using System.Diagnostics;

var buildTime = File.GetLastWriteTimeUtc(typeof(Program).Assembly.Location);

var app = WebApplication.Create(args);

app.MapGet("/", (HttpContext ctx) =>
{
    var mb = Process.GetCurrentProcess().PrivateMemorySize64 / (1024 * 1024);
    ctx.Response.Headers["X-Private-Bytes-MB"] = mb.ToString();
    return Results.Content(
        $"<html><body><p>WinAppSvcUrlCardinalityLeak (built {buildTime:yyyy-MM-dd HH:mm:ss} UTC)</p><p>Private Bytes: {mb:N0} MB</p></body></html>",
        "text/html");
});

app.MapGet("/echo", (string echo) => Results.Ok(echo));

app.MapGet("/{*path}", () => Results.Ok());

app.Run();
