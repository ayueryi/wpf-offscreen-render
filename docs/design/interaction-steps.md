# 设计：交互步骤与动画取帧（1.2.0）

状态：草案，待确认 · 目标版本：1.2.0

## 1. 背景

当前每次渲染只得到一张静态快照：视图布局完成、Dispatcher 空闲后截图。代理因此只能验证“初始画面”，无法回答这些常见问题：

- 展开详情 / 切换 Tab / 勾选选项后，布局有没有挤坏、绑定有没有报错？
- 点击“提交”后，校验错误提示是否出现在正确位置？
- 悬停、按下、禁用状态的样式对不对？
- 淡入、展开动画中途和结束时的画面是否正常？

离屏进程里没有真实的鼠标键盘输入，但 WPF 的大部分“动作”都能用代码确定性地驱动：设置属性、切换 VisualState、经 UI 自动化接口调用按钮、执行命令、把 Storyboard 定位到指定时刻。本设计在现有渲染流程上增加**步骤序列**：按顺序执行一组动作，每步之后截图并检查，最后汇总。

## 2. 目标与非目标

**目标**

1. 声明式描述一组步骤（JSON），由宿主按顺序执行，每步产出截图、绑定错误、布局问题，以及相对上一步的变化区域。
2. 结果可复现：同样的步骤、数据、环境得到同样的像素。不依赖真实时间与真实输入。
3. 三个入口都能用：命令行（`render.ps1 -Steps`）、业务项目预设（`wpf-render.json` 中的 `steps`）、MCP（`render_view` 的 `steps` 参数）。
4. 动画按时间点取帧（如 0 / 150 / 300 ms），拼成时间轴图。
5. 复杂动作留扩展点：业务仓库的 `ViewFactory.cs` 可以实现自定义步骤。

**非目标**

- 真实输入流程（拖拽、手势、IME、鼠标轨迹）与端到端自动化测试：交给 FlaUI / WinAppDriver 等桌面自动化工具。
- 实时录屏、帧率与性能测量：取帧只说明“某时刻的样子”，不说明流畅度。
- 依赖 `IsMouseOver` / `IsPressed` 等只读输入属性的**样式触发器**：离屏无法令其为 true（见 §6.4）。
- 与多主题 × 尺寸 × DPI 矩阵组合（1.2.0 中步骤与矩阵二选一，见 §11）。

## 3. 使用示例

预设（业务仓库 `wpf-render.json`）：

```json
{
  "views": {
    "OrderEditor": {
      "viewType": "MyUi.Views.OrderEditorView",
      "dataContextFactory": "MyUi.Preview.PreviewData.CreateOrderEditor",
      "windowHost": true,
      "steps": [
        { "name": "初始" },
        { "name": "展开明细", "set": { "element": "DetailsExpander", "property": "IsExpanded", "value": true } },
        { "name": "清空客户名", "set": { "element": "CustomerBox", "property": "Text", "value": "" } },
        { "name": "点击提交", "invoke": { "element": "SubmitButton" }, "waitMs": 100 },
        { "name": "提交按钮悬停", "state": { "element": "SubmitButton", "state": "MouseOver" } },
        { "name": "提示淡入", "animate": { "element": "Toast", "storyboard": "FadeIn", "atMs": [0, 150, 300] } }
      ]
    }
  }
}
```

命令行：`render.ps1 -Config . -Preset OrderEditor`，或 `render.ps1 -AssemblyPath … -ViewType … -Steps .\steps.json`。

MCP：`render_view { "config": "C:\\repo", "preset": "OrderEditor" }`，或直接传 `"steps": [ … ]`。

## 4. 步骤模型

每一步是一个对象：可选的 `name`，**至多一个**动作字段，加上可选的等待与截图控制。没有动作字段的步骤只截图（例如“初始”）。

### 4.1 公共字段

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `name` | string | `step-<序号>` | 显示在结果与总览图中；也用于输出目录名（清洗后） |
| `waitMs` | int | 0 | 动作后额外等待的**真实时间**（0–10000）。仅用于已知的有限延时（如防抖），不代替就绪信号 |
| `waitFor` | string | 无 | 等待条件，见 §4.3 |
| `capture` | bool | true | 为 false 时只执行不截图（用于准备性步骤） |
| `element` | — | — | 各动作中定位元素的写法，见 §5 |

