using System.Globalization;
using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Presenters;
using Avalonia.Controls.Primitives;
using Avalonia.Media;
using Avalonia.VisualTree;

// 把 Avalonia 的绑定日志拆成目标属性、路径与数据源，供摘要直接给出可读结论。
// 日志模板形如：An error occurred binding Text to Path at Path: Could not find a matching property accessor for 'Path' on 'Type'.
internal static class BindingIssues
{
    private static readonly Regex BindingPattern = new(@"binding (?<property>\S+) to (?<path>.+?) at .*?: (?<reason>.*)$", RegexOptions.Singleline);
    private static readonly Regex DataItemPattern = new(@" on '(?<v>[^']*)'");

    public static List<KeyValuePair<string, object?>> Describe(string message)
    {
        var match = BindingPattern.Match(message);
        if (!match.Success)
        {
            return Json.Object(("summary", message), ("reason", message), ("path", null), ("dataItem", null),
                ("targetElement", null), ("targetName", null), ("targetProperty", null), ("message", message));
        }
        var property = match.Groups["property"].Value;
        var path = match.Groups["path"].Value;
        var reason = match.Groups["reason"].Value.TrimEnd(' ', ';', '.');
        var dataItem = DataItemPattern.Match(reason) is { Success: true } item ? item.Groups["v"].Value : null;
        var summary = $"{property} <- Path={path}{(dataItem is null ? "" : $"（数据源 {dataItem}）")}：{reason}";
        return Json.Object(("summary", summary), ("reason", reason), ("path", path), ("dataItem", dataItem),
            ("targetElement", null), ("targetName", null), ("targetProperty", property), ("message", message));
    }
}

// 遍历视觉树，输出每个元素的位置尺寸，并检查文本截断、被裁切、尺寸为 0、超出视口与文本重叠。
// 报告里的矩形都是相对根元素（即截图）的 DIP 坐标，节点按深度优先排列并带 depth，与 WPF 宿主的 layout.json 契约一致；
// 不计入渲染变换（RenderTransform 等）。
internal static class LayoutReport
{
    private const int MaxNodes = 3000;
    private const int MaxOverlapCandidates = 400;
    private const double Tolerance = 1.0;
    // 足够大的有限矩形表示“无裁切”。
    private static readonly Rect Unbounded = new(-1e7, -1e7, 2e7, 2e7);

    private sealed record Ink(string Label, Rect Rect);

    public static (List<KeyValuePair<string, object?>> Report, int IssueCount) Inspect(Control root, double width, double height)
    {
        var nodes = new List<object?>();
        var issues = new List<object?>();
        var inks = new List<Ink>();
        var viewport = new Rect(0, 0, width, height);
        var truncated = false;

        void Report(string kind, string label, string message, Rect rect) =>
            issues.Add(Json.Object(("kind", kind), ("element", label), ("message", message), ("rect", Box(rect))));

        // overflowClip：祖先中会裁切子元素的布局溢出（ClipToBounds）的交集；ScrollViewer 视口是有意裁切，不计入。
        void Walk(Visual node, int depth, Rect overflowClip, bool placementReported)
        {
            if (node is Control element)
            {
                if (!element.IsVisible) return;
                var rect = AbsoluteRect(element, root);
                var label = Label(element);
                var text = (element as TextBlock)?.Text;
                if (nodes.Count < MaxNodes)
                {
                    nodes.Add(Json.Object(("depth", depth), ("type", TypeName(element)),
                        ("name", string.IsNullOrEmpty(element.Name) ? null : element.Name), ("rect", Box(rect)), ("text", Shorten(text, 80))));
                }
                else truncated = true;

                var isContent = element is TextBlock { Text.Length: > 0 } || element is Image { Source: not null } || element is TemplatedControl;
                if (isContent)
                {
                    if (rect.Width < 0.5 || rect.Height < 0.5)
                    {
                        // 模板化控件的外壳可能因父容器压缩为 0；与 WPF 一致，只对非 Control 内容报 zero-size 之外的情形留给文本检查。
                        Report("zero-size", label, $"布局尺寸为 {Size(rect.Width, rect.Height)}，内容不可见", rect);
                    }
                    else if (!placementReported)
                    {
                        if (!Contains(overflowClip, rect))
                        {
                            Report("clipped", label, $"被祖先裁切：元素 {Size(rect.Width, rect.Height)}，可见区域 {Describe(overflowClip.Intersect(rect))}", rect);
                            placementReported = true;
                        }
                        else if (rect.X < -Tolerance || rect.Y < -Tolerance || rect.Right > viewport.Right + Tolerance || rect.Bottom > viewport.Bottom + Tolerance)
                        {
                            Report("out-of-viewport", label, $"超出 {Size(width, height)} 视口", rect);
                            placementReported = true;
                        }
                    }

                    if (element is TextBlock { Text.Length: > 0 } textBlock && rect.Width >= 0.5 && rect.Height >= 0.5)
                    {
                        var ink = CheckText(textBlock, rect, label, Report);
                        if (ink is { } inkRect && inks.Count < MaxOverlapCandidates) inks.Add(new Ink(label, inkRect));
                    }
                }

                // 裁切祖先：ClipToBounds 的元素（非滚动视口）把后代限制在自己的矩形内。
                if (element.ClipToBounds && element is not ScrollViewer and not ScrollContentPresenter)
                    overflowClip = overflowClip.Intersect(rect);
            }

            foreach (var child in node.GetVisualChildren())
                Walk(child, depth + 1, overflowClip, placementReported);
        }

        Walk(root, 0, Unbounded, false);

        // 文本墨迹互相覆盖通常是布局错误（同一单元格、负边距、绝对定位冲突）。
        for (var i = 0; i < inks.Count; i++)
        {
            for (var j = i + 1; j < inks.Count; j++)
            {
                var overlap = inks[i].Rect.Intersect(inks[j].Rect);
                if (overlap.Width <= 0 || overlap.Height <= 0) continue;
                var area = overlap.Width * overlap.Height;
                var smaller = Math.Min(Area(inks[i].Rect), Area(inks[j].Rect));
                if (area > 4 && area > smaller * 0.15)
                    Report("overlap", inks[i].Label, $"与 {inks[j].Label} 的文本重叠 {Size(overlap.Width, overlap.Height)}", overlap);
            }
        }

        return (Json.Object(("viewport", Box(viewport)), ("nodeCount", nodes.Count), ("nodesTruncated", truncated),
            ("issueCount", issues.Count), ("issues", issues), ("nodes", nodes)), issues.Count);
    }

