using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Markup;

// 读取生成器写入的 harness.json：按配置合并资源字典，并按类型名或松散 XAML 创建视图。
// 修改 harness.json 后无需重新构建，可直接 -NoBuild 再渲染。
internal static class ConfiguredView
{
    internal static string? ConfigPath { get; set; }

    // 返回 null 表示未配置视图，由 ViewFactory 使用自己的实现。
    public static FrameworkElement? TryCreate(string theme)
    {
        if (ConfigPath is null || !File.Exists(ConfigPath)) return null;
        var config = JsonSerializer.Deserialize<HarnessConfig>(File.ReadAllText(ConfigPath),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new HarnessConfig();
        if (config.ViewType is not null && config.Xaml is not null)
            throw new InvalidOperationException("harness.json 中 viewType 与 xaml 只能二选一。");

        foreach (var source in config.ResourceDictionaries ?? [])
        {
            var resolved = source.Replace("{theme}", theme, StringComparison.Ordinal);
            var uri = Path.IsPathFullyQualified(resolved)
                ? new Uri(resolved, UriKind.Absolute)
                : new Uri(resolved, UriKind.RelativeOrAbsolute);
            Application.Current.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = uri });
        }

        FrameworkElement? view = null;
        if (config.ViewType is not null)
        {
            view = Activator.CreateInstance(ResolveType(config.ViewType), nonPublic: true) as FrameworkElement
                ?? throw new InvalidOperationException($"{config.ViewType} 不是 FrameworkElement。");
        }
        else if (config.Xaml is not null)
        {
            var path = Path.GetFullPath(config.Xaml);
            using var stream = File.OpenRead(path);
            view = XamlReader.Load(stream, new ParserContext { BaseUri = new Uri(path, UriKind.Absolute) }) as FrameworkElement
                ?? throw new InvalidOperationException($"XAML 根元素不是 FrameworkElement：{path}");
        }

        if (view is not null && config.DataContextType is not null)
            view.DataContext = Activator.CreateInstance(ResolveType(config.DataContextType), nonPublic: true);
        return view;
    }

    // 支持程序集限定名，或仅写全名时在已加载程序集与输出目录 DLL 中查找。
    private static Type ResolveType(string name)
    {
        var type = Type.GetType(name, throwOnError: false);
        if (type is not null) return type;
        foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            type = assembly.GetType(name, throwOnError: false);
            if (type is not null) return type;
        }
        foreach (var dll in Directory.EnumerateFiles(AppContext.BaseDirectory, "*.dll"))
        {
            try
            {
                type = Assembly.Load(AssemblyName.GetAssemblyName(dll)).GetType(name, throwOnError: false);
            }
            catch (BadImageFormatException) { continue; } // native DLL
            catch (FileLoadException) { continue; }
            if (type is not null) return type;
        }
        throw new InvalidOperationException($"找不到类型：{name}。确认已通过 -AssemblyPath 引用其程序集，且类型名含完整命名空间。");
    }

    private sealed class HarnessConfig
    {
        public string? ViewType { get; set; }
        public string? Xaml { get; set; }
        public string? DataContextType { get; set; }
        public string[]? ResourceDictionaries { get; set; }
    }
}
