using System.IO;
using Xunit;

namespace AgentRenderLogic.Tests;

// 绑定 trace 文本解析：摘要要给出「目标元素.属性 <- 路径（数据源）：原因」的可读结论。
public class BindingIssuesTests
{
    private const string Typical =
        "System.Windows.Data Error: 40 : BindingExpression path error: 'CustomerNmae' property not found on 'object' " +
        "''OrderPreviewVm' (HashCode=12345)'. BindingExpression:Path=CustomerNmae; DataItem='OrderPreviewVm' (HashCode=12345);" +
        " target element is 'TextBlock' (Name='CustomerText'); target property is 'Text' (type 'System.String')";

    [Fact]
    public void Describes_target_path_and_reason()
    {
        var fields = BindingIssues.Describe(Typical);
        // 摘要 = 原因（截至 BindingExpression 之前，去 HashCode）+ 目标 / 路径 / 数据源。
        var summary = (string)fields.First(pair => pair.Key == "summary").Value!;
        Assert.StartsWith("TextBlock#CustomerText.Text <- Path=CustomerNmae（数据源 OrderPreviewVm）：", summary);
        Assert.Contains("'CustomerNmae' property not found", summary);
        Assert.DoesNotContain("HashCode", summary);
        // 摘要在 BindingExpression 之后截断：不含路径段与目标段之外的日志尾部。
        Assert.DoesNotContain("DataItem", summary);
        Assert.DoesNotContain("target element", summary);
        Assert.Equal("CustomerNmae", fields.First(pair => pair.Key == "path").Value);
        Assert.Equal("OrderPreviewVm", fields.First(pair => pair.Key == "dataItem").Value);
        Assert.Equal("TextBlock", fields.First(pair => pair.Key == "targetElement").Value);
        Assert.Equal("CustomerText", fields.First(pair => pair.Key == "targetName").Value);
        Assert.Equal("Text", fields.First(pair => pair.Key == "targetProperty").Value);
    }

    [Fact]
    public void HashCode_is_stripped_from_reason()
    {
        var fields = BindingIssues.Describe(Typical);
        var reason = (string)fields.First(pair => pair.Key == "reason").Value!;
        Assert.DoesNotContain("HashCode", reason);
    }

    [Fact]
    public void Null_data_item_is_omitted_from_summary()
    {
        var message = "System.Windows.Data Error: 2 : Cannot find governing FrameworkElement for target element. " +
            "BindingExpression:Path=Foo; DataItem=null; target element is 'Border' (Name=''); target property is 'Tag' (type 'Object')";
        var summary = (string)BindingIssues.Describe(message).First(pair => pair.Key == "summary").Value!;
        Assert.DoesNotContain("数据源", summary);
        Assert.Contains("Border.Tag <- Path=Foo", summary);
    }

    [Fact]
    public void Unparseable_message_is_reported_verbatim()
    {
        var fields = BindingIssues.Describe("完全不是绑定日志的文本");
        Assert.Equal("完全不是绑定日志的文本", fields.First(pair => pair.Key == "summary").Value);
        Assert.Null(fields.First(pair => pair.Key == "path").Value);
    }
}

// Json 写入器：字段顺序、数组内单行对象与转义。
public class JsonWriterTests
{
    [Fact]
    public void Preserves_field_order_and_writes_scalars()
    {
        var json = Json.Write(Json.Object(("b", true), ("n", 3), ("s", "含\"引号\"与换行\n"), ("z", null)));
        Assert.Matches("(?s)^\\{\\s+\"b\": true,", json);
        Assert.Contains("\"s\": \"含\\\"引号\\\"与换行\\n\"", json);
        Assert.Contains("\"z\": null", json);
    }

    [Fact]
    public void Array_objects_are_single_line()
    {
        var json = Json.Write(new[] { Json.Object(("a", 1)), Json.Object(("a", 2)) });
        var lines = json.Split('\n').Where(line => line.Contains("\"a\":")).ToList();
        Assert.Equal(2, lines.Count);
        Assert.All(lines, line => Assert.Contains("{ \"a\":", line));
    }
}

// layout.json 报告壳：节点与问题的字段、重叠阈值、上限。
public class LayoutReportBuilderTests
{
    private static object? Field(List<KeyValuePair<string, object?>> fields, string key) => fields.First(field => field.Key == key).Value;

    [Fact]
    public void Overlap_needs_both_area_and_share_of_the_smaller_ink()
    {
        var report = new LayoutReportBuilder();
        report.AddInk("A", 0, 0, 10, 10);
        report.AddInk("B", 8, 8, 10, 10);   // 交叠 2×2 = 4，面积不大于 4，不报
        report.AddInk("C", 0, 30, 100, 10);
        report.AddInk("D", 0, 30, 10, 10);  // 交叠 10×10，占较小一块的全部，报
        var (fields, count) = report.Build(200, 100);

        Assert.Equal(1, count);
        var issue = Assert.Single((List<object?>)Field(fields, "issues")!);
        var fieldsOfIssue = Assert.IsType<List<KeyValuePair<string, object?>>>(issue);
        Assert.Equal("overlap", Field(fieldsOfIssue, "kind"));
        Assert.Equal("与 D 的文本重叠 10×10", Field(fieldsOfIssue, "message"));
        Assert.Equal(new[] { 0.0, 0.0, 200.0, 100.0 }, (double[])Field(fields, "viewport")!);
    }

