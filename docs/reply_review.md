# Reply.md（v0.2 / v0.3）审查报告

> 审查日期：2026-09-25
> 审查对象：`D:\库\Desktop\Reply.md`（3181 行，含 v0.2 数据模型答复 + v0.3 同步规范 + Dart 骨架）
> 审查方式：逐条对照规范文本与参考代码，并对可判定项做了静态推演（未运行，本机 Dart VM 创建子进程受限）
> 结论：**规范方向正确、信息密度高，采纳。但参考代码不能直接运行，且存在 9 项必须在实施前裁定的阻断问题。**

> ## 编号索引（先看这里，别滚屏找）
>
> | 编号 | 位置 | 状态 |
> |---|---|---|
> | R-1 `allocations` 承载 / R-2 B5 排除收付款单 / R-3 `documentAction` 幂等 / R-4 `documents` pull 游标 / R-5 正式单号回填边界 / R-6 立即收付与 `settlement` / R-7 负数舍入 | §B | R-1 · R-2 · R-6 · R-7 **已落地**；R-4 由 §L（R-13 方案 A）确定；**R-3.1 ~ R-3.5 五问仍待答**（清单在 §H 末）；R-5 随实现处置 |
> | R-8 / R-9 / R-10 / R-11 / R-12 实现期边界 | §D | 已按当前处置实现、**不阻断**；其中 **R-11 已落地**（§G） |
> | R-13 主数据并入 `pull` | §L | **已落地**（方案 A） |
> | R-14 客户端拉取游标存哪 | §M（候选）→ §N（落地） | **已落地**（方案 A） |
> | **R-15 商品条码重复** | 附录 R-15（待裁定项）→ §S（落地） | **已落地**（2026-09-26：允许 + 建档内联提示 + 扫码多条时选择器） |
>
> **过程记录**：§F 方案 C │ §G R-11 │ §H R-3 │ §I RULE-006 + SyncServer │ §J 包拆分 + host 传输层 │
> §K 首轮修复 │ §L R-13 │ §N R-14 │ §O 数据目录策略 │ §P 数据目录对话框 │ §Q lint 清零 + 左侧导航 │
> §R 商品建档 │ §S R-15 │ §T 首次真机启动 + 三个坑 │ §U 界面字体 │ §V 窗口标题 + 注入 pickDirectory │ §X 采购入库设计提案（待裁定） │ §Y 采购入库 Flutter 层 │ §Z 账户建档 + 店内销售设计提案（待裁定） │ §AA 库存查询 + 往来方页设计提案（待裁定） │ §AB 录入现有货物（期初建账）设计提案（待裁定） │ §AC v1 界面收尾：帮助/设置/期初录入/单据列表（待裁定） │
> §W 启动流程可测化：注入 configStore

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

---

## S. R-15 落地记录（2026-09-26）

**裁定**：同意「警告但不拦」，但要改两处 ——（1）形态是**内联提示**不是弹窗；
（2）**扫码行为必须配套改**：`findByBarcode` 返回列表，多条时让用户自己选。

### 一、裁定书补上了我漏掉的一环

我原来的建议只到「建档时警告」为止，那**和「允许重复」是自相矛盾的**：

```text
用户看到警告 → 继续保存 → 有两条同条码商品
   ↓  以后扫码 → 系统静默选最早那条
用户扫「A 商品」→ 系统弹出「B 商品」→ 用户：软件坏了
```

警告让他知道了重复，扫码时**静默挑一条**又把这个信息抹掉了。
所以 R-15 不是「加一句提示」，而是**同一个口径要贯穿两条链路** ——
建档时呈现、扫码时呈现，不静默、不猜测。

### 二、落地内容

| 层 | 改动 |
|---|---|
| `ProductDao.findByBarcode` | 返回类型 `Product?` → **`List<Product>`**，去掉 `LIMIT 1`；仍按 `(created_at, id)` 排序 |
| `ProductService.barcodeOwners` | **替代**原 `byBarcode`（原签名「返回单条」与裁定冲突，留着就是个坑）。多一个可选 `excludeId` |
| `ProductDraft.barcodeNotice` | 新增纯函数：`List<Product>` → `String?`（空 = 没人用过 = 界面什么都不显示） |
| `product_form_dialog.dart` | 条码框下方一行**橙色内联提示**，边打边更新；有提示时**让出 `helperText`**，避免两行辅助文字挤在一起 |
| `ProductsPage` | 无改动（v1 还没有扫码入口） |

### 三、`excludeId`：裁定书没写、但必须有的一环

**编辑**一条商品时，**它自己也在这个条码的占用者里**。不做排除，打开任何一条已有商品
都会看到「这个条码已经给『它自己』用过了」。所以 `barcodeOwners` 加了一个
可选具名参数 `excludeId`（不改变裁定书给的签名形状，纯增补）。

### 四、文案里的两个决定

1. **只列名字、不列编号**（裁定书已要求）：`「娃哈哈矿泉水 550ml」`，不是 `（P0007）`。
   名字从调用方传进来的 `Product` 直接取，不额外查库。
2. **条数用中文小数字**：`两条` / `三条` … `九条`，超过 9 退回阿拉伯数字 ——
   「保存后扫码会显示十二条商品供选择」反而难读。**这一条裁定书没写，是我加的**，
   测试已把两种形态都钉住（`两条` / `11条商品`）。

### 五、一个顺手修掉的测试缺陷（第七次镜像漂移）

正式测试里写的是 `contains('$ProductDraft.maxNameLength')` —— 少了花括号，
Dart 把 `$ProductDraft` 当成**类型对象的 `toString()`**，`.maxNameLength` 退化成字面量，
于是断言了一个不存在的字符串 `ProductDraft.maxNameLength`。自检那边写的是
`${ProductDraft.maxNameLength}`，所以**只有正式测试红**。
已修，并把这条写进 `docs/testing.md` §零。

### 六、门禁

- core：`typecheck` **18 入口**；`selfcheck_products` **38 → 50 项**；
  `product_service_test` **39 → 48 个用例**（核心合计 206 → **215**）
- 其余 7 个 core 自检复跑**无回归**
- Flutter 侧：`dart format --output=none` 语法通过（`flutter analyze` 需在仓库根跑）

---

## T. 首次真机启动成功 + 三个坑（2026-09-26）

**里程碑**：`flutter run -d windows` 第一次真正跑出 `shensuanzi.exe`（27.4 秒）。
「应用一直起不来」这件事有三个**互不相干**的原因，值得记下来。

### 一、坑 1：CMake 配置阶段下载 sqlite 源码失败（阻断）

`build/windows/x64/_deps/sqlite3-subbuild/.../sqlite-autoconf-3520000.tar.gz` 是 **0 字节**，
`_deps/sqlite3-src/` 是空目录 ⇒ 配置阶段直接失败。**与 Dart 代码无关**：
`flutter analyze` / `flutter test` 全绿也照样起不来。
根因是国内直连 `sqlite.org` 被掐断（镜像 `www2` / `www3` 通畅）。
处置：`windows/CMakeLists.txt` 加离线守卫 + 源码预置到 `third_party/sqlite3/`。
完整步骤见 **`docs/windows_build.md`**。

### 二、坑 2：MSBuild 的 CL.exe 崩在「环境变量大小写重复」上

```text
error MSB6001: "CL.exe" 的命令行参数无效。
System.ArgumentException: 已添加项。字典中的关键字:"HTTP_PROXY" 所添加的关键字:"http_proxy"
  → ProcessStartInfo.get_EnvironmentVariables → Hashtable.Insert
```

Windows 环境块允许同名不同大小写，而 .NET 的 `ProcessStartInfo.EnvironmentVariables`
是**大小写不敏感**的 Hashtable ⇒ 插入即抛异常 ⇒ **C/C++ 一个文件都编不了**。
清掉小写那组后同一个目标立刻编译成功（`env -u http_proxy -u https_proxy …`）。
**判据**：dump 环境筛 `proxy`，同时列出两种大小写 = 中招。

### 三、坑 3：`No MaterialLocalizations found.` —— 弹对话框用了 `MaterialApp` 之上的 context

真机启动后控制台抛 `Unhandled Exception: No MaterialLocalizations found.`，
栈顶是 `showDataDirectoryDialog` ← `_ShensuanziAppState._prepare`。

**根因**：`MaterialApp` 是 `ShensuanziApp` **自己 build 的**，所以
`_ShensuanziAppState.context` 在它**上面**。拿这个 context 去 `showDialog`，
沿祖先链找不到 `MaterialLocalizations`（由 `MaterialApp` 提供）⇒ 抛异常。
更糟的是**对话框根本不出现**，界面停在兜底页「需要一个文件夹来存放数据」——
用户看到的是「按钮没反应」，而不是「弹窗坏了」。

**修法**：加 `navigatorKey`，用 `navigatorKey.currentContext` 弹对话框 ——
Navigator 的 context 在 `MaterialApp` **下面**，这是「从树外面弹对话框」的标准做法
（`Navigator.of` 内部专门处理了「传进来的就是 navigator 自己的 element」这种情况）。

### 四、为什么现有的 widget 测试抓不到它

`test/widget_test.dart` 挂的是 **`AppShell`**，不是 `ShensuanziApp` ——
它压根不经过启动流程，所以这条路径从来没被任何门禁覆盖过
（文件注释里也写了「启动流程会读配置、弹对话框，widget 测试里会炸」）。
**可选的补救** → **已裁定**：注入 `pickDirectory` + `configStore`
（**不是** `DataDirectoryService`），见 §V / §W。

---

## U. 实机反馈：指定系统字体（2026-09-26）

**反馈**：实机跑通后，界面中文是**宋体**，看着「像外国软件没适配」。

**根因**：Flutter 自带的正文字体 **Roboto 不含中文字形**，Windows 上找不到字形
就交给系统兜底 —— 实测落到**宋体**。所以这不是「样式没设」，而是
**「什么都不设」＝把字体交给系统兜，而系统兜的是最旧的那一套**。

**处置**：字体栈放在**纯 Dart** 的 `AppTypography`（平台差异也在这里判断），
Flutter 只取值 —— 与「判断在纯 Dart，Flutter 只摆放」一致。

| 平台 | 字体栈（顺序即优先级） | 理由 |
|---|---|---|
| **Windows** | `Microsoft YaHei UI` → `Microsoft YaHei` → `SimHei` → `Segoe UI` | 雅黑 **UI** 是 Windows 的**界面**字体（资源管理器 / 设置同款）；`SimHei` 保中文字形且**仍是无衬线**；`Segoe UI` 保拉丁字形 |
| **Android** | **不指定**（空栈 = 不干预） | 默认字体本来就是 Noto / 思源，那正是它该有的样子；硬塞 Windows 字体名只会让它掉字形 |

**两个必须点出来的点**：

1. **族名必须写英文不变族名**（`Microsoft YaHei UI`，不是「微软雅黑」）：
   Flutter 在 Windows 上走 DirectWrite，本地化名匹配不上 ——
   而且**不报错、只静默退回兜底字体**。这种「无声降级」只能靠断言钉住，
   所以字体栈进了 `test/typography_test.dart` 与 `selfcheck_app.dart`。
2. **不把字体打进包里**：一套中文字体 10–20 MB，而用户系统里**已经有更好的那一套**；
   用系统字体零体积、随系统更新、与其它窗口同款。

**门禁**：app `typecheck` **8 入口**（新增 `typography_test.dart`）；
`selfcheck_app` **116 → 126 项**；`flutter analyze` / `flutter test` 仍为 0 / 全过。

---

## V. 窗口标题 + 注入 `pickDirectory`（2026-09-26）

### 一、窗口标题：`shensuanzi` → 神算子

`windows/runner/main.cpp` 的 `window.Create(L"shensuanzi", …)` 改成
`L"\u795e\u7b97\u5b50"` —— 标题栏与任务栏用的都是它。

**为什么用 `\u` 转义而不是直接写汉字**：本文件是 UTF-8（无 BOM），
而 MSVC 对没有 BOM 的源文件按**当前代码页**解码 —— 直接写汉字在不同语言的机器上
会被解成乱码标题。转义形式是**纯 ASCII 源码**，任何代码页下都正确。

**没做、留着的**：`windows/runner/Runner.rc` 里 `ProductName` / `FileDescription`
还是 `shensuanzi`，`CompanyName` 还是 `com.example`（exe 属性页、将来的签名会用到）。
RC **不支持 `\u` 转义**，要写中文得同时改 `Translation` 的代码页并另存文件编码 ——
属打包 / 发布阶段（README 状态表第 8、9 步），不混进这次改动。

### 二、注入 `pickDirectory`（按裁定：只注入这一个）

```dart
const ShensuanziApp({
  super.key,
  this.pickDirectory = pickFolderFromSystem,
});
```

- 默认值写在**参数上**（不是 `??` 兜底、更不是留 `null` 运行时再判）⇒
  类型系统保证非空，`runApp(const ShensuanziApp())` 一个字都没改
- `folder_picker.dart` 的 `pickDirectory()` 顺势改名 **`pickFolderFromSystem()`**：
  参数名 `pickDirectory` 到处都是，**真实实现只该有一个名字**。
  这个文件因此从「唯一的插件**调用**点」升级为「唯一的插件**注入**点」

### 三、⚠️ 但五个场景现在**写不了** —— 沙箱缺口（待裁定）

> ✅ **已裁定：采纳建议的 `configStore` 方案 → 落地见 §W。** 以下保留当时的论证。

裁定里说「`DataDirectoryService` 不用注入 —— **指到临时目录就行**」。
核对源码后发现**做不到**：它指向哪个目录，不取决于 `pickDirectory`，
而取决于**配置文件在哪**；配置文件的位置由 `AppEnvironment.detect()` 从 `%APPDATA%` 推出：

```dart
// bootstrap.dart
configStore = configStore ?? AppConfigStore.forEnvironment(environment);
// app_config.dart
final String base = environment.appData ?? p.join(home, '.shensuanzi');
```

`ShensuanziApp` 内部是 `DataDirectoryService(environment: AppEnvironment.detect())`，
**没有传 `configStore`** ⇒ 配置落在**真实的 `%APPDATA%\神算子\config.json`**。
两个后果都不能接受：

| 后果 | 具体 |
|---|---|
| **测试不确定** | 「没有配置过 → 弹对话框」这条在真机上**必然失败**：真实配置已指向 `D:\神算子数据`，`existing()` 返回非空，对话框不弹 |
| **会写坏开发者配置** | 走「确认」路径时 `bootstrap.prepare()` 会 `configStore.save(...)`，把**真实配置改写成测试的临时目录** ⇒ 下次真机启动直接开到临时目录 |

第二条尤其危险，且与**沙箱纪律**直接冲突（`docs/testing.md` §K：
「绝不能碰真实的 `%APPDATA%`」）。

**最小解法（建议）**：再加**一个**可选参数，形状与 `pickDirectory` 一模一样 ——
默认值就地指向真实实现：

```dart
const ShensuanziApp({
  super.key,
  this.pickDirectory = pickFolderFromSystem,
  this.configStore,     // null = 用真实 %APPDATA%
});
```

测试传 `AppConfigStore(File(p.join(sandbox.path, 'config.json')))`。
**只多一行，`DataDirectoryService` 照旧不注入**，其余全走真实路径 ——
与裁定「一个注入点解锁全部场景」的目标一致；只是那个注入点还需要一个
「配置放哪」的落点，否则临时目录**无处可指**。

> 备选是注入 `AppEnvironment`（粒度更大，会把「机器事实」也一起变成假的）。
> 不推荐：`configStore` 已经够用，而且它正是 `DataDirectoryService` /
> `AppBootstrap` **已有的那个接缝**。

**裁定前不动**：五个场景的 widget 测试**一行都没写** —— 写了就会碰真实配置。

> **【已裁定】**（`docs/reply.md`）：采纳 `configStore` 可选参数方案。理由三条——
> ① 它是 `AppBootstrap` **已有的接缝**，只是往上提一层；② `AppEnvironment` 必须保持真实，
> 否则变成「在假机器上跑假配置」，每个场景还得自己造盘符；③ 粒度与 `pickDirectory` 对称，
> 两个参数正好收拢启动流程的**全部系统交互**。落地记录见 **§W**。

