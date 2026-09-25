# 数据模型

> 真相来源是流水表，不是余额表。任何"当前状态"均可由流水重放得出。

## 一、通用约定

| 项 | 约定 |
|---|---|
| 主键 | UUIDv7（时间有序），客户端生成 |
| 时间 | UTC 毫秒时间戳（`int`） |
| 金额 | 整数分（`int`），禁止浮点 |
| 布尔 | `INTEGER`，0/1 |
| JSON | `TEXT` 存储，如 `roles` 字段 |
| 软删除 | `is_active` 字段，仅主数据有 |
| 乐观锁 | `sync_version` 字段，仅主数据有 |

## 二、主数据（可变）

主数据允许 UPDATE，受 `sync_version` 乐观锁保护。

### 2.1 `products`（商品）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PK | UUIDv7 |
| `code` | TEXT UNIQUE | 商品编码 |
| `name` | TEXT | 名称 |
| `barcode` | TEXT NULL | 条码，索引 |
| `unit` | TEXT | 单位，默认"件" |
| `cost_price` | INTEGER | 参考进价（分） |
| `sell_price` | INTEGER | 售价（分） |
| `safety_stock` | INTEGER | 安全库存 |
| `category` | TEXT NULL | 分类 |
| `is_active` | INTEGER | 默认 1 |
| `remark` | TEXT NULL | |
| `created_at` | INTEGER | |
| `updated_at` | INTEGER | |
| `sync_version` | INTEGER | 默认 0 |

索引：`idx_products_barcode(barcode)`

### 2.2 `parties`（往来方）

客户、供应商、司机统一存这张表，用 `roles` 区分。

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PK | UUIDv7 |
| `name` | TEXT | 名称 |
| `phone` | TEXT NULL | 索引 |
| `address` | TEXT NULL | |
| `roles` | TEXT | JSON 数组，如 `["supplier","customer"]` |
| `credit_limit` | INTEGER | 赊账额度（分），默认 0 |
| `is_active` | INTEGER | 默认 1 |
| `remark` | TEXT NULL | |
| `created_at` | INTEGER | |
| `updated_at` | INTEGER | |
| `sync_version` | INTEGER | 默认 0 |

索引：`idx_parties_phone(phone)`

### 2.3 `accounts`（资金账户）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PK | UUIDv7 |
| `name` | TEXT | 账户名 |
| `type` | TEXT | `cash` / `wechat` / `alipay` / `bank` / `other` |
| `initial_balance` | INTEGER | 期初余额（分） |
| `is_active` | INTEGER | 默认 1 |
| `created_at` | INTEGER | |
| `updated_at` | INTEGER | |
| `sync_version` | INTEGER | 默认 0 |

**注意**：修改 `initial_balance` 会重算全部历史余额。UI 需提示。

## 三、业务数据（不可变）

业务数据只插入，不更新，不删除。

### 3.1 `documents`（单据主表）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PK | UUIDv7 |
| `doc_no` | TEXT UNIQUE | 正式单号，**主机生成** |
| `doc_type` | TEXT | 见下表 |
| `status` | TEXT | 见下表 |
| `party_id` | TEXT NULL | 关联往来方 |
| `account_id` | TEXT NULL | 关联资金账户 |
| `total_amount` | INTEGER | 单据总额（分） |
| `paid_amount` | INTEGER | 已核销额（分），**缓存** |
| `ref_doc_id` | TEXT NULL | 关联原单（退货、核销） |
| `occurred_at` | INTEGER | 业务发生时间 |
| `time_estimated` | INTEGER | 1 = 客户端离线估算 |
| `created_at` | INTEGER | |
| `updated_at` | INTEGER | |
| `remark` | TEXT NULL | |

**允许 UPDATE 的字段**：`status`、`paid_amount`、`updated_at`。其余禁止。

**doc_type 枚举**：

