---
name: wpf-offscreen-render
description: 在独立临时进程中把真实 WPF UserControl、Page、Window 或松散 XAML 离屏渲染成 PNG，同时返回绑定错误、布局问题、实际尺寸与 DPI 摘要，用于界面预览、布局 / 主题 / 数据绑定检查和视觉回归。用户要渲染、截图、预览 WPF / XAML 界面，或对比改动前后效果时使用（render, screenshot, preview, WPF visual regression）。不适用于 WinUI、UWP、Avalonia、MAUI、WinForms。
---

# WPF 离屏渲染

**给 AI 一双看 WPF 的眼睛。**

在独立临时进程中创建 WPF Visual，通过 `RenderTargetBitmap` 输出 PNG；使用真实控件、真实样式和确定的样例数据，不启动业务程序。渲染需要 Windows；`windowHost` 还需要交互式桌面会话。

## 仓库根

「仓库根」是 **wpf-offscreen-render 工具仓库根目录**，必须同时存在：

- `scripts/render.ps1`
- `mcp/start.ps1`
- `references/cli.md`、`references/integration.md`、`references/steps.md`、`references/verification.md`

按顺序取第一个通过全部校验的路径：

1. 环境变量 `WPF_RENDER_ROOT`。
2. 若本 `SKILL.md` 位于工具仓库的 `skills/wpf-offscreen-render/` 下，沿其祖先目录向上查找。

Skill 被单独复制到其他目录时必须设置 `WPF_RENDER_ROOT`；不要按固定层数、当前工作区名称或模糊搜索猜路径。找不到时停止并告诉用户，不要调用脚本。MCP 启动器会通过 `--root` 把同一仓库根传给服务器。

脚本、文档和 MCP 参数一律使用仓库根的绝对路径；`preset` 还需要业务项目根目录的绝对 `config`。

## 工具路由

| 需求 | MCP 工具 | 脚本 / 限制 |
| --- | --- | --- |
| 读取业务预设 | `list_views` | 需要业务根的绝对 `config` |
| 按预设或单次渲染 | `render_view` | 支持 `config`、`preset`、`factoryFile`、`steps`；不传视图参数会渲染内置样例 |
| 直接程序集的多主题 / 尺寸 / DPI | `render_matrix` | 不支持 `config`、`preset`、`factoryFile`、`steps`；预设多组合使用 `render_view` 或 `render.ps1` |
| 前后对比 | `compare_snapshots` | 脚本为 `compare-snapshots.ps1` |
| 查询布局树 | `get_layout` | 读取某次渲染的 `layout.json` |
| 环境自检 | `self_test` | 或运行 `{仓库根}\tests\run-tests.ps1 -Quick` |

## 决策

1. 工具列表有 `render_view` 时优先使用 MCP；没有时使用 `{仓库根}\scripts\render.ps1` 等脚本，不要假装调用 MCP。
2. 业务根有 `wpf-render.json` 时先 `list_views`，再用 `render_view(config, preset)`；修改业务代码时加 `build: true`。脚本模式使用 `render.ps1 -Config <业务根> -Preset <名称>`。
3. 没有预设时先构建业务项目，再传 `assemblyPaths`（优先应用 exe 输出目录）和 `viewType` 或 `xaml`。不传视图参数得到的是内置样例，不可作为业务验收。
4. 默认使用 `layout-only`。只有依赖 `Loaded`、`PresentationSource`、窗口祖先、实际承载尺寸，或工厂返回 `Window` 时才用 `windowHost`；无交互桌面会话中不要选它。
5. DataContext 无参预览 VM 用 `dataContextType`；需要构造参数或 stub 用 `dataContextFactory`；需要资源、异步就绪、选中态或清理用 `factoryFile`。字段见 `{仓库根}\references\integration.md`。

`self_test` 用于首次安装、工具或 Windows Desktop Runtime 变化、`failed:start`，或怀疑环境异常时；不要每次改 UI 都运行。

## 最短路径

1. 渲染一次：MCP 按上面的路由调用；脚本用 `render.ps1`。多主题 / 尺寸 / DPI 的预设用 `render_view` 或脚本预设，多组合直传参数才用 `render_matrix`。
2. **先读 JSON，再检查 PNG。** 不把摘要、退出码或 manifest 当成视觉验收的替代品。

`status`：`ok` / `binding-issues` / `failed:<阶段>`（`build` / `locate` / `start` / `render` / `timeout` / `step`）。退出码 `0` 表示通过，`2` 表示绑定问题，`1` 或 `3` 表示失败。`bindingTraceVerified` 为 false 时绑定统计不可信。`layoutIssues`（`text-truncated` / `clipped` / `overlap` / `zero-size` / `out-of-viewport`）是线索，不影响状态；对照截图确认，坐标用 `get_layout`。失败看 `buildErrors` / `error` 和 `outDir` 下日志。排障见 `{仓库根}\references\verification.md`。

报告真实页面还是样例、模式、主题、尺寸、DPI、状态、绑定监听可信度、绑定与已确认的布局问题，以及未覆盖的 Popup / HWND / 默认主题悬停触发器 / 未等待的异步。

## 需要时再走

- **交互**：用 `steps` 验证展开、输入、点击、Tab、VisualState 和动画。步骤不能与多个主题 / 尺寸 / DPI 同时使用；用 `waitFor` 等明确完成信号，不要只靠 `waitMs`。默认主题 `IsMouseOver` / `IsPressed` 触发器离屏截不到，`state` 会明确报错。动作会运行真实业务代码，只对样例 VM / stub 服务执行。写法见 `{仓库根}\references\steps.md`。
- **改动对比**：改前后保持机器、字体、资源、样例数据、尺寸、主题、DPI 和动画状态一致，再用 `compare_snapshots`。查看 `changedBoundsDip`、`environmentDifferences` 和差异图。
- **一次性探查**：用 `{仓库根}\scripts\new-wpf-harness.ps1` 生成工程，再用 `invoke-wpf-render.ps1 -HarnessDir` 渲染；异步页面在 `ViewFactory.WaitUntilReadyAsync` 等明确完成信号。

## 产物生命周期

1. 先读取 JSON、日志并实际查看 PNG。
2. 用户要保留时，先把快照或基线移动到稳定目录，再清理其余临时文件并报告稳定路径。
3. 用户不需要时，在最终回复前删除本次 `render-*` / `matrix-*` `outDir` 和一次性 harness；不要把已删除的临时路径当作交付物。
