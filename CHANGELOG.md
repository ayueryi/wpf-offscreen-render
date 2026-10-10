# 更新日志

版本号记录在 `VERSION`，并与 `.claude-plugin/plugin.json`、`.codex-plugin/plugin.json`、`mcp/WpfRenderMcp/WpfRenderMcp.csproj` 保持一致（`tests/validate-plugins.ps1` 检查）。渲染结果的 `manifest.json` / `summary.json` 记录生成它的 `toolVersion`。

## 1.1.2 – 2026-10-10

第三轮全量 review 的修复。

### 修复
- **SDK 隔离**：`dotnet` 按当前目录（而不是工程目录）查找 `global.json`，1.1.1 写入宿主的空 `global.json` 在从业务仓库目录调用时并不生效。宿主与 MCP 服务器现在都在各自目录内构建，业务仓库锁定的 SDK 不再影响它们。
- **缓存清理**：原先会删除 `-CacheRoot` 下所有超过保留期的子目录；现在只处理本工具创建的缓存目录。
- **Stop hook 编码**：hook 的输入、git 输出与 hook 输出统一按 UTF-8 处理（原先使用控制台代码页，中文 Windows 上中文路径的项目找不到配置、中文文件名匹配不到 `watch`、拦截原因变成乱码）；输出 JSON 的非 ASCII 字符转义。
- **布局坐标**：`layout.json`、`elementRectDip` 改用截图坐标，计入根元素自身的 Margin / 对齐偏移（固定尺寸的视图居中时原先整体偏差），`out-of-viewport` 不再漏报。
- 业务代码留下的前台线程不再让已完成的渲染因进程无法退出而判为 `failed:timeout`。
- 预设与显式参数按组覆盖：显式 `-Xaml` 取消预设的 `viewType`（原先报“只能二选一”），显式 `-Width` / `-Height` 取消预设的 `sizes`（原先被静默忽略）。
- `-Element` 元素截图超过 6000 万像素时不再让整次渲染失败，原因写入 `elementError`。
- 渲染进程无法启动时（AppLocker 拦截、找不到 `dotnet`）也写出 `summary.json`，状态为 `failed:start`；宿主崩溃且没有 `error.txt` 时，`error` 取 stderr 末尾。
- MCP 启动器：首次编译使用一次性目录、成功后改名，客户端启动超时后重试不会与遗留的编译冲突；新增 `-BuildOnly` 预热；不再用 `Start-Process -Wait`（会等待 MSBuild 节点等子孙进程，服务器退出后启动器不退出）；源码哈希按统一换行计算，离线拷贝的缓存可复用。
- MCP 服务器不再读取用户项目目录中的 `appsettings*.json`（格式错误时启动即崩溃）；脚本在服务器的工作目录中运行，相对路径与向上查找 `wpf-render.json` 在各工具中含义一致；`list_views` 容忍注释与尾逗号。
- `-WindowHost` 重置业务窗口的 `WindowState`，最大化的窗口不再出现在真实屏幕上。
- `watch` 中的 `**` 可匹配零层目录；重命名时新旧路径都算改动。
- 程序集 TFM 或位数变化（路径不变）时重新生成缓存宿主；组合为空时报错；`-NoBuild` 找不到产物后缓存能自行恢复。
- 相对路径按 PowerShell 当前位置解析，UNC 路径可用；`trust-project.ps1 -Revoke` 可撤销已删除配置的授权；`Run` 自带字体的文本不再做截断检查（原先误报）；资源字典可用相对路径。

### 检查
- 新增用例：固定尺寸视图居中时的元素坐标、上层目录锁定未安装 SDK 时的构建、中文目录中的 Stop hook、预设的按组覆盖、缓存根目录中的无关目录不被删除。

## 1.1.1 – 2026-10-10

第二轮全量 review 的修复。

### 修复
- 所有 pwsh 启动配置（两份插件的 MCP 配置、Stop hook、MCP 服务器调用脚本、README 与模板中的命令）加上 `-ExecutionPolicy Bypass`：从 ZIP 解压安装（文件带“来自网络”标记）或策略为 `AllSigned` 时脚本原先无法运行。只作用于当次进程，组策略强制的设置仍优先。
- 生成的宿主写入空的 `global.json`，不再继承上层仓库锁定的 SDK 版本（`-WorkDir` 位于业务仓库内时可能无法构建）。
- 安装路径含 `[` `]` 时，生成器原先静默地没有复制任何宿主源文件；改为按字面路径复制。
- 渲染超时的状态由 `failed:render` 改为 `failed:timeout`，错误信息给出排查方向。

### 检查
- MCP 测试改用 `.claude-plugin/plugin.json` 中的真实启动命令；CI 新增在 `AllSigned` 策略下运行 MCP 测试的步骤。
- `tests/validate-plugins.ps1` 断言所有 pwsh 启动配置带 `-ExecutionPolicy Bypass`。
- CI 固定 Claude Code CLI 版本。

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