### 四、回头补的坑：C4819（我自己捅的）

上面第一节把窗口标题写成 `L"\u795e\u7b97\u5b50"` 是对的，
但我**顺手在那两行里写了中文注释** ⇒ 构建直接失败：

```text
main.cpp(1,1): error C2220: 以下警告被视为错误
main.cpp(1,1): warning C4819: 该文件包含不能在当前代码页(936)中表示的字符
```

**根因**：仓库源码是 UTF-8（无 BOM），而 `windows/` 下的 `.cpp` 原本**全是英文注释**，
所以这个坑从没暴露过。MSVC 默认按**系统代码页**（简体中文机器 = 936/GBK）解码源文件，
UTF-8 的中文在 936 下是非法字节序列 ⇒ C4819；而 `apply_standard_settings` 带 `/WX`
（警告即错误）⇒ 变 C2220 ⇒ **编译失败**。
**`\u` 转义只解决字符串字面量，注释照样报错** —— 我等于只修了半套。

> 顺带修正第一节的说法：加了 `/utf-8` 之后，字面量直接写汉字也能编过。
> 保留 `\u` 转义的理由变成「**不依赖编译选项**」：那一行是纯 ASCII，
> 将来谁把 `/utf-8` 去掉都不会让标题变乱码。

**修法（治根因，而不是把注释改成英文）**：`windows/runner/CMakeLists.txt`

```cmake
target_compile_options(${BINARY_NAME} PRIVATE "$<$<COMPILE_LANGUAGE:C,CXX>:/utf-8>")
```

**验证**（本机可复现：用**真实 `main.cpp`** + 从生成的 `vcxproj` 里取出 include 目录与宏，
直接调 `cl.exe`）：

| 编译选项 | C4819 | C2220 |
|---|---|---|
| 不带 `/utf-8` | **1** | **1** |
| 带 `/utf-8` | 0 | 0 |

另外确认 `/utf-8` 只进 `ClCompile` 的 `AdditionalOptions`（4 个配置各一条），
**没有**进 `ResourceCompile` —— `$<COMPILE_LANGUAGE:C,CXX>` 那个限定就是为这个。
（`rc.exe` 不认 `/utf-8`，少了限定就会在资源编译上再炸一次。）

完整论述与排查手法写进 `docs/windows_build.md` **§七**。

---

## W. 启动流程可测化：注入 `configStore`（2026-09-26）

**裁定**（`docs/reply.md`）：采纳 `configStore` 可选参数，默认 `null`，在字段初始化时
`??` 解析；**`AppEnvironment` 保持真实**，`DataDirectoryService` 与 `AppBootstrap`
**都不注入**。

### 一、补的是哪个缺口

`ShensuanziApp` 内部是 `DataDirectoryService(environment: AppEnvironment.detect())`，
**没传 `configStore`** ⇒ 配置落在**真实 `%APPDATA%\神算子\config.json`** ⇒
启动流程的测试既**不确定**（真机已有配置 → 对话框永远不弹），又**有破坏性**
（`prepare()` 会把真实配置改写成测试用的临时目录，而临时目录随后被清理）。

### 二、为什么是 `configStore`，不是别的

| 备选 | 不采纳的原因 |
|---|---|
| 注入 `AppEnvironment` | 测试要伪造 `home` / `appData` / 系统盘 / 每个盘的字母与剩余空间 —— **造机器的工作量会盖过测启动流程本身**。真想测的是「**真实机器 + 沙箱配置**」 |
| 注入 `DataDirectoryService` | 把「环境 + 配置 + 策略」捆成一团；服务本身已经有纯 Dart 测试 |
| 注入 `AppBootstrap` | 它是一个**流程**，不是依赖 —— 注入它，测的就成了「我传的假 bootstrap 会不会按我想的返回」，**测的是 mock** |

`configStore` 还占一条便宜：它**本来就是 `AppBootstrap` 已有的接缝**
（`configStore = configStore ?? AppConfigStore.forEnvironment(environment)`），
这次只是把它**往上提一层**。

### 三、两个注入点形状不同，表达的是同一件事

| 参数 | 默认值 | 为什么是这样 |
|---|---|---|
| `pickDirectory` | `pickFolderFromSystem` | 函数引用是**编译期常量**，能直接内联进参数默认值 |
| `configStore` | `null` | 真实位置依赖**运行时环境**（`AppEnvironment.detect()`），编译期算不出来 ⇒ 用 `null` 表示「用默认的」，在字段初始化时 `??` 解析 |

两者都是「**不传就用生产行为**」。`const ShensuanziApp()` 一个字没改。

### 四、落地

- `lib/src/app.dart`：`_environment`（`final`）→ `_configStore` → `_service`；
  后两个用 `late final`（要读 `widget.configStore`）
- **新增 `test/startup_test.dart`**：五条场景全部落地
- ⚠️ **测试必须调 `useLocalSqlite()`**：`sqlite3_flutter_libs` 只把 `sqlite3.dll`
  放进**应用目录**，`flutter test` 不打包它 ⇒ 不覆盖加载就一律开库失败，
  场景 ②/③/⑤ 会**假失败**（绿不了的绿比红更危险）
- 场景 ⑤ 的构造手法：把 `shensuanzi.db` 写成一个**非空的非法字符串** ⇒
  `Db.open` 首次执行 `PRAGMA journal_mode=WAL` 时抛 `SqliteException`，被
  `_openDatabase` 的 catch 捕获 → 错误页。这条路径（目录能建、库打不开）正是
  `app.dart` 里那个错误页存在的理由
- 前置状态（场景 ②/⑤）用 `DataMarker.write` + `store.save(AppConfig(...))`
  直接造，不调 `prepare()` —— 那样会**多写一次配置**（`prepare` 自己会
  `saveConfig`），且场景 ⑤ 要造的正是「prepare 放行、open 失败」的分叉，
  调 `prepare` 反而绕远了
- **场景 ③/⑤ 必须先点「更改」再点「开始使用」**：`DataDirectoryDialogModel.open()`
  用 `resolveDefault()` 起步，而那是**真实默认路径**（`D:\神算子数据`）——
  不先「更改」到沙箱目录，测试就会在开发者磁盘上真建目录

### 五、门禁

- `flutter test`：`widget_test` 6 + `startup_test` **5** = **11 个用例**
- `flutter analyze`：0 issues。新增测试 `import package:path`，根 `pubspec.yaml`
  因此**显式声明 `path: ^1.9.0`**（否则 `depend_on_referenced_packages` 会报：
  直接 import 的包必须是直接依赖）
- ✅ **已实测通过**（2026-09-26，用户复跑：11/11 全过）。首轮与二轮的两次红
  分别见上方的 **§七（finder 歧义）** 与 **§八（getter 写进函数体）**，
  根因都在**测试代码**，五条场景的业务逻辑一次通过

### 六、纪律与代码对齐（顺带的观察）

`docs/testing.md §K` 早就写了「绝不能碰真实 `%APPDATA%`」，
但**从 `ShensuanziApp` 外面看根本没有地方能指到沙箱** ——
这条纪律在这一层**无法被遵守**，只是暂时没人去触碰而已。
补上 `configStore` 之后，纪律和代码才对齐。

**写下的纪律必须能在代码里被执行，否则它只是一句话。**

### 七、首轮跑出的一处 finder 缺陷（3 条红，根因同一个）

首轮 `flutter test`：**场景 ① / ③ / ④ 红**，报
`Expected: exactly one matching candidate / Found 2 widgets with text "选择数据存放位置"`。

**根因**：启动兜底页（`_StartupPage`）的按钮文字**也叫「选择数据存放位置」**，
而对话框开着时**底下的兜底页还在** —— 标题一个、按钮一个，恰好 2 个。
裸 `find.text(...)` 直接撞上歧义。

**修法**：把「对话框在不在」的断言**限定在 `AlertDialog` 里面**：

```dart
Finder get dialog => find.byType(AlertDialog);
Finder get dialogTitle =>
    find.descendant(of: dialog, matching: find.text('选择数据存放位置'));
```

**顺带一个好消息**：首轮 **8 过 3 红**，而 3 条红是**同一个 finder 问题** ——
也就是说 `useLocalSqlite()` 在 tester 里**真能加载 `winsqlite3.dll`**（场景 ②/③ 开库成功）、
场景 ⑤ 的「非法库 → 错误页」成立、对话框的「更改 / 开始使用」交互可点。
五条场景的**逻辑**全部一次通过，红的全是查找器写法。

### 八、二轮翻车：getter 写进了函数体（编译都没过）

修好 finder 后我把它写成 `Finder get dialog => …` —— **但这段代码在 `main()` 里面**，
getter 只能声明在类 / 库顶层 ⇒ 整个测试文件**编译失败**：

```text
test/startup_test.dart:63:10: Error: Expected ';' after this.
  Finder get dialog => find.byType(AlertDialog);
```

**修法**：函数体内用局部 `final` 变量（同样是常量语义，但语法合法）：

```dart
final Finder dialog = find.byType(AlertDialog);
final Finder dialogTitle = find.descendant(of: dialog, matching: find.text('…'));
```

### 九、⚠️ 我的语法门禁为什么会放行它 —— 退出码被管道吞了

我跑的是：

```bash
dart format --output=none test/startup_test.dart 2>&1 | tail -2
echo "rc=$?"        # ← 取到的是 tail 的退出码，永远是 0
```

**`dart format` 其实报错了**（输出里有 `╵` 那个语法错误标记），但管道之后的 `$?`
是 `tail` 的退出码 —— 门禁被我自己的取码方式**静默放行**。

**正确写法**（二选一）：

```bash
dart format --output=none test/startup_test.dart          # 直跑，$? 就是它
dart format --output=none f.dart 2>&1 | tail -2; echo "${PIPESTATUS[0]}"   # 取第一个
```

这条已写进 `docs/testing.md` §L 的门禁表。

---

## X. 设计提案：采购入库开单（2026-09-27，**待裁定**）

> 裁定答复请写在 `docs/reply.md`。此处只存提案与结论锚点，落地后另开 §Y。

### 一、事实核对（core 已具备，本阶段**不动 core 规则**）

| 能力 | 现状 |
|---|---|
| `RuleEngine.dispatch(docType: purchase, lines, immediatePayments)` | ✅ 215 用例覆盖（RULE-001） |
| 散采现结（**无供应商 + 全款**） | ✅ 合法且有正向用例（`immediate_payment_test.dart:331`，往来净额为 0） |
| 赊购 / 部分付款 | ⚠️ **必须有供应商**（`_requirePayee`：存在未结清金额且无 party ⇒ 拒） |
| 立即付款约束 | `amount > 0`；`SUM(payments) ≤ total`；可多账户混合 |

### 二、分层

| 层 | 内容 |
|---|---|
| **core**（纯 Dart，`dart test` 覆盖） | `PurchaseDraft`：供应商 + 明细行 + 立即付款的**原文草稿 + 纯函数校验**，与 `ProductDraft` 同构；产出 `Document` / `DocumentLine` / `PaymentEntry` 交给 `RuleEngine` |
| **Flutter**（只摆放） | `purchase_page.dart`（沉浸模式已由导航定义）：供应商、明细行、合计、立即付款、保存 |

### 三、草稿校验清单（拟）

| 字段 | 规则 |
|---|---|
| 供应商 | 可空 = 散采；**散采必须当场结清**（留空且有欠款 ⇒ 报「散采要当场结清，或选一个供应商」） |
| 明细 | ≥ 1 行；每行商品必选、数量**正整数**、单价 ≥ 0 且最多两位小数 |
| 单价默认 | 选商品后**预填该商品的进价**（可改）——省一次输入，且进价本来就该填 |
| 立即付款 | 账户必选、金额 > 0、`SUM ≤ 合计`；可多条（多账户混合） |
| 文案 | 一律「怎么办」，字段级报错（同 `ProductDraft`） |

### 四、待裁定项

| # | 问题 | 我的建议 |
|---|---|---|
| P-1 | `PurchaseDraft` 放哪 | `core/src/documents/purchase_draft.dart`（与 `documents` 表语义对齐；`ProductDraft` 在 `master_data/` 是因为商品本身就是主数据，单据不是） |
| P-2 | 立即付款区形态 | **常驻显示**（供应商下方），金额默认空 = 全赊；旁边给「全款」一键填入合计。理由：货到付款是高频路径，折叠会让用户找不到 |
| P-3 | 保存后的去向 | **留在本页并清空表单** + SnackBar「已保存，单号 X，欠款 Y」。理由：开单是高频连续动作 |
| P-4 | 商品选择器 | 点「选商品」弹出**搜索列表**（名称/编码/条码，复用 `ProductService.list(query:)`），点选即填。不做下拉 —— 商品会超过一屏 |
| P-5 | 无往来方建档 UI | **本阶段不做**。散采现结不依赖往来方；等做「送货」前再补往来方建档（送货必须有客户） |

### 五、门禁（拟）

core：`purchase_draft_test` + `selfcheck` 镜像；Flutter：`purchase_page_test`（沿用两个注入点）；`flutter analyze` 0 issues。

### 六、裁定结果与落地（2026-09-27）

**裁定**（`docs/reply.md`）：P-1 / P-2 / P-4 同意；P-3 同意并补细节
（保存后**保留供应商与日期**，只清明细与付款）；**P-5 改为「最小供应商新建入口」**
（名称 + 电话可选两字段 —— 否则赊购用户在主路径上死锁，报错没法照做）；
另补 7 项遗漏：日期（默认今天可改）/ 取消（有内容时二次确认）/ 键盘效率（Enter 下一格、
Ctrl+S 保存、Esc 取消）/ 数字键盘 / 合计显示（大字 + 右对齐 + 千分位）/
**预填依据 = `products.cost_price`**（用户主动填的价，不做历史推算）/
数量精度限制（INTEGER，不支持按斤按米 —— v1 接受，记录在案）。
新增 **P-6 键盘效率**、**P-7 供应商新建入口**。

**第 1 步落地（core，2026-09-27）**：

| 项 | 内容 |
|---|---|
| `purchase_draft.dart` | 三个字段枚举 + `PurchaseLineDraft` / `PurchasePaymentDraft` / `PurchaseDraft`（原文 + 纯函数校验 + 取值 + `fromProduct` 预填进价） |
| `purchase_service.dart` | `PurchaseService.create`（三组校验 → 构造 Document / lines / `PaymentEntry` → `dispatch` → **读库**取最终状态）+ `createSupplier`（最小建档）+ `PurchaseSaved` |
| 门禁 | `typecheck` **20 入口**；`selfcheck_purchase` **19 项**（core 合计 513 → **532**）；全套 9 个自检无回归 |

**过程中的一个真发现**：`RuleOutcome.document` 带回的是主单**刷新前**的样子
（`paid_amount = 0`）—— 立即付款对 `paid_amount` 的刷新发生在 outcome 构造**之后**。
`PurchaseService` 因此**按 id 读库**取最终状态，不信任 outcome 的缓存值
（真相在库，不在返回值；已写进 `docs/testing.md` §N）。

**校验语义的两处修正**（首轮自检抓出）：
1. **空行照常报行级错误**（「加了一行就得填或删」）—— 原提案「空行不报错」会让人
   以为那行被忽略了；「至少要有一行」的判定随之改为 `lines.isEmpty`
2. 补上「**付款合计 ≤ 本单合计**」的表单级校验（挂 `PurchaseField.payments`，
   报错说清超了多少）—— 原提案漏了，只靠规则层兜底会让报错晚一步且文案不可执行

**下一步**：Flutter 页面（`purchase_page.dart` + 商品选择器 + 供应商最小新建 +
键盘/日期/合计），沿用两个注入点。

---

## Y. 采购入库 Flutter 层落地（2026-09-27）

按 §X 六 的顺序完成第 2、3 步。**本阶段一处未改 `RuleEngine`**（215 用例不动）。

### 一、core 补充（页面需要的查询）