    [Fact]
    public void Zero_size_is_reported_for_content_but_not_for_controls()
    {
        var report = new LayoutReportBuilder();
        report.ZeroSize(isControl: true, "Button#Ok", 0, 36, 0, 0, 0, 36);
        report.ZeroSize(isControl: false, "TextBlock#Hidden", 0, 12, 5, 6, 0, 12);
        var (fields, count) = report.Build(100, 100);

        Assert.Equal(1, count);
        var issue = Assert.IsType<List<KeyValuePair<string, object?>>>(Assert.Single((List<object?>)Field(fields, "issues")!));
        Assert.Equal("zero-size", Field(issue, "kind"));
        Assert.Equal("布局尺寸为 0×12，内容不可见", Field(issue, "message"));
        // 宽或高为 0 的矩形在报告里记成空数组，与原来 Rect.IsEmpty 的写法一致。
        Assert.Empty((double[])Field(issue, "rect")!);
        Assert.False((bool)Field(fields, "nodesTruncated")!);
    }

    [Fact]
    public void Nodes_stop_at_the_cap_and_mark_truncation()
    {
        var report = new LayoutReportBuilder();
        for (var i = 0; i <= LayoutReportBuilder.MaxNodes; i++)
            report.AddNode(i, "Border", null, 0, 0, 10, 10, i == 0 ? "第一行\n换行" : null);
        var (fields, _) = report.Build(10, 10);

        Assert.Equal(LayoutReportBuilder.MaxNodes, Field(fields, "nodeCount"));
        Assert.True((bool)Field(fields, "nodesTruncated")!);
        var first = Assert.IsType<List<KeyValuePair<string, object?>>>(((List<object?>)Field(fields, "nodes")!)[0]);
        Assert.Equal("第一行 换行", Field(first, "text"));
        Assert.Null(Field(first, "name"));
    }

    [Fact]
    public void Label_and_type_name_follow_the_existing_wording()
    {
        Assert.Equal("TextBlock#Title「短文本」", LayoutReportBuilder.Label("TextBlock", "Title", "短文本"));
        Assert.Equal("TextBlock", LayoutReportBuilder.Label("TextBlock", null, ""));
        Assert.Equal("Button", LayoutReportBuilder.TypeName(typeof(string), "System"));
        Assert.Equal(typeof(string).FullName, LayoutReportBuilder.TypeName(typeof(string), "Other"));
    }
}

// harness.json 读取端：字段、互斥校验、有没有交互步骤。
public class HarnessConfigTests
{
    private static HarnessConfig Read(string json)
    {
        var path = Path.Combine(Path.GetTempPath(), "harness-config-" + Guid.NewGuid().ToString("N") + ".json");
        File.WriteAllText(path, json);
        try { return HarnessConfig.Load(path)!; }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Reads_fields_and_ignores_step_contents()
    {
        var config = Read("""
            {"viewType":"Sample.View","resourceDictionaries":["pack://theme.xaml"],"assemblies":["SampleViews"],
             "steps":[{"action":"set","element":{"name":"Title"}}],"continueOnError":true}
            """);
        Assert.Equal("Sample.View", config.ViewType);
        Assert.Equal(new[] { "pack://theme.xaml" }, config.ResourceDictionaries);
        Assert.Equal(new[] { "SampleViews" }, config.Assemblies);
        Assert.True(config.HasSteps);
    }

    [Theory]
    [InlineData("{\"steps\": null}")]
    [InlineData("{\"steps\": []}")]
    [InlineData("{ \"steps\" : [ ] }")]
    public void Empty_steps_are_not_requested(string json)
    {
        Assert.False(Read(json).HasSteps);
    }

    [Fact]
    public void Missing_file_reads_as_null()
    {
        Assert.Null(HarnessConfig.Load(null));
        Assert.Null(HarnessConfig.Load(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".json")));
    }

    [Fact]
    public void Exclusive_choices_are_rejected_with_the_existing_messages()
    {
        var both = Read("{\"viewType\":\"A\",\"xaml\":\"b.xaml\",\"dataContextType\":\"C\",\"dataContextFactory\":\"C.Create\"}");
        Assert.Equal("harness.json 中 viewType 与 xaml 只能二选一。", Assert.Throws<InvalidOperationException>(both.EnsureExclusiveView).Message);
        Assert.Equal("harness.json 中 dataContextType 与 dataContextFactory 只能二选一。",
            Assert.Throws<InvalidOperationException>(both.EnsureExclusiveDataContext).Message);

        var one = Read("{\"viewType\":\"A\",\"dataContextType\":\"C\"}");
        one.EnsureExclusiveView();
        one.EnsureExclusiveDataContext();
    }
}

