# Reply.md（v0.2 / v0.3）审查报告

> 📦 **本文件是 `reply_review.md` 的归档部分。**
>
> 内容已被主文件的 §A「关闭确认」表完整吸收，仅作历史留存。**新裁定不写入本文件。**
>
> - **归档边界**（2026-09-28 裁定）：只归档 §0-§7（v0.2/v0.3 原始审查报告）；**§A 起全部留在主文件**。
> - **本文件收录的编号**：`P0-1` ~ `P0-9`、`P1-1` ~ `P1-10`、`P2-1` ~ `P2-7`，以及 §4 文档治理 / §5 工期 / §6 Day 1 范围 / §7 待裁定清单。
> - ⚠️ **源码注释里出现的裸编号**（`schema.dart` 的 `P2-3`、`database_test.dart` 的 `P0-1`、
>   `schema_test.dart` / `selfcheck.dart` 的 `P0-7` · `P1-9`）**指的就是本文件里的条目**；
>   §A 表另有逐条处置，因此这些引用不依赖本文件也能读懂。

---

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
