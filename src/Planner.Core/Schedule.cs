using System.Text.Json;
namespace LessonPlanner;
public enum JobState { Pending, Running, Completed, Cancelled, Missed, Interrupted, Failed }
public sealed class Job {
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Url { get; set; } = "";
    public string Name { get; set; } = "";
    public DateTimeOffset Start { get; set; }
    public DateTimeOffset End { get; set; }
    public JobState State { get; set; }
}
public static class Schedule {
    public static readonly TimeSpan MoscowOffset = TimeSpan.FromHours(3);
    public static DateTimeOffset MoscowNow => DateTimeOffset.UtcNow.ToOffset(MoscowOffset);
    public static DateTimeOffset FromPicker(DateTime d) => new(new DateTime(d.Year,d.Month,d.Day,d.Hour,d.Minute,0,DateTimeKind.Unspecified),MoscowOffset);
    public static bool Overlap(Job a, Job b) => a.Start < b.End && b.Start < a.End;
    public static bool IsLive(Job j) => j.State is JobState.Pending or JobState.Running;
    public static bool IsDue(Job j, DateTimeOffset now) => j.State == JobState.Pending && now >= j.Start && now < j.End && now-j.Start < TimeSpan.FromMinutes(2);
    public static bool IsMissed(Job j, DateTimeOffset now) => j.State == JobState.Pending && (now >= j.End || now-j.Start >= TimeSpan.FromMinutes(2));
    public static bool ValidUrl(string text) => Uri.TryCreate(text,UriKind.Absolute,out var u) && u.Scheme=="https" && u.IsDefaultPort && u.UserInfo.Length==0 && (u.Host=="telemost.yandex.ru" || u.Host=="telemost.360.yandex.ru") && System.Text.RegularExpressions.Regex.IsMatch(u.AbsolutePath,@"^/j/[A-Za-z0-9_-]+/?$");
    public static string? Validate(Job j, IEnumerable<Job> existing, DateTimeOffset now) {
        if (!ValidUrl(j.Url)) return "Нужна HTTPS-ссылка комнаты Телемоста вида …/j/номер.";
        if (string.IsNullOrWhiteSpace(j.Name) || j.Name.Length>150) return "Введите имя участника (до 150 символов).";
        if (j.Start<=now) return "Время входа должно быть в будущем (по Москве).";
        if (j.End<=j.Start) return "Выход должен быть позже входа.";
        if (existing.Any(x=>IsLive(x)&&Overlap(x,j))) return "Время пересекается с другим заданием.";
        return null;
    }
    public static string StateText(JobState s) => s switch {
        JobState.Pending=>"Ожидает", JobState.Running=>"Выполняется", JobState.Completed=>"Завершено: окно закрыто",
        JobState.Cancelled=>"Отменено", JobState.Missed=>"Пропущено", JobState.Interrupted=>"Прервано", _=>"Ошибка"
    };
}
public sealed class JobStore(string path) {
    public List<Job> Load() {
        if (!File.Exists(path)) return [];
        var jobs=JsonSerializer.Deserialize<List<Job>>(File.ReadAllText(path)) ?? throw new InvalidDataException("Расписание пустое или повреждено.");
        if (jobs.Any(j=>!Schedule.ValidUrl(j.Url)||string.IsNullOrWhiteSpace(j.Name)||j.End<=j.Start||!Enum.IsDefined(j.State))) throw new InvalidDataException("Расписание содержит неверные данные.");
        foreach(var j in jobs.Where(j=>j.State==JobState.Running)) j.State=JobState.Interrupted;
        return jobs;
    }
    public void Save(IEnumerable<Job> jobs) {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temp=path+".tmp";
        File.WriteAllText(temp,JsonSerializer.Serialize(jobs,new JsonSerializerOptions{WriteIndented=true}));
        File.Move(temp,path,true);
    }
}
