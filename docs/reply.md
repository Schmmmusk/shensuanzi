## 审查意见

先说结论：

- **待裁①：推荐乙（值对象 `MasterDataPolicy`）。**
- **待裁②：推荐「要收紧」，且方式温和（非匹配 = 视为未提供）。**
- **顺带发现的单边断言：确认存在，应按纪律补——但补在 core 侧、不是补在 selfcheck。**

---

## 一、待裁 ①：门控形状

### 三个候选的真实差异

| | 甲（两个 bool） | 乙（值对象） | 丙（扩三样） |
|---|---|---|---|
| 触页面数 | 5 | 5 | 5 + 服务层 |
| 未来放开往来 | 再加第三个 bool → 再触 5 页 | 改一处默认值 | — |
| 语义方向 | 混（`canCreateProducts` + `readOnlyPartyData`） | 一致（都是 can） | — |
| 新增类型 | 无 | 有 | 无 |
| 超 v1 范围 | 否 | 否 | **是** |

### 推荐乙，理由是「甲的两个缺陷」

**缺陷 1：命名方向相反。**

甲的方案里一个 flag 是 `canCreateProductsLocally`（正向），另一个是 `readOnlyPartyData`（反向）。**同一份代码里两种语义方向**——后来人读 `if (!readOnlyPartyData && ...)` 要反向思考一次。

**缺陷 2：将来放开往来会「第二次触 5 页」。**

§CH §8 说 v1 只开商品。但 v1.1/v1.2 放开往来几乎是必定的（`README` 已写「主数据入队」的后续增强）。甲到那时要再加 `canCreatePartiesLocally`，**同样的 5 页再动一次**。乙只改 `MasterDataPolicy.mobile()` 的默认值。

### 乙的落地形态

```dart
class MasterDataPolicy {
  final bool canCreateProducts;
  final bool canCreateParties;
  final bool canCreateAccounts;

  const MasterDataPolicy.desktop()
      : canCreateProducts = true,
        canCreateParties = true,
        canCreateAccounts = true;

  const MasterDataPolicy.mobile()
      : canCreateProducts = true,   // v1 只开商品（§CH §8）
        canCreateParties = false,
        canCreateAccounts = false;
}
```

页面收到一个 `MasterDataPolicy`，各自检查对应能力。

**唯一要写清的边界**：`MasterDataSink` 本身仍是 product-only（§CH §8）——**值对象只表达「UI 层面允许不允许」，不改变 sink 的能力面**。将来放开往来时，值对象改默认值 + 加 `QueuePartySink`，是两件事。

### 为什么不选甲

如果只有「一个能力需要独立门控」，甲确实更省。但现状是三个能力 + 未来必然放开至少一个——**甲是「省现在、贵将来」，乙是「贵现在、省将来」**。项目一贯的做法是「为将来留位置」（`ShellKind` / `DocumentSink` 都是这个套路），乙与之一致。

### 为什么不选丙

超出 §CH §8 的 v1 范围，工作量最大，且 D2b 会被卡住。

---

## 二、待裁 ②：是否收紧 `resolvePreferredCode`

**推荐：要收紧，且方式温和（非匹配 = 视为未提供，不拒绝整个 op）。**

### 收紧的理由

`code` 是系统生成的字段。§CS·五 已裁定「客户端不发、主机忽略」——但**「忽略」的定义不完整**：

- 客户端**不发** `code` → 主机生成 ✓
- 客户端**发了合法 `code`**（`^P\d+$`）→ 用它 / 改派 ✓
- 客户端**发了非法 `code`**（`""` / `"null"` / `"X999"` / 超长）→ **现在行为未定义**

第三种情况必须定义。**如果不定义，一个 bug 客户端可以往 `products.code` 塞任意文本**，破坏 UNIQUE 语义和数据一致性。

### 为什么选「温和」而不是「拒绝」

**如果选严格拒绝**（发非法 code → `rejected`）：

- 一个合法但笨的客户端（比如序列化 bug 把 `null` 当字符串发）会导致所有建档失败
- 与「主机永远赢」矛盾——主机不该因为客户端笨而拒绝服务

**温和执行**：

```text
1. payload 里没有 code 或 code 不匹配 ^P\d+$ ⇒ 视为未提供，走主机生成
2. code 匹配 ^P\d+$ 且未被异 id 占用 ⇒ 采用
3. code 匹配 ^P\d+$ 但被异 id 占用 ⇒ 改派
```

三种情况主机都能收敛，客户端零失败。

### 落地要写进文档

`sync_protocol.md §8.1` 的 `createMasterData` 段补一句：

> `code` 是**建议值**，**只接受匹配主机编码格式（当前 `^P\d+$`）的值**；不匹配视同未提供。主机格式变化（如将来改前缀）不影响客户端——客户端不发它。

这样「主机端格式」与「客户端契约」解耦——**客户端不需要知道主机格式是什么**，反正它不发。

### 一个副作用提醒

收紧时要注意：`resolvePreferredCode` 也是 `ProductService` 的一部分，**Windows UI 建档也走它**。

- Windows UI 建档**不传** `preferredCode` → 走主机生成，不受影响
- 但**要确认**：有没有别的地方（比如导入功能、调试脚本）传 `preferredCode`？如果有，收紧会改变它们的行为。

**建议：收紧前 grep 一次 `preferredCode` 的所有调用方**，确认只有 `SyncServer.createMasterData` 传它。

---

## 三、顺带发现：单边断言

**确认问题存在，应补。但补的位置要选对。**

### 问题实质

`sync_queue_triage_test`（单测）断言的 `counts()` / `isSynced`，**在 `tool/selfcheck*.dart` 里没有镜像**。这意味着：

- 单元测试跑过 → 绿
- 自检工具跑过 → 绿
- 但**两者断言的不是同一件事** → 自检**没有覆盖**这块

### 补在哪

**推荐：补在 core 的 selfcheck（`tool/selfcheck_core.dart` 之类），不是补在 app 层。**

理由：

- `counts()` / `isSynced` 是 core 的逻辑（`SyncQueueDao` / `SyncClient`）
- 纪律要求的是「同一断言两处覆盖」（测试 + 自检）
- 放在 core 层，将来 host/app 都能复用

**如果 core 的 selfcheck 不存在，说明这一层从来没被自检覆盖过**——那就不是「这一族缺镜像」，而是「整个 core 的 selfcheck 缺失」。**先确认是哪一种**。

### 顺带核查

提案说「core 全部自检 grep `counts()` / `isSynced` = 空」。**这句话我建议再 grep 一次**：

- grep `counts(`（去掉括号）—— 可能匹配到别的 `counts` 用法
- grep `isSynced` —— 是否只在测试里出现

**如果只有测试断言、没有任何自检引用，那确实是单边**。补的时候顺手把这个家族的断言全找齐，一次性补完，不要补一半。

---

## 四、一句话收束

**待裁①选乙（`MasterDataPolicy` 值对象）——甲是「省现在贵将来」，与项目一贯的「为将来留位置」不一致。待裁②选「温和收紧」——非匹配 = 视为未提供，不拒绝；落地前 grep 一次 `preferredCode` 调用方。单边断言确认存在，补在 core 的 selfcheck 层，不是补在 app；补前先确认 core 的 selfcheck 整体覆盖情况。**