using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

// 交互步骤：按 harness.json 中的 steps 依次执行动作（设置属性、调用按钮、切换状态、动画取帧等），
// 每步之后截图并检查绑定与布局。步骤由脚本规范化为扁平结构，值统一为不变区域字符串（见 scripts/Steps.ps1）。
// 只使用 .NET Framework 4.7.2 与 .NET 5+ 共有的 API（不用 required / init：net472 缺少对应的编译器特性类型）。
internal static class StepRunner
{
    internal sealed class Context
    {
        public FrameworkElement Root { get; set; } = null!;
        public FrameworkElement View { get; set; } = null!;
        public Window? Window { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public int Dpi { get; set; }
        public Brush? Background { get; set; }
        public string OutDir { get; set; } = null!;
        // 当前已记录的绑定错误（含步骤之前的），用于按步骤归属新增的错误。
        public Func<IReadOnlyList<string>> BindingErrors { get; set; } = null!;
        public RenderTargetBitmap Initial { get; set; } = null!;
    }

    private const int DefaultTimeoutMs = 10000;

    public static async Task<(List<object?> Reports, bool AnyFailed)> RunAsync(Context context, StepsConfig config)
    {
        var reports = new List<object?>();
        var anyFailed = false;
        var previous = context.Initial;
        var steps = config.Steps ?? [];
        var dialogs = new DialogWatcher();
        for (var i = 0; i < steps.Count; i++)
        {
            var step = steps[i];
            var index = i + 1;
            var name = string.IsNullOrWhiteSpace(step.Name) ? $"step-{index}" : step.Name!;
            var stepDir = Path.Combine(context.OutDir, "steps", $"{index:00}-{SafeName(name)}");
            if (anyFailed && config.ContinueOnError != true)
            {
                reports.Add(Json.Object(("index", index), ("name", name), ("action", step.Action), ("status", "skipped")));
                continue;
            }
            Directory.CreateDirectory(stepDir);
            var warnings = new List<object?>();
            var frames = new List<object?>();
            var dialogReports = new List<object?>();
            var errorsBefore = context.BindingErrors().Count;
            var watch = Stopwatch.StartNew();
            string status = "ok";
            string? error = null;
            List<KeyValuePair<string, object?>>? capture = null;
            try
            {
                dialogs.Begin();
                if (step.Action == "animate")
                {
                    previous = await AnimateAsync(context, config, step, stepDir, previous, frames);
                }
                else
                {
                    await ExecuteAsync(context, step, warnings);
                    await SettleAsync(context, step);
                }
                // 动作打开的对话框：截取后关闭（MessageBox 只能记录文字并关闭），关闭后让业务代码继续执行。
                if (await dialogs.CloseNewAsync(stepDir, context.Dpi, dialogReports))
                    await SettleAsync(context, step);
                if (step.Action != "animate" && step.Capture != false)
                {
                    (capture, previous) = Capture(context, config, stepDir, previous);
                }
            }
            catch (Exception ex)
            {
                anyFailed = true;
                status = "failed";
                error = Unwrap(ex).Message;
                try
                {
                    await dialogs.CloseNewAsync(stepDir, context.Dpi, dialogReports);
                    (capture, previous) = Capture(context, config, stepDir, previous);
                }
                catch (Exception captureError) { warnings.Add("失败后的截图未能生成：" + Unwrap(captureError).Message); }
            }

            var newErrors = context.BindingErrors().Skip(errorsBefore).ToList();
            var report = Json.Object(
                ("index", index), ("name", name), ("action", step.Action), ("status", status), ("error", error),
                ("durationMs", (int)watch.ElapsedMilliseconds),
                ("bindingIssueCount", newErrors.Count),
                ("bindingIssues", newErrors.Select(Summary).ToList()),
                ("warnings", warnings), ("dialogs", dialogReports));
            if (capture is not null) report.AddRange(capture);
            if (frames.Count > 0) report.Add(new("frames", frames));
            reports.Add(report);
        }
        return (reports, anyFailed);
    }

    // ---------- 动作 ----------

