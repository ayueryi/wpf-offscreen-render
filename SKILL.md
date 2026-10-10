---
name: wpf-offscreen-render
description: 在独立临时进程中把真实 WPF UserControl、Page、Window 或松散 XAML 离屏渲染成 PNG，同时输出绑定错误、实际尺寸、DPI 等结构化摘要，用于修改 WPF 界面后验证布局、主题、数据绑定和视觉回归；不启动业务程序、不抢焦点，支持 .NET Framework 4.7.2–4.8.1 与 .NET 5–10。用户要截图、预览或查看 WPF / XAML 界面效果，检查绑定错误，或对比改动前后界面时使用（render, screenshot or preview a WPF view or XAML offscreen; RenderTargetBitmap; WPF visual regression）。不适用于 WinUI、UWP、Avalonia、MAUI、WinForms。
---

# WPF 离屏渲染

在独立临时进程中创建 WPF Visual，通过 `RenderTargetBitmap` 输出 PNG；使用真实控件、真实样式和确定的样例数据。此 skill 不依赖任何 Gallery 或生产程序的启动入口。

随附工具支持 .NET Framework 4.7.2 / 4.8 / 4.8.1 与 .NET 5 – 10 的 WPF。生成器按 `-AssemblyPath` 的程序集自动推断宿主 TFM 与位数（x86 / x64），.NET Framework 与 .NET 程序集不能混在同一宿主。

## 选择模式

| 场景 | 模式 | 要点 |
| --- | --- | --- |
| 普通控件、静态布局、资源与绑定检查 | 默认 `layout-only` | 不创建 Window；显式 Measure / Arrange / UpdateLayout |
| 依赖 Loaded、PresentationSource、窗口祖先、实际承载尺寸的页面 | `-WindowHost` | 创建屏外窗口，ShowActivated=false，ShowInTaskbar=false；仍需 Windows 桌面会话 |
| 页面切换卡顿、加载耗时、线程阻塞 | 补充性能诊断 | 快照只能证明某状态下的外观；另测 UI 线程耗时、Dispatcher 心跳和数据加载完成时间 |

## 操作流程

1. 确认 Windows、PowerShell 7、匹配目标项目的 .NET SDK / WindowsDesktop Runtime。首次在某台机器上使用，或渲染异常怀疑是环境问题时，先运行 `& "$skillRoot\tests\run-tests.ps1" -Quick` 自检（会构建两个宿主；通过时输出 `2 通过，0 失败`）。检查控件构造和 Loaded 是否触发硬件、网络或写入；用样例 ViewModel / stub 服务隔离这些行为。此 skill 不授予启动生产程序、连接设备或 Git 操作的权限。
2. 免代码接入优先用一步脚本 `render.ps1`：生成（或复用缓存的）宿主、构建、渲染，最后打印 JSON 摘要并返回输出目录。`$skillRoot` 填此 SKILL.md 所在目录的绝对路径（不要依赖当前目录）。不带视图参数时渲染内置样例，不要用样例截图冒充业务页面验证。

   ```powershell
   $skillRoot = '<此 skill 目录的绝对路径>'
   $outDir = & "$skillRoot\scripts\render.ps1" -AssemblyPath 'C:\work\MyApp\bin\Debug\net8.0-windows\MyUi.dll' `
       -ViewType MyUi.Views.OrderView -DataContextType MyUi.Preview.OrderPreviewVm `
       -ResourceDictionary '/MyUi;component/Themes/Generic.xaml', '/MyUi;component/Themes/{theme}.xaml' -Theme dark
   # 或 -Xaml 'C:\path\probe.xaml'：松散 XAML（无 x:Class / 事件），可经 clr-namespace;assembly= 引用业务控件
   ```

   - TFM 与位数按 `-AssemblyPath` 自动推断（.NET Framework 4.7.2 – 4.8.1 / .NET 5 – 10，x86 / x64），也可显式传 `-TargetFramework`、`-Platform`；不兼容时直接报错。
   - 同一组程序集复用 `%TEMP%\wpf-render-cache` 中的宿主；只换视图、主题、尺寸时跳过构建，业务程序集或同目录 DLL 变化时自动重新构建。修改业务 UI 后先构建业务项目，再调用 `render.ps1`。
   - `{theme}` 替换为 `-Theme` 的值；其他参数：`-Width 1280 -Height 800 -Dpi 96 -Background auto -WindowHost`。
