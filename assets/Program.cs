using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

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
            app.Shutdown(1);
        };
        app.Dispatcher.InvokeAsync(async () =>
        {
            FrameworkElement? view = null;
            Window? window = null;
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
                view = ViewFactory.Create(theme);
                FrameworkElement root = view;
                if (hosted)
                {
                    window = view as Window ?? new Window { Content = view };
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
                var pngPath = Path.Combine(outDir, "snapshot.png");
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using (var stream = File.Create(pngPath)) encoder.Save(stream);
                listener.Flush();
                var manifest = new
                {
                    generatedAt = DateTime.UtcNow.ToString("O"),
                    mode = hosted ? "window-host" : "layout-only",
                    sourceViewType = view.GetType().FullName,
                    theme, widthDip = width, heightDip = height, pixelWidth, pixelHeight, dpi,
                    actualWidthDip = root.ActualWidth, actualHeightDip = root.ActualHeight,
                    background = background?.ToString() ?? "transparent", backgroundSource,
                    bindingTraceVerified = listener.SelfCheckHit,
                    bindingWarningOrErrorCount = listener.Errors.Count,
                    image = "snapshot.png",
                    sha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(pngPath))).ToLowerInvariant(),
                    runtime = Environment.Version.ToString(),
                    machineName = Environment.MachineName,
                    note = "Visual snapshot; native windows, input, and performance require separate verification."
                };
                File.WriteAllText(Path.Combine(outDir, "manifest.json"),
                    JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }));
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
                try
                {
                    if (view != null) ViewFactory.Cleanup(view);
                    window?.Close();
                    listener.Flush();
                }
                catch (Exception ex)
                {
                    File.AppendAllText(Path.Combine(outDir, "error.txt"), ex.ToString());
                    exitCode = 1;
                }
                PresentationTraceSources.DataBindingSource.Listeners.Remove(listener);
                File.WriteAllLines(Path.Combine(outDir, "binding-errors.txt"), listener.Errors);
                if (exitCode == 0 && listener.Errors.Count > 0) exitCode = 2;
                var manifestPath = Path.Combine(outDir, "manifest.json");
                if (File.Exists(manifestPath))
                {
                    var manifest = JsonNode.Parse(File.ReadAllText(manifestPath))!;
                    manifest["bindingWarningOrErrorCount"] = listener.Errors.Count;
                    manifest["exitCode"] = exitCode;
                    File.WriteAllText(manifestPath, manifest.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
                }
                Console.WriteLine($"{outDir} (exit={exitCode})");
                app.Shutdown(exitCode);
            }
        });
        app.Run();
        return exitCode;
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
            if (string.IsNullOrWhiteSpace(message)) return;
            if (message.Contains(marker, StringComparison.Ordinal)) { SelfCheckHit = true; return; }
            if (seen.Add(message)) Errors.Add(message);
        }
    }
}
