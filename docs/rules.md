# 业务规则

> 所有规则在**主机事务内**执行。任一失败整单回滚。

## 零、统一的资金流原则（方案 C，2026-09-25 裁定）

> **任何一笔钱的进或出，都对应一张独立的收付款单。**

- 立即收款 / 立即付款 / 立即退款 / 立即收退款，一律由主机在事务内**自动生成**
  `receipt` / `payment` 单
- **主单（`purchase` / `sale` / `sale_return` / `purchase_return`）不直接写 `money_ledger`，
  也不直接设置 `status = settled`**
- `status` 由 `RuleEngine` 在刷新 `paid_amount` 之后统一判定
- **`paid_amount` 语义唯一**：`SUM(settlements.amount WHERE target_doc_id = X)`，**无分支**

**为什么**：方案 B（`status = settled` 表达"全额已收"）在**立即部分收款**场景下无解
（客户买 5000、当场付 3000、余 2000 挂账 —— 既不是 settled，3000 也没地方记）。
方案 C 把资金流动统一成一件事，规则只有一条，UI 与实现的分支最少。

自动生成的收付款单与用户手动创建的收付款单**表结构上无差异**，
用 `documents.ref_doc_id` 区分：自动生成 → 指向来源主单；手动创建 → `null`。

## 零·乙、数量与让价口径（v3，2026-10-03 裁定 · `reply_review.md` §BD）

> 适用于**有金额/交易明细**的单据：RULE-001 / 002 / 003 / 007 / 008。
> 盘点（RULE-009）**不适用**本节的换算与让价口径 —— 它的 `quantity` 是**盘点后的实际数量**，
> 语义见 RULE-009。
> 字段定义与 7 条交互关系见 `data_model.md` §3.2（那里是权威）。

- **`document_lines.quantity` 永远是最小销售单位**（`products.unit`）——
  按「3 箱」录入时落库 **36**；`entry_quantity = 3` / `entry_unit = '箱'` 只记**录入原文**。
  ⚠️ **「纯记录」的准确含义**：**落库之后**不参与库存、成本、往来余额等**派生**计算；
  但**落库当时** `entry_unit` 是 `toBaseQuantity` 的输入、`entry_quantity` 是
  `amount` 公式的原文数量与展示反推来源 —— 不是"从头到尾都不参与"
  （`entry_unit = null` = 用户没切单位）
- **`entry_unit` 可选「箱」的前提是成对启用**：`products.package_unit` 与 `package_size`
  **都非空**；缺一个就只能选最小单位或 null（否则会出现"能选箱但报没设换算"的半配置状态）
- **换算的唯一落点** = core 纯函数 `toBaseQuantity`（**不在 UI**，三份草稿共用）；
  失败返回 `null` ⇒ UI 报错，**三种失败分开说**：
  选了 `package_unit` 但没设 `package_size` ⇒「**这个商品没设包装换算**」；
  `package_size <= 0` ⇒「**包装换算无效**」（档案校验本应挡住，纯函数兜底）；
  出现第三种单位 ⇒「**单位不合法**」（校验拒绝，理论上不该发生）
- **`amount` 是这一行真正发生多少钱的真相**：
  `amount = entry_quantity × entry_unit_price − discount_amount`
  （`entry_unit_price` 是**派生**，**不存第六列** —— 展示**原始**按箱报价由
  `(amount + discount_amount) / entry_quantity` 反推；展示**折后**单价才用
  `amount / entry_quantity`）
- **`unit_price` 是派生展示**：`round(amount / quantity)`，**不再被改**；
  档价只是预填默认值
- **让价 `discount_amount`**：分、**正数**、默认 0；**整单议价记在某一行**（UI 默认最后一行）。
  ⚠️ 单行上限 `[0, entry_quantity × entry_unit_price]` —— 差额超过最后一行折前金额时，
  **由 UI 从最后一行向前分摊到多行**（整单差额恒 ≤ 整单折前金额，分摊总有解）；
  「记在某一行」只是默认起点，不是硬性约束
