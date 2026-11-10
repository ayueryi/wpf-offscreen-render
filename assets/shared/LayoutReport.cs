using System.Globalization;

// layout.json 的报告壳：节点与问题的 JSON 字段、五类问题的阈值与提示、上限。
// 不依赖任何 UI 框架的类型：宿主把坐标换算成普通数字交进来，遍历与文本测量留在各自的 adapter。
// 只用 .NET Framework 4.7.2 与 .NET 5+ 共有的 API。
internal sealed class LayoutReportBuilder
{
    internal const int MaxNodes = 3000;
    internal const int MaxOverlapCandidates = 400;
    internal const double Tolerance = 1.0;

    private readonly List<object?> nodes = new();
    private readonly List<object?> issues = new();
    private readonly List<(string Label, double X, double Y, double Width, double Height)> inks = new();
    private bool truncated;

    internal bool NodesFull => nodes.Count >= MaxNodes;
    internal bool OverlapsFull => inks.Count >= MaxOverlapCandidates;

    internal void AddNode(int depth, string type, string? name, double x, double y, double width, double height, string? text)
    {
        if (NodesFull) { truncated = true; return; }
        nodes.Add(Json.Object(("depth", depth), ("type", type), ("name", string.IsNullOrEmpty(name) ? null : name),
            ("rect", Box(x, y, width, height)), ("text", Shorten(text, 80))));
    }

    // 控件外壳被压成 0 不报：模板化控件的外壳可能因父容器压缩为 0，只报真正的内容。
    internal void ZeroSize(bool isControl, string label, double width, double height, double x, double y, double boundsWidth, double boundsHeight)
    {
        if (isControl || width >= 0.5 && height >= 0.5) return;
        Issue("zero-size", label, $"布局尺寸为 {Size(width, height)}，内容不可见", x, y, boundsWidth, boundsHeight);
    }

    internal void Clipped(string label, double neededWidth, double neededHeight, double visibleWidth, double visibleHeight,
        double x, double y, double width, double height) =>
        Issue("clipped", label, $"被布局空间裁切：需要 {Size(neededWidth, neededHeight)}，可见 {Size(visibleWidth, visibleHeight)}", x, y, width, height);

    internal void OutOfViewport(string label, double viewportWidth, double viewportHeight, double x, double y, double width, double height) =>
        Issue("out-of-viewport", label, $"超出 {Size(viewportWidth, viewportHeight)} 视口", x, y, width, height);

    internal void TextTruncated(string label, bool wrapped, double needed, double available, bool trimmed,
        double x, double y, double width, double height)
    {
        var trimming = trimmed ? "（已显示省略号）" : "";
        var message = wrapped
            ? $"换行后需要高度 {Number(needed)}，可用 {Number(available)}{trimming}"
            : $"文本需要宽度 {Number(needed)}，可用 {Number(available)}{trimming}";
        Issue("text-truncated", label, message, x, y, width, height);
    }

    // 文本墨迹的矩形，已经是截图坐标。空矩形不记。
    internal void AddInk(string label, double x, double y, double width, double height)
    {
        if (OverlapsFull || width <= 0 || height <= 0) return;
        inks.Add((label, x, y, width, height));
    }

    internal (List<KeyValuePair<string, object?>> Report, int IssueCount) Build(double viewportWidth, double viewportHeight)
    {
        for (var i = 0; i < inks.Count; i++)
        {
            for (var j = i + 1; j < inks.Count; j++)
            {
                var overlap = Intersection(inks[i], inks[j]);
                if (overlap is not { } hit) continue;
                var area = hit.Width * hit.Height;
                var smaller = Math.Min(inks[i].Width * inks[i].Height, inks[j].Width * inks[j].Height);
                if (area > 4 && area > smaller * 0.15)
                    Issue("overlap", inks[i].Label, $"与 {inks[j].Label} 的文本重叠 {Size(hit.Width, hit.Height)}", hit.X, hit.Y, hit.Width, hit.Height);
            }
        }
        return (Json.Object(("viewport", Box(0, 0, viewportWidth, viewportHeight)), ("nodeCount", nodes.Count), ("nodesTruncated", truncated),
            ("issueCount", issues.Count), ("issues", issues), ("nodes", nodes)), issues.Count);
    }

    internal static string Label(string typeName, string? name, string? text)
    {
        var label = typeName + (string.IsNullOrEmpty(name) ? "" : "#" + name);
        return string.IsNullOrEmpty(text) ? label : $"{label}「{Shorten(text, 30)}」";
    }

    // 框架内置类型用短名，业务类型用全名。
    internal static string TypeName(Type type, string frameworkNamespace) =>
        type.Namespace?.StartsWith(frameworkNamespace, StringComparison.Ordinal) == true ? type.Name : type.FullName ?? type.Name;

    internal static string? Shorten(string? text, int length)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var single = text!.Replace('\r', ' ').Replace('\n', ' ');
        return single.Length <= length ? single : single.Substring(0, length) + "…";
    }

    internal static string Number(double value) => Math.Round(value, 1).ToString(CultureInfo.InvariantCulture);
    internal static string Size(double width, double height) => $"{Number(width)}×{Number(height)}";

    private void Issue(string kind, string label, string message, double x, double y, double width, double height) =>
        issues.Add(Json.Object(("kind", kind), ("element", label), ("message", message), ("rect", Box(x, y, width, height))));

    private static double[] Box(double x, double y, double width, double height) =>
        width <= 0 || height <= 0 ? new double[0] : new[] { Math.Round(x, 1), Math.Round(y, 1), Math.Round(width, 1), Math.Round(height, 1) };

    private static (double X, double Y, double Width, double Height)? Intersection(
        (string Label, double X, double Y, double Width, double Height) a,
        (string Label, double X, double Y, double Width, double Height) b)
    {
        var x = Math.Max(a.X, b.X);
        var y = Math.Max(a.Y, b.Y);
        var width = Math.Min(a.X + a.Width, b.X + b.Width) - x;
        var height = Math.Min(a.Y + a.Height, b.Y + b.Height) - y;
        return width <= 0 || height <= 0 ? null : (x, y, width, height);
    }
}
