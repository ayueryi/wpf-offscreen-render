using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

internal static class ViewFactory
{
    public static Control Create(string theme)
    {
        if (ConfiguredView.TryCreate(theme) is { } configured) return configured;
        var dark = theme == "dark";
        var panel = new StackPanel { Margin = new Thickness(32), Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = "Agent Render · Avalonia", FontSize = 28, Foreground = dark ? Brushes.White : Brushes.Black });
        panel.Children.Add(new TextBlock { Text = "Independent Avalonia visual snapshot / 独立离屏渲染", Foreground = dark ? Brushes.LightGray : Brushes.DimGray });
        panel.Children.Add(new Button { Content = "Sample button / 样例按钮", Width = 240, Height = 44, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Left });
        return new Border
        {
            Background = dark ? new SolidColorBrush(Color.Parse("#1C1F26")) : Brushes.White,
            Child = panel
        };
    }

    public static void WaitUntilReady(Control view) { }
    public static void Cleanup(Control view) { }
}