| 值 | 中文 | 语义 |
|---|---|---|
| `purchase` | 采购入库 | 库存 +，往来 - |
| `sale` | 店内销售 | 库存 -，往来 + 或资金 + |
| `delivery` | 送货 | 库存 -，往来 + |
| `sale_return` | 销售退货 | 库存 +，往来 - |
| `purchase_return` | 采购退货 | 库存 -，往来 + |
| `stocktake` | 盘点 | 差额入流水 |
| `receipt` | 收款 | 资金 +，核销 |
| `payment` | 付款 | 资金 -，核销 |
| `transfer` | 调拨 | **v1 拒绝创建** |

**status 枚举**：

`draft` / `confirmed` / `in_transit` / `delivered` / `settled` / `cancelled`

**`status` 判定规则**（方案 C，2026-09-25）：

```text
paid_amount = SUM(settlements.amount WHERE target_doc_id = self.id)
status      = paid_amount >= total_amount ? settled : confirmed
```

- 适用于 `doc_type ∈ {purchase, sale, sale_return, purchase_return}`
- **`status` 不直接设置**。任何"立即收付"都必须通过自动生成的收付款单 + `settlement` 表达
  （见 `docs/rules.md` §零 统一资金流原则）
- `receipt` / `payment` 单**创建即 `status = settled`**，此后不再变更
- `stocktake`：`status = confirmed`，永不变化
- ⚠️ `delivery` **不适用**该公式 —— 它的 `status` 由送货状态机驱动
  （`in_transit → delivered → settled`），与上式冲突，已记为待裁定项 **R-10**。
  具体语义见 `rules.md` RULE-003：
  - 创建即 `in_transit`，**即使已收满款也不改**（钱到了，货还在路上）
  - 签收后（`RuleEngine.markDelivered`）才允许由 `paid_amount` 决定
    `delivered` / `settled`

**索引**：

```sql
CREATE INDEX idx_documents_type_status ON documents(doc_type, status);
CREATE INDEX idx_documents_party       ON documents(party_id);
CREATE INDEX idx_documents_occurred    ON documents(occurred_at);
CREATE INDEX idx_documents_ref         ON documents(ref_doc_id);
-- 同步拉取游标。documents 没有 seq_no，(created_at, id) 是它的复合游标，
-- 见 sync_protocol.md §8.2 / R-4 处置
CREATE INDEX idx_documents_created     ON documents(created_at, id);
```

### 3.2 `document_lines`（单据明细）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PK | UUIDv7 |
| `document_id` | TEXT FK | |
| `product_id` | TEXT FK | |
| `quantity` | INTEGER | 正数。语义按 `doc_type` 分支 |
| `unit_price` | INTEGER | 单价（分） |
| `amount` | INTEGER | 小计 = `quantity × unit_price` |
| `remark` | TEXT NULL | |

**`quantity` 语义分支**：

| `doc_type` | `quantity` 语义 |
|---|---|
| 一般单据 | 交易数量 |
| `stocktake` | 盘点后的实际数量，不是差额 |

消费端（明细页、报表）必须按 `doc_type` 分支处理。

`stocktake` 的 `total_amount` 恒为 0，`paid_amount` 恒为 0。

`receipt` / `payment` 单**没有商品明细**，其 `lines` 为空数组。
核销分配（`allocations`）**不落在本表**，随同步 payload 传入，见 `sync_protocol.md` §8.1。
收付款单与主单的关联**通过 `settlements` 表表达**，不通过 `document_lines`。

索引：`idx_lines_document(document_id)`、`idx_lines_product(product_id)`

⚠️ `document_lines` **没有时间列**（继承主单的 `occurred_at`）。
这决定了它的同步游标策略：**明细没有独立游标，随主单同页拉取** ——
见 `sync_protocol.md` §8.2。

### 3.3 `stock_ledger`（库存流水）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PK | UUIDv7 |
| `product_id` | TEXT FK | |
| `document_id` | TEXT FK | |
| `quantity` | INTEGER | 正数入，负数出 |
| `unit_cost` | INTEGER | **派生字段**，= `round_half_up(total_cost / quantity)` |
| `total_cost` | INTEGER | **精确成本**（分） |
| `seq_no` | INTEGER | 每表独立单调递增，UNIQUE |
| `occurred_at` | INTEGER | |
| `time_estimated` | INTEGER | |
| `created_at` | INTEGER | |

