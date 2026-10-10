using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

// 把 WPF 绑定 trace 文本拆成目标元素、属性、路径与数据源，供摘要直接给出可读结论。
internal static class BindingIssues
{
    private static readonly Regex PathPattern = new(@"BindingExpression:Path=(?<v>[^;]*);");
    private static readonly Regex DataItemPattern = new(@"DataItem=(?:'(?<v>[^']*)'|(?<v>null))");
    private static readonly Regex TargetPattern = new(@"target element is '(?<type>[^']*)' \(Name='(?<name>[^']*)'\)");
    private static readonly Regex PropertyPattern = new(@"target property is '(?<v>[^']*)'");
    private static readonly Regex HashCodePattern = new(@" \(HashCode=\d+\)");

    public static List<KeyValuePair<string, object?>> Describe(string message)
    {
        string? Find(Regex pattern, string group = "v")
        {
            var match = pattern.Match(message);
            return match.Success ? match.Groups[group].Value : null;
        }
        var cut = message.IndexOf(" BindingExpression:", StringComparison.Ordinal);
        var reason = HashCodePattern.Replace(cut > 0 ? message.Substring(0, cut) : message, "").TrimEnd(' ', ';', '.');
        var path = Find(PathPattern);
        var dataItem = Find(DataItemPattern) is { } item && item != "null" ? item : null;
        var element = Find(TargetPattern, "type");
        var name = Find(TargetPattern, "name");
        var property = Find(PropertyPattern);
        var summary = element is null
            ? reason
            : $"{element}{(string.IsNullOrEmpty(name) ? "" : "#" + name)}.{property ?? "?"} <- Path={path ?? "?"}{(dataItem is null ? "" : $"（数据源 {dataItem}）")}：{reason}";
        return Json.Object(("summary", summary), ("reason", reason), ("path", path), ("dataItem", dataItem),
            ("targetElement", element), ("targetName", string.IsNullOrEmpty(name) ? null : name), ("targetProperty", property),
            ("message", message));
    }
}

// 遍历视觉树，输出每个元素的位置尺寸，并检查文本截断、被裁切、尺寸为 0、超出视口与文本重叠。
// 检查只针对内容元素（有文本的 TextBlock、有图像的 Image、Control），容器本身不报告，以减少误报。
internal static class LayoutReport
{
    private const int MaxNodes = 3000;
    private const int MaxOverlapCandidates = 400;
    private const double Tolerance = 1.0;
    // 足够大的有限矩形表示“无裁切”；用无穷大会在求交时产生 NaN。
    private static readonly Rect Unbounded = new(-1e7, -1e7, 2e7, 2e7);

    private sealed class Ink
    {
        public Ink(string label, Rect rect) { Label = label; Rect = rect; }
        public string Label { get; }
        public Rect Rect { get; }
    }

    public static (List<KeyValuePair<string, object?>> Report, int IssueCount) Inspect(FrameworkElement root, double width, double height, double pixelsPerDip)
    {
        var nodes = new List<object?>();
        var issues = new List<object?>();
        var inks = new List<Ink>();
        var viewport = new Rect(0, 0, width, height);
        var truncated = false;

        void Report(string kind, string label, string message, Rect rect) =>
            issues.Add(Json.Object(("kind", kind), ("element", label), ("message", message), ("rect", Box(rect))));

        // clip：所有祖先裁切的交集；overflowClip：只算布局溢出造成的裁切（排除 ScrollViewer 视口、ClipToBounds、显式 Clip）。
        // placementReported：祖先已报告裁切 / 超出视口时，后代不再重复报告。
        void Walk(DependencyObject node, int depth, Rect clip, Rect overflowClip, bool placementReported)
        {
            if (node is FrameworkElement element)
            {
                if (element.Visibility != Visibility.Visible) return;
                Rect bounds;
                GeneralTransform toRoot;
                try
                {
                    toRoot = ReferenceEquals(element, root) ? Transform.Identity : element.TransformToAncestor(root);
                    bounds = toRoot.TransformBounds(new Rect(element.RenderSize));
                }
                catch (InvalidOperationException) { return; }

                var layoutClip = LayoutInformation.GetLayoutClip(element);
                if (layoutClip is not null && !layoutClip.Bounds.IsEmpty)
                {
                    var clipInRoot = toRoot.TransformBounds(layoutClip.Bounds);
                    clip = Rect.Intersect(clip, clipInRoot);
                    var intended = element.ClipToBounds || element.Clip is not null || element is ScrollContentPresenter;
                    if (!intended) overflowClip = Rect.Intersect(overflowClip, clipInRoot);
                }

                var label = Label(element);
                var text = (element as TextBlock)?.Text;
                var isContent = element is TextBlock { Text.Length: > 0 } || element is Image { Source: not null } || element is Control;
                if (nodes.Count < MaxNodes)
                {
                    nodes.Add(Json.Object(("depth", depth), ("type", TypeName(element)), ("name", string.IsNullOrEmpty(element.Name) ? null : element.Name),
                        ("rect", Box(bounds)), ("text", Shorten(text, 80))));
                }
                else truncated = true;

                if (isContent)
                {
                    var visible = Rect.Intersect(bounds, clip);
                    if (element.ActualWidth < 0.5 || element.ActualHeight < 0.5)
                    {
                        if (element is not Control) Report("zero-size", label, $"尺寸为 {Size(element.ActualWidth, element.ActualHeight)}，内容不可见", bounds);
                    }
                    else if (!visible.IsEmpty && !placementReported)
                    {
                        var kept = Rect.Intersect(bounds, overflowClip);
                        if (kept.IsEmpty || kept.Width < bounds.Width - Tolerance || kept.Height < bounds.Height - Tolerance)
                        {
                            Report("clipped", label, $"被布局空间裁切：需要 {Size(bounds.Width, bounds.Height)}，可见 {(kept.IsEmpty ? "0×0" : Size(kept.Width, kept.Height))}", bounds);
                            placementReported = true;
                        }
                        else if (visible.Left < -Tolerance || visible.Top < -Tolerance
                            || visible.Right > viewport.Right + Tolerance || visible.Bottom > viewport.Bottom + Tolerance)
                        {
                            Report("out-of-viewport", label, $"超出 {Size(width, height)} 视口", bounds);
                            placementReported = true;
                        }
                    }

                    if (element is TextBlock textBlock && textBlock.Text.Length > 0 && element.ActualWidth >= 0.5)
                    {
                        var ink = CheckText(textBlock, pixelsPerDip, label, Report);
                        if (!visible.IsEmpty && inks.Count < MaxOverlapCandidates)
                        {
                            var inkInRoot = Rect.Intersect(toRoot.TransformBounds(ink), clip);
                            if (!inkInRoot.IsEmpty) inks.Add(new Ink(label, inkInRoot));
                        }
                    }
                }
            }

            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < count; i++)
                Walk(VisualTreeHelper.GetChild(node, i), node is FrameworkElement ? depth + 1 : depth, clip, overflowClip, placementReported);
        }

