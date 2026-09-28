using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Reflection;
using System.Text.Json;
namespace LessonPlanner;
internal sealed class RoomForm : Form {
    readonly WebView2 view=new(){Dock=DockStyle.Fill};
    readonly Job job;
    readonly bool automatic;
    readonly Action<string> report;
    readonly Label state=new(){Dock=DockStyle.Top,Height=46,Padding=new Padding(10),Text="Загрузка…"};
    readonly string profile;
    readonly string token=Guid.NewGuid().ToString("N");
    DateTimeOffset lastReload=DateTimeOffset.MinValue;
    int recoveries;
    bool connected;
    bool ending;
    public RoomForm(Job j,bool auto,string profilePath,Action<string> status) {
        job=j;automatic=auto;profile=profilePath;report=status;
        Text=auto?"Телемост · автоматическое подключение":"Телемост · ручная проверка";
        Width=1150;Height=800;StartPosition=FormStartPosition.CenterParent;
        Controls.Add(view);Controls.Add(state);
        Shown+=async (_,_)=>await Init();
    }
    void Say(string s){if(IsDisposed||ending)return;state.Text=s;report(s);}
    static bool Trusted(string s) => Uri.TryCreate(s,UriKind.Absolute,out var u)&&u.Scheme=="https"&&(u.Host=="yandex.ru"||u.Host.EndsWith(".yandex.ru",StringComparison.Ordinal)||u.Host=="yandex.net"||u.Host.EndsWith(".yandex.net",StringComparison.Ordinal));
    void Message(string source,string json) {
        if(ending||IsDisposed||!Trusted(source))return;
        try {
            using var d=JsonDocument.Parse(json);var r=d.RootElement;
            if(r.GetProperty("token").GetString()!=token)return;
            var kind=r.GetProperty("kind").GetString();
            var text=r.GetProperty("text").GetString()??"";
            if(kind=="connected"){connected=true;Say("Соединение WebRTC установлено. Проверьте присутствие при первом тесте.");}
            else if(kind=="disconnected"){connected=false;Say("Соединение прервано. Проверьте комнату.");}
            else if(kind=="landing"&&automatic&&!connected&&DateTimeOffset.UtcNow<job.End) {
                if(recoveries<3 && DateTimeOffset.UtcNow-lastReload>TimeSpan.FromSeconds(20)) {
                    recoveries++;lastReload=DateTimeOffset.UtcNow;Say($"Возврат к комнате ({recoveries}/3)…");view.CoreWebView2.Navigate(job.Url);
                } else if(recoveries>=3)Say("Телемост вернул главную страницу. Автовход не подтверждён.");
            } else if(kind=="status"&&!connected)Say(text);
        }catch(JsonException){}catch(KeyNotFoundException){}
    }
    void Frame(CoreWebView2Frame frame) {
        frame.WebMessageReceived+=(_,e)=>Message(e.Source,e.WebMessageAsJson);
        frame.FrameCreated+=(_,e)=>Frame(e.Frame);
        frame.PermissionRequested+=(_,e)=>{e.State=CoreWebView2PermissionState.Deny;e.Handled=true;};
        frame.ScreenCaptureStarting+=(_,e)=>e.Cancel=true;
    }
    async Task Init() {
        try {
            var environment=await CoreWebView2Environment.CreateAsync(null,profile,new CoreWebView2EnvironmentOptions("--disable-background-timer-throttling --disable-renderer-backgrounding"));
            if(ending||IsDisposed)return;
            await view.EnsureCoreWebView2Async(environment);
            if(ending||IsDisposed)return;
            var core=view.CoreWebView2;
            core.IsMuted=true;
            core.Settings.AreDefaultContextMenusEnabled=false;
            core.Settings.AreDevToolsEnabled=false;
            core.Settings.IsPasswordAutosaveEnabled=false;
            core.Settings.IsGeneralAutofillEnabled=false;
            core.PermissionRequested+=(_,e)=>e.State=CoreWebView2PermissionState.Deny;
            core.ScreenCaptureStarting+=(_,e)=>e.Cancel=true;
            core.DownloadStarting+=(_,e)=>e.Cancel=true;
            core.NewWindowRequested+=(_,e)=>{e.Handled=true;Say("Сайт запросил новое окно. Выполните вход вручную в этом окне.");};
            core.NavigationStarting+=(_,e)=>{if(!Trusted(e.Uri)&&e.Uri!="about:blank"){e.Cancel=true;Say("Переход за пределы Яндекса остановлен.");}};
            core.WebMessageReceived+=(_,e)=>Message(e.Source,e.WebMessageAsJson);
            core.FrameCreated+=(_,e)=>Frame(e.Frame);
            core.NavigationCompleted+=(_,e)=>{if(!e.IsSuccess)Say("Ошибка загрузки: "+e.WebErrorStatus+". Проверьте интернет и VPN.");};
            core.ProcessFailed+=(_,_)=>Say("Процесс браузера завершился. Остановите задание и повторите тест.");
            using var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("Planner.Windows.Assets.automation.js") ?? throw new InvalidDataException("Не найден сценарий автоматизации.");
            using var reader=new StreamReader(stream);
            var script=await reader.ReadToEndAsync();
            var config=JsonSerializer.Serialize(new{name=job.Name,auto=automatic,end=job.End.ToUnixTimeMilliseconds(),token});
            await core.AddScriptToExecuteOnDocumentCreatedAsync("(()=>{const config="+config+";\n"+script+"\n})();");
            if(ending||IsDisposed)return;
            if(automatic&&DateTimeOffset.UtcNow>=job.End){Say("Время задания уже истекло.");return;}
            core.Navigate(job.Url);
        } catch(WebView2RuntimeNotFoundException) {
            Say("Нужен Microsoft Edge WebView2 Runtime. Ссылка на установку есть в инструкции.");
        } catch(Exception e) { Say("Ошибка браузера: "+e.Message); }
    }
    public void Stop(){if(ending)return;ending=true;view.Dispose();Close();Dispose();}
    protected override void OnFormClosing(FormClosingEventArgs e) {
        if(!ending&&automatic&&MessageBox.Show(this,"Остановить текущую пару?","Подтверждение",MessageBoxButtons.YesNo)!=DialogResult.Yes){e.Cancel=true;return;}
        base.OnFormClosing(e);
    }
}
