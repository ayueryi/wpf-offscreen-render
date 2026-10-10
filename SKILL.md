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
2. 运行生成器，默认在 `%TEMP%` 建立唯一目录。`$skillRoot` 填此 SKILL.md 所在目录的绝对路径（不要依赖当前目录）。不引用业务程序集时默认 `net8.0-windows`；引用后自动推断，也可显式传 `-TargetFramework net472` / `net48` / `net481` / `netN.0-windows` 和 `-Platform`，与程序集不兼容时生成器直接报错：

   ```powershell
   $skillRoot = '<此 skill 目录的绝对路径>'
   $harness = & "$skillRoot\scripts\new-wpf-harness.ps1"
   & "$skillRoot\scripts\invoke-wpf-render.ps1" -HarnessDir $harness.WorkDir -Theme light
   if ($LASTEXITCODE -ne 0) { throw '渲染或绑定检查失败，请检查输出日志' }
   ```

3. 不带视图参数时渲染内置样例，不要用样例截图冒充业务页面验证。接入真实页面优先用**免代码参数**，按类型名或松散 XAML 创建视图，主题字典里的 `{theme}` 会替换成 `-Theme` 的值：

   ```powershell
   $harness = & "$skillRoot\scripts\new-wpf-harness.ps1" -AssemblyPath 'C:\work\MyApp\bin\Debug\net8.0-windows\MyUi.dll' `
       -ViewType MyUi.Views.OrderView -DataContextType MyUi.Preview.OrderPreviewVm `
       -ResourceDictionary '/MyUi;component/Themes/Generic.xaml', '/MyUi;component/Themes/{theme}.xaml'
   # 或 -Xaml 'C:\path\probe.xaml'：松散 XAML（无 x:Class / 事件），可经 clr-namespace;assembly= 引用业务控件
   ```

   这些参数写入生成工程的 `harness.json`，之后直接改 `harness.json` 或 XAML 文件再 `-NoBuild` 渲染即可，无需重建。DataContext 需要构造参数、需要 stub 服务、要等异步就绪或做清理时，改为在生成工程中修改 `ViewFactory.cs`；详见 [接入真实界面](references/integration.md)。
4. 按需要运行 `-Width 1280 -Height 800 -Dpi 96 -Theme dark`，或加 `-WindowHost`。异步页面在 `ViewFactory.WaitUntilReadyAsync` 等待明确完成信号，再截取；ContextIdle / 固定延时不能代替业务完成信号。
5. 执行器最后打印 JSON 摘要（同存为 `summary.json`）：`status`（`ok` / `binding-issues` / `failed:<阶段>`）、`snapshot` 路径、`sourceViewType`、实际尺寸、前几条绑定问题、编译错误与异常摘要。先读摘要定位；需要细节再看 `manifest.json`、`binding-errors.txt`、`error.txt` 和 build / render 日志。用可用的图片查看工具实际查看 PNG，再决定是否修正布局。详细验收与故障定位见 [验证和排障](references/verification.md)。
6. 报告真实页面 / 样例、模式、尺寸与 DPI、主题、绑定检查、视觉结论及未覆盖内容，提供产物绝对路径。临时产物不写入仓库。若用户要求保存基线，另选稳定目录，保留旧基线再生成新快照。

## 输出与执行约定

- 生成器拒绝覆盖已有目录；执行器每次创建独立 `render-时间-GUID` 目录。
- 默认执行器会构建到工程内固定的 `out\`；`-NoBuild` 仅用于已确认 C# 代码与引用未变化的工程（只改 `harness.json` / 松散 XAML 时可用）。
- 生成工程自带空的 `Directory.Build.props` / `.targets` 与关闭集中包管理的 `Directory.Packages.props`，放在业务仓库内也不会继承其构建配置。
- `-Background auto`（默认）在 PNG 底部铺不透明底色：业务 Window 或已被样式 / 本地值设置的窗口背景优先，否则按主题标签取白色 / `#1E1E1E`；`transparent` 保留 alpha，也可传 `#RRGGBB`。底色只是查看用的衬底，不代表业务背景；实际取值记录在 manifest 的 `background` / `backgroundSource`。
- 执行器仅对自己启动的渲染子进程设置超时（默认 120 秒）；不会终止其他应用。构建日志与渲染 stdout / stderr 分别保留。
- 宿主注入唯一的错误绑定作为监听自检，只排除这一条标记；不能清空全部绑定日志。真实绑定告警或错误导致退出码 2，自检 / 渲染失败退出码 1，正常退出码 0。
- `manifest.json` 记录渲染模式、主题标签、DIP / 像素尺寸、DPI、SHA256、绑定自检与问题条数。主题由工厂实际应用，标签本身不会替业务 UI 切换主题。
- 原生 HWND 内容、Popup 等独立窗口和系统窗口边框不在普通 Visual 快照的保证范围内。具体限制与官方依据见 [验证和排障](references/verification.md)。