- **`entry_*` 不因商品档案变化而重解释**：改 `package_size` 改的是**将来**的换算，**不改历史**

---

## RULE-001 采购入库

**输入**：`Document(doc_type=purchase, party_id=供应商)` + lines + `immediate_payments`（可选）

`immediate_payments` 形态：`[{ account_id, amount }]`，可空、可多条（多账户混合付款）。

**输出（按顺序，同一事务内）**：

1. **主单落库**
   - `documents`：`total_amount = SUM(lines.amount)`，`paid_amount = 0`，`status = confirmed`
   - `document_lines`：逐条插入

2. **库存与往来**
   - `StockLedger`：每 line `quantity = +qty`，`total_cost = qty × unit_price`
   - `PartyLedger`：`document_id = purchase.id`，`amount = -total_amount`（我欠供应商）

3. **立即付款**（若 `immediate_payments` 非空）

   对每条 `payment_entry`，主机自动生成一张 **payment 单**：

   ```text
   doc_type       = payment
   ref_doc_id     = purchase.id
   account_id     = payment_entry.account_id
   total_amount   = payment_entry.amount
   occurred_at    = purchase.occurred_at
   time_estimated = purchase.time_estimated      ← 继承主单
   status         = settled                      ← 收付款单创建即终态
   ```

   对每张自动生成的 payment 单：

   - `Settlement`：`receipt_doc_id = payment.id`，`target_doc_id = purchase.id`，
     `amount = payment_entry.amount`
   - `MoneyLedger`：`document_id = payment.id`，`amount = -payment_entry.amount`（支出）
   - `PartyLedger`：`document_id = payment.id`，`amount = +payment_entry.amount`（欠供应商减少）

4. **刷新主单**

   ```text
   purchase.paid_amount = SUM(settlements.amount WHERE target_doc_id = purchase.id)
   purchase.status      = paid_amount >= total_amount ? settled : confirmed
   ```

**约束**：

- 每条 `payment_entry.amount > 0`
- `SUM(immediate_payments.amount) ≤ purchase.total_amount`

> ⚠️ 上面第二条**仍然成立**，且是**服务层保证**的：`PurchaseService` 落库时按
> `PurchaseDraft.recordedPaymentCents` **封顶**（用户填超时只取应付部分）。
>
> **交互（§AY·四，2026-10-02 裁定：与 RULE-002 销售侧同构）**：填得**超过应付**时
> **不再拦住**，而是**按应付折算入账**，并在**两处提前说清**「记了多少、找了多少」：
> ① 输入时的**橙色内联**告知（`实付 ¥100，其中 ¥93 入账、找零 ¥7`）
> ② **提交按钮文字**（`记 ¥93 并找零 ¥7`）；保存成功后 SnackBar **再说一次**。
> 口径与文案的唯一出处同销售：`packages/shensuanzi_core/lib/src/documents/overpay.dart`。

**场景**：

| 场景 | `immediate_payments` | 结果 |
|---|---|---|
| 全赊采购 | 空 | 不生成 payment 单，`status = confirmed` |
| 全款采购 | 含一条等额 | 生成 payment 单，`status = settled` |
| 部分付款 | 含一条小于总额 | 生成 payment 单，`status = confirmed` |

后续再付款走 RULE-005，创建独立 payment 单，核销该 purchase。

---

## RULE-002 店内销售

**输入**：`Document(doc_type=sale, party_id=客户)` + lines + `immediate_payments`（可选）

**输出（按顺序，同一事务内）**：

1. **主单落库**：`total_amount = SUM(lines.amount)`，`paid_amount = 0`，`status = confirmed`

2. **库存与往来**
   - `StockLedger`：每 line `quantity = -qty`，成本按"出库时点加权平均"
     （见 `data_model.md` §3.3 / §六）
   - `PartyLedger`：`document_id = sale.id`，`amount = +total_amount`（客户欠我）
   - **负库存允许**。UI 红色告警；出库成本按最近一次入库价

