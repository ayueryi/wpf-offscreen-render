# ADR-0001：custom 步骤契约保留反射，校验前移到生成期

日期：2026-10-28 · 状态：已接受

## 背景

`custom` 交互步骤由业务 ViewFactory 的静态方法 `RunStepAsync(FrameworkElement view, string action, IReadOnlyDictionary<string, string> args)` 承接。宿主（assets/Steps.cs）用反射查找该方法。

架构审计（2026-10-28，第 2 轮候选 2）指出：该 interface 是隐式的——「ViewFactory 恰好有个静态方法」这一约定靠运行时反射发现，错误晚且难从 interface 上看出，建议改为显式成员 + 默认实现。

## 决策

**保留反射，不改成虚方法 / 默认接口方法。** 理由：

1. `docs/design/interaction-steps.md` §8（1.2.0 起）已把「未实现时不影响编译，现有自定义工厂无需改动」记录为设计决策。
2. 改成显式成员会改变方法签名（静态 → 实例或虚静态在 net472 上不可行），已有自定义工厂会**静默失效**（编译过但不再被调用），破坏面大于收益。
3. 错误晚的问题用**生成期校验**解决：`scripts/Steps.ps1` 的 `ConvertTo-HarnessSteps` 在 steps 含 `custom` 时检查工厂文件内容是否含 `RunStepAsync`（与运行时反射同一约定、同一来源），不含则在生成宿主之前报错。

## 后果

- 已有自定义工厂无需任何改动。
- 写了 `custom` 步骤但工厂未实现时，报错从「完整构建后的执行期」提前到「生成工程前」，省一轮构建。
- 判定标准是内容含关键字（非签名解析），理论上存在「文件里提到 RunStepAsync 但签名不对」的漏检——此时仍由运行时反射兜底报错，两个检查的约定一致。
- 未来若要彻底显形 interface，需要同步设计旧工厂迁移提示与版本说明，另行开 ADR。
