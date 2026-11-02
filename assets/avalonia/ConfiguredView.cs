using System.Reflection;
using System.Text.Json;
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
        if (ConfigPath is null || !File.Exists(ConfigPath)) return null;
        var config = JsonSerializer.Deserialize<HarnessConfig>(File.ReadAllText(ConfigPath), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new HarnessConfig();
        if (config.ViewType is not null && config.Xaml is not null)
            throw new InvalidOperationException("harness.json 中 viewType 与 xaml 只能二选一。");
        if (config.ResourceDictionaries?.Any(path => path.StartsWith("pack:", StringComparison.OrdinalIgnoreCase)) == true)
            throw new InvalidOperationException("Avalonia 宿主不支持 WPF pack:// 资源字典，请改用 avares:// 或绝对文件路径。");

        businessAssemblies = config.Assemblies ?? [];
        foreach (var source in config.ResourceDictionaries ?? [])
        {
            var resolved = source.Replace("{theme}", theme, StringComparison.Ordinal);
            var uri = new Uri(resolved, UriKind.RelativeOrAbsolute);
            Application.Current!.Resources.MergedDictionaries.Add(new ResourceInclude(uri) { Source = uri });
        }

        Control? view = null;
        if (config.ViewType is not null)
        {
            view = Activator.CreateInstance(ResolveType(config.ViewType), nonPublic: true) as Control
                ?? throw new InvalidOperationException($"{config.ViewType} 不是 Avalonia Control。");
        }
        else if (config.Xaml is not null)
        {
            var path = Path.GetFullPath(config.Xaml);
            using var stream = File.OpenRead(path);
            view = AvaloniaRuntimeXamlLoader.Load(stream, typeof(ConfiguredView).Assembly, null, new Uri(path, UriKind.Absolute), false) as Control
                ?? throw new InvalidOperationException($"AXAML 根元素不是 Control：{path}");
        }

        if (view is not null && config.DataContextType is not null && config.DataContextFactory is not null)
            throw new InvalidOperationException("harness.json 中 dataContextType 与 dataContextFactory 只能二选一。");
        if (view is not null && config.DataContextType is not null)
            view.DataContext = Activator.CreateInstance(ResolveType(config.DataContextType), nonPublic: true);
        if (view is not null && config.DataContextFactory is not null)
            view.DataContext = InvokeFactory(config.DataContextFactory);
        return view;
    }

    private static string[] businessAssemblies = [];

    private static Type ResolveType(string name)
    {
        var type = Type.GetType(name, throwOnError: false);
        if (type is not null) return type;
        foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            type = assembly.GetType(name, throwOnError: false);
            if (type is not null) return type;
        }
        var business = businessAssemblies.Select(assembly => Path.Combine(AppContext.BaseDirectory, assembly))
            .SelectMany(path => new[] { path + ".dll", path + ".exe" }).Where(File.Exists).ToList();
        var others = Directory.EnumerateFiles(AppContext.BaseDirectory, "*.dll")
            .Where(path => !business.Contains(path, StringComparer.OrdinalIgnoreCase));
        foreach (var dll in business.Concat(others))
        {
            try { type = Assembly.Load(AssemblyName.GetAssemblyName(dll)).GetType(name, throwOnError: false); }
            catch (BadImageFormatException) { continue; }
            catch (FileLoadException) { continue; }
            if (type is not null) return type;
        }
        throw new InvalidOperationException($"找不到类型：{name}。确认已通过 -AssemblyPath 引用其程序集，且类型名含完整命名空间。");
    }

    private static object? InvokeFactory(string factory)
    {
        var dot = factory.LastIndexOf('.');
        if (dot <= 0 || dot == factory.Length - 1) throw new InvalidOperationException($"dataContextFactory 应为 类型全名.方法名：{factory}");
        var type = ResolveType(factory.Substring(0, dot));
        var method = type.GetMethod(factory.Substring(dot + 1), BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static,
            null, Type.EmptyTypes, null) ?? throw new InvalidOperationException($"{type.FullName} 上没有无参静态方法 {factory.Substring(dot + 1)}。");
        return method.Invoke(null, null);
    }

    private sealed class HarnessConfig
    {
        public string? ViewType { get; set; }
        public string? Xaml { get; set; }
        public string? DataContextType { get; set; }
        public string? DataContextFactory { get; set; }
        public string[]? ResourceDictionaries { get; set; }
        public string[]? Assemblies { get; set; }
        public JsonElement? Steps { get; set; }
    }
}
