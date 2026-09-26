# Reply.md（v0.2 / v0.3）审查报告

> 审查日期：2026-09-25
> 审查对象：`D:\库\Desktop\Reply.md`（3181 行，含 v0.2 数据模型答复 + v0.3 同步规范 + Dart 骨架）
> 审查方式：逐条对照规范文本与参考代码，并对可判定项做了静态推演（未运行，本机 Dart VM 创建子进程受限）
> 结论：**规范方向正确、信息密度高，采纳。但参考代码不能直接运行，且存在 9 项必须在实施前裁定的阻断问题。**

## 0. 结论速览

| 分级 | 数量 | 含义 |
|---|---|---|
| **P0 阻断** | 9 | 不裁定就动手，写出来的代码必然返工或直接报错 |
| **P1 高** | 10 | 影响正确性 / 会计精度 / 安全，建议实施前定 |
| **P2 次要** | 7 | 可在实施中补，但需在文档写明 |

另外有一项**文档治理问题**：v0.2/v0.3 目前只存在于仓库外的桌面文件，仓库内的 `Agents.md` 仍是 v0.1，
项目"单一来源"约定已被破坏（见第四节）。

---

## 1. 阻断问题（P0）—— 实施前必须裁定

### P0-1 `Db.transaction` 不可重入，`purchaseInbound` 与 `stocktake` 必然抛错

**位置**：`lib/src/db/database.dart` 的 `Db.transaction`；`lib/src/rules/rule_engine.dart` 的 `purchaseInbound` / `stocktake`；
`lib/src/dao/document_dao.dart` 的 `insertIfAbsent`。

**现象**：`purchaseInbound` 外层调用 `db.transaction(...)`（`BEGIN IMMEDIATE`），内部又调用
`docs.insertIfAbsent(...)`，而后者**自己也调用 `db.transaction(...)`** → 嵌套 `BEGIN IMMEDIATE`。
SQLite 不支持嵌套事务，会抛 `SqliteException: cannot start a transaction within a transaction`。

**为什么是问题**：这不是边界情况，是**主路径 100% 触发**。文档给出的两个示例测试（`invariants_test.dart` 的两个用例）
都会在这一步失败，因此"参考代码可跑"这一前提不成立。

**推荐处置**：`Db.transaction` 改为**可重入**——用深度计数器（depth == 0 时才 `BEGIN`/`COMMIT`/`ROLLBACK`），
或改用 `SAVEPOINT`。同时明确"DAO 不自己开事务，由 RuleEngine 统一开"的边界，二者选一，不要两套并存。

---

### P0-2 `SyncServer._applyCreate` 只做裸 INSERT，不走 RuleEngine —— 客户端推上来的单据不产生任何流水

**位置**：`lib/src/sync/server.dart` 的 `_applyCreate`。

**现象**：实现是通用表插入：

```dart
final cols = op.payload.keys.join(', ');
db.raw.execute('INSERT INTO $table ($cols) VALUES ($ph)', op.payload.values.toList());
```

若客户端推送 `entity = 'documents'`，则**只有 `documents` 一行落库**，`document_lines`、`stock_ledger`、
`money_ledger`、`party_ledger` **全部不产生**。库存、资金、往来三本账在同步路径上整体丢失。

**更深一层**：v0.3 §6 规定"`seq_no` 由主机分配"，而 `seq_no` 只在**主机事务内**能分配。
通用插入无法分配 `seq_no`，因此"客户端推全部流水行"这条退路**与 §6 直接冲突**。
`settlements` 同理——它由 Android 端 create 并 push，但主机侧的通用插入**不会**刷新
`documents.paid_amount` 这个缓存字段。

**这是文档与参考代码之间最严重的一处断裂，必须二选一：**

| 方案 | 内容 | 代价 |
|---|---|---|
| **A（推荐）** | 客户端只推 **`Document` + lines**；主机侧 `SyncServer` 收到后**调用 `RuleEngine` 的对应规则**落地，`seq_no` 与流水由主机生成 | 需主机侧按 `doc_type` 分派规则；客户端离线期间无权威流水 |
| B | 客户端把 4 张流水表的行一并推上来 | 与 §6"seq_no 由主机分配"冲突，需改为客户端分配（则失去全局单调性） |

---

### P0-3 参考测试无法编译（两处确定性编译错误）

**位置**：`test/invariants_test.dart`。

1. `_memDb()` 中 `return Db._(db);` —— `Db._` 是**库级私有**构造，测试在另一个库，
   **不可访问** → `The constructor 'Db._' isn't defined`。
2. 测试只 `import 'package:shensuanzi_core/src/db/database.dart'`，却使用 `Schema.createTables`；
   Dart 的 `import` **不传递导出**（`database.dart` 里的 `import 'schema.dart'` 不会对外暴露 `Schema`）
   → `Undefined name 'Schema'`。

**推荐处置**：给 `Db` 增加公开工厂 `Db.openInMemory()` 与 `Db.forTesting(Database raw)`；
在 `lib/shensuanzi_core.dart` 统一 `export` 需要对外可见的符号，测试改为 import 包入口。

---

### P0-4 同步队列的"四类写入"与"只推 create"自相矛盾；离线动作（司机签收）没有队列类型

**位置**：v0.3 §3「状态变更的动作化」。

**现象 A（自相矛盾）**：同一节先写「`sync_queue` 只推 `create`，不推 `update documents.status`」，
紧接着又写「Android 端的 sync_queue 只需要处理三类写入：1. create Document 2. **update 主数据** 3. create Settlement」。
第 2 类就是 update。`sync_queue.operation` 的枚举也含 `update`/`delete`。
应改为：「业务数据（Document + 4 张 Ledger）只推 create；主数据可推 update/delete」。

**现象 B（实质缺口）**：§3 规定客户端改状态必须走 `POST /api/documents/:id/actions`。
但**"司机已签收"恰好是离线场景的核心动作**（送货途中无网是常态）。而三类写入里**没有 action**，
`sync_queue.operation` 枚举里也没有 → **离线状态下无法签收**。

**推荐处置**：`sync_queue.operation` 增加第 4 类 `action`；`payload` 存
`{ "document_id": ..., "action": "mark_delivered", ... }`；主机收到后在其事务内执行动作并更新 `status`。

---

### P0-5 `doc_no` 的生成主体未定义，且 `documents.doc_no` 是 `UNIQUE` → 离线多端必然撞号

**位置**：`schema.dart` 的 `doc_no TEXT NOT NULL UNIQUE`；骨架里的 `rules/doc_no_generator.dart`（**无实现**）。

**现象**：v0.3 让 Android 端**离线**开单并本地生成 `document.id`（UUIDv7），但**没有规定 `doc_no` 由谁生成**。
若客户端也按 `XS20260925-001` 规则本地生成，两台设备同日离线开单**必然撞号**，推送时
`UNIQUE` 冲突 → 插入失败，且 `_applyCreate` 会把它抛成异常（见 P1-3）。

**推荐处置（三选一）**：

| 方案 | 内容 |
|---|---|
| **A（推荐）** | `doc_no` **由主机在事务内生成**；客户端离线期间用 UUIDv7 前 8 位做**临时展示号**，同步后由主机回填正式号 |
| B | 客户端生成，规则改为 `前缀-YYYYMMDD-设备短码-序号`，用 `device_id` 保证不撞号 |
| C | 放弃人可读单号，直接用 UUID（违背原始需求，不建议） |

---

### P0-6 `seq_no` 是"全局单调"还是"每表独立"—— 规范与实现不符，且同步游标不可用

**位置**：v0.2 §8 写「由**主机**在写入时分配，**全局单调递增**」；
实现上 `SeqCounter` 是**每张表独立** `MAX(seq_no)+1`；`schema.dart` 为三张流水表各建了一个
**表内 UNIQUE** 索引（`idx_stock_seq` / `idx_money_seq` / `idx_party_ledger_seq`）。

**后果**：`seq_no` **不是全局唯一键**。而 v0.2 §7 的接口
`GET /api/sync/pull?since_seq=` 是**单个游标**——它无法跨 `stock_ledger` / `money_ledger` /
`party_ledger` 三张表分页（三张表的 `seq_no` 各自从 1 开始，语义不同）。

**推荐处置**：明确"**每表独立单调**"是最终语义（成本计算在表内自洽，够用）；
把 §8 的"全局单调递增"改为"每张流水表内单调递增"；
`/api/sync/pull` 改为**按实体分别传游标**（如 `?stock_since=&money_since=&party_since=&doc_since=`）。

---

### P0-7 `documents.sync_version` 是否存在 —— 文档三处自相矛盾

| 出处 | 说法 |
|---|---|
| v0.2 §0 白名单表 | `documents` 允许 UPDATE `status`, `paid_amount`, `updated_at`, **`sync_version`**（4 个） |
| v0.2 结尾「一句话规格」 | 「`documents` 表只允许更新 `status`、`paid_amount`、`updated_at`、`sync_version` 四个字段」 |
| v0.3 §4 | 「**`sync_version` 只对主数据有意义**（Product / Party / Account）。业务数据不需要 `sync_version`」 |
| 参考代码 `schema.dart` | `documents` 表**没有 `sync_version` 列** |
| 参考代码 `updateStatusAndPaid` 注释 | 「只允许 `status` / `paid_amount` / `updated_at`」（**3 个**） |

**结论**：v0.3 §4 与参考代码是正确的（3 个字段，无 `sync_version`）。
**需修正**：v0.2 §0 白名单表与"一句话规格"两处必须删掉 `sync_version`，否则实施者会照着加列。

---

### P0-8 `sync_queue.idempotency_key` —— 同一份文档内前后矛盾

- v0.2「总纲」表：`sync_queue` **增加 `idempotency_key`** → 解决问题 6
- v0.3 §1：**「不设 `sync_queue.idempotency_key`。幂等键就是实体自身的 UUIDv7 主键」**

v0.3 是显式冻结的结论，应以此为准（且理由充分：避免幂等键与主键不同步）。
**需修正**：删除 v0.2 总纲表该行，或标注"已被 v0.3 取代"。

---

### P0-9 缺少 `sqlite3_flutter_libs` —— 桌面能跑、Android 直接崩

**位置**：v0.3 的 `shensuanzi_core/pubspec.yaml` 依赖清单。

`package:sqlite3` 只是 **Dart 绑定**，不含原生库。Android 上必须搭配 `sqlite3_flutter_libs`
（由它提供 `libsqlite3.so`），Windows 上也需要它把 `sqlite3.dll` 带进产物。
参考 pubspec 只有 `sqlite3` / `uuid` / `path` / `collection` → **Android 端首次运行即报
`Failed to load dynamic library`**。

**推荐处置**：`shensuanzi_core` 增加 `sqlite3_flutter_libs`。注意这是 federated 插件，
按项目既定纪律，**引入前先跑 `dart pub add --dry-run` 量出连带包范围**再确认。

---

## 2. 高优先问题（P1）—— 影响正确性 / 会计精度 / 安全

### P1-1 `_weightedCost` 缺 `seq_no <= ?` 上界，不是"时点成本"

**位置**：`rule_engine.dart` 的 `_weightedCost`。

