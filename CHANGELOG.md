# 更新日志

版本号记录在 `VERSION`，并与 `.claude-plugin/plugin.json`、`.codex-plugin/plugin.json`、`mcp/WpfRenderMcp/WpfRenderMcp.csproj` 保持一致（`tests/validate-plugins.ps1` 检查）。渲染结果的 `manifest.json` / `summary.json` 记录生成它的 `toolVersion`。

## 1.1.0 – 2026-10-10

安全与稳健性修复（全量 review）。

### 行为变化
- **Stop hook 需要授权**：hook 会执行 `wpf-render.json` 中的 `build` 命令并运行业务程序集，现在只对用户用 `scripts/trust-project.ps1` 授权过的配置生效。授权保存在本机、绑定配置内容哈希，配置修改后需重新授权；未授权时每个会话只提示一次。
- 渲染类 MCP 工具（`render_view`、`render_matrix`、`compare_snapshots`、`self_test`）不再声明只读，避免客户端据此自动批准会构建与运行代码的调用。
- Codex 插件的 MCP 配置由根目录 `.mcp.json` 改名为 `codex.mcp.json`，打开本仓库时不再被 Claude Code 当作项目 MCP 配置加载。

### 修复
- 过期缓存清理先尝试获取目录的互斥量，不再删除其他进程正在使用的缓存宿主；开始使用时立即刷新时间戳。
- 按类型名查找视图时优先在 `-AssemblyPath` 的业务程序集中查找，减少加载无关程序集。

### 文档与检查
- 离线 / 内网环境说明、hook 的启动开销、`layout.json` 矩形含义、新增故障排查条目。
- `tests/validate-plugins.ps1` 同时检查 README 版本徽章。

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
