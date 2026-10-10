using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

internal static class ViewFactory
{
    // 生成器传了 -ViewType / -Xaml 时由 harness.json 创建视图；否则在生成的临时工程中替换下方样例，
    // 先配置资源，再创建真实 View 并设置 DataContext。
    public static FrameworkElement Create(string theme)
    {
        if (ConfiguredView.TryCreate(theme) is { } configured) return configured;
        var dark = theme == "dark";
        var panel = new StackPanel { Margin = new Thickness(32) };
        var title = new TextBlock
        {
            FontSize = 28,
            Foreground = dark ? Brushes.White : Brushes.Black,
            DataContext = new SampleData()
        };
        title.SetBinding(TextBlock.TextProperty, new Binding(nameof(SampleData.Title)));
        panel.Children.Add(title);
        panel.Children.Add(new TextBlock
        {
            Text = "Independent WPF visual snapshot / 独立离屏渲染",
            Foreground = dark ? Brushes.LightGray : Brushes.DimGray,
            Margin = new Thickness(0, 12, 0, 24)
        });
        panel.Children.Add(new Button
        {
            Content = "Sample button / 样例按钮", Width = 240, Height = 44,
            HorizontalAlignment = HorizontalAlignment.Left
        });
        return new Border
        {
            Background = dark ? new SolidColorBrush(Color.FromRgb(28, 31, 38)) : Brushes.White,
            Child = panel
        };
    }

    // 此方法在布局 / Loaded 后的 Dispatcher 线程执行。异步页面改成等待真实完成信号。
    public static Task WaitUntilReadyAsync(FrameworkElement view) => Task.CompletedTask;

    // 可在此释放样例 ViewModel 的订阅、计时器和图像等资源。
    public static void Cleanup(FrameworkElement view) { }

    private sealed class SampleData
    {
        public string Title => "WPF Offscreen Render";
    }
}
