using System.ComponentModel;
using System.Text.Json;
using System.Text.Json.Nodes;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace WpfRenderMcp;

[McpServerToolType]
public sealed class RenderTools(ScriptRunner runner)
{
    // 超过这个尺寸的图片只返回路径，避免撑满代理上下文。
    private const int MaxImageBytes = 1_500_000;
    private const int MaxImageSide = 2400;
    private static readonly JsonSerializerOptions Indented = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    [McpServerTool(Name = "render_view", Title = "Render WPF view", ReadOnly = true, OpenWorld = false)]
    [Description("在独立临时进程中把真实 WPF UserControl / Page / Window 或松散 XAML 离屏渲染成 PNG（需要 Windows）。"
        + "返回 JSON 摘要（status、bindingIssues 单行绑定结论、layoutIssues 布局问题、尺寸、outDir）和截图。"
        + "业务项目有 wpf-render.json 时优先用 config + preset（先用 list_views 查看可用视图），build=true 会先构建业务项目；"
        + "否则传 assemblyPaths + viewType / xaml。都不传时渲染内置样例。同一组程序集第二次起跳过宿主构建。")]
    public async Task<CallToolResult> RenderView(
        [Description("wpf-render.json 的绝对路径或其所在目录（业务项目根目录）")] string? config = null,
        [Description("wpf-render.json 中的视图名；其余参数省略时取预设值，显式传入时覆盖")] string? preset = null,
        [Description("渲染前在配置目录执行预设的 build 命令（修改了业务代码时使用）")] bool build = false,
        [Description("业务程序集（.dll / .NET Framework .exe）绝对路径；TFM 与位数据此自动推断")] string[]? assemblyPaths = null,
        [Description("视图类型全名，如 MyUi.Views.OrderView；需无参构造。与 xaml 二选一")] string? viewType = null,
        [Description("松散 XAML 文件路径（无 x:Class / 事件），与 viewType 二选一")] string? xaml = null,
        [Description("DataContext 类型全名，需无参构造")] string? dataContextType = null,
        [Description("创建 DataContext 的无参静态方法 Namespace.Type.Method，与 dataContextType 二选一")] string? dataContextFactory = null,
        [Description("替换宿主 ViewFactory.cs 的文件（需要构造参数、stub 服务或等待异步就绪时）")] string? factoryFile = null,
        [Description("按顺序合并的资源字典（pack URI 或绝对路径），{theme} 替换为主题")] string[]? resourceDictionaries = null,
        [Description("light 或 dark，默认 light")] string? theme = null,
        [Description("视口宽度（DIP），默认 1280")] int? width = null,
        [Description("视口高度（DIP），默认 800")] int? height = null,
        [Description("输出 DPI，默认 96")] int? dpi = null,
        [Description("PNG 衬底：auto / transparent / #RRGGBB")] string? background = null,
        [Description("用屏外窗口承载（依赖 Loaded、窗口祖先或实际承载尺寸的页面）")] bool? windowHost = null,
        [Description("另存该 x:Name 元素的截图")] string? element = null,
        [Description("显式宿主 TFM，如 net48 / net8.0-windows；省略时自动推断")] string? targetFramework = null,
        [Description("显式位数 AnyCPU / x86 / x64 / ARM64；省略时自动推断")] string? platform = null,
        [Description("是否在结果中附带截图")] bool includeImage = true,
        CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsWindows()) return WindowsOnly();
        var arguments = ViewArguments(assemblyPaths, viewType, xaml, dataContextType, resourceDictionaries, targetFramework, platform);
        arguments["Config"] = config;
        arguments["Preset"] = preset;
        arguments["Build"] = build ? true : null;
        arguments["DataContextFactory"] = dataContextFactory;
        arguments["FactoryFile"] = factoryFile;
        arguments["Theme"] = theme is null ? null : new[] { theme };
        arguments["Width"] = width;
        arguments["Height"] = height;
        arguments["Dpi"] = dpi is null ? null : new[] { dpi.Value };
        arguments["Background"] = background;
        arguments["WindowHost"] = windowHost;
        arguments["Element"] = element;
        var result = await runner.RunAsync(Path.Combine("scripts", "render.ps1"), arguments, TimeSpan.FromMinutes(20), cancellationToken);
        if (LastOutput(result) is not { } outDir) return ScriptFailure(result);
        // 预设可能配置了多个主题 / 尺寸 / DPI，此时得到的是汇总目录。
        if (ReadJson(Path.Combine(outDir, "matrix.json")) is { } matrix)
        {
            var matrixContent = new List<ContentBlock> { Text(matrix) };
            if (includeImage) AddImage(matrixContent, matrix["overview"]?.GetValue<string>(), "总览图");
            return new CallToolResult { Content = matrixContent, IsError = matrix["status"]?.GetValue<string>() == "failed" };
        }
        if (ReadJson(Path.Combine(outDir, "summary.json")) is not { } summary) return ScriptFailure(result);

