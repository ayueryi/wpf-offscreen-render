# 更新日志

版本号记录在 `VERSION`，并与 `.claude-plugin/plugin.json`、`.codex-plugin/plugin.json`、`mcp/WpfRenderMcp/WpfRenderMcp.csproj` 保持一致（`tests/validate-plugins.ps1` 检查）。渲染结果的 `manifest.json` / `summary.json` 记录生成它的 `toolVersion`。

## 1.0.0 – 2026-10-10

首个带版本号的发布，汇总从独立仓库建立以来的全部能力。

### 代理接入
- MCP 服务器（`mcp/`）：`render_view`、`render_matrix`、`compare_snapshots`、`get_layout`、`list_views`、`self_test`，结果为 JSON 摘要加内联截图。
- Claude Code 插件（`.claude-plugin/`）与 Codex 插件（`.codex-plugin/`、`.mcp.json`、`.agents/plugins/`），共用 `skills/wpf-offscreen-render`。
- 业务项目接入：`wpf-render.json` 视图预设、`dataContextFactory` 静态工厂、`factoryFile` 外部 ViewFactory；Stop hook 在结束本轮前渲染受影响的视图；`templates/` 提供配置与 AGENTS.md / CLAUDE.md 规则。

### 渲染
- 支持 .NET Framework 4.7.2 / 4.8 / 4.8.1 与 .NET 5 – 10，按业务程序集自动推断 TFM 与位数（含 x86 / “首选 32 位”）。
- `render.ps1` 一步渲染：缓存宿主、程序集未变时跳过构建、多主题 × 尺寸 × DPI 组合与总览图、`-Element` 元素截图。
- `compare-snapshots.ps1`：差异图、变化占比、变化区域与环境差异。

### 诊断
- 绑定错误解析为单行结论（目标元素、属性、路径、数据源、原因）。
- `layout.json`：视觉树坐标与五类布局问题（文本截断、被裁切、文本重叠、尺寸为 0、超出视口）。

### 质量
- `tests/run-tests.ps1` 端到端回归测试；CI 在 Windows 上运行全部用例，在 Linux 上运行 MCP 协议测试与插件清单校验。

### 已知待验证
- Codex 插件安装、`.mcp.json` 的 `cwd` 解析与 Codex Stop hook 尚未在真实 Codex 客户端中验证。
