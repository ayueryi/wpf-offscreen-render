using System.Windows;
using SampleViews;

// custom 步骤测试用：实现可选的 RunStepAsync，按 action / args 修改样例 ViewModel。
internal static class ViewFactory
{
    public static FrameworkElement Create(string theme) => ConfiguredView.TryCreate(theme) ?? new InteractionView();

    public static Task WaitUntilReadyAsync(FrameworkElement view) => Task.CompletedTask;

    public static void Cleanup(FrameworkElement view) { }

    public static Task RunStepAsync(FrameworkElement view, string action, IReadOnlyDictionary<string, string> args)
    {
        if (action == "SetStatus") ((InteractionVm)view.DataContext).Status = args["status"];
        else throw new InvalidOperationException("未知的 custom 动作：" + action);
        return Task.CompletedTask;
    }
}
