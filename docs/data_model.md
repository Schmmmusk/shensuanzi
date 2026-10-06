# 数据模型

> 真相来源是流水表，不是余额表。任何"当前状态"均可由流水重放得出。
>
> **版本与升级**（建表语句的演进、迁移链、兼容性原则）见 **`docs/schema_migration.md`** ——
> 本文件描述**当前版本**的结构，不重复迁移纪律。

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
| `code` | TEXT UNIQUE | 商品编码。**由系统生成**（`P0001` 起，见 `docs/reply.md`），用户不填 |
| `name` | TEXT | 名称 |
| `barcode` | TEXT NULL | 条码，索引 |
| `unit` | TEXT | 单位，默认"件"。**最小销售单位**（§AJ·AI-5 裁定）—— 库存、成本、流水均按此单位记。按箱进、按个卖的商品填「个」，装箱关系写 `package_note`；**需要按箱录入自动换算**的商品另填 `package_unit` / `package_size`（见下方 v3 两列与 §3.2 的 7 条） |
| `cost_price` | INTEGER | 参考进价（分） |
| `sell_price` | INTEGER | 售价（分） |
| `safety_stock` | INTEGER | 安全库存 |
| `category` | TEXT NULL | 分类 |
| `is_active` | INTEGER | 默认 1 |
| `remark` | TEXT NULL | |
| `package_note` | TEXT NULL | 包装说明（如「1 箱 = 48 瓶」）。**纯备注，给人看的**（§AJ·AI-5），库存页展示用。schema v2 新增，存量库经 `Schema.migrationStep(1)` 迁移 |
| `package_unit` | TEXT NULL | **包装单位名**（如「箱」）。与 `package_size` **成对**：两列**同时有值**才启用包装换算，任一为空 ⇒ 行为与 v2 完全一致。schema v3 新增（`migrationStep(2)`）。与 `package_note` 的分工：**那个是备注，这两列是给换算用的数据** |
| `package_size` | INTEGER NULL | **1 个包装 = 多少个最小单位**（正整数，如 48）。与 `package_unit` 成对，schema v3 新增（`migrationStep(2)`）。换算的唯一实现 = core 纯函数 `toBaseQuantity`（见 §3.2 的 7 条交互关系） |
| `created_at` | INTEGER | |
| `updated_at` | INTEGER | |
| `sync_version` | INTEGER | 默认 0 |

索引：`idx_products_barcode(barcode)`、`idx_products_updated(updated_at, id)`

**⚠️ `code` 是系统生成的，所以它不能用来排序**：编码是定宽补零的
（`P0001`），**定宽总会在某个位数上断掉** —— `P10000` 的字典序小于 `P9999`。
所以：

- **列表排序用 `(created_at, id)`**（= 建档顺序，与 `sync_protocol.md` §七 一致）
- **取最大编码时必须 `ORDER BY LENGTH(code) DESC, code DESC`** —— 先比长度再比字典序，
  等价于「数值最大」。只按 `code DESC` 会取回 `P9999`，生成器算出 `P10000` ⇒ **撞 UNIQUE**
  （`ProductCodeGenerator` 的回归守卫钉住了这条）

`barcode` 有索引但**不唯一**：两条商品可以共用同一个条码（真实世界里会发生，
比如同一箱货拆开卖）。扫码时取**最早建档**的那条 —— 若将来要改成「拒绝重复」，
那是规格变更，需要裁定（见 `docs/reply_review.md` 附录的待裁定项）。

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

索引：`idx_parties_phone(phone)`、`idx_parties_updated(updated_at, id)`

**`roles` 的语义**（§审查 OBS-05 后半 / `rules.md` RULE-010）：

- 角色是 party 的**属性**，**不参与任何流水计算** —— 库存 / 资金 / 往来全部按
  `party_id` 汇总，与 `roles` 无关。⇒ **任何时候都能加 / 减角色**，历史交易
  不受影响（流水里存的是 `party_id`，不是角色快照）。
- 新建时至少一个角色；编辑时允许清空（清空后不出现在开单的选择器里，UI 有提示）。

