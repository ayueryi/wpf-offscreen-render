# 接入真实 WPF 界面

## 业务项目接入：wpf-render.json

把要验证的视图登记在业务仓库根目录的 `wpf-render.json` 中，代理就能按名称渲染（MCP `render_view` 的 `config` + `preset`，或 `render.ps1 -Config <目录> -Preset <名称>`），结束本轮前的 Stop hook 也据此自动验证。完整示例见 [templates/wpf-render.json](../templates/wpf-render.json)。

| 字段 | 位置 | 说明 |
| --- | --- | --- |
| `verifyOnStop` | 顶层 | `true` 时启用结束前自动验证（Claude Code 插件自带 Stop hook；Codex 见 [templates/codex-hooks.json](../templates/codex-hooks.json)） |
| `blockOnLayoutIssues` | 顶层 | `true` 时布局问题也会阻止结束；默认只有渲染失败与绑定错误会阻止 |
| `defaults` | 顶层 | 各视图共用的设置，视图中的同名字段覆盖它 |
| `views.<名称>` | 顶层 | 一个视图预设 |
| `assemblyPaths`、`xaml`、`factoryFile` | 预设 | 相对路径相对于 `wpf-render.json` 所在目录 |
| `viewType`、`dataContextType`、`dataContextFactory` | 预设 | 同 `render.ps1` 的同名参数；`dataContextFactory` 为无参静态方法 `Namespace.Type.Method` |
| `resourceDictionaries` | 预设 | pack URI 原样使用，其余相对路径相对于配置目录；`{theme}` 替换为主题 |
| `themes`、`sizes`、`dpis` | 预设 | 多个值时得到多组合汇总（`matrix.json` 与总览图） |
| `width`、`height`、`background`、`windowHost`、`element`、`targetFramework`、`platform` | 预设 | 同 `render.ps1` 参数 |
| `build` | 预设 | 参数数组（不经过 shell），如 `["dotnet", "build", "src/MyApp/MyApp.csproj", "-c", "Debug"]`；`-Build` / `build: true` 时在配置目录执行 |
| `watch` | 预设 | 文件模式（`**` 任意层级、`*` 单级），相对于配置目录；Stop hook 只验证改动命中 `watch` 的视图 |

显式传入的参数覆盖预设值，例如 `render.ps1 -Config . -Preset OrderList -Width 900`。

**DataContext 的三种来源**，按需要选择最轻的一种：

1. `dataContextType`：无参构造的预览 ViewModel。
2. `dataContextFactory`：无参静态工厂方法，适合需要构造参数、stub 服务或填充样例数据的 ViewModel，例如在业务项目中放一个 `PreviewData.CreateOrderList()`。
3. `factoryFile`：业务仓库中受版本管理的 `ViewFactory.cs`，替换宿主默认工厂；可以配置资源、等待异步就绪、设置选中态和清理。形状见下文“资源、主题和 DataContext”，三个方法签名不能改。工厂文件内容变化时宿主自动重新构建。

**授权**：Stop hook 会执行配置中的 `build` 命令并运行业务程序集，因此只对用户显式授权的配置生效。在本机运行 `scripts/trust-project.ps1 -Path <业务仓库目录>` 授权（`-List` 查看、`-Revoke` 撤销）；授权记录保存在 `%LOCALAPPDATA%\wpf-offscreen-render\trusted-projects.json`，绑定 `wpf-render.json` 的内容哈希，配置被修改后需要重新授权。未授权时 hook 不执行任何构建或渲染，每个会话只提示一次。

**Stop hook 的行为**：代理结束本轮前，hook 从会话目录向上找到 `wpf-render.json`；`verifyOnStop` 为 `true` 且已授权时，用 `git status` 找出未提交的改动，渲染 `watch` 命中的视图（先执行一次 `build`）。有渲染失败或绑定错误时阻止结束，并把结论（视图、绑定路径、截图路径）交给代理继续修复；同一份改动只验证一次，代理确认无法修复时不会被反复拦截。没有 `wpf-render.json`、未启用或非 Windows 时立即退出。

