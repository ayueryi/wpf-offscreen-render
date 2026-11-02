using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Data;
using Avalonia.Headless;
using Avalonia.Logging;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Themes.Fluent;
using Avalonia.VisualTree;

// Avalonia 11 / 12 宿主：Headless + Skia，用 RenderTargetBitmap 出图。
// 不用 CaptureRenderedFrame：它拍的是一块会留下历史脏区的帧缓冲，像素不稳定。
// 结果文件与 WPF 宿主同一套：snapshot.png、manifest.json、layout.json、binding-errors.json。
internal static class Program
{
    private const long MaxPixels = 60_000_000;

    private static int Main(string[] args)
    {
        var exitCode = Run(args);
        // 业务代码可能留下前台线程（轮询、设备监听），进程会因此无法退出而被判为超时；结果已写完，直接结束进程。
        Console.Out.Flush();
        Console.Error.Flush();
        Environment.Exit(exitCode);
        return exitCode;
    }

    private static int Run(string[] args)
    {
        string? Optional(string key)
        {
            var index = Array.IndexOf(args, key);
            return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
        }
        string Value(string key) => Optional(key) ?? throw new ArgumentException($"缺少参数 {key}");

        var outDir = Path.GetFullPath(Value("--out"));
        ConfiguredView.ConfigPath = Optional("--config");
        Directory.CreateDirectory(outDir);
        var exitCode = 1;
        try
        {
            if (args.Contains("--window-host"))
            {
                File.WriteAllText(Path.Combine(outDir, "error.txt"), "Avalonia 宿主本期不支持 windowHost；请使用默认 layout-only 模式。");
                exitCode = 1;
                WriteResults(outDir, null, new BindingLog(), exitCode);
                return exitCode;
            }
            if (StepsRequested(Optional("--config")))
            {
                File.WriteAllText(Path.Combine(outDir, "error.txt"),
                    "Avalonia 宿主本期不支持交互步骤（steps）。请去掉 steps 后再渲染，或改用 WPF 宿主。");
                exitCode = 3;
                WriteResults(outDir, null, new BindingLog(), exitCode);
                return exitCode;
            }

            AppBuilder.Configure<Application>()
                .UseSkia()
                .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false })
                .SetupWithoutStarting();
            var app = Application.Current ?? throw new InvalidOperationException("Avalonia Application 未创建。");
            app.Styles.Add(new FluentTheme());

            var marker = "AgentRenderSelfCheck_" + Guid.NewGuid().ToString("N");
            var log = new BindingLog();
            Logger.Sink = new BindingSink(marker, log);

            Probe(marker);
            var theme = Value("--theme");
            app.RequestedThemeVariant = theme == "dark" ? Avalonia.Styling.ThemeVariant.Dark : Avalonia.Styling.ThemeVariant.Light;

            var view = ViewFactory.Create(theme);
            var width = int.Parse(Value("--width"), CultureInfo.InvariantCulture);
            var height = int.Parse(Value("--height"), CultureInfo.InvariantCulture);
            var dpi = int.Parse(Value("--dpi"), CultureInfo.InvariantCulture);
            // 视图必须挂到（无头）窗口上：游离的控件不会应用 Application 样式，
            // 按钮、输入框等模板化控件会没有模板而渲染成空白。
            var window = HostInWindow(view, width, height);
            ViewFactory.WaitUntilReady(view);
            Settle(window);
            Control root = window is not null && ReferenceEquals(window, view) ? window : view;

            var (background, backgroundSource) = ResolveBackground(Optional("--background") ?? "auto", theme);
            var bitmap = RenderRoot(root, width, height, dpi, background);
            var pngPath = Path.Combine(outDir, "snapshot.png");
            bitmap.Save(pngPath);

            var (elementRect, elementError) = CaptureElement(root, Optional("--element"), dpi, background, outDir);
            var (layoutIssueCount, layoutReportError) = WriteLayoutReport(root, width, height, outDir);

            string sha256;
            using (var sha = SHA256.Create())
                sha256 = Convert.ToHexString(sha.ComputeHash(File.ReadAllBytes(pngPath))).ToLowerInvariant();

