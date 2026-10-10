# 验证、比较与排障

## 产物验收

执行完成后读取 manifest 和绑定日志，并实际打开 PNG：

```powershell
$manifest = Get-Content -LiteralPath (Join-Path $outDir 'manifest.json') -Raw | ConvertFrom-Json
$manifest | Select-Object mode, theme, widthDip, heightDip, pixelWidth, pixelHeight, dpi, `
    actualWidthDip, actualHeightDip, bindingTraceVerified, bindingWarningOrErrorCount
Get-Content -LiteralPath (Join-Path $outDir 'binding-errors.txt')
```

先读 `summary.json`：`bindingIssues` 是解析后的单行绑定结论，`layoutIssues` 是自动布局检查的前 10 条。再使用当前代理可用的图片工具（如 Codex 的 `view_image`）查看真实 PNG。确认没有空白 / 全透明图、裁切、文字重叠、缺失图标、主题资源失效或意外占位状态。manifest 与退出码只能证明生成和监听结果，不能替代图片检查。

绑定监听在构造目标 View 前启用，先制造唯一错误绑定验证采集有效，仅过滤该标记。退出码：0=渲染与监听通过且无真实绑定问题，1=构建 / 渲染 / 监听自检失败，2=真实绑定告警或错误。绑定问题仍会保留 PNG 方便排查。未生成 manifest / PNG 的失败应看 build.log、error.txt、render.stderr.log；不应该描述为“视觉通过”。

## 布局检查

`layout.json` 的 `issues` 由宿主在截图后遍历视觉树得出，只检查内容元素（有文本的 `TextBlock`、有图像的 `Image`、`Control`）：

- `text-truncated`：用元素自身的字体与字号测量文本，宽度（不换行）或高度（换行）超过分到的布局空间。已设置 `TextTrimming` 的会注明“已显示省略号”；这是否可接受由业务决定。
- `clipped`：`Image` / `Control` 分到的布局空间小于所需尺寸，或任意内容元素被祖先容器的布局空间裁掉一部分。`ScrollViewer` 视口、`ClipToBounds`、显式 `Clip` 属于有意裁切，不报告。
- `overlap`：两段文本的字形区域重叠超过较小者面积的 15%。常见原因是同一 `Grid` 单元格、负边距或 `Canvas` 定位冲突。
- `zero-size`：有内容的元素宽或高为 0，通常是固定尺寸、`*` 行列分配为 0 或父容器被压缩。
- `out-of-viewport`：可见部分超出渲染视口；可能是视口太小，也可能是页面真的溢出，换更大的 `-Width` / `-Height` 再渲染区分。

这些是线索，不影响退出码。逐条对照 PNG 确认后再修改；确认属于有意设计的，在报告中说明即可。需要定位某个元素时，在 `layout.json` 的 `nodes` 中按 `name` 或 `text` 查 `rect`（相对根元素的 DIP 坐标 `[x, y, w, h]`）。检查不覆盖：颜色对比度、图标缺失、字形回退、Popup / 原生窗口内容，以及 `Visibility` 非 `Visible` 的元素。

## 视觉基线

同一 View 的前后比较应保持机器、字体、资源版本、样例数据、视口、主题、DPI 与动画状态一致。每次使用新输出目录，避免把旧图误当本次结果。

```powershell
& "$skillRoot\scripts\compare-snapshots.ps1" -Before $baselineDir -After $outDir
# status same / different，changedRatio、changedBoundsDip（对照 layout.json 定位元素），差异图 diff.png（变化像素标红）
```

- `environmentDifferences` 非空时（主题、DPI、运行时、机器等不同），像素差异可能来自渲染条件，先统一条件再比较。
- `same` 说明像素一致；`different` 不自动等于回归，结合差异图与修改目的判断。字体渲染、系统更新、显卡驱动都可能带来像素差异，`-Tolerance` 只用于忽略抗锯齿级别的微小差别，不能代替判断。
- 基线保存在用户选定的稳定目录；生成新基线前保留旧基线，不要自动覆盖用户认可的基线，临时产物不要提交进业务仓库。

## 故障定位

| 现象 | 优先检查 |
| --- | --- |
| `找不到类型`（harness.json 模式） | 类型名是否含完整命名空间、程序集是否在 `-AssemblyPath` 中 |
| 编译缺类型、加载程序集失败 | TFM、DLL / NuGet 版本、运行时依赖与内容文件；看 `build.log` / `error.txt` |
| `ResourceReferenceKeyNotFoundException` / `XamlParseException` | 资源合并顺序、pack URI、Theme bootstrap；看内层异常 |
| 空白图或 `actual*Dip` 为 0 | Measure / Arrange、Visibility、返回的根元素；是否依赖 `Loaded`（改用 `-WindowHost`） |
| 样式正确但数据缺失 | 实际 `DataContext`、`Binding.Path`、异步完成信号；看 `binding-errors.txt` |
| `bindingTraceVerified=false` | `PresentationTraceSources.Refresh`、监听注册时机；**不要把空日志当成没有绑定错误** |
| 截图停在“加载中” | `WaitUntilReadyAsync` 是否在等真实任务，而不是 `ContextIdle` |
| 窗口出现在屏幕上 / 弹出对话框 | 构造函数或 `Loaded` 的自身行为；停止本次验证并隔离副作用 |
| 原生视口或菜单缺失 | 见下方[已知限制](#已知限制) |
| 多次输出不稳定 | 主题静态状态、动画、当前时间、随机数据、字体、异步未就绪 |
| 构建输出被锁定 | 使用独立 harness / 临时输出；不要擅自结束正在运行的业务程序 |
| MCP 服务器连接失败 | `pwsh` 与 `dotnet` 是否在 PATH 中；首次编译是否能访问 NuGet（见上文离线说明）；编译输出在代理的 MCP 日志（stderr）中 |
| 结束前自动验证没有触发 | 是否 `verifyOnStop: true`、是否已用 `trust-project.ps1` 授权且授权后未修改配置（`-List` 查看）、改动的文件是否命中 `watch`、改动是否已提交（hook 只看未提交的改动） |
| 超时（`error.txt` 提示超过 N 秒） | 就绪信号永不完成、UI 线程被同步阻塞；必要时调大 `-TimeoutSeconds` 定位 |

## 离线与内网环境

- **MCP 服务器**：首次启动时 `mcp/start.ps1` 需要从 NuGet 还原 `ModelContextProtocol`。离线机器上可以先在联网的同版本环境中启动一次（或运行 `tests/run-tests.ps1 -Filter mcp-server`），再把 `%LOCALAPPDATA%\wpf-offscreen-render\mcp\<哈希>` 整个目录复制到离线机器的相同位置；哈希由服务器源码决定，插件版本相同即可复用。也可以通过 `WPF_RENDER_MCP_CACHE` 指定缓存目录。
- **.NET Framework 宿主**：需要安装对应版本的 .NET Framework Developer Pack；未安装时 SDK 会尝试从 NuGet 还原引用程序集。
- **业务程序集的 NuGet 依赖**：指向应用（exe）的输出目录时依赖已在目录中，不需要联网。

## 已知限制

| 限制 | 原因 / 替代方案 |
| --- | --- |
| `Popup`、`ToolTip`、`ContextMenu` 不出现在快照里 | 它们在独立的呈现源（独立 HWND）中；需在定制宿主中对其 `Child` 单独渲染 |
| `HwndHost`、`WindowsFormsHost`、WebView、HALCON 等 native 视口为空白 | WPF / HWND airspace 限制，`RenderTargetBitmap` 不捕获 native 内容；使用组件自身的图像导出接口，或获授权后做实际窗口捕获。**不要把 native 空白判定为回归** |
| 不含系统窗口边框和阴影 | 只截 `Window.Content`；业务自绘标题栏属于内容，会被截到 |
| 不能证明性能 | `RenderTargetBitmap` 成功不代表页面切换不卡；性能需单独计时，见下方“性能验证边界” |
| 不能证明交互 | 快照不覆盖输入、焦点、键盘导航 |
| `-WindowHost` 需要桌面会话 | 无交互会话的服务或 CI 代理可能失败 |
| .NET Core 3.x 程序 | 只支持 .NET Framework 4.7.2+ 与 .NET 5+ 宿主；3.x 程序集需升级，或显式 `-TargetFramework net5.0-windows` 等后自行验证兼容性 |
| 混用 .NET Framework 与 .NET 程序集 | 一个进程只能承载一种运行时，生成器会拒绝；分别生成宿主 |
| WinUI / UWP | 本工具针对 WPF 的 `System.Windows.Media.Imaging.RenderTargetBitmap`，与 WinUI / UWP 同名 API 无关 |

## 性能验证边界

RenderTargetBitmap 成功不代表页面切换不卡顿。检查性能时分别测构造 / XAML 初始化、Loaded → 就绪、数据加载与首帧等待；UI 线程操作用 Dispatcher 计时，后台扫描 / 图像解码与 UI 发布区分记录。用 DispatcherTimer 心跳查看操作期间 UI 是否持续处理消息。

`dotnet build`、进程启动、固定等待和 PNG 编码不能混入页面切换耗时。首次 / 重复加载分别测，保持数据规模一致。临时样例只证明隔离路径，不能推出现场整个窗口的耗时。报告中区分“已生成快照”“样例性能通过”和“真实程序实测”。

## 官方依据

- [RenderTargetBitmap](https://learn.microsoft.com/en-us/dotnet/api/system.windows.media.imaging.rendertargetbitmap)：将 Visual 转为位图，构造参数包含像素尺寸、DPI 和像素格式。
- [WPF Threading model](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/threading-model)：Dispatcher、UI 线程与异步工作。
- [WPF Layout](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/layout)：Measure / Arrange 布局阶段。
- [Technology Regions / airspace](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/technology-regions-overview)：WPF 与 native HWND 互操作的呈现边界。

以上是 WPF 文档，不是 UWP / WinUI 的同名 RenderTargetBitmap API。接入第三方控件时以其实现和当前文档补充限制。