v0.2 §5 给的公式是**时点加权**（含 `AND seq_no <= ?`），实现里**该条件被漏掉**：

```dart
'... FROM stock_ledger WHERE product_id = ? AND quantity > 0'   // 缺 seq_no <= ?
```

后果：算的是"截至**当前**（含之后所有入库）的加权平均"，而**不是出库那个时点**的加权平均。
与 v0.2 §5「出库时点加权平均成本（Point-in-Time）」的定名不符。
**处置**：补上上界（传入当前待分配的 `seq_no`），或明确把口径改名为"当前加权平均"并更新 §5。

### P1-2 加权成本用整数截断，且盘盈会回写成本形成自反馈

1. `return total ~/ qty;` —— **整数除法截断**。例：入库 3 件，成本分别 100/101/101 分
   → `302 ~/ 3 = 100` 分，每件凭空少 0.67 分。因为出库 `unit_cost` **写入即冻结**，
   误差**永久固化**，且方向单一（系统性低估成本 → **毛利虚高**）。
   **必须定义舍入策略**（建议 round-half-up，并在规范里写明"成本总额 ≠ 出库数量 × 出库均价"）。
2. RULE-009 盘点盘盈时写入 `unit_cost = _weightedCost(...)`，而该值正是历史入库的加权平均
   → 在**精确算术下不改变均值**、在**截断算术下逐步下移**均值。两者叠加会放大 P1-2.1 的漂移。
   **处置**：盘盈的 `unit_cost` 取值口径需显式规定（用当前加权、还是用最近一次入库价）。

### P1-3 同步服务端拼 SQL，且 `_applyDelete` 对无 `is_active` 列的表会直接报错

**位置**：`server.dart` 的 `_applyCreate` / `_applyUpdate` / `_applyDelete`。

1. **注入面**：`op.entity`（表名）与 `op.payload.keys`（列名）**直接字符串拼接进 SQL**。
   token 是唯一的门（明文进二维码、v1 无 TLS，见 v0.2 §10）——一旦泄露即可任意拼表名/列名。
   **处置**：服务端维护**表名白名单 + 列名白名单**，拒绝一切不在白名单内的输入。
2. **必然报错**：`_applyDelete` 执行 `UPDATE $table SET is_active = 0 ...`，
   而 `documents` 表**没有 `is_active` 列** → `no such column: is_active`。
   §3 说队列不处理 documents 的 delete，但实现是**通用**的，没有拦截。
   **处置**：delete 仅允许主数据（Product/Party/Account），其余一律 `rejected`。

### P1-4 `settlements` 无 `seq_no`；`documents.paid_amount` 缓存刷新路径缺失

- `settlements` 是三张流水之外的**第四张真相表**（v0.2 §2 明确"真相永远是 `SUM(settlements.amount)`"），
  但**没有 `seq_no`**，只能靠 `created_at` 排序。建议补 `seq_no`，或明确"`paid_amount` 允许与真相短暂不一致，UI 必须容忍"。
- 缓存刷新路径在两处都不存在：`SyncServer._applyCreate` 不会刷新（P0-2），
  `RuleEngine` 示例里也没有核销规则 → `paid_amount` 会**永久停留在 0**。
  **处置**：核销写 `settlements` 后，**在同一事务内**按
  `SUM(settlements.amount WHERE target_doc_id = X)` 回写 `X.paid_amount`。

### P1-5 Android 离线端的本地库存视图与 `seq_no` 二义性未解决

v0.3 让 Android 离线开单并本地生成 `document.id`，但**没有规定客户端是否维护本地库存视图**。
若维护（离线优先的应有之义），则客户端必须自己排序流水，而 `seq_no` **只有主机能分配** →
同步完成后本地 `seq_no` 与主机不同 → **任何引用 `seq_no` 的本地缓存（加权成本）失效**。
**处置**：明确"客户端用 `(created_at, id)` 本地排序、`seq_no` 仅主机内部使用"，
并明确客户端库存视图是**估算值**（服务端权威）。

### P1-6 负库存（超卖）策略未定义

测试清单把"负库存"列为边界用例，但**没有任何规则规定销售时库存不足是否拒绝**。
离线优先下**必然**出现本地超卖（两台设备各自离线卖同一件货），事后无法拒绝。
**必须回答**：允许记负账（记账口径，推荐）还是拒绝出库并告警？

### P1-7 盘点单的语义缺口，与"不变量"冲突

1. `stocktake` 的 `document_lines.quantity` 记的是**盘点后的实际数量**，而标准单据记的是**交易数量**。
   **同一字段两种语义**，消费端（明细页、报表）必须按 `doc_type` 分支，否则误算。
   规范里**没有写明这一点**。
2. RULE-009 代码写入 `unitPrice: 0, amount: 0`，而测试清单 B 有独立不变量
   「`SUM(document_lines.amount)` = `document.total_amount`」→ 盘点单上该不变量成立的条件是
   `total_amount` 恒为 0，但规范**没有定义盘点单的 `total_amount` 语义**。
   **处置**：显式规定"盘点单 `total_amount = 0`，其金额信息只体现在 `stock_ledger`"。

### P1-8 核销约束缺失；RULE-004 的判定口径未随 `settlements` 更新

- v0.2 §2 给了四条核心公式，但**没有任何约束校验**：核销额不得超过收款单未核销额、
  不得超过目标单未收金额、不得为负/零。
- 原 RULE-004 的"`paid_amount >= total_amount` → `status = settled`"在引入多对多核销后，
  应改为基于 `SUM(settlements.amount WHERE target_doc_id = X)` 判断。**需在规范中改写**。

### P1-9 `time_estimated=true` 标记没有对应列

v0.2 §8 规定 Android 端估算时间要"打上 `time_estimated=true` 标记"，
但 `documents` / `stock_ledger` / `money_ledger` / `party_ledger` 的 schema 里**都没有该列**。
**处置**：补列（`INTEGER NOT NULL DEFAULT 0`），或删除该设计。

### P1-10 mDNS 依赖未决策，且是双端 + 防火墙问题

v0.2 §10 把 mDNS 列为**主方案**（`_shensuanzi._tcp.local`），但参考 pubspec 里**没有任何 mDNS 包**
（`sqlite3` / `uuid` / `path` / `collection`）。Windows 与 Android 各需实现，
Windows 还需处理**防火墙入站规则**（否则发现成功但连不上）。
按项目纪律，引入前需先量连带范围。

---

## 3. 次要问题（P2）

| # | 问题 | 处置建议 |
|---|---|---|
| P2-1 | `DocType.transfer` 在枚举里且 `docTypeFromDb` 可解析，但**无任何规则** | v1 在创建入口**显式拒绝** `transfer`，避免产生无法处理的单据 |
| P2-2 | `Document` **未实现** `base.dart` 的 `ImmutableEntity` / `MutableEntity` 抽象 | 因此"不暴露 update、编译期堵死"的承诺**未兑现**。要么让 `Document` 实现 `MutableEntity`，要么明确该承诺属后续 |
| P2-3 | `clock_offset`（客户端概念）与业务表共用同一份 `Schema.createTables` | 注明"仅客户端使用"，或拆成 `clientTables` / `serverTables` |
| P2-4 | `_applyResults` 用**下标** `resp.results[i]` 与 `pending[i]` 配对 | 应改为按 `entityId` 匹配，否则服务端顺序一变就错配 |
| P2-5 | 盘点不生成 Party/Money 流水 → **盘亏在资金与往来报表中不可见** | 需在规范写明"盘亏只通过成本进入毛利，不产生资金流出" |
| P2-6 | `accounts.initial_balance` 属可更新主数据 → 修改后**历史余额报表整体失真** | 注明"更改期初余额会重算全部历史余额"，或限制只允许在无流水时修改 |
| P2-7 | `stock_ledger.unit_cost` 取 `line.unit_price`，**不含运费/折扣** | 在规范中明示成本口径边界 |

---

## 4. 文档治理问题（需单独处理）

当前权威规范被**拆成两处**，且**仓库内外分离**：

| 位置 | 内容 | 状态 |
|---|---|---|
| `Agents.md`（仓库内，294 行） | v0.1 模型：8 张表、RULE-001~006 | 已是**过期版本**（无 `party_ledger` / `settlements` / `seq_no` / 幂等规范） |
| `D:\库\Desktop\Reply.md`（**仓库外**） | v0.2 + v0.3：11 张表、RULE-007~009、同步冻结规范 | 未入库、无版本控制 |

**风险**：`Agents.md` 仍写着"任何业务动作只能通过创建单据实现"，而 v0.2 §1 的新增记账规则
（如"采购入库生成 `party_ledger`"）**不在其中**。后续任何只看 `Agents.md` 的实施者都会做出错误实现。

**建议**：把 v0.2/v0.3 并入仓库 —— `Agents.md` 保留规则与纪律 + 摘要，实体与规则细节拆到
`docs/data_model.md` / `docs/sync_protocol.md`，并在 `README.md` 建立文档分工表（沿用 Nova 项目的做法）。

---

## 5. 工期与实施顺序评估

v0.3 修订后的 12 天计划，方向正确（同步协议先行），但**偏紧**。未计入工期的项：

1. 上述 9 项 P0 的裁定与修正（预计 0.5~1 天，且是纯返工成本）
2. `sqlite3_flutter_libs` / mDNS 的依赖实测与接入
3. Windows 防火墙入站规则、端口探测（17890→17900）
4. 二维码生成库接入（`qr_flutter`）
5. MSIX / APK 的**签名**流程（MSIX 需证书）
6. Windows UI 4 天要覆盖 3 张主数据 CRUD + 3 个开单页 + 核销页 + 库存页 —— 偏紧
7. Android 2 天要覆盖配对 + mDNS + 扫码 + 查询 + 开单 + 离线队列 + 同步 —— **明显偏紧**

**建议**：把 12 天视为"最小可运行版本"的目标，并**在第 1 天只做一件事**——
让 P0 全部落地（规范修正 + 骨架可 `dart test` 通过），再进入 schema。

---

## 6. 建议的 Day 1 范围（待确认）

1. 修正 P0-1（事务可重入）、P0-3（测试可编译）、P0-9（补齐依赖）
2. 按 P0-2 选定的方案，重写 `SyncServer` 的 create 路径
3. 完成 `schema.dart` 的最终版（含 P1-9 的 `time_estimated`、P1-4 的 `settlements.seq_no` 决策）
4. 只交付 **RULE-001 + RULE-009** 两条规则 + 不变量单测，跑通 `dart test`
5. 不碰 UI、不碰 HTTP、不碰 Android

---

## 7. 待裁定清单

| 编号 | 问题 | 推荐 |
|---|---|---|
| P0-2 | 同步落库路径 | 客户端只推 Document，主机用 RuleEngine 落地 |
| P0-4 | 离线动作（签收）同步 | `sync_queue.operation` 增加 `action` 类型 |
| P0-5 | `doc_no` 生成主体 | 主机生成 + 客户端临时展示号 |
| P0-6 | `seq_no` 语义 | 每表独立单调 + 同步游标按实体分开 |
| P0-7 | `documents.sync_version` | **确认删除**（3 字段白名单） |
| P0-8 | `sync_queue.idempotency_key` | **确认不设**（幂等键 = 实体 id） |
| P1-2 | 成本舍入 | round-half-up，并写明口径 |
| P1-6 | 负库存 | 允许记负账（待用户确认业务语义） |
| 治理 | 规范入库 | v0.2/v0.3 并入 `Agents.md` + `docs/` |