**代理规则**：把 [templates/agent-rules.md](../templates/agent-rules.md) 的内容加入业务仓库的 `AGENTS.md`（Codex 等）或 `CLAUDE.md`（Claude Code），约定修改界面后必须渲染验证并在回复中给出结论。

## 工程和程序集

本工具的工程独立于业务仓库，只有 WPF 和 .NET 依赖。使用 Windows + PowerShell 7。支持的宿主 TFM：`net472`、`net48`、`net481` 与 `net5.0-windows` … `net10.0-windows`（可带平台版本）。确认 `dotnet --list-sdks` 能构建该 TFM；.NET 宿主还需 `dotnet --list-runtimes` 中有对应的 WindowsDesktop Runtime，.NET Framework 宿主需本机已装对应版本的 .NET Framework，并有 Developer Pack 或 NuGet 访问来获取引用程序集。

生成时引用已经构建的程序集：

```powershell
$harness = & "$skillRoot\scripts\new-wpf-harness.ps1" `
    -AssemblyPath 'C:\work\MyApp\bin\Debug\net8.0-windows\MyApp.dll', `
                  'C:\work\MyApp\bin\Debug\net8.0-windows\MyUi.dll'
$harness | Select-Object TargetFramework, Platform
```

省略 `-TargetFramework` / `-Platform` 时由生成器推断，规则如下：

- TFM：读取每个程序集的 `TargetFrameworkAttribute`，取同类中的最高版本。低于 4.7.2 的 .NET Framework 程序集使用 `net472` 宿主；.NET Standard 程序集两类宿主都能引用，不参与推断；没有业务程序集时为 `net8.0-windows`。
- 拒绝的情况：.NET Framework 与 .NET 程序集混用、面向 .NET Core 3.x 的程序集、显式 TFM 与程序集类别不同或版本更低。
- 位数：读取 PE 头。x86 编译、C++/CLI 混合模式的程序集以及“首选 32 位”的 exe（VS 中 .NET Framework 程序的默认设置）需要 32 位进程，x64 / ARM64 编译的程序集需要对应进程；全是 AnyCPU 时宿主为 AnyCPU（64 位系统上以 64 位运行）。.NET Framework 宿主直接运行 `RenderHarness.exe`；.NET 宿主固定位数时启用 apphost，需安装该架构的 WindowsDesktop Runtime。

.NET Framework WPF 程序的界面常常直接写在 `.exe` 里，`-AssemblyPath` 也接受 `.exe`。业务程序依赖 `App.config` 里的配置节时，在生成工程中新建 `App.config` 放入需要的部分；程序集版本的绑定重定向由 SDK 构建时自动生成到 `RenderHarness.exe.config`。

这些路径只是示例，先确认实际程序集名称、版本、输出位置。生成器使用 XML 转义写入 HintPath，路径含空格可正常使用。生成的工程自带隔离用的 `Directory.Build.props` / `.targets` / `Directory.Packages.props`，因此 `-WorkDir` 即使放在业务仓库内，也不会继承上层构建配置。需要额外 NuGet 包、ProjectReference 或依赖 DLL 时修改生成的 `RenderHarness.csproj`。引用 DLL 并不保证所有运行时依赖、native DLL、内容文件都被复制；按错误补齐明确需要的依赖，保留它们的相对目录。不要对生产输出目录做覆盖或全量清理。

如果只需要公开的 View 类型，优先 DLL 引用以避免业务项目构建前后的副作用。需要自动跟随源码时才使用 ProjectReference，注意目标项目的构建事件。存在 Costura / 单文件发布时，优先业务项目普通构建产物；生产 App 的程序集加载器通常不会在独立宿主里自动注册。

## 免代码接入：harness.json

满足以下条件时，不必修改 `ViewFactory.cs`：View 和 DataContext 都有无参构造（可以是 non-public），资源只需要按顺序合并字典，并且不需要等待异步就绪。这种情况优先用 `scripts/render.ps1` 一步渲染：参数与下例相同，宿主会被缓存，程序集未变时跳过构建。