    // 元素在根元素（截图）坐标系中的矩形。Bounds 是相对父元素的，不能直接用。
    private static Rect AbsoluteRect(Control element, Control root)
    {
        if (ReferenceEquals(element, root)) return new Rect(0, 0, element.Bounds.Width, element.Bounds.Height);
        var origin = element.TranslatePoint(new Point(0, 0), root) ?? new Point(element.Bounds.X, element.Bounds.Y);
        return new Rect(origin, element.Bounds.Size);
    }

    // 检查文本是否放得下，返回文本墨迹在截图坐标中的矩形（用于重叠检查）；无法测量时返回 null。
    private static Rect? CheckText(TextBlock textBlock, Rect rect, string label, Action<string, string, string, Rect> report)
    {
        try
        {
            var padding = textBlock.Padding;
            var available = Math.Max(0, rect.Width - padding.Left - padding.Right);
            var availableHeight = Math.Max(0, rect.Height - padding.Top - padding.Bottom);
            var formatted = new FormattedText(textBlock.Text!, CultureInfo.CurrentUICulture, textBlock.FlowDirection,
                new Typeface(textBlock.FontFamily, textBlock.FontStyle, textBlock.FontWeight, textBlock.FontStretch),
                textBlock.FontSize, Brushes.Black);
            var trimming = textBlock.TextTrimming == TextTrimming.None ? "" : "（已显示省略号）";
            if (textBlock.TextWrapping == TextWrapping.NoWrap)
            {
                if (formatted.Width > available + Tolerance)
                    report("text-truncated", label, $"文本需要宽度 {Number(formatted.Width)}，可用 {Number(available)}{trimming}", rect);
            }
            else
            {
                formatted.MaxTextWidth = Math.Max(available, 1);
                if (formatted.Height > availableHeight + Tolerance)
                    report("text-truncated", label, $"换行后需要高度 {Number(formatted.Height)}，可用 {Number(availableHeight)}{trimming}", rect);
            }
            var inkWidth = Math.Min(formatted.Width, available);
            var offset = textBlock.TextAlignment switch
            {
                TextAlignment.Center => (available - inkWidth) / 2,
                TextAlignment.Right or TextAlignment.End => available - inkWidth,
                _ => 0
            };
            return new Rect(rect.X + padding.Left + offset, rect.Y + padding.Top, inkWidth, Math.Min(formatted.Height, availableHeight));
        }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    // inner 是否（在容差内）完全位于 clip 之内。
    private static bool Contains(Rect clip, Rect inner) =>
        inner.X >= clip.X - Tolerance && inner.Y >= clip.Y - Tolerance
        && inner.Right <= clip.Right + Tolerance && inner.Bottom <= clip.Bottom + Tolerance;

    private static string Label(Control element)
    {
        var label = TypeName(element) + (string.IsNullOrEmpty(element.Name) ? "" : "#" + element.Name);
        var text = element is TextBlock textBlock ? textBlock.Text : element is ContentControl { Content: string content } ? content : null;
        return string.IsNullOrEmpty(text) ? label : $"{label}「{Shorten(text, 30)}」";
    }

    private static string TypeName(Control element) => element.GetType().Namespace?.StartsWith("Avalonia", StringComparison.Ordinal) == true
        ? element.GetType().Name : element.GetType().FullName ?? element.GetType().Name;

    private static string? Shorten(string? text, int length)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var single = text.Replace('\r', ' ').Replace('\n', ' ');
        return single.Length <= length ? single : single[..length] + "…";
    }

    private static double Area(Rect rect) => rect.Width * rect.Height;
    private static double[] Box(Rect rect) => rect.Width <= 0 || rect.Height <= 0 ? [] : [Round(rect.X), Round(rect.Y), Round(rect.Width), Round(rect.Height)];
    private static string Describe(Rect rect) => rect.Width <= 0 || rect.Height <= 0 ? "0×0" : Size(rect.Width, rect.Height);
    private static double Round(double value) => Math.Round(value, 1);
    private static string Number(double value) => Round(value).ToString(CultureInfo.InvariantCulture);
    private static string Size(double width, double height) => $"{Number(width)}×{Number(height)}";
}