### 4.2 动作类型

| 动作 | 写法 | 行为 | 典型用途 |
| --- | --- | --- | --- |
| `set` | `{ element, property, value }` | 设置依赖属性或 CLR 属性。值经属性类型的 `TypeConverter` 按不变区域转换 | 展开 / 勾选 / 选中项 / 输入文本 / 禁用 |
| `setData` | `{ path, value }` | 在视图的 `DataContext` 上按属性路径赋值（如 `Order.Status`），走 ViewModel 的正常通知 | 切换数据状态：空列表、错误、加载中 |
| `invoke` | `{ element }` | 经 UI 自动化接口调用：`IInvokeProvider`（按钮、菜单项、超链接）、`IToggleProvider`（复选框、开关）、`IExpandCollapseProvider`、`ISelectionItemProvider`（列表项、Tab），按元素支持的接口自动选择 | “点击”按钮、切换开关、选中 Tab |
| `command` | `{ element }` 或 `{ path, parameter }` | 执行元素的 `Command`（带 `CommandParameter`），或执行 DataContext 上路径指向的 `ICommand` | 绕过按钮直接执行命令 |
| `state` | `{ element, state }` | `VisualStateManager.GoToState(control, state, false)`，返回 false 时报错 | 悬停 / 按下 / 聚焦 / 自定义状态（仅限用 VSM 实现的模板） |
| `focus` | `{ element }` | `Keyboard.Focus`；窗口模式下先激活屏外窗口 | 聚焦样式、校验提示 |
| `animate` | `{ element?, storyboard, atMs: [] }` | 取帧：开始指定 Storyboard，逐个时刻定位并截图（§7） | 动画中途 / 结束画面 |
| `custom` | `{ action, args }` | 调用业务 `ViewFactory.RunStepAsync`（§8） | 以上无法表达的动作 |

### 4.3 等待与就绪

每个动作执行后固定做：`UpdateLayout` → 等 Dispatcher `ContextIdle` → `waitMs` 真实时间（如有）→ `waitFor`（如有）→ 再次 `UpdateLayout` / 空闲 → 截图。

`waitFor` 支持：

- `"idle"`（默认，已包含）；
- `"property:<元素>.<属性>=<值>"`：轮询直到相等，例如 `property:SubmitButton.IsEnabled=True`；
- `"data:<路径>=<值>"`：同上，作用于 DataContext；
- `"factory"`：调用 `ViewFactory.WaitUntilReadyAsync`（复用现有钩子）。

轮询间隔 50 ms，单步超时 `stepTimeoutMs`（默认 10000，可在步骤或整体上设置）。超时视为该步失败（§9）。

## 5. 元素定位

`element` 接受字符串或对象：

| 写法 | 含义 |
| --- | --- |
| `"SubmitButton"` | 按 `x:Name` 匹配（与现有 `-Element` 相同） |
| `{ "automationId": "submit" }` | 按 `AutomationProperties.AutomationId` 匹配 |
| `{ "name": "Row", "index": 2 }` | 同名元素的第 3 个（模板 / ItemsControl 中会重复） |
| `{ "text": "提交" }` | `TextBlock.Text` 或 `ContentControl.Content` 等于该文本的最近可交互祖先 |
| `{ "type": "Expander", "index": 0 }` | 按类型短名匹配 |

查找在**每一步执行前**于当前视觉树中进行（步骤可能改变视觉树，例如展开后新生成的元素）。遍历包含逻辑树中尚未生成视觉的元素时，先 `ApplyTemplate` / `UpdateLayout`。找不到时报错并列出可用名称（复用现有 `-Element` 的提示逻辑）。

## 6. 各动作的实现要点

### 6.1 `set`

- 先按名称找依赖属性（`DependencyPropertyDescriptor.FromName`，含附加属性 `Grid.Row` 写法），找不到再找 CLR 属性。
- 值转换：步骤 JSON 中的值由脚本统一写成**字符串**（见 §10.2），宿主用目标属性类型的 `TypeConverter.ConvertFromInvariantString` 转换；`null` 表示 `ClearValue`。
- 只读属性（如 `IsMouseOver`）直接报错并说明原因，不尝试反射写入。

### 6.2 `invoke`