---

# 附录：v0.4 复审（2026-09-25）

v0.4 冻结版已落地于仓库内（`README.md` / `Agents.md` / `docs/{data_model,sync_protocol,rules,threat_model}.md`）。
原始答复文档（`D:\库\Desktop\Reply.md`）已迁移完毕并将删除，**本报告后续不再引用它**。

## A. 关闭确认

第一节提出的问题在 v0.4 中的处置：

| 原编号 | v0.4 处置 | 状态 |
|---|---|---|
| P0-1 事务嵌套 | `Agents.md` 纪律 1：DAO 不开事务，`Db.transaction` 必须可重入 | ✅ |
| P0-2 同步落库 | `Agents.md` 纪律 9 + `sync_protocol.md` §五：客户端只推 Document，主机走 RuleEngine | ✅ |
| P0-3 测试不可编译 | 未在文档层面提及，属实现细节（实施时用公开工厂 + 包入口 export） | ⏳ 实现侧处理 |
| P0-4 离线动作 | `sync_queue.operation` 五类含 `documentAction` | ✅ |
| P0-5 `doc_no` | 主机生成，客户端用 `待同步-XXXXXX` | ✅（但见 R-5） |
| P0-6 `seq_no` 语义 | 每表独立单调 + 游标按实体分开 | ✅ |
| P0-7 `documents.sync_version` | 删除，白名单收紧为 3 字段 | ✅ |
| P0-8 `idempotency_key` | 明确不设，幂等键 = 实体 `id` | ✅ |
| P0-9 `sqlite3_flutter_libs` | 明确必须包含 | ✅ |
| P1-1 时点成本 | `WHERE seq_no < 出库 seq_no AND quantity > 0` | ✅ |
| P1-2 成本精度 | 引入 `total_cost` 精确追踪，`unit_cost` 降为派生字段 | ✅ 优于原建议 |
| P1-3 SQL 白名单 | `Agents.md` 纪律 10 + `sync_protocol.md` §8.4 | ✅ |
| P1-4 `settlements.seq_no` + 缓存刷新 | 已加 `seq_no`；§五 明确刷新 `paid_amount` | ✅（但见 R-6） |
| P1-5 客户端排序 | 用 `(created_at, id)`，`seq_no` 不持久化 | ✅ |
| P1-6 负库存 | 允许，UI 告警，成本取最近入库价 | ✅ |
| P1-7 盘点语义 | `total_amount = 0`，`quantity` 语义分支 | ✅（但见 R-2） |
| P1-8 核销约束 | `rules.md` RULE-004 五条约束 | ✅ |
| P1-9 `time_estimated` | 补列（4 张流水 + documents + settlements） | ✅ |
| P1-10 mDNS | v1 只做二维码，mDNS 延后 v1.5 | ✅ |
| P2-1~P2-7 | 均已处置（transfer 拒绝、初始余额提示、按 `entityId` 匹配、盘亏口径、成本边界等） | ✅ |
| 治理 | v0.4 全部入库，单一来源恢复 | ✅ |

**结论：第一节的 26 项全部关闭或转入实现侧。**

## B. 残留问题（v0.4 文档内部一致性复审新发现）

### R-1 收款/付款单的 `allocations` 无承载结构 —— **阻断 RULE-004 / RULE-005 实现**

- `rules.md` RULE-004 输入 = `Document(doc_type=receipt)` + `allocations`，其中 `allocations = [{ target_doc_id, amount }]`
- `data_model.md` §3.2 `document_lines` 字段为 (`product_id`, `quantity`, `unit_price`, `amount`) ——
  **没有 `target_doc_id` 的位置**
- `sync_protocol.md` §8.1 `createDocument` 的 payload 只定义 `{ "document": {...}, "lines": [...] }`，
  `lines` 即 `document_lines` 行

⇒ **收/付款单无法表达核销分配**，因此"司机回店收款"这一核心离线场景无法从 Android 端发起。

**需裁定（三选一）**：

| 方案 | 内容 | 代价 |
|---|---|---|
| **A（推荐）** | `createDocument` 的 payload 增加可选 `allocations` 字段，主机 `RuleEngine` 在 RULE-004 内消费 | 不动表结构，仅扩 payload 契约 |
| B | `sync_queue.operation` 增加第 6 类 `createSettlement` | 需要 `settlements` 的 `seq_no` 由主机分配，且客户端要理解核销语义 |
| C | 收/付款单只允许在 Windows 主机创建 | 放弃离线收款，与"离线可用"的产品立场冲突 |

### R-2 不变量 B5 对 `receipt` / `payment` 不成立

`data_model.md` §五 不变量 5「`SUM(document_lines.amount) = document.total_amount`」只排除了 `stocktake`。
但收/付款单没有商品明细（`SUM(lines.amount) = 0`）而 `total_amount > 0` ⇒ 断言必然失败。
**处置**：把不变量改为「`stocktake` / `receipt` / `payment` 除外」，并明确这三类的 `total_amount` 语义。

### R-3 `documentAction` 的幂等判定缺乏存储依据

> ✅ **已裁定（2026-09-25）：推迟到同步层**（裁定书 `docs/reply.md`）。
> 理由：「动作」这一抽象尚未定型，它会影响 `sync_queue` 的操作枚举、
> `SyncServer` 的处理路径、甚至是否需要动作表；现在猜等于把 `sync_queue`
> 的字段设计押在未验证的假设上。**该问题不反向决定 schema 骨架**，
> 因此按「冻结的标准」留到实现层裁定。
>
> **落地方式**：`documentAction` 枚举保留但 v1 一律 `rejected` +
> `action_not_implemented`；签收走主机本地 `RuleEngine.markDelivered`
> （幂等判定**基于状态**，是 R-3.1 的候选答案）。
>
> 进入同步层时需回答 R-3.1 ~ R-3.5，
> 清单见本文件 §H「R-3.1 ~ R-3.5 待答清单」。

`sync_protocol.md` §三 用 `(document_id, action, occurred_at)` 判定"已处理"，
但主机**没有任何表记录已执行的动作**（`data_model.md` 无 `document_actions` 之类）。
**处置**：若 v1 的动作全部可归约为 `status` 判定（如 `mark_delivered` 时若已是 `delivered` 即幂等），
需**在规范中显式写明这一归约**；否则需补一张动作表。

### R-4 `documents` 的 pull 游标字段未定义

> ✅ **已处置（2026-09-25，同步层落地时）**。`sync_protocol.md` §8.2 用
> `doc_since=1700000000000`（毫秒），但 §七 说「排序一律用 `seq_no`」，
> 而 `documents` **没有 `seq_no` 列**。
>
> **处置（不动表结构，只加一个索引）**：`documents` 用 **`(created_at, id)` 复合游标**
> （形如 `"1700000000000|0192…"`）。理由：`created_at` **不唯一** ——
> 用 `>` 会丢同一毫秒的其它行，用 `>=` 又会在「同一毫秒行数 > `limit`」时死循环；
> 复合游标是唯一既**不丢行**又能**保证推进**的方案，且与 §七「客户端按 `(created_at, id)`
> 排序」一致。为此新增索引 `idx_documents_created`（纯增量，无迁移）。
>
> **顺带发现并一并处置**：`document_lines` **根本没有时间列**，
> 所以它**不需要独立游标** —— 明细与主单在同一事务里写入、永不单独存在，
> 按「本页 `documents`」取即可。这也解释了 §8.2 为什么只给了 `doc_since`。
>
> 四张流水表的游标仍是开区间的 `seq_no > ?`（`seq_no` 唯一）。
> 两种游标语义不同，不可互换 —— 已写进 §8.2。

### R-5 正式单号回填与"业务数据不可变"的边界未写明

`Agents.md` 裁定「`doc_no` 主机生成，客户端离线用 `待同步-XXXXXX` 临时展示号」。
客户端需通过 `/api/sync/pull` 拿到正式号并**覆盖本地**的 `doc_no` ——
但客户端本地 `documents` 归入"业务数据只插入不更新"。
**处置**：明确「"业务数据不可变"是**主机侧**约束；客户端本地是估算镜像，允许被主机状态覆盖」。

### R-6 立即收款 / 立即退款不生成 `settlement`，与"已收额"口径冲突

- `rules.md` RULE-002 立即收款时只写 `MoneyLedger`、`status = settled`，**不写 `settlements`**；
  RULE-007 / RULE-008 的立即退款同理
- 但不变量 B4 定义「单据已收额 = `SUM(settlements.amount WHERE target_doc_id = X)`」
  ⇒ 立即收款的销售单"已收额"算出来是 **0**，而实际已全额收款；`documents.paid_amount` 缓存同样为 0

**处置（二选一）**：

| 方案 | 内容 |
|---|---|
| A | 立即收款时**同时**创建一条 `settlement`（指向该 sale 单）。注意此时 `receipt_doc_id` 无独立收/付款单，需放宽 `receipt.doc_type ∈ {receipt, payment}` 的约束 |
| **B（推荐）** | 明确 `paid_amount` 语义为"**经收/付款单核销**的金额"；立即收款单据靠 `status = settled` 单独表达。不变量 B4 相应限定为「存在收/付款单的场景」，UI 按 `doc_type` + `status` 分支 |

### R-7 `stock_ledger.unit_cost` 的负数舍入方向未定义

`data_model.md` §3.3 定义 `unit_cost = round_half_up(total_cost / quantity)`。
出库时 `quantity < 0` 且 `total_cost < 0`，**负数的 half-up 方向**（向零 / 远离零）未定义。
**处置**：补一句规定，或直接规定"`unit_cost` 仅在 UI 使用，按 `abs` 舍入后补符号"。

## C. 实施前置

| 项 | 状态 |
|---|---|
| 规范单一来源 | ✅ 已恢复（4 + 1 份 `docs/`） |
| **R-1** | ✅ **已裁定（2026-09-25）：方案 A** —— `allocations` 随 `createDocument` payload 传入，不动表结构。已写入 `sync_protocol.md` §8.1、`rules.md` RULE-004、`Agents.md` 裁定表 |
| **R-2** | ✅ **已随 R-1 连带处置** —— R-1 选 A 后收/付款单确实无商品明细，不变量 5 已排除 `receipt` / `payment`（`data_model.md` §五） |
| R-3 ~ R-5、R-7 | 待实现时处理，不阻断 `schema` |
| **R-6** | ⏳ **待裁定** —— 立即收款/退款的"已收额"口径（方案 A：补一条 settlement / 方案 B：`paid_amount` 仅指经收付款单核销额）。**不阻断 `schema`**，但阻断 RULE-002 / RULE-007 / RULE-008 实现 |

## D. 实现期新增待裁定项（2026-09-25，RULE-001 / RULE-009 落地时）

以下两项是**规范未覆盖、我在实现中自行选定处置**的边界。已按最保守方式实现，但**需要你确认**。

