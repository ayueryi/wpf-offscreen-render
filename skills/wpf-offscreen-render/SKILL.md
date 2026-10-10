---
name: wpf-offscreen-render
description: 在独立临时进程中把真实 WPF UserControl、Page、Window 或松散 XAML 离屏渲染成 PNG，同时输出绑定错误、布局问题、实际尺寸、DPI 等结构化摘要，用于修改 WPF 界面后验证布局、主题、数据绑定和视觉回归；不启动业务程序、不抢焦点，支持 .NET Framework 4.7.2–4.8.1 与 .NET 5–10。用户要截图、预览或查看 WPF / XAML 界面效果，检查绑定错误，或对比改动前后界面时使用（render, screenshot or preview a WPF view or XAML offscreen; RenderTargetBitmap; WPF visual regression）。不适用于 WinUI、UWP、Avalonia、MAUI、WinForms。
---

# WPF 离屏渲染

在独立临时进程中创建 WPF Visual，通过 `RenderTargetBitmap` 输出 PNG；使用真实控件、真实样式和确定的样例数据，不依赖 Gallery 或生产程序的启动入口。渲染需要 Windows；云端 Linux 容器中的会话无法使用。

下文的“插件根目录”是此 SKILL.md 上两级的目录（含 `mcp/`、`scripts/`、`references/`）。

## 调用方式

优先使用 MCP 工具（作为插件安装时自动可用，服务器名 `wpf-offscreen-render`）：

| 工具 | 用途 |
| --- | --- |
| `list_views` | 列出业务项目 `wpf-render.json` 中登记的视图预设 |
| `render_view` | 渲染一个视图（或预设），返回 JSON 摘要与截图（`element` 另附元素截图） |
| `render_matrix` | 一次渲染多个主题 × 尺寸 × DPI，返回汇总与总览图 |
| `compare_snapshots` | 对比两次渲染的 `outDir`，返回变化区域与差异图 |
| `get_layout` | 按元素名 / 文本或问题类型查询某次渲染的布局树，不必读取整个 `layout.json` |
| `self_test` | 环境自检 |

没有这些工具时（只装了 skill，或 MCP 未启用），改用插件根目录下的 PowerShell 脚本，参数一一对应：`scripts/render.ps1`（渲染与多组合）、`scripts/compare-snapshots.ps1`、`tests/run-tests.ps1 -Quick`（自检）；`layout.json` 在渲染输出目录中。完整参数见 [cli.md](../../references/cli.md)。

## 选择模式

| 场景 | 模式 | 要点 |
| --- | --- | --- |
| 普通控件、静态布局、资源与绑定检查 | 默认 `layout-only` | 不创建 Window；显式 Measure / Arrange / UpdateLayout |
| 依赖 Loaded、PresentationSource、窗口祖先、实际承载尺寸的页面 | `windowHost` | 创建屏外窗口，不激活、不显示在任务栏；仍需 Windows 桌面会话 |
| 页面切换卡顿、加载耗时、线程阻塞 | 补充性能诊断 | 快照只能证明某状态下的外观；另测 UI 线程耗时、Dispatcher 心跳和数据加载完成时间 |

## 操作流程