    private static async Task ExecuteAsync(Context context, StepConfig step, List<object?> warnings)
    {
        switch (step.Action)
        {
            case null or "": break; // 只截图
            case "set": SetProperty(Find(context, step, warnings), step); break;
            case "setData": SetData(context.View.DataContext, Required(step.Path, "setData.path"), step); break;
            case "invoke": Invoke(Find(context, step, warnings), warnings); break;
            case "command": ExecuteCommand(context, step, warnings); break;
            case "state": GoToState(Find(context, step, warnings), Required(step.State, "state.state")); break;
            case "focus": Focus(context, Find(context, step, warnings), warnings); break;
            case "custom": await RunCustomAsync(context, step); break;
            default: throw new InvalidOperationException($"未知的步骤动作：{step.Action}");
        }
    }

    private static void SetProperty(FrameworkElement target, StepConfig step)
    {
        var property = Required(step.Property, "set.property");
        var descriptor = FindDependencyProperty(target, property);
        if (descriptor is not null)
        {
            var dp = descriptor.DependencyProperty;
            if (dp.ReadOnly)
                throw new InvalidOperationException($"{property} 是只读属性（由 WPF 根据输入或布局计算），不能设置。悬停 / 按下等状态请用 state 步骤。");
            if (step.Clear == true) { target.ClearValue(dp); return; }
            // SetCurrentValue 保留绑定（双向绑定会把值写回 ViewModel），与用户操作控件的效果一致。
            target.SetCurrentValue(dp, Convert(step.Value, dp.PropertyType, descriptor.Converter));
            return;
        }
        var clr = target.GetType().GetProperty(property, BindingFlags.Public | BindingFlags.Instance)
            ?? throw new InvalidOperationException($"{TypeName(target)} 上没有属性 {property}。");
        if (!clr.CanWrite) throw new InvalidOperationException($"{TypeName(target)}.{property} 不可写。");
        clr.SetValue(target, step.Clear == true ? null : Convert(step.Value, clr.PropertyType, null));
    }

    // 普通依赖属性按名称查找；附加属性写成 Owner.Property（如 Grid.Row）。
    private static DependencyPropertyDescriptor? FindDependencyProperty(FrameworkElement target, string property)
    {
        var dot = property.LastIndexOf('.');
        if (dot < 0) return DependencyPropertyDescriptor.FromName(property, target.GetType(), target.GetType());
        var ownerName = property.Substring(0, dot);
        var owner = AppDomain.CurrentDomain.GetAssemblies()
            .SelectMany(assembly => { try { return assembly.GetTypes(); } catch (ReflectionTypeLoadException e) { return e.Types.Where(t => t is not null).Cast<Type>(); } })
            .Where(type => type.Name == ownerName || type.FullName == ownerName)
            .OrderBy(type => type.Namespace?.StartsWith("System.Windows", StringComparison.Ordinal) == true ? 0 : 1)
            .FirstOrDefault() ?? throw new InvalidOperationException($"找不到附加属性的所有者类型 {ownerName}。");
        return DependencyPropertyDescriptor.FromName(property.Substring(dot + 1), owner, target.GetType())
            ?? throw new InvalidOperationException($"{owner.Name} 上没有附加属性 {property.Substring(dot + 1)}。");
    }

    // 按 DataContext 上的点分路径赋值，支持索引（Items[0].Name）。
    private static void SetData(object? dataContext, string path, StepConfig step)
    {
        if (dataContext is null) throw new InvalidOperationException("视图没有 DataContext，无法执行 setData。");
        var segments = path.Split('.');
        var current = dataContext;
        for (var i = 0; i < segments.Length - 1; i++)
            current = GetMember(current, segments[i], path) ?? throw new InvalidOperationException($"{path} 中 {segments[i]} 为 null。");
        var (member, index) = ParseSegment(segments[segments.Length - 1]);
        if (index is not null)
        {
            var list = GetMember(current, member, path) as System.Collections.IList ?? throw new InvalidOperationException($"{path} 中 {member} 不是列表。");
            var elementType = list.GetType().GetGenericArguments().FirstOrDefault() ?? typeof(object);
            list[index.Value] = step.Clear == true ? null : Convert(step.Value, elementType, null);
            return;
        }
        var property = current.GetType().GetProperty(member, BindingFlags.Public | BindingFlags.Instance)
            ?? throw new InvalidOperationException($"{current.GetType().Name} 上没有属性 {member}（路径 {path}）。");
        if (!property.CanWrite) throw new InvalidOperationException($"{current.GetType().Name}.{member} 不可写（路径 {path}）。");
        property.SetValue(current, step.Clear == true ? null : Convert(step.Value, property.PropertyType, null));
    }