- `UIElementAutomationPeer.CreatePeerForElement(element)` → 按优先级取 `Invoke` / `Toggle` / `ExpandCollapse` / `SelectionItem` 模式。
- `ButtonAutomationPeer.Invoke` 内部是异步派发点击：执行后必须等一次 Dispatcher 空闲（§4.3 已包含）。
- 元素 `IsEnabled == false` 时报错（`ElementNotEnabledException`），而不是静默跳过：这本身就是有用的结论。

### 6.3 `command` / `setData`

- `command`：`ICommandSource` 取 `Command` + `CommandParameter`；`CanExecute` 为 false 时报错。
- `setData`：按点分路径反射取到父对象，再用属性类型的 `TypeConverter` 赋值；支持索引器 `Items[0].Name`。

### 6.4 `state` 与悬停的局限

- `VisualStateManager.GoToState` 只对**模板中定义了 VisualStateGroups** 的控件有效。
- WPF 默认主题（Aero2 等）的 `Button`、`TextBox` 等是用 `Trigger Property="IsMouseOver"` 实现悬停的，`IsMouseOver` 只读且由输入系统计算，离屏无法令其为 true。此时 `state` 会因 `GoToState` 返回 false 而报错，提示“该控件的悬停由样式触发器实现，离屏无法模拟”。
- 业务自定义模板若使用 VSM（多数设计系统 / 第三方主题如此），悬停、按下都能截到。

### 6.5 `focus`

- 窗口模式：屏外窗口以 `ShowActivated=false` 创建，聚焦前调用 `window.Activate()`。仍在屏外，但会成为前台窗口，**可能短暂抢占焦点**：只在步骤中出现 `focus` 时才激活，并在文档中说明。
- 默认模式（无窗口）：`Keyboard.Focus` 不生效，只能设置逻辑焦点（`FocusManager.SetFocusedElement`）。依赖 `IsKeyboardFocused` 的样式不会生效，结果中给出警告。
- 焦点框（FocusVisualStyle）只在键盘导航时显示，离屏一般不出现，文档说明。

## 7. 动画取帧

```json
{ "name": "提示淡入", "animate": { "element": "Toast", "storyboard": "FadeIn", "atMs": [0, 150, 300] } }
```

- `storyboard`：在 `element`（缺省为根视图）及其祖先的资源中按 key 查找；或写 `{ "trigger": "Loaded" }` 取该元素上 `EventTrigger` 中的 `BeginStoryboard`。
- 实现：`storyboard.Begin(target, isControllable: true)` → `Pause` → 对每个时刻 `SeekAlignedToLastTick(target, t, BeginTime)` → `UpdateLayout` → 截图。`SeekAlignedToLastTick` 同步计算动画值，不依赖真实时钟推进，因此结果确定。
- 输出：每个时刻一张截图（`<步骤>/t0150ms.png`），另拼一张横向时间轴图；JSON 中记录每帧的时刻与变化区域。
- 取帧后 `Seek` 到末尾并保持，后续步骤看到的是动画结束状态。
- **其他动画的稳定性**：截图时仍在运行的其他动画会造成像素不稳定。增加整体选项 `animations`：`"live"`（默认，保持现状）、`"settle"`（每次截图前把所有已开始的 Storyboard `SkipToFill`）。`settle` 依赖能拿到 Storyboard 引用，只覆盖经资源 / 触发器启动的 Storyboard，代码中 `BeginAnimation` 启动的动画不在范围内（文档说明）。

**待验证（原型阶段第一件事）**：默认模式（无 `PresentationSource`）下 `SeekAlignedToLastTick` 是否能驱动动画值；若不能，`animate` 要求窗口模式并在默认模式下报错。

## 8. 自定义步骤

业务仓库的 `ViewFactory.cs`（经 `-FactoryFile` 使用）可选实现：

```csharp
// 可选：处理 steps 中的 { "custom": { "action": "...", "args": { ... } } }
public static Task RunStepAsync(FrameworkElement view, string action, IReadOnlyDictionary<string, string> args)
```

宿主用反射查找该方法：**未实现时不影响编译**（现有自定义工厂无需改动），只有用到 `custom` 步骤时才报错“ViewFactory 未实现 RunStepAsync”。`args` 的值统一为字符串（同 §10.2）。

## 9. 失败语义