### R-8 盘盈时若无任何入库历史，「当前加权均价」无定义

`docs/data_model.md` §3.3 规定盘盈的 `total_cost` 用**当前加权均价**。
但账面数量 ≤ 0 且**从未入库过**时，加权均价是 `0/0` —— 规范没有定义。

**我的处置**：`total_cost = 0`（`cost_policy.dart` 的 `surplusCost`，无历史时走
`lastInboundUnitCost ?? 0`）。

**影响**：盘盈成本记 0 会**低估成本 → 毛利虚高**。
**可选替代**：回退到 `products.cost_price`（参考进价）作为估值。

### R-9 出库数量超过账面数量时，比率公式会把库存总成本推成负数

`CostPolicy.outboundCost` 在账面数量 > 0 时用
`round_half_up(库存总成本 × 出库数量 / 库存数量)`。
当出库量 > 账面量（超卖，`docs/threat_model.md` §3.4 明确**允许负库存**）时，
该公式会算出「超过现有成本」的金额，使 `SUM(total_cost)` 转为负值。

**实际效果是自洽的**：例 300 分 / 3 件，出库 5 件 → 出库成本 -500，
余值 -200、余量 -2，均价仍为 100。
**但需确认**：这是否是期望行为，还是应该只按账面量计成本、超出部分另按最近入库价？

### R-10（方案 C 引入）`delivery.status` 与通用 `status` 判定规则冲突

`docs/data_model.md` §3.1 的通用规则写的是
`status = paid_amount >= total_amount ? settled : confirmed`，
并声称适用于 `{purchase, sale, delivery, sale_return, purchase_return}`。
但送货的 `status` 由状态机驱动（`in_transit → delivered → settled`，见 `rules.md` RULE-003），
创建时必须是 `in_transit` —— **通用公式会把它立刻改成 `confirmed`**。

**当前处置（已实现）**：`data_model.md` §3.1 与 `rules.md` RULE-003 已标注 `delivery`
**不适用**该公式，实现上：

- 创建时主机**强制** `status = in_transit`
- `paid_amount` 照常按 `SUM(settlements.amount)` 刷新（不变量 B4 无例外），但**不驱动** `status`
- `in_transit → delivered` 需要 `documentAction: mark_delivered`，属 R-3（幂等判定），随 `SyncServer` 落地

**待你确认**：上述三条是否即期望语义。若认为「送货单收满款即算 `settled`」，需改规则。

### R-11（方案 C 引入）退货成本「用原单成本比例分摊」缺少可执行的定位手段

> ✅ **已裁定（2026-09-25）：方案 A —— 原单比例精确回退**。裁定书见 `docs/reply.md`。
> 已落地到 `data_model.md` §3.3「退货的成本分摊」、`rules.md` RULE-007 / RULE-008 与
> 独立小节「退货成本分摊」、`testing.md` §F。

`docs/rules.md` RULE-007 / RULE-008 规定退货的 `stock_ledger.total_cost`
「用**原销售单的出库成本**（按数量比例分摊）」，但：

- `stock_ledger` 只有 `product_id` + `document_id`，**没有 `document_line_id`**
- 因此无法把「某条出库流水」对应回「原单的哪条明细」

**裁定采用的算法**：按 `(document_id, product_id)` 聚合原单的流水，得到该商品的数量与
总成本，再用「**累计退货量**」比例分摊，并以「累计分摊 − 已分摊」消除多次退货的舍入余数。
**不加 `document_line_id`**（不动结构）。

**已知代价**：原单同一商品有多条明细时**合并为一次分摊**，明细粒度丢失。
成本总额仍精确（可重放），只是「退的是哪一条明细」不可考。

### R-12（方案 C 引入）「有欠款就必须有 `party_id`」是方案 C 的隐含硬约束

方案 C 下主单要写 `PartyLedger = ±total_amount`；若 `party_id` 为空该条目被跳过，
**欠款会凭空消失**。因此实现中加了硬校验：

> `SUM(immediate_payments) < total_amount`（即存在未结清金额）时，**必须**有 `party_id`；
> 否则 `rejected`。

**推论**：**零售散客（无往来方）只能"全额立即收款"**。若确实需要给散客记赊账，
必须先建一个"散客"伪往来方。

**已实现并自检覆盖**（`tool/selfcheck_payments.dart`）。若你希望放宽（例如散客赊账走别的科目），
需要修改规则。

## E. 实施前置状态（更新）

| 项 | 状态 |
|---|---|
| R-1 | ✅ 已裁定（方案 A）并落地 |
| R-2 | ✅ 随 R-1 连带处置 |
| R-6 | ✅ **已裁定（方案 C）并落地** —— `immediate_payments` + 自动生成收付款单机制已实现 |
| **R-11** | ✅ **已裁定（方案 A）并落地** —— 退货成本按原单比例**精确回退**（`data_model.md` §3.3 + `rules.md` 共用小节） |
| R-8 / R-9 | ⏳ 待确认；**不阻断**（当前处置可用） |
| **R-10** | ⏳ 待确认；已按「状态机驱动、`paid_amount` 不驱动 `status`」实现，**不阻断** |
| **R-12** | ⏳ 待确认；已按「有欠款必须有 `party_id`」实现，**不阻断** |
| **R-3** | ✅ **已裁定（2026-09-25）：推迟到同步层** —— 「动作」抽象未定型，动作部分暂缓；v1 用主机本地 `RuleEngine.markDelivered` 替代（裁定书 `docs/reply.md`） |
| **R-4** | ✅ **已处置（2026-09-25，同步层落地时）** —— `documents` 用 `(created_at, id)` 复合游标；明细无独立游标，随主单同页 |
| R-5 | 待实现时处理（客户端本地镜像的可覆盖性，不反向决定主机表结构） |
| R-7 | ✅ 已随实现确定：负数舍入**半数远离零**（`Money.divideRoundHalfUp`） |

## F. 方案 C 落地记录（2026-09-25）

已实现并通过自检（`tool/selfcheck_payments.dart`，67 项）：

- **统一资金流**：`RuleEngine` 的 `dispatch` 新增 `immediatePayments` 与 `allocations`
  两个互斥入参；前者触发**主机自动生成** `receipt` / `payment` 单
- **自动收付款单**：一张主单可生成多张（混合支付）；每张写 `MoneyLedger` + `PartyLedger` + `Settlement`，
  并继承主单的 `occurredAt` / `timeEstimated`；`ref_doc_id` 指向来源主单
- **`status` 派生**：`_refreshPaidAmount` 按 `SUM(settlements.amount WHERE target_doc_id)` 刷新
  `paid_amount` 与 `status`；主单**不再**直接写 `money_ledger`、**不再**直接设 `settled`
- **RULE-004 / 005**：手动核销走 `allocations`，含五条核销约束校验
- **新增防御性校验**：`document_lines.document_id` 必须等于单据 `id`；
  收付款单必须有 `party_id` + `account_id`；立即收付款总额 ≤ 单据总额
- **仍未实现**：RULE-003 送货、RULE-007 / RULE-008 退货（当前 `rejected`）

## G. R-11 落地记录（2026-09-25）

**裁定**：方案 A —— 原单比例精确回退（裁定书 `docs/reply.md`）。

**文档**：

- `data_model.md` §3.3：新增「退货的成本分摊」小节 + `total_cost` 取值规则补两行 + 新增「符号约定」表
- `rules.md`：RULE-007 / RULE-008 的输出精确化；新增共用小节「退货成本分摊」
- `rules.md` RULE-003：补 v1 首版对 R-10 的保守处置（创建即 `in_transit`）
- `testing.md`：§E 补充拒绝场景，§F 扩为「盘点与退货成本」

**代码**：

- `StockLedgerDao.documentProductFlow` / `StockLedgerDao.returnedFlow`：两组聚合查询（带符号原始值）
- `CostPolicy.returnCost`：累计分摊 − 已分摊，含 `return_exceeds_original` 校验
- `RuleEngine._return`：RULE-007 / RULE-008 共用实现（原单类型校验、符号、往来方向、自动退款/收退款）
- `RuleEngine._delivery`：RULE-003 创建路径（强制 `in_transit`）
- `RuleEngine._refreshPaidAmount`：新增 `delivery` 分支（只刷 `paid_amount`，不推 `status`）

**一处对裁定书公式的符号修正**（需你过目）：

裁定书 §3.1 写的是 `已退数量 = SUM(-sl.quantity)`，且未区分原单类型。
但 `quantity` 的符号随**被退的原单类型**而变：原单是 `sale` 时其出库流水 `quantity` 为**负**、
`total_cost` 也为负；原单是 `purchase` 时两者均为正。
若按字面实现，`sale_return` 会得到**负的**「已退数量」，`purchase_return` 会得到**正的** `total_cost`（应为负）。

实现按**裁定书 §3.4 的符号表**（那是自洽的）落地：分子分母一律取绝对值，
最后由退货类型决定符号。**语义与 §3.2 的余数归属示例完全一致**（该示例已验算通过）。
`data_model.md` §3.3 的公式已按此写清。

## H. R-3 裁定落地记录（2026-09-25）

**裁定**：「动作」抽象未定型 → **推迟到同步层**，v1 用主机本地改状态替代（裁定书 `docs/reply.md`）。

**文档**：

- `Agents.md` §五 重写：新增**「冻结的标准」**（是否反向决定表结构/字段）+ R-3 条目；
  §四 裁定表补「退货成本」「送货签收」「拒收」三行
- `rules.md` RULE-003：状态流转改为代码块 + v1 实现表 + `markDelivered` 幂等口径；
  RULE-007 前置放宽为 `sale` **或 `delivery`**；共用小节补第 8 条测试要点
- `data_model.md` §3.1 `delivery` 例外写具体；§3.3 补「原单类型」约束；§4.1 补 v1 不落地声明
- `sync_protocol.md` §三 + §十一：`documentAction` → `rejected` + `action_not_implemented`，幂等测试暂缓
- `testing.md` §C 补签收断言、§G 标注暂缓

**代码**：

- `RuleEngine.markDelivered`：**主机本地**签收入口，幂等**基于状态**
  （`in_transit` → `delivered`；已收满款 → 同事务内到 `settled`；重复 → `alreadyExists`；
  `cancelled` / 非 `delivery` / 不存在 → `rejected`）
- `_refreshPaidAmount` 的 `delivery` 分支改为**完整状态机**：
  `in_transit` 不动 → `delivered` 由 `paid_amount` 决定 `delivered`/`settled` →
  `settled`/`cancelled` 不回退
- `RuleEngine.returnOriginalTypes` 由 `Map<DocType, DocType>` 改为 `Map<DocType, Set<DocType>>`

**一处我主动修的规范内部不一致**（需你过目）：

`rules.md` RULE-003 写着「客户拒收 → 走 RULE-007 销售退货」，
但 RULE-007 的前置写的是「`ref_doc_id` 必须指向**原销售单**」——
两条合起来看，拒收**无路可走**（原单是 `delivery`，不是 `sale`）。

