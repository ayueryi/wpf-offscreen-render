---
name: wpf-offscreen-render
description: 在独立临时进程中把真实 WPF UserControl、Page、Window 或松散 XAML 离屏渲染成 PNG，同时输出绑定错误、布局问题、实际尺寸、DPI 等结构化摘要，用于修改 WPF 界面后验证布局、主题、数据绑定和视觉回归；不启动业务程序、不抢焦点，支持 .NET Framework 4.7.2–4.8.1 与 .NET 5–10。用户要截图、预览界面、看一眼 XAML、离屏截图、查看 WPF 界面效果、检查绑定错误，或对比改动前后界面时使用（render, screenshot or preview a WPF view or XAML offscreen; RenderTargetBitmap; WPF visual regression）。不适用于 WinUI、UWP、Avalonia、MAUI、WinForms。
---

# WPF 离屏渲染

在独立临时进程中创建 WPF Visual，通过 `RenderTargetBitmap` 输出 PNG；使用真实控件、真实样式和确定的样例数据，不依赖 Gallery 或生产程序的启动入口。渲染需要 Windows；云端 Linux 容器中的会话无法使用。

## 仓库根

后续「仓库根」指 **wpf-offscreen-render 工具仓库根目录**，必须**同时**存在 `scripts/render.ps1` 与 `mcp/start.ps1`。脚本、文档、MCP `--root` 都用这个目录的**绝对路径**。

**禁止**按「此 SKILL.md 上两级」推断。skill 装在插件内时碰巧是上两级；复制到 `.agents/skills/` 后上两级是工作区，不是本工具。

按顺序取第一个通过校验的路径，未通过则试下一个：

1. 环境变量 `WPF_RENDER_ROOT`（MCP 启动器也会设 `--root`，与此同源）。
2. 下一行写死的绝对路径（复制或安装 skill 时填写；未填则跳过）：
   `仓库根：C:\Users\yu\codes\tooling\wpf-offscreen-render`
3. 当前工作区里名为 `wpf-offscreen-render` 且含上述两个文件的目录（monorepo 常见于 `tooling/wpf-offscreen-render`）。
4. 仅当本 `SKILL.md` 仍位于工具仓库的 `skills/wpf-offscreen-render/` 下时，用其祖先目录，**必须校验那两个文件**，不得按固定级数。

都找不到则停止并告诉用户，不要猜路径、不要调用脚本。文档在 `{仓库根}/references/`（`cli.md`、`integration.md`、`steps.md`、`verification.md`），不要用相对于本 SKILL.md 的 `../../references/`。

**路径一律传绝对路径**：Codex 等客户端以插件目录为工作目录启动 MCP 服务器，相对路径会被拒绝；`preset` 需要同时传 `config`（业务项目根目录的绝对路径）。此 skill 不授予启动生产程序、连接设备或 Git 操作的权限。

## 决策（10 秒）

按顺序回答，选第一条成立的路。非 Windows / 找不到仓库根：停止。

1. **通道**：工具列表里有 `render_view` → MCP。没有 → `{仓库根}\scripts\render.ps1` 等脚本（参数见 `{仓库根}/references/cli.md`）。禁止假装调用 MCP。
2. **入口**：业务根有 `wpf-render.json` → `config`（该目录绝对路径）+ `preset`（改了业务代码加 `build: true`）。没有 → 先构建业务项目，再 `assemblyPaths`（优先应用 exe 输出目录）+ `viewType` 或 `xaml`。不传视图参数会渲内置样例，**不得当业务验收**。
3. **模式**：默认 `layout-only`。仅当依赖 Loaded / PresentationSource / 窗口祖先 / 实际承载尺寸时用 `windowHost`。卡顿、耗时、阻塞不是本工具能证明的，另测。
4. **DataContext**：无参预览 VM → `dataContextType`；要构造参数或 stub → `dataContextFactory`；还要资源 / 异步就绪 / 选中态 / 清理 → `factoryFile`。字段见 `{仓库根}/references/integration.md`。

`self_test` 只在本机没跑过、或 `failed:start` / 怀疑缺 SDK 时用（通过输出 `2 通过，0 失败`），不要每次改 UI 都跑。

MCP 工具：`list_views`、`render_view`、`render_matrix`、`compare_snapshots`、`get_layout`、`self_test`。脚本对应 `{仓库根}\scripts\render.ps1`、`compare-snapshots.ps1`、`{仓库根}\tests\run-tests.ps1 -Quick`。

## 最短路径

1. 按上面调一次渲染（MCP：`list_views` 再 `render_view`；脚本：`render.ps1 -Config <业务根> -Preset <名>`）。多主题/尺寸/DPI → `render_matrix`（或脚本一次传多个 `-Theme` / `-Size` / `-Dpi`）。只关心某控件 → `element`（`x:Name`）。
2. **先读 JSON 再看图**。

`status`：`ok` / `binding-issues` / `failed:<阶段>`（`build` / `locate` / `start` / `render` / `timeout` / `step`）。`bindingTraceVerified` 为 false 则绑定统计不可信。`bindingIssues` 逐条定位路径。`layoutIssues`（`text-truncated` / `clipped` / `overlap` / `zero-size` / `out-of-viewport`）是线索，不影响 status，对照截图确认；坐标用 `get_layout`。失败看 `buildErrors` / `error` 与 `outDir` 下日志。排障：`{仓库根}/references/verification.md`。
3. 向用户报告：真实页面还是样例；模式 / 主题 / 尺寸 / DPI；`status` 与 `bindingTraceVerified`；绑定与已确认的布局问题；未覆盖（Popup / HWND / 默认主题悬停触发器 / 未 wait 的异步）；`outDir` 绝对路径。临时产物不进仓库。
4. **强制清理**：汇报后若无需保留，立即删除本次 `outDir`（`render-*` / `matrix-*`）和一次性 harness。禁止靠 7 天 Temp 清理。用户要留图则先移到稳定目录再删其余。

## 需要时再走
- **交互**（展开、输入、点击、Tab、动画）：`steps`；不能与多主题/尺寸/DPI 同时用。用 `waitFor`，不要只靠 `waitMs`。默认主题 `IsMouseOver` / `IsPressed` 离屏截不到，`state` 会报错。只打样例 VM / stub。写法：`{仓库根}/references/steps.md`。一次性探查也可用 `{仓库根}\scripts\new-wpf-harness.ps1` + `invoke-wpf-render.ps1 -HarnessDir`。异步在 `ViewFactory.WaitUntilReadyAsync` 等明确完成信号。
- **改动对比**：改前渲一次当基线，改后 `compare_snapshots`（两次 `outDir`）。看 `changedBoundsDip` 是否只在预期区域、`environmentDifferences` 是否为空。用户要留基线则另选稳定目录，先留旧再写新。
- **坐标**：`layout.json`、`elementRectDip`、`compare_snapshots` 都是截图 DIP。`background` 默认 `auto`（衬底，不代表业务背景）。超时只作用于本工具拉起的渲染进程（默认 120 秒）。
