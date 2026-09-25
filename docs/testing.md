# 测试要求

> 目标：把"真相在流水"这一设计变成**可执行的断言**，而不是纪律。
> 本文件是测试要求的**单一来源**；`sync_protocol.md` 第十一节是其同步部分的分节，两者不重复描述。

## 零、本地运行前提

> ⚠️ **`dart test` 在两个纯 Dart 包里跑，不在仓库根。** 三种位置用**不同的运行器**：
>
> | 位置 | 命令 | 原因 |
> |---|---|---|
> | `packages/shensuanzi_core/` | `dart test` | 纯 Dart 包，无 Flutter 依赖 |
> | `packages/shensuanzi_host/` | `dart test` | 纯 Dart 包（shelf 也是纯 Dart），无 Flutter 依赖 |
> | 仓库根 | `flutter test` | Flutter 应用；`dart test` 编译不了 `package:flutter`（会报大量 `package:flutter/src/...` 的 switch 穷尽性错误） |
>
> 在根目录跑 `dart test` 还会去编译 Flutter 模板测试 `test/widget_test.dart`，产生成片的 Flutter 报错 ——
> **那不是数据层的失败**。

**最短正确路径**（两条命令都不能省，**注意 `cd` 目标**）：

```bash
# 数据层
cd packages/shensuanzi_core
dart pub get      # ← 别漏：test 是 dev_dependency，不装就报 "Could not find package test"
dart test

# 主机端
cd packages/shensuanzi_host
dart pub get
dart test
```

`dart test` 需要能创建子进程的环境（测试跑在独立 isolate 里）。此外：

| 项 | 说明 |
|---|---|
| **依赖安装（最易漏）** | `test` 是 **dev_dependency**，只写在 `pubspec.yaml` 里**不会自动生效** —— 必须先 `dart pub get`；漏了会报 `Could not find package test or file test:test` |
| SQLite 原生库 | 纯 Dart 环境**不含**原生库。非 Windows 通常能自动找到系统 sqlite3；**Windows 需自行提供 `sqlite3.dll`**，或设环境变量 `SQLITE3_DLL` 指向它。`shensuanzi_core/lib/sqlite_local.dart` 负责查找（含 `System32\winsqlite3.dll` 兜底） |
| `sqlite3_flutter_libs` 的位置 | **加在根 Flutter 应用**（`pubspec.yaml`），**不加在任何纯 Dart 包** —— 它是 Flutter 插件，加进纯 Dart 包会让 `dart test` 失效 |
| 根目录不要加 `package:test` | 根应用用 `flutter_test`；给根加 `test` 只会让 `dart test` 误编译 Flutter 源码 |
| 跨包共享测试辅助 | `test/` 不属于包的公开面，**无法跨包导入**。`sqlite_local.dart` 因此放在 `shensuanzi_core/lib/`（公开 API，但不 re-export）；`test/support/fixtures.dart` 在两个包里**各有一份精简镜像**，改夹具语义时要两边看 |

**降级门禁**（当分析器 / 测试运行器不可用时）：

```bash
# 数据层
cd packages/shensuanzi_core
dart run tool/selfcheck.dart           # 基础设施：schema / 事务 / 约束 / 金额 / ID
dart run tool/selfcheck_rules.dart     # RULE-001 / RULE-009
dart run tool/selfcheck_payments.dart  # 方案 C：立即收付款自动生成收付款单
dart run tool/selfcheck_delivery.dart  # RULE-003 送货（含 R-10 的 status 例外、签收、在途视图）
dart run tool/selfcheck_returns.dart   # RULE-007 / RULE-008（含 R-11 成本分摊、拒收）
dart run tool/selfcheck_query.dart     # RULE-006 查询（库存 / 余额 / 在途 / 在店可售）
dart run tool/typecheck.dart           # 编译校验：import 全部入口但不执行

# 主机端
cd packages/shensuanzi_host
dart run tool/selfcheck_sync.dart      # SyncServer（五类操作 + 白名单 + 拉取游标）
dart run tool/selfcheck_host.dart      # 令牌 / 主机身份 / 配对载荷 / 二维码数据 / shelf HTTP
dart run tool/typecheck.dart
```

镜像关系（**改一边必须改另一边**）：

| 包 | `tool/` | `test/` |
|---|---|---|
| core | `selfcheck.dart` | `schema_test` + `database_test` + `util_test` |
| core | `selfcheck_rules.dart` | `rule_engine_test.dart` |
| core | `selfcheck_payments.dart` | `immediate_payment_test.dart` |
| core | `selfcheck_delivery.dart` | `delivery_test.dart` |
| core | `selfcheck_returns.dart` | `return_test.dart` |
| core | `selfcheck_query.dart` | `query_test.dart` |
| **host** | `selfcheck_sync.dart` | `sync_server_test.dart` |
| **host** | `selfcheck_host.dart` | `auth_test` + `pairing_test` + `http_server_test` |

