# 交互步骤与动画取帧

在初始截图之后按顺序执行一组动作（设置属性、点击、切换状态、动画取帧等），每步之后截图并做绑定与布局检查，最后汇总。用于验证“展开后布局有没有挤坏”“点击提交后错误提示是否正确”“悬停样式对不对”“动画中途和结束的画面”这类问题。设计背景见 [docs/design/interaction-steps.md](../docs/design/interaction-steps.md)。

## 入口

| 入口 | 写法 |
| --- | --- |
| MCP | `render_view` 的 `steps`（数组）、`continueOnError`、`animations`、`includeStepImages` |
| 预设 | `wpf-render.json` 视图中的 `steps`（以及 `continueOnError`、`animations`） |
| 命令行 | `render.ps1 -Steps <JSON 数组字符串或文件路径> [-ContinueOnError] [-Animations settle]`；两步脚本同样在 `new-wpf-harness.ps1` 上传入 |

步骤写入宿主的 `harness.json`，修改步骤不需要重新构建宿主。步骤**不能**与多个主题 / 尺寸 / DPI 同时使用，需要时对每个组合分别渲染。

```json
"steps": [
  { "name": "初始" },
  { "name": "展开明细", "set": { "element": "DetailsExpander", "property": "IsExpanded", "value": true } },
  { "name": "清空客户名", "set": { "element": "CustomerBox", "property": "Text", "value": "" } },
  { "name": "点击提交", "invoke": "SubmitButton", "waitFor": "data:Status=Submitted" },
  { "name": "悬停", "state": { "element": "SubmitButton", "state": "MouseOver" } },
  { "name": "提示淡入", "animate": { "storyboard": "FadeIn", "atMs": [0, 150, 300] } }
]
```

## 步骤字段

每步可选 `name`，加**至多一个**动作字段；没有动作的步骤只截图。

| 公共字段 | 默认 | 说明 |
| --- | --- | --- |
| `name` | `step-<序号>` | 显示在结果和总览图中 |
| `waitMs` | 0 | 动作后额外等待的真实时间（最多 10000），只用于已知的有限延时 |
| `waitFor` | 无 | `property:元素.属性=值`、`data:路径=值`（轮询直到相等，大小写不敏感）或 `factory`（调用 `ViewFactory.WaitUntilReadyAsync`） |
| `timeoutMs` | 10000 | `waitFor` 的超时 |
| `capture` | true | false 时只执行不截图 |

| 动作 | 写法 | 行为 |
| --- | --- | --- |
| `set` | `{ element, property, value }` | 设置依赖属性（`SetCurrentValue`，保留绑定，双向绑定会写回 ViewModel）或 CLR 属性；附加属性写 `Grid.Row`；`value: null` 清除本地值。值按属性类型的 TypeConverter（不变区域）转换，如 `"#FF0000"`、`"8,4"`、`true` |
| `setData` | `{ path, value }` | 在视图 DataContext 上按路径赋值，如 `Order.Status`、`Items[0].Name` |
| `invoke` | `{ element }` 或直接写元素名 | 经 UI 自动化接口操作：按钮 / 菜单项 / 超链接调用，复选框 / 开关切换，Expander 展开或折叠，列表项 / Tab 选中。元素禁用时失败 |
| `command` | `{ element }` 或 `{ path, parameter }` | 执行元素的 `Command`（带 `CommandParameter`），或 DataContext 上路径指向的 `ICommand`；`CanExecute` 为 false 时失败 |
| `state` | `{ element, state }` | `VisualStateManager.GoToState`，如 `MouseOver`、`Pressed`、`Focused` |
| `focus` | `{ element }` | 窗口模式下激活屏外窗口并设置键盘焦点；默认模式只能设置逻辑焦点（结果中有提示） |
| `animate` | `{ element?, storyboard 或 trigger, atMs }` | 动画取帧，见下文 |
| `custom` | `{ action, args }` | 调用业务 `ViewFactory.RunStepAsync`，见下文 |

**元素定位**（`element`）：字符串为 `x:Name`；对象可组合 `name`、`automationId`（`AutomationProperties.AutomationId`）、`type`（类型短名或全名）、`text`（显示文本，匹配到模板中的文本时取最近的按钮 / 列表项等可交互祖先）、`index`（第几个匹配，从 0 开始）。每步执行前在当前视觉树中查找（包括折叠的元素），找不到时报错并列出可用名称。按文本定位受本地化与文案修改影响，结果中会给出提示；稳定的写法是 `x:Name` 或 `AutomationId`。

