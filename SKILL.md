---
name: wpf-offscreen-render
description: 独立的 Windows WPF 离屏渲染与界面快照工作流。用于把真实 UserControl、Page 或 Window 渲染为 PNG，检查布局、主题、尺寸、DPI、数据绑定和视觉回归。包含临时 STA 渲染工程生成器、渲染执行器和接入说明；不依赖 UiGallery、HR 或特定 UI 框架。用户提到 WPF 离屏截图、RenderTargetBitmap、无焦点界面预览或修改 WPF 后验证视觉效果时使用。
---

# WPF 离屏渲染

在独立临时进程中创建 WPF Visual，通过 `RenderTargetBitmap` 输出 PNG；使用真实控件、真实样式和确定的样例数据。此 skill 不依赖任何 Gallery 或生产程序的启动入口。

随附工具支持 .NET 8 及以上 WPF。旧 .NET Framework 项目可参考渲染流程，但需另建兼容宿主，不能直接跨运行时引用业务程序集。

## 选择模式

| 场景 | 模式 | 要点 |
| --- | --- | --- |
| 普通控件、静态布局、资源与绑定检查 | 默认 `layout-only` | 不创建 Window；显式 Measure / Arrange / UpdateLayout |
| 依赖 Loaded、PresentationSource、窗口祖先、实际承载尺寸的页面 | `-WindowHost` | 创建屏外窗口，ShowActivated=false，ShowInTaskbar=false；仍需 Windows 桌面会话 |
| 页面切换卡顿、加载耗时、线程阻塞 | 补充性能诊断 | 快照只能证明某状态下的外观；另测 UI 线程耗时、Dispatcher 心跳和数据加载完成时间 |

## 操作流程

1. 确认 Windows、PowerShell 7、匹配目标项目的 .NET SDK / WindowsDesktop Runtime。检查控件构造和 Loaded 是否触发硬件、网络或写入；用样例 ViewModel / stub 服务隔离这些行为。此 skill 不授予启动生产程序、连接设备或 Git 操作的权限。
2. 从 skill 目录运行生成器，默认在 `%TEMP%` 建立唯一目录。示例使用 `net8.0-windows`，接入时改成目标项目兼容的 TFM：

   ```powershell
   $skillRoot = (Get-Location).Path # 当前位于此 skill 的目录
   $harness = & "$skillRoot\scripts\new-wpf-harness.ps1" -TargetFramework net8.0-windows
   & "$skillRoot\scripts\invoke-wpf-render.ps1" -HarnessDir $harness.WorkDir -Theme light
   if ($LASTEXITCODE -ne 0) { throw '渲染或绑定检查失败，请检查输出日志' }
   ```

3. 默认工程附带可运行样例。验证真实页面前，在**生成的工程**里修改 `ViewFactory.cs`，配置程序集引用、资源字典、主题、DataContext 和状态；读取 [接入真实界面](references/integration.md)。不要用样例截图冒充业务页面验证。
4. 按需要运行 `-Width 1280 -Height 800 -Dpi 96 -Theme dark`，或加 `-WindowHost`。异步页面在 `ViewFactory.WaitUntilReadyAsync` 等待明确完成信号，再截取；ContextIdle / 固定延时不能代替业务完成信号。
5. 查看输出目录的 `snapshot.png`、`manifest.json`、`binding-errors.txt`；失败查看 `error.txt` 和 build / render 日志。用可用的图片查看工具实际查看 PNG，再决定是否修正布局。详细验收与故障定位见 [验证和排障](references/verification.md)。
6. 报告真实页面 / 样例、模式、尺寸与 DPI、主题、绑定检查、视觉结论及未覆盖内容，提供产物绝对路径。临时产物不写入仓库。若用户要求保存基线，另选稳定目录，保留旧基线再生成新快照。

## 输出与执行约定

- 生成器拒绝覆盖已有目录；执行器每次创建独立 `render-时间-GUID` 目录。
- 默认执行器会构建；`-NoBuild` 仅用于已确认代码与引用未变化的工程。
- 执行器仅对自己启动的渲染子进程设置超时（默认 120 秒）；不会终止其他应用。构建日志与渲染 stdout / stderr 分别保留。
- 宿主注入唯一的错误绑定作为监听自检，只排除这一条标记；不能清空全部绑定日志。真实绑定告警或错误导致退出码 2，自检 / 渲染失败退出码 1，正常退出码 0。
- `manifest.json` 记录渲染模式、主题标签、DIP / 像素尺寸、DPI、SHA256、绑定自检与问题条数。主题由工厂实际应用，标签本身不会替业务 UI 切换主题。
- 原生 HWND 内容、Popup 等独立窗口和系统窗口边框不在普通 Visual 快照的保证范围内。具体限制与官方依据见 [验证和排障](references/verification.md)。