**`total_cost` 取值规则**：

| 类型 | `total_cost` |
|---|---|
| 入库（采购） | `quantity × unit_price`（精确） |
| 出库（销售） | `round_half_up(库存总成本 × 出库数量 / 库存数量)` |
| 盘盈 | 同入库（用当前加权均价） |
| 盘亏 | 同出库 |
| 负库存出库 | 最近一次入库 `unit_cost` × 出库数量 |
| 销售退货（货回库） | **原单比例精确回退**（见下「退货的成本分摊」），符号为正 |
| 采购退货（货出库） | 同上，符号为负 |

**毛利计算**：`SUM(销售额) - SUM(出库 total_cost)`。精确，无累积误差。

`unit_cost` 是派生展示字段。**`total_cost` 是真相。**

**符号约定**：`total_cost` 是「成本的**变动**」，不是绝对值 —— 符号与 `quantity` **一致**：

| 单据 | `quantity` | `total_cost` |
|---|---|---|
| 销售单（出库） | 负数 | 负数 |
| 销售退货（回库） | 正数 | 正数 |
| 采购单（入库） | 正数 | 正数 |
| 采购退货（出库） | 负数 | 负数 |

#### 退货的成本分摊

退货时写入 `stock_ledger`，其 `total_cost` 按**原单比例精确回退**（R-11 裁定，方案 A）：

```text
原单量    = |SUM(quantity)  WHERE document_id = 原单 AND product_id = P|
原单成本  = |SUM(total_cost) WHERE document_id = 原单 AND product_id = P|

已退量    = |SUM(sl.quantity)   WHERE 前序退货单 (d.ref_doc_id = 原单, d.doc_type = 本退货类型) AND sl.product_id = P|
已退成本  = |SUM(sl.total_cost) WHERE 同上|

累计退货量 = 已退量 + 本次退货量
累计分摊额 = round_half_up(原单成本 × 累计退货量 / 原单量)
本次 |total_cost| = 累计分摊额 - 已退成本
本次  total_cost  = 销售退货 ? +本次|total_cost| : -本次|total_cost|
```

（`sl` = `stock_ledger`，`d` = `documents`；`P` = 本 line 的 `product_id`）

**关键约束**：

- **原单类型**：`sale_return` 的原单是 `sale` **或 `delivery`**（客户拒收）；
  `purchase_return` 的原单是 `purchase`。`delivery` 与 `sale` 的流水同构
  （都是「货已离店」的负数 `quantity` / 负数 `total_cost`），故公式无需分支
- **累计退货量 ≤ 原单量**，违反则整单拒绝（错误码 `return_exceeds_original`）
- 约束按「**原单 + 商品**」粒度检查，不是整单总额：原单多商品各自独立约束
- 用「累计分摊 − 已分摊」而**不是**「本次单独分摊」，保证多次退货的 `total_cost`
  之和**精确等于**应分摊总额 —— 余数由最后一次退货自动吸收，无需额外状态表
- 原单在负库存时出库的，其 `total_cost` 是估算值，退货**原样回退**该值，不做特殊处理
- **退货不修改原单 `paid_amount`**。原单是已完成的历史交易，退货是独立的新交易；
  客户实际欠款以 `party_ledger` 汇总为准

**为什么不用「退货时点的当前加权平均」**：会改变库存成本结构、破坏「给定完整流水即可
精确重放」的性质，并留下「低买、高买、再退低价的货」的套利空间。

**索引**：

```sql
CREATE INDEX idx_stock_product_seq ON stock_ledger(product_id, seq_no);
CREATE INDEX idx_stock_document    ON stock_ledger(document_id);
CREATE UNIQUE INDEX idx_stock_seq  ON stock_ledger(seq_no);
```