3. **立即收款**（若 `immediate_payments` 非空）

   对每条 `payment_entry`，主机自动生成一张 **receipt 单**：

   ```text
   doc_type       = receipt
   ref_doc_id     = sale.id
   account_id     = payment_entry.account_id
   total_amount   = payment_entry.amount
   occurred_at    = sale.occurred_at
   time_estimated = sale.time_estimated
   status         = settled
   ```

   - `Settlement`：`receipt_doc_id = receipt.id`，`target_doc_id = sale.id`，
     `amount = payment_entry.amount`
   - `MoneyLedger`：`document_id = receipt.id`，`amount = +payment_entry.amount`（收入）
   - `PartyLedger`：`document_id = receipt.id`，`amount = -payment_entry.amount`（客户欠款减少）

4. **刷新主单**：同 RULE-001 第 4 步（`paid_amount` + `status`）

**约束**：每条 `payment_entry.amount > 0`；`SUM(immediate_payments.amount) ≤ sale.total_amount`

> ⚠️ 上面这条**仍然成立**，且是**服务层保证**的：`SaleService` 落库时按
> `SaleDraft.recordedPaymentCents` **封顶**（用户填超时只取应收部分）。
> 所以「用户填 100」不会让这条约束被破 —— 破的是草稿的原文，落库的是折算值。

> **落库金额永远是「应收」，不是「顾客给的」**（`reply_review.md` §AJ·AI-4 裁定，
> §AX·一 **复核维持**）：收款金额 = 这笔交易让老板**净赚**的钱；找零是**现金箱内部的
> 物理流动**（顾客给 100、找零 7，箱内 +100−7 = 净 +93），不是交易的一部分 ——
> 所以"顾客给了"**不进** `immediate_payments`、不落库。若记 100，现金箱会凭空多 7 元。
>
> **交互（§AX·一 方案 3甲，2026-10-02 修订）**：填得**超过应收**时
> **不再拦住**，而是**按应收折算入账**，并在**两处提前说清**「记了多少、找了多少」：
> ① 输入时的**橙色内联**告知（`实收 ¥100，其中 ¥93 入账、找零 ¥7`）
> ② **提交按钮文字**（`记 ¥93 并找零 ¥7`）—— 按钮文字是用户动作的最终确认。
> 保存成功后 SnackBar / 核销结果里**再说一次**。
> 口径与文案的**唯一出处**是 `packages/shensuanzi_core/lib/src/documents/overpay.dart`
> （`Overpay`）—— 开单页与核销对话框**同源**，不许各写一份。
> ⚠️ 折算**不是**「把用户填的数改掉」：草稿保留原文，落库金额由
> `SaleDraft.recordedPaymentCents` 派生（封顶到 `total_amount`）。

**场景**：

| 场景 | `immediate_payments` | 结果 |
|---|---|---|
| 全款现金 | `[{cash, 5000}]` | 1 张 receipt，`status = settled` |
| 全赊 | 空 | 无 receipt，`status = confirmed` |
| **部分收款** | `[{wechat, 3000}]`（总额 5000） | 1 张 receipt，`status = confirmed`，余 2000 挂账 |
| 混合支付 | `[{cash, 2000}, {wechat, 3000}]` | 2 张 receipt，`status = settled` |
| 部分 + 混合 | `[{cash, 1000}, {wechat, 2000}]`（总额 5000） | 2 张 receipt，`status = confirmed`，余 2000 挂账 |

---

## RULE-003 送货

**输入**：`Document(doc_type=delivery, status=in_transit)` + lines

**输出**：

- `StockLedger`：每 line `quantity = -qty`（货离店即扣库存）
- `PartyLedger`：`amount = +total_amount`

**状态流转**：

