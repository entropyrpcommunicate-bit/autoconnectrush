using System.Runtime.InteropServices;
namespace LessonPlanner;
internal static class Program {
    [STAThread] static void Main(string[] args) {
        ApplicationConfiguration.Initialize();
        using var mutex=new Mutex(true,"Local\\LessonPlanner.Windows",out var first);
        if(!first){MessageBox.Show("Планировщик уже запущен. Найдите его значок рядом с часами."); return;}
        try {
            var form=new PlannerForm();
            if(args.Contains("--smoke-test")) {
                using var stream=System.Reflection.Assembly.GetExecutingAssembly().GetManifestResourceStream("Planner.Windows.Assets.automation.js") ?? throw new Exception("Missing automation resource");
                var timer=new System.Windows.Forms.Timer{Interval=1500}; timer.Tick+=(_,_)=>{timer.Stop();form.Close();};timer.Start();
            }
            Application.Run(form);
        }
        catch(Exception e){if(args.Contains("--smoke-test")){Environment.Exit(1);return;}MessageBox.Show("Не удалось запустить приложение:\n"+e.Message,"Планировщик");}
    }
}
internal static class Power {
    [DllImport("kernel32.dll",SetLastError=true)] private static extern uint SetThreadExecutionState(uint flags);
    public static bool KeepAwake(bool on) => SetThreadExecutionState(0x80000000u | (on?0x1u:0)) != 0;
}