已把 `sale_return` 的合法原单放宽为 **`sale` 或 `delivery`**。
依据：两者在成本口径上同构 —— `stock_ledger` 都是「货已离店」的负数流水
（`quantity < 0`、`total_cost < 0`），所以 §3.3 的比例回退公式**无需分支**即可对两者成立。
已实测：送货 10 件（出库成本 1000）→ 拒收 4 件 → 回退 `1000 × 4 / 10 = 400`。

**门禁**：`selfcheck_delivery` 30 → **70** 项、`selfcheck_returns` 80 → **89** 项。

**同时修掉的守卫缺陷**：`tool/typecheck.dart` 此前**只 import `test/`，不 import `tool/`**，
因此自检脚本自身的编译错误（本轮真实发生一次：`createParty(name:)` 参数不存在）
**不会被任何门禁发现**（`dart test` 也只跑 `test/`）。已把 5 个自检脚本全部纳入
`typecheck.dart`，入口数 7 → 12。

### R-3.1 ~ R-3.5 待答清单（2026-09-26 迁入）

> ⚠️ 这份清单**原先只写在 `docs/reply.md`**，而 `reply.md` 是**逐轮改写的裁定书**
> （每轮被新裁定覆盖）。它被 R-13 覆盖后，`Agents.md` / `sync_protocol.md` /
> `rules.md` 里三处「见 `docs/reply.md`」的引用**全部悬空**。
> 现从 git 历史（`bdf71eb:docs/reply.md`）中取回，**迁到本台账** —— 这里只增不改。

写 `SyncServer._applyAction` 时必然会撞上这五问：

| # | 问题 | 影响面 |
|---|---|---|
| R-3.1 | 动作能否全部归约为 `status` 判定？ | 若可以，不建表；若不可以，需 `document_actions` 表 |
| R-3.2 | 同一 `document_id` 上的多个动作是否有序？ | 决定是否需要 `action_seq` |
| R-3.3 | 动作的 `occurred_at` 由客户端提供，冲突时按哪个时间判？ | 与 §七 的 `seq_no` 排序一致性 |
| R-3.4 | 动作失败（如已 `cancelled` 的单据收到 `mark_delivered`）如何返回？ | `rejected` 还是 `conflict`？语义不同 |
| R-3.5 | 一台 Android 离线签收，另一台同时取消该单，谁赢？ | 「主机赢」在动作层面如何具体化 |

**当前的候选答案**（未裁定）：`RuleEngine.markDelivered` 的幂等**基于状态**
（已是 `delivered` / `settled` → `alreadyExists`），这是 R-3.1 「可以归约」的一个证据，
但**不覆盖** R-3.2 ~ R-3.5（多动作有序性、时间判定、失败语义、并发胜负）。

## I. RULE-006 + SyncServer 落地记录（2026-09-25）

规则集到此齐了（RULE-001 ~ RULE-009 全部落地），并补上主机侧同步领域层。

**新增代码**：

- `dao/query_dao.dart` —— **RULE-006**：`stockByProduct` / `accountBalances` /
  `partyBalances` / `inTransitByProduct` / `availableInStore`（全是批量映射，
  避免列表页 N+1）
- `sync/sync_operation.dart` —— `SyncOperation` / `SyncOpType` / `SyncResponse` / `SyncStatus`
- `sync/whitelist.dart` —— `SyncWhitelist`（表 / 列 / 主机专属列）+ `SyncValueCheck`（值类型规整）
- `sync/sync_server.dart` —— `SyncServer`（五类操作 + `pull` + `SyncCursor` + `SyncPullResult`）

**架构决定（需你过目）**：

1. **`SyncServer` 不含 HTTP**。它接 `SyncOperation`、返 `SyncResponse`；
   HTTP 适配层（shelf）留给 Windows 应用侧，只做 JSON ↔ 对象搬运。
   这样同步逻辑是**纯 Dart**，在无网络、无 Flutter 的环境可测，
   而且 `shensuanzi_core` **不引入任何新依赖**。
2. **wire 值的形态 = `toRow()` 的形态**（列名 snake_case、布尔 `1/0`、时间毫秒、
   金额整数分）。于是模型已有的 `toRow()` / `fromRow()` **直接就是编解码器**，
   没有转换层也就没有转换漂移。
3. **`RowReader` 的报错改为带列名**（`base.dart`）。原来缺列只抛
   `Null check operator used on a null value`、类型不符只抛 `TypeError`，
   **都不说是哪一列** —— 而 `fromRow` 唯一的远程调用方就是 `SyncServer`，
   没有列名等于没有可诊断信息。

**R-4 处置**（见上文）：`documents` 用 `(created_at, id)` 复合游标；
`document_lines` 因**没有时间列**而**不需要独立游标**，随主单同页返回。
新增索引 `idx_documents_created`（22 → 23 个索引，纯增量、无需迁移）。

**`documentAction`**：v1 一律 `rejected` + `action_not_implemented`（R-3 未裁定）。

**门禁**：新增 `test/{query,sync_server}_test.dart` 与镜像的
`tool/selfcheck_{query,sync}.dart`；`typecheck.dart` 入口 12 → **16**
（9 个测试文件 + 7 个自检脚本）。

## J. 包拆分 + host 传输层落地记录（2026-09-25）

**裁定**：方案 A —— 新建纯 Dart 包 `shensuanzi_host`（裁定书 `docs/reply.md`）。

**目录重构**：`shensuanzi_core/` → `packages/shensuanzi_core/`；
新建 `packages/shensuanzi_host/`。根 Flutter 应用留在仓库根（`reply.md` 的
「注意」允许一个应用 + `Platform.isWindows` 分支）。

**按裁定书移动的文件**：

| 文件 | 从 | 到 | 依据 |
|---|---|---|---|
| `sync_server.dart`（`SyncServer`） | core | **host** | 「host 应包含 `SyncServer`」 |
| `sync_server_test.dart` / `selfcheck_sync.dart` | core | **host** | 跟随被测对象 |
| `SyncCursor` / `SyncPullResult` | core 的 `sync_server.dart` | core 的 **`sync_pull.dart`** | 它们是**游标 DTO**，客户端也要解析 ⇒ 留 core |
| `sqlite_local.dart` | core 的 `tool/` | core 的 **`lib/`** | host 的测试也要用它，而**跨包只能 `package:` 导入** |

**新增（core）**：`lib/src/sync/sync_pull.dart`（`SyncCursor` / `SyncCursorKeys` /
`SyncPullResult`）；`SyncPushRequest` / `SyncPushResponse` 两个信封 DTO
（`sync_operation.dart`）。
**新增（host）**：`auth.dart`（`HostToken` / `HostIdentity` / `HostIdentityStore`）、
`pairing.dart`（`PairingPayload` / `PairingQr`）、`http_server.dart`
（`HostHttpServer` / `PortRange`）、`lib/shensuanzi_host.dart`。

**几处实现决定**：

1. **令牌只持久化 `sha256`**。校验只需哈希 ⇒ **重启后照样能校验**，
   但**画不出二维码**（哈希不可逆），必须 `reset`。`HostIdentity.plaintextToken`
   为 `null` 就是「重启后」的状态，`canShowQr` 据此判断。
   —— 我最初写成了「重启后编一个假明文」，那是错的，已改。
2. **校验用常量时间比较**（异或累积）。逐字节提前返回可用响应时间**逐字节猜出**令牌。
3. **令牌存文件（`<数据目录>/host.json`）而不是建表** ——
   `data_model.md` 里没有配对应的表，令牌是**主机设施**不是业务数据。**不动 schema。**
4. **不做「先探测端口再绑定」**：那有竞态。逐个真正 `serve`，失败就试下一个。
5. **`/api/health` 不鉴权**：客户端**扫码之前**就要能判断「这个 IP:端口是不是主机」。
   只返回 4 个键，不含业务数据 —— 并用断言钉住「不泄露」。
6. **持久化 JSON 里不含明文令牌** —— 这条被断言，不只是注释里的一句话。

**新发现一个缺口（R-13）**：

`/api/sync/pull` **只返回 6 个业务实体，不含主数据**（这是 §8.2 的原文），
而 §8.3 的 GET 接口只有 `?q=&active=`、**没有 `since`**。两端合起来：

> **一台客户端改了商品价格，另一台客户端无法通过 `pull` 得知。**

这不是实现 bug，是**规范的缺口**。修法两选（并入 `pull` / 给 §8.3 加 `?since=`），
代价已写进 `sync_protocol.md` §8.3。**待裁定。**

**我踩到的两个自己的错**（都由自检抓到，不是靠人眼）：

1. `HostIdentityStore.inMemory()` 的内存槽初值写成了**空 map**而非 `null`，
   于是 `load()` 把「还没存过」误判成「已存过一条记录」→ 空指针。
   已改，并在注释里写清「初值必须是 `null`」。
2. 我在测试与自检里都断言了 `pull` 返回 `products` —— **错的**（§8.2 不含主数据）。
   两处一起改；顺带把「pull 不含主数据」变成**正向断言**钉住这个契约。

**门禁**：core 8 测试 + 6 自检（371 项）；host 4 测试 + 2 自检（189 项）。
两包各有独立 `typecheck.dart`（14 + 6 个入口）。




## K. host 传输层首轮测试失败修复 + 规范收紧（2026-09-25）

**现象**：`packages/shensuanzi_host` 首轮 `dart test` = `+77 -1`。
唯一失败是 `http_server_test.dart` 的「推送后能拉到业务实体与游标」——
期望两条回执 `applied`，实际第二条 `rejected`。

**根因**：**夹具手写 wire JSON，漏了明细的 `id`**。

`document_lines.id` 由**客户端**生成、主机**原样落库不重建**
（`DocumentDao.insertLine` 直接用 `line.toRow()`），
所以 `DocumentLine.fromRow` 把它当必填 —— 漏了就在解析阶段抛错，
被 `_createDocument` 的 catch 兜成一个笼统的 `rejected`。

**这不是实现 bug，是测试夹具违反 wire 约定**（「值 = `toRow()` 的形态」，`sync_protocol.md` §8.2 前）。

**修了什么**：

1. **夹具改为由模型生成**：主单 `Document.toRow()` 再经 `SyncWhitelist.isAllowedColumn`
   过滤主机专属列，明细 `DocumentLine.toRow()`。夹具从此**不可能**写出非法列 / 漏列。
2. **断言 `status` 时把 `reason` 带进 `reason:`** —— 这次失败的输出里只有
   `'applied'` vs `'rejected'`，没有原因，等于白跑一轮。
3. **补回归守卫**：新增用例「明细漏 id → `rejected` 且原因点到列名」，
   并在 `selfcheck_host.dart` 里镜像同一条（断言错误信息含 `缺少必填列 \`id\``，
   以及被拒单据不落库）。
4. **收紧规范**：`sync_protocol.md` §8.1 补明
   「`document` 与 `lines` 的元素都是完整 wire 行；`document_lines.id` 由客户端生成、
   主机原样落库」，并说明为什么**不能**由主机重新生成
   （本地镜像已用该 id 建行，重生成会让 `pull` 回来的明细与本地对不上）。
5. **改诊断信息**：`_createDocument` 的 catch 文案原为
   「单据字段缺失或类型不符（必填：id / doc_type / status / occurred_at）」——
   它只提主单字段，明细出错时会误导。改为同时点名 `lines` 并指向 §8.1。

