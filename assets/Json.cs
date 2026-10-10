using System.Collections;
using System.Globalization;
using System.Text;

// 最小 JSON 写入器，只用 .NET Framework 4.7.2 与 .NET 5+ 共有的 API。
// 对象用 KeyValuePair 列表表示以保持字段顺序；数组中的对象写成单行，便于按行查找。
internal static class Json
{
    public static List<KeyValuePair<string, object?>> Object(params (string Key, object? Value)[] fields) =>
        fields.Select(field => new KeyValuePair<string, object?>(field.Key, field.Value)).ToList();

    public static string Write(object? value)
    {
        var builder = new StringBuilder();
        Append(builder, value, 0, compact: false);
        return builder.ToString();
    }

    private static void Append(StringBuilder builder, object? value, int indent, bool compact)
    {
        switch (value)
        {
            case null: builder.Append("null"); break;
            case bool flag: builder.Append(flag ? "true" : "false"); break;
            case string text: Quote(builder, text); break;
            case Enum name: Quote(builder, name.ToString()); break; // Enum 也实现 IFormattable，需先于数字处理
            case double number when double.IsNaN(number) || double.IsInfinity(number): builder.Append("null"); break;
            case double number: builder.Append(number.ToString("R", CultureInfo.InvariantCulture)); break;
            case IEnumerable<KeyValuePair<string, object?>> fields: AppendObject(builder, fields, indent, compact); break;
            case IFormattable number: builder.Append(number.ToString(null, CultureInfo.InvariantCulture)); break;
            case IEnumerable items: AppendArray(builder, items, indent, compact); break;
            default: Quote(builder, value.ToString() ?? ""); break;
        }
    }

    private static void AppendObject(StringBuilder builder, IEnumerable<KeyValuePair<string, object?>> fields, int indent, bool compact)
    {
        var first = true;
        builder.Append('{');
        foreach (var field in fields)
        {
            if (!first) builder.Append(',');
            first = false;
            if (compact) builder.Append(' ');
            else builder.AppendLine().Append(' ', indent + 2);
            Quote(builder, field.Key);
            builder.Append(": ");
            Append(builder, field.Value, indent + 2, compact);
        }
        if (first) builder.Append('}');
        else if (compact) builder.Append(" }");
        else builder.AppendLine().Append(' ', indent).Append('}');
    }

    private static void AppendArray(StringBuilder builder, IEnumerable items, int indent, bool compact)
    {
        var first = true;
        builder.Append('[');
        foreach (var item in items)
        {
            if (!first) builder.Append(',');
            first = false;
            if (compact) builder.Append(' ');
            else builder.AppendLine().Append(' ', indent + 2);
            // 数组元素中的对象写成单行。
            Append(builder, item, indent + 2, compact: true);
        }
        if (first) builder.Append(']');
        else if (compact) builder.Append(" ]");
        else builder.AppendLine().Append(' ', indent).Append(']');
    }

    private static void Quote(StringBuilder builder, string value)
    {
        builder.Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                default:
                    if (c < ' ') builder.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else builder.Append(c);
                    break;
            }
        }
        builder.Append('"');
    }
}
