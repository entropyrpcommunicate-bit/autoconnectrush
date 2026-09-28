// Injected into every document, including Yandex child frames.
const trusted = () => /(^|\.)(yandex\.ru|yandex\.net)$/.test(location.hostname) && location.protocol === 'https:';
let lastStatus = '';
function send(kind,text='') { if (!trusted()) return; try { window.chrome.webview.postMessage({token:config.token,kind,text}); } catch (_) {} }
const deny = () => Promise.reject(new DOMException('Камера и микрофон отключены', 'NotAllowedError'));
for (const key of ['getUserMedia','getDisplayMedia']) {
  try { Object.defineProperty(navigator.mediaDevices,key,{value:deny,writable:false,configurable:false}); } catch (_) {}
}
if (window.RTCPeerConnection) {
  const Native = window.RTCPeerConnection;
  window.RTCPeerConnection = new Proxy(Native,{construct(target,args){
    const pc = new target(...args);
    pc.addEventListener('connectionstatechange',()=>{
      if(pc.connectionState==='connected')send('connected');
      if(['failed','disconnected','closed'].includes(pc.connectionState))send('disconnected');
    });return pc;
  }});
}
function step() {
          if (Date.now() >= config.end) return 'Время задания истекло';
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
            if (candidates.length === 0) candidates = fields.filter(e => ['гость','guest',norm(config.name)].includes(norm(value(e))));
            if (candidates.length !== 1) return 'Не удалось однозначно определить поле имени — проверь форму вручную';
            const name = candidates[0];
            if (value(name) !== config.name) {
              name.focus();
              if (name.isContentEditable) name.textContent = config.name;
              else Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(name, config.name);
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
          // Telemost can show its home screen inside a frame while retaining /j/... .
          const pageText = norm(document.body?.innerText);
          const landing = pageText.includes('яндекс телемост') && pageText.includes('скачайте приложение') && pageText.includes('войдите в аккаунт');
          if (landing) {
            window.__plannerLandingSince ??= Date.now();
            return Date.now() - window.__plannerLandingSince >= 5000 ? 'LANDING' : 'Проверяю возврат на главную страницу';
          }
          delete window.__plannerLandingSince;
          if (controls.some(e => /^(покинуть встречу|выйти из встречи|завершить звонок|leave meeting)$/.test(label(e)))) return 'Виден интерфейс встречи; дождитесь подтверждения соединения';
          return 'Ожидание формы, допуска организатора или ручного входа';
        }
function advance() {
  if (!config.auto || !trusted() || Date.now() >= config.end) return;
  try {
    const s = step();
    if (s === 'LANDING') { send('landing'); return; }
    if (s !== lastStatus) { lastStatus = s; send('status',s === 'CLICKED' ? 'Нажата кнопка входа; подключение ещё не подтверждено.' : s); }
  } catch (_) { send('status','Не удалось обработать форму. Проверьте страницу вручную.'); }
}
setInterval(advance,750);
document.addEventListener('DOMContentLoaded',advance);