    private static object? GetMember(object target, string segment, string path)
    {
        var (member, index) = ParseSegment(segment);
        var property = target.GetType().GetProperty(member, BindingFlags.Public | BindingFlags.Instance)
            ?? throw new InvalidOperationException($"{target.GetType().Name} 上没有属性 {member}（路径 {path}）。");
        var value = property.GetValue(target);
        if (index is null) return value;
        return value is System.Collections.IList list ? list[index.Value] : throw new InvalidOperationException($"{path} 中 {member} 不是列表。");
    }

    private static (string Member, int? Index) ParseSegment(string segment)
    {
        var open = segment.IndexOf('[');
        if (open < 0) return (segment, null);
        return (segment.Substring(0, open), int.Parse(segment.Substring(open + 1).TrimEnd(']'), CultureInfo.InvariantCulture));
    }

    // 经 UI 自动化接口操作控件，与辅助技术“点击”按钮的路径相同；按元素支持的模式自动选择。
    private static void Invoke(FrameworkElement target, List<object?> warnings)
    {
        if (!target.IsEnabled) throw new InvalidOperationException($"{TypeName(target)} 已禁用（IsEnabled=false），无法调用。");
        var peer = UIElementAutomationPeer.CreatePeerForElement(target)
            ?? throw new InvalidOperationException($"{TypeName(target)} 没有自动化对等体，无法调用；可改用 command 或 set 步骤。");
        switch (peer.GetPattern(PatternInterface.Invoke), peer.GetPattern(PatternInterface.Toggle),
            peer.GetPattern(PatternInterface.ExpandCollapse), peer.GetPattern(PatternInterface.SelectionItem))
        {
            case (IInvokeProvider invoke, _, _, _): invoke.Invoke(); break;
            case (_, IToggleProvider toggle, _, _): toggle.Toggle(); break;
            case (_, _, IExpandCollapseProvider expand, _):
                if (expand.ExpandCollapseState == ExpandCollapseState.Collapsed) expand.Expand(); else expand.Collapse();
                break;
            case (_, _, _, ISelectionItemProvider selection): selection.Select(); break;
            default: throw new InvalidOperationException($"{TypeName(target)} 不支持 Invoke / Toggle / ExpandCollapse / SelectionItem，可改用 command 或 set 步骤。");
        }
    }

    private static void ExecuteCommand(Context context, StepConfig step, List<object?> warnings)
    {
        ICommand command;
        object? parameter;
        IInputElement? commandTarget = null;
        if (step.Element is not null)
        {
            var element = Find(context, step, warnings);
            var source = element as ICommandSource ?? throw new InvalidOperationException($"{TypeName(element)} 不是命令源（ICommandSource）。");
            command = source.Command ?? throw new InvalidOperationException($"{TypeName(element)} 没有绑定 Command。");
            parameter = source.CommandParameter;
            commandTarget = source.CommandTarget ?? element;
        }
        else
        {
            var path = Required(step.Path, "command.path");
            var segments = path.Split('.');
            object? current = context.View.DataContext ?? throw new InvalidOperationException("视图没有 DataContext，无法按路径执行命令。");
            foreach (var segment in segments) current = current is null ? null : GetMember(current, segment, path);
            command = current as ICommand ?? throw new InvalidOperationException($"{path} 不是 ICommand。");
            parameter = step.Parameter;
        }
        if (command is RoutedCommand routed)
        {
            var target = commandTarget ?? context.Root;
            if (!routed.CanExecute(parameter, target)) throw new InvalidOperationException("命令当前不可执行（CanExecute=false）。");
            routed.Execute(parameter, target);
            return;
        }
        if (!command.CanExecute(parameter)) throw new InvalidOperationException("命令当前不可执行（CanExecute=false）。");
        command.Execute(parameter);
    }

    private static void GoToState(FrameworkElement target, string state)
    {
        if (target is Control control && VisualStateManager.GoToState(control, state, false)) return;
        if (VisualStateManager.GoToElementState(target, state, false)) return;
        throw new InvalidOperationException($"{TypeName(target)} 的模板中没有 VisualState {state}。"
            + "WPF 默认主题的按钮、输入框等用样式触发器（IsMouseOver / IsPressed）实现悬停与按下，这些属性只读，离屏无法模拟；只有用 VisualStateManager 定义状态的模板才能截到。");
    }

