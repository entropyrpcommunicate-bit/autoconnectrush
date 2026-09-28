import Cocoa
import WebKit

struct Lesson: Codable {
    var id = UUID().uuidString
    var url: String
    var name: String
    var start: Date
    var end: Date
    var state = "Ожидает"
}
func due(_ j: Lesson, _ now: Date) -> Bool { j.state == "Ожидает" && now >= j.start && now < j.end && now.timeIntervalSince(j.start) < 120 }
func minuteStart(_ date: Date) -> Date { Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60) }
func overlaps(_ a: Lesson, _ b: Lesson) -> Bool { a.start < b.end && b.start < a.end }
let moscowZone = TimeZone(identifier: "Europe/Moscow")!
let formatter: DateFormatter = { let f = DateFormatter(); f.timeZone = moscowZone; f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "dd.MM.yyyy HH:mm"; return f }()
let guardScript = #"""
(() => {
  const send = s => { try { window.webkit.messageHandlers.status.postMessage(s); } catch (_) {} };
  const frameID = Math.random().toString(36).slice(2);
  setInterval(() => { try { window.webkit.messageHandlers.frameReady.postMessage(frameID); } catch (_) {} }, 1000);
  const deny = () => Promise.reject(new DOMException('Камера и микрофон отключены планировщиком', 'NotAllowedError'));
  try { Object.defineProperty(navigator.mediaDevices, 'getUserMedia', {value:deny, writable:false, configurable:false}); } catch (_) {}
  try { Object.defineProperty(navigator.mediaDevices, 'getDisplayMedia', {value:deny, writable:false, configurable:false}); } catch (_) {}
  const NativePC = window.RTCPeerConnection;
  if (NativePC) {
    window.RTCPeerConnection = new Proxy(NativePC, {construct(target,args) {
      const pc = new target(...args);
      pc.addEventListener('connectionstatechange', () => {
        if (pc.connectionState === 'connected') send('Соединение WebRTC установлено');
        if (['failed','disconnected'].includes(pc.connectionState)) send('Соединение прервано — проверьте комнату');
      });
      return pc;
    }});
  }
  setInterval(() => document.querySelectorAll('audio,video').forEach(e => { e.muted = true; e.volume = 0; }), 300);
})();
"""#

class Planner: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
    var window: NSWindow!
    var browserWindow: NSWindow?
    var web: WKWebView?
    var timer: Timer?
    var coffee: Process?
    var jobs: [Lesson] = []
    var active: String?
    var attempts = 0
    var lastAttempt = Date.distantPast
    var frames: [String: WKFrameInfo] = [:]
    var busyFrames = Set<String>()
    var lastRecovery = Date.distantPast
    var recoveryCount = 0
    var connected = false
    var activity: NSObjectProtocol?
    let urlField = NSTextField(string: "")
    let nameField = NSTextField(string: "")
    let startPicker = NSDatePicker()
    let endPicker = NSDatePicker()
    let list = NSTextView()
    let status = NSTextField(wrappingLabelWithString: "Автовход экспериментальный: сначала проверьте на тестовой встрече. Камера и микрофон запрещены.")
    let sleepStatus = NSTextField(labelWithString: "")
    let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalLessonPlanner/jobs.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        load()
        let menu = NSMenu(); let root = NSMenuItem(); menu.addItem(root); root.submenu = NSMenu()
        root.submenu!.addItem(withTitle: "Выйти из планировщика", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:980,height:680), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        window.title = "Пары · планировщик 0.4.1"; window.center(); window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:24),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-24)])
        let title = NSTextField(labelWithString:"Твоё расписание · Москва (UTC+3)"); title.font = .systemFont(ofSize:24,weight:.bold); stack.addArrangedSubview(title)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:"Работает локально без Codex. Интернет нужен для Телемоста. Приложение должно оставаться запущенным."))
        stack.addArrangedSubview(NSTextField(labelWithString:"Ссылка Телемоста")); stack.addArrangedSubview(urlField)
        stack.addArrangedSubview(NSTextField(labelWithString:"Имя участника")); stack.addArrangedSubview(nameField)
        for p in [startPicker,endPicker] { p.datePickerStyle = .textFieldAndStepper; p.datePickerElements = [.yearMonthDay,.hourMinute]; p.timeZone = moscowZone; p.locale = Locale(identifier:"ru_RU") }
        startPicker.dateValue = minuteStart(Date().addingTimeInterval(600)); endPicker.dateValue = minuteStart(Date().addingTimeInterval(4200))
        let dates = NSStackView(views:[NSTextField(labelWithString:"Вход:"),startPicker,NSTextField(labelWithString:"Выход:"),endPicker]); dates.spacing = 12; stack.addArrangedSubview(dates)
        let buttons = NSStackView(views:[button("Добавить в расписание",#selector(add)),button("Проверить страницу",#selector(preview)),button("Автотест 90 с",#selector(autoTest)),button("Остановить / отменить всё",#selector(cancelAll))]); buttons.spacing = 10; stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(status); stack.addArrangedSubview(sleepStatus)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = list
        list.isEditable = false; list.isSelectable = true; list.font = .monospacedSystemFont(ofSize:12,weight:.regular); list.autoresizingMask = [.width]; list.isVerticallyResizable = true; list.textContainer!.widthTracksTextView = true
        stack.addArrangedSubview(scroll); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:140).isActive = true
        for v in [urlField,nameField,status,sleepStatus,scroll] { v.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:"На зарядке • крышка открыта • не выбирай «Режим сна». Пока есть задания, приложение препятствует автоматическому сну. Экран можно погасить."))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        timer = Timer(timeInterval:0.25,repeats:true) { [weak self] _ in self?.tick() }
        timer!.tolerance = 0.05
        RunLoop.main.add(timer!, forMode:.common)
        tick()
    }
    func button(_ title:String,_ action:Selector)->NSButton { NSButton(title:title,target:self,action:action) }
    func error(_ text:String) { status.stringValue = text; NSSound.beep() }
    func input() -> Lesson? {
        let s = urlField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let u = URL(string:s), u.scheme == "https", ["telemost.yandex.ru","telemost.360.yandex.ru"].contains(u.host ?? ""), u.path.hasPrefix("/j/"), u.user == nil, u.password == nil else { error("Нужна HTTPS-ссылка комнаты Телемоста с /j/."); return nil }
        let n = nameField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !n.isEmpty else { error("Укажи имя участника."); return nil }
        return Lesson(url:s,name:n,start:minuteStart(startPicker.dateValue),end:minuteStart(endPicker.dateValue))
    }
    @objc func add() {
        guard let j = input() else { return }
        guard j.start > Date(), j.end > j.start else { error("Вход должен быть в будущем, а выход — позже входа."); return }
        guard !jobs.contains(where:{ ["Ожидает","Выполняется"].contains($0.state) && overlaps($0,j) }) else { error("Это время пересекается с другой запланированной парой."); return }
        jobs.append(j); jobs.sort{$0.start < $1.start}; save(); refresh(); keepAwake()
        status.stringValue = "Запланировано: \(formatter.string(from:j.start)) → \(formatter.string(from:j.end)). Проверь вход заранее."
    }
    @objc func autoTest() {
        guard active == nil, !jobs.contains(where: { $0.state == "Ожидает" && $0.start < Date().addingTimeInterval(90) }) else { error("Автотест пересекается с запланированной парой."); return }
        guard var j = input() else { return }
        j.start = Date(); j.end = Date().addingTimeInterval(90)
        jobs.append(j); save(); tick(); refresh()
    }
    @objc func preview() {
        guard active == nil else { error("Сначала останови текущую пару."); return }
        guard let j = input() else { return }
        openRoom(j, auto:false)
        status.stringValue = "Проверка страницы: автоматическая кнопка входа отключена. Разрешения камеры и микрофона заблокированы."
    }
    func openRoom(_ j:Lesson, auto:Bool) {
        destroyBrowser()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addUserScript(WKUserScript(source:guardScript,injectionTime:.atDocumentStart,forMainFrameOnly:false))
        config.userContentController.add(self,name:"status")
        config.userContentController.add(self,name:"frameReady")
        let w = WKWebView(frame:NSRect(x:0,y:0,width:1050,height:720),configuration:config)
        w.navigationDelegate = self; w.uiDelegate = self
        web = w
        let bw = NSWindow(contentRect:w.frame,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        bw.title = auto ? "Телемост · пара по расписанию" : "Телемост · проверка без автоматического входа"
        bw.isReleasedWhenClosed = false; bw.contentView = w; bw.delegate = self; browserWindow = bw
        bw.center(); bw.makeKeyAndOrderFront(nil); w.load(URLRequest(url:URL(string:j.url)!))
    }
    func destroyBrowser() {
        frames.removeAll(); busyFrames.removeAll(); connected = false
        web?.configuration.userContentController.removeScriptMessageHandler(forName:"frameReady")
        web?.stopLoading(); web?.configuration.userContentController.removeScriptMessageHandler(forName:"status")
        web?.loadHTMLString("<html><body>Соединение завершено планировщиком.</body></html>",baseURL:nil)
        browserWindow?.contentView = nil; browserWindow?.orderOut(nil); browserWindow = nil; web = nil
    }
    @objc func cancelAll() {
        for i in jobs.indices where ["Ожидает","Выполняется"].contains(jobs[i].state) { jobs[i].state = "Отменено" }
        active = nil; destroyBrowser(); save(); refresh(); keepAwake(); status.stringValue = "Все задания отменены. Окно комнаты закрыто."
    }
    func tick() {
        let now = Date(); var changed = false
        if let id = active, let i = jobs.firstIndex(where:{$0.id == id}) {
            if now >= jobs[i].end { jobs[i].state = "Завершено (окно закрыто)"; active = nil; destroyBrowser(); status.stringValue = "Время вышло — страница комнаты закрыта, подключение остановлено."; changed = true }
            else if now.timeIntervalSince(lastAttempt) >= 0.75 { tryJoin(jobs[i]); lastAttempt = now }
        }
        for i in jobs.indices where jobs[i].state == "Ожидает" {
            if now >= jobs[i].end || now.timeIntervalSince(jobs[i].start) >= 120 { jobs[i].state = "Пропущено — приложение не работало вовремя"; changed = true }
            else if active == nil && due(jobs[i],now) {
                jobs[i].state = "Выполняется"; active = jobs[i].id; attempts = 0; recoveryCount = 0; lastRecovery = .distantPast; lastAttempt = .distantPast
                openRoom(jobs[i],auto:true); status.stringValue = "Открываю комнату. Подключение пока не подтверждено."; changed = true
            }
        }
        if changed { save(); refresh() }; keepAwake()
    }
    func tryJoin(_ j:Lesson) {
        guard let web = web else { return }
        let encoded = String(data:try! JSONEncoder().encode(j.name),encoding:.utf8)!
        let script = #"""
        (() => {
          if (location.protocol === 'about:') return 'Страница загружается; подключение пока не подтверждено';
          if (!/(^|\.)(yandex\.ru|yandex\.net)$/.test(location.hostname)) return 'Нужен вход в аккаунт — выполни его вручную';
          const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          const norm = s => (s || '').trim().toLowerCase().replace(/\s+/g,' ');
          const controls = [...document.querySelectorAll('button,[role="button"],a,input[type="button"],input[type="submit"],[tabindex]')].filter(visible);
          const label = e => norm(e.innerText || e.getAttribute('aria-label') || e.value || e.title);
          const enabled = e => !e.disabled && e.getAttribute('aria-disabled') !== 'true';
          // Dismiss only the observed camera-error notice, never arbitrary confirmations.
          const acknowledgements = controls.filter(e => label(e) === 'понятно' && enabled(e));
          for (const ack of acknowledgements) {
            let panel = ack.parentElement;
            while (panel && panel !== document.body && panel !== document.documentElement) {
              const text = norm(panel.innerText);
              if (text.length < 1800 && text.includes('включить видео не удалось')) {
                ack.click(); return 'Сообщение о камере закрыто. Камера остаётся заблокирована.';
              }
              panel = panel.parentElement;
            }
          }
          const browser = controls.find(e => label(e) === 'продолжить в браузере' && enabled(e));
          if (browser) { browser.click(); return 'Открываю форму подключения в браузере'; }
          const join = controls.find(e => /^(подключиться|присоединиться|войти во встречу|join|join meeting)$/.test(label(e)) && enabled(e));
          // The pre-join page also has a hang-up button in its sidebar.
          // Process the name dialog before considering any in-call controls.
          if (join) {
            const fields = [...document.querySelectorAll('input,[contenteditable="true"],[role="textbox"]')].filter(e => visible(e) && !e.disabled && !e.readOnly && (!e.tagName || e.tagName !== 'INPUT' || ['text','search',''].includes(e.type || '')));
            const value = e => e.isContentEditable ? e.textContent : e.value;
            const description = e => [e.placeholder,e.getAttribute('aria-label'),e.name,
              ...[...(e.labels || [])].map(l => l.textContent),
              ...(e.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean).map(id => document.getElementById(id)?.textContent || '')].join(' ');
            let candidates = fields.filter(e => /имя|name/i.test(description(e)) && !/email|почта|логин|пароль|password|search|поиск/i.test(description(e)));
            if (candidates.length === 0) candidates = fields.filter(e => ['гость','guest',norm(NAME_VALUE)].includes(norm(value(e))));
            if (candidates.length !== 1) return 'Не удалось однозначно определить поле имени — проверь форму вручную';
            const name = candidates[0];
            if (value(name) !== NAME_VALUE) {
              name.focus();
              if (name.isContentEditable) name.textContent = NAME_VALUE;
              else Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(name, NAME_VALUE);
              name.dispatchEvent(new Event('input',{bubbles:true})); name.dispatchEvent(new Event('change',{bubbles:true}));
              name.blur();
              return 'Имя заполнено; проверяю его перед подключением';
            }
            // Only explicit turn-off actions; never toggle an already-off device.
            const off = controls.find(e => /^(выключить|отключить) (микрофон|камеру)(\s*\(.*\))?$/.test(label(e)) && enabled(e));
            if (off) { off.click(); return 'Выключаю устройство перед подключением'; }
            if ((window.__plannerJoinCount || 0) >= 6) return 'Лимит попыток входа: проверь комнату вручную';
            if (Date.now() - (window.__plannerLastJoin || 0) < 12000) return 'Ожидаю результат подключения';
            window.__plannerLastJoin = Date.now(); window.__plannerJoinCount = (window.__plannerJoinCount || 0) + 1;
            join.click(); return 'CLICKED';
          }
          if (controls.some(e => /^(покинуть встречу|выйти из встречи|завершить звонок|leave meeting)$/.test(label(e)))) return 'Виден интерфейс встречи; дождитесь подтверждения соединения';
          const pageText = norm(document.body?.innerText);
          if (window === window.top && /^\/?$/.test(location.pathname) && pageText.includes('яндекс телемост') && pageText.includes('скачайте приложение')) return 'LANDING';
          return 'Ожидание формы, допуска организатора или ручного входа';
        })()
        """#.replacingOccurrences(of:"NAME_VALUE",with:encoded)
        let targets: [(String, WKFrameInfo?)] = [("main", nil)] + frames.map { ($0.key, Optional($0.value)) }
        for (key, frame) in targets where !busyFrames.contains(key) {
            busyFrames.insert(key)
            web.evaluateJavaScript(script, in: frame, in: .page) { [weak self, weak web] result in
                guard let self = self else { return }
                self.busyFrames.remove(key)
                guard self.active == j.id, self.web === web else { return }
                switch result {
                case .success(let value):
                    guard let s = value as? String else { return }
                    if s == "CLICKED" { self.attempts += 1; self.status.stringValue = "Нажата кнопка входа. Жду подтверждения соединения." }
                    else if s == "LANDING" {
                        if !self.connected && self.recoveryCount < 3 && Date().timeIntervalSince(self.lastRecovery) > 20 {
                            self.recoveryCount += 1; self.lastRecovery = Date()
                            self.status.stringValue = "Вместо комнаты открылась главная. Повторяю переход по ссылке (\(self.recoveryCount)/3)."
                            web?.load(URLRequest(url:URL(string:j.url)!))
                        } else if !self.connected { self.status.stringValue = "Телемост перенаправил на главную — подключение не подтверждено." }
                    } else if s != "Ожидание формы, допуска организатора или ручного входа" && !self.connected { self.status.stringValue = s }
                case .failure:
                    if key != "main" { self.frames.removeValue(forKey:key) }
                }
            }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message:WKScriptMessage) {
        let host = message.frameInfo.securityOrigin.host
        guard host == "yandex.ru" || host.hasSuffix(".yandex.ru") || host == "yandex.net" || host.hasSuffix(".yandex.net") else { return }
        if message.name == "frameReady", let id = message.body as? String, !message.frameInfo.isMainFrame {
            frames[id] = message.frameInfo
        } else if active != nil, let s = message.body as? String {
            connected = s == "Соединение WebRTC установлено"
            status.stringValue = s
        }
    }
    func webView(_ webView:WKWebView, didStartProvisionalNavigation navigation:WKNavigation!) { frames.removeAll(); busyFrames.removeAll(); connected = false }
    func webView(_ webView:WKWebView, didFinish navigation:WKNavigation!) {
        if let j = jobs.first(where:{$0.id == active}) { tryJoin(j) }
    }
    func webView(_ webView:WKWebView, requestMediaCapturePermissionFor origin:WKSecurityOrigin, initiatedByFrame frame:WKFrameInfo, type:WKMediaCaptureType, decisionHandler:@escaping (WKPermissionDecision)->Void) { decisionHandler(.deny) }
    func webView(_ webView:WKWebView, didFailProvisionalNavigation navigation:WKNavigation!, withError error:Error) { status.stringValue = "Не удалось загрузить Телемост: \(error.localizedDescription)" }
    func webView(_ webView:WKWebView, decidePolicyFor navigationAction:WKNavigationAction, decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
        guard let u = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(["https","about"].contains(u.scheme ?? "") ? .allow : .cancel)
    }
    func keepAwake() {
        let pending = jobs.contains{["Ожидает","Выполняется"].contains($0.state)}
        if pending && activity == nil { activity = ProcessInfo.processInfo.beginActivity(options:[.userInitiatedAllowingIdleSystemSleep,.latencyCritical],reason:"Выполнение расписания пар") }
        if !pending, let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        if pending && coffee?.isRunning != true {
            let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/caffeinate"); p.arguments = ["-i","-w",String(ProcessInfo.processInfo.processIdentifier)]
            do { try p.run(); coffee = p } catch { sleepStatus.stringValue = "Не удалось включить защиту от сна: \(error.localizedDescription)"; return }
        } else if !pending { coffee?.terminate(); coffee = nil }
        sleepStatus.stringValue = pending ? "● Защита от автоматического сна включена. Крышку не закрывай." : "Нет ожидающих заданий — обычный режим сна."
    }
    func refresh() { list.string = jobs.isEmpty ? "Заданий пока нет." : jobs.map { "\(formatter.string(from:$0.start)) → \(formatter.string(from:$0.end)) МСК\n\($0.name) · \($0.state)\n\($0.url)\n" }.joined(separator:"\n") }
    func save() { do { try FileManager.default.createDirectory(at:storeURL.deletingLastPathComponent(),withIntermediateDirectories:true); try JSONEncoder().encode(jobs).write(to:storeURL,options:.atomic) } catch { status.stringValue = "Ошибка сохранения расписания: \(error.localizedDescription)" } }
    func load() { if let d = try? Data(contentsOf:storeURL), let saved = try? JSONDecoder().decode([Lesson].self,from:d) { jobs = saved; for i in jobs.indices where jobs[i].state == "Выполняется" { jobs[i].state = "Прервано при закрытии приложения" } }; refresh() }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        if sender === window { window.miniaturize(nil); return false }
        if sender === browserWindow && active != nil {
            let a = NSAlert(); a.messageText = "Остановить текущую пару?"; a.addButton(withTitle:"Продолжить пару"); a.addButton(withTitle:"Остановить")
            if a.runModal() == .alertFirstButtonReturn { return false }
            if let i = jobs.firstIndex(where:{$0.id == active}) { jobs[i].state = "Остановлено вручную" }; active = nil; status.stringValue = "Пара остановлена вручную."; save(); refresh(); keepAwake()
        }
        destroyBrowser(); return false
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if jobs.contains(where:{["Ожидает","Выполняется"].contains($0.state)}) {
            let a = NSAlert(); a.messageText = "После выхода расписание не выполняется"; a.informativeText = "Будущие задания сохранятся, но приложение нужно открыть до времени входа."; a.addButton(withTitle:"Остаться"); a.addButton(withTitle:"Выйти")
            if a.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification:Notification) { coffee?.terminate(); destroyBrowser(); save() }
}
if CommandLine.arguments.contains("--self-test") {
    let t = Date(timeIntervalSince1970:1800000000)
    precondition(minuteStart(t.addingTimeInterval(59)) == t)
    let j = Lesson(url:"https://telemost.360.yandex.ru/j/1",name:"Тест",start:t,end:t.addingTimeInterval(600))
    precondition(!due(j,t.addingTimeInterval(-1))); precondition(due(j,t)); precondition(!due(j,t.addingTimeInterval(120))); precondition(!due(j,t.addingTimeInterval(600)))
    var other = j; other.start = j.end; other.end = j.end.addingTimeInterval(600); precondition(!overlaps(j,other)); other.start = j.start.addingTimeInterval(1); precondition(overlaps(j,other))
    let decoded = try! JSONDecoder().decode([Lesson].self,from:JSONEncoder().encode([j])); precondition(decoded[0].name == "Тест"); precondition(moscowZone.secondsFromGMT(for:t) == 10800)
    print("PASS: scheduling boundaries, missed-job cutoff, overlap detection, persistence, Moscow timezone")
} else {
    let app = NSApplication.shared; let delegate = Planner(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
}
