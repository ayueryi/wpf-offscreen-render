using System.Text.Json.Nodes;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;

// 用法：dotnet run --project mcp/WpfRenderMcp.Tests -- --root <仓库根目录> [--sample <SampleViews.dll>]
// 经 mcp/start.ps1 启动服务器（与代理的 MCP 配置相同），逐项调用工具并断言结果。
string? Option(string name)
{
    var index = Array.IndexOf(args, name);
    return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
}
var root = Path.GetFullPath(Option("--root") ?? throw new ArgumentException("缺少 --root"));
var sample = Option("--sample");
var failures = new List<string>();
var passed = 0;

void Check(string name, bool condition, string detail = "")
{
    if (condition) { passed++; Console.WriteLine($"PASS {name}"); }
    else { failures.Add(name); Console.WriteLine($"FAIL {name} {detail}"); }
}

static string Texts(CallToolResult result) => string.Join("\n", result.Content.OfType<TextContentBlock>().Select(block => block.Text));
static int Images(CallToolResult result) => result.Content.OfType<ImageContentBlock>().Count();
// 第一个文本块是 JSON 摘要。
static JsonNode? Json(CallToolResult result) =>
    result.Content.OfType<TextContentBlock>().FirstOrDefault() is { } block && block.Text.TrimStart().StartsWith('{') ? JsonNode.Parse(block.Text) : null;

// 使用 Claude Code 插件清单中的真实启动命令（${CLAUDE_PLUGIN_ROOT} 替换为仓库根目录），确保测试覆盖用户实际执行的命令行。
var server = JsonNode.Parse(File.ReadAllText(Path.Combine(root, ".claude-plugin", "plugin.json")))!["mcpServers"]!["wpf-offscreen-render"]!;
await using var client = await McpClient.CreateAsync(new StdioClientTransport(new StdioClientTransportOptions
{
    Name = "wpf-offscreen-render",
    Command = server["command"]!.GetValue<string>(),
    Arguments = server["args"]!.AsArray().Select(arg => arg!.GetValue<string>().Replace("${CLAUDE_PLUGIN_ROOT}", root)).ToList(),
}));

var toolList = await client.ListToolsAsync();
var tools = toolList.Select(tool => tool.Name).OrderBy(name => name).ToArray();
Check("tools/list", tools.SequenceEqual(new[] { "compare_snapshots", "get_layout", "list_views", "render_matrix", "render_view", "self_test" }), string.Join(",", tools));
// 会构建、运行业务代码或写文件的工具不能声明只读，否则客户端可能据此自动批准。
var readOnly = toolList.Where(tool => tool.ProtocolTool.Annotations?.ReadOnlyHint == true).Select(tool => tool.Name).OrderBy(name => name).ToArray();
Check("只有查询类工具声明只读", readOnly.SequenceEqual(new[] { "get_layout", "list_views" }), string.Join(",", readOnly));

async Task<CallToolResult> Call(string tool, Dictionary<string, object?> arguments) =>
    await client.CallToolAsync(tool, arguments);

var missing = await Call("get_layout", new() { ["outDir"] = Path.Combine(root, "no-such-render") });
Check("get_layout 缺少目录时报错", missing.IsError == true && Texts(missing).Contains("layout.json"), Texts(missing));

var presetDir = Directory.CreateTempSubdirectory("wpf-render-preset-").FullName;
File.WriteAllText(Path.Combine(presetDir, "wpf-render.json"), """
    { "verifyOnStop": true,
      // 注释与尾逗号：与脚本使用的 ConvertFrom-Json 一样可以解析
      "defaults": { "assemblyPaths": ["bin/App.dll"], "themes": ["light", "dark"], },
      "views": { "Order": { "viewType": "App.OrderView", "watch": ["src/Order/**"] }, "Login": { "xaml": "probe.xaml" } } }
    """);
var views = Json(await Call("list_views", new() { ["config"] = presetDir }));
var names = (views?["views"] as JsonArray)?.Select(view => view?["name"]?.GetValue<string>()).OrderBy(name => name).ToArray() ?? [];
Check("list_views 列出预设并合并 defaults", names.SequenceEqual(new[] { "Login", "Order" })
    && (views?["views"] as JsonArray)?.First(view => view?["name"]?.GetValue<string>() == "Login")?["themes"]?.AsArray().Count == 2, views?.ToJsonString() ?? "");
Directory.Delete(presetDir, recursive: true);