    private static void Focus(Context context, FrameworkElement target, List<object?> warnings)
    {
        if (context.Window is not null)
        {
            // 键盘焦点需要活动窗口：激活屏外窗口，可能短暂成为前台窗口。
            context.Window.Activate();
            warnings.Add("为设置键盘焦点激活了屏外窗口（可能短暂成为前台窗口）。");
            Keyboard.Focus(target);
            if (!target.IsKeyboardFocusWithin) warnings.Add($"{TypeName(target)} 未获得键盘焦点（是否 Focusable=false 或被禁用？）。");
            return;
        }
        FocusManager.SetFocusedElement(FocusManager.GetFocusScope(target), target);
        warnings.Add("默认模式（无窗口）只能设置逻辑焦点，依赖 IsKeyboardFocused 的样式不会生效；需要键盘焦点时使用 windowHost。");
    }

    private static async Task RunCustomAsync(Context context, StepConfig step)
    {
        var method = typeof(ViewFactory).GetMethod("RunStepAsync", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static)
            ?? throw new InvalidOperationException("ViewFactory 未实现 RunStepAsync(FrameworkElement view, string action, IReadOnlyDictionary<string, string> args)，无法执行 custom 步骤。");
        var args = (step.Args ?? []).Where(arg => arg.Key is not null).ToDictionary(arg => arg.Key!, arg => arg.Value ?? "");
        var result = method.Invoke(null, [context.View, Required(step.CustomAction, "custom.action"), (IReadOnlyDictionary<string, string>)args]);
        if (result is Task task) await task;
    }

    // ---------- 动画取帧 ----------

    private static async Task<RenderTargetBitmap> AnimateAsync(Context context, StepsConfig config, StepConfig step, string stepDir,
        RenderTargetBitmap previous, List<object?> frames)
    {
        var warnings = new List<object?>();
        var target = step.Element is null ? context.View : Find(context, step, warnings);
        Storyboard storyboard;
        if (step.Storyboard is not null)
        {
            storyboard = target.TryFindResource(step.Storyboard) as Storyboard
                ?? throw new InvalidOperationException($"在 {TypeName(target)} 及其上级资源中找不到 Storyboard {step.Storyboard}。");
        }
        else
        {
            var trigger = Required(step.Trigger, "animate.storyboard 或 animate.trigger");
            storyboard = Triggers(target).OfType<EventTrigger>().Where(t => t.RoutedEvent?.Name == trigger)
                .SelectMany(t => t.Actions.OfType<BeginStoryboard>()).Select(action => action.Storyboard).FirstOrDefault(sb => sb is not null)
                ?? throw new InvalidOperationException($"{TypeName(target)} 上没有 {trigger} 事件触发的 BeginStoryboard。");
        }
        var times = step.AtMs is { Length: > 0 } ? step.AtMs : new[] { 0 };
        // 可控方式开始并暂停，再逐个时刻定位：SeekAlignedToLastTick 同步计算动画值，不依赖真实时钟，结果可复现。
        storyboard.Begin(target, true);
        storyboard.Pause(target);
        foreach (var ms in times)
        {
            storyboard.SeekAlignedToLastTick(target, TimeSpan.FromMilliseconds(ms), TimeSeekOrigin.BeginTime);
            context.Root.UpdateLayout();
            var (frame, current) = Capture(context, config, stepDir, previous, $"frame-{ms:0000}ms", settle: false);
            frame.Insert(0, new("atMs", ms));
            frames.Add(frame);
            previous = current;
        }
        // 最后一帧同时作为该步的截图；动画随后跳到结束状态，后续步骤看到的是动画完成后的画面。
        File.Copy(Path.Combine(stepDir, $"frame-{times[times.Length - 1]:0000}ms.png"), Path.Combine(stepDir, "snapshot.png"), true);
        storyboard.SkipToFill(target);
        await IdleAsync();
        return previous;
    }

    // ---------- 等待 ----------

    private static async Task SettleAsync(Context context, StepConfig step)
    {
        context.Root.UpdateLayout();
        await IdleAsync();
        if (step.WaitMs is > 0) await Task.Delay(Math.Min(step.WaitMs.Value, 10000));
        if (!string.IsNullOrEmpty(step.WaitFor)) await WaitForAsync(context, step.WaitFor!, step.TimeoutMs ?? DefaultTimeoutMs);
        context.Root.UpdateLayout();
        await IdleAsync();
    }

