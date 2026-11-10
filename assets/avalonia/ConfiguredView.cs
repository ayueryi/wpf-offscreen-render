using Avalonia;
using Avalonia.Controls;
using Avalonia.Markup.Xaml;
using Avalonia.Markup.Xaml.Styling;

// 读取 harness.json，按类型名或松散 AXAML 创建视图，并设置预览 DataContext。
internal static class ConfiguredView
{
    internal static string? ConfigPath { get; set; }

    public static Control? TryCreate(string theme)
    {
        var config = HarnessConfig.Load(ConfigPath);
        if (config is null) return null;
        config.EnsureExclusiveView();
        if (config.ResourceDictionaries?.Any(path => path.StartsWith("pack:", StringComparison.OrdinalIgnoreCase)) == true)
            throw new InvalidOperationException("Avalonia 宿主不支持 WPF pack:// 资源字典，请改用 avares:// 或绝对文件路径。");

        foreach (var source in config.ResourceDictionaries ?? [])
        {
            var resolved = source.Replace("{theme}", theme, StringComparison.Ordinal);
            var uri = new Uri(resolved, UriKind.RelativeOrAbsolute);
            Application.Current!.Resources.MergedDictionaries.Add(new ResourceInclude(uri) { Source = uri });
        }

        Control? view = null;
        if (config.ViewType is not null)
        {
            view = Activator.CreateInstance(config.ResolveType(config.ViewType), nonPublic: true) as Control
                ?? throw new InvalidOperationException($"{config.ViewType} 不是 Avalonia Control。");
        }
        else if (config.Xaml is not null)
        {
            var path = Path.GetFullPath(config.Xaml);
            using var stream = File.OpenRead(path);
            view = AvaloniaRuntimeXamlLoader.Load(stream, typeof(ConfiguredView).Assembly, null, new Uri(path, UriKind.Absolute), false) as Control
                ?? throw new InvalidOperationException($"AXAML 根元素不是 Control：{path}");
        }

        if (view is not null) config.EnsureExclusiveDataContext();
        if (view is not null && config.DataContextType is not null)
            view.DataContext = Activator.CreateInstance(config.ResolveType(config.DataContextType), nonPublic: true);
        if (view is not null && config.DataContextFactory is not null)
            view.DataContext = config.InvokeFactory(config.DataContextFactory);
        return view;
    }
}