        var content = new List<ContentBlock> { Text(summary) };
        if (includeImage)
        {
            AddImage(content, summary["snapshot"]?.GetValue<string>(), "截图");
            AddImage(content, summary["elementSnapshot"]?.GetValue<string>(), "元素截图");
        }
        return new CallToolResult { Content = content, IsError = IsFailed(summary) };
    }

    [McpServerTool(Name = "list_views", Title = "List WPF render presets", ReadOnly = true, Idempotent = true, OpenWorld = false)]
    [Description("列出业务项目 wpf-render.json 中配置的视图（名称、视图类型、主题 / 尺寸、watch 文件模式），供 render_view 的 preset 参数使用。")]
    public CallToolResult ListViews([Description("wpf-render.json 的绝对路径或其所在目录")] string config)
    {
        var path = Directory.Exists(config) ? Path.Combine(config, "wpf-render.json") : config;
        if (ReadJson(path) is not { } file) return Error($"找不到或无法解析 {path}。");
        var defaults = file["defaults"] as JsonObject;
        var views = new JsonArray();
        foreach (var (name, value) in file["views"] as JsonObject ?? [])
        {
            JsonNode? Setting(string key) => (value?[key] ?? defaults?[key])?.DeepClone();
            views.Add(new JsonObject
            {
                ["name"] = name,
                ["viewType"] = Setting("viewType"),
                ["xaml"] = Setting("xaml"),
                ["themes"] = Setting("themes"),
                ["sizes"] = Setting("sizes"),
                ["watch"] = Setting("watch"),
                ["hasBuild"] = Setting("build") is not null,
            });
        }
        return new CallToolResult { Content = [Text(new JsonObject { ["config"] = Path.GetFullPath(path), ["verifyOnStop"] = file["verifyOnStop"]?.DeepClone(), ["views"] = views })] };
    }

    [McpServerTool(Name = "render_matrix", Title = "Render WPF view matrix", ReadOnly = true, OpenWorld = false)]
    [Description("一次渲染多个主题 × 尺寸 × DPI 组合（需要 Windows），只构建一次。返回 matrix JSON（每个组合的状态、绑定与布局问题、截图路径）和拼好的总览图。")]
    public async Task<CallToolResult> RenderMatrix(
        [Description("业务程序集绝对路径")] string[]? assemblyPaths = null,
        [Description("视图类型全名，与 xaml 二选一")] string? viewType = null,
        [Description("松散 XAML 文件路径")] string? xaml = null,
        [Description("DataContext 类型全名")] string? dataContextType = null,
        [Description("按顺序合并的资源字典，{theme} 替换为主题")] string[]? resourceDictionaries = null,
        [Description("主题列表，如 [\"light\",\"dark\"]")] string[]? themes = null,
        [Description("视口尺寸列表，如 [\"1280x800\",\"800x600\"]")] string[]? sizes = null,
        [Description("DPI 列表，如 [96,144]")] int[]? dpis = null,
        [Description("PNG 衬底")] string background = "auto",
        [Description("用屏外窗口承载")] bool windowHost = false,
        [Description("显式宿主 TFM")] string? targetFramework = null,
        [Description("显式位数")] string? platform = null,
        [Description("是否在结果中附带总览图")] bool includeImage = true,
        CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsWindows()) return WindowsOnly();
        var arguments = ViewArguments(assemblyPaths, viewType, xaml, dataContextType, resourceDictionaries, targetFramework, platform);
        arguments["Theme"] = themes is { Length: > 0 } ? themes : new[] { "light", "dark" };
        arguments["Size"] = sizes is { Length: > 0 } ? sizes : null;
        arguments["Dpi"] = dpis is { Length: > 0 } ? dpis : new[] { 96 };
        arguments["Background"] = background;
        arguments["WindowHost"] = windowHost;
        var result = await runner.RunAsync(Path.Combine("scripts", "render.ps1"), arguments, TimeSpan.FromMinutes(30), cancellationToken);
        if (LastOutput(result) is not { } outDir) return ScriptFailure(result);

        // 只有一个组合时 render.ps1 返回普通渲染目录。
        if (ReadJson(Path.Combine(outDir, "matrix.json")) is { } matrix)
        {
            var content = new List<ContentBlock> { Text(matrix) };
            if (includeImage) AddImage(content, matrix["overview"]?.GetValue<string>(), "总览图");
            return new CallToolResult { Content = content, IsError = matrix["status"]?.GetValue<string>() == "failed" };
        }
        if (ReadJson(Path.Combine(outDir, "summary.json")) is { } summary)
        {
            var content = new List<ContentBlock> { Text(summary) };
            if (includeImage) AddImage(content, summary["snapshot"]?.GetValue<string>(), "截图");
            return new CallToolResult { Content = content, IsError = IsFailed(summary) };
        }
        return ScriptFailure(result);
    }

    [McpServerTool(Name = "compare_snapshots", Title = "Compare WPF snapshots", ReadOnly = true, OpenWorld = false)]
    [Description("比较前后两次渲染（需要 Windows）：返回 status（same / different）、变化像素占比、变化区域（像素与 DIP，可对照 get_layout）、"
        + "两次渲染的环境差异，以及差异图（变化像素标红）。before / after 为 render_view 返回的 outDir 或 snapshot.png 路径。")]
    public async Task<CallToolResult> CompareSnapshots(
        [Description("修改前的渲染输出目录或 snapshot.png")] string before,
        [Description("修改后的渲染输出目录或 snapshot.png")] string after,
        [Description("单个颜色通道差值不超过该值视为相同，0–255")] int tolerance = 0,
        [Description("是否在结果中附带差异图")] bool includeImage = true,
        CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsWindows()) return WindowsOnly();
        var arguments = new Dictionary<string, object?> { ["Before"] = before, ["After"] = after, ["Tolerance"] = tolerance };
        var result = await runner.RunAsync(Path.Combine("scripts", "compare-snapshots.ps1"), arguments, TimeSpan.FromMinutes(5), cancellationToken);
        JsonNode? comparison = null;
        if (result.Error is null && result.Output.Length > 0)
        {
            try { comparison = JsonNode.Parse(string.Join("\n", result.Output)); } catch (JsonException) { }
        }
        if (comparison is null) return ScriptFailure(result);
        var content = new List<ContentBlock> { Text(comparison) };
        if (includeImage && comparison["status"]?.GetValue<string>() == "different") AddImage(content, comparison["diff"]?.GetValue<string>(), "差异图");
        return new CallToolResult { Content = content };
    }

    [McpServerTool(Name = "get_layout", Title = "Query WPF layout", ReadOnly = true, Idempotent = true, OpenWorld = false)]
    [Description("读取一次渲染的 layout.json 并筛选：布局问题（可按 kind 过滤），以及名称或文本匹配 element 的元素及其子树（DIP 坐标 [x,y,w,h]，相对根元素）。"
        + "用于定位 layoutIssues 或 compare_snapshots 变化区域对应的元素，不必读取整个视觉树。")]
    public CallToolResult GetLayout(
        [Description("render_view 返回的 outDir")] string outDir,
        [Description("按 x:Name 精确匹配或按文本包含匹配的元素；返回其子树")] string? element = null,
        [Description("只返回该类型的布局问题：text-truncated / clipped / overlap / zero-size / out-of-viewport")] string? kind = null,
        [Description("最多返回的节点数")] int maxNodes = 200)
    {
        var layout = ReadJson(Path.Combine(outDir, "layout.json"));
        if (layout is null) return Error($"找不到 {Path.Combine(outDir, "layout.json")}（渲染是否成功？）");
        var issues = (layout["issues"] as JsonArray ?? [])
            .Where(issue => kind is null || issue?["kind"]?.GetValue<string>() == kind)
            .Select(issue => issue?.DeepClone()).ToList();
        var nodes = layout["nodes"] as JsonArray ?? [];
        var selected = new JsonArray();
        if (element is not null)
        {
            for (var i = 0; i < nodes.Count && selected.Count < maxNodes; i++)
            {
                var node = nodes[i]!;
                var name = node["name"]?.GetValue<string>();
                var text = node["text"]?.GetValue<string>();
                if (name != element && (text is null || !text.Contains(element, StringComparison.OrdinalIgnoreCase))) continue;
                // 节点按深度优先排列：之后深度更大的连续节点属于其子树。
                var depth = node["depth"]!.GetValue<int>();
                selected.Add(node.DeepClone());
                for (var j = i + 1; j < nodes.Count && nodes[j]!["depth"]!.GetValue<int>() > depth && selected.Count < maxNodes; j++)
                    selected.Add(nodes[j]!.DeepClone());
                break;
            }
        }
        var response = new JsonObject
        {
            ["viewport"] = layout["viewport"]?.DeepClone(),
            ["nodeCount"] = layout["nodeCount"]?.DeepClone(),
            ["issueCount"] = issues.Count,
            ["issues"] = new JsonArray(issues.ToArray()),
            ["element"] = element,
            ["matchedNodes"] = element is null ? null : selected,
        };
        if (element is not null && selected.Count == 0) response["note"] = $"没有名称为 {element} 或文本包含它的可见元素。";
        return new CallToolResult { Content = [Text(response)] };
    }

    [McpServerTool(Name = "self_test", Title = "Self-test WPF rendering environment", ReadOnly = true, OpenWorld = false)]
    [Description("运行环境自检（tests/run-tests.ps1 -Quick，需要 Windows）：构建两个宿主并渲染内置样例与松散 XAML，确认 .NET SDK、WindowsDesktop 运行时与 PowerShell 可用。首次使用或渲染异常怀疑环境问题时调用。")]
    public async Task<CallToolResult> SelfTest(CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsWindows()) return WindowsOnly();
        var result = await runner.RunAsync(Path.Combine("tests", "run-tests.ps1"), new() { ["Quick"] = true }, TimeSpan.FromMinutes(10), cancellationToken, captureHost: true);
        var text = string.Join("\n", result.Output.Where(line => !string.IsNullOrWhiteSpace(line)));
        if (result.Error is not null) text += $"\n错误：{result.Error}";
        return new CallToolResult { Content = [new TextContentBlock { Text = text }], IsError = result.ExitCode != 0 };
    }

    private static Dictionary<string, object?> ViewArguments(string[]? assemblyPaths, string? viewType, string? xaml, string? dataContextType,
        string[]? resourceDictionaries, string? targetFramework, string? platform) => new()
    {
        ["AssemblyPath"] = assemblyPaths is { Length: > 0 } ? assemblyPaths : null,
        ["ViewType"] = viewType,
        ["Xaml"] = xaml,
        ["DataContextType"] = dataContextType,
        ["ResourceDictionary"] = resourceDictionaries is { Length: > 0 } ? resourceDictionaries : null,
        ["TargetFramework"] = targetFramework,
        ["Platform"] = platform,
    };

    private static string? LastOutput(ScriptRunner.Result result) =>
        result.Error is null ? result.Output.LastOrDefault(line => !string.IsNullOrWhiteSpace(line))?.Trim() : null;

    private static JsonNode? ReadJson(string path)
    {
        if (!File.Exists(path)) return null;
        try { return JsonNode.Parse(File.ReadAllText(path)); }
        catch (JsonException) { return null; }
    }

    private static bool IsFailed(JsonNode summary) => summary["status"]?.GetValue<string>()?.StartsWith("failed", StringComparison.Ordinal) == true;

    private static TextContentBlock Text(JsonNode node) => new() { Text = node.ToJsonString(Indented) };

    // 图片过大时只给出路径，代理可按需用自己的图片工具打开。
    private static void AddImage(List<ContentBlock> content, string? path, string label)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return;
        var bytes = File.ReadAllBytes(path);
        var (width, height) = PngSize(bytes);
        if (bytes.Length > MaxImageBytes || Math.Max(width, height) > MaxImageSide)
        {
            content.Add(new TextContentBlock { Text = $"{label}过大（{width}×{height}，{bytes.Length / 1024} KB），未内联：{path}" });
            return;
        }
        content.Add(new TextContentBlock { Text = $"{label}：{path}" });
        content.Add(ImageContentBlock.FromBytes(bytes, "image/png"));
    }

    private static (int Width, int Height) PngSize(byte[] bytes) => bytes.Length < 24 ? (0, 0)
        : ((bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19], (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23]);

    private static CallToolResult ScriptFailure(ScriptRunner.Result result)
    {
        var lines = new List<string> { $"脚本执行失败（退出码 {result.ExitCode}）。" };
        if (result.Error is not null) lines.Add("错误：" + result.Error);
        if (result.Output.Length > 0) lines.Add("输出：" + string.Join("\n", result.Output.TakeLast(20)));
        if (!string.IsNullOrWhiteSpace(result.StandardError)) lines.Add("stderr：" + string.Join("\n", result.StandardError.Trim().Split('\n').TakeLast(20)));
        return Error(string.Join("\n", lines));
    }

    private static CallToolResult WindowsOnly() =>
        Error("WPF 渲染只能在 Windows 上运行；当前 MCP 服务器运行在 " + System.Runtime.InteropServices.RuntimeInformation.OSDescription + "。");

    private static CallToolResult Error(string message) => new() { Content = [new TextContentBlock { Text = message }], IsError = true };
}
