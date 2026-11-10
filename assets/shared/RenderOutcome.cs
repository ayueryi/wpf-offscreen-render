using System.Globalization;
using System.Reflection;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

// 结果清单的写端：字段名与顺序、像素换算、绑定结果落盘、退出码含义。
// WPF 与 Avalonia 宿主只交自己的事实（实际尺寸、mode、steps、warning），不再各自拼一份 manifest。
// 只用 .NET Framework 4.7.2 与 .NET 5+ 共有的 API，随 assets/shared 一起拷进两个宿主工程。
internal static class RenderOutcome
{
    // 与 references/cli.md 的退出码表一致：0 成功，1 失败，2 有真实绑定问题，3 交互步骤失败。
    internal const int ExitOk = 0;
    internal const int ExitFailed = 1;
    internal const int ExitBindingIssues = 2;
    internal const int ExitStepFailed = 3;

    // 优先级从高到低：自检未命中、某一步失败、有绑定问题、全部通过。
    internal static int ResolveExitCode(bool selfCheckHit, bool stepsFailed, int bindingIssueCount) =>
        !selfCheckHit ? ExitFailed : stepsFailed ? ExitStepFailed : bindingIssueCount > 0 ? ExitBindingIssues : ExitOk;

    internal static int PixelSize(int dip, int dpi) => (int)Math.Ceiling(dip * dpi / 96.0);

    // 公共字段按固定顺序排好。head 插在最前（Avalonia 的 stack），
    // middle 插在 element 与 image 之间（WPF 的 steps），tail 追在最后（warning、note）。
    internal static List<KeyValuePair<string, object?>> BuildManifest(
        IEnumerable<KeyValuePair<string, object?>>? head,
        string? toolVersion, string mode, string? sourceViewType, string theme,
        int width, int height, int dpi, double actualWidthDip, double actualHeightDip,
        string? background, string backgroundSource,
        bool selfCheckHit, int? layoutIssueCount, string? layoutReportError,
        string? element, double[]? elementRect, string? elementError,
        IEnumerable<KeyValuePair<string, object?>>? middle,
        string sha256,
        IEnumerable<KeyValuePair<string, object?>>? tail)
    {
        var fields = new List<KeyValuePair<string, object?>>();
        if (head is not null) fields.AddRange(head);
        fields.AddRange(new KeyValuePair<string, object?>[]
        {
            new("generatedAt", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture)),
            new("toolVersion", toolVersion),
            new("mode", mode),
            new("sourceViewType", sourceViewType),
            new("theme", theme),
            new("widthDip", width), new("heightDip", height),
            new("pixelWidth", PixelSize(width, dpi)), new("pixelHeight", PixelSize(height, dpi)), new("dpi", dpi),
            new("actualWidthDip", actualWidthDip), new("actualHeightDip", actualHeightDip),
            new("background", background ?? "transparent"), new("backgroundSource", backgroundSource),
            new("bindingTraceVerified", selfCheckHit),
            new("layoutIssueCount", layoutIssueCount),
            new("layoutReportError", layoutReportError),
            new("element", element),
            new("elementRectDip", elementRect),
            new("elementImage", element is null || elementError is not null ? null : "element.png"),
            new("elementError", elementError),
        });
        if (middle is not null) fields.AddRange(middle);
        fields.AddRange(new KeyValuePair<string, object?>[]
        {
            new("image", "snapshot.png"),
            new("sha256", sha256),
            new("targetFramework", Assembly.GetExecutingAssembly().GetCustomAttribute<TargetFrameworkAttribute>()?.FrameworkName),
            new("runtime", RuntimeInformation.FrameworkDescription),
            new("processArchitecture", RuntimeInformation.ProcessArchitecture.ToString()),
            new("machineName", Environment.MachineName),
        });
        if (tail is not null) fields.AddRange(tail);
        return fields;
    }

    // 绑定结果落盘并把条数与退出码补进 manifest。manifest 为 null 时只写绑定结果（渲染未完成就失败的情况）。
    internal static void WriteResults(string outDir, List<KeyValuePair<string, object?>>? manifest,
        IReadOnlyList<string> bindingErrors, IEnumerable<object?> bindingIssues, int exitCode)
    {
        File.WriteAllLines(Path.Combine(outDir, "binding-errors.txt"), bindingErrors);
        File.WriteAllText(Path.Combine(outDir, "binding-errors.json"), Json.Write(bindingIssues));
        if (manifest is not null)
        {
            manifest.Add(new("bindingWarningOrErrorCount", bindingErrors.Count));
            manifest.Add(new("exitCode", exitCode));
            File.WriteAllText(Path.Combine(outDir, "manifest.json"), Json.Write(manifest));
        }
        Console.WriteLine($"{outDir} (exit={exitCode})");
    }
}