            var manifest = BuildManifest(Optional, view, theme, width, height, dpi, background, backgroundSource,
                log.SelfCheckHit, layoutIssueCount, layoutReportError, elementRect, elementError, sha256,
                dpi == 96 ? null : "Avalonia 无头窗口的 RenderScaling 固定为 1：布局与文本度量仍按 96 DPI 的 DIP 计算，请求的 DPI 只放大输出位图（矢量缩放），不等同于真实高 DPI 显示器上的布局。");
            exitCode = !log.SelfCheckHit ? 1 : log.Errors.Count > 0 ? 2 : 0;
            if (!log.SelfCheckHit)
                File.WriteAllText(Path.Combine(outDir, "error.txt"), "绑定监听自检未命中，不能宣称绑定检查通过。");
            try { ViewFactory.Cleanup(view); }
            catch (Exception ex) { File.AppendAllText(Path.Combine(outDir, "error.txt"), ex.ToString()); exitCode = 1; }
            WriteResults(outDir, manifest, log, exitCode);
        }
        catch (Exception ex)
        {
            File.WriteAllText(Path.Combine(outDir, "error.txt"), ex.ToString());
            exitCode = 1;
            WriteResults(outDir, null, new BindingLog(), exitCode);
        }
        return exitCode;
    }

    // 探针先于目标视图：绑一个不存在的属性，确认 ILogSink 能收到 Binding 区的 Warning。
    private static void Probe(string marker)
    {
        var probe = new TextBlock { DataContext = new object() };
        probe.Bind(TextBlock.TextProperty, new Binding(marker));
        probe.Measure(new Size(100, 30));
        probe.Arrange(new Rect(0, 0, 100, 30));
    }

    private static bool StepsRequested(string? configPath)
    {
        if (configPath is null || !File.Exists(configPath)) return false;
        var text = File.ReadAllText(configPath);
        return text.Contains("\"steps\"") && !text.Contains("\"steps\": null") && !text.Contains("\"steps\":null") && !text.Contains("\"steps\": []") && !text.Contains("\"steps\":[]");
    }

    // 把视图放进屏外的无头窗口；业务 Window 直接使用并设置视口尺寸。
    private static Window HostInWindow(Control view, int width, int height)
    {
        var window = view as Window ?? new Window { Content = view };
        // 不设置窗口装饰：无头窗口不绘制原生边框，且 11 的 SystemDecorations 在 12 已移除；
        // 实测设置与否输出逐字节一致，删掉即可让同一份源码同时编译 11 / 12。
        window.SizeToContent = SizeToContent.Manual;
        window.WindowState = WindowState.Normal;
        window.Width = width;
        window.Height = height;
        window.Show();
        Settle(window);
        return window;
    }

    // 处理排队的调度任务并完成一轮布局（相当于 WPF 宿主的 ContextIdle + UpdateLayout）。
    private static void Settle(Window window)
    {
        Avalonia.Threading.Dispatcher.UIThread.RunJobs();
        window.UpdateLayout();
        Avalonia.Threading.Dispatcher.UIThread.RunJobs();
    }

    // 游离的简单控件（只用于底色填充）的手动布局。
    private static void LayoutDetached(Control view, int width, int height)
    {
        view.Width = width;
        view.Height = height;
        view.Measure(new Size(width, height));
        view.Arrange(new Rect(0, 0, width, height));
    }

    private static RenderTargetBitmap RenderRoot(Control root, int width, int height, int dpi, IBrush? background)
    {
        var pixelWidth = (int)Math.Ceiling(width * dpi / 96.0);
        var pixelHeight = (int)Math.Ceiling(height * dpi / 96.0);
        var bitmap = new RenderTargetBitmap(new PixelSize(pixelWidth, pixelHeight), new Vector(dpi, dpi));
        if (background is not null)
        {
            var fill = new Border { Background = background, Width = width, Height = height };
            LayoutDetached(fill, width, height);
            bitmap.Render(fill);
        }
        bitmap.Render(root);
        return bitmap;
    }

    private static (double[]? Rect, string? Error) CaptureElement(Control root, string? name, int dpi, IBrush? background, string outDir)
    {
        if (name is null) return (null, null);
        var target = Descendants(root).FirstOrDefault(control => control.Name == name);
        if (target is null)
        {
            var names = string.Join(", ", Descendants(root).Select(control => control.Name).Where(item => item?.Length > 0).Distinct().Take(40));
            return (null, $"找不到 x:Name 为 {name} 的可见元素。可用名称：{names}");
        }
        var size = target.Bounds;
        var origin = target.TranslatePoint(new Point(0, 0), root) ?? new Point(0, 0);
        var rect = new[] { Math.Round(origin.X, 1), Math.Round(origin.Y, 1), Math.Round(size.Width, 1), Math.Round(size.Height, 1) };
        var pixelWidth = Math.Max(1, (int)Math.Ceiling(size.Width * dpi / 96.0));
        var pixelHeight = Math.Max(1, (int)Math.Ceiling(size.Height * dpi / 96.0));
        if ((long)pixelWidth * pixelHeight > MaxPixels)
            return (rect, $"元素 {name} 为 {pixelWidth}×{pixelHeight} 像素，超过 {MaxPixels / 1_000_000} 百万像素上限，未生成 element.png。");
        using var bitmap = new RenderTargetBitmap(new PixelSize(pixelWidth, pixelHeight), new Vector(dpi, dpi));
        bitmap.Render(target);
        bitmap.Save(Path.Combine(outDir, "element.png"));
        return (rect, null);
    }

    private static (int? Count, string? Error) WriteLayoutReport(Control root, int width, int height, string outDir)
    {
        try
        {
            var (report, count) = LayoutReport.Inspect(root, width, height);
            File.WriteAllText(Path.Combine(outDir, "layout.json"), Json.Write(report));
            return (count, null);
        }
        catch (Exception ex) { return (null, ex.GetType().Name + ": " + ex.Message); }
    }

    private static List<KeyValuePair<string, object?>> BuildManifest(Func<string, string?> optional, Control view,
        string theme, int width, int height, int dpi, IBrush? background, string backgroundSource,
        bool selfCheckHit, int? layoutIssueCount, string? layoutReportError, double[]? elementRect, string? elementError,
        string sha256, string? warning) =>
    [
        new("stack", "avalonia"),
        new("generatedAt", DateTime.UtcNow.ToString("O")),
        new("toolVersion", optional("--tool-version")),
        new("mode", "layout-only"),
        new("sourceViewType", view.GetType().FullName),
        new("theme", theme),
        new("widthDip", width), new("heightDip", height),
        new("pixelWidth", (int)Math.Ceiling(width * dpi / 96.0)), new("pixelHeight", (int)Math.Ceiling(height * dpi / 96.0)), new("dpi", dpi),
        new("actualWidthDip", view.Bounds.Width), new("actualHeightDip", view.Bounds.Height),
        new("background", background?.ToString() ?? "transparent"), new("backgroundSource", backgroundSource),
        new("bindingTraceVerified", selfCheckHit),
        new("layoutIssueCount", layoutIssueCount),
        new("layoutReportError", layoutReportError),
        new("element", optional("--element")),
        new("elementRectDip", elementRect),
        new("elementImage", optional("--element") is null || elementError is not null ? null : "element.png"),
        new("elementError", elementError),
        new("image", "snapshot.png"),
        new("sha256", sha256),
        new("targetFramework", typeof(Program).Assembly.GetCustomAttribute<TargetFrameworkAttribute>()?.FrameworkName),
        new("runtime", RuntimeInformation.FrameworkDescription),
        new("processArchitecture", RuntimeInformation.ProcessArchitecture.ToString()),
        new("machineName", Environment.MachineName),
        new("warning", warning),
        new("note", "Avalonia headless snapshot; native windows, input, and performance require separate verification.")
    ];

    private static void WriteResults(string outDir, List<KeyValuePair<string, object?>>? manifest, BindingLog log, int exitCode)
    {
        File.WriteAllLines(Path.Combine(outDir, "binding-errors.txt"), log.Errors);
        File.WriteAllText(Path.Combine(outDir, "binding-errors.json"), Json.Write(log.Errors.Select(BindingIssues.Describe).ToList()));
        if (manifest is not null)
        {
            manifest.Add(new("bindingWarningOrErrorCount", log.Errors.Count));
            manifest.Add(new("exitCode", exitCode));
            File.WriteAllText(Path.Combine(outDir, "manifest.json"), Json.Write(manifest));
        }
        Console.WriteLine($"{outDir} (exit={exitCode})");
    }

    private static (IBrush? Brush, string Source) ResolveBackground(string value, string theme)
    {
        if (value.Equals("transparent", StringComparison.OrdinalIgnoreCase)) return (null, "transparent");
        if (value.Equals("auto", StringComparison.OrdinalIgnoreCase))
            return (theme == "dark" ? new SolidColorBrush(Color.Parse("#1E1E1E")) : Brushes.White, "theme-fallback");
        return (new SolidColorBrush(Color.Parse(value)), "explicit");
    }

    private static IEnumerable<Control> Descendants(Control root)
    {
        // 视觉树（含模板生成的元素），与布局报告一致。
        yield return root;
        foreach (var control in root.GetVisualDescendants().OfType<Control>())
            if (control.IsVisible) yield return control;
    }

    private sealed class BindingLog
    {
        public List<string> Errors { get; } = new();
        public bool SelfCheckHit { get; set; }
    }

    // Avalonia 没有 WPF 的 PresentationTraceSources。绑定错误走 Logger，探针用唯一路径标记自检。
    private sealed class BindingSink(string marker, BindingLog log) : ILogSink
    {
        private readonly HashSet<string> seen = new(StringComparer.Ordinal);

        public bool IsEnabled(LogEventLevel level, string area) => area == LogArea.Binding && level >= LogEventLevel.Warning;

        public void Log(LogEventLevel level, string area, object? source, string messageTemplate) => Record(messageTemplate);

        public void Log(LogEventLevel level, string area, object? source, string messageTemplate, params object?[] propertyValues)
        {
            var text = messageTemplate;
            foreach (var value in propertyValues)
                text = ReplaceFirst(text, value?.ToString() ?? "null");
            Record(text);
        }

        private void Record(string message)
        {
            if (message.Contains(marker, StringComparison.Ordinal)) { log.SelfCheckHit = true; return; }
            if (seen.Add(message)) log.Errors.Add(message);
        }

        // 模板里的占位符按顺序换成实参，保留一行可读的原因。
        private static string ReplaceFirst(string template, string value)
        {
            var start = template.IndexOf('{');
            var end = start < 0 ? -1 : template.IndexOf('}', start);
            return start < 0 || end < 0 ? template : template.Substring(0, start) + value + template.Substring(end + 1);
        }
    }
}