## 动画取帧

```json
{ "name": "淡入", "animate": { "storyboard": "FadeIn", "atMs": [0, 150, 300] } }
{ "name": "加载动画", "animate": { "element": "Spinner", "trigger": "Loaded", "atMs": [0, 500] } }
```

- `storyboard`：在 `element`（缺省为视图根元素）及其上级的资源中按 key 查找；`trigger`：取该元素（或其样式）上对应事件的 `EventTrigger` 中的 `BeginStoryboard`。
- 以可控方式开始并暂停 Storyboard，再逐个时刻用 `SeekAlignedToLastTick` 定位后截图：动画值同步计算，不依赖真实时钟，同样的输入得到同样的像素。
- 每帧输出 `frame-0150ms.png`；最后一帧同时是该步的 `snapshot.png`。取帧后动画跳到结束状态，后续步骤看到的是动画完成后的画面。
- 只说明“某时刻的样子”，不说明帧率与流畅度。

**其他动画**：截图时仍在运行的动画会让像素不稳定。`animations: "settle"` 在每次截图前把元素及其样式上由事件触发器启动的 Storyboard 跳到结束状态；代码中 `BeginAnimation` 启动的动画、模板内部的动画不在范围内。默认 `live` 保持原样。

## 自定义步骤

业务仓库的 `ViewFactory.cs`（经 `factoryFile` / `-FactoryFile` 使用）可选实现：

```csharp
public static Task RunStepAsync(FrameworkElement view, string action, IReadOnlyDictionary<string, string> args)
```

```json
{ "name": "选中第 3 行", "custom": { "action": "SelectRow", "args": { "row": 2 } } }
```

宿主通过反射查找该方法：未实现时不影响编译，只有用到 `custom` 步骤才报错。`args` 的值统一为字符串。

## 结果

| 位置 | 内容 |
| --- | --- |
| `summary.json` 的 `steps` | 每步的 `index` / `name` / `action` / `status`（`ok` / `failed` / `skipped`）/ `error` / `snapshot` / `changedBoundsDip`（相对上一张截图的变化区域）/ 新增绑定问题前 3 条 / 布局问题条数 / 动画帧 / 对话框 / 提示 |
| `summary.json` 的 `stepsOverview` | `steps-overview.png`：初始画面、每步截图与动画帧拼成的总览图 |
| `steps.json` | 完整的逐步结果（含每帧的变化像素数、耗时） |
| `steps/<序号>-<名称>/` | `snapshot.png`、`layout.json`，动画帧 `frame-*.png`，对话框截图 `dialog-*.png` |

顶层的 `snapshot.png` / `layout.json` 仍是初始画面。

**状态与退出码**：任一步失败为 `failed:step`（退出码 3）；否则任一步（或初始画面）出现绑定错误为 `binding-issues`（退出码 2），绑定错误会标明首次出现的步骤；否则 `ok`。

**失败**：找不到元素、转换失败、元素禁用、`CanExecute` 为 false、没有对应的 VisualState、等待超时、动作抛出异常时，记录原因并截取失败时的画面，然后跳过后续步骤（`continueOnError` 时继续）。

**对话框**：动作打开的 WPF 窗口（含 `ShowDialog`）会先被移到屏外，截图后关闭，业务代码随后继续执行；Win32 `MessageBox` 只记录标题与文字，并按“取消 → 否 → 确定”的顺序关闭（只在没有不执行操作的按钮时才确认）。`MessageBox` 会短暂显示在真实屏幕上。

## 限制

- **默认主题的悬停 / 按下截不到**：WPF 默认主题的按钮、输入框用样式触发器响应 `IsMouseOver` / `IsPressed`，这些属性只读，离屏无法令其为 true，`state` 步骤会明确报错。只有用 VisualStateManager 定义状态的模板（多数设计系统与第三方主题）才能截到。
- **焦点**：`focus` 在窗口模式下会激活屏外窗口，可能短暂成为前台窗口；焦点框（FocusVisualStyle）只在键盘导航时出现，一般截不到。
- **副作用**：`invoke` / `command` / `custom` 运行真实业务代码，可能访问网络、写文件。只对样例 ViewModel / stub 服务执行动作。
- **不覆盖**：拖拽、手势、IME、真实输入序列与端到端流程（使用 FlaUI / WinAppDriver 等桌面自动化工具）。