- 某步失败（找不到元素、转换失败、`CanExecute` 为 false、`GoToState` 返回 false、等待超时、动作抛异常）：记录该步 `status: failed` 与错误信息，**截取失败时的画面**，然后停止后续步骤（`continueOnError: true` 时继续）。
- 整体状态取最严重者：任一步失败 → `failed:step`；否则任一步出现新的绑定错误 → `binding-issues`；否则 `ok`。退出码沿用 0 / 1 / 2。
- 绑定错误按步骤归属：监听器记录每条错误首次出现时所在的步骤，摘要中写成 `[点击提交] TextBlock#Error.Text <- Path=…`。
- **对话框**：动作打开了新窗口（`MessageBox`、`ShowDialog`）时，模态循环会阻塞后续步骤。宿主在执行动作前记录 `Application.Current.Windows`，动作后检测新窗口：窗口模式下截取新窗口内容作为该步附加截图，然后关闭它并记录 `dialogOpened`；`MessageBox`（非 WPF 窗口）无法截取，依赖单步超时兜底，文档说明。

## 10. 实现结构

### 10.1 宿主（assets）

- 新文件 `assets/Steps.cs`：步骤模型（DataContract）、元素定位、各动作执行、等待逻辑。只用 .NET Framework 4.7.2 与 .NET 5+ 共有的 API（`AutomationPeer`、`VisualStateManager`、`Storyboard` 均满足）。
- `Program.cs`：初始渲染流程不变；若 harness 配置含步骤，在第一张截图之后进入步骤循环。现有“写截图 / 布局 / manifest”的代码提取为 `CaptureAsync(stepDir)` 复用。
- 每步输出到 `render-…/steps/<两位序号>-<名称>/`：`snapshot.png`、`layout.json`、`step.json`（动作、耗时、状态、新增绑定错误、相对上一步的 `changedBoundsDip`）。顶层 `snapshot.png` 仍为初始画面，保持对旧调用方兼容。
- `changedBoundsDip`：宿主内对前后两张位图做像素比对（复用 `ImageTools.Compare` 的算法，移植一份不依赖 System.Drawing 的实现，直接比较 `RenderTargetBitmap` 像素）。

### 10.2 配置传递

- 步骤写入 `harness.json` 的 `steps` 数组（与视图配置一样，改步骤不需要重新构建宿主）。
- `DataContractJsonSerializer` 不适合反序列化任意类型的 `value`：脚本在写 `harness.json` 前把所有标量值规范化为**不变区域字符串**（`true` → `"True"`，`1.5` → `"1.5"`，`null` 保持 null），宿主统一按字符串 + `TypeConverter` 转换。

### 10.3 脚本

- `render.ps1`：新增 `-Steps <文件路径或 JSON 字符串>`；预设支持 `steps` 键（按 §3 写法）。与 `-Theme` / `-Size` / `-Dpi` 多值同时出现时报错（1.2.0 不支持步骤 × 矩阵）。
- `invoke-wpf-render.ps1`：`summary.json` 新增 `steps` 数组（每步名称、状态、截图、新增绑定错误前 3 条、布局问题条数、变化区域）与 `stepsOverview`（拼图路径）；`status` 新增 `failed:step`。
- 步骤总览图：复用 `ImageTools.ContactSheet`，每格标注序号、名称、状态。

### 10.4 MCP

- `render_view` 新增参数 `steps`（对象数组，schema 见 §4）与 `continueOnError`。
- 返回内容：JSON 摘要 + 步骤总览图；`includeStepImages: true` 时附上每步截图（受现有单图大小上限约束，超过 6 张时只附总览图并给路径）。
- `compare_snapshots` 无需改动：步骤目录本身就是合法的 `before` / `after`。

### 10.5 Stop hook

- 预设带 `steps` 时 hook 照常渲染，步骤失败与绑定错误一样阻止结束。无需额外改动，只需摘要格式兼容（hook 读取 `summary.json` 的 `status` 与问题列表）。

## 11. 范围决策（需要确认）

