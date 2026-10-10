using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using WpfRenderMcp;

// 仓库根目录（含 scripts/、tests/）：由启动器以 --root 传入，也可用环境变量 WPF_RENDER_ROOT 指定。
var rootIndex = Array.IndexOf(args, "--root");
var root = rootIndex >= 0 && rootIndex + 1 < args.Length ? args[rootIndex + 1] : Environment.GetEnvironmentVariable("WPF_RENDER_ROOT");
if (string.IsNullOrEmpty(root) || !File.Exists(Path.Combine(root, "scripts", "render.ps1")))
{
    Console.Error.WriteLine("未找到 wpf-offscreen-render 根目录：请通过 --root 或 WPF_RENDER_ROOT 指定包含 scripts/render.ps1 的目录。");
    return 2;
}

var builder = Host.CreateApplicationBuilder(args);
// stdout 专用于 MCP 协议，日志全部写到 stderr。
builder.Logging.ClearProviders();
builder.Logging.AddConsole(options => options.LogToStandardErrorThreshold = LogLevel.Trace);
builder.Logging.SetMinimumLevel(LogLevel.Warning);
builder.Services.AddSingleton(new ScriptRunner(Path.GetFullPath(root)));
builder.Services
    .AddMcpServer(options => options.ServerInfo = new() { Name = "wpf-offscreen-render", Version = typeof(ScriptRunner).Assembly.GetName().Version?.ToString(3) ?? "0.0.0" })
    .WithStdioServerTransport()
    .WithToolsFromAssembly();
await builder.Build().RunAsync();
return 0;