    // idle / factory / property:元素.属性=值 / data:路径=值
    private static async Task WaitForAsync(Context context, string condition, int timeoutMs)
    {
        if (condition == "idle") return;
        if (condition == "factory") { await ViewFactory.WaitUntilReadyAsync(context.View); return; }
        var colon = condition.IndexOf(':');
        var equals = condition.LastIndexOf('=');
        if (colon < 0 || equals < colon) throw new InvalidOperationException($"无法识别的 waitFor：{condition}（支持 idle、factory、property:元素.属性=值、data:路径=值）。");
        var kind = condition.Substring(0, colon);
        var subject = condition.Substring(colon + 1, equals - colon - 1);
        var expected = condition.Substring(equals + 1);
        Func<object?> read = kind switch
        {
            "property" => () =>
            {
                var dot = subject.IndexOf('.');
                if (dot < 0) throw new InvalidOperationException($"waitFor property 应写成 元素.属性：{subject}");
                var element = FindByName(context, subject.Substring(0, dot));
                var name = subject.Substring(dot + 1);
                var descriptor = FindDependencyProperty(element, name);
                return descriptor is not null ? element.GetValue(descriptor.DependencyProperty) : element.GetType().GetProperty(name)?.GetValue(element);
            },
            "data" => () =>
            {
                object? current = context.View.DataContext;
                foreach (var segment in subject.Split('.')) current = current is null ? null : GetMember(current, segment, subject);
                return current;
            },
            _ => throw new InvalidOperationException($"无法识别的 waitFor 类型：{kind}"),
        };
        var watch = Stopwatch.StartNew();
        while (true)
        {
            var actual = System.Convert.ToString(read(), CultureInfo.InvariantCulture) ?? "";
            if (string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase)) return;
            if (watch.ElapsedMilliseconds > timeoutMs) throw new TimeoutException($"等待 {condition} 超过 {timeoutMs} ms（当前值 {actual}）。");
            await Task.Delay(50);
            context.Root.UpdateLayout();
        }
    }

    // ---------- 截图与比较 ----------

    private static (List<KeyValuePair<string, object?>> Report, RenderTargetBitmap Bitmap) Capture(Context context, StepsConfig config,
        string stepDir, RenderTargetBitmap previous, string fileName = "snapshot", bool settle = true)
    {
        if (settle && config.Animations == "settle") SettleAnimations(context.Root);
        context.Root.UpdateLayout();
        var bitmap = Program.RenderRoot(context.Root, context.Width, context.Height, context.Dpi, context.Background);
        var path = Path.Combine(stepDir, fileName + ".png");
        Program.SavePng(bitmap, path);
        var report = Json.Object(("snapshot", path));
        var (changedPixels, bounds) = Diff(previous, bitmap);
        var scale = context.Dpi / 96.0;
        report.Add(new("changedPixels", changedPixels));
        report.Add(new("changedBoundsDip", bounds is { } b
            ? new[] { Math.Round(b.X / scale, 1), Math.Round(b.Y / scale, 1), Math.Round(b.Width / scale, 1), Math.Round(b.Height / scale, 1) }
            : null));
        if (fileName == "snapshot")
        {
            try
            {
                var (layout, issueCount) = LayoutReport.Inspect(context.Root, Program.RootToImage(context.Root), context.Width, context.Height, context.Dpi / 96.0);
                File.WriteAllText(Path.Combine(stepDir, "layout.json"), Json.Write(layout));
                report.Add(new("layoutIssueCount", issueCount));
                var issues = layout.FirstOrDefault(pair => pair.Key == "issues").Value as List<object?> ?? [];
                report.Add(new("layoutIssues", issues.Take(5).OfType<List<KeyValuePair<string, object?>>>().Select(issue =>
                    $"[{Field(issue, "kind")}] {Field(issue, "element")}：{Field(issue, "message")}").ToList()));
            }
            catch (Exception ex) { report.Add(new("layoutReportError", ex.GetType().Name + ": " + ex.Message)); }
        }
        return (report, bitmap);
    }