// 结果清单写端：字段顺序、像素换算、退出码含义、绑定结果落盘。
public class RenderOutcomeTests
{
    [Fact]
    public void Exit_code_prefers_self_check_over_steps_over_bindings()
    {
        Assert.Equal(RenderOutcome.ExitFailed, RenderOutcome.ResolveExitCode(selfCheckHit: false, stepsFailed: true, bindingIssueCount: 4));
        Assert.Equal(RenderOutcome.ExitStepFailed, RenderOutcome.ResolveExitCode(selfCheckHit: true, stepsFailed: true, bindingIssueCount: 4));
        Assert.Equal(RenderOutcome.ExitBindingIssues, RenderOutcome.ResolveExitCode(selfCheckHit: true, stepsFailed: false, bindingIssueCount: 1));
        Assert.Equal(RenderOutcome.ExitOk, RenderOutcome.ResolveExitCode(selfCheckHit: true, stepsFailed: false, bindingIssueCount: 0));
    }

    [Fact]
    public void Manifest_keeps_shared_order_and_slots_adapter_facts()
    {
        var fields = RenderOutcome.BuildManifest(
            head: new[] { new KeyValuePair<string, object?>("stack", "avalonia") },
            toolVersion: "2.1.0", mode: "layout-only", sourceViewType: "Sample.View", theme: "dark",
            width: 100, height: 50, dpi: 192, actualWidthDip: 100.5, actualHeightDip: 49.5,
            background: null, backgroundSource: "theme-fallback",
            selfCheckHit: true, layoutIssueCount: 0, layoutReportError: null,
            element: "Title", elementRect: new[] { 1.0, 2.0, 3.0, 4.0 }, elementError: null,
            middle: new[] { new KeyValuePair<string, object?>("stepCount", 2) },
            sha256: "abc",
            tail: new[] { new KeyValuePair<string, object?>("warning", "dpi"), new KeyValuePair<string, object?>("note", "n") });

        var keys = fields.Select(field => field.Key).ToList();
        Assert.Equal("stack", keys[0]);
        Assert.Equal(new[] { "element", "elementRectDip", "elementImage", "elementError", "stepCount", "image", "sha256" },
            keys.SkipWhile(key => key != "element").Take(7));
        Assert.Equal(new[] { "warning", "note" }, keys.TakeLast(2));

        // 192 DPI 是 96 的两倍，100×50 DIP 向上取整成 200×100 像素。
        Assert.Equal(200, fields.First(field => field.Key == "pixelWidth").Value);
        Assert.Equal(100, fields.First(field => field.Key == "pixelHeight").Value);
        // 背景没给时按透明记录；有元素且没有错误时指向 element.png。
        Assert.Equal("transparent", fields.First(field => field.Key == "background").Value);
        Assert.Equal("element.png", fields.First(field => field.Key == "elementImage").Value);
    }

    [Fact]
    public void Element_image_is_omitted_when_capture_failed_or_not_requested()
    {
        var failed = RenderOutcome.BuildManifest(null, null, "layout-only", null, "light", 10, 10, 96, 10, 10,
            "#fff", "explicit", true, null, null, "Title", null, "找不到元素", null, "abc", null);
        Assert.Null(failed.First(field => field.Key == "elementImage").Value);

        var none = RenderOutcome.BuildManifest(null, null, "layout-only", null, "light", 10, 10, 96, 10, 10,
            "#fff", "explicit", true, null, null, null, null, null, null, "abc", null);
        Assert.Null(none.First(field => field.Key == "elementImage").Value);
    }

    [Fact]
    public void Write_results_persists_bindings_and_appends_count_and_exit_code()
    {
        var dir = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "render-outcome-" + Guid.NewGuid().ToString("N")));
        try
        {
            var manifest = new List<KeyValuePair<string, object?>> { new("mode", "layout-only") };
            var issues = new[] { Json.Object(("summary", "TextBlock.Text <- Path=Missing")) };
            RenderOutcome.WriteResults(dir.FullName, manifest, new[] { "raw binding error" }, issues, RenderOutcome.ExitBindingIssues);

            Assert.Equal("raw binding error", File.ReadAllLines(Path.Combine(dir.FullName, "binding-errors.txt")).Single());
            Assert.Contains("TextBlock.Text", File.ReadAllText(Path.Combine(dir.FullName, "binding-errors.json")));
            var written = File.ReadAllText(Path.Combine(dir.FullName, "manifest.json"));
            Assert.Contains("\"bindingWarningOrErrorCount\":", written);
            Assert.Contains("\"exitCode\":", written);
            // 条数与退出码是补在末尾的，不插进宿主交来的字段之间。
            Assert.Equal(new[] { "mode", "bindingWarningOrErrorCount", "exitCode" }, manifest.Select(field => field.Key));
            Assert.Equal(1, manifest[1].Value);
            Assert.Equal(RenderOutcome.ExitBindingIssues, manifest[2].Value);
        }
        finally
        {
            dir.Delete(recursive: true);
        }
    }
}