**`is_active` 的语义**（停用 = 软删）：

- **停用不影响 `party_ledger`** —— 余额仍按 `party_id` 汇总、**照常计入往来**，一分不少。
- 停用只意味着**不再出现在开单的客户 / 供应商选择器里**。
- ⚠️ 因此**停用但余额 ≠ 0 的 party 仍然显示在往来方页**（标「已停用 · 账未结清」）。
  把它藏起来会让那笔应收 / 应付变成用户看不到的**「幽灵账」** —— 催款会漏掉、
  对账永远差一笔。显示口径的唯一实现是 `PartyService.listVisible()`。

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

索引：`idx_accounts_updated(updated_at, id)`

> **三张主数据表的 `(updated_at, id)` 复合索引**是 §8.2 增量拉取的游标索引
> （R-13 方案 A，`sync_protocol.md` §8.2）。`updated_at` **不唯一**，
> 单列游标会丢行或死循环，所以索引必须带上 `id`。

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
  （`in_transit → delivered → settled`；**拒收路径**：客户拒收 ⇒ 规则
  RULE-007 在同一事务内把未签收的送货单置为 `cancelled`，2026-10-04 裁定 ——
  见 `rules.md` RULE-003 状态机），与上式冲突，已记为待裁定项 **R-10**。
  具体语义见 `rules.md` RULE-003：
  - 创建即 `in_transit`，**即使已收满款也不改**（钱到了，货还在路上）
  - 签收后（`RuleEngine.markDelivered`）才允许由 `paid_amount` 决定
    `delivered` / `settled`

**动作只做单向终态转变**（R-3，2026-09-29）：`mark_delivered` 是 v1 唯一的动作
（送货单 `in_transit → delivered`），**反向业务用新建单据表达，不修改历史**
（如「反签收」= 新建冲抵单，不是把状态改回去）。因此幂等判定**只看当前状态**、
不需要 `document_actions` 表；动作的回执分类与 FAW 并发语义见 `sync_protocol.md` §8.5。

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
| `unit_price` | INTEGER | 单价（分）。**派生展示**：v3 起 = `round(amount / quantity)`，**不再被改**（档价 `products.sell_price` 只是预填默认值） |
| `amount` | INTEGER | 小计（分）。**这一行真正发生多少钱** —— v3 起 = **`entry_quantity × entry_unit_price − discount_amount`**（`entry_unit_price` 是**录入单位报价**，**不落库**）。⚠️ 别写成 `quantity × unit_price` —— `unit_price` 是派生值（见下），用它反算会有舍入差（36 × 2083 = 74988 ≠ 75000） |
| `discount_amount` | INTEGER | **让价**（分、**正数**、默认 **0**）—— 这一行让掉多少，**不是**「负商品」。schema v3 新增（`migrationStep(2)`）。**整单议价 = 把差额记在某一行**（UI 默认最后一行）。`unit_price` 是**派生展示**（= `round(amount / quantity)`），**不再被改**；档价只是预填默认值 |
| `entry_quantity` | INTEGER NULL | **录入原文数量** —— 用户当时在输入框里输的那个数字。schema v3 新增。⚠️ **「纯记录」的准确含义**：落库**之后**不参与库存、成本、往来余额等**派生**计算；但落库**当时**它是 `amount` 公式的原文数量、也是展示反推（`amount / entry_quantity`）的来源 —— 不是"从头到尾都不参与" |
| `entry_unit` | TEXT NULL | **录入原文单位** —— **三态**：`null` / `products.unit` / `products.package_unit`；可取 `package_unit` 的前提是 **`package_unit` 与 `package_size` 都非空**（成对启用 —— 缺一个就只能选 `products.unit` 或 null，否则会出现"能选箱但报没设换算"的半配置状态）；**其余值 ⇒ 校验拒绝**。**null = 用户没在两种单位间切换**。schema v3 新增。⚠️ **「纯记录」的准确含义**：落库**之后**不参与派生计算；但落库**当时**它是 `toBaseQuantity` 的**输入**（决定 `quantity` 怎么来）—— 见下方第 4 条 |
| `remark` | TEXT NULL | |