    // 逐像素比较两张同尺寸位图，返回变化像素数与外接矩形（像素坐标）。
    private static (int Count, Int32Rect? Bounds) Diff(BitmapSource before, BitmapSource after)
    {
        if (before.PixelWidth != after.PixelWidth || before.PixelHeight != after.PixelHeight)
            return (after.PixelWidth * after.PixelHeight, new Int32Rect(0, 0, after.PixelWidth, after.PixelHeight));
        var width = after.PixelWidth;
        var height = after.PixelHeight;
        var a = new int[width * height];
        var b = new int[width * height];
        before.CopyPixels(a, width * 4, 0);
        after.CopyPixels(b, width * 4, 0);
        int count = 0, minX = width, minY = height, maxX = -1, maxY = -1;
        for (var y = 0; y < height; y++)
        {
            var row = y * width;
            for (var x = 0; x < width; x++)
            {
                if (a[row + x] == b[row + x]) continue;
                count++;
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
            }
        }
        return count == 0 ? (0, null) : (count, new Int32Rect(minX, minY, maxX - minX + 1, maxY - minY + 1));
    }

    // animations: settle：把元素与其样式上由事件触发器启动的 Storyboard 跳到结束状态，减少截图时的动画抖动。
    private static void SettleAnimations(FrameworkElement root)
    {
        foreach (var element in AllElements(root))
        {
            var triggers = Triggers(element).OfType<EventTrigger>();
            foreach (var begin in triggers.SelectMany(trigger => trigger.Actions.OfType<BeginStoryboard>()))
            {
                try { begin.Storyboard?.SkipToFill(element); } catch (InvalidOperationException) { }
            }
        }
    }

    private static IEnumerable<TriggerBase> Triggers(FrameworkElement element) =>
        element.Triggers.Cast<TriggerBase>().Concat(element.Style?.Triggers.Cast<TriggerBase>() ?? Enumerable.Empty<TriggerBase>());

    // ---------- 元素定位 ----------

    private static FrameworkElement Find(Context context, StepConfig step, List<object?> warnings)
    {
        var selector = step.Element ?? throw new InvalidOperationException($"{step.Action} 步骤需要 element。");
        if (selector.Text is not null) warnings.Add("按显示文本定位元素，受本地化与文案修改影响；稳定的写法是 x:Name 或 AutomationId。");
        var matches = AllElements(context.Root).Where(element =>
            (selector.Name is null || element.Name == selector.Name)
            && (selector.AutomationId is null || AutomationProperties.GetAutomationId(element) == selector.AutomationId)
            && (selector.Type is null || element.GetType().Name == selector.Type || element.GetType().FullName == selector.Type)
            && (selector.Text is null || TextOf(element) == selector.Text)).ToList();
        var index = selector.Index ?? 0;
        if (index < matches.Count) return selector.Text is not null ? InteractiveAncestor(matches[index], context.Root) : matches[index];
        var names = AllElements(context.Root).Select(element => element.Name).Where(name => name.Length > 0).Distinct().Take(40);
        throw new InvalidOperationException($"找不到元素 {Describe(selector)}（匹配 {matches.Count} 个）。可用名称：{string.Join(", ", names)}");
    }

    private static FrameworkElement FindByName(Context context, string name) =>
        AllElements(context.Root).FirstOrDefault(element => element.Name == name)
        ?? throw new InvalidOperationException($"找不到 x:Name 为 {name} 的元素。");

