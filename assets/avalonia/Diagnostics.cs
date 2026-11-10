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
    private const double Tolerance = LayoutReportBuilder.Tolerance;
    // 足够大的有限矩形表示“无裁切”。
    private static readonly Rect Unbounded = new(-1e7, -1e7, 2e7, 2e7);

    public static (List<KeyValuePair<string, object?>> Report, int IssueCount) Inspect(Control root, double width, double height)
    {
        var report = new LayoutReportBuilder();

        // overflowClip：祖先中会裁切子元素的布局溢出（ClipToBounds）的交集；ScrollViewer 视口是有意裁切，不计入。
        void Walk(Visual node, int depth, Rect overflowClip, bool placementReported)
        {
            if (node is Control element)
            {
                if (!element.IsVisible) return;
                var rect = AbsoluteRect(element, root);
                var label = Label(element);
                var text = (element as TextBlock)?.Text;
                report.AddNode(depth, TypeName(element), element.Name, rect.X, rect.Y, rect.Width, rect.Height, text);

                var isContent = element is TextBlock { Text.Length: > 0 } || element is Image { Source: not null } || element is TemplatedControl;
                if (isContent)
                {
                    if (rect.Width < 0.5 || rect.Height < 0.5)
                    {
                        // 模板化控件的外壳可能因父容器压缩为 0，与 WPF 一致不报；只报真正的内容。
                        report.ZeroSize(element is TemplatedControl, label, rect.Width, rect.Height, rect.X, rect.Y, rect.Width, rect.Height);
                    }
                    else if (!placementReported)
                    {
                        var shown = overflowClip.Intersect(rect);
                        if (!Contains(overflowClip, rect))
                        {
                            report.Clipped(label, rect.Width, rect.Height, Positive(shown.Width), Positive(shown.Height), rect.X, rect.Y, rect.Width, rect.Height);
                            placementReported = true;
                        }
                        else if (rect.X < -Tolerance || rect.Y < -Tolerance || rect.Right > width + Tolerance || rect.Bottom > height + Tolerance)
                        {
                            report.OutOfViewport(label, width, height, rect.X, rect.Y, rect.Width, rect.Height);
                            placementReported = true;
                        }
                    }

                    if (element is TextBlock { Text.Length: > 0 } textBlock && rect.Width >= 0.5 && rect.Height >= 0.5)
                    {
                        var ink = CheckText(textBlock, rect, label, report);
                        if (ink is { } inkRect) report.AddInk(label, inkRect.X, inkRect.Y, inkRect.Width, inkRect.Height);
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
        return report.Build(width, height);
    }

    // 元素在根元素（截图）坐标系中的矩形。Bounds 是相对父元素的，不能直接用。
    private static Rect AbsoluteRect(Control element, Control root)
    {
        if (ReferenceEquals(element, root)) return new Rect(0, 0, element.Bounds.Width, element.Bounds.Height);
        var origin = element.TranslatePoint(new Point(0, 0), root) ?? new Point(element.Bounds.X, element.Bounds.Y);
        return new Rect(origin, element.Bounds.Size);
    }

    // 检查文本是否放得下，返回文本墨迹在截图坐标中的矩形（用于重叠检查）；无法测量时返回 null。
    private static Rect? CheckText(TextBlock textBlock, Rect rect, string label, LayoutReportBuilder report)
    {
        try
        {
            var padding = textBlock.Padding;
            var available = Math.Max(0, rect.Width - padding.Left - padding.Right);
            var availableHeight = Math.Max(0, rect.Height - padding.Top - padding.Bottom);
            var formatted = new FormattedText(textBlock.Text!, CultureInfo.CurrentUICulture, textBlock.FlowDirection,
                new Typeface(textBlock.FontFamily, textBlock.FontStyle, textBlock.FontWeight, textBlock.FontStretch),
                textBlock.FontSize, Brushes.Black);
            if (textBlock.TextWrapping == TextWrapping.NoWrap)
            {
                if (formatted.Width > available + Tolerance)
                    report.TextTruncated(label, wrapped: false, formatted.Width, available, textBlock.TextTrimming != TextTrimming.None,
                        rect.X, rect.Y, rect.Width, rect.Height);
            }
            else
            {
                formatted.MaxTextWidth = Math.Max(available, 1);
                if (formatted.Height > availableHeight + Tolerance)
                    report.TextTruncated(label, wrapped: true, formatted.Height, availableHeight, textBlock.TextTrimming != TextTrimming.None,
                        rect.X, rect.Y, rect.Width, rect.Height);
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

    private static string Label(Control element) => LayoutReportBuilder.Label(TypeName(element), element.Name,
        element is TextBlock textBlock ? textBlock.Text : element is ContentControl { Content: string content } ? content : null);

    private static string TypeName(Control element) => LayoutReportBuilder.TypeName(element.GetType(), "Avalonia");

    private static double Positive(double value) => value > 0 ? value : 0;
}