> ⚠️ **`typecheck.dart` 必须 import 全部入口，包括 `tool/` 下每个自检脚本本身。**
> `dart test` 只跑 `test/`，脚本自身的编译错误不会被任何门禁发现 ——
> 2026-09-25 真实漏过一次（`selfcheck_returns.dart` 调了不存在的 `createParty(name:)`）。
> 加入口时**同时改 `typecheck.dart` 的 import 与 `entries` 列表**。**每个包各有一份 `typecheck.dart`。**

> ⚠️ **改规则语义时必须同时改两处**：`test/**` 与 `tool/selfcheck*.dart` 是**两套并行的镜像断言**
> （前者是正式门禁，后者是无法运行 `dart test` 时的降级门禁）。
> **只改一边会造成语义漂移** —— 已经踩过一次：方案 C 落地时更新了 `selfcheck_rules.dart`
> 却漏了 `test/rule_engine_test.dart`，导致 9 个用例失败（7 个是缺少默认往来方、
> 2 个是过期断言）。
>
> 同理，**改断言文字（如错误信息里的 `不变量 5` → `不变量 B5`）也要两边同步**。
>
> ⚠️ **漂移最常见的原因是「只搬了断言、没搬 setup」**。第二次踩到（2026-09-25）：
> `query_test.dart` 的「没进过货的商品不出现」用例里建了两个商品却**没给任何一个入过货**，
> 却断言 `contains(p)` —— 而 `selfcheck_query.dart` 里同一场景**先 seed 了库存**，所以那边是绿的。
> **搬一个场景时，把它的夹具调用（seed / 建单 / 定价）一起搬过去**，
> 不要凭「上一个用例的上下文」补脑子里的前置条件。
>
> ⚠️ **夹具里的 wire 行不要手写 JSON —— 用模型的 `toRow()` 生成。**
> wire 约定是「值 = `toRow()` 的形态」（`sync_protocol.md` §8.2 前），手写必然漏字段。
> 第三次踩到（2026-09-25）：`http_server_test` 手写的明细漏了 `id`
> （`document_lines.id` 由**客户端**生成、主机原样落库），整条 `createDocument` 被判 `rejected`。
> 现在主单用 `Document.toRow()` 经 `SyncWhitelist` 过滤主机专属列，明细用 `DocumentLine.toRow()`。
>
> ⚠️ **断言 `status` 时必须把 `reason` 带进 `reason:`**。
> 「`rejected`」本身不告诉你为什么，得回头加打印再跑一遍才算定位 ——
> 上面那次失败的输出里只有 `'applied'` vs `'rejected'`，白跑了一轮。

## A. DAO 层

- 每个实体的 `insert` / `query`
- **不可变实体不暴露 `update` 方法**（编译期保证）。不可变实体 =
  `document_lines` / `stock_ledger` / `money_ledger` / `party_ledger` / `settlements`
- `documents` 白名单外字段 UPDATE 被拒（只允许 `status` / `paid_amount` / `updated_at`）
- **`Db.transaction` 可重入**：事务内再次调用 `db.transaction` 不得报错（v0.4 裁定）
- **事务失败回滚**：外层抛异常后，本次全部写入不可见
- **DAO 不开事务**：DAO 方法在无事务上下文时也能正确工作（由调用方决定事务边界）

## B. 不变量（property-based）

| # | 断言 |
|---|---|
| B1 | 库存 = `SUM(stock_ledger.quantity)` GROUP BY `product_id` |
| B2 | 账户余额 = `accounts.initial_balance + SUM(money_ledger.amount)` GROUP BY `account_id` |
| B3 | 往来余额 = `SUM(party_ledger.amount)` GROUP BY `party_id` |
| B4 | 单据已收额 = `SUM(settlements.amount)` GROUP BY `target_doc_id` |
| B5 | `SUM(document_lines.amount) = document.total_amount`（`stocktake` 除外） |
| B6 | `seq_no` 在每张流水表内**唯一且单调递增** |

## C. 业务规则 RULE-001 ~ RULE-009

每条规则至少 1 个 happy path + 1 个边界用例。

**边界清单**：