        Walk(root, 0, Unbounded, Unbounded, false);

        // 文本墨迹互相覆盖通常是布局错误（同一单元格、负边距、绝对定位冲突）。
        for (var i = 0; i < inks.Count; i++)
        {
            for (var j = i + 1; j < inks.Count; j++)
            {
                var overlap = Rect.Intersect(inks[i].Rect, inks[j].Rect);
                if (overlap.IsEmpty) continue;
                var area = overlap.Width * overlap.Height;
                var smaller = Math.Min(Area(inks[i].Rect), Area(inks[j].Rect));
                if (area > 4 && area > smaller * 0.15)
                    Report("overlap", inks[i].Label, $"与 {inks[j].Label} 的文本重叠 {Size(overlap.Width, overlap.Height)}", overlap);
            }
        }

        var report = Json.Object(("viewport", Box(viewport)), ("nodeCount", nodes.Count), ("nodesTruncated", truncated),
            ("issueCount", issues.Count), ("issues", issues), ("nodes", nodes));
        return (report, issues.Count);
    }

    // 检查文本是否放得下，返回文本墨迹在元素坐标中的矩形（用于重叠检查）。
    private static Rect CheckText(TextBlock textBlock, double pixelsPerDip, string label, Action<string, string, string, Rect> report)
    {
        var padding = textBlock.Padding;
        var available = Math.Max(0, textBlock.ActualWidth - padding.Left - padding.Right);
        var availableHeight = Math.Max(0, textBlock.ActualHeight - padding.Top - padding.Bottom);
        var formatted = new FormattedText(textBlock.Text, CultureInfo.CurrentUICulture, textBlock.FlowDirection,
            new Typeface(textBlock.FontFamily, textBlock.FontStyle, textBlock.FontWeight, textBlock.FontStretch),
            textBlock.FontSize, Brushes.Black, pixelsPerDip);
        var trimming = textBlock.TextTrimming == TextTrimming.None ? "" : "（已显示省略号）";
        var bounds = new Rect(textBlock.RenderSize);
        if (textBlock.TextWrapping == TextWrapping.NoWrap)
        {
            if (formatted.WidthIncludingTrailingWhitespace > available + Tolerance)
                report("text-truncated", label, $"文本需要宽度 {Number(formatted.WidthIncludingTrailingWhitespace)}，可用 {Number(available)}{trimming}", bounds);
        }
        else
        {
            formatted.MaxTextWidth = Math.Max(available, 1);
            if (formatted.Height > availableHeight + Tolerance)
                report("text-truncated", label, $"换行后需要高度 {Number(formatted.Height)}，可用 {Number(availableHeight)}{trimming}", bounds);
        }
        var inkWidth = Math.Min(formatted.Width, available);
        var offset = textBlock.TextAlignment switch
        {
            TextAlignment.Center => (available - inkWidth) / 2,
            TextAlignment.Right => available - inkWidth,
            _ => 0
        };
        return new Rect(padding.Left + offset, padding.Top, inkWidth, Math.Min(formatted.Height, availableHeight));
    }

    private static string Label(FrameworkElement element)
    {
        var label = TypeName(element) + (string.IsNullOrEmpty(element.Name) ? "" : "#" + element.Name);
        var text = element switch
        {
            TextBlock textBlock => textBlock.Text,
            ContentControl { Content: string content } => content,
            _ => null
        };
        return string.IsNullOrEmpty(text) ? label : $"{label}「{Shorten(text, 30)}」";
    }

    // WPF 内置类型用短名，业务类型用全名。
    private static string TypeName(FrameworkElement element)
    {
        var type = element.GetType();
        return type.Namespace?.StartsWith("System.Windows", StringComparison.Ordinal) == true ? type.Name : type.FullName ?? type.Name;
    }

    private static string? Shorten(string? text, int length)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var single = text!.Replace('\r', ' ').Replace('\n', ' ');
        return single.Length <= length ? single : single.Substring(0, length) + "…";
    }

    private static double Area(Rect rect) => rect.Width * rect.Height;
    private static double[] Box(Rect rect) => rect.IsEmpty ? [] : [Round(rect.X), Round(rect.Y), Round(rect.Width), Round(rect.Height)];
    private static double Round(double value) => Math.Round(value, 1);
    private static string Number(double value) => Round(value).ToString(CultureInfo.InvariantCulture);
    private static string Size(double width, double height) => $"{Number(width)}×{Number(height)}";
}