#### v3 五列：包装换算与让价（**已落地** · schema v3 / `migrationStep(2)` · §BD）

**7 条交互关系**（裁定原文见 `reply_review.md` §BD·三）—— 实现者**不许在各处各自解读**：

1. **三对字段的分工**：`products.unit` = **最小销售单位** · `products.package_unit` = **包装单位名** ·
   `products.package_size` = **1 个包装 = 多少个最小单位**（正整数）·
   `document_lines.quantity` = **永远是最小单位数量** · `entry_quantity` = **录入原文数量** ·
   `entry_unit` = **录入原文单位**。
2. **`entry_unit` 允许 `null`**（散客买 3 个，强制选单位是摩擦）：`null` = 用户没在两种单位间切换，
   此时 `entry_quantity == quantity`；`= products.unit` ⇒ 同上；`= package_unit` ⇒
   `entry_quantity × package_size == quantity`。**规则统一：`entry_quantity` 永远等于输入框里
   那个数字，`quantity` 永远是换算后的值。**
3. **两个名字空间**：档案写了 `package_unit = '箱'` **不代表**这次必须按箱录（可以输「5 瓶」）。
   `entry_unit` **三态** —— `null`、`products.unit` 或 `products.package_unit`；
   可选 `package_unit` 的**前提是成对启用**（`package_unit` 与 `package_size` **都非空**；
   缺一个就只能选 `products.unit` 或 null —— 否则会出现"能选箱但报没设换算"的半配置状态）。
   **其余值 ⇒ 校验拒绝**。
4. **换算的唯一落点 = core 纯函数 `toBaseQuantity`**（`documents/quantity_conversion.dart`，
   2b 段实现）—— **不在 UI 里做**：三份草稿（采购 / 销售 / 送货）共用同一换算 · UI 不懂业务 ·
   `dart test` 要能覆盖。失败返回 `null`，**三种原因分开报**（UI 文案不许共用一句）：
   `entryUnit == null || == baseUnit` ⇒ `entryQuantity`（不失败）；
   `== packageUnit` 且 `packageSize != null && packageSize > 0` ⇒ `entryQuantity × packageSize`；
   `== packageUnit` 但 `packageSize == null` ⇒ `null`（UI 报**「这个商品没设包装换算」**）；
   `== packageUnit` 但 `packageSize <= 0` ⇒ `null`（UI 报**「包装换算无效」**——
   档案校验本应挡住，纯函数兜底防的是数据被外部改坏）；
   第三种单位 ⇒ `null`（UI 报**「单位不合法」**—— 校验拒绝；理论上不该发生，因为 UI 只给两个
   选项，但兜底文案必须与"没设换算"分开）。
5. **`unit_price` 是派生展示，禁止加第六列** —— 用户输「3 箱 × ¥250/箱」：
   `amount` = 75000（**真相**，用户填的）· `quantity` = 36（**真相**，换算后）·
   `unit_price` = `round(amount / quantity)` = 2083（**派生**；⚠️ 它与 36 相乘 ≠ 75000，
   正因为如此 `amount` 才是真相、它只是展示）。
   **「¥250/箱」不需要存**：展示**原始录入报价**时由
   `(amount + discount_amount) / entry_quantity` 反推；展示**折后**单位报价时才用
   `amount / entry_quantity` ⇒ **不许加 `entry_unit_price` 列**。
6. **`discount_amount` 与单位无关** —— 让价是**整单金额**的减项：
   `amount = entry_quantity × entry_unit_price − discount_amount`
   （`entry_unit_price = amount_before_discount / entry_quantity`，派生）。
   永远是**分**、**正值**，范围 `[0, entry_quantity × entry_unit_price]`。
   ⚠️ 这个上限是**单行**的 —— **整单议价**的差额若超过最后一行折前金额，
   **由 UI 从最后一行向前分摊到多行**（每行各记各的 `discount_amount`，都守各自上限；
   整单差额恒 ≤ 整单折前金额，所以分摊**总有解**，不会出现"摊不完"）。
   「记在某一行」只是**默认起点**，不是硬性约束。
