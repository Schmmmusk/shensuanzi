## 审查意见

先说结论：

- **发现属实，严重度评判准确（🔴）。这比 #20 / #21 更根本——它是「RuleEngine 的 rejected 语义没分层」的暴露。**
- **选乙，但乙的范围比提案描述的大——不是「甲 + 加码字段」，是「甲 + 加码字段 + StateError 分流 + `onInternalError` 通道」。**
- **`reason_code` 草案基本可用，但 `rule_rejected` 这个伞码会把 #22 的问题再压一次——它也需要细分，不是兜底。**

---

## 一、发现的严重度确认

提案的三个发现都对，**第一个最严重**：

> `RuleEngine.dispatch` 的兜底 catch 产出 `'规则执行失败，整单回滚：$error'`，`$error.toString()` 的前缀是 `Bad state:` —— 直接显示给用户。

**这比 #20 / #21 更糟**：

| #20 / #21 | #22 |
|---|---|
| SyncServer 层的措辞问题 | **RuleEngine 层的语义问题** |
| 改文案即可 | 改文案 + 加通道 + 分流 StateError |
| 一处改完即封口 | 改了 RuleEngine，Windows UI 侧路径**也受影响**（`ServiceSink`） |

**关键盲点**：`RuleEngine` 有**两个消费者**——

1. **Windows UI**（`ServiceSink`）：错误进 SnackBar / 对话框，用户就在电脑前
2. **Sync 通道**（`SyncServer`）：错误进 `SyncResponse`，给 Android 端

**现有 `sync_failure_test` 只覆盖第 2 条**——第 1 条（Windows UI 看到的错误）**零覆盖**。而 `'Bad state: …'` 在 Windows UI 上**也会显示**，只是你们还没被测试报告扫到。

**这条发现的价值不只是「修文案」，是「RuleEngine 的 rejected 从来没有一个明确契约」**。

---

## 二、乙 的实际范围（比提案大）

提案说乙 = 「甲 + 给 `RuleOutcome` 加码字段」。**实际要做四件事**：

### ① 修显式泄漏（甲 的范围）

- `dispatch` 兜底 catch 的 `$error` → 不拼进 `reason`
- `'docs/rules.md RULE-003'` → 不写进用户可见文本
- `'v1 尚未实现'` / `'immediate_payments 与 allocations 互斥'` → 客户端 bug，改通用文案

### ② 给 `RuleEngine` 加 `onInternalError` 通道

`RuleEngine` 现在**没有日志出口**。`$error` 一旦不拼进 reason，就必须有地方落——否则泄漏变成「丢失诊断信息」。

```dart
class RuleEngine {
  RuleEngine(this.db, {this.onInternalError});
  final void Function(String label, Object error, StackTrace stack)? onInternalError;
  ...
}
```

**与 `SyncServer.onInternalError` 同构**——`SyncServer` 创建 `RuleEngine` 时把回调传下去，或各自持有。**单一通道还是两条通道**要裁一下：我倾向**单一**（`SyncServer` 持有，构造 `RuleEngine` 时注入），否则同一条错误会在两个日志出口各记一次。

### ③ StateError 分流（提案没提，但是 #22 的真正核心）

提案说「20+ 处 `throw StateError` 被上一行吞进 `$error`」——**这 20+ 处必须分流**：

| 类型 | 特征 | 处置 |
|---|---|---|
| **业务拒绝** | 用户能改（如 `return_exceeds_original`） | 显式改成 `RuleOutcome(rejected, code: ..., reason: ...)` |
| **内部 bug** | 协议违反 / 不变量破坏（如「line 数量必须为正数，实际 0」） | 保留 `throw StateError`，被兜底 catch 捕获后**只进日志** |

**为什么必须分流**：`return_exceeds_original` 是**用户能改**的（少退一点）。今天它被埋在 `'Bad state: return_exceeds_original: ...'` 里——**好信息被坏前缀毁了**。这恰恰是 §8.5 早就写好的「错误码」被埋没的案例。

**分流的判据**（明确写进裁定的）：

> 用户**能做什么**——能做 = 业务拒绝（`RuleOutcome`，用户可见）；不能做 = bug（`StateError`，只进日志）。

### ④ `RuleOutcome` 加码字段 + `SyncResponse` 加码字段

提案 §五 的草案对——`RuleOutcome` 与 `SyncResponse` 各加 `reason_code`，`_mapOutcome` 汇合。**这是 #21 方案 A 的延伸，正确。**