`PurchaseService` 新增三个只读查询（页面只依赖 `PurchaseService` + `ProductService` 两个对象，
不再往外暴露 DAO）：

| 方法 | 用途 |
|---|---|
| `activeSuppliers()` | 供应商选择器（`role: supplier, active: true`） |
| `activeAccounts()` | 立即付款区（默认账户 = 第一个启用账户） |
| `recentlyPurchased({limit: 20})` | 商品选择器**空查询时的「最近使用」**—— 采购大部分是重复的，打开就能点到常买的货；只含启用中的商品，按最近采购时间倒序 |

`Money.formatGrouped(cents)`：合计大字的**千分位**展示（`12,345.67`）。

### 二、页面（`lib/src/ui/purchase_page.dart`）

- **状态以控制器为真相**：`_RowCtl` / `_PayCtl` 持有 `TextEditingController` 与
  商品 / 账户选择结果，保存时**合成** `PurchaseDraft` —— 预填进价、清空表单都是
  直接操作控制器，无需双向绑定
- 行卡片 / 付款卡片是**无状态组件**，控制器由页面持有 ⇒ 删行、清空、预填都是改页面状态
- 沉浸模式（无面包屑）；「取消」在有内容时弹确认，确认即**清空回初始**（本页是
  导航内容区的一部分，不是独立路由）
- ⚠️ **Enter 下一格在桌面端要显式切焦点**（`onSubmitted: (_) => FocusScope.nextFocus()`）
  —— `textInputAction: next` 只影响虚拟键盘按钮，Windows 上没作用

### 三、门禁

- `flutter analyze` / `flutter test`（widget_test 6 + startup_test 5 + **purchase_page 5** = 16）
  —— **待用户复跑**（本机 flutter_tools 缺陷跑不了）
- core：`typecheck` 20 入口、`selfcheck_purchase` 19/19（上轮已完成）
- 语法门禁：`dart format --output=none` 退出码 **0**（本轮起按 §W 八 的教训取对退出码）

### 四、页面测试覆盖（`test/purchase_page_test.dart`）

| # | 场景 |
|---|---|
| 1 | 空表单点保存 → 「至少要有一行商品」且无 SnackBar |
| 2 | 散采全款 → SnackBar「已保存 ¥35.00…（已结清）」+ 库存 +10 |
| 3 | 散采欠款 → 「散采要当场结清」 |
| 4 | 供应商 + 部分付款 → SnackBar 带「王老板 累计欠款」 |
| 5 | 取消：有内容 → 确认框 → 确认后清空 |

测试交互的两个坑：商品选择器**空查询显示的是「最近采购」**（首次为空，要先在
搜索框输入再点选）；`find.widgetWithText` **匹配不到 InputDecoration 的 label**
（那是参数不是 Text widget）—— 输入框一律用 `Key` 定位。

### 五、首轮复跑抓出的 14 个问题与修复（2026-09-27）

用户复跑 `flutter analyze` 报 **14 issues**（6 error / 4 warning / 4 info），
`flutter test` / `flutter run -d windows` 因此全部编译失败。**根因不在 Dart 语法**
（`dart format` 门禁通过），而在**语义层** —— 逐条修复：

| # | 问题 | 修法 |
|---|---|---|
| 1 | `AppShell` 有 `purchases` 字段但**构造函数漏了参数** | 补 `this.purchases` |
| 2 | 页面 `await service.create(...)` —— `create` 是**同步**的 | 去 await；`_save` 改同步函数 |
| 3 | 两处 `const InputDecoration(errorText: <非 const 表达式>)` | 去掉 `const` |
| 4 | `DropdownButtonFormField.value:` 已废弃（v3.33 起） | 改**完全受控**的 `InputDecorator` + `DropdownButton` —— 顺带修掉一个潜在 bug：FormField 的 `initialValue` 只在首帧生效，而本页用 ValueKey 复用卡片（删行 / 清空后下标挪动），内部状态会跟控制器错位 |
| 5 | `recentlyPurchased` 调在 `ProductService` 上（实际在 `PurchaseService`） | 「最近采购」查的是 `document_lines`（采购数据非主数据），由页面查好**当参数传入**弹层 |
| 6 | 未用的 import / 字段（`_suppliers`）/ 参数（`_RowCtl.product`） | 清除 |
| 7 | 测试里未用的局部变量 | 清除 |

**测试又暴露两个交互坑（已写进测试注释）**：

- `find.byType(TextField).first` 找弹层搜索框会**命中页面背后的输入框**
  （弹层底下压着 4 个，树的先序遍历先碰到）→ 搜索框加 `Key('picker-search')`
- 800×600 测试视口装不下整页，**底部按钮在渲染树之外**，直接 tap 会 miss
  → `tapBottomButton()` 先 `scrollUntilVisible` 再点

另外「空表单」的断言随校验语义更新：空行报**行级**错误（`请选一个商品`），
没有整单级「至少要有一行」。

### 六、门禁终值（本轮起**全部可自验**）

| 门禁 | 结果 |
|---|---|
| `flutter analyze` | **0 issues**（沙箱内实测跑通 —— 环境限制解除） |
| `flutter test` | **16/16**（widget 6 + startup 5 + purchase_page 5） |
| core `dart test` | **234/234**（含 `purchase_draft_test` 19） |
| `flutter build windows --debug` | ✅ 12.7s 出 `shensuanzi.exe`（`env -u http_proxy`） |

**环境备忘（2026-09-27 实测）**：此前「本机 `dart test` / `flutter *` 不可用」的结论**已过时** ——
补上 PortableGit PATH 后 `flutter analyze` / `flutter test` / `dart test` / `flutter build`
都能在 AI 会话里跑（C/C++ 构建仍需先清小写代理变量）。交付前的门禁改为**自验后再交**。

### 七、真机反馈两连修（2026-09-27 下午）

真机截图确认页面可用，但控制台每敲一个字崩一次：

| # | 问题 | 根因 | 修法 |
|---|---|---|---|
| 1 | `Unsupported operation: Cannot remove from a fixed-length list`（供应商搜索逐字崩） | `activeSuppliers()..removeWhere(...)` —— sqlite3 的结果行是**定长列表**，不能 removeWhere | 改 `.where(...).toList()` 生成新列表，不碰原对象；新增回归用例（打字不崩 + 过滤生效 + 过滤到空） |
| 2 | **无资金账户时的死局**（截图：库里没账户，「请选一个资金账户」无法照做） | `initState` 只在**有**账户时才造付款行 —— 用户点「添加账户」后得到账户下拉为空的必错行 | 没有账户时付款区给**能照做**的内联提示（橙色 §1.3）：「先到「账户」页新建；在那之前只能全赊（需选供应商）」；「全款」按钮同步禁用 |

门禁：`flutter analyze` / `flutter test`（17 用例）—— AI 会话管道耗尽无法复跑，**待用户复跑**
（本轮改动语义简单：一处 where() 重构 + 一段条件摆放 + 一条新用例，语法门禁已过）。

---

## Z. 设计提案：账户建档 + 店内销售开单（2026-09-27，**待裁定**）

> 裁定答复请写在 `docs/reply.md`。此处只存提案与结论锚点，落地后另开 §AA。

### 一、事实核对（core 现状）

| 能力 | 现状 |
|---|---|
| `RuleEngine` 的 `_sale`（RULE-002） | ✅ **已实现**：负库存（加权平均出库成本）、`PartyLedger +total`、立即收款自动生成 receipt + Settlement + MoneyLedger |
| 销售测试覆盖 | ✅ `immediate_payment_test` 11 处 `DocType.sale` —— **core 规则层不需要动** |
| 散客约束 | ✅ `_requirePayee` 与采购同源：**无客户 + 有未结清 ⇒ 拒**（散客必须当场结清） |
| `Account` 模型 | ✅ 已有 `initialBalance`（期初余额，**修改会重算全部历史余额**，`data_model.md` §2.3）+ `AccountType` 五类（cash/wechat/alipay/bank/other） |
| 账户建档服务层 | ⛔ 只有 `AccountDao`，**没有 `AccountDraft` / `AccountService`**（主数据三件套缺账户） |
| 真机已撞到的阻塞 | 上轮测试：库里无账户 ⇒ 散采全款存不了 —— **账户建档是当前最短板** |

### 二、范围建议

**A. 账户建档（小，先行）+ B. 店内销售开单（大，随后）一个阶段做完**。
理由：A 是 B 的收款前置，而且上轮真机已经撞到「没账户存不了全款」。

### 三、A 账户建档

| 层 | 内容 |
|---|---|
| core | `AccountDraft`（名称必填、类型五选一、期初余额可空默认 0）+ `AccountService`（create / update / setActive / list），与 `ProductService` 同构 |
| Flutter | `account_page.dart`：列表（余额列用 `QueryDao.accountBalances`）+ 新建/编辑对话框 + 停用恢复，复用商品页骨架 |

### 四、B 店内销售开单（与采购页同构，差异点如下）

| 差异 | 内容 |
|---|---|
| 方向 | 库存 `-qty`；付款区 = **收款**（收入）；对象 = **客户** |
| 单价预填 | **售价** `sellingPrice`（采购预填进价） |
| 散客 | 客户可空 = 散客；**散客必须当场结清**（同散采，文案对齐） |
| **负库存** | RULE-002 **允许**但「UI 红色告警」—— 行内显示当前库存，数量超库存时**红色内联提示（不拦人）**，说明「按最近入库价出库」 |
| 最近使用 | 商品选择器空查询 = 最近**销售** |
| 客户新建 | 最小入口（名称 + 电话可选，role=customer），同 P-7 供应商 |

### 五、待裁定项

| # | 问题 | 我的建议 |
|---|---|---|
| Z-1 | 范围 | A + B 一起做（账户先行）；若嫌大，A 单独成阶段 |
| Z-2 | 负库存告警形态 | **行内红色提示，不拦人**（与「允许负库存」的规则一致；弹窗会被高频误触） |
| Z-3 | 账户**编辑期初余额** | 建时可填；编辑时改它 ⇒ **二次确认**（会重算全部历史余额，属重大操作，§1.2） |
| Z-4 | 客户建档 | 本阶段只做**最小新建入口**；完整往来方页（列表/编辑/对账）留后续 |
| Z-5 | 「最近销售」查询 | 把 `recentlyPurchased` **泛化**为 `recentProducts({List<DocType>})`（一处 SQL，采购/销售共用），不新增平行方法 |

### 六、门禁（拟）

core：`account_draft_test` + `sale_draft_test` + selfcheck 镜像；Flutter：`account_page_test` + `sale_page_test`（复用两个注入点经验）；`flutter analyze` 0 issues。交付前 AI 侧先自验（能跑时）。

### 七、裁定结果与落地（2026-09-27，core 第 1 步）

**裁定**（`docs/reply.md`）：Z-1 ~ Z-5 全同意；**Z-3 改方案 A**（不允许编辑期初余额，
比二次确认干净 —— 「我当时填错了」和「我改变主意了」是同一件事，都是修正；
真改错就新建账户 + 停用老的）；**Z-4 补「同名 party 追加 role」**；补 7 项遗漏。

**7 项遗漏的处置**：

| # | 处置 |
|---|---|
| 退货入口 | **方案 A：v1 UI 不做，明说**。单据列表页尚不存在，B 方案（列表+退货按钮）依赖它 ⇒ 依赖倒挂。**在 §Z 明确声明是有意识的不做**：需要退货请等 v1.1（会带单据列表一起做）；在此期间开负数销售单会绕开 RULE-007 成本回退，**不建议** |
| 折扣/抹零 | v1 不做；改最后一行单价即可；整单折扣记 v1.2 候选 |
| 最近客户 | 客户选择器空查询显示「最近往来的客户」（Flutter 轮随页面一起做） |
| 预填售价 | **默认值不是约束**：用户改过的单价是这一行的真相，**不回写** `sell_price`（已写进 `SaleLineDraft` 注释） |
| 送货单 | v1 不做（`delivery` 规则 core 已有，UI 留 v1.1）；送货可在备注注明 |
| 利润显示 | v1 开单页与 SnackBar **都不显示**（用户会问「这数怎么来的」）；v1.2 在单据详情页按需展示 |
| 必填星号 | 已加进 `docs/ui_principles.md` §一（必填标红星、选填不标） |

**两条实现建议的采纳**：

1. **`DocumentDraft` 抽象：本轮留注释不抽**。`SaleDraft` 与 `PurchaseDraft` 约
   80% 同构，但采购已被 200+ 用例钉住；现在抽要同时动两个稳定模块。
   **等第三个（`DeliveryDraft`）出现时再抽** —— 三处重复才看得清抽象形状
   （裁定书明确允许此选项）。过渡措施：两文件**逐字段对齐** + 文件头写明抽象时机。
2. **库存快照语义**：`SaleService.stockSnapshot()` —— **打开本页时查一次**
   （`QueryDao.stockByProduct` 批量），输入时只对照快照；**不重查**，因为它
   只是提示不是校验（负库存本来就放行）。UI 文案将标明「（打开本页时）」。

**落地内容（core）**：

| 文件 | 内容 |
|---|---|
| `master_data/account_draft.dart` + `account_service.dart` | 账户三件套；**update 不改期初余额**（服务层兜底，绕过 UI 也改不了） |
| `master_data/party_service.dart` | `ensureParty` 三分支（新建 / 追加 role / 原样返回）+ `PartyMutation`（UI 据此提示「已把老王加为你的客户」）；`PurchaseService.createSupplier` **改为委托它** |
| `dao/query_dao.dart` | `recentProducts({List<DocType>})` —— 采购/销售共用一处 SQL（Z-5）；`recentlyPurchased` 变成命名转发 |
| `documents/sale_draft.dart` + `sale_service.dart` | 销售草稿三件套 + `SaleService`（`stockSnapshot()` / `activeCustomers` / `recentlySold` / `createCustomer`） |
| 门禁 | `typecheck` **26 入口**；三个新 selfcheck **11 + 19 + 6 = 36 项**；**12 个自检全绿合计 568 项**（采购 19 项无回归）；`dart test`（+30 用例）因会话管道耗尽**待用户复跑** |

### 八、Flutter 层落地（2026-09-27，第 2/3 步）

| 文件 | 内容 |
|---|---|
| `ui/account_page.dart` | 列表（余额 = 期初+流水）+ 新建/编辑对话框 + 停用/恢复；**编辑时期初余额只读**并给「怎么办」（新建账户+停用，Z-3 方案 A 的 UI 面） |
| `ui/sale_page.dart` | 与采购页同构；售价预填（可议价、不回写）；**负库存行内红色提示，标明「（打开本页时）」快照**（Z-2）；散客文案；无账户死局预防（同采购页）；必填红星；v1 无折扣/无利润显示（§Z 遗漏 2/6） |
| `ui/app_shell.dart` + `app.dart` | 接线 `sales` / `accounts` / `parties` 三个服务（`SalePage` 的客户「新建」直接用 `PartyService`） |
| core 补充 | `QueryDao.recentParties`（遗漏 3：客户选择器空查询 = **最近往来**；散客 `party_id IS NULL` 天然排除）→ `SaleService.recentCustomers`；镜像 test + selfcheck 各一条 |

**门禁**：语法全过；`typecheck` 26 入口；`selfcheck_party` **7/7**（含 recentCustomers）。
⚠️ 会话管道持续耗尽 —— `flutter analyze` / `flutter test`（预期 0 issues / 28 用例 =
widget 6 + startup 5 + purchase 6 + account 4 + sale 7）与 `dart test`（account 单文件）**待用户复跑**。

### 九、复跑 6 issues 修复（2026-09-27）

| # | 问题 | 修法 |
|---|---|---|
| 1 | `AccountType? _type = widget.existing?.type;` —— 初始化器里**不能读 `widget`** | 改 `late final`（与 `_name` 同款） |
| 2 | sale_page 的 `_RowCtl` 漏了 `quantityValue` getter（镜像采购时漏搬） | 补上 |
| 3 | 测试里 `const <PurchaseLineDraft>[... productId: productId ...]` —— **const 列表里掺运行时变量** | 去 `const` |
| 4 | party_service_test 未用局部变量 | 删 |