7. **`entry_*` 不因商品档案变化而重解释** —— 录入时 `package_size = 12`，历史行
   `entry_quantity = 3 / entry_unit = '箱'`；三个月后档案改成 24 ⇒ 历史行 `quantity`
   **不变**（仍 36）。改档案改的是**将来**怎么换算，**不改历史** ——
   与「业务数据不可变」同一哲学。

**连带校验（2b 段实现）**：有 `packageSize` 时必须 `packageSize > 0` 且 `packageUnit`
非空；`packageUnit` 与 `packageSize` **成对**，不允许半配置。导出表**取 `amount`
不取 `unit_price`**，并加断言（导出列里不出现 `unit_price`）。

**不变量不变**：B5 守的是**列级** `Σ amount = documents.total_amount`
（`amount` 已含让价），**不守**行级乘积。
`amount` 是真相、`unit_price` 是派生展示 —— 与 `total_cost` / `unit_cost` 同哲学
（§AY·一 已解除行级严格约束）。

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
**UI 单据列表对「派生单据」的过滤口径**（§审查 OBS-08 / §AN·二，2026-10-05 更新）：

| 单据 | `ref_doc_id` | 默认列表 | 说明 |
|---|---|---|---|
| **自动生成**的收付款单 | 指向来源主单 | **不显示** | 免得「一笔交易两条记录」 |
| **手动创建**的收付款单（含在详情页点「收款 / 付款」核销产生的） | `null` | **显示** | 用户主动发起的独立交易，要能打开 / 导出 |
| **拒收**产生的整单退货单（原单已作废） | 指向原送货单 | **不显示** | 与已作废的原单内容一致 ⇒ 只有「退货记录」里能点开 |
| **普通退货**单 | 指向原单 | **显示** | 独立交易（`settlement_view_test` 钉住） |

实现：`DocumentDao._summaries` 的 `includeDerived` 参数；用户**明确按
「退货 / 收付款」类目筛选**时放开（否则选了那一类会一片空白）。

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
| `status` | TEXT | `pending` / `sent` / `failed` —— 生命周期见下 |
| `retry_count` | INTEGER | 默认 0 |
| `last_error` | TEXT NULL | |
| `created_at` | INTEGER | |
| `next_retry_at` | INTEGER | 默认 0 |

**`status` 的生命周期**（R-14 附带的「未同步影响」，2026-09-26 裁定）：

| 状态 | 含义 | 进入 | 离开 |
|---|---|---|---|
| `pending` | 本地已开单、**尚未 push 成功**（或 push 失败待重试） | 用户开单（`next_retry_at = 0`） | push 成功 → `sent` |
| `sent` | 已 push 成功、主机已收下，但**拉取尚未确认** | push 回执 `applied` / `already_exists` | **pull 见到该 `entity_id`** → 删除 |
| `failed` | **死信**：`retry_count > 10`，**退出自动重试**，等人工处理 | 重试超限 | 人工 `requeue` → `pending` |

⚠️ **`sent` 不删除、只在 pull 确认后删除**：

> 如果 push 成功就删条目，用户在下次 pull 之前**看不到自己刚做的生意** ——
> 界面会显示「库存 10」而用户刚刚卖了 3 件。保留 `sent` 条目正是为了让
> 「主机已收下、但我还没在权威状态里见到」这段窗口**可见**。

⚠️ **`failed` 必须退出自动重试**：`retry_count > 10` 之后继续自动重试
等于无限重试（只是越来越慢），而规范要的是「UI 提示人工处理」。

⚠️ **清除 `sent` 按 `entity_id` 逐条确认，不是「pull 成功就清全部」**：
`pull` 是**分页**的，刚 push 的单可能落在本页之外（`seq_no` 更大）；
一刀切会把未同步影响提前归零，界面就会把刚卖掉的货又加回来。

**自动重试的对象**：只取 `pending` 且 `next_retry_at <= now` 的条目
（见 `SyncQueueDao.due`）。`sent` 与 `failed` 都不参与自动推送。

**`operation` 枚举**：