| 编号 | 问题 | 建议 |
| --- | --- | --- |
| D1 | 步骤 × 主题 / 尺寸 / DPI 矩阵是否在 1.2.0 支持 | **不支持**。组合爆炸、总览图难读；需要时对每个主题各跑一次 |
| D2 | `focus` 是否允许激活屏外窗口（可能短暂抢焦点） | **允许，但只在用到 `focus` 时激活**，并在结果中标注 |
| D3 | 对话框处理：自动关闭新窗口还是视为失败 | **截取后自动关闭并记录**，`MessageBox` 依赖超时 |
| D4 | `animations: "settle"` 是否默认开启 | **默认 `live`**（不改变现有行为），文档推荐有动画的视图开启 |
| D5 | 是否支持 `text` 定位（按显示文本找元素） | **支持**，但在结果中提示“按文本定位受本地化影响” |

## 12. 测试计划

新增样例视图 `SampleViews.InteractionView`（同时编译 net472 与 net8.0-windows）：

- `Expander`（`DetailsExpander`）+ 展开后才出现的 `TextBlock`；
- `TextBox`（`CustomerBox`）+ 校验规则，空值时显示错误模板；
- `Button`（`SubmitButton`）绑定 `ICommand`，执行后把 `StatusText` 改为“已提交”，并故意在提交后的模板里留一个拼错的绑定；
- 使用 VSM 模板的 `Button`（`VsmButton`）定义 `MouseOver` 状态（背景变色）；
- 带 `FadeIn` Storyboard 的 `Border`（`Toast`），Opacity 0 → 1，300 ms。

新增用例（`tests/run-tests.ps1`，net8 与 net472 各一组）：

| 用例 | 断言 |
| --- | --- |
| `steps-set-invoke` | 展开后新文本出现在 `layout.json`；点击后 `StatusText` 为“已提交”；`changedBoundsDip` 非空且落在预期区域 |
| `steps-binding-per-step` | 拼错的绑定只归属到“点击提交”这一步，状态 `binding-issues` |
| `steps-vsm-state` | `VsmButton` 悬停前后像素不同；默认主题 `Button` 的 `MouseOver` 报明确错误 |
| `steps-animate` | 0 / 150 / 300 ms 三帧的 `Toast` 区域平均 alpha 递增；两次运行像素一致（确定性） |
| `steps-failure` | 找不到元素时 `failed:step`，后续步骤未执行，失败画面存在；`continueOnError` 时继续 |
| `steps-dialog` | 动作打开 WPF 对话框时被截取并关闭，步骤不卡住 |
| `steps-preset` / `steps-mcp` | 预设 `steps` 与 MCP `steps` 参数各跑通一次 |
| `steps-custom` | 自定义工厂实现 `RunStepAsync`；未实现时只有用到 `custom` 才报错 |

## 13. 分阶段交付

| 阶段 | 内容 | 产出 |
| --- | --- | --- |
| P0 原型（约 0.5 天） | 验证 §7 的 `SeekAlignedToLastTick` 在两种模式下是否生效、`ButtonAutomationPeer.Invoke` 离屏可用、VSM 状态截图 | 结论写回本文档，决定 `animate` 是否限窗口模式 |
| P1 核心 | `set` / `setData` / `invoke` / `command` / `state` / `focus` / 等待，步骤输出、按步绑定错误、变化区域、总览图，CLI 与预设入口 | 1.2.0-preview |
| P2 动画与对话框 | `animate` 取帧与时间轴图、`animations: settle`、对话框检测 | |
| P3 集成 | MCP `steps` 参数、`custom` 钩子、SKILL.md / README / cli.md / integration.md、CHANGELOG | 1.2.0 |

每个阶段都要通过现有 32 个用例与新增用例，并保持旧调用方的输出兼容（没有 `steps` 时行为与 1.1.3 完全一致）。

## 14. 风险

- **离屏动画时钟**：若默认模式下动画不求值，`animate` 只能在窗口模式下使用（P0 验证）。
- **业务动作的副作用**：`invoke` / `command` 运行真实业务代码，可能访问网络、写文件、弹窗。与现有“构造视图即运行业务代码”的信任模型一致，但影响面更大：文档强调用样例 ViewModel / stub 服务隔离，并在 SKILL.md 中要求代理只对样例数据执行动作。
- **元素定位的脆弱性**：依赖 `x:Name` / `AutomationId`；建议业务代码为关键交互元素设置 `AutomationId`（同时有利于无障碍）。
- **默认主题悬停不可模拟**：§6.4 的限制需要在文档和错误信息里讲清楚，避免代理误以为“悬停样式没问题”。