**这是第三次同源漂移**（前两次：只改一边的镜像断言、只搬断言没搬 setup）。
已把「夹具别手写 wire JSON」「断言 status 要带 reason」两条写进 `docs/testing.md` 的镜像纪律块。

**门禁**：core 8 测试 + 6 自检（371 项）；host 4 测试 + 2 自检（**209** 项，自检 189 → 209）。

## L. R-13 方案 A 落地核验 + 文档补齐（2026-09-26）

**裁定**：R-13 选**方案 A** —— 主数据并入 `pull`，游标 `(updated_at, id)`。
完整论述见 `docs/reply.md`（逐轮覆盖）。

**核验时的仓库状态**：代码与测试**已在**（`3d354af`），但**文档全没跟上**：

| 位置 | 核验前 | 已补 |
|---|---|---|
| `sync_protocol.md` §8.2 | 仍写 6 个实体、4 个游标、`doc_since` 单时间戳 | 9 个实体、8 个游标、主数据游标与返回语义表 |
| `sync_protocol.md` §8.3 | 仍挂着「已知缺口：主数据的增量同步没有游标……待裁定」 | 改为「⛔ 本节**不承担同步职责**」+ 三行职责表 |
| `sync_protocol.md` §十一 | 仍写「恰好 6 个业务实体」 | 9 个实体 + 6 条主数据同步测试项 |
| `data_model.md` §2.1/§2.2/§2.3 | 只有 `idx_products_barcode` / `idx_parties_phone`；`accounts` 无索引行 | 各补 `(updated_at, id)` 复合索引 + 为什么必须带 `id` |
| `data_model.md` §五 | 无 B7 | 新增 **B7**：主数据 `updated_at` 每次写操作后刷新（含软删） |
| `testing.md` §B | 无 B7 | 补 B7 |
| `testing.md` §G2 | 「恰好 6 个业务实体」「不含主数据」「待裁定」 | 9 个实体 + 主数据游标语义 + 跨设备可见的测试要点 |
| `Agents.md` §五 | R-13 标「待裁定」 | 移入「已裁定并落地」；§四 补「同步游标」「pull 的实体面」两行 |
| `README.md` | 「主数据 REST + 增量同步｜未开始（缺口）」；索引数 23 | 拆成「主数据增量同步 ✅」+「§8.3 便利接口 未开始（有意）」；索引数改 26 |

**发现并修掉一个真 bug（`_linesOfPage` 越过页边界）**：

`documents` 的分页有 `LIMIT`，而明细查询**没有** —— 谓词只写了游标条件。
于是 `limit=1` + 3 张单时，`document_lines` 返回 **3 条**（后面所有主单的明细）。
页数越多越糟（第 1 页就返回全量明细），客户端还会先收到「主单还没到」的孤儿明细行。

- **不是本轮引入**：父提交 `579e48b` 里 `_linesOfPage(from, limit)` 的 `limit`
  参数**从未被使用**，注释却写着「谓词与主单页边界完全一致」。典型的「注释承诺 > 实现」。
- **修法不是把谓词再写一遍**（两次查询的页边界一旦写法不同就会错位，这次就是），
  而是**明细直接由本页 `documents` 的实际结果派生**：
  `WHERE document_id IN (本页主单 id…)`，分批绑定参数（`IN` 占位符受
  `SQLITE_MAX_VARIABLE_NUMBER` 限制，而 `limit` 客户端可控）。
  **从结构上排除**「两次查询页边界不一致」这一类 bug。
- 顺带明确两个**不同**的语义：**不截断**（本页明细全给）与**不越界**（页边界一致）。

**另一处治理问题：悬空引用**。

`R-3.1 ~ R-3.5` 五问清单**原先只写在 `docs/reply.md`**，而那是**逐轮覆盖的裁定书**。
被 R-13 覆盖后，`Agents.md` / `sync_protocol.md` / `rules.md` / `reply_review.md` 里
**四处**「见 `docs/reply.md`」全部指向不存在的内容。

已从 git 历史（`bdf71eb:docs/reply.md`）取回清单，**迁进本文件 §H**，
四处引用改指本文件；并在 `Agents.md` §六 写入文档治理规则：

> `reply.md` 是**逐轮覆盖**的裁定书 —— 规范条文不要引用它；
> 需要长期有效的东西（清单、候选答案）**必须迁进 `reply_review.md`**；
> 已被覆盖的内容从 git 历史取（`git show <commit>:docs/reply.md`）。

**门禁**：core 8 测试 + 6 自检（374 项，84 项含 3 个新索引断言）；
host 4 测试 + 2 自检（258 项，142 + 116）。两包 typecheck 各 14 / 6 入口。
**索引三处一致**：`schema.dart` 实际 26 个 = `schema_test` 期望 26 个 = `selfcheck.dart` 期望 26 个（已 diff 核对）。

## M. 新待裁定项 R-14：客户端拉取游标存哪（2026-09-26，动工 `SyncClient` 前发现）

**问题**：`sync_protocol.md` §8.2 明确写着「客户端要 `sync_version` 做下次
`base_version`、要 `updated_at` **存游标**」，但 `data_model.md` §四（同步数据，仅 Android 端）
**只有两张表**：`sync_queue` 与 `clock_offset` —— **8 个拉取游标没有存储位置**。

按 §五 的**冻结标准**（是否反向决定表结构或字段）：**方案 A 会加表 ⇒ 属「是」**
⇒ **动工前必须裁定**。因此 R-14 **阻断 `SyncClient`**。

### 方案 A：新表 `sync_cursor`

```sql
CREATE TABLE sync_cursor (
  entity      TEXT PRIMARY KEY,   -- 8 个键之一（如 'products_since'）
  cursor      TEXT NOT NULL,      -- 主机返回的 next_cursors 原值
  updated_at  INTEGER NOT NULL
);
```

- **好处**：游标就是**主机返回的原值**，客户端不推断任何东西；
  与「镜像是否被修剪 / 本地是否有未确认单据」**完全解耦**
- **代价**：schema 11 → **12 表**（需连带更新 `data_model.md` §四、
  `schema_test` 的表数断言、新增 `SyncCursorDao`）
- 需要一并定义：初始值语义（流水用 `'0'`、复合游标用 `''`；
  主机侧 `SyncCursorKeys.all` 已是**单一出处**，可直接对齐）

### 方案 B：从本地镜像的「水位」推算

流水取 `MAX(seq_no)`、`documents` / 主数据取 `MAX(时间列, id)`。**零新表**。

⚠️ **但有一个静默丢数据的陷阱**（这是我不推荐它的原因）：

1. `created_at` **按 §七是主机分配的**（「主机收到后……用主机时钟分配 `created_at` 与 `seq_no`」），
   而客户端本地新建的单据在推送前**只能填客户端时钟的估算值**（列是 NOT NULL）
2. 若客户端时钟**快于**主机，本地那条单据的 `created_at` 就**大于**主机将来会分配的值
3. 于是 `MAX(created_at, id)` 给出的游标**跑到了主机尚未到达的时间点** ——
   下次 `pull` 会**跳过**其它设备在该时间点之前创建的全部单据与主数据
4. 而且这个错误**不会报错、不会重试、不会自愈**：客户端只是永远少一部分数据

要绕开就得「排除未确认的本地单据」（例如按 `doc_no` 是否仍是 `pendingDocNoPrefix` 判别），
但那是在**推断**「主机已确认」这件事 —— 引入的隐含前提比方案 A 多得多。

### 方案 C（不推荐）：把 `clock_offset` 泛化成单行 `sync_state(key, value)`

会破坏 `clock_offset` 的强类型（`offset_ms` / `updated_at`），
把一个有语义的表降级成 K-V 袋。**不采用。**

### 我的建议

**方案 A**。理由：游标是**主机的输出**，客户端只需原样保存 ——
存下来是最小、最直白、也最不可能错的做法；
方案 B 用「推算」替代「保存」，换取零新表，代价是一个**静默丢数据**的失效模式。

切换成本不对称：**A 之后想省表**只需删表（游标随时能从水位重算一次）；
**B 之后想修复丢数据**却需要先补表、再让所有已丢失的数据重新拉回来 —— 未必可恢复。

## N. R-14 方案 A 落地记录（2026-09-26）

**裁定**：方案 A —— 新表 `sync_cursor` 存拉取游标；客户端**不跑规则**，
只做数量累加。完整论述见 `docs/reply.md`（逐轮覆盖）。

### 落地内容

| 层 | 内容 |
|---|---|
| `schema.dart` | 新增 `sync_cursor(entity PK, cursor, updated_at)`（表数 11 → **12**）；把 `sync_queue` / `clock_offset` / `sync_cursor` 归入 `Schema.clientTables`，与 `serverTables` 分开（R-14 §五 建议的 P2-3，先做**常量分组**） |
| `data_model.md` | §4.1 补 `status` 生命周期（`sent` 不删、`failed` 退自动重试、按 `entity_id` 逐条确认）；§4.3 换成 `sync_cursor` 正式定义（含「为什么不解析」「为什么不能从镜像推算」）；新增 §4.4 客户端镜像两条硬约束；§五 加 **B8**；§七 加「客户端不跑业务规则」 |
| `sync_protocol.md` | §一 架构图补 `pending_delta` / `in_flight_delta`；§六 重写重试策略（push 成功 → `sent`、pull 确认 → 删除）并区分「协议层失败 vs 业务拒绝」；§8.2 补客户端落库四条约束；§十一 补客户端测试项 |
| `testing.md` | §B 补 B8；§零 补两个自检命令与镜像表两行；新增 **§G3 客户端同步引擎**；§J 补「已自动化的一层」（含陷阱 1/2 的守卫说明） |
| `Agents.md` | §四 新增 5 行裁定（客户端游标 / 客户端不跑规则 / 未同步影响 / 客户端镜像 / 客户端传输）；§五 把 R-14 移入「已裁定并落地」 |
| `README.md` | 进度表：表数 12、`SyncClient` ✅、未同步影响 ✅、端到端 ✅ |

### 代码

- **`sync_dao.dart`**：`SyncCursorDao`（`getAll` / `upsertAll` / `clear`）、
  `SyncQueueDao`（`enqueue` / `due` / `markSent` / `markFailed` / `requeue` /
  `clearConfirmed`）、`ClockOffsetDao`
- **`sync_queue_entry.dart`**：`SyncQueueEntry` + `SyncQueueStatus`
  （**不继承** `ImmutableEntity` —— 队列条目是传输状态，不是业务记录）
- **`transport.dart`**：`TransportRequest` / `TransportResponse` / `Transport`
  抽象类 + `SyncHttpException`（区分协议层失败与业务 `rejected`）
- **`sync_client.dart`**：`push` / `pull` / `deltaOf` / `unsyncedDelta` /
  `stockViewOf` / `recordClockOffset`；`SyncPullReport` / `SyncPushReport` / `StockView`
- **`sync_pull.dart`**：`SyncPullResult.fromJson`（只收 9 个实体 ⇒ 落库表名天然不越界）

### 过程中自检抓出的 5 个真问题（都不是靠人眼）