```text
创建 ───────────────→ in_transit        货已离店（库存在创建时即扣）
客户签收 ───────────→ delivered
签收 + 已收满款 ────→ settled
已付款但未签收 ─────→ 停在 in_transit    钱到了，货还在路上
客户签收 ───────────→ delivered
签收 + 已收满款 ────→ settled
已付款但未签收 ─────→ 停在 in_transit    钱到了，货还在路上
客户拒收 ───────────→ 走 RULE-007 销售退货（ref_doc_id 指向本送货单）
                       且原送货单**同一事务内**置为 `cancelled`
                       （2026-10-04 裁定：否则在途视图永远把拒收的货算进去）；
                       仅未签收（in_transit）时收口，已签收（delivered）的
                       原单不在此列 —— 货确实送到过，退货不改「送过货」这个事实
```

> ⚠️ **送货的 `status` 由上面的状态机驱动，不由通用的
> `paid_amount >= total_amount ? settled : confirmed` 单条公式推导** ——
> 这与 `data_model.md` §3.1 的通用判定存在冲突，已记为待裁定项 R-10。
> 具体地：**未签收时即使已收满款，状态也停在 `in_transit`**。

**v1 实现**（R-10 未裁定前的处置）：

| 环节 | 做法 |
|---|---|
| 创建 | 主机**强制** `status = in_transit`（调用方传什么都会被覆盖） |
| `paid_amount` | 仍按 `SUM(settlements.amount)` 刷新（不变量 B4 无例外），但**不驱动** `status` |
| 签收 | **主机本地**路径：`RuleEngine.markDelivered(documentId)` —— 司机回店后由主机 UI 手动标记 |
| 离线签收 | **暂缓**。`documentAction: mark_delivered` 的幂等判定与存储属 **R-3**，随同步层落地（清单见 `docs/reply_review.md` §H） |
| 签收后收满款 | `_refreshPaidAmount` 把 `delivered` 提升为 `settled`（纯派生，不依赖 R-3） |

**`markDelivered` 的幂等判定基于状态**（R-3.1 的**候选**答案，尚未裁定；
清单见 `docs/reply_review.md` §H）：

```text
in_transit                 → delivered；若已收满款，同一事务内直接到 settled
delivered / settled        → alreadyExists（重复签收是 no-op，不写 updated_at）
cancelled 等其它状态       → rejected
非 delivery 单据 / 单据不存在 → rejected
```

**为什么不让 UI 直接调 `DocumentDao.updateStatusAndPaid`**：那个方法按契约
「只在主机本地事务内由 RuleEngine 调用」，裸调用拦不住 `cancelled → delivered`
这类非法迁移。**规则的实现只应有一处。**

**v1 的送货闭环**：出发前在主机创建送货单 → 客户签收后回店手动标记签收。
不如「司机途中签收」顺滑，但闭环完整；R-3 定了再补离线签收。

> ✅ **UI 已就绪（2026-10-02，批次 1b / `docs/reply_review.md` §AP）**：
> 导航「高频动作」组新增**送货**入口（与销售开单 / 采购入库并列，**不做模式开关**）；
> 独立开单页（**客户必选**、**无收款区** —— 送货单本身就是赊销）；
> 单据详情页对 `in_transit` 的单给 **[签收]**，并给一条内联提示
> 「客户拒收请用销售退货（开发中）」。
>
> ⚠️ **不能从销售单「转送货」** —— 送货单**创建即扣库存**，转一次就双扣。
>
> **本批次 0 数据层改动**：规则本体（`_delivery` / `markDelivered`）早就在 core 里，
> 1b 只补 Flutter 入口 + `DeliveryDraft` / `DeliveryService`（服务层）。

**在途视图**：

```sql
SELECT product_id, SUM(dl.quantity) AS in_transit
FROM document_lines dl
JOIN documents d ON d.id = dl.document_id
WHERE d.doc_type = 'delivery' AND d.status = 'in_transit'
GROUP BY dl.product_id
```

