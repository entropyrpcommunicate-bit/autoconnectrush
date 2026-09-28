namespace LessonPlanner;
internal sealed class PlannerForm : Form {
    readonly TextBox url=new(){Width=790,PlaceholderText="https://telemost.360.yandex.ru/j/…"};
    readonly TextBox name=new(){Width=400,PlaceholderText="Имя и фамилия"};
    readonly DateTimePicker start=new(){Format=DateTimePickerFormat.Custom,CustomFormat="dd.MM.yyyy HH:mm",Width=180};
    readonly DateTimePicker end=new(){Format=DateTimePickerFormat.Custom,CustomFormat="dd.MM.yyyy HH:mm",Width=180};
    readonly Label status=new(){AutoSize=true,MaximumSize=new Size(860,0),Text="Сначала проверьте автоматический вход на тестовой встрече."};
    readonly Label power=new(){AutoSize=true};
    readonly ListView list=new(){View=View.Details,FullRowSelect=true,MultiSelect=false,Dock=DockStyle.Fill};
    readonly System.Windows.Forms.Timer timer=new(){Interval=250};
    readonly NotifyIcon tray=new(){Icon=SystemIcons.Application,Text="Планировщик пар",Visible=true};
    readonly JobStore store;
    readonly List<Job> jobs;
    readonly string data=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"LessonPlanner");
    RoomForm? room;
    Job? active;
    bool quitting;
    bool tickBusy;
    public PlannerForm() {
        store=new JobStore(Path.Combine(data,"jobs.json"));jobs=store.Load();
        Text="Планировщик пар · Windows · 0.5";Width=990;Height=700;MinimumSize=new Size(850,580);Font=new Font("Segoe UI",10);StartPosition=FormStartPosition.CenterScreen;
        start.Value=Schedule.MoscowNow.AddMinutes(5).DateTime;end.Value=Schedule.MoscowNow.AddMinutes(95).DateTime;
        var top=new FlowLayoutPanel(){Dock=DockStyle.Top,AutoSize=true,FlowDirection=FlowDirection.TopDown,WrapContents=false,Padding=new Padding(18)};
        top.Controls.Add(new Label(){Text="Расписание по Москве · UTC+3",AutoSize=true,Font=new Font("Segoe UI",20,FontStyle.Bold)});
        top.Controls.Add(new Label(){Text="Работает без Codex. Нужны интернет, включённый компьютер и открытое приложение.",AutoSize=true});
        top.Controls.Add(new Label(){Text="Ссылка комнаты",AutoSize=true});top.Controls.Add(url);
        top.Controls.Add(new Label(){Text="Имя на встрече",AutoSize=true});top.Controls.Add(name);
        var dates=Row();dates.Controls.Add(new Label(){Text="Вход:",AutoSize=true});dates.Controls.Add(start);dates.Controls.Add(new Label(){Text="Выход:",AutoSize=true});dates.Controls.Add(end);top.Controls.Add(dates);
        var buttons=Row();buttons.Controls.Add(Button("Добавить",Add));buttons.Controls.Add(Button("Автотест 90 с",Test));buttons.Controls.Add(Button("Ручная проверка",Preview));buttons.Controls.Add(Button("Отменить выбранное",Cancel));buttons.Controls.Add(Button("Инструкция",Help));top.Controls.Add(buttons);
        top.Controls.Add(status);top.Controls.Add(power);
        list.Columns.Add("Вход · МСК",160);list.Columns.Add("Выход · МСК",160);list.Columns.Add("Имя",190);list.Columns.Add("Состояние",300);
        Controls.Add(list);Controls.Add(top);
        var bottom=new Label(){Dock=DockStyle.Bottom,Height=45,Padding=new Padding(15,8,0,0),Text="Оставьте питание подключённым. Крышку не закрывайте. Экран может погаснуть."};Controls.Add(bottom);
        tray.ContextMenuStrip=new ContextMenuStrip();tray.ContextMenuStrip.Items.Add("Открыть",null,(_,_)=>ShowWindow());tray.ContextMenuStrip.Items.Add("Выйти",null,(_,_)=>Close());tray.DoubleClick+=(_,_)=>ShowWindow();
        Resize+=(_,_)=>{if(WindowState==FormWindowState.Minimized)Hide();};
        FormClosing+=OnClosingRequested;
        timer.Tick+=(_,_)=>Tick();timer.Start();RefreshJobs();Tick();
    }
    static FlowLayoutPanel Row()=>new(){AutoSize=true,WrapContents=true,FlowDirection=FlowDirection.LeftToRight};
    static Button Button(string text,Action action){var b=new Button(){Text=text,AutoSize=true,Height=34};b.Click+=(_,_)=>action();return b;}
    void Say(string text){status.Text=text;}
    Job Input()=>new(){Url=url.Text.Trim(),Name=name.Text.Trim(),Start=Schedule.FromPicker(start.Value),End=Schedule.FromPicker(end.Value)};
    void Add(){var j=Input();var issue=Schedule.Validate(j,jobs,DateTimeOffset.UtcNow);if(issue!=null){Say(issue);return;}jobs.Add(j);if(!Save()){jobs.Remove(j);return;}RefreshJobs();Tick();Say("Задание сохранено. Перед первой парой выполните автотест.");}
    bool CheckRoom(Job j){if(!Schedule.ValidUrl(j.Url)||string.IsNullOrWhiteSpace(j.Name)){Say("Введите ссылку комнаты и имя.");return false;}return true;}
    void Test(){var j=Input();if(!CheckRoom(j))return;if(active!=null){Say("Сначала остановите текущую пару.");return;}j.Start=DateTimeOffset.UtcNow.AddMilliseconds(20);j.End=j.Start.AddSeconds(90);if(jobs.Any(x=>Schedule.IsLive(x)&&Schedule.Overlap(x,j))){Say("Автотест пересекается с заданием.");return;}jobs.Add(j);if(!Save()){jobs.Remove(j);return;}RefreshJobs();Tick();}
    void Preview(){var j=Input();if(!CheckRoom(j))return;if(active!=null){Say("Сначала остановите текущую пару.");return;}CloseRoom();room=new RoomForm(j,false,Path.Combine(data,"BrowserProfile"),Say);room.Show(this);Say("Ручная проверка: автоматические нажатия отключены.");}
    void Cancel(){if(list.SelectedItems.Count==0){Say("Выберите задание в списке.");return;}var j=(Job)list.SelectedItems[0].Tag!;if(!Schedule.IsLive(j))return;j.State=JobState.Cancelled;if(active?.Id==j.Id){active=null;CloseRoom();}Save();RefreshJobs();Tick();Say("Выбранное задание отменено.");}
    void Start(Job j){CloseRoom();active=j;j.State=JobState.Running;Save();Say("Открываю комнату. Подключение пока не подтверждено.");var opened=new RoomForm(j,true,Path.Combine(data,"BrowserProfile"),Say);room=opened;opened.FormClosed+=(_,_)=>{if(active?.Id==j.Id){j.State=JobState.Cancelled;active=null;Save();RefreshJobs();}if(ReferenceEquals(room,opened))room=null;};opened.Show(this);}
    void CloseRoom(){var old=room;room=null;if(old!=null&&!old.IsDisposed)old.Stop();}
    void Tick(){if(tickBusy||quitting)return;tickBusy=true;try{var now=DateTimeOffset.UtcNow;var changed=false;
        if(active!=null&&now>=active.End){active.State=JobState.Completed;active=null;CloseRoom();changed=true;Say("Время вышло. Соединение закрыто.");}
        foreach(var j in jobs.Where(j=>j.State==JobState.Pending).OrderBy(j=>j.Start).ToArray()){
            if(Schedule.IsMissed(j,now)){j.State=JobState.Missed;changed=true;}
            else if(active==null&&Schedule.IsDue(j,now)){Start(j);changed=true;}
        }
        if(changed){Save();RefreshJobs();}
        var pending=jobs.Any(Schedule.IsLive);var ok=Power.KeepAwake(pending);
        power.Text=ok?(pending?"● Автоматический сон отключён, пока есть задания.":"Нет ожидающих заданий — обычный режим сна."):"Не удалось удержать компьютер от сна. Проверьте параметры питания.";
    }finally{tickBusy=false;}}
    bool Save(){try{store.Save(jobs);return true;}catch(Exception e){Say("Не удалось сохранить расписание: "+e.Message);return false;}}
    void RefreshJobs(){var selected=list.SelectedItems.Count>0?((Job)list.SelectedItems[0].Tag!).Id:Guid.Empty;list.BeginUpdate();list.Items.Clear();foreach(var j in jobs.OrderBy(j=>j.Start)){var item=new ListViewItem([j.Start.ToOffset(Schedule.MoscowOffset).ToString("dd.MM.yyyy HH:mm"),j.End.ToOffset(Schedule.MoscowOffset).ToString("dd.MM.yyyy HH:mm"),j.Name,Schedule.StateText(j.State)]){Tag=j,Selected=j.Id==selected};list.Items.Add(item);}list.EndUpdate();}
    void ShowWindow(){Show();WindowState=FormWindowState.Normal;Activate();}
    void Help()=>MessageBox.Show(this,"1. Укажите ссылку и имя.\n2. Выполните «Автотест 90 с»: это реальный вход и выход.\n3. Добавьте занятия по московскому времени.\n4. Не закрывайте приложение и не усыпляйте компьютер.\n\nКамера, микрофон и звук отключены. Авторизация и CAPTCHA — вручную. Вход не гарантирован, если сайт изменился или сеть недоступна.\n\nПолная инструкция — README.ru.md рядом с приложением.","Как пользоваться");
    void OnClosingRequested(object? sender,FormClosingEventArgs e){if(jobs.Any(Schedule.IsLive)&&MessageBox.Show(this,"После выхода задания выполняться не будут. Выйти?","Планировщик",MessageBoxButtons.YesNo)!=DialogResult.Yes){e.Cancel=true;return;}quitting=true;timer.Stop();if(active!=null)active.State=JobState.Interrupted;active=null;CloseRoom();Save();Power.KeepAwake(false);tray.Visible=false;tray.Dispose();}
}