| # | 问题 | 处置 |
|---|---|---|
| 1 | **落库顺序撞外键**：§8.2 字段顺序把主数据列在**最后**，而 `document_lines` / `stock_ledger` 都引用 `products` | 新增 `SyncClient.applyOrder`（依赖优先），并明确「不照 §8.2 字段顺序」 |
| 2 | **镜像的 FK 契约没定**：某行引用的主数据落在页外时，开着 FK 会让 pull **永久失败**（毒丸） | `SyncClient` 构造时**显式拒绝**开着外键的镜像（`PRAGMA foreign_keys` 在事务内是 no-op，只能打开时定） |
| 3 | **`SyncPushReport.rejected` 从未被累加**（我把计数记进了 `retried`） | 修正：`rejected` 是「为什么失败」的归类，`retried` 是「接下来怎么办」的处置 |
| 4 | **`due()` 把死信也当可自动重试** —— 与「`> 10` → UI 提示人工处理」矛盾 | `due()` 只取 `pending`；新增 `requeue` 供人工处理后放回 |
| 5 | **传输实现必须显式 utf8**：`HttpClientRequest.write` 默认编码不是 UTF-8，中文 payload 直接抛 `Invalid argument: Contains invalid characters` | 端到端测试改为 `add(utf8.encode(body))`；把这条写进 `transport.dart` 的实现提示 |

**其中 #1 / #2 会直接导致「同步永远不成功」，#3 / #4 是静默行为错误。**

### 门禁

- core：`typecheck` 16 入口（9 测试 + 7 自检）；自检 **462 项**
  （含新增 `selfcheck_sync_client` **86 项**）
- host：`typecheck` 8 入口（5 测试 + 3 自检）；自检 **288 项**
  （含新增 `selfcheck_client_server` **30 项**）
- **陷阱 1 的回归守卫已通过**：`push 不推进拉取游标` + `A 再拉必须拿到 B 的 5 张`
  —— 这条会明确失败在「从镜像水位推算游标」的实现上

## O. Windows UI 阶段首批：数据目录策略（2026-09-26）

**裁定**：数据目录采用**「用户可选」** —— 但按**「默认 + 覆盖 + 校验」**实现。
完整论述见 `docs/reply.md`（逐轮覆盖）。UI 原则同批落地。

### 为什么不能只是「让用户选」

「用户自己选」如果做得太裸，会引入另一批问题：

| 天真实现 | 现实后果 |
|---|---|
| 首次启动弹目录选择框 | 中老年用户会懵 ——「选哪里？C 盘还是 D 盘？我不知道啊」 |
| 路径只存在内存 | 重启后忘了路径 → 找不到数据 → 以为数据丢了 |
| 允许任意路径 | 有人选到 U 盘 / OneDrive 同步目录，拔盘后打不开，或 SQLite 被同步冲突损坏 |
| 允许选 `C:/Program Files` | 无写权限，创建失败，报错看不懂 |

### 落地内容

| 层 | 内容 |
|---|---|
| 新包 `shensuanzi_app` | **纯 Dart、可测**。`environment.dart`（本机事实注入）/ `data_directory.dart`（默认位置、校验三档、备份路径、迁移校验）/ `app_config.dart`（配置 + 缩放档位）/ `data_marker.dart`（标记文件 + 目录内容判定）/ `bootstrap.dart`（启动恢复 + 打开数据库） |
| 默认位置 | **优先非系统盘**（`D:/神算子数据`），否则 `C:/Users/<你>/神算子数据`。理由：重装系统不丢数据、绕开 `%LOCALAPPDATA%` 清理风险、备份到 U 盘更顺手 |
| 校验三档 | `reject`（系统目录 / 系统盘根 / 相对路径 / 非空且无标记）/ `warn`（`%LOCALAPPDATA%` 等会被清理的位置、网盘同步目录、可移动盘、网络盘、空间不足、非系统盘根）/ `ok`。**警告不拦人** |
| 配置 | `%APPDATA%\神算子\config.json`。**配置不是数据** —— 被清理软件删掉只丢偏好。**读永不抛**（外部输入，坏字段不该让软件打不开） |
| 标记文件 | 数据目录里放 `.shensuanzi-data`（app / schema_version / created_at）。**配置被清后重选原目录即可复用**，不需要用户记住路径 |
| 备份位置 | 数据目录的**兄弟目录**（`D:/神算子数据` + `D:/神算子备份`）。不放子目录（避免「备份里包含备份」的递归）、**不放 `文档`**（OneDrive 会同步它） |
| 门禁 | `tool/selfcheck_app.dart`（**75 项**）+ `tool/typecheck.dart`（4 入口）；`test/` 三个文件（`data_directory_test` / `app_config_test` / `bootstrap_test`） |

### 文档

- **新增 `docs/data_directory.md`** —— 默认值、校验规则、配置、标记、恢复、迁移、实现映射
- **新增 `docs/ui_principles.md`** —— 中老年用户画像的两条推论、视觉基调数字、缩放机制、数字输入、错误信息写法、5 步向导
- `threat_model.md` 新增 **§4.4 数据目录策略**；**修掉 §4.1 的过时备份路径**（原文写的 `文档/神算子备份/` 与本节裁定冲突，且 `文档` 会被 OneDrive 同步）
- `README.md` 新增「数据在哪」用户可见说明；目录结构 / 包边界 / 进度表同步
- `Agents.md` §四 新增 3 条裁定（数据目录 / 备份位置 / UI 基线）；§六 补两份文档；§七 标注进度

### 自检抓到的 2 个真 bug（都不是靠人眼）

| # | 问题 | 后果 |
|---|---|---|
| 1 | **盘根作容器时 `isNested` 静默失效** —— `_key` 只剥掉长度 > 3 的末尾分隔符，`C:/` 原样保留反斜杠，拼出的前缀成了 `C://`，任何子路径都匹配不上 | `inspectMigration('D:/', 'D:/数据')` **放行** —— 迁移时会把数据搬进自己的子目录，之后越搬越深 |
| 2 | **系统盘根被当成普通盘根放行** —— `_key` 转小写，比较串却用**大写**的 `systemLetter`，`'c:/' == 'C:/'` **永远为 false** | `C:/` 返回 `warn` 而非 `reject`，与 `docs/reply.md` §一的校验表不符（实测被自检当场抓住） |

两个都是**同类根因**：**大小写 / 分隔符的归一化在不同地方各写一遍**。
处置：`isNested` 改为基于「容器是否已带末尾分隔符」决定前缀；系统盘根的比较
**统一走 `_key` 归一化**。两条都已补回归断言，并写进 `docs/testing.md` §K。

### 关于本轮内核的 3 个失败

内核 `dart test` 报的 3 个失败（退避时刻、无回执文案、`stockViewOf` delta）
**全部是测试夹具与断言写错，不是实现问题**，且都是**镜像漂移的第 4 次**：
我的降级自检（`selfcheck_sync_client`）当时是绿的，正式测试是红的。
三处已在上一轮修正（固定时钟替代会推进的时钟、错误文案与实现对齐、
delta 夹具改用真实 `productId`），并在 `docs/testing.md` 补了纪律：
**搬场景时把夹具调用一起搬；断言状态时必须把 `reason` 带出来。**

## P. UI 阶段第 1 天：数据目录对话框（2026-09-26）

**裁定**：**先做核心闭环，但先抽一个「数据目录对话框」**；
向导其余 4 步第 10 天回补。完整论述见 `docs/reply.md`。

### 裁定的核心：向导 5 步里只有第 2 步是硬依赖

| 步骤 | 是不是硬依赖 | 能否后补 |
|---|---|---|
| 1. 欢迎 | 否 | 完全可后补 |
| 2. **数据位置** | **是** | **必须先有**（没有它，数据库不知道放哪，程序起不来） |
| 3. 商店信息 | 否 | 可后补 |
| 4. 账户设置 | 否 | 可后补（有默认值） |
| 5. 完成 | 否 | 完全可后补 |

所以第 1 天只做两件事：**数据目录对话框** + **空主界面**。

### 落地内容

| 层 | 内容 |
|---|---|
| **服务入口** | `DataDirectoryService` —— 四个**意图命名**的方法（`resolveDefault` / `validate` / `ensureInitialized` / `isShensuanziDir`），名字取自 `docs/reply.md` §四 的能力清单。**本类不含逻辑**，只「改名 + 转发」给 `DataDirectoryPolicy`（纯判断）与 `AppBootstrap`（会落盘） |
| **对话框状态机** | `DataDirectoryDialogModel`（纯 Dart，`dart test` 可跑）：`open` / `choosePath` / `confirm` → `created` \| `reused` \| `needsForeignConfirm` \| `blocked`；另有 `notice`（唯一一句话，含「怎么办」）与 `noticeKind`（给 widget 选颜色，不用文字串判断） |
| **对话框 widget** | 根 `lib/src/ui/data_directory_dialog.dart` —— **只做摆放**：显示路径 / 容量提示 / 提示条，接选择器，把 `location` pop 回去 |
| **系统选择器** | 根 `lib/src/folder_picker.dart` —— **全项目唯一调用 Flutter 插件的地方**（插件行为无法在本机验证，隔离成一个文件） |
| **启动流程** | 根 `lib/src/app.dart`：`existing()` → 可用就直接开库，否则弹对话框 → 开库 → 主界面。**开库失败也有专门界面**（含「换到本机磁盘上的文件夹」） |
| **空主界面** | 根 `lib/src/ui/home_page.dart`：说清「数据在哪 / 备份在哪 / 数据文件是否就绪」，并列出核心闭环五个入口（标「待实现」） |
| **依赖** | 根 `pubspec.yaml` 加 `sqlite3_flutter_libs`（SQLite 原生库，**必须在根 Flutter 应用**）+ `file_selector`（选择文件夹）+ 两个 path 包 |

### 设计要点（都写进了 `docs/data_directory.md` §九）

1. **`confirm()` 不抛异常** —— 失败也要有结论，UI 才知道该显示什么
2. **改路径作废上一次结果** —— 否则会拿旧的成功结果去开库，而那个目录已经不是用户选的了
3. **二次确认不是拒绝** —— 用户可能就是要放在这个文件夹里；默认拒绝只是防误选
4. **提示同时给图标 + 颜色 + 文字** —— 色觉异常的比例不低，不能只靠红绿区分
5. **`existing()` 每次重跑校验** —— 配置里「有路径」不等于「能用」

### 分层：判断在纯 Dart，Flutter 只做摆放

**这是本轮的架构决定**，理由是验证能力不对称：

| 层 | 位置 | 怎么验证 |
|---|---|---|
| 路径策略 / 校验 / 标记 / 恢复 / **对话框状态机** | `packages/shensuanzi_app` | **`dart test` + 自检**，全自动 |
| 对话框 widget / 启动流程 / 主界面 | 根 `lib/src/` | 只能 `flutter analyze` / `flutter test` |

把判断全挪到纯 Dart 之后，Flutter 那层只剩「摆放控件、调选择器、pop 结果」，
**出错面被压到最小**。

### ⚠️ 本机限制（必须说清）