```powershell
$harness = & "$skillRoot\scripts\new-wpf-harness.ps1" -AssemblyPath $myUiDll `
    -ViewType MyUi.Views.OrderView `
    -DataContextType MyUi.Preview.OrderPreviewVm `
    -ResourceDictionary '/MyUi;component/Themes/Generic.xaml', '/MyUi;component/Themes/{theme}.xaml'
```

- `-ViewType` / `-DataContextType`：可以写完整类型名（会在已加载程序集和输出目录的 DLL 中查找），也可以写程序集限定名 `Ns.Type, Assembly`。
- `-Xaml`：松散 XAML 文件，与 `-ViewType` 二选一。不能写 `x:Class` 和事件处理器；业务控件通过 `xmlns:v="clr-namespace:MyUi.Views;assembly=MyUi"` 引用，对应程序集需在 `-AssemblyPath` 中。适合快速拼一个探针布局或组合多个控件。
- `-ResourceDictionary`：按给定顺序合并到 `Application.Current.Resources`。支持 pack URI 或磁盘绝对路径，`{theme}` 替换为 `-Theme` 的值。
- 手工编辑 `harness.json` 时键名区分大小写（`viewType`、`xaml`、`dataContextType`、`resourceDictionaries`）。
- 这些参数都写入生成工程的 `harness.json`，渲染时才读取。修改它或 XAML 文件后，可以直接 `-NoBuild` 再渲染。

超出上述条件时（VM 需要参数或 stub 服务、需要 Bootstrap、需要等待加载完成或设置选中态），按下文修改 `ViewFactory.cs`。默认的 `ViewFactory.Create` 会先尝试 `harness.json`，未配置视图时才走样例。整体替换 `ViewFactory.cs` 后，`harness.json` 中的视图配置就不再生效。

## 资源、主题和 DataContext

`ViewFactory` 有三个钩子，签名不要改。在 `Create` 中**先配置资源，再构造 View**。示例形状（替换程序集、字典、类型名称后才能使用）：

```csharp
using System.Windows;
using MyUi.Views;          // 替换成真实命名空间

internal static class ViewFactory
{
    // 先配置资源，再构造 View。
    public static FrameworkElement Create(string theme)
    {
        var resources = Application.Current.Resources.MergedDictionaries;
        resources.Add(new ResourceDictionary
        {
            Source = new Uri("/MyUi;component/Themes/Generic.xaml", UriKind.Relative)
        });
        resources.Add(new ResourceDictionary
        {
            Source = new Uri(theme == "dark"
                ? "/MyUi;component/Themes/Dark.xaml"
                : "/MyUi;component/Themes/Light.xaml", UriKind.Relative)
        });

        return new OrderListPage { DataContext = PreviewViewModel.CreateSample() };
    }

    // 在布局（以及 window-host 下的 Loaded）之后、截图之前执行，运行在 Dispatcher 线程。
    public static async Task WaitUntilReadyAsync(FrameworkElement view)
    {
        var vm = (PreviewViewModel)view.DataContext;
        await vm.LoadCompleted.WaitAsync(TimeSpan.FromSeconds(15));
    }

