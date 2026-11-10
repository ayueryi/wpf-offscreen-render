using System.IO;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;

// harness.json 的读取端：字段、互斥校验、类型查找、有没有交互步骤。
// 视图怎么造（XAML 加载、资源字典类型、根元素基类）留在各自宿主。
// 步骤的完整结构留在 WPF 的 StepsConfig；这里只回答「有没有」，不把步骤模型带进 Avalonia 工程。
// 键名区分大小写，与生成器写入的 harness.json 一致。只用 .NET Framework 4.7.2 与 .NET 5+ 共有的 API。
[DataContract]
internal sealed class HarnessConfig
{
    [DataMember(Name = "viewType")] public string? ViewType { get; set; }
    [DataMember(Name = "xaml")] public string? Xaml { get; set; }
    [DataMember(Name = "dataContextType")] public string? DataContextType { get; set; }
    [DataMember(Name = "dataContextFactory")] public string? DataContextFactory { get; set; }
    [DataMember(Name = "resourceDictionaries")] public string[]? ResourceDictionaries { get; set; }
    // -AssemblyPath 中业务程序集的文件名（不含扩展名），用于优先查找类型。
    [DataMember(Name = "assemblies")] public string[]? Assemblies { get; set; }
    // 只占位：步骤对象的字段全部忽略，条数大于 0 即为「有步骤」。
    [DataMember(Name = "steps")] public List<StepPresence>? Steps { get; set; }

    internal bool HasSteps => Steps is { Count: > 0 };

    internal static HarnessConfig? Load(string? path)
    {
        if (path is null || !File.Exists(path)) return null;
        using var stream = File.OpenRead(path);
        return (HarnessConfig?)new DataContractJsonSerializer(typeof(HarnessConfig)).ReadObject(stream) ?? new HarnessConfig();
    }

    internal void EnsureExclusiveView()
    {
        if (ViewType is not null && Xaml is not null)
            throw new InvalidOperationException("harness.json 中 viewType 与 xaml 只能二选一。");
    }

    internal void EnsureExclusiveDataContext()
    {
        if (DataContextType is not null && DataContextFactory is not null)
            throw new InvalidOperationException("harness.json 中 dataContextType 与 dataContextFactory 只能二选一。");
    }

    // "Namespace.Type.Method"：调用无参静态方法（可为 non-public）创建 DataContext。
    internal object? InvokeFactory(string factory)
    {
        var dot = factory.LastIndexOf('.');
        if (dot <= 0 || dot == factory.Length - 1) throw new InvalidOperationException($"dataContextFactory 应为 类型全名.方法名：{factory}");
        var type = ResolveType(factory.Substring(0, dot));
        var method = type.GetMethod(factory.Substring(dot + 1), BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static,
            null, Type.EmptyTypes, null) ?? throw new InvalidOperationException($"{type.FullName} 上没有无参静态方法 {factory.Substring(dot + 1)}。");
        return method.Invoke(null, null);
    }

    // 支持程序集限定名；仅写全名时依次在已加载程序集、-AssemblyPath 指定的业务程序集、输出目录其余 DLL 中查找。
    // 先查业务程序集，避免为找一个类型加载（并初始化）无关的依赖程序集。
    internal Type ResolveType(string name)
    {
        var type = Type.GetType(name, throwOnError: false);
        if (type is not null) return type;
        foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            type = assembly.GetType(name, throwOnError: false);
            if (type is not null) return type;
        }
        var business = (Assemblies ?? []).Select(assembly => Path.Combine(AppContext.BaseDirectory, assembly))
            .SelectMany(path => new[] { path + ".dll", path + ".exe" }).Where(File.Exists).ToList();
        var others = Directory.EnumerateFiles(AppContext.BaseDirectory, "*.dll")
            .Where(path => !business.Contains(path, StringComparer.OrdinalIgnoreCase));
        foreach (var dll in business.Concat(others))
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
}

// 空契约：反序列化时丢掉步骤对象里的全部字段，只保留条数。
[DataContract]
internal sealed class StepPresence
{
}
