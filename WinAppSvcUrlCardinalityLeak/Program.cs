using System.Diagnostics;

var buildTime = File.GetLastWriteTimeUtc(typeof(Program).Assembly.Location);

var app = WebApplication.Create(args);

app.MapGet("/", (HttpContext ctx) =>
{
    var mb = Process.GetCurrentProcess().PrivateMemorySize64 / (1024 * 1024);
    ctx.Response.Headers["X-Private-Bytes-MB"] = mb.ToString();
    var crashMonitoring = Environment.GetEnvironmentVariable("WEBSITE_CRASHMONITORING_SETTINGS");
    var crashMonitoringHtml = crashMonitoring is not null
        ? $"<p>WEBSITE_CRASHMONITORING_SETTINGS: {System.Net.WebUtility.HtmlEncode(crashMonitoring)}</p>"
        : "";
    var leakTrackModule = Process.GetCurrentProcess().Modules
        .Cast<System.Diagnostics.ProcessModule>()
        .FirstOrDefault(m => m.ModuleName.Contains("LeakTrack", StringComparison.OrdinalIgnoreCase));
    var leakTrackHtml = leakTrackModule is not null
        ? $"<p>LeakTrack: loaded ({System.Net.WebUtility.HtmlEncode(leakTrackModule.FileName)})</p>"
        : "<p>LeakTrack: NOT loaded</p>";
    return Results.Content(
        $"<html><body><p>WinAppSvcUrlCardinalityLeak (built {buildTime:yyyy-MM-dd HH:mm:ss} UTC)</p><p>Private Bytes: {mb:N0} MB</p>{crashMonitoringHtml}{leakTrackHtml}</body></html>",
        "text/html");
});

app.MapGet("/echo", (string echo) => Results.Ok(echo));

app.MapGet("/{*path}", () => Results.Ok());

app.Run();
