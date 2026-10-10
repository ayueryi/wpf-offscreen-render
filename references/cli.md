# 脚本参数与输出产物

`scripts/` 下各脚本的参数、渲染模式、输出文件、退出码与尺寸 / DPI 规则。使用流程见 [SKILL.md](../skills/wpf-offscreen-render/SKILL.md) 与 [README](../README.md)，接入业务界面见 [integration.md](integration.md)，验收与排障见 [verification.md](verification.md)。

## 脚本参数

### `scripts/new-wpf-harness.ps1`

生成一个新的 `RenderHarness` 工程，返回 `[pscustomobject]@{ WorkDir; ProjectPath; ConfigPath; TargetFramework; Platform }`。

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `-TargetFramework` | string | 自动 | `net472` / `net48` / `net481`，或 `net5.0-windows` … `net10.0-windows`（可带平台版本，如 `net8.0-windows10.0.19041.0`）。省略时读取 `-AssemblyPath` 的 `TargetFrameworkAttribute`：取同类中最高版本，低于 4.7.2 的 .NET Framework 程序集用 `net472`；没有业务程序集时为 `net8.0-windows`。显式指定但与业务程序集不兼容（类别不同或版本更低）时报错 |
| `-Platform` | string | 自动 | `AnyCPU` / `x86` / `x64` / `ARM64`，写入 `PlatformTarget`。省略时读取 `-AssemblyPath` 的 PE 头：存在 x86 程序集（含 C++/CLI 混合程序集与“首选 32 位”的 exe）或 x64 / ARM64 程序集就跟随它，否则 `AnyCPU`；要求冲突时报错 |
| `-WorkDir` | string | `%TEMP%\wpf-render-<GUID>` | 工程目录；**已存在则拒绝覆盖** |
| `-AssemblyPath` | string[] | 空 | 要引用的业务程序集（`.dll`，或 .NET Framework WPF 程序的 `.exe`）；以 `HintPath` + `Private=true` 写入 csproj（路径做 XML 转义，可含空格）。.NET Framework 与 .NET 程序集不能混用 |
| `-ViewType` | string | 空 | 要渲染的 View 类型（完整名或程序集限定名），需有无参构造；与 `-Xaml` 二选一 |
| `-Xaml` | string | 空 | 松散 XAML 文件（无 `x:Class` / 事件），可经 `clr-namespace;assembly=` 引用业务控件 |
| `-DataContextType` | string | 空 | 用无参构造创建并设为 View 的 `DataContext` |
| `-DataContextFactory` | string | 空 | 无参静态工厂方法 `Namespace.Type.Method`，返回值设为 `DataContext`；与 `-DataContextType` 二选一 |
| `-ResourceDictionary` | string[] | 空 | 按顺序合并的资源字典：pack URI、绝对路径，或相对当前目录的路径（生成时解析为绝对路径）；`{theme}` 替换为 `-Theme` 的值 |
| `-FactoryFile` | string | 空 | 用该文件替换工程中的 `ViewFactory.cs`。自定义工厂不调用 `ConfiguredView.TryCreate` 时，`-ViewType` / `-Xaml` / `-DataContext*` 不生效 |
| `-InferOnly` | switch | 关 | 只推断并返回 `TargetFramework` / `Platform`，不生成工程 |

相对路径（`-WorkDir`、`-AssemblyPath`、`-Xaml` 等）按 PowerShell 当前位置解析，UNC 路径可直接使用。视图参数写入 `harness.json`，渲染时才读取；之后修改它或 XAML 文件只需 `-NoBuild` 重新渲染。工程同时写入空的 `Directory.Build.props` / `.targets`、关闭集中包管理的 `Directory.Packages.props` 与空的 `global.json`，放在业务仓库里也不会继承上层构建配置。`dotnet` 按**当前目录**查找 `global.json`，`invoke-wpf-render.ps1` 因此在宿主目录内执行构建，业务仓库锁定的 SDK 版本不影响宿主。

生成的 csproj 关键属性：`OutputType=Exe`、`UseWPF=true`、`ImplicitUsings`、`Nullable`、`LangVersion=latest`、`PlatformTarget`。启动方式由 TFM 和位数决定：

| 宿主 | 启动方式 |
| --- | --- |
| .NET Framework | 直接运行 `out\RenderHarness.exe`，位数由 `PlatformTarget` 决定 |
| .NET，`AnyCPU` | `UseAppHost=false`，通过 `dotnet RenderHarness.dll` 启动；`RollForward=Major`，本机没有该主版本的 WindowsDesktop 运行时时使用更高版本 |
| .NET，固定 `x86` / `x64` / `ARM64` | `UseAppHost=true`，运行对应架构的 `RenderHarness.exe`，需安装该架构的 WindowsDesktop Runtime |