**共同点**：全是「搬运时漏了上下文」—— 镜像采购页时 `_RowCtl` 少搬一个 getter、
测试里手写 `const` 却忘了字段值来自变量。语义门禁（analyze）仍是硬依赖。

### 十、复跑 1 issue 修复（2026-09-27）

`_type` 上一轮改成 `late final`（为了在初始化器里读 `widget`），但下拉的
`onChanged` 还要**写**它 —— 两个约束打架。标准解法：字段改回**可变**，
回填挪进 **`initState`**（State 的生命周期里读 `widget` 是合法的）。
`_save` 读 / `onChanged` 写 / `initState` 回填三条路都通。

**教训（`docs/testing.md` §L 补）**：State 字段要**读 `widget` 回填 + 后续可写**
时，唯一正确形状是「可变字段 + initState 回填」—— `late final` 只适用于
永不改写的派生值。

好消息：上轮 `flutter test` 输出里 **purchase 6 + sale 7 共 13 条已实际通过**
（红的是 account/startup/widget 被同一个编译错连累加载失败）——
销售页的负库存快照提示、议价、客户同名追加 role 全部验证过。

### 十一、复跑 1 红修复（2026-09-27）：账户行加 Key

`analyze` 0 issues ✓。唯一 1 红：编辑用例 `tap('现金')` 找到 **2 个** ——
列表行账户名 + 对话框下拉的**选中项**都叫「现金」（与采购页 finder 歧义同款）。
修法：`_AccountRow` 加 `Key('account-row-<id>')`，测试点 Key 不点文字。

**同一段文字会在屏幕上出现两次** —— 这条在采购页（兜底页按钮 vs 对话框标题）、
销售页（无）之后第三次出现，值得作为默认反射：**凡是「点某行 / 某元素」的测试，
能用 Key 就不用文字**。

### 十二、全过收官（2026-09-27 晚）

`flutter analyze` **0 issues**；`flutter test` **28/28**（widget 6 + startup 5 +
purchase 6 + account 4 + sale 7）；core `dart test` **270 用例**、
12 个自检 **568 项**、`typecheck` **26 入口**。

**核心闭环现状**：商品建档 → 采购入库（立付/赊购/散采）→ **账户建档 → 店内销售
（立收/赊销/散客/负库存告警）** 全部可走真机。单据/库存/往来方查询、送货、
退货、付款核销仍待后续阶段（v1 范围声明见 §Z 七）。

**本轮 finder 歧义第三次出现**（兜底按钮/对话框标题 → 账户名/下拉选中项），
已固化为反射：点某行的测试一律用 Key。

---

## AA. 设计提案：库存查询页 + 往来方页（2026-09-28，**待裁定**）

> 裁定答复请写在 `docs/reply.md`。落地后另开 §AB。

### 一、事实核对与范围建议

| 候选 | core 现状 | 建议 |
|---|---|---|
| **库存查询**（RULE-006） | ✅ `stockByProduct` / `inTransitByProduct` / `availableInStore` / `costSnapshotOf` 全就绪 | **本阶段做** |
| **往来方页** | ✅ `partyBalances` / `PartyDao.findAll(role:, active:)` / **`PartyLedgerDao.ofParty`（流水）** 全就绪 | **本阶段做** |
| 单据列表页 | ⛔ `DocumentDao` **没有任何列表查询方法**（只有 insert/findById），要新设计分页/过滤 | **随付款核销阶段** —— 它是退货/核销的操作前置，值得独立成阶段 |

理由：采购/销售跑通后用户最想问的是「还剩多少货、谁欠我多少」—— 两个查询页
**零新规则**（RULE-006 纯聚合读），半天量级；单据列表是新查询设计 + 操作枢纽，
混进来会把查询页拖成大阶段。

### 二、库存查询页（RULE-006）

| 列 | 口径 |
|---|---|
| 商品 | 名称 + 编码（启用中的） |
| **在店可售**（主列） | 账面 − 在途（`availableInStore`，低库存告警按它算） |
| 账面库存 | `stockByProduct` |
| 在途 | `inTransitByProduct`（送货单未签收） |
| 库存成本（待裁定 AA-4） | `SUM(total_cost)` 加权余值 —— 「压了多少钱的货」 |

搜索：名称 / 编码 / 条码（复用 `ProductService.list(query:)`）。无流水的商品
按 0 显示（没进过货 ≠ 不存在）。

### 三、往来方页

| 列 | 内容 |
|---|---|
| 名称 + 角色 | 供应商 / 客户（可双角色，两个标签） |
| 余额 | **正 = 应收（对方欠我）**，负 = 应付；0 沉底 |

点击某往来方 → **流水页**（`PartyLedgerDao.ofParty` 已有，每笔：单号 / 方向 /
金额 / 日期）—— 对账的最基本形态，零新查询。

### 四、待裁定项

| # | 问题 | 我的建议 |
|---|---|---|
| AA-1 | 范围 | 库存 + 往来两页本阶段做；单据列表随付款核销阶段 |
| AA-2 | 库存主列 | **在店可售**为主列（低库存告警按它）—— 用户关心「现在还能卖多少」 |
| AA-3 | 低库存告警 | `safety_stock > 0` 且在店可售 ≤ 安全库存 ⇒ 行内**橙色**提示「低于安全库存 N」，不拦人（与 Z-2 同哲学） |
| AA-4 | 库存成本列 | **显示**（core 需补一个批量 `costByProduct()`，避免 N+1）—— 用户关心压货金额；若嫌列多可 v1.1 |
| AA-5 | 往来排序 | 按 \|余额\| 降序，0 沉底 —— 最该看的在前 |
| AA-6 | 往来流水 | **v1 做**（`ofParty` 现成，页面成本低；没有流水的往来列表 = 只能看总数，对不了账） |

### 五、门禁（拟）

core：若 AA-4 采纳，`costByProduct()` + `query_test` / `selfcheck_query` 镜像各一条；
Flutter：`stock_page_test` + `parties_page_test`（沿用 Key 定位 / 沙箱库经验）；
`flutter analyze` 0 issues。

### 二、落地记录（2026-09-28）

**裁定**（`docs/reply.md`）：AA-1/2/5 采纳；**AA-3 改三档颜色**（负库存红 / 低库存橙 /
正常无色 —— 负库存是「账对不上」比「该补货」严重；`safety_stock = 0` 不告警）；
**AA-4 列名改「成本（均价）」+ tooltip 口径说明 + 负值红色**（R-9 超卖会让余值转负）；
**AA-6 `ofParty` JOIN documents**（返回 `PartyFlowEntry`：docNo/docType/amount/occurredAt/
seqNo —— 裸流水时代的 `.length` / `.single.seqNo` 调用**全部兼容**，无需改旧测试）；
7 项遗漏全部处置（🔴 新建/编辑/停用入口、应收应付三态表达；🟡 汇总行、库存排序、
零流水隐藏+开关、流水行不可点+底部说明；🟢 盘点入口 v1 不放记录在案）。

**core 落地**：

| 项 | 内容 |
|---|---|
| `QueryDao.costByProduct()` | `SUM(total_cost)` 批量（`_keyedSum` 同形状）；加权均价口径注释 |
| `PartyLedgerDao.ofParty` 改造 | JOIN documents → `List<PartyFlowEntry>`；不设平行方法 |
| `PartyService.createFull` | 往来方页完整新建（双角色）—— 内部逐 role 走 `ensureParty`，**Z-4 同名保证自动继承**；`ensureParty` 增加 `address`（只在新建写） |
| `PartyService.updateProfile / setActive / flowsOf` | 页面侧编辑资料（不改角色）/ 停用恢复 / 流水查询 |

**Flutter 落地**：`stock_page.dart`（三档 + 主列层级 + 成本 tooltip + 按在店可售
降序 + 零流水隐藏开关 + 搜索）+ `parties_page.dart`（三态余额表达 + 汇总行 +
新建/编辑/停用 + 排序 0 沉底）+ `party_flow_page.dart`（单号/类型/方向字/日期 +
行不可点 + 底部「功能开发中」说明）+ 接线（`AppShell.queries`）。

**门禁**：`typecheck` 26 入口；`selfcheck_query` **26 项**（+6）、`selfcheck_party`
**9 项**（+2）全绿；语法门禁全过。⚠️ 会话管道耗尽 —— `flutter analyze` /
`flutter test`（预期 0 / **35 用例** = 28 + stock 4 + parties 4 + flow 并入）
**待用户复跑**。

**自检期抓出并修正的两处测试错误**：① 超卖测试的 `totalAmount` 与明细和不符
被 B5 拒绝回滚（成本余值纹丝不动）；② 流水单号断言拿内存对象的占位前缀比
—— dispatch 会换成正式单号，应断言「非待同步前缀」。另外 **selfcheck_party
第三次踩跨用例污染**（前面用例建过「王老板」，createFull 复用它 → phone/address
断言失败）—— 独立内存库纪律再次生效。

### 三、复跑 7 issues 修复（2026-09-28）

| # | 问题 | 修法 |
|---|---|---|
| 1 | `app.dart` `QueryDao(db)` —— State 字段是 `_db` | 改 `QueryDao(_db!)`（`AppShell` 分支保证非 null） |
| 2 | `PartyService` **没有 `list()` / `partyBalances()`** —— 页面要用的查询我假定了存在 | core 补两个委托方法（findAll / QueryDao.partyBalances） |
| 3 | `parties_page` 用了 `PartyFlowPage` 却没 import | 补 |
| 4 | `app_shell` 的 `party_flow_page` import 未用（流水页由 parties_page 自己 push） | 删 |
| 5/6 | 两个测试文件残留（未用变量 / 已删声明的赋值） | 清理 |

**共同点**：写页面时**假定了 core 的查询形状**（`service.list()` / `partyBalances()`）
却没先 grep 确认 —— 与采购页 14 issues 的「构造少参数」同类。自查清单再加一条：
**页面用到 `service.xxx()` 的每个方法，先在 core 里确认存在**。

### 四、复跑 2 红修复（2026-09-28）：stock_page_test 两处测试错误

| # | 问题 | 根因 | 修法 |
|---|---|---|---|
| 1 | 三档颜色用例：`sell(6)` 后找不到「低于安全库存 5」 | **页面只在 build 时读库** —— 测试里改了数据却只 `pump()`，页面还是旧数据 | sell 后重新 `pumpWidget(page())` 重挂载（查询页进页面刷新即重读，语义正确） |
| 2 | 零流水用例：`buy(3)` 抛「散采要当场结清」 | 付款金额 `qty * 350 ~/ 100` —— **整数除法截断**：1050 ~/ 100 = 10 元 ≠ 10.50 元，差 5 角被拒（qty=10 时恰好整除没暴露） | 金额用 `Money.format(qty * 350)` 生成精确值 |

**教训（testing.md §O 补）**：测试夹具里的金额一律用 `Money.format(分)`
生成，**不要手写整数除法** —— 截断会在非整除值上静默差钱。

### 五、复跑 1 红修复（2026-09-28）：开关用 CheckboxListTile

「显示全部」开关原来是 `Row(Checkbox + Text)` —— **点文字不会切换 Checkbox**
（两者无关联），测试和真实用户都会点文字。修法：换 **`CheckboxListTile`**
（整行可点），隐藏计数放 `trailing`。

这条同时是**可用性修正**：中老年用户看到「显示全部（…）」的文字，自然反应是
点文字 —— 点不动会当成 bug。规则：**凡是「勾选框 + 说明文字」，一律
CheckboxListTile，不摆裸 Checkbox**。

### 六、复跑编译错修复（2026-09-28）：CheckboxListTile 没有 trailing

`CheckboxListTile` **没有 `trailing` 参数**（那是 `ListTile` 的；它的尾部被
checkbox 本身占用，由 `controlAffinity` 控制位置）—— 张冠李戴。修法：计数放
**`subtitle`**。

**与「service.xxx() 先 grep」同类**：widget 的参数也别凭记忆写 —— Flutter
组件多、同名组件参数集不同（`ListTile` vs `CheckboxListTile` vs
`SwitchListTile`），**用之前查一眼 API**。

---

## AB. 设计提案：录入现有货物（期初建账）（2026-09-28，**待裁定**）

> 用户反馈：开店的用户最需要把**店里已有的货**高效记进来（§AA 真机反馈）。
> 裁定答复请写在 `docs/reply.md`。落地后另开 §AC。

### 一、事实核对：语义上是**一次期初盘点**，RULE-009 已实现

| 能力 | 现状 |
|---|---|
| `_stocktake`（RULE-009） | ✅ `lines.quantity` = **实际数量**；diff 生成流水；盘盈成本走 `surplusCost` |
| 成本口径（`surplusCost`） | 有历史 → 加权均价；**无历史（新店首录）→ 成本 0** |
| 与采购的区别 | 期初录入没有真实交易：没有供应商、没有付款 —— **走采购单语义不对**（凭空造一笔「欠供应商」或「付款」） |
| `dispatch` 签名 | `stocktakeActual: Map<String, int>`（实际数量表），直接可用 |

**结论**：期初录入 = 「把实际有多少告诉系统」= 一次盘点单。**零新规则**。

### 二、UI 设计（入口在库存页）

库存页右上角（或列表空态）加 **「录入现有货物」** 按钮 → 期初录入页：

| 元素 | 内容 |
|---|---|
| 说明文案 | 「开店时店里已经有的货，在这里一次记入。以后按采购/销售正常记，不用再管这一页。」 |
| 行结构 | 与采购开单同构：**选商品（搜索/新建）+ 数量**；可加多行 |
| 提交 | 一张盘点单（多行合一）；提交后跳回库存页，数字立刻可见 |
| 撤销 | RULE-009 约束「盘点提交后不可撤销」—— **UI 上要明说**：提交前确认弹窗（重大操作，§1.2），说清「数量记入后不可撤销，发现错了再盘一次」 |

### 三、待裁定项

| # | 问题 | 我的建议 |
|---|---|---|
| AB-1 | 走盘点单（复用 RULE-009 零新规则）还是新规则「期初单」 | **盘点单**。语义完全匹配；新规则要动引擎 + 同步白名单，成本高收益低 |
| AB-2 | 成本 | **v1 按 0 记**（无历史时 `surplusCost` 就是 0），录入页**明说**「期初成本按 0 记，库存金额会偏低；下次采购时进价会校准成本」。用户真在意期初成本 ⇒ 待裁定扩 RULE-009（改 core 规则，不建议 v1 做） |
| AB-3 | 重复录入 | 用户忘了已经录过又录一遍 ⇒ 数量是**实际数量语义**（不是累加），第二遍会把库存改回去 —— 录入页顶部提示「这里填的是**实际有多少**，不是新进了多少」，并在已有库存的商品行内显示当前账面数 |
| AB-4 | 多行数量上限 | 不设（一页滚动到底）；商品多的店分几次录也行（盘点本来就可以多次） |

### 四、门禁（拟）

core 零改动（纯 UI + `stocktakeActual` 组装）；Flutter `opening_stock_page_test`
（沿用沙箱库 + Key 定位经验：录入两件 → 库存页数字正确 / 已有库存商品显示账面数 /
提交确认弹窗）；`flutter analyze` 0 issues。

---

## AC. 设计提案：v1 界面收尾 —— 帮助 / 设置 / 期初录入 / 单据列表（2026-09-28，**待裁定**）

> 用户：「单据、设置和帮助界面没做了，继续前进」。本提案把剩余三页 + §AB 期初录入
> 合并为**v1 界面收尾阶段**。裁定答复请写在 `docs/reply.md`。落地后另开 §AD。

### 一、事实核对

| 页 | core/包现状 |
|---|---|
| 帮助 | 纯静态，零依赖 |
| 设置 | ✅ `AppConfig{dataDirectory, uiScale, shopName}` + `UiScale` 五档 + `AppConfigStore` 全就绪；⚠️ **`uiScale` / `shopName` 目前零消费**（存了没用）；导航宽度 API `AppNavigation.widthFor(scale:)` 已有 |
| 期初录入 | §AB 已提案（RULE-009 盘点复用，零新规则），**尚未裁定** |
| 单据列表 | ⛔ `DocumentDao` 无列表查询（§AA 已核对）；对方名需要 join parties；**付款核销/退货入口不在本阶段**（§Z 七声明随核销阶段） |