1. 首次在某台机器上使用，或渲染异常怀疑是环境问题时，先调用 `self_test`（会构建两个宿主；通过时输出 `2 通过，0 失败`）。检查控件构造和 Loaded 是否触发硬件、网络或写入；用样例 ViewModel / stub 服务隔离这些行为。此 skill 不授予启动生产程序、连接设备或 Git 操作的权限。
2. 业务项目根目录有 `wpf-render.json` 时，优先按预设渲染：先 `list_views`（`config` 为该目录），再 `render_view`（`config` + `preset`；修改了业务代码时加 `build: true`，由预设的 build 命令先构建）。预设的字段与 DataContext 的三种来源见 [integration.md](../../references/integration.md#业务项目接入wpf-renderjson)。没有预设时，修改业务 UI 后先构建业务项目，再调用 `render_view`：
   - `assemblyPaths`：业务程序集的绝对路径，优先指向应用（exe）的输出目录，那里依赖最全。TFM（.NET Framework 4.7.2 – 4.8.1 / .NET 5 – 10）与位数（x86 / x64）据此自动推断，不兼容时直接报错。
   - `viewType`（需无参构造）或 `xaml`（松散 XAML，无 `x:Class` / 事件，可经 `clr-namespace;assembly=` 引用业务控件）；`dataContextType`（需无参构造）；`resourceDictionaries` 按顺序合并，`{theme}` 替换为主题。
   - 不传视图参数时渲染内置样例，不要用样例截图冒充业务页面验证。
   - 同一组程序集复用缓存宿主：只换视图、主题、尺寸时跳过构建；程序集或同目录 DLL 变化时自动重新构建。
   - 需要同时看多个主题 / 尺寸 / DPI 时用 `render_matrix`，先看总览图再按需打开单张；只关心某个控件时传 `element`（`x:Name`）。
3. DataContext 需要构造参数或 stub 服务时，用 `dataContextFactory`（无参静态工厂方法）；还需要配置资源、等待异步就绪、设置选中态或清理时，用 `factoryFile` 指向业务仓库中受版本管理的 `ViewFactory.cs`。只做一次性探查时也可以改用两步脚本：`scripts/new-wpf-harness.ps1` 生成工程，修改其中的 `ViewFactory.cs`，再用 `scripts/invoke-wpf-render.ps1 -HarnessDir` 渲染。异步页面在 `ViewFactory.WaitUntilReadyAsync` 等待明确完成信号；ContextIdle / 固定延时不能代替业务完成信号。详见 [接入真实界面](../../references/integration.md)。
4. 先读 JSON 摘要再看图：
   - `status`：`ok` / `binding-issues` / `failed:<阶段>`（`build` / `locate` / `start` / `render` / `timeout`）；多组合的汇总为 `ok` / `binding-issues` / `failed`，逐个组合看 `results`。
   - `bindingIssues`：每条一行，如 `TextBlock#Name.Text <- Path=CustomerNmae（数据源 OrderVm）：…`，直接定位到绑定。
   - `layoutIssues`：自动布局检查（`text-truncated` 文本放不下、`clipped` 被布局空间裁切、`overlap` 文本重叠、`zero-size`、`out-of-viewport`）。它们是线索不是结论，不影响状态；逐条对照截图确认，需要坐标时用 `get_layout` 按元素查询。
   - 失败时看 `buildErrors` 与 `error`，细节在 `outDir` 下的 `build.log`、`error.txt`、`render.stderr.log`。
   实际查看截图后再决定是否修正布局。详细验收与故障定位见 [验证和排障](../../references/verification.md)。
5. 验证改动效果时，修改前先渲染一次作为基线，修改后用 `compare_snapshots`（`before` / `after` 为两次的 `outDir`）对比：看 `changedBoundsDip` 是否只落在预期区域、`environmentDifferences` 是否为空，并查看差异图（变化像素标红）。
6. 报告真实页面 / 样例、模式、尺寸与 DPI、主题、绑定检查、布局检查、视觉结论及未覆盖内容，提供产物绝对路径。临时产物不写入仓库。若用户要求保存基线，另选稳定目录，保留旧基线再生成新快照。

## 输出与执行约定

- 每次渲染创建独立的 `render-时间-GUID` 输出目录；缓存宿主与渲染结果超过 7 天未使用会被自动清理，需要保留的截图另存。
- 生成的宿主工程自带隔离用的 `Directory.Build.props` / `.targets` / `Directory.Packages.props` 与空的 `global.json`，并在宿主目录内构建，放在业务仓库内或从业务仓库目录调用都不会继承其构建配置与锁定的 SDK。
- `layout.json`、`elementRectDip` 与 `compare_snapshots` 的区域都是截图坐标（DIP），可以直接互相对照。
- `background` 默认 `auto`：业务 Window 或已被样式设置的窗口背景优先，否则按主题取白色 / `#1E1E1E`；`transparent` 保留 alpha。底色只是查看用的衬底，不代表业务背景。
- 只对自己启动的渲染子进程设置超时（默认 120 秒），不会终止其他应用。
- 宿主注入唯一的错误绑定作为监听自检，只排除这一条标记；`bindingTraceVerified` 为 false 时绑定统计不可信。
- `manifest.json` 记录渲染模式、主题标签、尺寸、DPI、SHA256、TFM / 运行时 / 进程架构、绑定与布局问题条数。主题由视图工厂实际应用，标签本身不会替业务 UI 切换主题。
- 原生 HWND 内容、Popup 等独立窗口和系统窗口边框不在普通 Visual 快照的保证范围内。具体限制见 [验证和排障](../../references/verification.md)。