根 Flutter 应用**我编译不了**：`package:flutter` 依赖 `dart:ui`，
在纯 Dart VM 里不存在，`dart run` 必然失败；`flutter *` 与 `dart analyze`
在本机也起不来（子进程缺陷）。所以 Flutter 那一层的验证只能靠：

- `dart format --output=none lib test` —— **语法**（解析但不解析导入），已通过 6/6 文件
- 用户跑 `flutter analyze` + `flutter test` + 真机启动一次

**意外收获**：新增依赖后，IDE 自动跑了 `pub get` —— 于是
`sqlite3 2.9.4` / `sqlite3_flutter_libs 0.5.42` / `file_selector 1.1.0` 的解析、
以及 `windows/generated_plugin_registrant.cc` 的插件注册，**都已确认可用**。

### 门禁

- app 包：`typecheck` 6 入口；`selfcheck_app` **101 项**（上一轮 75 → 本轮 +26）；
  `test/` 五个文件 **117 个用例**
- core 463 项 / host 288 项不变

**尚缺（不阻断）**：真实盘类型与剩余空间（纯 Dart 拿不到，对话框对 `null` 已处理）；
界面缩放接入 `textScaler`（第 11 天设置页）。

## Q. lint 债清零 + 左侧常驻导航（2026-09-26）

### 一、`flutter analyze` 揭出一批**从未被发现的** lint 债

用户在仓库根跑了第一次 `flutter analyze`，报 **37 项**。其中**只有 1 项**是本轮
引入的（`data_marker.dart` 的多余导入），其余全部来自此前几轮 —— 根因是：

> **`flutter analyze` 在仓库根会连带分析 path 依赖的全部包**
> （`shensuanzi_core` / `shensuanzi_host` / `shensuanzi_app`），
> 而本机 `dart analyze` 起不来（analysis_server 子进程缺陷）。
> 我们此前的门禁只有 `dart run tool/typecheck.dart` —— 它**编译**但**不 lint**。
> 于是 lint 债一路静默累积。

**这说明一件事**：`flutter analyze` 是本项目**唯一的全仓 lint 门禁**，
必须纳入常规回归（`docs/testing.md` §L）。

### 二、37 项的处置

| 类别 | 数量 | 处置 |
|---|---|---|
| `annotate_overrides`（9 个模型的 `final String id`） | 9 | 补 `@override` —— 它确实覆盖 `ImmutableEntity.id` |
| `unused_import` | 4 | 删除（含 3 处 `package:sqlite3/sqlite3.dart`） |
| `unnecessary_cast` | 6 | 4 处是 `is T &&` 之后的兑现提升（直接去 cast）；2 处是**字符串插值里连转四次 `as Map`**，改为**一次性 `Map<String, Object?>.from` 的辅助函数** |
| `use_null_aware_elements` | 5 | 改为 `'k': ?v`（Dart 3.9+ 的空值感知元素，语义等价于 `if (v != null) 'k': v`） |
| `unnecessary_nullable_for_final_variable_declarations` | 3 | `_require()` 返回非空 `Object` ⇒ 去掉 `Object?` |
| `unnecessary_brace_in_string_interps` / `unnecessary_string_interpolations` | 3 | 去掉多余花括号 / 直接传值 |
| `unused_field`（`HostHttpServer._clock`） | 1 | **删除字段**。时钟只交给 `_HostRoutes`（真正取时间的地方），这个字段从未被读过 —— 死状态 |
| `unused_local_variable`（`c4`） | 1 | 删除（重构后遗留） |
| `depend_on_referenced_packages`（host 直接用写 `sqlite3` 类型） | 3 | host 的 `pubspec.yaml` **显式声明 `sqlite3: ^2.4.0`**（与 core 对齐）；另外 2 处是未使用导入，直接删 |

**顺带清掉一处重复**：`DataDirectoryPolicy.markerFileName` 与
`DataMarker.fileName` 是**同一个字符串的两个出处**（必然漂移），已删前者 ——
**谁拥有这个文件，谁定义它的名字**。

### 三、左侧常驻导航（裁定落地）

按 `docs/reply.md`：**左侧常驻导航 + 分组 + 图标与文字 + 三重高亮 + 开单页沉浸模式**。

| 层 | 内容 |
|---|---|
| **结构**（纯 Dart，`dart test` 覆盖） | `navigation.dart`：`NavSection`（首页 / 高频动作 / 数据查询 / 系统）、`NavDestination`（id / label / iconKey / section / immersive）、`AppNavigation`（destinations / of / byId / initial / widthFor） |
| **图标映射** | `lib/src/ui/nav_icons.dart`：`iconKey` → `IconData`，查不到用兜底（**不崩** —— 导航在启动路径上） |
| **摆放** | `lib/src/ui/app_shell.dart`：220px 列 + 分隔线分组 + 三重高亮 + 面包屑；`overview_page.dart`（原 `home_page.dart` 改名）承载「数据在哪」 |

**把结构放进纯 Dart 的收益是具体的**：把几条界面**原则**变成了可执行断言 ——

- 「所有功能必须有常驻可见入口 + 文字标签」→ 断言每个入口 `label` 非空、入口数 ≥ 9
- 「分组清晰、不穿插」→ 断言 section 在列表里**分段连续**
- 「开单页是沉浸模式」→ 断言只有 `sale` / `purchase` 带 `immersive`
- 「点击区 ≥ 44」「导航 220 × 缩放」→ 断言常量

**一处对裁定书列表的增补**：「概览」不在原 9 项里，但新版安装没有任何数据，
直接落在沉浸式开单页是坏的落地体验，且「你的数据在哪」这个承诺需要常驻位置。
已作为**首页组**加入（列表第 1 项），**待你确认**。

### 四、门禁

- core 463 / host 288 / app **116**（+15 导航断言）= 合计 **867 项全绿**
- app `test/` **137 个用例**（+20 导航）
- Flutter 侧：`dart format --output=none` 语法通过 8/8 文件
- **待用户复跑**：`flutter analyze`（预期 **0 issues**）、`flutter test`（预期 5 个用例）

## R. 商品建档（核心闭环第一块，2026-09-26）

**裁定**：第一版 **6 个字段** —— 名称 / 单位 / 售价 / 进价 / 条码 / 安全库存。
`code` **由系统生成**；`category` / `remark` 延后；`is_active` 不是表单字段
（它是列表页的「停用」操作）。完整论述见 `docs/reply.md`。

### 一、裁定书纠正了我的一处误判（值得记下来）

我原本把 `code` 和 `barcode` **一起**列为「留后」，理由是「都是可选的标识」。
裁定书指出两者的**补录成本差异极大**：

| 字段 | 留后的代价 |
|---|---|
| `code` | **零** —— 它是系统生成的，用户永远不会想「给这个商品改个货号」 |
| `barcode` | **极高** —— 首次录入时用户手上正好有货、顺手就扫了；**补录时要对着一屋子货逐个找**。而第一次没录的用户大概率永远不补 ⇒ Android 端的扫码功能对他等于不存在 |

**字段的存在本身就是一种引导。** `cost_price` / `safety_stock` 同理：
隐藏了不会「省事」，只会让用户永远不知道有这回事（进价不填 → 毛利永远 0；
安全库存不填 → 低库存告警永远不触发）。

### 二、落地内容

| 层 | 内容 |
|---|---|
| **编码生成** | `ProductCodeGenerator`（`src/rules/`，与 `DocNoGenerator` 并列）：`P0001` 起、事务内强制 |
| **表单模型** | `ProductDraft` / `ProductField`（`src/master_data/`）：**保留用户输入的原文** + 纯函数校验；`ProductDraft.of(existing)` 回填编辑 |
| **建档服务** | `ProductService`：`create` / `update` / `setActive` / `list` / `byBarcode`；服务层**重新校验**（不假设调用方校验过），失败抛 `ProductDraftInvalid`（带字段级原因） |
| **金额输入** | `Money.tryParseYuan`：**不经过 `double`**（`1.005` 的二进制误差会让 `*100` 舍成 100），按小数点切分后用整数拼 |
| **列表排序** | `ProductDao.findAll` 改为 `ORDER BY created_at, id`（原为 `code`） |
| **DAO 补充** | `latestCode()` / `findByBarcode()` / `activate()` |
| **Flutter** | `products_page.dart`（搜索 + 新增 + 行操作）、`product_form_dialog.dart`（6 字段 + 字段级标红 + 扫码回车即保存） |

### 三、两个必须点出来的实现决定

1. **列表排序不能再用 `code`**。编码是定宽补零的，**定宽总会在某个位数上断掉** ——
   `P10000` 的字典序小于 `P9999`。取最大编码时必须
   `ORDER BY LENGTH(code) DESC, code DESC`（先长度后字典序 = 数值最大）。
   只按 `code DESC` 会取回 `P9999` ⇒ 生成器算出 `P10000` ⇒ **撞 UNIQUE**。
   **已补回归守卫**（`P9999→P10000`、`已有 P10000 → P10001`），第二条会明确失败在上面那种实现上。
2. **编辑时表单没有的列保持原值**（`category` / `remark` / `is_active`）——
   否则「改个名字」会把用户后来设的分类、备注、停用状态一起抹掉。

### 四、自检抓到的第三个同源漂移（已写进 `docs/testing.md` §零）

`selfcheck_products.dart` 里 `before` 已被成功 `update` 过一次，我却拿它**更新前**的
`syncVersion` 去比 ⇒ 「编辑校验不过 → 库里原值不变」**假失败**；`test/` 版是隔离用例，所以是对的。
根因还是那条：**自检是一个长脚本（对象跨段复用），测试是互相隔离的用例**。

### 五、门禁

- core：`typecheck` **18 入口**；自检 **501 项**（新增 `selfcheck_products` **38 项**）；
  `test/` **206 个用例**（新增 `product_service_test` **39 个**）
- Flutter 侧：`dart format --output=none` 语法通过 10/10 文件
- **待用户复跑**：`flutter analyze`（预期 0 issues）、`flutter test`（预期 6 个用例）、
  core `dart test`（预期 206）

---

## 附录：新待裁定项 R-15 —— 商品条码**重复**怎么办

`barcode` 有索引但**不唯一**。现在允许两条商品共用同一个条码，扫码开单取
**最早建档**的那条（`ProductDao.findByBarcode`）。

**为什么现在不定**：真实世界里确实存在「同一箱货拆开卖」「同一商品进了两批、条码一样」，
一刀切拒绝会挡住合法操作；但放任重复又会让扫码结果不确定。

**两选**：

| 方案 | 代价 |
|---|---|
| **A. 允许重复（现状）** | 扫码取最早建档的那条。风险：用户扫到一个「看起来不对」的商品，会以为扫码坏了 |
| **B. 建档时**若条码已被占用 → **警告但不拦**（提示「这个条码已经给『XX』用过了」） | 需要 `ProductService` 查一次占用；不改变数据约束 |

**我的建议**：**B**。与数据目录警告同一原则 —— **中老年用户被拦住会认为「软件坏了」**，
但让他知道「这个条码已经用过了」是有价值的。等 Android 端做扫码时再定也来得及
（v1 还没有扫码功能，但条码**已经在录入了**，所以这个决定越早越好）。
