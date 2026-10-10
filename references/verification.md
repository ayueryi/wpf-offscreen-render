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
$before = Get-Content -LiteralPath (Join-Path $baselineDir 'manifest.json') -Raw | ConvertFrom-Json
$after = Get-Content -LiteralPath (Join-Path $outDir 'manifest.json') -Raw | ConvertFrom-Json
[pscustomobject]@{
    SameHash = $before.sha256 -eq $after.sha256
    BeforeImage = Join-Path $baselineDir 'snapshot.png'
    AfterImage = Join-Path $outDir 'snapshot.png'
}
```

SHA256 相等说明 PNG 字节相同；变化不自动等于回归。并排看前后图，必要时用可用图像比较工具生成差异图，结合修改目的判断。字体渲染与机器环境变化可能造成像素差异，不能用一个全局阈值替代判断。不要自动覆盖用户认可的基线。

## 故障定位

| 现象 | 优先检查 |
| --- | --- |
| 编译缺类型、加载程序集失败 | TFM、DLL / NuGet 版本、运行时依赖和内容文件，查看 build.log / error.txt |
| ResourceReferenceKeyNotFound / XamlParseException | 资源合并顺序、pack URI、Theme bootstrap、内层异常 |
| 空白或布局为零 | Measure / Arrange、Visibility、返回根元素；是否依赖 Loaded，需要 WindowHost |
| 样式正确但数据缺失 | 实际 DataContext、Binding.Path、异步完成信号，查看 binding-errors.txt |
| 监听自检未命中 | PresentationTraceSources.Refresh、日志注册时机；不要把空日志当没有绑定错误 |
| 截图停在加载中 | WaitUntilReadyAsync 是否等真实任务；不能仅靠 ContextIdle |
| 窗口出现在屏幕或弹对话框 | Loaded / 构造函数自身行为，停止该次验证并隔离副作用，不扩大启动范围 |
| 原生视口或菜单没出现 | HwndHost airspace / Popup 独立窗口限制，选对应组件导出或独立捕获 |
| 重复输出不稳定 | 主题静态状态、动画、时间、随机数据、字体、异步任务未就绪 |
| 构建输出锁定 | 使用独立 harness / 临时输出；不擅自终止用户运行中的业务程序 |

## 性能验证边界

RenderTargetBitmap 成功不代表页面切换不卡顿。检查性能时分别测构造 / XAML 初始化、Loaded → 就绪、数据加载与首帧等待；UI 线程操作用 Dispatcher 计时，后台扫描 / 图像解码与 UI 发布区分记录。用 DispatcherTimer 心跳查看操作期间 UI 是否持续处理消息。

`dotnet build`、进程启动、固定等待和 PNG 编码不能混入页面切换耗时。首次 / 重复加载分别测，保持数据规模一致。临时样例只证明隔离路径，不能推出现场整个窗口的耗时。报告中区分“已生成快照”“样例性能通过”和“真实程序实测”。

## 官方依据

- [RenderTargetBitmap](https://learn.microsoft.com/en-us/dotnet/api/system.windows.media.imaging.rendertargetbitmap)：将 Visual 转为位图，构造参数包含像素尺寸、DPI 和像素格式。
- [WPF Threading model](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/threading-model)：Dispatcher、UI 线程与异步工作。
- [WPF Layout](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/layout)：Measure / Arrange 布局阶段。
- [Technology Regions / airspace](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/technology-regions-overview)：WPF 与 native HWND 互操作的呈现边界。

以上是 WPF 文档，不是 UWP / WinUI 的同名 RenderTargetBitmap API。接入第三方控件时以其实现和当前文档补充限制。