### 二、建议落地顺序（按大小递增）

| # | 内容 | 量级 |
|---|---|---|
| 1 | **帮助页**：四步上手（建商品 → 采购 → 销售 → 看库存/往来）+ 常见问题（数据在哪 / 忘了密码不存在 / 换电脑）+ 「找谁反馈」占位。纯静态 | 小 |
| 2 | **设置页**：界面缩放五档（`UiScale`）+ 店名（可选）+ 数据位置只读展示 | 中 |
| 3 | **期初录入页**（§AB，按裁定） | 中 |
| 4 | **单据列表页**（只读）：类型筛选 + 日期倒序 + 单号/类型/对方/金额/状态 | 大 |

### 三、待裁定项

| # | 问题 | 我的建议 |
|---|---|---|
| SC-1 | **缩放作用范围** | **全局文字缩放**（`TextScaler`，中老年用户的本命功能）+ 导航宽度联动（`widthFor(scale:)` 现成）。只缩导航没有意义 |
| SC-2 | 店名用途 | **概览页顶部显示**（「王记小卖部」替代「概览」标题）；不填则维持现状。字段已有，采集零成本 |
| SC-3 | 单据列表排序/筛选/分页 | 日期降序；类型 chips（全部/采购/销售/收款/付款）；`limit 200` **不做分页**（个体户单据量级，v1 够用） |
| SC-4 | 单据行点击 | **不可点** + 底部灰字「单据详情开发中」（同流水页模式）；详情/退货/核销随下一阶段 |
| SC-5 | 期初录入（§AB）是否并入本阶段 | **并入**（用户点名），顺序在单据列表之前 |
| SC-6 | 对方名列 | 单据列表显示对方名需要 join parties —— **显示**（`ofParty` 经验：JOIN 一次拿全，不逐条查） |

### 四、门禁（拟）

core：`DocumentDao.listDocuments({DocType? type, int limit})`（JOIN parties 取对方名）
+ `document/query` 测试与 selfcheck 镜像；设置页的缩放/店名接线用 `configStore`
沙箱测试。Flutter：各页 widget 测试 + `flutter analyze` 0 issues。交付前我侧自验
（管道恢复时）。

### 三、落地记录（2026-09-28）：帮助 / 设置 / 单据列表三页

§AB + §AC 裁定全部采纳（AB-2 三层处理、AB-3 实时差额、AB-4 分批说明、5 项
§AB 遗漏、SC-1~6 含修正、6 项 §AC 遗漏）。**本批落地三页**（期初录入随下一批，
§AB 已裁定齐）：

| 页 | 裁定落点 |
|---|---|
| `help_page.dart` | 四步上手（**期初录入选第一步** + emoji 锚点，遗漏 4）；FAQ 含「期初成本为什么 0」（AB-2 第三层）；反馈入口给**真实地址**（GitHub issues + 邮箱，遗漏 3）；版本号底部（遗漏 6） |
| `settings_page.dart` | 缩放五档改档**立即生效**（全局 `TextScaler` + 导航宽度联动，SC-1）+ **「恢复默认大小」一键重置**（遗漏 2）；店名 ≤ 20 字（SC-2）；**数据安全区**（遗漏 1）：位置/备份目录 + 「打开文件夹」—— ⚠️「立即备份」按钮 v1 不放（备份执行机制未实现，空按钮比不做糟） |
| `documents_page.dart` | 时间 chips（默认**最近 30 天**，SC-3 修正）+ 类型 chips + 对方名（JOIN，散客/散采显示文字，SC-6）+ **行点击复制单号**（SC-4 修正）+ 「全部」档 200 条提示 |
| `app.dart` / `app_shell.dart` | `uiScale` → 全局 `TextScaler` + 导航 `widthFor(scale:)`；`shopName` → 概览页顶部大字；`configStore` / `onConfigChanged` 接线（改配置热应用）；`DocumentDao(_db!)` |

**core**：`DocumentDao.listDocuments({type, sinceMillis, limit})` JOIN parties
（`DocumentSummary{document, partyName}`，散客 null → UI 文字）。

**门禁**：语法全过；`typecheck` 26 入口。⚠️ 管道耗尽 —— **analyze / test 待用户
复跑**（新增 help 4 + settings 4 + documents 5 = 13 条用例）。

**自查期修掉的一个隐患**：SettingsPage 连续修改互相覆盖（每次基于打开时快照）
→ 内部持 `_current` 副本，改哪项都基于最新值。

### 五、复跑返工记录（2026-09-28）：§AC 三页测试收尾

三轮返工，49/49 全过（analyze 0 issues）。根因分三类，均有沉淀：

**编译层（第一轮）**：
- core 桶文件 `show DocumentDao` 漏了新类型 `DocumentSummary` —— **新增 DAO
  返回类型必须同步加进桶文件清单**
- `documents:` 参数被误插进 Purchase/SaleService 构造内部（缩进错位暴露）
- OverviewPage 加了 `shopName` 字段但构造函数漏参数

**测试与页面语义错位（第二、三轮）**：
- 行内对方名是插值串（`王老板 · 日期`）→ `find.text` 精确匹配必 0 命中，
  一律 `textContaining`
- chip 文案写错：`DocType.sale.label` = 「店内销售」不是「销售开单」——
  **枚举 label 必须从模型定义抄**；且行内也渲染同文案 → tap 一律
  `find.ancestor(of: text, matching: ChoiceChip)` 定位
- `await Clipboard.setData` 在 widget 测试里 Future 永不完成 → SnackBar 永远
  出不来 → 改 `unawaited`（平台通道 await 挂死类，第 3 次踩）
- `maxLength: 20` 让店名超长提示成死代码（输入阶段就截断）→ 删，放手输 +
  提示不落盘（SC-2 原意）
- 数据安全区按裁定补全为「位置 / 备份目录」两行（`SettingsPage` 加
  `backupDirectory`，AppShell 从 `DataLocation` 传入）
- 帮助页测试断言旧邮箱 —— 用户已改联系方式（163 邮箱 + xgopilot 仓库）未同步
  → 测试断言跟进
- 「王老板 found 2」**不是 bug**：立即付款自动生成独立收/付款单（继承主单
  对方与日期，创建即 settled），单据页如实列出 → 断言 `findsWidgets`；
  夹具日期错开消除排序赌局

---

## AD. 设计提案：期初录入页落地（2026-09-28，**待裁定**）

> §AB 已裁定齐（走盘点单 / 成本按 0 / 实际数量语义 / 不设行数上限）。
> 本提案只做**落地形态**的事实核对与拆解。裁定答复请写在 `docs/reply.md`。

### 一、事实核对（本轮补充）

| 事项 | 现状 |
|---|---|
| RULE-009 引擎入口 | `dispatch(document, lines, stocktakeActual?, now)`；`totalAmount` 必须 0；`quantity` = 实际数量；diff=0 不产生流水；**不写** PartyLedger / MoneyLedger |
| 单号 | 页面传占位号，引擎 `_prepare` 换正式单号（`PD` 前缀）——与采购/销售同构 |
| 错误形态 | 规则拒绝走 `RuleOutcome.rejected`（整单回滚），UI 走「意外失败」兜底——采购页同款 |
| 商品选择器 | 采购页、销售页**各有一份私有** `_ProductPickerSheet`（未抽共享）——期初页要么复制第三份，要么先抽共享 |
| 库存页空态 | 现文案「先到采购入库进一批货」与帮助页「期初录入选第一步」**矛盾**，本批顺手改 |
| 当前账面数 | `QueryDao.stockByProduct()` 现成（库存页在用），AB-3 行内显示账面数零成本 |

### 二、落地拆解

| 部分 | 内容 |
|---|---|
| core（视 AD-1） | `StocktakeDraft`（行 = 商品 + 数量原文；`validate()`：至少一行 / 数量正整数 / 同商品不重复）+ `StocktakeService.create()`（组装盘点单 → dispatch → 按 id 读回，镜像 PurchaseService 形态）——**规则零改动**，只是把「组装 + 校验」从 Flutter 挪进纯 Dart |
| `opening_stock_page.dart` | 顶部说明文案（AB-2：「期初成本按 0 记……下次采购时进价会校准」+ AB-3：「这里填的是**实际有多少**，不是新进了多少」）；行 = 选商品 + 数量 + **当前账面数灰字**；提交前确认弹窗（不可撤销，§1.2 重大操作）；成功后 SnackBar（单号）+ 返回库存页 |
| 库存页接线 | 标题行加「录入现有货物」按钮（`stockPage` 需要拿到 engine——经 `AppShell`/`app.dart` 传入）；空态文案改为引导期初录入 |
| 测试 | core：`stocktake_service_test` + selfcheck 镜像（两套并行纪律）；Flutter：`opening_stock_page_test`（录两件 → 库存页数字正确 / 账面数显示 / 确认弹窗 / 空行报错） |

### 三、待裁定项

| # | 问题 | 我的建议 |
|---|---|---|
| AD-1 | 组装+校验放哪 | **core 薄服务**（`StocktakeDraft` + `StocktakeService`）。§AB 说「core 零改动」指**规则**零改动；校验判断按铁律应放纯 Dart 可 `dart test`。代价：core 加两个文件（纯增量） |
| AD-2 | 商品选择器第三份复制 vs 先抽共享 | **v1 复制一份**（与采购/销售现状一致，不碰已验证页面）；抽共享列后续重构阶段单独裁定。三份重复的账记在 reply_review，重构时不至于漏 |
| AD-3 | 同商品选两行 | **校验拒绝**（「该商品已在列表」）。盘点语义下行内两笔「实际数」无法合并出正确答案，采购页允许多行是成本累加语义，这里不同 |
| AD-4 | 单据日期 | **固定今天，不可改**。期初录入就是「现在建账」，给日期字段只会多一个能填错的地方（与设置页「改完立即生效」同款判断） |
| AD-5 | 提交后去向 | SnackBar 报单号 → `Navigator.pop` 回库存页（数字立刻可见）；弹窗文案：**「数量记入后不可撤销。发现录错了，再来这一页重新盘一次就行。」** |
| AD-6 | 库存页空态文案 | 改为「店里有现成的货？先点右上角『录入现有货物』；进货走『采购入库』。」——与帮助页四步对齐 |

### 四、门禁（拟）

core：`dart test`（`stocktake_service_test` 新增 + selfcheck 镜像同步，`typecheck` 入口表更新）；
Flutter：`flutter analyze` 0 issues + `opening_stock_page_test`（5 条：空行报错 /
录两件后库存页数字正确 / 已有库存商品显示账面数 / 确认弹窗取消不动账 / 确认后
SnackBar + 返回）。交付前我侧自验，其余按老规矩用户复跑。

### 六、落地记录（2026-09-28）：§AD 期初录入（core + Flutter 一批交付）

裁定全采纳（AD-1~6 + 6 项遗漏 + 3 条实现建议）。**core 第一批已由用户复跑 dart test 全过**，
本批把 Flutter 层一并落地：

| 文件 | 落点 |
|---|---|
| `stocktake_draft.dart` / `stocktake_service.dart`（core，已过） | AD-1 薄服务 / AD-3 重复行拒绝 / AD-4 主机时钟 / `changedCount·unchangedCount` |
| `QueryDao.hasAnyStockLedger()` / `inboundProductIds()`（core，已过） | 遗漏 1「待校准」/ 遗漏 2「首次/再次」的数据口径 |
| `opening_stock_page.dart` **新** | 标题首次/再次（遗漏 2）；AB-2/AB-3 说明文案；行内账面数 + 实时差额（建议 1）；确认弹窗 AD-5 裁定文案（摘要 + 「记下之后不能取消」）；**遗漏 4：失败一律不清输入**；SnackBar 建议 2 两态（全无变化给诚实反馈）；取消 §X-3 同构；选择器复制第三份：**空查询 = 全部商品**（AD-2 点名的真实差异）+ 新建入口共用 `showProductFormDialog`（遗漏 3） |
| `stock_page.dart` | 标题行入口按钮（首次「录入现有货物」/ 再次「重新清点」）；成本三态「未进货 / 待校准（灰 + tooltip）/ 金额」；空态两段式（AD-6）；就地切换到期初录入页（完成后 setState 刷新数字，左侧导航不消失） |
| `app.dart` / `app_shell.dart` | `engine` 挂到 AppShell（null → 库存页占位，与 services 同款判定） |
| 测试 | `opening_stock_page_test` 7 条（空表单拦截 / 差额三态 / 弹窗摘要 + 成功链路 / 诚实反馈 / 重复行 + 状态保留 / 取消确认 / 选择器全部商品）；`stock_page_test` +2 条（待校准含校准后恢复 / 入口文案切换）+ 空态新文案 |

**门禁**：`dart format --output=none` 无语法错。⚠️ analyze / test 待用户复跑
（预期 analyze 0 issues；test 49 + 7 + 2 = 58 用例）。

**AD-2 重构期限（裁定原文存档）**：`_ProductPickerSheet` 已出现**第三份**
（采购 / 销售 / 期初录入）。**第四处出现时强制抽共享；在此之前，任何一份的
bug 修复必须同步三处。**

**遗漏 6（记录在案）**：期初录入页每行一个 `TextEditingController`，500 商品
级别会慢 —— v1 接受此限制，重构阶段换懒加载行。

**帮助页四步**：核对过 —— 第一步已是「录入现有货物」，与新空态文案一致，
无需改动（遗漏 5 关闭）。

### 七、复跑返工与收官（2026-09-28）：§AD 期初录入

**analyze 0 issues + test 58/58 全过**（用户复跑确认）。三轮小返工，均为测试/一行级：
1. `isDense` 写在 `InputDecorator` 层（应为 `decoration.isDense`）—— widget 参数查 API 家族
2. 测试夹具没点「加一行」就填第二行（页面初始行数 = 1）—— 夹具步骤与初始状态对齐
3. **产品级**：确认弹窗前置了校验 —— `_save` 先跑 `draft.validate()`，不过就地报错，
   弹窗只在草稿整体合法时出现（「不可能通过的内容不该先问确认」）；
   `service.create` 内的二次校验保留（防御纵深）

**v1 界面收尾全部完成**：概览 / 商品 / 采购 / 账户 / 销售 / 库存 / 往来方 / 帮助 /
设置 / 单据 / **期初录入** —— 十一个入口全部实装，无「正在开发」占位残留
（`_PendingPage` 仅剩「数据库未就绪」兜底用途）。

---

## AE. 设计提案：备份执行机制（2026-09-28，**待裁定**）

> reply.md 裁定：备份优先于核销 —— 「用户不会在一个数据看起来随时会丢的软件里
> 认真录入一个月的账」。裁定已给的框架：每天首次启动检查、ZIP、保留 30 天、
> 加密不做、恢复 v1 无 UI。本提案做事实核对 + 落地形态，含糊处列待裁定。

### 一、事实核对

| 事项 | 现状 | 影响 |
|---|---|---|
| 备份执行代码 | **零**——现有只有「算出备份目录路径」（`DataDirectoryPolicy.backupDirectoryFor`，数据目录的兄弟目录「神算子备份」）和设置页/概览页的文案 | 全新模块，落 `shensuanzi_app`（纯 Dart 可测，铁律） |
| **数据库是 WAL 模式** | `PRAGMA journal_mode = WAL`（database.dart:32，断电安全性基础） | **直接拷 .db 文件会丢未 checkpoint 的事务**！备份前必须 `PRAGMA wal_checkpoint(TRUNCATE)` 再拷，这是本模块最重要的技术点 |
| 数据目录内容 | `shensuanzi.db` + 标记文件（DataMarker） | 备份内容二选一：仅 db / db + 标记 |
| 依赖 | `archive` 包（纯 Dart）未引入 | ZIP 需要新增依赖（shensuanzi_app pubspec） |
| UI 挂点 | 设置页数据安全区已有「位置/备份目录」两行（§AC 遗漏 1 落地时预留）——**「立即备份」按钮 v1 有意没放**（当时机制未实现，空按钮比不做糟） | 本批补按钮 + 上次备份时间显示 |
| 启动挂点 | `app.dart._openDatabase` 成功后 | 自动备份检查在此触发；**失败不阻塞启动** |