"在店可售" = 账面库存 - 在途数量。低库存告警用"在店可售"。

---

## RULE-004 收款核销

**输入**：`Document(doc_type=receipt)` + `allocations`

`allocations = [{ target_doc_id, amount }]`。`target_doc_id = null` 表示预收。

> `allocations` **随同步 payload 传入**（`createDocument` 的可选字段，R-1 裁定 2026-09-25），
> 不是 `document_lines` 的行 —— 它由本规则消费后写入 `settlements`。
> 收付款单的 `lines` 为空。

**输出**：

1. 主单落库（`status = settled`；收付款单创建即终态）
2. `MoneyLedger`：`document_id = receipt.id`，`amount = +receipt.total_amount`
3. `PartyLedger`：`document_id = receipt.id`，`amount = -receipt.total_amount`（客户欠款减少）
4. 对每条 `allocation`：插入 `Settlement(receipt_doc_id = receipt.id, target_doc_id, amount)`
5. **刷新被核销单**：逐个 `target_doc_id`
   - `target.paid_amount = SUM(settlements.amount WHERE target_doc_id = X)`
   - `target.status = paid_amount >= total_amount ? settled : confirmed`

**核销约束（创建时校验，违反则整单拒绝）**：

- `amount > 0`
- 同一 `receipt_doc_id` 的 `SUM(amount) ≤ receipt.total_amount`
- 同一 `target_doc_id` 的 `SUM(amount) ≤ target.total_amount`
- `receipt.doc_type ∈ {receipt, payment}`
- `target.doc_type ∈ {sale, purchase, sale_return, purchase_return, delivery}`
  （`target_doc_id = null` 时不受此限）

**场景覆盖**：

| 场景 | `settlements` 记录 |
|---|---|
| 一收款核一单（部分） | 1 条，`amount < 销售单总额` |
| 一收款核一单（全额） | 1 条，`amount = 销售单总额` |
| 一收款核多单 | N 条，各指向不同 `target_doc_id` |
| 一单多次收款 | N 条，各来自不同 `receipt_doc_id` |
| 超收/预收 | N 条指向具体单 + 1 条 `target_doc_id = null` |
| 用预收核新单 | 新建 1 条 settlement，`receipt_doc_id` 指向原收款单 |

> **数据层已支持「一收核多单」的多对多**（`settlements` 表设计如此，两个索引齐备）。
> v1 的 UI 只做**从单据详情发起的单笔核销**；**批量收款 / 预收入口是 v1.1 候选**
> —— 将来加 UI **不需要改 schema**（§AK / reply.md 六个待审查项 · 3）。

---

## RULE-005 付款

同 RULE-004，方向相反。

- `PartyLedger`：`amount = +付款额`（欠款减少）
- `MoneyLedger`：`amount = -付款额`

---

## RULE-006 库存查询

**库存**：

```sql
SELECT product_id, SUM(quantity) AS stock FROM stock_ledger GROUP BY product_id
```

**账户余额**：

```sql
SELECT account_id, a.initial_balance + COALESCE(SUM(m.amount), 0)
FROM accounts a
LEFT JOIN money_ledger m ON m.account_id = a.id
GROUP BY account_id
```

**往来余额**：

```sql
SELECT party_id, SUM(amount) FROM party_ledger GROUP BY party_id
```

正数 = 应收，负数 = 应付。

**在途 / 在店可售**（RULE-003 的视图）：

```sql
SELECT product_id, SUM(dl.quantity) AS in_transit
FROM document_lines dl
JOIN documents d ON d.id = dl.document_id
WHERE d.doc_type = 'delivery' AND d.status = 'in_transit'
GROUP BY dl.product_id
```

```text
在店可售 = 账面库存 − 在途数量
```

**低库存告警必须用「在店可售」** —— 送货单创建时货已离店（账面已扣），
若只看账面库存，会误以为店里还有货。