    // 释放自己创建的订阅、计时器、Disposable VM / 图像。
    public static void Cleanup(FrameworkElement view)
    {
        (view.DataContext as IDisposable)?.Dispose();
    }
}
```

按业务项目实际资源加载顺序配置，尤其是 Generic、字体、converter、全局 style 和模板的依赖。若框架需要 ThemeManager / Bootstrap，调用明确的资源初始化入口；不要直接运行生产 `App.OnStartup`、`Root` 或完整 IoC 启动链。

`-Theme light / dark` 仅传入字符串；样例工厂根据字符串换背景，真实主题必须由新工厂应用。动态主题对比可以在不同进程分别渲染两个主题，减少静态资源与全局状态污染。

数据尽量覆盖实际页面状态：正常、空列表、长名称、选中项、禁用状态、错误提示。使用确定样例数据，不依赖现场目录、摄像机、PLC 或检测引擎。控件自身会覆盖 DataContext 时，确认实际绑定源；不要盲目塞入匿名对象掩盖真实 ViewModel 的缺失。

## 生命周期与异步就绪

默认 `layout-only` 创建 Application 和 Dispatcher，但没有 Window，也不保证触发 Loaded 或有效 PresentationSource；适合纯 Visual / 控件布局。Measure / Arrange 的尺寸使用 DIP。

需要 Loaded、窗口祖先绑定、ActualWidth 承载、主题窗口挂接时：

```powershell
$outDir = & "$skillRoot\scripts\invoke-wpf-render.ps1" `
    -HarnessDir $harness.WorkDir -WindowHost -Width 1100 -Height 760 -Theme dark
```

工厂可以返回 UserControl / Page / 其他 FrameworkElement，也可以返回已有的业务 Window；Window 仅支持 `-WindowHost`。工具把窗口设置为屏外、不激活、不显示任务栏、无系统边框、固定尺寸，捕获 `Window.Content`。业务自绘标题栏属于内容，可截取；操作系统边框和阴影不在其中。窗口的 MinWidth / MaxWidth 等约束仍可能影响实际尺寸，核对 manifest 的 actualWidthDip / actualHeightDip。

Loaded 或控件内部代码仍可能主动激活窗口、弹出对话框、读取现场数据；运行前识别并替换这类路径。不要设置 Visibility=Collapsed、Opacity=0 或调用 Hide 来伪装离屏，它们可能改变布局或呈现状态。

对异步加载，在生成工程的就绪钩子等待公开的完成信号，例如：

```csharp
public static async Task WaitUntilReadyAsync(FrameworkElement view)
{
    var vm = (PreviewViewModel)view.DataContext;
    await vm.LoadCompleted.WaitAsync(TimeSpan.FromSeconds(15));
    // 如需验证选中状态，在这里设置它，再让宿主完成最后一轮布局。
}
```

`PreviewViewModel.LoadCompleted` 是示例契约，不是 WPF 内置 API。返回 Window 时按真实 Window / 内容的 DataContext 找对应 VM。不要在 UI 线程 `.Wait()` / `.Result` / Thread.Sleep；宿主提供 Dispatcher 消息循环，await 可让加载与绑定继续处理。延时只适合等待已知有限动画，不代表数据加载完成。动画影响稳定性时在样例工厂关闭框架动画或选择明确的静止状态。

在 `Cleanup` 中释放自己创建的订阅、计时器、Disposable 图像 / VM；不要释放业务程序正在使用的对象。宿主退出只关闭自己创建或承载的窗口。

## 截图尺寸、整页和独立窗口

工具输出固定视口，宽高默认 1280×800 DIP。PNG 像素为 `ceil(DIP × DPI / 96)`，例如 640×360 DIP、144 DPI 输出 960×540 像素。`-Dpi` 控制输出分辨率，不模拟真实多显示器 DPI 切换；依赖 GetDpi / HWND 的代码需在实际显示环境另测。

ScrollViewer 默认截取视口。要查看未滚动内容，可给页面更高的固定渲染高度，或在生成工程定制 Measure / Arrange 与截取根节点；固定高度只用于视觉检查，不代表所有数据行已生成。虚拟化列表未实例化的条目不会因截图自动出现。可以用小规模样例数据，或仅在临时 harness 中关闭虚拟化 / 分页；不要为截图改业务行为。

Popup、ToolTip、ContextMenu 在独立呈现源中，需定制宿主对它们的 Child / 对应 Visual 单独渲染。HwndHost、WindowsFormsHost、部分 WebView / HALCON / native 视口通常不属于可保证捕获的 WPF Visual；使用组件提供的图像导出接口，或在获得相应操作授权后进行实际窗口捕获。不要把 native 空白区域判成业务回归。