### 二、落地形态

| 部分 | 内容 |
|---|---|
| core... 不，`shensuanzi_app/lib/src/backup.dart`（新，纯 Dart） | `BackupService`：① `shouldAutoBackup(now, lastBackup)` 纯函数（>24h）；② `run()`：checkpoint → 打包 ZIP（按 AE-4 裁定内容）→ 落备份目录 → 按保留策略清理旧包；③ `lastBackupTime()` 读目录里最新包的时间戳 |
| 保留策略（AE-2 裁定） | 删 30 天前的每日包；**每周一份长期保留**（「最坏情况的最低保障」）——具体规则见待裁定 |
| 启动接线（`app.dart`） | 开库成功后异步触发：`shouldAutoBackup` → `run()`；**任何失败只记状态，不弹窗不阻塞**（用户马上要用软件） |
| 设置页 | 数据安全区加「立即备份」按钮（点击执行 + SnackBar 结果）+「上次备份：xx（自动/手动）」一行；备份中禁用按钮 |
| 帮助页 | FAQ 补「数据备份与恢复」：备份在哪、怎么恢复（解压把 `shensuanzi.db` 拷回数据目录）——**逃生门不是日常功能** |
| 测试 | `backup_test.dart`（`shensuanzi_app` 的 dart test）：checkpoint 后拷贝完整 / 命名与时间戳 / 保留策略边界（30 天、周保留）/ `shouldAutoBackup` 边界 / 失败不抛穿；selfcheck 镜像；设置页 widget 测试（按钮 + 状态显示，备份动作注入桩） |

### 三、待裁定项

| # | 问题 | 我的建议 |
|---|---|---|
| AE-1 | ZIP（新依赖 `archive`）vs 直接拷 `.db` 文件 | **直接拷 db 文件**（命名 `shensuanzi-20260928-1530.db`）。理由：单个 SQLite 文件**本身就是开放格式**，用户拖进任何 SQLite 工具都能看；ZIP 反而多一步解压，且引入依赖。reply.md 提 ZIP 的理由是「用户能自己打开看」——裸 db 文件同样满足且更彻底 |
| AE-2 | 保留策略细则 | **30 天内的每日包 + 每个自然周最早的一份长期保留**（不删）。判断纯函数可测。备选：滑动窗口「最近 30 份每日 + 最近 12 份每周」，不按自然周锚定——个体户不关心周一还是周四，窗口制实现更简单也更直观 |
| AE-3 | 自动备份时机 | 每天首次启动（距上次备份 >24h 触发），**失败完全静默**（设置页能看到「上次备份：从未/时间」，红色提示超过 3 天未备份）。备选：失败弹一次非阻塞提示 |
| AE-4 | 备份内容 | **仅 `shensuanzi.db`**（checkpoint 后单文件完整）。标记文件恢复时自动重建，不备；config 在 %APPDATA%，本就是设备偏好不在备份范围 |
| AE-5 | 「上次备份」状态显示 | 设置页显示时间 + 来源（自动/手动）；**超 3 天未备份红色提醒**（数据安全的可视化，呼应「可信赖」定位） |
| AE-6 | 恢复路径 | v1 无恢复 UI；帮助页 FAQ 写清三步（关软件 → 解压/拷贝备份的 db 到数据目录覆盖 → 重开）。**要不要在设置页加「从备份恢复」按钮**：v1 不做（覆盖现有数据是高危操作，做错就是灾难；逃生门用文件操作已够） |

### 四、门禁（拟）

`shensuanzi_app`：`dart test`（backup_test 新增 + 既有 26 用例不回归）；selfcheck 镜像
（typecheck 入口表更新）；根应用 `flutter analyze` 0 + 设置页 widget 测试（按钮/状态/
注入桩不真拷贝）。交付前我侧自验，用户复跑。

### 八、§AE 落地记录（2026-09-28）—— ⚠️ 本批中止，待通道恢复

**状态**：纯 Dart 第一批写到一半，AI 侧工具通道开始返回不可信内容（文件读取
返回编造内容、一次 Write 内容发岔），已停止编辑避免污染仓库。

**已发生的改动（以 git status/diff 为准，未提交）**：
1. `shensuanzi_core/lib/src/dao/query_dao.dart` —— 追加 `hasAnyDocument()`
   （遗漏 1 空库判定，内容正确，纯增量）
2. `shensuanzi_app/lib/src/backup.dart` —— 新文件；第一版残缺后已用完整实现
   **覆盖**，但未经 typecheck 验证，**需人工核对或直接丢弃重写**
3. 桶文件导出编辑（shensuanzi_app.dart）—— **最可疑，建议直接 checkout 丢弃**

**处置**：`git checkout -- <可疑文件>` 丢弃即可，裁定与设计全在本台账，不丢失。
通道恢复后按本节重写。

**裁定整合清单（reply.md §AE 审查，落地时逐条对照）**：
- AE-1 ✅ + 加固：副本 `PRAGMA integrity_check`，失败删残件（必做）
- AE-2 ✅ 主方案自然周锚定 + 手动包不参与清理（`m-` 前缀，同分钟防连点）
  + 周代表边界三例（仅周三/仅周日/零备份）
- AE-3 ✅ 改两层：单次失败静默 + **超 3 天概览页橙卡**（用户不会主动开设置页）
- AE-4 ✅ 文件名带 schema 版本：`shensuanzi-schema1-YYYYMMDD-HHMM.db`
- AE-5 ✅ 状态行可点开备份目录（_FolderRow 已有「打开」位）
- AE-6 ✅ FAQ 六步恢复（含「改名 .bak 再粘贴」心理安全带）
- 🔴 遗漏 1 空库不自动备份（`QueryDao.hasAnyDocument()`，手动不受限）
- 🔴 遗漏 2 目录可写探测（建目录+探针文件）；磁盘余量检查纯 Dart 不可得 →
  拷贝失败路径兜底（降级记录在案）
- 🔴 遗漏 3 并发串行化（`_running` Future 复用）
- 🔴 遗漏 4 tmp + rename 原子化 + 清 .tmp 残留
- 🟡 遗漏 5 SnackBar 带完整路径 / 遗漏 6 备份区说明文案 / 遗漏 7 文件名本地时间 /
  遗漏 8 同盘风险 FAQ 明说 / 遗漏 9 时钟回跳容错
- 🟢 遗漏 10 README.txt 记录不做 / 遗漏 11 按钮防抖（busy 禁用 +「备份中…」）

**数据导出建议（用户新提，§AF 候选待提案）**：Excel/CSV/PDF 导出，
「导出后的数据不再受神算子控制」。排序待裁定：备份之后、核销之前/之后。

**下一步（通道恢复后）**：重写 backup.dart（按本节清单）→ backup_test +
selfcheck 镜像 → 桶文件导出 → 用户复跑 dart test → Flutter 批（启动接线 /
设置页按钮 / 概览橙卡 / 帮助 FAQ）。

### 九、§AE 落地记录（2026-09-28）：第一批（纯 Dart 层）✅

通道恢复，backup.dart 按裁定清单重写完成。**门禁（我侧）**：
- core typecheck 28 入口 ✅（`QueryDao.hasAnyDocument()` 已在库）
- app typecheck 10 入口 ✅（backup.dart / backup_test.dart / selfcheck_backup.dart 全编译）
- **selfcheck_backup 25 过 0 挂**（真实文件库）：WAL checkpoint 回归探针（副本里查得到
  checkpoint 前的单据）/ integrity_check / 同分钟防连点 / 单飞 Future（identical）/
  保留策略（周代表豁免、手动包保留、恰好 30 天严格 <）/ 残留 .tmp 清理 / 时钟回跳
  重触发 / 目录不可写 failure
- `dart test`：被会话管道耗尽拦（CreateFile 231，加载器无法 spawn 编译器；typecheck
  已证实测试文件编译通过）→ **用户复跑**

**交付物**：
| 文件 | 内容 |
|---|---|
| `shensuanzi_app/lib/src/backup.dart` | `BackupFileName`（解析/生成，`m-` 前缀）· `shouldAutoBackup`（>24h/首次/时钟回跳）· `expiredAutoBackups`（30 天严格 < + 周代表豁免 + 手动包永不清理）· `BackupService`（checkpoint → 拷 tmp → integrity_check → rename；可写探测；单飞；保留清理）|
| `shensuanzi_app/test/backup_test.dart` | 21 用例（文件名 4 + 判定 5 + 保留 6 + 集成 8，含并发 identical 与时钟回拨重触发）|
| `shensuanzi_app/tool/selfcheck_backup.dart` | 降级门禁镜像（25 检查）|
| `shensuanzi_app/lib/shensuanzi_app.dart` | 桶导出（BackupFileName/Outcome/Service + 3 个纯函数）|
| `shensuanzi_core/lib/src/dao/query_dao.dart` | `hasAnyDocument()`（用户保留的那份，已在库）|

**落地中抓到并修掉的真 bug（selfcheck 门禁的价值）**：
1. 单飞缺陷：`_run` 原本存原始 Future、返回 whenComplete 包装 → 并发方拿到不同
   Future。改为**存包装后**的（identical 可测）
2. **dedupe 跳过路径没跑保留策略** —— 手动备份先建了同名包后，后续备份命中
   「同名跳过」提前返回，`.tmp` 残留与过期包清理全被跳过。修为：跳过重拷
   **不跳过清理**
3. selfcheck 空库断言直接 listSync 不存在的目录（skipped 路径不建目录是正确
   行为）→ 断言改防御式

**§AF 导出（用户裁定）**：备份之后、核销之前；现阶段 CSV；Excel 视观感后续定；
PDF 仅打印。详细提案待备份真机验证后出。

**下一步（第二批，Flutter 层）**：app.dart 启动接线（autoBackup，失败静默）/
设置页「立即备份」+ 状态行 / 概览页橙卡（超 3 天）/ 帮助页六步恢复 FAQ。
用户复跑：`cd packages/shensuanzi_app && dart test && dart run tool/selfcheck_backup.dart`

### 十、§AE 第一批复跑返工（2026-09-28）：4 处夹具目录缺失

用户复跑 169 过 4 挂，失败全部是**测试夹具**的同类疏漏（与 selfcheck 里修过的
目录问题同根因，测试文件漏了对应四处）：
1. 手动备份空库 / 同分钟防连点：`Db.open('empty/shensuanzi.db')` 前没建
   `empty` 目录（code 14）
2. 残留 .tmp / 保留策略集成：写哑文件前没建 `backupDir`（PathNotFound）

修法：四处补 `createSync(recursive: true)`。已修，待用户复跑
（我侧 dart test 被管道耗尽拦；typecheck 已证实编译通过）。

**教训沉淀**：`Db.open` 在目录不存在时报 code 14 而不是自动建目录；
写文件前置目录创建。§AE 第二批（Flutter 接线）的启动接线里同样适用
——**数据目录由启动流程保证存在，备份/导出目录在服务内建**（backup.dart
的可写探测已含 createSync，无需调用方预建）。

### 十一、会话收尾状态（2026-09-28 晚）

- 用户已核查并 `git checkout -- lib/src/app.dart`：本批计划外的混入编辑已还原，app.dart 干净。
- **§AF 导出裁定（权威）**：备份之后、核销之前；现阶段 CSV；Excel 视使用观感后续定；
  PDF 属不可二次修改文件、仅用于打印（用于打印另立功能，不进导出）。
- **§AE 第二批（Flutter 接线）未开始**，实施方案：backup.dart 补 `latestBackupFile()` +
  `needsBackupAttention()`（⚠️ 本会话末尾已写入但**未经编译验证**，新会话先跑
  typecheck+test 确认）；app.dart 启动接线（autoBackup 静默 + _manualBackup 回调）；
  app_shell 透传；overview 橙卡（StatefulWidget 化）；settings 备份区；help FAQ 两条；
  测试补齐。详见会话总结。
- **新会话第一步**：`cd packages/shensuanzi_app && dart run tool/typecheck.dart && dart test`
  验证现状，再动第二批。

### 十二、§AE 第二批落地（2026-09-28）：Flutter 接线 + 镜像回填

**承接 §十一的「新会话第一步」**：先验现状 —— `app typecheck 10 入口 ✅`（上一会话末尾
写入的 `latestBackupFile()` / `needsBackupAttention()` 编译无误，**不用重写**）。

**⚠️ 本会话的验证通道收窄**：`dart test` / `flutter analyze` / `flutter test` **全部**
被 `CreateFile failed 231（所有的管道范例都在使用中）` 拦住。本会话实测
`Process.runSync('where', …)` 最小用例同样失败 ⇒ **创建不了任何子进程**
（不是 flutter 的问题；上会话的「已解除」结论只在正常会话里成立）。
⇒ 我侧门禁 = `dart run tool/typecheck.dart` + `tool/selfcheck_*.dart` + `dart format
--output=none`（只验语法）；**analyze / test 一律由用户复跑**。
⚠️ 另：`dart run` **编译不了 import `package:flutter` 的文件**（`dart:ui is not
available on this platform`）⇒ **根 `lib/` 没有任何我侧可达的编译门禁**，
Flutter 层只能语法检查 + 人工核对 + 用户 `flutter analyze`。

#### 一、纯 Dart 层（判断与文案，`dart test` 可覆盖）

| 落点 | 内容 |
|---|---|
| `needsBackupAttention` **加 `lastFailure`** | **唯一**的判定入口。原为「空库 → 不提醒；从未 / 超 3 天 → 提醒」，本批补上 **§AE 遗漏 2 的失败分支**：最近一次尝试就失败 → **立刻提醒**（优先级在「几天没备份」之上）。空库仍然压倒一切（没数据可丢） |
| +`daysSince` / `formatBackupTime` / `backupStatusLine` | 人话：从未 / 今天 09:05 / 昨天 21:30 / 9月25日 08:12。**按自然日**算（昨晚 23:00 备份 → 今天显示「昨天」），本地时间（遗漏 7） |
| +`backupReminderText` | 橙卡文案；**非空 ⟺ `needsBackupAttention`** —— 与设置页红字同源。失败时直接说「上次备份没成功：<领域层写好的怎么办>」 |
| +`backupOutcomeMessage` | 手动备份结果文案（遗漏 5）：成功带**完整路径**，失败直接用领域层的「怎么办」 |
| `BackupService._execute` 加固 | **备份目录「建不出来」也走「说怎么办」那一族**（原来只兜住「探针写不进」）：目录被删、被设只读、**或路径上蹲着一个同名文件**（U 盘拔了/被人改名）都会落到 `File.copySync` 前的通用 catch，文案不指向备份目录。selfcheck 逮到的真问题 |

> ⚠️ **中途砍掉的一版设计（记录在案）**：本批先写了 `BackupStatus` 值对象 +
> `BackupService.status({hasDocuments})`，让服务把「最新一份 + 要不要提醒」一起算出来。
> 自查时发现它会变成**第二处判定**（服务在「读状态时」算一次，应用在「重绘时」也要算
> 一次才能跨天自洽），而且 UI 实际用的是应用层那次 ⇒ `BackupStatus.needsAttention`
> 是死代码。**已整体删除**，改为：应用只存 `BackupFileName? _lastBackup` +
> `String? _backupError`，**判定只在 build 里问 `needsBackupAttention` 一次**。
> 教训：值对象里塞「判定结果」时，先问「这个结果谁来消费」——没人消费就是两处口径。

#### 二、Flutter 层（只摆放）

