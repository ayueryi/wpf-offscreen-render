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

    // 故意把 Customer 拼错，渲染应以退出码 2 报告绑定问题。
    public sealed class BrokenBindingView : OrderView
    {
        protected override string MapPath(string path) =>
            path == nameof(OrderPreviewVm.Customer) ? "CustomerNmae" : path;
    }
}
