using Xunit;

namespace WpfRenderLogic.Tests;

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