| 文件 | 落点 |
|---|---|
| `app.dart` | 开库成功后建 `BackupService`；`_refreshBackupStatus()`（**只在启动与每次备份后**读 `latestBackupFile()` + 空库判定，不放 build —— 目录列举是 IO）；`unawaited(_autoBackup())`（**先让出一次事件循环**：拷贝是同步的，别卡启动那一下）；`_backupNow()` 手动路径（auto/manual **共用同一 service ⇒ 共用单飞锁**，遗漏 3）。**`_noteBackupOutcome`：`ok` 与 `skipped` 都算没事**（「库还是空的」「不足 24h」是设计内跳过，记成失败会让橙卡天天喊）。UI 只拿到**算好的字符串** |
| `app_shell.dart` | 透传 `backupStatusLine` / `backupNeedsAttention` / `backupReminder` / `onBackupNow`；帮助页带上两个**真实**目录 |
| `overview_page.dart` | **StatefulWidget 化**（§十一 拟定）：橙卡（AE-3 两层机制上层）+「立即备份」；文案来自纯 Dart，本页不造句 |
| `settings_page.dart` | 备份区：「上次备份：时间（来源）」+ 需要提醒时**红字**（AE-5；失败时这一行改说「上次备份没成功：…」）+「立即备份」按钮（遗漏 11：点了立刻禁用 +「备份中…」）+ 两行说明（遗漏 6，含 §AE-1 的「普通数据库文件」承诺）。**删掉原「每天关店前软件会提醒备份」—— 与实际行为不符** |
| `help_page.dart` | FAQ 两条：§AE-6 **六步恢复**（带真实路径 + 「先改名成 .bak 再粘贴」）+ 遗漏 8 **同盘风险坦白**。没传路径就退回「到设置页看」，**不编造路径** |

**一个设计取舍（请复看）**：`backupReminder` / `backupStatusLine` 由 `app.dart` 在
`build` 里调纯函数算出后**以字符串下传**，页面完全不碰时钟。好处是 widget 测试只断言
「摆得对不对」，文案边界（4 天 / 恰好 3 天 / 空库）只在 `dart test` 里钉一次 ——
两处各算一遍正是 §AE 明令避免的漂移源。

**按钮防抖放在页面自持 `_busy`**（遗漏 11）：服务侧单飞是**兜底**，不是替代 ——
用户点下去必须立刻看到「我的操作被接受了」。测试里用 `Completer` 卡住 Future，
断言「第二次点击不触发回调」。

#### 三、镜像回填（两套并行断言的欠账）

本批新增断言时**顺带清掉两处既有漂移**（`test/**` ↔ `tool/selfcheck*.dart`）：

1. `backup_test` 有、`selfcheck_backup` **没有**：残留 `.tmp` 清理、备份目录不可写 —— 已补（25 → 42 项）
2. core 侧 `QueryDao` 的三个存在性判定 `hasAnyDocument`（§AE 遗漏 1）/
   `hasAnyStockLedger` / `inboundProductIds`（§AD 遗漏 1、2）**从未有镜像断言**
   —— `query_test.dart` + `selfcheck_query.dart` 一并补上（26 → 30 项）

#### 四、测试（新增 16 条）

| 文件 | 条数 | 内容 |
|---|---|---|
| `test/overview_page_test.dart` | **新 6** | 无提醒不摆卡 / 有提醒摆卡 / 备份不可用不摆空按钮 / 点击→回调+SnackBar 带路径 / 失败说「怎么办」 / busy 防连点 |
| `test/settings_page_test.dart` | +4 | 状态行 + 说明文案 + SnackBar 路径 / 需要提醒时红字（且正常不刷红）/ 备份不可用整块不显示 / busy 防连点 |
| `test/help_page_test.dart` | +3 | 六步恢复（含 `.bak` 与真实路径）/ 没传路径的兜底措辞 / 同盘风险 |
| `test/startup_test.dart` | +3 | **场景 6** 空库不备份（备份目录连建都不建）/ **场景 7** 备份目录不可用 → 自动备份静默失败 + 概览橙卡出现（AE-3 两层机制）/ **场景 8** 正常链路启动即出一份、橙卡不出现 |
| `packages/shensuanzi_app/test/backup_test.dart` | +6 | 文案与判定 5 条（含**「上次尝试失败」压过「几天没备份」**）+ 集成 1 条（`latestBackupFile` / 备份后提醒消失） |

**我侧门禁（实测）**：core typecheck 28 入口 ✅ ｜ app typecheck 10 入口 ✅ ｜
`selfcheck_backup` **42 过 0 挂** ✅ ｜ `selfcheck_query` 30 项 ✅ ｜
`selfcheck_app` **126 过 0 挂** ✅ ｜ 15 个改动文件 `dart format --output=none` 无语法错 ✅

**用户复跑（预期）** —— 在仓库根 `D:\shensuanzi\shensuanzi` 下，逐段执行：

```powershell
# ① 纯 Dart 包（我侧已自验，这里确认用例数）
cd packages\shensuanzi_app ; dart test ; dart run tool\selfcheck_backup.dart
cd ..\shensuanzi_core        ; dart test ; dart run tool\selfcheck_query.dart

# ② 回到仓库根：全仓 lint + 根 widget 测试
cd ..\..
flutter analyze
flutter test
```

预期：analyze **0 issues**；app `dart test` 169 + 6 = **175**；根 `flutter test`
58 + 16 = **74**；core `dart test` +3。（数字是推导值，**以你回传的为准**。）

#### 五、记录在案 / 待真机确认

- **本批之外**：`lib/src/ui/products_page.dart` 有一处**未提交**改动（真机反馈 2026-09-28：
  副标题改成「单位：个」）。已核对 `Product.unit` 非空 ⇒ 编译无碍，且无测试断言该副标题；
  **归用户决定去留**。
- **橙卡什么时候留在屏幕上**：① 有单据 + 从未备份 / 超 3 天没备份，且**自动备份没成功**
  （成功就立刻消失，正确）；② **最近一次尝试失败**（遗漏 2）—— 这一条即使「昨天刚备份过」
  也会显示，因为它说的是「这次没成」，不是「多久没成」。真机走查请专门造一次
  「备份目录不可写」看这两条。
  ⚠️ **本批把遗漏 2 的「不静默」补全了**（第一批只做了探测 + 降级记录）；请裁定这个口径
  是否合意 —— 备选是「失败只在设置页显示」（更安静，但用户不主动看就永远不知道）。
- 遗漏 10（备份目录放 README.txt）仍**不做**（记录在案）；遗漏 8 已在帮助页明说同盘风险。
- `docs/testing.md` §L 的「已自动化」表格**已同步本批**（`startup_test` 五条 → 八条，
  新增 `overview_page_test` 一行）；该表还缺 `settings` / `help` / `documents` / `stock` /
  `parties` / `opening_stock` 六个文件的行 —— 列为**待办**，本批没有擅自补全。
- 真机走查清单（§AE 末）：首启空库不备份 → 录商品 → 重启触发备份 → 立即备份看 SnackBar
  路径 → 手动删一个备份文件确认保留策略不误删其他。

#### 六、复跑返工（2026-09-28 晚）：两处**断言**写错，产品代码零改动

用户复跑：core **全部通过** ✅ ｜ 根 `flutter analyze` **无问题** ✅ ｜ 两处红，都是测试自己错：

| # | 失败 | 根因 | 修法 |
|---|---|---|---|
| 1 | `backup_test` 301：期望「今天 09:05」实得「今天 09:00」 | 我把夹具写成 `DateTime(2026, 9, 28, 9)` 却断言 09:05 —— **同一个笔误我在 `selfcheck_backup` 里已修过，却漏了 `dart test` 那一侧**（镜像纪律的教科书反面案例：修一边必须修另一边） | 夹具改 `9, 5` |
| 2 | `startup_test` 247（场景 7）：`还没有备份过` 找到 0 个 | **不是 bug，是新行为**：这一轮确实试过且确实没成 ⇒ 文案走的是「上次备份没成功：…」（遗漏 2 分支）。断言还停在第一批的口径 | 断言改成 `上次备份没成功` + `备份文件夹用不了`（**同时钉住「原因与怎么办来自领域层」**） |

**这条返工的真正价值**：失败 #2 说明「文案分支」确实按三种处境分开走了 —— 从没试过 /
长期没搬动 / 试过但没成 是三句不同的话。测试必须**分别**断言，不能只断言「卡片在」。

**沉淀**：夹具时间与断言时间**手写两遍**就会漂 —— 时间类断言优先写成
`final DateTime t = …; expect(format(t), '…')` 里**只有一处**字面量，
或者干脆断言 `formatBackupTime` 的分支（`contains('今天')`）而不锚具体分钟。

**收官（2026-09-28 晚）**：用户复跑 **app `dart test` 全绿**、**根 `flutter test` 全绿**、
**`flutter analyze` 0 issues**、core 全绿。§AE（备份执行机制）两块全部闭环。

---

## AF. 设计提案：CSV 数据导出（2026-09-28，**待裁定**）

> 用户已给的框架（§十一 权威，`docs/reply.md` §AF 建议审查之外的裁定）：
> **备份之后、核销之前**；**现阶段只做 CSV**；Excel 视使用观感后续定；
> **PDF 属不可二次修改文件、仅用于打印**（打印另立功能，不进导出）。
> 本提案只做**事实核对 + 落地形态**，含糊处列待裁定。裁定答复请写在 `docs/reply.md`。

### 一、事实核对（本轮）

| 事项 | 现状 | 影响 |
|---|---|---|
| **三处 200 行上限** | `DocumentDao.listDocuments({…, limit = 200})`、`ProductDao.findAll({…, limit = 200})`、`PartyDao.findAll({…, limit = 200})`；`PartyLedgerDao.ofParty` **无上限** | 🔴 **「导出 = 当前视图」直接撞上硬上限**：一年几千张单，导出只会拿到最近 200 条，而且**用户看不出来被截断了**。这是本提案最重要的一条，必须先裁定 |
| 各页「当前视图」定义不同 | 商品页 = `ProductService.list(query:)`（LIKE，仍 200 上限）· 库存页 = `_query` 页内搜索 + 成本三态 · 单据页 = 时间 chips（**默认最近 30 天**，SC-3）+ 类型 chips · 往来方页 = 无筛选，按 \|余额\| 降序 · 往来流水页 = 单一往来方的全部 | 「导出当前视图」这句话在五个页面上**不是同一件事**，按钮文案要说清导的是什么 |
| 库存页拿不到名字 | `stockByProduct()` / `costByProduct()` / `availableInStore()` 都是 `Map<String,int>`（**无名称 / 条码 / 单位**），商品档案另走 `ProductService.list()` | 库存导出要「商品 × 数量 × 成本」三处拼装；另需定义「有库存但商品已停用」的行要不要出 |
| 导出目录 | `DataDirectoryPolicy` 只有 `backupDirectoryFor`（兄弟目录 + 「自己就叫神算子备份」时避让）；**没有导出目录** | 新增 `exportFolderName` + `exportDirectoryFor`（**复制**那段避让逻辑，不复用备份目录 —— 用户要能分清「哪个是给会计的」） |
| CSV 依赖 | pubspec 里**没有** CSV 包，也没有 `archive` | 手写（§AF 坑 2）—— 与项目「零新依赖」倾向一致，且只有 20 行 |
| 值的形态 | 模型自带编解码：时间**毫秒**、金额**整数分**、布尔 `1/0` | 导出是给人看的 ⇒ 必须有「分 → 元」「毫秒 → 本地日期」的**展示层**转换（纯 Dart、可测；与备份的「本地时间」同款判断） |
| 已有落点 | 设置页「数据」区已有位置 / 备份目录两行；帮助页 FAQ 已含备份六步 | 导出**不需要**设置页入口（AF-2），但帮助页要补「怎么把数据给会计」 |

### 二、落地形态（拟）

| 部分 | 内容 |
|---|---|
| `shensuanzi_app/lib/src/csv.dart`（新，纯 Dart） | `csvEscape`（RFC 4180：含 `,` / `"` / 换行才加引号，内部 `"` 双写）· `csvBytes(header, rows)`（**UTF-8 with BOM**：`utf8.encode('\uFEFF' + text)`，三字节换 Excel 不乱码）· 展示层格式化 `formatAmount(分)` / `formatDate(毫秒)` / `formatBool` · 空值输出**空串**（不是 `null` 字面量） |
| `shensuanzi_app/lib/src/export.dart`（新，纯 Dart） | `ExportFileName`（`神算子-商品-20260928.csv`，单据带范围 `…-20260601至20260928.csv`；**中文 + 无空格**、本地日期）· `ExportService`（目录可写探测 → 边生成边写 → 失败「说怎么办」→ 单飞，与 `BackupService` 同构）· `ExportOutcome` + `exportOutcomeMessage`（SnackBar 文案，成功带**完整路径**） |
| core：三个「导出用」读取入口 | `DocumentDao` / `ProductDao` / `PartyDao` 各加一个**不设上限**的读取（`limit: null` 或 `listAll*`）。⚠️ **只加读方法：不动表结构、不动现有默认值**（页面列表仍 200） |
| 五页右上角「导出」 | 商品 / 库存 / 往来方 / 单据 / 往来流水；按钮**带行数口径**（如「导出 137 条」），让用户知道导的是筛选后的那批 |
| 中文列名（给人看，不是字段名） | 商品：`商品名称 / 条码 / 单位 / 售价 / 进价 / 安全库存`；库存：`商品 / 条码 / 库存数量 / 在店可售 / 成本金额`；往来方：`往来方 / 角色 / 余额`；单据：`单号 / 单据类型 / 对方 / 金额 / 已收付 / 日期` |
| 导出后 | SnackBar 带完整路径 + **「打开文件夹」**动作（`explorer /select, <path>`）—— 中老年用户自己找文件管理器会迷路（§AF 坑 3） |
| 帮助页 | FAQ 两条：「怎么把数据给会计」（打开单据页 → 选时间 → 导出 → 微信/U 盘）+「**导出的文件完全属于你**」承诺（§AF 六） |

### 三、待裁定项

