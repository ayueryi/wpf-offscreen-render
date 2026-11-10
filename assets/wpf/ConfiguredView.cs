using System.IO;
using System.Windows;
using System.Windows.Markup;

// 读取生成器写入的 harness.json：按配置合并资源字典，并按类型名或松散 XAML 创建视图。
// 修改 harness.json 后无需重新构建，可直接 -NoBuild 再渲染。
// 只使用 .NET Framework 4.7.2 与 .NET 5+ 共有的 API，同一份源码适配全部受支持的 TFM。
internal static class ConfiguredView
{
    internal static string? ConfigPath { get; set; }

    // 返回 null 表示未配置视图，由 ViewFactory 使用自己的实现。
    public static FrameworkElement? TryCreate(string theme)
    {
        var config = HarnessConfig.Load(ConfigPath);
        if (config is null) return null;
        config.EnsureExclusiveView();

        foreach (var source in config.ResourceDictionaries ?? [])
        {
            var resolved = source.Replace("{theme}", theme);
            var uri = IsFullyQualifiedPath(resolved)
                ? new Uri(resolved, UriKind.Absolute)
                : new Uri(resolved, UriKind.RelativeOrAbsolute);
            Application.Current.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = uri });
        }

        FrameworkElement? view = null;
        if (config.ViewType is not null)
        {
            view = Activator.CreateInstance(config.ResolveType(config.ViewType), nonPublic: true) as FrameworkElement
                ?? throw new InvalidOperationException($"{config.ViewType} 不是 FrameworkElement。");
        }
        else if (config.Xaml is not null)
        {
            var path = Path.GetFullPath(config.Xaml);
            using var stream = File.OpenRead(path);
            view = XamlReader.Load(stream, new ParserContext { BaseUri = new Uri(path, UriKind.Absolute) }) as FrameworkElement
                ?? throw new InvalidOperationException($"XAML 根元素不是 FrameworkElement：{path}");
        }

        if (view is not null) config.EnsureExclusiveDataContext();
        if (view is not null && config.DataContextType is not null)
            view.DataContext = Activator.CreateInstance(config.ResolveType(config.DataContextType), nonPublic: true);
        if (view is not null && config.DataContextFactory is not null)
            view.DataContext = config.InvokeFactory(config.DataContextFactory);
        return view;
    }

    // 盘符绝对路径或 UNC 路径；"/MyUi;component/..." 这类 pack URI 不算。
    private static bool IsFullyQualifiedPath(string path) =>
        path.StartsWith(@"\\", StringComparison.Ordinal)
        || path.Length >= 3 && char.IsLetter(path[0]) && path[1] == ':' && (path[2] == '\\' || path[2] == '/');
}