    // 视觉树中的全部 FrameworkElement（含折叠的元素：步骤可能需要把它们显示出来），广度优先。
    private static IEnumerable<FrameworkElement> AllElements(FrameworkElement root)
    {
        var queue = new Queue<DependencyObject>();
        queue.Enqueue(root);
        while (queue.Count > 0)
        {
            var node = queue.Dequeue();
            if (node is FrameworkElement element) yield return element;
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) queue.Enqueue(VisualTreeHelper.GetChild(node, i));
        }
    }

    private static string? TextOf(FrameworkElement element) => element switch
    {
        TextBlock textBlock => textBlock.Text,
        HeaderedContentControl { Header: string header } => header,
        HeaderedItemsControl { Header: string header } => header,
        ContentControl { Content: string content } => content,
        _ => null,
    };

    // 文本通常在按钮、列表项等的模板里：返回最近的可交互祖先。
    private static FrameworkElement InteractiveAncestor(FrameworkElement element, FrameworkElement root)
    {
        DependencyObject? current = element;
        while (current is not null && !ReferenceEquals(current, root))
        {
            if (current is ButtonBase or ListBoxItem or TabItem or MenuItem or TreeViewItem or ComboBoxItem or Expander) return (FrameworkElement)current;
            current = VisualTreeHelper.GetParent(current);
        }
        return element;
    }

    // ---------- 对话框 ----------

    // 动作期间打开的窗口：WPF 窗口先移到屏外（Loaded 时），截图后关闭；Win32 MessageBox 记录标题与文字后关闭。
    private sealed class DialogWatcher
    {
        private HashSet<Window> before = [];
        private static bool registered;

        public void Begin()
        {
            if (!registered)
            {
                EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent, new RoutedEventHandler(MoveOffscreen));
                registered = true;
            }
            before = new HashSet<Window>(Application.Current.Windows.Cast<Window>());
        }

        private static void MoveOffscreen(object sender, RoutedEventArgs e)
        {
            if (sender is Window window && window.Left > -10000) { window.Left = -20000; window.Top = -20000; }
        }

        public async Task<bool> CloseNewAsync(string stepDir, int dpi, List<object?> reports)
        {
            var closed = false;
            foreach (var window in Application.Current.Windows.Cast<Window>().Where(w => !before.Contains(w)).ToList())
            {
                window.UpdateLayout();
                var path = Path.Combine(stepDir, $"dialog-{reports.Count + 1}.png");
                string? captured = null;
                try
                {
                    var width = (int)Math.Max(1, Math.Ceiling(window.ActualWidth));
                    var height = (int)Math.Max(1, Math.Ceiling(window.ActualHeight));
                    Program.SavePng(Program.RenderRoot(window, width, height, dpi, window.Background), path);
                    captured = path;
                }
                catch (Exception) { }
                reports.Add(Json.Object(("kind", "window"), ("type", window.GetType().FullName), ("title", window.Title), ("snapshot", captured)));
                window.Close();
                closed = true;
            }
            foreach (var (title, text) in NativeDialogs.CloseMessageBoxes())
            {
                reports.Add(Json.Object(("kind", "messageBox"), ("title", title), ("text", text)));
                closed = true;
            }
            if (closed) await IdleAsync();
            return closed;
        }
    }

    private static class NativeDialogs
    {
        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumThreadWindows(int threadId, EnumWindowsProc callback, IntPtr lParam);
        [DllImport("kernel32.dll")] private static extern int GetCurrentThreadId();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);
        private const int WmCommand = 0x0111;

        // 标准对话框类 #32770（MessageBox）。按 取消 → 否 → 确定 的顺序发送命令：只会选择不执行操作的按钮，没有时才确认。
        public static List<(string Title, string Text)> CloseMessageBoxes()
        {
            var found = new List<(string, string)>();
            var handles = new List<IntPtr>();
            EnumThreadWindows(GetCurrentThreadId(), (hwnd, _) =>
            {
                var name = new StringBuilder(64);
                GetClassName(hwnd, name, name.Capacity);
                if (name.ToString() == "#32770" && IsWindowVisible(hwnd)) handles.Add(hwnd);
                return true;
            }, IntPtr.Zero);
            foreach (var hwnd in handles)
            {
                found.Add((Text(hwnd), Text(GetDlgItem(hwnd, 0xFFFF))));
                foreach (var id in new[] { 2, 7, 1 }) PostMessage(hwnd, WmCommand, (IntPtr)id, IntPtr.Zero);
            }
            return found;
        }

        private static string Text(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return "";
            var text = new StringBuilder(1024);
            GetWindowText(hwnd, text, text.Capacity);
            return text.ToString();
        }
    }

    // ---------- 工具 ----------

    private static object? Convert(string? value, Type type, TypeConverter? converter)
    {
        var target = Nullable.GetUnderlyingType(type) ?? type;
        if (value is null) return null;
        if (target == typeof(string) || target == typeof(object)) return value;
        converter ??= TypeDescriptor.GetConverter(target);
        if (converter is null || !converter.CanConvertFrom(typeof(string)))
            throw new InvalidOperationException($"无法把字符串转换为 {target.Name}。");
        try { return converter.ConvertFromInvariantString(value); }
        catch (Exception ex) { throw new InvalidOperationException($"无法把 \"{value}\" 转换为 {target.Name}：{Unwrap(ex).Message}"); }
    }

    private static Task IdleAsync() => Dispatcher.CurrentDispatcher.InvokeAsync(() => { }, DispatcherPriority.ContextIdle).Task;

    private static string Required(string? value, string name) =>
        string.IsNullOrEmpty(value) ? throw new InvalidOperationException($"缺少 {name}。") : value!;

    private static Exception Unwrap(Exception ex) => ex is TargetInvocationException { InnerException: { } inner } ? Unwrap(inner) : ex;

    private static string Summary(string message) =>
        BindingIssues.Describe(message).FirstOrDefault(pair => pair.Key == "summary").Value as string ?? message;

    private static string? Field(List<KeyValuePair<string, object?>> fields, string key) => fields.FirstOrDefault(pair => pair.Key == key).Value as string;

    private static string TypeName(FrameworkElement element) =>
        element.GetType().Name + (string.IsNullOrEmpty(element.Name) ? "" : "#" + element.Name);

    private static string Describe(ElementSelector selector) => string.Join(" ", new[]
    {
        selector.Name is null ? null : "name=" + selector.Name,
        selector.AutomationId is null ? null : "automationId=" + selector.AutomationId,
        selector.Type is null ? null : "type=" + selector.Type,
        selector.Text is null ? null : "text=" + selector.Text,
        selector.Index is null ? null : "index=" + selector.Index,
    }.Where(part => part is not null));

    private static string SafeName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var cleaned = new string(name.Select(c => invalid.Contains(c) || char.IsWhiteSpace(c) ? '_' : c).ToArray());
        return cleaned.Length > 40 ? cleaned.Substring(0, 40) : cleaned;
    }
}