if (!OperatingSystem.IsWindows())
{
    var refused = await Call("render_view", new());
    Check("非 Windows 时 render_view 明确拒绝", refused.IsError == true && Texts(refused).Contains("Windows"), Texts(refused));
}
else
{
    var basic = await Call("render_view", new() { ["width"] = 640, ["height"] = 360 });
    Check("render_view 内置样例：ok 且带截图", basic.IsError != true && Json(basic)?["status"]?.GetValue<string>() == "ok" && Images(basic) == 1, Texts(basic));

    if (sample is not null)
    {
        var problems = await Call("render_view", new()
        {
            ["assemblyPaths"] = new[] { sample }, ["viewType"] = "SampleViews.LayoutProblemsView", ["element"] = "ClippedButton", ["dpi"] = 144,
        });
        var summary = Json(problems);
        Check("render_view 业务视图：布局问题 5 条，截图与元素截图各一", problems.IsError != true
            && summary?["layoutIssueCount"]?.GetValue<int>() == 5 && Images(problems) == 2, Texts(problems));

        var outDir = summary?["outDir"]?.GetValue<string>() ?? "";
        var layout = Json(await Call("get_layout", new() { ["outDir"] = outDir, ["element"] = "ClippedButton", ["kind"] = "overlap" }));
        Check("get_layout 按元素与类型筛选", layout?["issueCount"]?.GetValue<int>() == 1 && (layout?["matchedNodes"] as JsonArray)?.Count > 0, layout?.ToJsonString() ?? "");

        var broken = await Call("render_view", new()
        {
            ["assemblyPaths"] = new[] { sample }, ["viewType"] = "SampleViews.BrokenBindingView", ["dataContextType"] = "SampleViews.OrderPreviewVm",
        });
        Check("render_view 绑定错误：binding-issues 且给出结论", broken.IsError != true
            && Json(broken)?["status"]?.GetValue<string>() == "binding-issues" && Texts(broken).Contains("Path=CustomerNmae"), Texts(broken));
    }

    var matrix = await Call("render_matrix", new() { ["themes"] = new[] { "light", "dark" }, ["sizes"] = new[] { "640x360" } });
    var matrixJson = Json(matrix);
    Check("render_matrix：两个组合与总览图", matrix.IsError != true && matrixJson?["rendered"]?.GetValue<int>() == 2 && Images(matrix) == 1, Texts(matrix));

    var results = matrixJson?["results"] as JsonArray;
    if (results is { Count: 2 })
    {
        var compare = await Call("compare_snapshots", new() { ["before"] = results[0]!["outDir"]!.GetValue<string>(), ["after"] = results[1]!["outDir"]!.GetValue<string>() });
        var comparison = Json(compare);
        Check("compare_snapshots：明暗主题判为不同并附差异图", comparison?["status"]?.GetValue<string>() == "different"
            && Texts(compare).Contains("theme: light -> dark") && Images(compare) == 1, Texts(compare));
    }

    var selfTest = await Call("self_test", new());
    Check("self_test 通过", selfTest.IsError != true && Texts(selfTest).Contains("0 失败"), Texts(selfTest));
}

// Codex 的启动方式：codex.mcp.json 中的相对脚本路径 + 以插件目录为工作目录。此时相对路径参数应明确报错。
var codexServer = JsonNode.Parse(File.ReadAllText(Path.Combine(root, "codex.mcp.json")))!["mcpServers"]!["wpf-offscreen-render"]!;
await using (var codexClient = await McpClient.CreateAsync(new StdioClientTransport(new StdioClientTransportOptions
{
    Name = "wpf-offscreen-render-codex",
    Command = codexServer["command"]!.GetValue<string>(),
    Arguments = codexServer["args"]!.AsArray().Select(arg => arg!.GetValue<string>()).ToList(),
    WorkingDirectory = Path.GetFullPath(Path.Combine(root, codexServer["cwd"]!.GetValue<string>())),
})))
{
    var codexTools = await codexClient.ListToolsAsync();
    Check("Codex 启动方式：tools/list", codexTools.Count == 6, string.Join(",", codexTools.Select(tool => tool.Name)));
    var relative = await codexClient.CallToolAsync("list_views", new Dictionary<string, object?> { ["config"] = "." });
    Check("Codex 启动方式：相对路径明确报错", relative.IsError == true && Texts(relative).Contains("绝对路径"), Texts(relative));
}

Console.WriteLine($"{passed} 通过，{failures.Count} 失败");
return failures.Count == 0 ? 0 : 1;