### 3.4 `money_ledger`（资金流水）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PK | UUIDv7 |
| `account_id` | TEXT FK | |
| `document_id` | TEXT FK | |
| `amount` | INTEGER | 正数收入，负数支出 |
| `seq_no` | INTEGER | UNIQUE |
| `occurred_at` | INTEGER | |
| `time_estimated` | INTEGER | |
| `external_ref` | TEXT NULL | 预留：微信/支付宝交易号 |
| `created_at` | INTEGER | |

索引：`idx_money_account_seq(account_id, seq_no)`、`idx_money_document(document_id)`、UNIQUE `idx_money_seq(seq_no)`

### 3.5 `party_ledger`（往来流水）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PK | UUIDv7 |
| `party_id` | TEXT FK | |
| `document_id` | TEXT FK | |
| `amount` | INTEGER | 正数=对方欠我，负数=我欠对方 |
| `seq_no` | INTEGER | UNIQUE |
| `occurred_at` | INTEGER | |
| `time_estimated` | INTEGER | |
| `created_at` | INTEGER | |

索引：`idx_party_ledger_party_seq(party_id, seq_no)`、`idx_party_ledger_document(document_id)`、UNIQUE `idx_party_ledger_seq(seq_no)`

### 3.6 `settlements`（核销关系）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PK | UUIDv7 |
| `receipt_doc_id` | TEXT FK | 收款单/付款单 |
| `target_doc_id` | TEXT NULL | 被核销单。null = 预收/预付 |
| `amount` | INTEGER | 本次核销金额 |
| `seq_no` | INTEGER | UNIQUE |
| `time_estimated` | INTEGER | |
| `created_at` | INTEGER | |

**核心公式**：

```text
收款单已核销额 = SUM(settlements.amount WHERE receipt_doc_id = X)
收款单未核销额 = receipt.total_amount - 已核销额     ← 这就是预收
销售单已收额   = SUM(settlements.amount WHERE target_doc_id = X)
```

**核销约束（创建时校验）**：

- `amount > 0`
- 同一 `receipt_doc_id` 的 `SUM(amount) ≤ receipt.total_amount`
- 同一 `target_doc_id` 的 `SUM(amount) ≤ target.total_amount`
- `receipt.doc_type ∈ {receipt, payment}`
- `target.doc_type ∈ {sale, purchase, sale_return, purchase_return, delivery}`（`target_doc_id = null` 时不受此限）

索引：`idx_settle_receipt(receipt_doc_id)`、`idx_settle_target(target_doc_id)`、UNIQUE `idx_settle_seq(seq_no)`

**`receipt_doc_id` 可以指向**：

| 来源 | 说明 | `receipt.ref_doc_id` |
|---|---|---|
| 用户手动创建的独立收付款单 | RULE-004 / RULE-005 | `null` |
| 主机自动生成的收付款单 | RULE-001 / RULE-002 / RULE-007 / RULE-008 | 指向来源主单 |

两类在**表结构上无差异**，用 `documents.ref_doc_id` 区分。
UI 单据列表默认用 `ref_doc_id IS NOT NULL` 过滤掉自动生成的收付款单。

## 四、同步数据（仅 Android 端）

### 4.1 `sync_queue`

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | TEXT PK | 队列条目自己的 UUIDv7 |
| `entity` | TEXT | 目标表名 |
| `entity_id` | TEXT | 目标实体 id，幂等键 |
| `operation` | TEXT | 见下 |
| `base_version` | INTEGER NULL | `update` 时必填 |
| `payload` | TEXT | JSON |
| `status` | TEXT | `pending` / `sent` / `failed` |
| `retry_count` | INTEGER | 默认 0 |
| `last_error` | TEXT NULL | |
| `created_at` | INTEGER | |
| `next_retry_at` | INTEGER | 默认 0 |

**`operation` 枚举**：