3. DataContext 需要构造参数或 stub 服务、需要等待异步就绪、要设置选中态或做清理时，改用两步：`new-wpf-harness.ps1` 生成工程，修改其中的 `ViewFactory.cs`，再用 `invoke-wpf-render.ps1 -HarnessDir` 渲染。异步页面在 `ViewFactory.WaitUntilReadyAsync` 等待明确完成信号；ContextIdle / 固定延时不能代替业务完成信号。详见 [接入真实界面](references/integration.md)。
4. 依赖 Loaded、窗口祖先或实际承载尺寸的页面加 `-WindowHost`。
5. 先读 JSON 摘要（同存为 `summary.json`）再看图：
   - `status`：`ok` / `binding-issues`（退出码 2）/ `failed:<阶段>`（退出码 1）。
   - `bindingIssues`：每条一行，如 `TextBlock#Name.Text <- Path=CustomerNmae（数据源 OrderVm）：…`，直接定位到绑定。
   - `layoutIssues`：自动布局检查（`text-truncated` 文本放不下、`clipped` 被布局空间裁切、`overlap` 文本重叠、`zero-size`、`out-of-viewport`）。它们是线索不是结论，不影响退出码；逐条对照截图确认，必要时在 `layout.json` 中按元素名查看完整视觉树坐标。
   - 失败时看 `buildErrors` 与 `error`，细节在 `build.log`、`error.txt`、`render.stderr.log`。
   用可用的图片查看工具实际查看 PNG，再决定是否修正布局。详细验收与故障定位见 [验证和排障](references/verification.md)。
6. 报告真实页面 / 样例、模式、尺寸与 DPI、主题、绑定检查、视觉结论及未覆盖内容，提供产物绝对路径。临时产物不写入仓库。若用户要求保存基线，另选稳定目录，保留旧基线再生成新快照。

## 输出与执行约定

- 生成器拒绝覆盖已有目录；执行器每次创建独立 `render-时间-GUID` 目录。`render.ps1` 的缓存宿主与渲染结果超过 7 天未使用会被自动清理（`-RetentionDays`），需要保留的截图另存。
- 默认执行器会构建到工程内固定的 `out\`；`-NoBuild` 仅用于已确认 C# 代码与引用未变化的工程（只改 `harness.json` / 松散 XAML 时可用）。
- 生成工程自带空的 `Directory.Build.props` / `.targets` 与关闭集中包管理的 `Directory.Packages.props`，放在业务仓库内也不会继承其构建配置。
- `-Background auto`（默认）在 PNG 底部铺不透明底色：业务 Window 或已被样式 / 本地值设置的窗口背景优先，否则按主题标签取白色 / `#1E1E1E`；`transparent` 保留 alpha，也可传 `#RRGGBB`。底色只是查看用的衬底，不代表业务背景；实际取值记录在 manifest 的 `background` / `backgroundSource`。
- 执行器仅对自己启动的渲染子进程设置超时（默认 120 秒）；不会终止其他应用。构建日志与渲染 stdout / stderr 分别保留。
- 宿主注入唯一的错误绑定作为监听自检，只排除这一条标记；不能清空全部绑定日志。真实绑定告警或错误导致退出码 2，自检 / 渲染失败退出码 1，正常退出码 0。
- `manifest.json` 记录渲染模式、主题标签、DIP / 像素尺寸、DPI、SHA256、TFM / 运行时 / 进程架构、绑定自检与问题条数、布局问题条数。主题由工厂实际应用，标签本身不会替业务 UI 切换主题。
- 原生 HWND 内容、Popup 等独立窗口和系统窗口边框不在普通 Visual 快照的保证范围内。具体限制与官方依据见 [验证和排障](references/verification.md)。