- **负库存**：允许出库，库存转负；UI 红色告警；出库成本取**最近一次入库**的 `unit_cost`
- 零数量单据
- **超额退货**被拒（超过原单数量扣除已退数量）
- `transfer` 被拒（v1 无对应规则）
- 缺少 `ref_doc_id` 的退货单被拒
- `ref_doc_id` 指向**错误类型**的原单被拒（`sale_return` → `sale`；`purchase_return` → `purchase`）
- **送货单**：主机**强制** `status = in_transit`（调用方传什么都覆盖）；
  收满款也不改 `status`（R-10），但 `paid_amount` 照常刷新
- **送货状态机**（`RuleEngine.markDelivered`）：
  - `in_transit` → `delivered`；已收满款时同一事务内直接到 `settled`
  - 未收满款签收 → 停在 `delivered`；签收后收到余款 → `settled`
  - **重复签收 → `alreadyExists`**，且不改库存 / 流水 / `updated_at`
  - `cancelled` 的单不能签收 → `rejected`；非 `delivery` 单据 / 单据不存在 → `rejected`
  - **签收只改 `status`，不动库存与流水**
- **拒收**：`sale_return.ref_doc_id` 可指向 **`delivery`**，成本按原送货单比例回退
- **分派边界用「差集」而非硬编码列举**：断言「唯一落到*尚未实现*分支的是 `transfer`」，
  这样将来新增 `doc_type` 会在这里失败，而不是被静默漏掉
  （历史上出现过「用例因错误理由通过」：`sale` 已实现，却因缺 `party_id` 而被拒，
  测试一直在假装保护一件早就不存在的事）

## D. 核销场景

- 一收款核一单（部分 / 全额）
- 一收款核多单
- 一单多次收款
- 超收 → 预收余额（`target_doc_id = null`）正确
- 用预收核新单
- **约束违反被拒**：`amount ≤ 0`、超过收款单总额、超过被核销单总额、
  `receipt.doc_type` 或 `target.doc_type` 不在允许集合内

## E. 退货

- 销售退货 → 库存回、往来减、退款流水正确
- 采购退货 → 库存减、往来减、收款流水正确
- 超额退货被拒
- `ref_doc_id` 缺失 / 原单不存在 / 原单类型不符 → 拒绝
- **退货不修改原单 `paid_amount`**（原单是已完成的历史交易）
- **成本分摊的精确断言见 §F**

## F. 盘点与退货成本

**盘点**：

- 盘盈 `diff > 0` → `StockLedger` 正确（`total_cost` 同入库）
- 盘亏 `diff < 0` → `StockLedger` 正确（`total_cost` 同出库）
- `diff = 0` → **不产生流水**
- 盘点后 `SUM(stock_ledger.quantity)` = 盘点实际数
- 盘点单 `total_amount = 0`，且**不生成** `party_ledger` / `money_ledger`

**退货成本分摊**（R-11 裁定 · 方案 A，算法见 [`data_model.md` §3.3](data_model.md)）：

- 单次全额退：`total_cost` = 原单该商品 `total_cost`
- 单次部分退：`round_half_up(原单 total_cost × 退货量 / 原单数量)`
- **多次部分退**：原 `total_cost = 1001`、原量 10，分三次退 `3 + 3 + 4`
  - 第一次 → `300`，第二次 → `301`，第三次 → `400`
  - 三次之和 = `1001`（精确，余数由最后一次吸收）
- **累计退货量超额**：原单 10 件，退 8 件后再退 3 件 → 拒绝（`return_exceeds_original`）
- **多商品独立约束**：原单有 A / B 两商品，A 超退不影响 B 的合法退货
- **符号**：销售退货 `total_cost` 为正、采购退货为负，均与 `quantity` 一致
- **原单类型校验**：`sale_return` → `sale`；`purchase_return` → `purchase`；否则拒绝
- **负库存出库后退货**：原单成本按「最近一次入库 `unit_cost`」估算，退货原样回退该值
- **退货不修改原单 `paid_amount`**：原单 `paid_amount` 在退货前后不变

## G. 同步

见 [`sync_protocol.md`](sync_protocol.md) 第十一节（幂等、冲突、离线队列、死信、白名单、按 `entityId` 匹配）。

**`SyncServer`（主机侧领域层，`test/sync_server_test.dart`）**：

- **五类操作**：`createDocument` / `createMasterData` / `updateMasterData` /
  `deleteMasterData` / `documentAction`
- **落库走 RuleEngine**：`createDocument` 的拒绝原因必须来自规则
  （如无 `party_id` 的赊账销售），证明同步层没有绕过规则自己写流水
- **幂等**：同 `entity_id` 推两次 → `already_exists`，且**不产生重复流水**
- **互斥**：`immediate_payments` 与 `allocations` 同时非空 → `rejected`
- **契约校验**：`entity_id ≠ payload.document.id`、缺 `payload.document`、
  未知顶层字段、主机专属列、缺必填列（原因须**点出列名**）→ 均 `rejected`