---

## 三、对 `reason_code` 草案的意见

草案的码集基本可用，**但 `rule_rejected` 这个伞码有问题**：

```text
| rule_rejected | RuleEngine 拒绝（+#22 的细分码） |
```

**「+ #22 的细分码」这个写法把 #22 推给未来了**。但 #22 就是现在——**伞码 + 未来细分 = 中间态会留很久**。

**建议**：`RuleEngine` 的 rejected 码**当场定义**，不留伞码。已知的至少：

- `return_exceeds_original`（已有，从 reason 前缀升级为字段）
- `rule_validation_failed`（业务拒绝的通用兜底）
- `rule_internal_error`（内部 bug，只进日志 + 通用文案）

**伞码的诱惑在于「我不知道该分几类」——但 #22 的分流（业务拒绝 / 内部 bug）已经给了**两类**的边界。不要留 `rule_rejected` 这个不上不下的层级。**

其余码我认可：`not_writable_table` / `unknown_field` / `unwritable_column` / `missing_field` / `field_type_mismatch` / `id_mismatch` / `unknown_action` / `malformed_parameter` / `duplicate` / `reference_missing` / `data_invalid` / `host_storage`。

**`reference_missing` 特意确认一下**——它承载 §8.5「引用的主数据尚未同步」的契约，是**唯一一个用户能「等待后重试」成功的码**。文档要写清这一点，因为客户端要按它做**特殊处理**（不删队列，等主数据 pull 后再重推）。

---

## 四、与 #21 的关系

提案说「与 #21 的方案 A 同一次设计」——**对，但实际关系比这句更紧**：

- #21 的「17 处」在 `SyncServer`
- #22 的「RuleEngine rejected」也在 `SyncServer`（经 `_mapOutcome` 透传）
- **两者的 `reason_code` 都是 `SyncResponse.reason_code`**
- **两者的测试改写都是同一批文件**（`sync_server_test` / `selfcheck_sync`）

**所以 #21 + #22 应该合并成一次执行**，不是「同一次设计、分两次做」。分开做会：
1. 改两次 `SyncResponse`（一次加字段、一次给 RuleEngine 用）
2. 改两次测试
3. 中间态不一致

**建议**：裁定上仍可分两笔记账（#21 / #22），**执行上合成一个批次**。

---

## 五、「另 3 处」的重新归属

#21 里我提到「`规则拒绝` / `动作被拒绝` / `主数据不存在` 单独裁」。**现在归属清晰了**：

- `规则拒绝` / `动作被拒绝` → **归 #22**（它们是 `RuleEngine` 透传的兜底文案）
- `主数据不存在` → 归 #21（`deleteMasterData` 幂等，行为改动）

**#21 的裁定范围要相应调整**——不是「17 处 + 3 处」，是「17 处 + `主数据不存在`」，另两处归 #22。

---

## 六、一个提案没提但必须补的

**`RuleEngine` 的 rejected 在 Windows UI 上的行为，也要一并定义。**

Windows UI 通过 `ServiceSink` 调 `RuleEngine`。如果 `RuleEngine` 的拒绝文案改了（变通用、变短），Windows UI 的 SnackBar 会跟着变。

**这意味着**：
- 「数量必须为正数」这类**在 Windows UI 上确实可操作**的提示，改通用后会变差
- 但反过来说，**Windows UI 的 Draft 校验应该在 RuleEngine 之前就拦住**——如果拦得住，RuleEngine 的 rejected 在 Windows UI 上应该**永远不出现**

**建议**：**核对 Windows UI 路径上 RuleEngine 拒绝会不会被触发**。如果会，说明 Draft 校验有缺口——**那是另一个问题**，别用「保留详细文案」来掩盖。

**这一条超出 #22 的范围**，但**必须在做 #22 之前确认**——否则改完后 Windows UI 用户会看到明显变差的提示，误以为是回归。

---

## 七、一句话收束

**发现属实，选乙，但乙的范围是四件事：修显式泄漏 + 加 `onInternalError` 通道 + StateError 分流（业务拒绝 vs 内部 bug）+ 双方加 `reason_code`。不要留 `rule_rejected` 伞码——#22 的分流已给出两类边界，当场定码。`#21 + #22` 记账分开、执行合并。做 #22 前先核对 Windows UI 路径上 RuleEngine 拒绝会不会被触发——会的话那是 Draft 校验缺口，不能靠保留详细文案掩盖。**