| 值 | 语义 | 目标 |
|---|---|---|
| `createDocument` | 新单据 | `documents` + lines |
| `createMasterData` | 新主数据 | Product / Party / Account |
| `updateMasterData` | 改主数据 | 同上，带 `base_version` |
| `deleteMasterData` | 软删主数据 | 同上 |
| `documentAction` | 对已有单据执行动作 | 如"司机已签收" —— 已落地 `mark_delivered`（R-3，2026-09-29），见下 |

`documentAction` 的 `payload`：

```json
{
  "action": "mark_delivered",
  "occurred_at": 1234567890
}
```

主机收到后，在事务内执行动作并更新 `status`。动作本身不产生新 `Document`。
`occurred_at`（客户端提供）仅展示用，不参与判定、不落库（R-3.3）。

> ✅ **已落地（R-3，2026-09-29 裁定）**：动作只做**单向终态转变**，
> v1 唯一动作 `mark_delivered`（送货单 `in_transit → delivered`，规则本体
> `RuleEngine.markDelivered`）。回执：转变 → `applied`；重复签收 → `already_exists`；
> 状态不匹配（如已取消）→ `conflict` + `server_state`（客户端自动对齐）；
> 规则不允许（类型不符 / 单据不存在）→ `rejected`；未知动作 → `rejected` +
> `unknown_action`。分类原则与 FAW 并发语义见 `sync_protocol.md` §8.5。
> 将来做 MSIX/AH-B：Android 端「签收」按钮随之解锁。

索引：`idx_sync_status(status, next_retry_at)`、`idx_sync_entity(entity_id, operation)`

### 4.2 `clock_offset`（仅客户端）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | INTEGER PK | 恒为 1 |
| `offset_ms` | INTEGER | `server_time - client_time` |
| `updated_at` | INTEGER | |

### 4.3 `sync_cursor`（仅客户端）—— 拉取游标

**R-14 方案 A**（2026-09-26 裁定，论述见 `docs/reply.md`）。

| 字段 | 类型 | 说明 |
|---|---|---|
| `entity` | TEXT PK | **§8.2 的键名**（`stock_since` / `doc_since` / `products_since` …），**不是表名** |
| `cursor` | TEXT | **原样保存**主机返回的 `next_cursors` 值；客户端**从不解析** |
| `updated_at` | INTEGER | 本游标最后一次推进的主机毫秒时间戳 |

**设计取舍**：

| 决策 | 理由 |
|---|---|
| `entity` 作 PK，**不是 `id = 1` 的单行表** | 加同步实体 = **插一行**，不是加一列。8 列变 9 列的迁移比 1 行变 2 行的迁移痛得多 |
| `cursor` 统一 `TEXT` | `seq_no` 的整数字符串与复合游标的 `"1700000000000\|0192…"` 形态统一；客户端**原样回传** |
| `entity` 存**键名**而非表名 | 不变量 B8 要求本表与 `next_cursors` **逐字段一致** —— 存键名时那就是两个 map 的**直接相等**，不需要映射层（与「wire 值 = `toRow()` 形态」同一条原则）。键的单一出处是 `SyncCursorKeys.all` |
| **不存「是否已初始化」标志** | **没有行 = 从头拉**，这是正确的默认，不需要额外状态 |
| `updated_at` 是**主机毫秒**，不是本地时钟 | 仅供审计与 UI 显示「镜像新鲜度」，不参与计算 |

**为什么游标不解析**（协议特性，不是妥协）：

- 主机可以**换游标编码**（例如从 `"1700000000000|0192"` 换成 base64）而**不需要客户端升级**
- 客户端不需要知道 `seq_no` 或 `(created_at, id)` 的语义 —— 它只负责原样回传
- 客户端本地排序用 `(created_at, id)` 是**展示层的需要**，与同步游标无关

**为什么不能从本地镜像推算**（这是 R-14 的核心）：

游标回答的是「**服务器已交付到哪里**」（通信状态），
`MAX(本地镜像)` 回答的是「**我本地有什么**」（数据状态）。
神算子的写入路径有**三条**（pull、push 的回程、本地离线写），
后两条会让本地镜像**越过**服务器已交付的水位 —— 于是推算出的游标会
**静默跳过**其它设备在中间写入的数据。**详见 `docs/reply_review.md` §M。**