**实现**：`shensuanzi_core` 的 `QueryDao`。四条查询都是**批量映射**
（`Map<id, int>`），不是逐条 —— 列表页要一次拿全，逐条查会退化成 N+1。

**两处与本节 SQL 的差异（实现为准）**：

1. **账户余额的分组键用 `a.id`，不是 `account_id`**。原文 SQL 里
   `SELECT account_id ... GROUP BY account_id` 配合 `LEFT JOIN` 有歧义：
   一条流水都没有的账户，`m.account_id` 是 `NULL`，会被归到 `NULL` 组里、
   `a.initial_balance` 随之丢失。用 `a.id` 才对，且能保证**没有流水的账户也出现在结果里**。
2. **库存映射不含零流水商品**。从没进过货的商品不会出现在 `stockByProduct()` 里，
   消费端用 `map[id] ?? 0` 取值。

---

## RULE-007 销售退货

**前置**：`ref_doc_id` 必须指向原销售单（`sale`）**或送货单（`delivery`）**

> 原单是 `delivery` 的情形即 **RULE-003 的「客户拒收」**。
> 两者在成本口径上同构：`stock_ledger` 都是「货已离店」的负数流水，
> 因此 §「退货成本分摊」的比例回退对两者一致。

**输入**：`Document(doc_type=sale_return, party_id=客户, ref_doc_id=原销售单)` + lines
+ `immediate_payments`（可选，此处语义为**立即退款**）

**输出（同一事务内）**：

1. **主单落库**：`total_amount = SUM(lines.amount)`，`paid_amount = 0`，`status = confirmed`

2. **库存与往来**
   - `StockLedger`：每 line `quantity = +qty`（货回库），
     `total_cost` = **原销售单该商品成本按累计退货量精确回退**，
     算法与约束见 [`data_model.md` §3.3「退货的成本分摊」](data_model.md)
   - `PartyLedger`：`document_id = sale_return.id`，`amount = -退货额`（客户欠款减少）

3. **立即退款**（若 `immediate_payments` 非空）

   对每条 `payment_entry`，主机自动生成一张 **payment 单**：

   ```text
   doc_type       = payment
   ref_doc_id     = sale_return.id
   account_id     = payment_entry.account_id
   total_amount   = payment_entry.amount
   occurred_at    = sale_return.occurred_at
   time_estimated = sale_return.time_estimated
   status         = settled
   ```

   - `Settlement`：`receipt_doc_id = payment.id`，`target_doc_id = sale_return.id`
   - `MoneyLedger`：`document_id = payment.id`，`amount = -payment_entry.amount`（退给客户）
   - `PartyLedger`：`document_id = payment.id`，`amount = +payment_entry.amount`（客户欠款恢复）

4. **刷新主单**：同 RULE-001 第 4 步

**约束**：

- 退货数量不能超过原单数量（扣除已退数量）。违反则整单拒绝
- `SUM(immediate_payments.amount) ≤ sale_return.total_amount`

**说明**：未立即退款的部分成为"我们欠客户"（`party_ledger` 为负），
后续走 RULE-005 付款核销。

---

## RULE-008 采购退货

**前置**：`ref_doc_id` 必须指向原采购单

**输入**：`Document(doc_type=purchase_return, party_id=供应商, ref_doc_id=原采购单)` + lines
+ `immediate_payments`（可选，此处语义为**立即收退款**）

**输出（同一事务内）**：

1. **主单落库**：`total_amount = SUM(lines.amount)`，`paid_amount = 0`，`status = confirmed`

2. **库存与往来**
   - `StockLedger`：每 line `quantity = -qty`（货出库），
     `total_cost` = **原采购单该商品成本按累计退货量精确回退**（**符号为负**），
     算法与约束见 [`data_model.md` §3.3「退货的成本分摊」](data_model.md)
   - `PartyLedger`：`document_id = purchase_return.id`，`amount = +退货额`（我欠供应商减少）

