<!-- 复制到业务仓库的 AGENTS.md（Codex 等）或 CLAUDE.md（Claude Code）。按项目实际情况修改路径与视图名。 -->

## WPF 界面验证

本仓库的 WPF 界面用 wpf-offscreen-render 验证，视图预设在根目录的 `wpf-render.json`。

- 修改 `*.xaml`、`*.xaml.cs`、视图模型、样式或资源字典后，必须渲染受影响的视图再结束：
  调用 MCP 工具 `render_view`，参数 `config` 为本仓库根目录的绝对路径、`preset` 为视图名、`build: true`；
  不确定视图名时先调用 `list_views`。没有 MCP 工具时运行
  `pwsh -ExecutionPolicy Bypass -File <wpf-offscreen-render>/scripts/render.ps1 -Config . -Preset <视图名> -Build`。
- 修改前若需要对比，先渲染一次作为基线；修改后用 `compare_snapshots` 对比，确认变化只出现在预期区域。
- 结论以 JSON 摘要为准：`status` 不是 `ok` 时必须修复；`bindingIssues` 逐条处理；`layoutIssues` 逐条对照截图确认，属于预期的在回复中说明。
- 在回复中给出：渲染的视图、主题 / 尺寸、绑定与布局检查结论、截图路径，以及未覆盖的内容（Popup、原生控件、未用交互步骤验证的交互、性能）。改动涉及交互时用 `steps` 逐步验证。
- 新增视图时同时在 `wpf-render.json` 中登记预设，并配置 `watch`，让结束前的自动验证覆盖它。