### 4.4 客户端镜像的硬约束

1. **镜像必须关闭外键**：`Db.open(path, foreignKeys: false)`。
   主机是权威，完整性由主机保证；客户端一侧的 FK 会让 `pull` 变成**毒丸** ——
   某一行引用的主数据若落在本页之外（`limit` 分页），该行永远插不进去，
   于是 pull 每次整批回滚、游标退回，形成死循环。
   （`PRAGMA foreign_keys` 在事务内是 **no-op**，所以只能在打开时定。）
   `SyncClient` 构造时会**显式拒绝**开着外键的镜像。
2. **本地占位单号必须唯一**，且不得与主机单号同形：本地乐观写入用
   `Document.pendingDocNoPrefix + <本地唯一后缀>`；主机回填正式单号后覆盖。
   （`documents.doc_no` 有 UNIQUE 约束；撞车意味着镜像已损坏，
   `pull` 会抛**带上下文**的 `StateError`，修复路径是重建镜像 + 重拉。）
3. **镜像只读，写入仅通过 pull**（C2·§CC，2026-10-06）：
   九张业务表的唯一写入方是 `SyncClient.pull`；用户 UI 一律只读
   （手机端读面 = 镜像库，本机主库废弃但保留 —— v1 Android 未发布，无历史数据，不迁移）。
   `sync_queue` / `clock_offset` / `sync_cursor` 三张**客户端传输表**不在此限
   （§四：它们是传输状态，不是业务数据）。
   主数据「新建 / 编辑 / 停用」只在主机做 —— 手机端本机建的 id 推到主机会被
   外键拒绝（§CC 摸底：协议正确性），UI 上以「保留入口 + 引导到电脑」呈现。

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
   —— ⚠️ 这是**列级**不变量：守的是「合计 = 各行小计之和」，
   **不守**行级 `amount = quantity × unit_price`（该严格等式已于 2026-10-02 解除 —— `reply_review.md` §AY·一）
   - `stocktake`：`total_amount = 0`
   - `receipt` / `payment`：`total_amount` = 收/付款金额，`document_lines` 为空
7. `SUM(stock_ledger.quantity) × 单价区间` 与 `SUM(total_cost)` 的关系仅通过 `unit_cost` 派生
8. **B7**：主数据（`products` / `parties` / `accounts`）的 `updated_at`
   在**每次写操作后**由主机刷新为主机当前时钟 —— 它是 §8.2 增量拉取的游标列
   （R-13 方案 A）。不刷新，客户端就永远感知不到「另一台设备改了价格」。
   「写操作」含 `createMasterData` / `updateMasterData` / `deleteMasterData`
   （**软删也算写**：`is_active = 0` 必须让另一台设备看得见）
9. **B8**：每次成功 `pull` 后，`sync_cursor` 的 8 行（首次为 8 条插入）
   与响应体的 `next_cursors` **逐字段一致**。
   任何一行不一致即同步实现 bug。
   *这条可以直接在测试里断言*：把主机的 `next_cursors` 与
   `SELECT * FROM sync_cursor` 做**等值比较**（这也是 `entity` 存键名而非表名的原因）。

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

**客户端不跑业务规则**（R-14 附带问题 3 的裁定，2026-09-26）：

客户端**不实现 `RuleEngine`**，只维护一个「已发生、但权威状态还没包含」的
**数量 delta**（由 `sync_queue` 派生，见 `sync_protocol.md` §一）：

- **只做 `±quantity` 累加**：算不出加权成本，因为那依赖 `seq_no`；
  算不出盘点影响，因为那需要账面数量
- **不算成本、不算往来余额**：宁可**诚实地不提供**，也不要「看起来精确的错误」
- 客户端算出的成本/余额与主机**必然有偏差**，且偏差随离线时长增长 ——
  跑规则不是「更准的估算」，而是「看起来更准的错误」，且**没有任何门禁能发现**
  （主机侧有 9 条规则的门禁，客户端侧没有）

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
