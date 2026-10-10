using System.IO;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
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
        if (ConfigPath is null || !File.Exists(ConfigPath)) return null;
        HarnessConfig config;
        using (var stream = File.OpenRead(ConfigPath))
            config = (HarnessConfig?)new DataContractJsonSerializer(typeof(HarnessConfig)).ReadObject(stream) ?? new HarnessConfig();
        if (config.ViewType is not null && config.Xaml is not null)
            throw new InvalidOperationException("harness.json 中 viewType 与 xaml 只能二选一。");

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

        if (view is not null && config.DataContextType is not null && config.DataContextFactory is not null)
            throw new InvalidOperationException("harness.json 中 dataContextType 与 dataContextFactory 只能二选一。");
        if (view is not null && config.DataContextType is not null)
            view.DataContext = Activator.CreateInstance(ResolveType(config.DataContextType), nonPublic: true);
        if (view is not null && config.DataContextFactory is not null)
            view.DataContext = InvokeFactory(config.DataContextFactory);
        return view;
    }

    // 盘符绝对路径或 UNC 路径；"/MyUi;component/..." 这类 pack URI 不算。
    private static bool IsFullyQualifiedPath(string path) =>
        path.StartsWith(@"\\", StringComparison.Ordinal)
        || path.Length >= 3 && char.IsLetter(path[0]) && path[1] == ':' && (path[2] == '\\' || path[2] == '/');

    // "Namespace.Type.Method"：调用无参静态方法（可为 non-public）创建 DataContext，适合需要构造参数或 stub 服务的 ViewModel。
    private static object? InvokeFactory(string factory)
    {
        var dot = factory.LastIndexOf('.');
        if (dot <= 0 || dot == factory.Length - 1) throw new InvalidOperationException($"dataContextFactory 应为 类型全名.方法名：{factory}");
        var type = ResolveType(factory.Substring(0, dot));
        var method = type.GetMethod(factory.Substring(dot + 1), BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static, null, Type.EmptyTypes, null)
            ?? throw new InvalidOperationException($"{type.FullName} 上没有无参静态方法 {factory.Substring(dot + 1)}。");
        return method.Invoke(null, null);
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

    // 键名区分大小写，与生成器写入的 harness.json 一致。
    [DataContract]
    private sealed class HarnessConfig
    {
        [DataMember(Name = "viewType")] public string? ViewType { get; set; }
        [DataMember(Name = "xaml")] public string? Xaml { get; set; }
        [DataMember(Name = "dataContextType")] public string? DataContextType { get; set; }
        [DataMember(Name = "dataContextFactory")] public string? DataContextFactory { get; set; }
        [DataMember(Name = "resourceDictionaries")] public string[]? ResourceDictionaries { get; set; }
    }
}
