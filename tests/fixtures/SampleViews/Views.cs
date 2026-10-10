using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

namespace SampleViews
{
    // 无参构造，可由 -ViewType / -DataContextType 直接创建。
    public sealed class OrderPreviewVm
    {
        public string Title => "Order #1024";
        public string Customer => "Contoso 有限公司";
        public string Status => "Shipped";
    }

    // 没有无参构造：只能经 dataContextFactory 静态工厂方法或自定义 ViewFactory 创建。
    public sealed class RemoteOrderVm
    {
        public RemoteOrderVm(string title) { Title = title; }
        public string Title { get; }
        public string Customer => "Fabrikam 股份有限公司";
        public string Status => "Pending";
    }

    public static class PreviewData
    {
        public static RemoteOrderVm CreateRemoteOrder() => new RemoteOrderVm("Order #2048");
    }

    public class OrderView : UserControl
    {
        public OrderView()
        {
            var panel = new StackPanel { Margin = new Thickness(24) };
            panel.Children.Add(Bound(nameof(OrderPreviewVm.Title), 24));
            panel.Children.Add(Bound(nameof(OrderPreviewVm.Customer), 16));
            panel.Children.Add(Bound(nameof(OrderPreviewVm.Status), 16));
            Content = new Border { Background = Brushes.White, Child = panel };
        }

        protected virtual string MapPath(string path) => path;

        private TextBlock Bound(string path, double fontSize)
        {
            var text = new TextBlock { FontSize = fontSize, Margin = new Thickness(0, 0, 0, 8) };
            text.SetBinding(TextBlock.TextProperty, new Binding(MapPath(path)));
            return text;
        }
    }

    // 每类布局问题各一处：布局检查应分别报告 text-truncated、clipped、overlap、zero-size、out-of-viewport。
    public sealed class LayoutProblemsView : UserControl
    {
        public LayoutProblemsView()
        {
            var panel = new StackPanel { Margin = new Thickness(16) };
            panel.Children.Add(new TextBlock { Name = "TruncatedTitle", Width = 80, FontSize = 16, Text = "This title is far too long for its box" });

            var narrow = new StackPanel { Orientation = Orientation.Horizontal, Width = 200, HorizontalAlignment = HorizontalAlignment.Left };
            narrow.Children.Add(new Button { Name = "ClippedButton", Width = 300, Content = "Clipped" });
            panel.Children.Add(narrow);

            var cell = new Grid();
            cell.Children.Add(new TextBlock { Name = "OverlapA", Text = "Overlapping text A" });
            cell.Children.Add(new TextBlock { Name = "OverlapB", Text = "Overlapping text B", Margin = new Thickness(20, 4, 0, 0) });
            panel.Children.Add(cell);

            panel.Children.Add(new TextBlock { Name = "ZeroSizeText", Width = 0, Text = "Invisible" });

            var canvas = new Canvas { Height = 40 };
            var offscreen = new TextBlock { Name = "OffscreenNote", Text = "Offscreen note" };
            Canvas.SetLeft(offscreen, 1250);
            canvas.Children.Add(offscreen);
            panel.Children.Add(canvas);

            Content = new Border { Background = Brushes.White, Child = panel };
        }
    }

    // 布局检查的反例：滚动区域内超出视口的行、同一单元格中左右对齐的文本都属正常，不应报告任何问题。
    public sealed class ScrollListView : UserControl
    {
        public ScrollListView()
        {
            var dock = new DockPanel { Margin = new Thickness(16) };
            var header = new Grid { Margin = new Thickness(0, 0, 0, 8) };
            header.Children.Add(new TextBlock { Text = "Orders", FontSize = 20 });
            header.Children.Add(new TextBlock { Text = "60 items", FontSize = 20, TextAlignment = TextAlignment.Right });
            DockPanel.SetDock(header, Dock.Top);
            dock.Children.Add(header);

            var rows = new StackPanel();
            for (var i = 1; i <= 60; i++) rows.Children.Add(new TextBlock { Text = "Row " + i, Margin = new Thickness(0, 2, 0, 2) });
            dock.Children.Add(new ScrollViewer { Height = 300, VerticalAlignment = VerticalAlignment.Top, Content = rows });

            Content = new Border { Background = Brushes.White, Child = dock };
        }
    }

    // 故意把 Customer 拼错，渲染应以退出码 2 报告绑定问题。
    public sealed class BrokenBindingView : OrderView
    {
        protected override string MapPath(string path) =>
            path == nameof(OrderPreviewVm.Customer) ? "CustomerNmae" : path;
    }
}
