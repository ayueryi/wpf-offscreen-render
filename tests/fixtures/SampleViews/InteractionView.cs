using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace SampleViews
{
    // 交互步骤测试用：展开、输入、提交（命令 + 提交后才出现的错误绑定）、VSM 悬停、Storyboard 淡入、对话框。
    public sealed class InteractionVm : INotifyPropertyChanged
    {
        private string customer = "Contoso";
        private string status = "Draft";
        private SubmitResult result;

        public InteractionVm() { SubmitCommand = new RelayCommand(() => { Status = "Submitted"; Result = new SubmitResult(); }); }

        public string Customer { get => customer; set { customer = value; Raise(nameof(Customer)); } }
        public string Status { get => status; set { status = value; Raise(nameof(Status)); } }
        public SubmitResult Result { get => result; set { result = value; Raise(nameof(Result)); } }
        public ICommand SubmitCommand { get; }

        public event PropertyChangedEventHandler PropertyChanged;
        private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public sealed class SubmitResult
    {
        public string Message => "Thanks";
    }

    public sealed class RelayCommand : ICommand
    {
        private readonly Action execute;
        public RelayCommand(Action execute) { this.execute = execute; }
        public event EventHandler CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object parameter) => true;
        public void Execute(object parameter) => execute();
    }

    public sealed class InteractionView : UserControl
    {
        public InteractionView()
        {
            DataContext = new InteractionVm();
            var panel = new StackPanel { Margin = new Thickness(16) };

            var expander = new Expander { Name = "DetailsExpander", Header = "Details", Content = new TextBlock { Name = "DetailsText", Text = "Order details: 3 items" } };
            panel.Children.Add(expander);

            var customer = new TextBox { Name = "CustomerBox", Width = 200, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
            customer.SetBinding(TextBox.TextProperty, new Binding(nameof(InteractionVm.Customer)) { Mode = BindingMode.TwoWay, UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged });
            panel.Children.Add(customer);

            var customerEcho = new TextBlock { Name = "CustomerEcho" };
            customerEcho.SetBinding(TextBlock.TextProperty, new Binding(nameof(InteractionVm.Customer)) { StringFormat = "Customer: {0}" });
            panel.Children.Add(customerEcho);

            var submit = new Button { Name = "SubmitButton", Content = "Submit", Width = 120, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
            submit.SetBinding(Button.CommandProperty, new Binding(nameof(InteractionVm.SubmitCommand)));
            panel.Children.Add(submit);

            var status = new TextBlock { Name = "StatusText" };
            status.SetBinding(TextBlock.TextProperty, new Binding(nameof(InteractionVm.Status)));
            panel.Children.Add(status);

            // 提交后才有内容：模板中的绑定故意拼错（Mesage），绑定错误应归属到“提交”这一步。
            var result = new ContentControl { Name = "ResultHost", ContentTemplate = (DataTemplate)XamlReader.Parse(
                "<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><TextBlock Text='{Binding Mesage}' /></DataTemplate>") };
            result.SetBinding(ContentControl.ContentProperty, new Binding(nameof(InteractionVm.Result)));
            panel.Children.Add(result);

            // 用 VisualStateManager 定义悬停状态的按钮：state 步骤可以切到 MouseOver。
            var vsm = new Button { Name = "VsmButton", Content = "Hover me", Width = 120, Height = 32, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
            vsm.Template = (ControlTemplate)XamlReader.Parse(
                "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='Button'>"
                + "<Border x:Name='Root'><Border.Background><SolidColorBrush x:Name='RootBrush' Color='LightGray' /></Border.Background>"
                + "<VisualStateManager.VisualStateGroups><VisualStateGroup x:Name='CommonStates'><VisualState x:Name='Normal' />"
                + "<VisualState x:Name='MouseOver'><Storyboard><ColorAnimation Storyboard.TargetName='RootBrush' Storyboard.TargetProperty='Color' To='Orange' Duration='0' /></Storyboard></VisualState>"
                + "</VisualStateGroup></VisualStateManager.VisualStateGroups>"
                + "<ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center' /></Border></ControlTemplate>");
            panel.Children.Add(vsm);

            var disabled = new Button { Name = "DisabledButton", Content = "Disabled", IsEnabled = false, Width = 120, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
            panel.Children.Add(disabled);

            var dialog = new Button { Name = "DialogButton", Content = "Open dialog", Width = 120, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
            dialog.Click += (_, _) =>
            {
                var window = new Window { Title = "Confirm", Width = 240, Height = 120, Content = new TextBlock { Text = "Are you sure?", Margin = new Thickness(16) } };
                window.ShowDialog();
                ((InteractionVm)DataContext).Status = "Dialog closed";
            };
            panel.Children.Add(dialog);

            var message = new Button { Name = "MessageButton", Content = "Message", Width = 120, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
            message.Click += (_, _) => MessageBox.Show("Saved successfully", "Info");
            panel.Children.Add(message);

            // 淡入提示：资源中的 Storyboard 直接以元素为目标（代码创建的视图没有名称范围）。
            var toast = new Border { Name = "Toast", Background = Brushes.SteelBlue, Width = 200, Height = 40, HorizontalAlignment = HorizontalAlignment.Left, Opacity = 0, Margin = new Thickness(0, 8, 0, 0),
                Child = new TextBlock { Text = "Saved", Foreground = Brushes.White, Margin = new Thickness(8) } };
            panel.Children.Add(toast);
            var fade = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(300));
            Storyboard.SetTarget(fade, toast);
            Storyboard.SetTargetProperty(fade, new PropertyPath(OpacityProperty));
            var storyboard = new Storyboard();
            storyboard.Children.Add(fade);
            Resources["FadeIn"] = storyboard;

            Content = new Border { Background = Brushes.White, Child = panel };
        }
    }
}