| 值 | 语义 | 目标 |
|---|---|---|
| `createDocument` | 新单据 | `documents` + lines |
| `createMasterData` | 新主数据 | Product / Party / Account |
| `updateMasterData` | 改主数据 | 同上，带 `base_version` |
| `deleteMasterData` | 软删主数据 | 同上 |
| `documentAction` | 对已有单据执行动作 | 如"司机已签收" —— **v1 返回 `action_not_implemented`**，见下 |

`documentAction` 的 `payload`：

```json
{
  "document_id": "...",
  "action": "mark_delivered",
  "occurred_at": 1234567890,
  "remark": "张三签收"
}
```

主机收到后，在事务内执行动作并更新 `status`。动作本身不产生新 `Document`。

> ⚠️ **v1 状态**：「动作」这一抽象的**幂等判定与存储**尚未定型（待裁定项 **R-3**，
> 见 `docs/reply.md`）。因此：
>
> - **枚举值保留**（客户端仍可入队），但 `SyncServer` 一律返回
>   `rejected` + 错误码 `action_not_implemented`
> - **Android 端的"签收"按钮在 v1 禁用**（标注"v1.1 开放"）
> - v1 的签收由**主机本地**路径完成：`RuleEngine.markDelivered`（见 `rules.md` RULE-003）

索引：`idx_sync_status(status, next_retry_at)`、`idx_sync_entity(entity_id, operation)`

### 4.2 `clock_offset`（仅客户端）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | INTEGER PK | 恒为 1 |
| `offset_ms` | INTEGER | `server_time - client_time` |
| `updated_at` | INTEGER | |

## 五、不变量

以下不变量必须在测试中断言：

1. 库存 = `SUM(stock_ledger.quantity)` GROUP BY `product_id`
2. 账户余额 = `accounts.initial_balance + SUM(money_ledger.amount)` GROUP BY `account_id`
3. 往来余额 = `SUM(party_ledger.amount)` GROUP BY `party_id`
4. **B4**：任意主单 X（`doc_type ∈ {purchase, sale, sale_return, purchase_return, delivery}`）
   的 `paid_amount` = `SUM(settlements.amount WHERE target_doc_id = X.id)`
   —— 方案 C 统一了资金流后，**没有排除项**
5. **B4'**：`receipt` / `payment` 单本身**不出现在** `settlements.target_doc_id` 中
   （它们只出现在 `receipt_doc_id`）
6. **B5**：`SUM(document_lines.amount) = document.total_amount`，适用于
   `doc_type ∈ {purchase, sale, delivery, sale_return, purchase_return}`
   - `stocktake`：`total_amount = 0`
   - `receipt` / `payment`：`total_amount` = 收/付款金额，`document_lines` 为空
7. `SUM(stock_ledger.quantity) × 单价区间` 与 `SUM(total_cost)` 的关系仅通过 `unit_cost` 派生

## 六、成本口径边界

- `unit_cost` / `total_cost` **不含运费、折扣、税费**。这些通过其他单据体现。
- 成本采用"出库时点加权平均"：`WHERE seq_no < 出库 seq_no AND quantity > 0`
- 舍入策略：**round-half-up**。成本总额 ≠ 出库数量 × 出库均价，这是正常现象。
- **负库存出库成本**：取最近一次入库的 `unit_cost`。

## 七、排序与时钟

- 排序一律用 `seq_no`（表内单调），**不用** `occurred_at`
- `occurred_at` 仅用于展示与筛选
- Android 端本地排序用 `(created_at, id)`。`seq_no` 是主机内部概念，**客户端不持久化、不引用**
- Android 端离线产生的记录 `time_estimated = 1`。主机保留该标记，用于审计

## 八、盘点语义

```text
document_lines.quantity = 盘点后的实际数量（不是差额）

系统在主机事务内计算 diff = 实际数量 - 账面数量

diff > 0 盘盈，diff < 0 盘亏，diff = 0 不产生流水

盘点单 total_amount = 0，paid_amount = 0

盘点不生成 party_ledger / money_ledger

盘亏只通过 stock_ledger.total_cost 进入毛利，不产生资金流出

盘点单提交后不可撤销。发现错误只能再盘一次
```