- **乐观锁**：`updateMasterData` 的 `base_version` 落后 → `conflict` + `server_state`，
  且**主机侧的值未被覆盖**
- **软删**：`deleteMasterData` 只翻 `is_active`，**从不 DELETE**；重复删除 → `already_exists`
- **白名单**：业务表 / `sqlite_master` / 任意未知表名 → `rejected`，且**一行都没写进去**
- **批量独立性**：一批里一条被拒，**不拖累**其它条目
- **拉取游标**：流水用 `seq_no`（开区间）、`documents` 用 `(created_at, id)` 复合、
  明细**随主单同页**且无独立游标；**同一毫秒的多行分页不丢不重且游标必推进**；
  明细**不按 `limit` 截断**

> ⏸ **暂缓**：原「`documentAction` 幂等」一项推迟到 **R-3** 裁定后
> （见 `docs/reply.md`）。v1 只需要断言 `documentAction` → `rejected` +
> `action_not_implemented`。

## G2. 主机端传输层（`packages/shensuanzi_host/`）

**令牌与主机身份**（`auth_test.dart`）：

- `generate` 注入种子可复现、不注入时两次不同；明文是 32 字节 Base64
- `matches` 正确 / 错误 / 空串 / `null`；`constantTimeEquals` 等长与不等长
- **首启生成时带明文**；**重启后只读回哈希、没有明文**（哈希不可逆），
  但**照样能校验旧令牌** —— 校验只需要哈希
- `reset` 换 `host_id` + 新令牌 → **旧令牌立刻失效**（一键重置 = 所有设备重配）
- **持久化的 JSON 不含明文令牌**（含哈希），这条必须被断言，不能只写在注释里

**配对载荷**（`pairing_test.dart`）：

- `uri` 形态与 §9.1 一致；生成 → 解析**往返一致**
- 含 URL 不安全字符的令牌（Base64Url 的 `-` `_`）也能往返
- 非配对码 / 缺字段 / `port` 非法 → `FormatException`
- `PairingQr`：`moduleCount ≥ 21`、矩阵是方阵、有深色模块、
  **三个定位角（左上 / 右上 / 左下）是深色**、不同内容矩阵不同

**HTTP 层**（`http_server_test.dart`）：

- 端口落在给定范围；同范围第二次启动落到下一个端口
- `/api/health` **不需要鉴权**（扫码前就要能探到），且**不泄露业务数据**（只有 4 个键）
- `/api/sync/push` 与 `/api/sync/pull` **缺令牌 / 错令牌 → 401**
- 合法 push → 200 + `results`；**一条被拒不拖累同批其它条目**
- 请求体不是 JSON / 缺 `operations` → 400
- pull 返回**恰好 6 个业务实体 + `next_cursors`**，
  **不含主数据**（主数据走 §8.3，见下）
- 游标非法 → 400
- **`createDocument` 全链路**（HTTP → `SyncServer` → `RuleEngine` → 四张流水 → 再 pull 回来）：
  推送采购单 → 两条回执 `applied`；单据落库且**主机分配正式单号**（不再是 `pendingDocNoPrefix`）；
  `document_lines` / `stock_ledger` / `party_ledger` 各 1 行；
  `next_cursors` 的 `stock_since` 推进到 `1`、`doc_since` 不再等于 `'0|'`；
  **带这两个游标再拉一次 → `documents` 与 `stock_ledger` 都为空**（增量语义）

> ⚠️ **`/api/sync/pull` 不返回主数据**。主数据的增量同步目前**没有游标**
> （§8.3 的 REST 接口只有 `?q=&active=`），这是一个已知缺口，待裁定。

## H. 时钟

- 客户端时钟偏移 +1 小时 → `seq_no` 顺序仍正确
- 加权成本**不受** `occurred_at` 影响
- `time_estimated = 1` 的标记被主机**保留**（用于审计）
- 客户端本地排序用 `(created_at, id)`，不引用 `seq_no`

## I. 成本精度（v0.4）

- 出库 `total_cost` 使用 **round-half-up**
- `SUM(出库 total_cost)` **精确、无累积误差**（`unit_cost` 是派生字段，不参与累计）
- 毛利 = `SUM(销售额) - SUM(出库 total_cost)`
- 成本不含运费 / 折扣 / 税费

## J. 端到端

- Windows 启动 → Android 配对 → 入库 → 销售 → 收款 → 库存 / 余额 / 往来全部正确
- Windows 关机 → Android 离线开单 → Windows 开机 → 同步 → 数据一致
- 同一 `Document` 重复推送 → 数据库仅一条
