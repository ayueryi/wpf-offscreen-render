using System.Windows;
using SampleViews;

// -FactoryFile 测试用：替换宿主默认的 ViewFactory.cs，用带构造参数的 ViewModel 创建视图。
internal static class ViewFactory
{
    public static FrameworkElement Create(string theme) =>
        new OrderView { DataContext = new RemoteOrderVm("Custom factory order") };

    public static Task WaitUntilReadyAsync(FrameworkElement view) => Task.CompletedTask;

    public static void Cleanup(FrameworkElement view) { }
}
