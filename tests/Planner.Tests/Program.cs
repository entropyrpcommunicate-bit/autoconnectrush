using LessonPlanner;
using System.Text.Json;
var count=0;
void Check(bool condition,string name){if(!condition)throw new Exception(name);Console.WriteLine("PASS: "+name);count++;}
var now=new DateTimeOffset(2026,10,1,8,57,0,TimeSpan.FromHours(3));
Job J()=>new(){Name="Test Participant",Url="https://telemost.360.yandex.ru/j/1234567890",Start=now,End=now.AddHours(1)};
Check(Schedule.FromPicker(new DateTime(2026,10,1,8,57,59)).Second==0,"hidden seconds removed");
Check(Schedule.FromPicker(new DateTime(2026,10,1,8,57,59)).UtcDateTime.Hour==5,"Moscow time independent of system zone");
Check(!Schedule.IsDue(J(),now.AddTicks(-1)),"no early entry");
Check(Schedule.IsDue(J(),now),"entry at boundary");
Check(Schedule.IsDue(J(),now.AddSeconds(119)),"short startup delay allowed");
Check(!Schedule.IsDue(J(),now.AddSeconds(120))&&Schedule.IsMissed(J(),now.AddSeconds(120)),"stale jobs skipped");
var adjacent=J();adjacent.Start=now.AddHours(1);adjacent.End=now.AddHours(2);
Check(!Schedule.Overlap(J(),adjacent),"adjacent jobs allowed");adjacent.Start=now.AddMinutes(59);Check(Schedule.Overlap(J(),adjacent),"overlap rejected");
Check(Schedule.Validate(J(),[],now.AddMinutes(-1))==null,"valid job");
Check(Schedule.Validate(J(),[J()],now.AddMinutes(-1))!=null,"duplicate time rejected");
foreach(var bad in new[]{"http://telemost.yandex.ru/j/1","https://telemost.yandex.ru.evil.test/j/1","https://user@telemost.yandex.ru/j/1","https://telemost.yandex.ru/","https://telemost.yandex.ru:444/j/1"})Check(!Schedule.ValidUrl(bad),"reject bad URL: "+bad);
var dir=Path.Combine(Path.GetTempPath(),"planner-tests-"+Guid.NewGuid());Directory.CreateDirectory(dir);
try {
 var path=Path.Combine(dir,"jobs.json");var store=new JobStore(path);Check(store.Load().Count==0,"new schedule");
 var running=J();running.State=JobState.Running;store.Save([running]);Check(store.Load()[0].State==JobState.Interrupted,"running job not resumed blindly");
 File.WriteAllText(path,"broken");bool failed=false;try{store.Load();}catch(JsonException){failed=true;}Check(failed&&File.ReadAllText(path)=="broken","corrupt file not overwritten");
}finally{Directory.Delete(dir,true);}
Console.WriteLine($"All {count} tests passed.");