宿主源码只使用 .NET Framework 4.7.2 与 .NET 5+ 共有的 API（不依赖 `System.Text.Json` 等 NuGet 包），同一份 `Program.cs` / `ConfiguredView.cs` / `ViewFactory.cs` 适用于全部 TFM。定制 `ViewFactory.cs` 时同样只能用目标 TFM 存在的 API。.NET 5 / 6 / 7 已停止支持，构建时会出现 `NETSDK1138` 警告，不影响渲染。

### `scripts/render.ps1`

一步渲染，适合免代码接入。参数是 `new-wpf-harness.ps1` 的视图 / 程序集参数（`-AssemblyPath`、`-ViewType`、`-Xaml`、`-DataContextType`、`-DataContextFactory`、`-ResourceDictionary`、`-FactoryFile`、`-TargetFramework`、`-Platform`）加上 `invoke-wpf-render.ps1` 的渲染参数（`-Width`、`-Height`、`-Background`、`-WindowHost`、`-Element`、`-TimeoutSeconds`），另有：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Theme` | `light` | 可传多个，如 `-Theme light, dark` |
| `-Dpi` | `96` | 可传多个，如 `-Dpi 96, 144` |
| `-Size` | 无 | 多个视口，如 `-Size 1280x800, 800x600`；指定后忽略 `-Width` / `-Height` |
| `-FactoryFile` | 无 | 同生成器；内容变化时重新构建缓存宿主 |
| `-Preset` | 无 | `wpf-render.json` 中的视图名，见 [integration.md](integration.md#业务项目接入wpf-renderjson) |
| `-Config` | 从当前目录向上查找 | `wpf-render.json` 的路径或其所在目录 |
| `-Build` | 关 | 渲染前在配置目录执行预设的 `build` 命令，失败时抛出并附构建日志末尾 |
| `-CacheRoot` | `%TEMP%\wpf-render-cache` | 缓存宿主所在目录；清理只处理本工具创建的缓存目录（16 位十六进制名称），不会删除其中的其他内容 |
| `-NoCache` | 关 | 生成一次性宿主，不读写缓存 |
| `-RetentionDays` | `7` | 超过该天数未使用的缓存宿主与渲染结果会被删除 |

缓存键由程序集路径、`-TargetFramework` / `-Platform`、`-FactoryFile` 路径与工具版本（生成器和 `assets/*.cs` 的哈希）组成；视图参数每次重写 `harness.json`。业务程序集所在目录中任一 dll / exe 的大小或修改时间变化时重新构建，否则跳过构建；若程序集的 TFM 或位数也变了（如 4.6.1 升级到 4.8），先重新生成宿主工程。同一缓存宿主用系统互斥量串行化，多个代理并发调用也不会同时构建。

使用 `-Preset` 时显式参数覆盖预设，视图中的设置覆盖 `defaults`，互斥的参数按组覆盖（视图写了 `xaml` 时不继承 `defaults` 的 `viewType`，写了 `width` / `height` 时不继承 `sizes`，以此类推）：显式 `-ViewType` / `-Xaml` 覆盖预设的 `viewType` 与 `xaml`，显式 `-DataContextType` / `-DataContextFactory` 覆盖预设的两者，显式 `-Width` / `-Height` 覆盖预设的 `sizes`。主题、DPI、尺寸的组合不能为空。

**单个组合**时输出与退出码同 `invoke-wpf-render.ps1`。**多个组合**（主题 × 尺寸 × DPI）时最多构建一次，每个组合在独立进程中渲染，然后在缓存宿主下新建 `matrix-<时间>-<id>` 目录并返回它：

| 文件 | 内容 |
| --- | --- |
| `matrix.json` | `status`（`ok` / `binding-issues` / `failed`）、`combinations`、`rendered`、`overview`，以及每个组合的 `theme` / `size` / `dpi` / `status` / `snapshot` / 绑定与布局问题 / `outDir` |
| `overview.png` | 全部截图缩放到 480 像素宽后拼成的总览图，每张标注主题、尺寸、DPI 与状态，一次查看即可对比 |

多组合的退出码取最严重者：任一组合失败为 `1`，否则任一绑定问题为 `2`，否则 `0`。构建失败时不再渲染其余组合。

### `scripts/invoke-wpf-render.ps1`

构建（输出到工程内 `out\`）并渲染一次，打印 JSON 摘要，输出目录路径写入管道，退出码写入 `$LASTEXITCODE`。

| 参数 | 类型 | 默认值 | 范围 | 说明 |
| --- | --- | --- | --- | --- |
| `-HarnessDir` | string | **必填** | — | `new-wpf-harness.ps1` 返回的 `WorkDir` |
| `-Width` | int | `1280` | 1–6000 | 视口宽度（DIP） |
| `-Height` | int | `800` | 1–6000 | 视口高度（DIP） |
| `-Dpi` | int | `96` | 48–384 | 输出位图 DPI，决定像素尺寸 |
| `-Theme` | string | `light` | `light` / `dark` | 仅作为字符串传给 `ViewFactory.Create`，真实主题由工厂负责应用 |
| `-WindowHost` | switch | 关 | — | 使用屏外窗口承载 |
| `-NoBuild` | switch | 关 | — | 跳过 `dotnet build`；仅在代码和引用都未变化时使用 |
| `-Background` | string | `auto` | `auto` / `transparent` / `#RRGGBB` / `#AARRGGBB` / 颜色名 | PNG 衬底。`auto`：业务窗口或被样式设置过的窗口背景优先，否则 light→白、dark→`#1E1E1E`；避免透明 PNG 在查看器中显示为黑底 |
| `-Element` | string | 无 | — | 另存该 `x:Name` 元素的截图为 `element.png`（整页 `snapshot.png` 照常生成）；找不到时失败并列出可用名称。元素截图超过 6000 万像素时不生成，原因写入 `elementError`，其余结果照常输出 |
| `-TimeoutSeconds` | int | `120` | 5–600 | 渲染子进程超时；超时会结束该子进程并写 `error.txt` |

额外保护：输出像素总数超过 6000 万（例如 6000×6000 DIP @ 192 DPI）时直接拒绝执行。

### `scripts/trust-project.ps1`

授权业务项目的 `wpf-render.json`，使结束前自动验证（Stop hook）生效。

| 用法 | 说明 |
| --- | --- |
| `trust-project.ps1 [-Path <目录或文件>]` | 授权当前目录（或向上最近）的 `wpf-render.json`，并列出 hook 将执行的构建命令 |
| `trust-project.ps1 -List` | 列出已授权的配置及状态（已授权 / 授权后已修改 / 文件不存在） |
| `trust-project.ps1 -Revoke [-Path …]` | 撤销授权；配置文件已删除或移动时按原路径撤销 |

授权记录默认在 `%LOCALAPPDATA%\wpf-offscreen-render\trusted-projects.json`（可用环境变量 `WPF_RENDER_TRUST_FILE` 改位置），绑定配置文件内容的 SHA256。

### `scripts/compare-snapshots.ps1`

比较前后两次渲染，打印 JSON 结果。退出码：`0` 无差异（或在容差内），`1` 有差异。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Before` / `-After` | **必填** | `snapshot.png` 路径，或渲染输出目录（自动取其中的 `snapshot.png` 与 `manifest.json`） |
| `-DiffPath` | `After` 所在目录的 `diff.png` | 差异图：以 after 为底淡化成浅灰，变化像素标红 |
| `-Tolerance` | `0` | 单个颜色通道差值不超过该值时视为相同，用于忽略抗锯齿等微小差异 |

输出字段：`status`（`same` / `different`）、`identicalBytes`、`sameSize`、`beforeSize` / `afterSize`、`changedPixels`、`changedRatio`、`changedBoundsPx` 与 `changedBoundsDip`（变化区域外接矩形 `[x, y, w, h]`，DIP 坐标可直接对照 `layout.json`）、`environmentDifferences`（两次渲染在视图类型、模式、主题、尺寸、DPI、衬底、TFM、运行时、架构、机器上的差别；有差别时像素变化可能来自渲染条件而非界面改动）、`diff`。

---

## 渲染模式

| 场景 | 模式 | 说明 |
| --- | --- | --- |
| 普通控件、静态布局、资源与绑定检查 | 默认 `layout-only` | 不创建 Window，显式 Measure / Arrange；**不保证**触发 `Loaded`，没有有效 `PresentationSource` |
| 依赖 `Loaded`、`PresentationSource`、`RelativeSource AncestorType=Window`、实际承载尺寸的页面；或工厂直接返回 `Window` | `-WindowHost` | 创建真实但屏外、不激活的窗口；仍需要桌面会话（服务 / 无会话的 CI 代理通常不行） |
| 页面切换卡顿、加载耗时、线程阻塞 | 另做性能诊断 | 快照只能证明某个状态下的外观，见 `references/verification.md` 的性能边界 |

`Window` 只能在 `-WindowHost` 下使用；`layout-only` 遇到 `Window` 会直接报错。窗口的 `MinWidth` / `MaxWidth` 等约束仍可能改变实际尺寸，请核对 manifest 中的 `actualWidthDip` / `actualHeightDip`。窗口显示后会再强制一次屏外位置、普通状态与尺寸（业务窗口常在 `Loaded` 中恢复上次的最大化状态）。渲染结束时不关闭窗口、不调用 `Application.Shutdown`（避免触发 `Closing` 中的确认对话框），结果全部写出后才执行 `ViewFactory.Cleanup`，随后结束进程。

---

## 输出产物

每次执行都会在工程目录下新建 `render-yyyyMMdd-HHmmss-<GUID>`，不会覆盖历史结果：

| 文件 | 何时生成 | 内容 |
| --- | --- | --- |
| `snapshot.png` | 渲染成功（含存在绑定错误时） | 目标视觉快照 |
| `manifest.json` | 渲染成功 | 元数据，见下表 |
| `binding-errors.txt` | 宿主正常结束 | 去重后的真实绑定告警 / 错误，每条一行；为空表示无问题（前提是自检通过） |
| `element.png` | 使用 `-Element` 且渲染成功 | 指定元素的截图，尺寸为元素的 `RenderSize` × DPI / 96 |
| `binding-errors.json` | 宿主正常结束 | 同上，逐条解析出 `targetElement` / `targetName` / `targetProperty` / `path` / `dataItem` / `reason` 与单行 `summary` |
| `layout.json` | 渲染成功 | 视觉树中每个可见 `FrameworkElement` 的类型、名称、截图坐标中的矩形（DIP，已计入根元素自身的 Margin / 对齐偏移，与 `snapshot.png` 和 `elementRectDip` 一致）与文本（最多 3000 个），以及布局问题 `issues`。节点矩形是元素需要的完整尺寸，被父容器或自身槽位裁掉的部分也包含在内；实际可见范围以 `issues` 中的说明为准 |
| `build.log` | 未使用 `-NoBuild` | `dotnet build` 完整输出 |
| `render.stdout.log` / `render.stderr.log` | 子进程启动后 | 宿主标准输出 / 错误 |
| `error.txt` | 失败时 | 异常堆栈、自检失败、进程无法启动或超时说明。宿主崩溃而没有写出它时（如缺少 WindowsDesktop 运行时），`summary.json` 的 `error` 取 `render.stderr.log` 的末尾 |
| `summary.json` | 总是 | 结论摘要：`status`（`ok` / `binding-issues` / `failed:build` / `failed:locate` / `failed:start` / `failed:render` / `failed:timeout`）、`snapshot`、`elementSnapshot` / `elementRectDip` / `elementError`（使用 `-Element` 时）、`warning`（如窗口模式下 RightToLeft 的业务 Window 截图未镜像）、`sourceViewType`、尺寸、衬底、前 5 条绑定问题（`bindingIssues`，解析后的单行结论）、布局问题条数与前 10 条（`layoutIssueCount` / `layoutIssues`）、编译错误、异常前 15 行；同时打印到控制台 |

`layout.json` 的布局问题（只检查有文本的 `TextBlock`、有图像的 `Image` 与 `Control`，容器本身不报告）：

| `kind` | 含义 | 不会报告的情况 |
| --- | --- | --- |
| `text-truncated` | 文本按当前字体放不下分到的布局空间（不换行时比较宽度，换行时比较高度），含已显示省略号的情况 | — |
| `clipped` | 非文本内容元素（`Image`、`Control`）分到的布局空间小于所需尺寸，或任意内容元素被祖先容器的布局空间裁掉一部分 | `ScrollViewer` 视口、`ClipToBounds`、显式 `Clip` 造成的裁切 |
| `overlap` | 两段文本的墨迹区域互相覆盖（按文本对齐计算实际字形范围） | 同一单元格中左右 / 居中对齐、字形不相交的文本 |
| `zero-size` | 有内容的元素分到的布局空间宽或高为 0 | `Visibility` 不是 `Visible` 的元素及其子树；`Control` 不报告（滚动条按钮等常为 0） |
| `out-of-viewport` | 元素可见部分超出 `-Width` × `-Height` 视口 | 滚动区域内被视口裁掉的部分 |

布局问题是给代理和人的线索，不影响退出码；祖先已报告 `clipped` / `out-of-viewport` 时后代不再重复报告。

`manifest.json` 示例（640×260 DIP、144 DPI、window-host、dark）：

```json
{
  "generatedAt": "2026-10-10T08:03:23.6543328Z",
  "mode": "window-host",
  "sourceViewType": "System.Windows.Controls.Border",
  "theme": "dark",
  "widthDip": 640,
  "heightDip": 260,
  "pixelWidth": 960,
  "pixelHeight": 390,
  "dpi": 144,
  "actualWidthDip": 640,
  "actualHeightDip": 260,
  "background": "#FF1E1E1E",
  "backgroundSource": "theme-fallback",
  "bindingTraceVerified": true,
  "layoutIssueCount": 0,
  "layoutReportError": null,
  "image": "snapshot.png",
  "sha256": "bafb482d…",
  "targetFramework": ".NETCoreApp,Version=v8.0",
  "runtime": ".NET 8.0.31",
  "processArchitecture": "X64",
  "machineName": "…",
  "note": "Visual snapshot; native windows, input, and performance require separate verification.",
  "bindingWarningOrErrorCount": 0,
  "exitCode": 0
}
```

| 字段 | 含义 |
| --- | --- |
| `mode` | `layout-only` 或 `window-host` |
| `sourceViewType` | 工厂返回的根类型全名，用来确认截的是真实页面而不是样例 |
| `theme` | 传入的主题**标签**；不代表业务主题已切换 |
| `widthDip` / `heightDip` | 请求的视口尺寸 |
| `pixelWidth` / `pixelHeight` / `dpi` | 实际位图尺寸与 DPI |
| `actualWidthDip` / `actualHeightDip` | 根元素布局后的实际尺寸；与请求不一致说明有约束或布局问题 |
| `bindingTraceVerified` | 绑定监听自检是否命中；`false` 时绑定统计不可信 |
| `layoutIssueCount` / `layoutReportError` | 布局问题条数；布局检查自身出错时记录原因（不影响渲染与退出码） |
| `bindingWarningOrErrorCount` | 真实绑定问题条数（排除自检标记） |
| `background` / `backgroundSource` | 实际衬底颜色与来源（`window` / `theme-fallback` / `explicit` / `transparent`）；衬底不代表业务背景 |
| `sha256` | PNG 字节哈希，用于快速判断是否完全一致 |
| `targetFramework` / `runtime` / `processArchitecture` | 宿主编译的 TFM、实际运行时（如 `.NET Framework 4.8.9221.0`）与进程架构，基线比较时应一致 |
| `exitCode` | 最终退出码 |

---

## 退出码

| 退出码 | 含义 | 是否有 PNG |
| --- | --- | --- |
| `0` | 渲染成功、绑定监听自检命中、没有真实绑定问题 | 有 |
| `1` | 构建失败 / 渲染异常 / 自检未命中 / 超时 | 通常没有；查看 `build.log`、`error.txt`、`render.stderr.log` |
| `2` | 渲染成功，但存在真实绑定告警或错误 | 有，便于排查；详情在 `binding-errors.txt` |

例：把样例绑定改成不存在的属性后，执行器返回 `2`，`binding-errors.txt` 内容为：

```text
BindingExpression path error: 'NoSuchProperty' property not found on 'object' ''SampleData' (HashCode=44115416)'. BindingExpression:Path=NoSuchProperty; DataItem='SampleData' (HashCode=44115416); target element is 'TextBlock' (Name=''); target property is 'Text' (type 'String')
```

> 退出码和 manifest 只能证明“生成成功、监听有效”。**视觉是否正确必须实际打开 PNG 看。**

---

## 尺寸与 DPI

- `-Width` / `-Height` 单位是 **DIP**（与 WPF 布局一致），默认 1280×800。
- PNG 像素 = `ceil(DIP × DPI / 96)`。例：640×360 DIP、144 DPI → 960×540 像素。
- `-Dpi` 只控制输出分辨率，**不模拟**真实多显示器 DPI 切换；依赖 `VisualTreeHelper.GetDpi` / HWND DPI 的代码需在真实显示环境另测。
- `ScrollViewer` 默认只截视口。想看完整内容，可给更大的固定高度，或在生成工程里定制截取根节点；固定高度只用于视觉检查。
- 虚拟化列表中未实例化的项不会因截图出现。可以用小规模数据，或**仅在临时宿主里**关闭虚拟化 / 分页；不要为截图修改业务行为。