3. **立即收退款**（若 `immediate_payments` 非空）

   对每条 `payment_entry`，主机自动生成一张 **receipt 单**：

   ```text
   doc_type       = receipt
   ref_doc_id     = purchase_return.id
   account_id     = payment_entry.account_id
   total_amount   = payment_entry.amount
   occurred_at    = purchase_return.occurred_at
   time_estimated = purchase_return.time_estimated
   status         = settled
   ```

   - `Settlement`：`receipt_doc_id = receipt.id`，`target_doc_id = purchase_return.id`
   - `MoneyLedger`：`document_id = receipt.id`，`amount = +payment_entry.amount`（供应商退我们钱）
   - `PartyLedger`：`document_id = receipt.id`，`amount = -payment_entry.amount`（我欠供应商恢复）

4. **刷新主单**：同 RULE-001 第 4 步

**约束**：

- 退货数量不能超过原单数量（扣除已退数量）
- `SUM(immediate_payments.amount) ≤ purchase_return.total_amount`

---

## 退货成本分摊（RULE-007 / RULE-008 共用）

**算法与约束的单一来源**：[`data_model.md` §3.3「退货的成本分摊」](data_model.md)。
此处只列本规则的实现要点与测试要点。

**实现要点**：

1. `ref_doc_id` 必须存在，且 `doc_type` 必须是本退货类型的**合法原单**
   （`sale_return` → `sale` **或 `delivery`**；`purchase_return` → `purchase`）
2. 原单该商品**必须**有 `stock_ledger` 流水，否则拒绝（说明数据不一致）
3. 分摊的分子分母都取**绝对值**，最后由退货类型决定符号 ——
   这样同一段代码对「原单是 sale（流水为负）」与「原单是 purchase（流水为正）」
   都成立
4. 「已退量 / 已退成本」按 `documents.ref_doc_id = 原单 AND doc_type = 本退货类型`
   过滤，因此**不会**把另一种退货类型的量算进来

**测试要点**：

1. 单次全额退 → `total_cost` = 原单该商品的 `total_cost`
2. 单次部分退 → `round_half_up(原单 total_cost × 退货量 / 原单数量)`
3. **多次部分退**：多次之和精确等于应分摊总额（余数由最后一次吸收）
4. **累计退货量超额** → 拒绝（`return_exceeds_original`）
5. **多商品独立**：原单 A 超退不影响 B 的合法退货
6. **负库存出库后退货** → 原样回退原单估算成本
7. **退货不修改原单 `paid_amount`**
8. **拒收**：原单是 `delivery` 时同样按比例回退（`sale` 与 `delivery` 的流水同构）

---

## RULE-009 盘点

**输入**：`Document(doc_type=stocktake, total_amount=0, paid_amount=0, status=confirmed)` + lines

`lines` 语义：`quantity` = **盘点后的实际数量**，不是差额。

**输出**：

- 对每个有差异的 `product_id`：
  - `diff = 实际数量 - 账面数量`
  - `StockLedger`：`quantity = diff`，`total_cost` 按规则（盘盈同入库，盘亏同出库）
- `diff = 0` 不产生流水
- **不生成** `PartyLedger` / `MoneyLedger`（v1 不做追责）

**约束**：

```text
盘点单提交后不可撤销。发现错误只能再盘一次
document_lines.quantity 是实际数量，与一般单据语义不同。消费端必须按 doc_type 分支
盘亏只通过 stock_ledger.total_cost 进入毛利，不产生资金流出
```

---

## 规则引擎的边界

```text
所有规则在主机事务内执行。任一失败整单回滚
DAO 不开事务。事务由 RuleEngine 统一开
没有对应规则的 doc_type 一律拒绝（如 v1 的 transfer）
客户端不实现 RuleEngine。客户端只推 Document，主机落地
规则实现只此一份，在 shensuanzi_core 的 rule_engine.dart
自动生成的收付款单不进同步 payload，由主机端生成
```