// harness.json 中的步骤配置（由 scripts/Steps.ps1 规范化后写入）。
[DataContract]
internal sealed class StepsConfig
{
    [DataMember(Name = "steps")] public List<StepConfig>? Steps { get; set; }
    [DataMember(Name = "continueOnError")] public bool? ContinueOnError { get; set; }
    // live（默认）或 settle。
    [DataMember(Name = "animations")] public string? Animations { get; set; }

    public static StepsConfig? Load(string? path)
    {
        if (path is null || !File.Exists(path)) return null;
        using var stream = File.OpenRead(path);
        var config = (StepsConfig?)new DataContractJsonSerializer(typeof(StepsConfig)).ReadObject(stream);
        return config?.Steps is { Count: > 0 } ? config : null;
    }
}

[DataContract]
internal sealed class StepConfig
{
    [DataMember(Name = "name")] public string? Name { get; set; }
    // null（只截图）/ set / setData / invoke / command / state / focus / animate / custom
    [DataMember(Name = "action")] public string? Action { get; set; }
    [DataMember(Name = "element")] public ElementSelector? Element { get; set; }
    [DataMember(Name = "property")] public string? Property { get; set; }
    [DataMember(Name = "value")] public string? Value { get; set; }
    // value 为 JSON null：清除本地值。
    [DataMember(Name = "clear")] public bool? Clear { get; set; }
    [DataMember(Name = "path")] public string? Path { get; set; }
    [DataMember(Name = "parameter")] public string? Parameter { get; set; }
    [DataMember(Name = "state")] public string? State { get; set; }
    [DataMember(Name = "storyboard")] public string? Storyboard { get; set; }
    [DataMember(Name = "trigger")] public string? Trigger { get; set; }
    [DataMember(Name = "atMs")] public int[]? AtMs { get; set; }
    [DataMember(Name = "customAction")] public string? CustomAction { get; set; }
    [DataMember(Name = "args")] public List<StepArg>? Args { get; set; }
    [DataMember(Name = "waitMs")] public int? WaitMs { get; set; }
    [DataMember(Name = "waitFor")] public string? WaitFor { get; set; }
    [DataMember(Name = "timeoutMs")] public int? TimeoutMs { get; set; }
    [DataMember(Name = "capture")] public bool? Capture { get; set; }
}

[DataContract]
internal sealed class ElementSelector
{
    [DataMember(Name = "name")] public string? Name { get; set; }
    [DataMember(Name = "automationId")] public string? AutomationId { get; set; }
    [DataMember(Name = "text")] public string? Text { get; set; }
    [DataMember(Name = "type")] public string? Type { get; set; }
    [DataMember(Name = "index")] public int? Index { get; set; }
}

[DataContract]
internal sealed class StepArg
{
    [DataMember(Name = "key")] public string? Key { get; set; }
    [DataMember(Name = "value")] public string? Value { get; set; }
}