| # | 问题 | 我的建议 |
|---|---|---|
| AF-1 | v1 格式 | **已裁定**：只做 CSV（UTF-8 with BOM）；XLSX 视观感后续定；PDF 仅用于打印、另立功能 |
| AF-2 | 出口位置 | **每页右上角**，不做设置页统一入口（导出是当前视图的延伸）；但**按钮要写明导的是筛选后的行** |
| AF-3 | 导出目录 | `D:\神算子导出\`（数据目录的兄弟，与备份平级）；新增 `exportDirectoryFor`，避让逻辑照抄备份那份 |
| AF-4 | 导出后动作 | SnackBar 带完整路径 +「打开文件夹」（`explorer /select,`） |
| **AF-5** | **「当前视图」撞 200 上限** | **导出走独立查询（无上限）**，行数显示在按钮上；页面列表保持 200。备选是「导出跟随 200 + 文件头标注『仅前 200 条』」——**不建议**，用户拿这个给会计会漏账 |
| AF-6 | 时间范围 | 单据 / 往来流水**跟随页面现有 chips**（默认最近 30 天，SC-3 已有），**不另设「默认最近 3 个月」**（两处默认值不同会让人困惑）；商品 / 库存 / 往来方全量 |
| AF-7 | 文件名 | 中文 + 日期 + 无空格（见上）；单据带范围段 |
| AF-8 | 「导出全部数据」一键包 | **不做**（那是迁移场景，不是日常场景） |
| AF-9 | 列名清单 | 见上表；**请直接在裁定里改** —— 列名是给人看的，现在改比以后改代码便宜 |
| AF-10 | 导出目录参与清理吗 | **不参与**：导出文件归用户自己管，与备份的 30 天保留策略完全隔离 |
| AF-11 | 进度指示 | **先不做**：手写 CSV 几千行是毫秒级。⚠️ 与 §AE 备份一样**跑在 UI 线程**；真机若见卡顿，再谈 isolate |
| AF-12 | 停用商品 / 无库存商品 | 库存导出**只出有流水或有库存的行**（与库存页一致）；商品导出**含停用**（列里给「状态」列），因为「带走数据」不该偷偷少东西 |

### 四、门禁（拟）

- `shensuanzi_app`：`dart test`（新增 `csv_test` + `export_test`；既有 175 条不回归）；
  selfcheck 镜像（`typecheck` 入口表同步更新）。
- core：三个「导出用」读取入口 + 镜像断言（`test/**` ↔ `tool/selfcheck*.dart` 两套）。
- 根：`flutter analyze` 0 issues + 五页导出按钮的 widget 测试（**注入桩，不真写文件**）。
- 交付前我侧自验（typecheck + selfcheck + 语法），analyze / test 由用户复跑。

### 五、与 §AE 的关系（为什么紧接着做）

§AE 解决「**数据不丢**」，§AF 解决「**数据能带走**」—— 同一个立场的两面：
**开放格式优先，用户的文件永远能在神算子之外被打开**（§AE-1 从 ZIP 退回裸 `.db` 就是这个原则）。

§AF 建议把这条写进 `Agents.md` 的裁定表：

> **数据可携带性原则**：所有面向用户的输出（备份、导出）优先选择开放格式，
> 不引入专有封装。用户的文件永远能在神算子之外被打开。

⚠️ **我未擅自改 `Agents.md`**（规范文件）—— 连同 §AE 的备份裁定行，请一并裁定是否落表。

### 十三、§AF 落地记录（2026-09-28）：CSV 导出（core + 纯 Dart + 五页接线）

**裁定合入**（`docs/reply.md` §AF 审查：4 处修正 + 10 项遗漏 + 4 条实现建议）。

#### 一、逐条对照

| 裁定 | 落地 |
|---|---|
| **AF-5** 导出走独立查询 ✅ 但**按钮不带行数** | `ExportButton` 只摆文案；行数由 SnackBar 报告（`exportOutcomeMessage` 用 `ExportSuccess.rowCount`）。✅ 少一次 `COUNT(*)`，也少一个「显示不同步」 |
| **AF-9 补 4 类字段** | 商品 +`编码`/`状态`；库存 +`单位`/`在途`，`成本金额`→**`库存成本`**；往来方 +`电话`/`地址`，`余额`→拆 **`应收`/`应付`**（不用负数）；单据 +`状态`；`对方` 为空写「散客/散采」；`单据类型`/`状态` 走中文 |
| **AF-2 每页文案不同** | 商品「导出全部商品」· 库存「导出库存」· 往来方「导出往来方」· 单据「导出当前筛选的单据」· 流水「导出该往来方的全部流水」 |
| **AF-7 流水文件名带往来方名** | `ExportFileName(extra: party.name)`；顺带做**非法字符清洗**（`王老板/李老板`→`王老板_李老板`，含结尾点/超长截断/空名兜底） |
| **AF-3 目录主动创建** | 抽 `fs.dart` 的 `ensureWritableDirectory`（§AF 建议 1），**备份与导出共用**；备份的 `_execute` 已改调它（措辞随之统一） |
| **AF-4 `/select,` 的逗号** | `revealInExplorer` 显式注释「少写逗号只会打开目录不选中文件」 |
| **AF-11 + 遗漏 3** | 点下即禁用 +「导出中…」；**先弹「正在导出…」**（裁定给的「更简单」版），出结果再替换 |
| **遗漏 1 CSV 注入** | `csvEscape` 加前导 `'`。⚠️ **但做了一处反向修正**（见下） |
| **遗漏 2 并发** | `ExportService` 单飞 —— **按目标文件名做 key**（见下「与备份不同的一处」） |
| **遗漏 4 空结果** | 0 行 → `ExportEmpty`，**不生成文件**（连目录都不建） |
| **遗漏 5 结果反馈** | 成功带**完整路径** + 「打开文件夹」按钮（`ExportOutcome` 用 **sealed**，UI 侧 `switch` 必须穷尽 —— 建议 3） |
| **遗漏 6 日期带时分** | `formatDateTime` → `2026-09-28 15:30`（只到日的话同日多单排序会乱） |
| **遗漏 7 StringBuffer** | 已用；`csvBytes` 注释里写明「字符串 `+=` 是 O(n²)」 |
| **遗漏 8 Excel 乱码逃生门** | 帮助页 FAQ：「不要双击，用 数据→从文本/CSV→65001」 |
| **遗漏 9 目录不可写** | 失败文案指向「导出文件夹」+ 路径 + 怎么办 |
| **遗漏 10 列宽** | **记录在案**（CSV 固有缺点，v1 接受；XLSX 的真正理由是列宽与格式） |
| **建议 2 `csvBytes → Uint8List`** | 按裁定签名实现（BOM 在函数内部写完，调用方不管编码） |
| **建议 4 数据可携带性原则** | 见本提案末 —— **等裁定**是否落 `Agents.md` |

#### 二、落地物

| 文件 | 内容 |
|---|---|
| `packages/shensuanzi_app/lib/src/fs.dart` **新** | `ensureWritableDirectory`（建目录 + 探针真写；三种坏情况一句话说清） |
| `packages/shensuanzi_app/lib/src/csv.dart` **新** | `csvEscape` / `csvLine` / `csvBytes`（BOM + CRLF + UTF-8）/ `csvBom` |
| `packages/shensuanzi_app/lib/src/format.dart` **新** | `formatDate` / `formatDateTime` / `formatFileDate` / `docStatusLabel` / `partyRoleLabel(s)` / `activeLabel` / `documentPartyLabel` —— **词汇表**（UI 不造句） |
| `packages/shensuanzi_app/lib/src/export.dart` **新** | `ExportTable` / `ExportFileName`（含 `sanitize`）/ **sealed** `ExportOutcome`（Success/Empty/Failed）/ `exportOutcomeMessage` / `ExportSink`（能力面）/ `ExportService`（单飞 + 可写探测 + 同步写盘） |
| `packages/shensuanzi_app/lib/src/export_tables.dart` **新** | 五张表的列定义与行映射（纯 Dart、`dart test` 覆盖） |
| core：三个导出读取 + 两个服务入口 | `DocumentDao.listDocumentsForExport`、`ProductDao.findAllForExport`、`PartyDao.findAllForExport`、`ProductService.listForExport`、`PartyService.listForExport`（**只加读方法**：不动表结构、不动现有默认值，页面列表仍 200） |
| `lib/src/ui/export_button.dart` **新** | 五页共用的导出按钮（busy 态 + SnackBar + `revealInExplorer`） |
| 五页接线 | 商品 / 库存 / 往来方 / 单据 / 往来流水（流水页在 `AppBar.actions`） |
| `data_directory.dart` + `bootstrap.dart` | `exportFolderName` / `exportDirectoryFor`（**复用**备份那段避让逻辑：抽了 `_siblingFor`）+ `DataLocation.exportDirectory` |
| `help_page.dart` | FAQ 三条：**导出 ≠ 备份**（遗漏 5）、怎么把数据给会计 + 「**导出的文件完全属于你**」、Excel 乱码逃生门（遗漏 8） |
| 测试 | `test/export_reads_test.dart` + `tool/selfcheck_export_reads.dart`（core，8 项）；`test/csv_test.dart` + `test/export_test.dart` + `tool/selfcheck_export.dart`（app，26 项）；`test/support/fake_export.dart` + 四个页面的导出用例（含新文件 `products_page_test.dart`） |

#### 三、selfcheck 抓到的**真 bug**：`whenComplete` 自等待死锁 🔴

写 `ExportService` 的单飞时照抄了 `BackupService` 的写法，但备份是**单字段**、导出是**按文件名做 key 的 Map**：

```dart
// ❌ 永不完成：回调返回的正是刚从 Map 里取出的那个 Future（= wrapped 自己）
final wrapped = _execute(...).whenComplete(() => _running.remove(target));
// ✅ 块体 → 返回 void，whenComplete 不会再等
final wrapped = _execute(...).whenComplete(() { _running.remove(target); });
```

`whenComplete` 的入参是 `FutureOr<void> Function()` —— **回调一旦返回 Future，它会先等那个 Future**。
实测症状：`selfcheck_export` 在第一个 `await` 处**静默退出（exit 0）**，没有任何报错 ——
`dart test` 里则表现为「测试永不结束」。

**最小复现**（已定位到形态差异，非环境问题）：

```dart
class A { Future<T>? _running; }   // 单字段：() => _running = null  → 完好（备份）
class B { Map<String, Future<T>> _running; } // Map：() => _running.remove(k) → 死锁（导出）
```

**沉淀**：`whenComplete` 的回调**永远写块体**；判「Future 有没有完成」别只看有没有异常，
**「进程静默退出」也是一次失败**（本次就是靠自检的输出缺口发现的）。

#### 四、一处**反向修正**（请复看）：CSV 注入里的纯数字放行

裁定的 `csvEscape` 对 `= + - @` **一律**加前导 `'`。照抄的话：

> 流水/往来方里的**负金额**（收款单是负数）会变成**文本**，Excel 求和时被跳过 ——
> 会计一求和就漏数，而且**看不出来**。

所以加了一层：**纯数字字面量放行**（`^-?\d+(\.\d+)?$`）。
`-12.34` 保持数字（可求和），`-5 折` / `=SUM(...)` / `+86 138` / `-2+3` 照样加引号。
**数字字面量本身不是注入向量**，所以这层收窄不削弱防护。

（往来方的余额也顺势拆成 `应收`/`应付` 两列，与 AF-9 的建议一致。）

#### 五、几处**类推**（裁定没写，我按同一逻辑推的，请追认或置回）

| # | 类推 | 理由 |
|---|---|---|
| 1 | 库存导出**含停用**，并加 `状态` 列 | AF-12 说「只出有流水或有库存的行」——「停用但有库存」必然落进这个集合，不标状态这行就无法解释；且会计对账少了它就对不上 |
| 2 | 往来方导出**含停用**，并加 `状态` 列 | **停用但还欠钱的客户**必须在账里（否则这笔应收凭空消失） |
| 3 | 商品/库存导出都带 `编码` | 「同款不同批次」是常态（R-15 条码可重复），光靠名字分不开；两份文件也能按编码对上 |
| 4 | 单飞**按文件名做 key**（不是单个 `_running`） | 备份永远写同一件事，复用 Future 是对的；导出**每张表内容不同**，复用会把 A 表的结果当成 B 表返回 —— 比不做去重更糟。同键（同页同一天）仍完全等同备份的行为 |
| 5 | 页面注入的是 **`ExportSink` 接口**而非具体 `ExportService` | 裁定要求「widget 测试注入桩、不真写文件」；接口还让测试能断言「页面拼出来的表几行几列」 |
| 6 | 同日同页重复导出**覆盖**同名文件 | 与备份的「同分钟防连点」不同：导出是用户主动动作，覆盖是最符合直觉的结果（备选：文件名加时分） |
| 7 | 库存 `库存成本` 期初商品写 `0.00` | 保持「数字列可求和」，不写「待校准」文字（帮助页已有「期初成本为什么是 0」的解释）。备选：加一列成本口径说明 —— 请裁定 |

#### 六、我侧门禁（实测）

core typecheck **30 入口** ✅ ｜ `selfcheck_export_reads` **8 项** ✅ ｜ `selfcheck_query` 30 ✅
app typecheck **13 入口** ✅ ｜ `selfcheck_export` **26 过 0 挂** ✅ ｜ `selfcheck_backup` 42 ✅ ｜
`selfcheck_app` 126 ✅ ｜ 15 个 Flutter 文件语法检查无错 ✅ ｜
**根 `tool/import_guard.dart`：34 文件 0 处缺导入** ✅（§九 新增）

⚠️ 本会话仍**创建不了子进程**（`CreateFile failed 231`），所以 `flutter analyze` / `flutter test` /
`dart test` 依旧跑不了 —— 且 `dart run` 编译不了 import `package:flutter` 的文件，
**根 `lib/` 没有我侧可达的编译门禁**。五页接线与新增 widget 测试**只能靠语法检查 + 人工核对**。

#### 七、用户复跑（预期）

```powershell
# ① 纯 Dart 包
cd packages\shensuanzi_app ; dart test ; dart run tool\selfcheck_export.dart
cd ..\shensuanzi_core        ; dart test ; dart run tool\selfcheck_export_reads.dart

# ② 仓库根
cd ..\..
flutter analyze
flutter test
```

预期：analyze **0 issues**；app `dart test` 175 + 新增（csv 12 + export 11 ≈ **23**）≈ **198**；
根 `flutter test` 74 + 新增（单据 1 + 商品 2 + 库存 1 + 往来方 2 + 帮助 1 = **7**）= **81**；
core `dart test` + 8。（数字是推导值，**以你回传为准**。）

#### 八、待裁定 / 记录在案

- **`Agents.md` 是否落两条**：「数据可携带性原则」（§AF 建议 4，一条管多代功能）+ §AE 备份裁定行。
- `docs/testing.md` §L 已同步本批（新增 `products_page_test` 行 + 导出覆盖说明）；该表仍缺
  `settings`/`help`/`documents`/`stock`/`parties`/`opening_stock` 六行 —— 待办。
- `lib/src/ui/products_page.dart` 那处**未提交**改动（真机反馈「单位：个」）仍在，归你处置。

#### 九、复跑返工（首轮，三处失败 —— 全是测试侧写错，产品代码零改动）

| # | 位置 | 根因 | 修法 |
|---|---|---|---|
| 1 | `packages/shensuanzi_app/test/export_test.dart`：写成功用例 | 用 `String.fromCharCodes(bytes.sublist(3))` 当解码器 —— 它按 Latin-1 逐字节取值，中文解成 `ç¼ç ` 乱码，断言必然失败（且失败信息里看不出是**解码**错了） | 改 `utf8.decode`。**自检侧一直是对的 ⇒ 镜像漂移第 8 次**（这次是测试错、自检对） |
| 2 | 同上：0 行用例 | 对**不存在的目录**调 `listSync()` 证明「目录是空的」⇒ 抛 `PathNotFoundException`。空结果在可写探测**之前**就返回，目录根本不会被建 | 改成 `!Directory(exportDir).existsSync()`，断言更强（连目录都不建）；`selfcheck_export` 同步收紧，两侧一致 |
| 3 | 根 `test/`：单据/商品/库存/往来方 4 个 widget 测试 | 用了 `ExportSink` / `ExportTable`，但**没 import `package:shensuanzi_app/shensuanzi_app.dart`** —— `test/support/fake_export.dart` 里有那行导入，可 **Dart 的 import 不传递**，别的文件看不见 | 四个文件各补一行桶导入。analyze 报的 2 条 `unnecessary_nullable_for_final_variable_declarations`（`info`）是「类型解析失败」的连带效应，导入补齐后应消失 |

**沉淀**：
- 字节 → 文本**只有一个正确解码器**（`utf8.decode`）。`String.fromCharCodes` 名字像解码、实际是 Latin-1 取值 —— 凡是断言里出现它，先怀疑。
- 「证明目录为空」必须**先判存在**：`listSync()` 对不存在路径抛异常，报错信息（`列表失败`）离真正的问题（空结果不建目录）很远。
- **镜像纪律**：本轮 3 处里有 1 处仍是对称漂移。两个文件写同一件事时，断言用的**API 名**也必须一致（`utf8.decode` ↔ `utf8.decode`），不能只看结论相同。

#### 十、新增 `tool/import_guard.dart`（补根层缺口）

失败 #3 暴露的不是笔误，是**结构性缺口**：根 `lib/`+`test/` 没有我侧可达的编译门禁
（`dart run` 编译不了 import flutter 的文件、`dart analyze` 起不了 analysis server），
所以这类错误只能等用户跑 `flutter analyze` 才发现。新增一个**纯 Dart 静态守卫**把发现时刻提前：

- **只查一类错**：用了桶导出名、却没 import 对应桶文件。
- **规则从桶文件推导**（读 `show` 子句），无手写清单 ⇒ 不会漂移。
- 实现要点：Dart 源码级状态机去注释（块注释**可嵌套**）与去字符串 —— 否则文档/注释里
  出现的 `ExportSink` 会满屏假报警。
- **灵敏度已反向验证**：临时摘掉 `stock_page_test.dart` 的桶导入 → 精确报出那 2 个名字；
  还原 → 0 处。且脚本以自身路径定位仓库根，从任意目录运行都对。
- ⚠️ **它不替代 `flutter analyze`**：类型不匹配、参数写错、方法不存在一律看不见。

已写入 `docs/testing.md` 的「降级门禁」段，并注明根层为何没有编译门禁。



