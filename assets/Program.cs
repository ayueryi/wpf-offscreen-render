using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

// 只使用 .NET Framework 4.7.2 与 .NET 5+ 共有的 API，同一份源码适配全部受支持的 TFM。
internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
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
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var exitCode = 1;
        app.DispatcherUnhandledException += (_, e) =>
        {
            exitCode = 1;
            File.WriteAllText(Path.Combine(outDir, "error.txt"), e.Exception.ToString());
            e.Handled = true;
            // 只停止消息循环，不走 Application.Shutdown：它会关闭全部窗口，触发业务窗口 Closing 中的确认对话框。
            app.Dispatcher.InvokeShutdown();
        };
        app.Dispatcher.InvokeAsync(async () =>
        {
            FrameworkElement? view = null;
            Window? window = null;
            List<KeyValuePair<string, object?>>? manifest = null;
            var marker = "WpfRenderSelfCheck_" + Guid.NewGuid().ToString("N");
            using var listener = new BindingListener(marker);
            try
            {
                PresentationTraceSources.Refresh();
                PresentationTraceSources.DataBindingSource.Switch.Level = SourceLevels.Warning;
                PresentationTraceSources.DataBindingSource.Listeners.Add(listener);
                // 用独立的小型 Visual 验证监听链路，避免污染目标视图或清空真实绑定错误。
                var probe = new TextBlock { DataContext = new object() };
                probe.SetBinding(TextBlock.TextProperty, new Binding(marker));
                probe.Measure(new Size(100, 30));
                probe.Arrange(new Rect(0, 0, 100, 30));
                await IdleAsync();
                BindingOperations.ClearBinding(probe, TextBlock.TextProperty);

                var width = int.Parse(Value("--width"), CultureInfo.InvariantCulture);
                var height = int.Parse(Value("--height"), CultureInfo.InvariantCulture);
                var dpi = int.Parse(Value("--dpi"), CultureInfo.InvariantCulture);
                var theme = Value("--theme");
                var hosted = args.Contains("--window-host");
                var elementName = Optional("--element");
                view = ViewFactory.Create(theme);
                FrameworkElement root = view;
                if (hosted)
                {
                    window = view as Window ?? new Window { Content = view };
                    // 最大化 / 最小化的窗口会忽略 Left / Top / Width / Height，出现在真实屏幕上或尺寸不受控。
                    window.WindowState = WindowState.Normal;
                    window.Topmost = false;
                    window.ShowActivated = false;
                    window.ShowInTaskbar = false;
                    window.WindowStartupLocation = WindowStartupLocation.Manual;
                    window.Left = -20000;
                    window.Top = -20000;
                    window.WindowStyle = WindowStyle.None;
                    window.ResizeMode = ResizeMode.NoResize;
                    window.SizeToContent = SizeToContent.Manual;
                    window.Width = width;
                    window.Height = height;
                    window.Show();
                    root = window.Content as FrameworkElement
                        ?? throw new InvalidOperationException("Window.Content 必须是 FrameworkElement。");
                    await IdleAsync();
                    // 业务窗口常在 SourceInitialized / Loaded 中恢复上次的位置与最大化状态：显示后再强制一次。
                    window.WindowState = WindowState.Normal;
                    window.Left = -20000;
                    window.Top = -20000;
                    window.Width = width;
                    window.Height = height;
                    await IdleAsync();
                }
                else
                {
                    if (view is Window) throw new InvalidOperationException("Window 需要 -WindowHost 模式。");
                    root.Measure(new Size(width, height));
                    root.Arrange(new Rect(0, 0, width, height));
                }
                root.UpdateLayout();
                await ViewFactory.WaitUntilReadyAsync(view);
                await IdleAsync();
                root.UpdateLayout();

                var pixelWidth = (int)Math.Ceiling(width * dpi / 96.0);
                var pixelHeight = (int)Math.Ceiling(height * dpi / 96.0);
                var (background, backgroundSource) = ResolveBackground(Optional("--background") ?? "auto", theme, window, view is Window);
                var bitmap = new RenderTargetBitmap(pixelWidth, pixelHeight, dpi, dpi, PixelFormats.Pbgra32);
                if (background is not null)
                {
                    // RenderTargetBitmap 会叠加多次 Render，先铺底色避免透明 PNG 在查看器中显示为黑底。
                    var fill = new DrawingVisual();
                    using (var dc = fill.RenderOpen()) dc.DrawRectangle(background, null, new Rect(0, 0, width, height));
                    bitmap.Render(fill);
                }
                bitmap.Render(root);
                // RenderTargetBitmap 按根元素自身的变换与偏移（Margin、对齐、固定尺寸居中）绘制；
                // 布局报告与元素坐标统一换算到截图坐标，才能与 snapshot.png、compare_snapshots 的区域直接对照。
                var rootToImage = RootToImage(root);
                var pngPath = Path.Combine(outDir, "snapshot.png");
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using (var stream = File.Create(pngPath)) encoder.Save(stream);

                // -Element：另存指定 x:Name 元素的截图。
                double[]? elementRect = null;
                string? elementError = null;
                if (elementName is not null)
                {
                    var target = Descendants(root).FirstOrDefault(element => element.Name == elementName)
                        ?? throw new InvalidOperationException($"找不到 x:Name 为 {elementName} 的可见元素。可用名称：" +
                            string.Join(", ", Descendants(root).Select(element => element.Name).Where(name => name.Length > 0).Distinct().Take(40)));
                    var size = target.RenderSize;
                    var toRoot = ReferenceEquals(target, root) ? Transform.Identity : target.TransformToAncestor(root);
                    var bounds = rootToImage.TransformBounds(toRoot.TransformBounds(new Rect(size)));
                    elementRect = [Math.Round(bounds.X, 1), Math.Round(bounds.Y, 1), Math.Round(bounds.Width, 1), Math.Round(bounds.Height, 1)];
                    var elementPixelWidth = Math.Max(1, (int)Math.Ceiling(size.Width * dpi / 96.0));
                    var elementPixelHeight = Math.Max(1, (int)Math.Ceiling(size.Height * dpi / 96.0));
                    // 未虚拟化的长列表等元素可能远大于视口：超过上限时不生成 element.png，整页截图与布局报告照常输出。
                    if ((long)elementPixelWidth * elementPixelHeight > MaxPixels)
                        elementError = $"元素 {elementName} 为 {elementPixelWidth}×{elementPixelHeight} 像素，超过 {MaxPixels / 1000000} 百万像素上限，未生成 element.png。";
                    else
                        WriteElementImage(target, size, background, elementPixelWidth, elementPixelHeight, dpi, Path.Combine(outDir, "element.png"));
                }
                listener.Flush();
                // 布局检查只提供线索，不影响退出码；检查本身出错时记录原因，不让渲染失败。
                int? layoutIssueCount = null;
                string? layoutReportError = null;
                try
                {
                    var (layout, issueCount) = LayoutReport.Inspect(root, rootToImage, width, height, dpi / 96.0);
                    File.WriteAllText(Path.Combine(outDir, "layout.json"), Json.Write(layout));
                    layoutIssueCount = issueCount;
                }
                catch (Exception ex) { layoutReportError = ex.GetType().Name + ": " + ex.Message; }

                string sha256;
                using (var sha = SHA256.Create())
                    sha256 = BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(pngPath))).Replace("-", "").ToLowerInvariant();
                // 绑定问题条数与退出码在 finally 中补齐后一次性写出。
                manifest =
                [
                    new("generatedAt", DateTime.UtcNow.ToString("O")),
                    new("toolVersion", Optional("--tool-version")),
                    new("mode", hosted ? "window-host" : "layout-only"),
                    new("sourceViewType", view.GetType().FullName),
                    new("theme", theme),
                    new("widthDip", width), new("heightDip", height),
                    new("pixelWidth", pixelWidth), new("pixelHeight", pixelHeight), new("dpi", dpi),
                    new("actualWidthDip", root.ActualWidth), new("actualHeightDip", root.ActualHeight),
                    new("background", background?.ToString() ?? "transparent"), new("backgroundSource", backgroundSource),
                    new("bindingTraceVerified", listener.SelfCheckHit),
                    new("layoutIssueCount", layoutIssueCount),
                    new("layoutReportError", layoutReportError),
                    new("element", elementName),
                    new("elementRectDip", elementRect),
                    new("elementImage", elementName is null || elementError is not null ? null : "element.png"),
                    new("elementError", elementError),
                    new("image", "snapshot.png"),
                    new("sha256", sha256),
                    new("targetFramework", typeof(Program).Assembly.GetCustomAttribute<TargetFrameworkAttribute>()?.FrameworkName),
                    new("runtime", RuntimeInformation.FrameworkDescription),
                    new("processArchitecture", RuntimeInformation.ProcessArchitecture.ToString()),
                    new("machineName", Environment.MachineName),
                    // 业务 Window 为 RightToLeft 时，镜像变换在 Window 上而截图只渲染其 Content，结果未镜像。
                    new("warning", hosted && view is Window { FlowDirection: FlowDirection.RightToLeft }
                        ? "Window.FlowDirection 为 RightToLeft：截图与布局坐标未镜像（镜像在 Window 本身上）。可改为渲染其内容的 UserControl。" : null),
                    new("note", "Visual snapshot; native windows, input, and performance require separate verification.")
                ];
                exitCode = !listener.SelfCheckHit ? 1 : listener.Errors.Count > 0 ? 2 : 0;
                if (!listener.SelfCheckHit)
                    File.WriteAllText(Path.Combine(outDir, "error.txt"), "绑定监听自检未命中，不能宣称绑定检查通过。");
            }
            catch (Exception ex)
            {
                File.WriteAllText(Path.Combine(outDir, "error.txt"), ex.ToString());
                exitCode = 1;
            }
            finally
            {
                // 先写出全部结果，再执行业务清理：清理可能卡住（例如窗口关闭确认框），结果不能因此丢失。
                listener.Flush();
                PresentationTraceSources.DataBindingSource.Listeners.Remove(listener);
                File.WriteAllLines(Path.Combine(outDir, "binding-errors.txt"), listener.Errors);
                File.WriteAllText(Path.Combine(outDir, "binding-errors.json"), Json.Write(listener.Errors.Select(BindingIssues.Describe).ToList()));
                if (exitCode == 0 && listener.Errors.Count > 0) exitCode = 2;
                if (manifest is not null)
                {
                    manifest.Add(new("bindingWarningOrErrorCount", listener.Errors.Count));
                    manifest.Add(new("exitCode", exitCode));
                    File.WriteAllText(Path.Combine(outDir, "manifest.json"), Json.Write(manifest));
                }
                Console.WriteLine($"{outDir} (exit={exitCode})");
                try
                {
                    if (view != null) ViewFactory.Cleanup(view);
                }
                catch (Exception ex)
                {
                    File.AppendAllText(Path.Combine(outDir, "error.txt"), ex.ToString());
                    exitCode = 1;
                }
                // 不关闭窗口、不调用 Application.Shutdown（会关闭全部窗口并触发 Closing 中的确认对话框）：
                // 只停止消息循环，随后由 Environment.Exit 结束进程。
                app.Dispatcher.InvokeShutdown();
            }
        });
        app.Run();
        // 业务代码可能留下前台线程（轮询、设备监听），进程会因此无法退出而被判为超时；结果已写完，直接结束进程。
        Console.Out.Flush();
        Console.Error.Flush();
        Environment.Exit(exitCode);
        return exitCode;
    }

    private const long MaxPixels = 60000000;

    // 根元素在截图中的变换：RenderTargetBitmap.Render 会应用根元素的 VisualTransform 与 VisualOffset。
    private static GeneralTransform RootToImage(FrameworkElement root)
    {
        var group = new TransformGroup();
        if (VisualTreeHelper.GetTransform(root) is { } transform) group.Children.Add(transform);
        var offset = VisualTreeHelper.GetOffset(root);
        group.Children.Add(new TranslateTransform(offset.X, offset.Y));
        return group;
    }

    // 用 VisualBrush 把元素绘制到原点，避免直接 Render 子元素时带上其在父容器中的偏移。
    private static void WriteElementImage(FrameworkElement target, Size size, Brush? background, int pixelWidth, int pixelHeight, int dpi, string path)
    {
        var bitmap = new RenderTargetBitmap(pixelWidth, pixelHeight, dpi, dpi, PixelFormats.Pbgra32);
        var drawing = new DrawingVisual();
        using (var dc = drawing.RenderOpen())
        {
            if (background is not null) dc.DrawRectangle(background, null, new Rect(size));
            dc.DrawRectangle(new VisualBrush(target)
            {
                Stretch = Stretch.None, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top,
                ViewboxUnits = BrushMappingMode.Absolute, Viewbox = new Rect(size)
            }, null, new Rect(size));
        }
        bitmap.Render(drawing);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }

    // auto：业务窗口或被样式 / 本地值设置过 Background 的承载窗口取其背景，否则按主题标签取中性底色；
    // transparent：保留 alpha；其余按 WPF 颜色解析。宿主自建窗口的系统默认白底不代表业务外观，不采用。
    private static (Brush? Brush, string Source) ResolveBackground(string value, string theme, Window? window, bool businessWindow)
    {
        if (value.Equals("transparent", StringComparison.OrdinalIgnoreCase)) return (null, "transparent");
        if (!value.Equals("auto", StringComparison.OrdinalIgnoreCase))
            return ((Brush)new BrushConverter().ConvertFromInvariantString(value)!, "explicit");
        if (window?.Background is { } windowBrush && !(windowBrush is SolidColorBrush { Color.A: 0 })
            && (businessWindow || DependencyPropertyHelper.GetValueSource(window, Control.BackgroundProperty).BaseValueSource
                > BaseValueSource.DefaultStyleTrigger))
            return (windowBrush, "window");
        return (theme == "dark" ? new SolidColorBrush(Color.FromRgb(0x1E, 0x1E, 0x1E)) : Brushes.White, "theme-fallback");
    }

    // 可见的 FrameworkElement，按视觉树广度优先。
    private static IEnumerable<FrameworkElement> Descendants(FrameworkElement root)
    {
        var queue = new Queue<DependencyObject>();
        queue.Enqueue(root);
        while (queue.Count > 0)
        {
            var node = queue.Dequeue();
            if (node is FrameworkElement element)
            {
                if (element.Visibility != Visibility.Visible) continue;
                yield return element;
            }
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) queue.Enqueue(VisualTreeHelper.GetChild(node, i));
        }
    }

    private static async Task IdleAsync()
    {
        await Dispatcher.CurrentDispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle);
    }

    private sealed class BindingListener(string marker) : TraceListener
    {
        private readonly StringBuilder buffer = new();
        private readonly HashSet<string> seen = new(StringComparer.Ordinal);
        public List<string> Errors { get; } = new();
        public bool SelfCheckHit { get; private set; }
        public override void Write(string? message) { lock (buffer) buffer.Append(message); }
        public override void WriteLine(string? message)
        {
            lock (buffer)
            {
                buffer.Append(message);
                Record(buffer.ToString());
                buffer.Clear();
            }
        }
        public override void TraceEvent(TraceEventCache? cache, string source, TraceEventType type, int id, string? message)
        { lock (buffer) Record(message); }
        public override void TraceEvent(TraceEventCache? cache, string source, TraceEventType type, int id,
            string? format, params object?[]? args)
        {
            lock (buffer) Record(args is { Length: > 0 }
                ? string.Format(CultureInfo.InvariantCulture, format ?? "", args) : format);
        }
        public override void Flush()
        {
            lock (buffer) { Record(buffer.ToString()); buffer.Clear(); }
        }
        private void Record(string? message)
        {
            if (message is null || string.IsNullOrWhiteSpace(message)) return; // .NET Framework 的 BCL 没有可空注解
            if (message.IndexOf(marker, StringComparison.Ordinal) >= 0) { SelfCheckHit = true; return; }
            if (seen.Add(message)) Errors.Add(message);
        }
    }
}
