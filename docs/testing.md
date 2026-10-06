# 测试要求

> 目标：把"真相在流水"这一设计变成**可执行的断言**，而不是纪律。
> 本文件是测试要求的**单一来源**；`sync_protocol.md` 第十一节是其同步部分的分节，两者不重复描述。

## 零、本地运行前提

> ⚠️ **测试是「警报」，不是「命令」**（2026-09-29，§AJ·一）。测试红时，第一反应必须是
> 「**为什么红**」，而不是「怎么让它绿」。**改断言让测试变绿**和**改生产代码让测试变绿**，
> 在未获授权时都是越权 —— 先报告「哪个测试红了、根因是什么、有哪几个方案」，由人裁定后再动手。
> 另见 `Agents.md` §二纪律 12。

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

# 应用运行时（数据目录策略 / 配置 / 标记 / 恢复）
cd packages/shensuanzi_app
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
dart run tool/selfcheck_products.dart  # 商品建档（金额解析 / 表单校验 / 编码生成 / 编辑停用）
dart run tool/selfcheck_sync_client.dart # SyncClient（游标 / pull 事务性 / push 退避 / delta）
dart run tool/typecheck.dart           # 编译校验：import 全部入口但不执行

# 主机端
cd packages/shensuanzi_host
dart run tool/selfcheck_sync.dart      # SyncServer（五类操作 + 白名单 + 拉取游标）
dart run tool/selfcheck_host.dart      # 令牌 / 主机身份 / 配对载荷 / 二维码数据 / shelf HTTP
dart run tool/selfcheck_client_server.dart # 端到端：一台主机 + 两台客户端，真实 HTTP
dart run tool/typecheck.dart

# 应用运行时
cd packages/shensuanzi_app
dart run tool/selfcheck_app.dart       # 数据目录策略 / 校验三档 / 配置 / 标记 / 启动恢复
dart run tool/typecheck.dart

# 仓库根（Flutter 层）
dart run tool/import_guard.dart        # §AF 复跑返工新增：只查「用了桶导出名却没导入桶」
```

> ⚠️ **根 `lib/` 与 `test/` 没有编译门禁**（这是本项目的结构性缺口，不是疏漏）：
> 那些文件都 import `package:flutter` ⇒ `dart run` 编译不了（`dart:ui is not available
> on this platform`）；`dart analyze` 要起 analysis server 子进程，沙箱会话里起不来。
> 于是根层的编译错误**只有用户终端的 `flutter analyze` 能发现**。
> `tool/import_guard.dart` 是这里唯一能自查的一小块 —— 它**只**覆盖「缺桶导入」
> 这一类（§AF 复跑时 4 个 widget 测试文件全部栽在这上面），
> 规则从两个桶文件的 `show` 子句**推导**（无手写清单 ⇒ 不会漂移）。
> **它不是编译门禁的替代品**：类型不匹配、参数写错、方法不存在它一律看不见。

> ⚠️ **应用层的测试必须用临时目录**，绝不能碰真实的 `%APPDATA%` ——
> 那会把开发者自己的配置写坏。夹具 `sandbox()` 提供用完即弃的临时目录，
> 且 `AppBootstrap` 的 `configStore` **必须注入**（指向沙箱），不要用默认值。

镜像关系（**改一边必须改另一边**）：

| 包 | `tool/` | `test/` |
|---|---|---|
| core | `selfcheck.dart` | `schema_test` + `database_test` + `util_test` |
| core | `selfcheck_rules.dart` | `rule_engine_test.dart` |
| core | `selfcheck_payments.dart` | `immediate_payment_test.dart` |
| core | `selfcheck_delivery.dart` | `delivery_test.dart` |
| core | `selfcheck_returns.dart` | `return_test.dart` |
| core | `selfcheck_query.dart` | `query_test.dart` |
| core | `selfcheck_products.dart` | `product_service_test.dart` |
| core | `selfcheck_purchase.dart` | `purchase_draft_test.dart` |
| core | `selfcheck_account.dart` | `account_draft_test.dart` |
| core | `selfcheck_party.dart` | `party_service_test.dart` |
| core | `selfcheck_sale.dart` | `sale_draft_test.dart` |
| **core** | `selfcheck_sync_client.dart` | `sync_client_test.dart` |
| **host** | `selfcheck_sync.dart` | `sync_server_test.dart` |
| **host** | `selfcheck_host.dart` | `auth_test` + `pairing_test` + `http_server_test` |
| **host** | `selfcheck_client_server.dart` | `client_server_test.dart` |
| **app** | `selfcheck_app.dart` | `data_directory_test` + `data_directory_service_test` + `app_config_test` + `bootstrap_test` + `dialog_model_test` + `navigation_test` + `typography_test` |

> ⚠️ **`typecheck.dart` 必须 import 全部入口，包括 `tool/` 下每个自检脚本本身。**
> `dart test` 只跑 `test/`，脚本自身的编译错误不会被任何门禁发现 ——
> 2026-09-25 真实漏过一次（`selfcheck_returns.dart` 调了不存在的 `createParty(name:)`）。
> 加入口时**同时改 `typecheck.dart` 的 import 与 `entries` 列表**。**每个包各有一份 `typecheck.dart`。**

> ### 四条硬纪律（2026-09-28 提炼；**具体案例已分散到各测试节**）
>
> 1. **`test/**` ↔ `tool/selfcheck*.dart` 必须同时改**（两套并行的镜像断言，只改一边 = 语义漂移）。
>    ⚠️ 两个子项：**搬场景要把夹具一起搬**（seed / 建单 / 定价），别凭「上一个用例的上下文」补前置条件；
>    **自检是一个长脚本**（对象跨段复用）而测试是互相隔离的用例 —— 复用对象时断言要对齐「最近一次操作之后」的状态。
> 2. **断言必须带 `reason:`** —— 尤其引用状态 / 枚举值的（`'applied'` vs `'rejected'` 本身不说明为什么）。
> 3. **涉及时间算术的断言必须注入固定时钟**（`clock: () => fixed`）。
> 4. **新断言要做一次「反向验证」**：把被测行为**故意改坏**，看它是否真的红。
>    **「断言是绿的」≠「断言有效」** —— 夹具让缺陷显现不出来时，断言在、但它瞎。
>
> 📌 规律：**同一个场景里，后写的那个门禁往往是对的**。本仓已出现 **8 次**漂移，其中 5 次是
> 「正式测试错、自检对」—— 两边不一致时别默认正式测试是对的，**先看哪个更符合规范条文**。

## A. DAO 层

- 每个实体的 `insert` / `query`
- **不可变实体不暴露 `update` 方法**（编译期保证）。不可变实体 =
  `document_lines` / `stock_ledger` / `money_ledger` / `party_ledger` / `settlements`
- `documents` 白名单外字段 UPDATE 被拒（只允许 `status` / `paid_amount` / `updated_at`）
- **`Db.transaction` 可重入**：事务内再次调用 `db.transaction` 不得报错（v0.4 裁定）
- **事务失败回滚**：外层抛异常后，本次全部写入不可见
- **DAO 不开事务**：DAO 方法在无事务上下文时也能正确工作（由调用方决定事务边界）
> 📌 **案例（漂移 2，2026-09-25）**：`query_test.dart` 的「没进过货的商品不出现」用例建了两个商品
> 却**没给任何一个入过货**，却断言 `contains(p)`；而 `selfcheck_query.dart` 里同一场景**先 seed 了库存**，
> 所以那边是绿的。**搬场景要连夹具一起搬。**

## B. 不变量（property-based）

| # | 断言 |
|---|---|
| B1 | 库存 = `SUM(stock_ledger.quantity)` GROUP BY `product_id` |
| B2 | 账户余额 = `accounts.initial_balance + SUM(money_ledger.amount)` GROUP BY `account_id` |
| B3 | 往来余额 = `SUM(party_ledger.amount)` GROUP BY `party_id` |
| B4 | 单据已收额 = `SUM(settlements.amount)` GROUP BY `target_doc_id` |
| B5 | `SUM(document_lines.amount) = document.total_amount`（`stocktake` 除外） |
| B6 | `seq_no` 在每张流水表内**唯一且单调递增** |
| B7 | 主数据（`products` / `parties` / `accounts`）的 `updated_at` 在每次写操作（含软删）后由主机刷新 —— 它是增量拉取的游标列（R-13） |
| B8 | 成功 `pull` 后 `sync_cursor` 的 8 行与响应体 `next_cursors` **逐字段一致**（直接比 map，R-14） |
| B8 | 成功 `pull` 后 `sync_cursor` 的 8 行与响应体 `next_cursors` **逐字段一致**（直接比 map，R-14） |

> 📌 **案例（漂移 1b，2026-09-25）**：改**断言文字**也算改语义 —— 错误信息里的
> `不变量 5` 改成 `不变量 B5` 时两边只改了一半。**断言里出现的字符串就是断言的一部分。**

## C. 业务规则 RULE-001 ~ RULE-009

每条规则至少 1 个 happy path + 1 个边界用例。
每条规则至少 1 个 happy path + 1 个边界用例。

> 📌 **案例（漂移 1，2026-09-25）**：方案 C 落地时更新了 `selfcheck_rules.dart` 却漏了
> `test/rule_engine_test.dart` ⇒ **9 个用例失败**（7 个是缺少默认往来方、2 个是过期断言）。
> 镜像纪律不是「理论上要同步」，**它已经红过一次**。

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

> ✅ **已落地（R-3，2026-09-29）**：动作矩阵见 `sync_server_test.dart`
> 「documentAction（R-3 已裁定）」组 —— in_transit → `applied`（单据落 `delivered`）/
> 重复 → `already_exists` / cancelled → `conflict` + `server_state` /
> 未知动作 → `unknown_action` / purchase 收签收 → `rejected`（不适用）/ 单据不存在 → `rejected`。

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
- pull 返回**恰好 9 个实体 + `next_cursors`** =
  6 个业务实体（四张流水 + `documents` + `document_lines`）
  + 3 个主数据实体（`products` / `parties` / `accounts`）（R-13 方案 A）
- 主数据的游标是 `"<updated_at>|<id>"`，**软删行照常返回**（`is_active = 0`）、
  **返回全部列**（含 `sync_version`，客户端要拿它做下次 `base_version`）
- 游标非法 → 400
- **`createDocument` 全链路**（HTTP → `SyncServer` → `RuleEngine` → 四张流水 → 再 pull 回来）：
  推送采购单 → 两条回执 `applied`；单据落库且**主机分配正式单号**（不再是 `pendingDocNoPrefix`）；
  `document_lines` / `stock_ledger` / `party_ledger` 各 1 行；
  `next_cursors` 的 `stock_since` 推进到 `1`、`doc_since` 不再等于 `'0|'`；
  **带这两个游标再拉一次 → `documents` 与 `stock_ledger` 都为空**（增量语义）
- **主数据跨设备可见**（R-13 的核心主张）：设备 A 改价 → 设备 B 带游标 pull 拿到新价；
  设备 A 软删 → 设备 B pull 拿到 `is_active = 0` 的行；
  从未见过该商品的新客户端**全量首拉**就能拿到 `is_active = 0` 的行
- **`(updated_at, id)` 游标**：同一毫秒内多次更新 → 不丢行、不重复、必推进
- **`(updated_at, id)` 游标**：同一毫秒内多次更新 → 不丢行、不重复、必推进

> 📌 **案例（漂移 3b，2026-09-25｜wire 行别手写 JSON）**：**用模型的 `toRow()` 生成** ——
> wire 约定是「值 = `toRow()` 的形态」（`sync_protocol.md` §8.2 前），手写必然漏字段。
> `http_server_test` 手写的明细漏了 `id`（`document_lines.id` 由**客户端**生成、主机原样落库），
> 整条 `createDocument` 被判 `rejected`。现在主单走 `Document.toRow()` + `SyncWhitelist` 过滤，
> 明细走 `DocumentLine.toRow()`。

## G3. 客户端同步引擎（`packages/shensuanzi_core/`，R-14 落地）

**游标（`SyncCursorDao`）**：

- 空表 → 空 map（**没有行 = 从头拉**，不需要「已初始化」标志）
- 写入 / 覆盖；**不透明游标**（base64 风格）也照样存与回传
- **B8**：pull 后 `sync_cursor` 与 `next_cursors` 逐字段相等

**队列（`SyncQueueDao`）**：

- 入队 → `pending` 且立即可送；`markSent` 后不再是到期条目（但仍在表里）
- `markFailed(dead: false)` → 仍 `pending` + 退避；`dead: true` → 死信
- **死信退出自动重试**：`due()` 不含 `failed`；`requeue` 放回并清零
- `clearConfirmed`：只清 `sent` 且 `entity_id` 命中的条目；
  **`pending` 的即使命中也不清**（它还没推送成功）

**拉取**：

- 请求形状：`GET /api/sync/pull` + Bearer + `limit`；**首次不带 `since`**
- 已存游标**原样**进查询串
- 落库 + 存游标 + 清已确认条目**同事务**
- **非法行（缺 id）→ 整批回滚**（行与游标都不落库）
- 幂等：同一页重复拉不产生重复行；本地占位单据被主机版本覆盖（含 `doc_no` 回填）
- 未知实体键**被忽略**且不落库（也不会被当表名拼进 SQL）
- `doc_no` 撞车 → **带上下文**的 `StateError`（非裸 `SqliteException`）+ 整批回滚
- 非 200 → `SyncHttpException`（401 可识别为需重新配对）
- 缺 `next_cursors` / 游标非字符串 → `FormatException`

**推送**：

- 空队列不发请求；回执**按 `entity_id` 配对**（顺序打乱不影响）
- `applied` / `already_exists` → `sent`（**不删除**）；`rejected` → 退避 + 记原因
- 退避序列 **1s / 4s / 16s / 64s**；`> 10` → 死信
- `conflict` → `server_state` 覆盖本地 + 删除条目
- 某条无回执 → 只影响该条
- **传输异常 / 非 200 → 整批退避且仍为 `pending`**（不伪装成业务拒绝）
- 已 `sent` 的条目不会被再次推送

**未同步影响（delta）**：

- 符号表：`purchase` / `sale_return` → `+`；`sale` / `delivery` / `purchase_return` → `−`；
  `stocktake` / `receipt` / `payment` → `0`（客户端**算不出**盘点影响，也不估算资金）
- 多行分别累计；主数据操作不影响库存
- `unsyncedDelta` 合计 `pending` + `sent` + `failed`
- `stockViewOf` = 权威镜像 + 未同步影响，并给出**贡献者**（UI 展开「这 3 件是哪张单卖的」）

**镜像契约**：

- 开着外键的镜像 → 构造 `SyncClient` 时**明确拒绝**（否则 pull 会变成毒丸）
- 落库顺序**按依赖排**（主数据在前），与 §8.2 的字段顺序不同
- 落库顺序**按依赖排**（主数据在前），与 §8.2 的字段顺序不同

> 📌 **案例（漂移 6，2026-09-26｜共享夹具助手会带入它自己的假设）**：delta 用例的 `queueDoc(...)`
> 助手把明细 `product_id` 写成 `p0` / `p1`（为「多行累加」用例设计的），却被拿去做
> `stockViewOf(productId)` 的断言 ⇒ `unsynced` 是 `0` 而不是 `-3`。
> **用助手之前先看它的隐含假设，语义不同就自己拼夹具。**

## H. 时钟

- 客户端时钟偏移 +1 小时 → `seq_no` 顺序仍正确
- 加权成本**不受** `occurred_at` 影响
- `time_estimated = 1` 的标记被主机**保留**（用于审计）
- 客户端本地排序用 `(created_at, id)`，不引用 `seq_no`
- 客户端本地排序用 `(created_at, id)`，不引用 `seq_no`

> 📌 **案例（漂移 4 / 5，2026-09-26｜必须是固定时钟）**：本机时钟夹具 `now()` 是**每次调用 +1**
> 的计数器，于是「差值」里混进的是**调用次数**而不是被测时长：`expect(nextRetryAt, t + 1000)`
> 失败，因为 `push` 自己也会读一次时钟（实际是 `t + 1 + 1000`）；退避序列断言同理。
> **涉及时间算术的断言一律用 `clock: () => fixed` 的实例。**

## I. 成本精度（v0.4）

- 出库 `total_cost` 使用 **round-half-up**
- `SUM(出库 total_cost)` **精确、无累积误差**（`unit_cost` 是派生字段，不参与累计）
- 毛利 = `SUM(销售额) - SUM(出库 total_cost)`
- 成本不含运费 / 折扣 / 税费

## J. 端到端

- Windows 启动 → Android 配对 → 入库 → 销售 → 收款 → 库存 / 余额 / 往来全部正确
- Windows 关机 → Android 离线开单 → Windows 开机 → 同步 → 数据一致
- 同一 `Document` 重复推送 → 数据库仅一条

**已自动化的一层**（`client_server_test.dart` / `selfcheck_client_server.dart`）：
**一台主机 + 两台客户端，真实 HTTP**（`dart:io HttpClient` 做传输）。
它需要 `SyncServer`（host）与 `SyncClient`（core）**同场**，
所以放在 host 包（依赖方向 host → core）。

- **陷阱 1 回归守卫**（R-14 的核心，**这条会明确失败在「从镜像水位推算游标」的实现上**）：
  ```
  A pull → 游标停在 0
  B 在 A 不知情时写 5 张单（seq 1..5）
  A 离线开单并 push 成功（主机分配 seq 6）
     → 断言 A 的游标**仍是 0**（push 不推进拉取游标）
  A 再 pull → **必须拉到 6 条**（B 的 5 + A 的 1）
     → 若实现从 MAX(镜像) 推算，B 的 5 张会被**永久跳过**
  ```
- **陷阱 2 回归守卫**：客户端时钟快 1 小时 → pull 仍不跳过服务器数据
- 跨设备可见：A 推的单，B 拉得到**主机分配的正式单号**；重复 pull 幂等
- 未同步影响：push 后显示库存立刻包含刚卖的货；pull 确认后归零
- 乐观锁冲突：两台同时改同一商品 → 后到者 `conflict` + 本地被覆盖（主机赢）
- v1 边界：`documentAction` → `rejected` + 进重试（非死信）；错令牌 → 401

## K. 应用运行时（`packages/shensuanzi_app/`）

**目标**：数据目录策略全部可测 —— **用代码构造机器**，不依赖真机。

真机取值只在 `AppEnvironment.detect()` 做一次，所有判断都是纯函数；
测试可以造出「有 U 盘 / 有网盘 / 无 D 盘 / 盘类型未知」的机器，
**不需要真的插一个 U 盘**。

**必测清单**：

- **默认位置**：优先非系统盘；无可用的非系统盘 → 用户目录；
  U 盘 / 网络盘 / 空间不足的盘**不作默认**；固定盘优先于 U 盘；
  连 HOME 都拿不到 → 兜底系统盘
- **拒绝**：空路径、相对路径、系统盘根、`C:\Windows`（含子路径）、
  `C:\Program Files`（含 x86）、**大小写变体**（`c:\windows\`）
- **警告**：`%LOCALAPPDATA%` / `%APPDATA%` / `%TEMP%`、网盘同步目录
  （OneDrive / 坚果云 / Dropbox / 百度网盘）、可移动盘、网络盘、
  剩余空间不足、非系统盘根
- **放行**：用户自起名的目录；**名字里带 `Windows` 但不是系统目录**
  （`D:\Windows备份`）—— 防止「前缀匹配」写成误判
- **警告与拒绝的边界**：`warn` 必须 `isUsable`（**警告不拦人**）
- **配置**：缺失 / 语法坏 / 顶层非对象 / 值类型不对 → 一律退回默认且**不抛**；
  往返一致；未知缩放值退回 125%
- **标记文件**：写读往返；字段缺失或类型不对 → `null`；
  **标记损坏时 `contentsOf` 仍算 `ours`，但 `read` 返回 `null`**
- **启动恢复**：没配过 → 走向导；配过且有标记 → 复用；配置被清 → 走向导
  **但标记还在**；重选原目录 → **数据立刻回来**；配置指向 foreign /
  已删 / 非法目录 → 走向导
- **向导**：空目录 → 创建 + 写标记 + 记配置；再选同目录 → 复用且
  **不重写标记**；非空无标记 → 拒绝且**不写配置、不写标记**；
  用户确认后放行且**不动里面已有的文件**；非法位置一律拒绝
- **备份**：是数据目录的**兄弟目录**；数据目录自己叫「神算子备份」时
  **让位**（不允许与数据目录重合）
- **迁移**：新在旧里面 / 旧在新里面 → 拒绝；并列 → 放行；
  目标非法 → 直接返回该结论
- **打开数据库**：`user_version` = `Schema.version`；主机端**外键开着**
  （与客户端镜像相反）
- **界面字体栈**（`AppTypography`）：Windows 首选 `Microsoft YaHei UI`；
  含雅黑本体 `Microsoft YaHei`；含无衬线中文保底 `SimHei`；**不含 `SimSun`**
  （宋体正是要修掉的观感）；含拉丁兜底 `Segoe UI`；无重复族名。
  族名必须是**英文不变族名** —— 字体族写错了**不会报错**，只会静默退回兜底字体，
  这种「无声降级」只能靠断言钉住。
  **Android 返回空栈 = 不干预**（它的默认字体本来就是 Noto / 思源）；
  `primaryFamilyFor` / `fallbackFor` 拆开与拼回必须等于完整栈（不漏层、不重复写首选）

**两个真实踩到的 bug**（都已补回归断言）：

1. **盘根作容器时 `isNested` 静默失效** —— `_key` 只剥掉长度 > 3 的末尾分隔符，
   `C:\` 会原样保留反斜杠，于是拼出的前缀是 `C:\\`，任何子路径都匹配不上。
   后果：`inspectMigration('D:\', 'D:\数据')` **放行** —— 会把数据搬进自己的子目录。
2. **系统盘根被当成普通盘根放行** —— `_key` 转小写，而比较串用的是**大写**的
   `systemLetter`，`'c:\' == 'C:\'` **永远为 false**，于是 `C:\` 返回 `warn`
   而不是 `reject`。**大小写归一化必须两边同源。**

**沙箱纪律**：测试与自检**必须**用临时目录，且 `AppBootstrap` 的 `configStore`
必须注入到沙箱 —— 绝不能让测试写真实的 `%APPDATA%`。

**同一条纪律适用于 Flutter 层**：`ShensuanziApp(configStore:)` **必须**指向沙箱
（`test/startup_test.dart` 就是这么做的）。这一条曾经**无法被遵守** ——
`docs/testing.md` 早就写了「绝不能碰真实 `%APPDATA%`」，但从 `ShensuanziApp`
外面看**没有地方能指到沙箱**；补上 `configStore` 之后纪律和代码才对齐
（`docs/reply_review.md` §W 六）。

## M. 商品建档（`packages/shensuanzi_core/`）

对应 `test/product_service_test.dart` 与 `tool/selfcheck_products.dart`。
字段范围见 `docs/reply_review.md` §R（6 个字段，`code` 由系统生成）；
**条码重复的口径见同文件附录 R-15**。

**必测清单**：

- **金额解析**（`Money.tryParseYuan`）：整数 / 一位 / 两位小数；`.5`；前后空格；
  **符号保留**（「不能为负」是业务校验）；**`1.005` 直接拒绝**（不走 `double`，
  否则 `*100` 的二进制误差会舍成 100）；非法输入一律 `null`；位数过长防溢出
- **表单校验**：名称必填 + 超长；单位必填；售价必填 / 不能负 / 只能是数字；
  **进价与安全库存可空**（空 = 0）；安全库存只收整数；条码可空 + 过长要报；
  **一次能报多个字段**（界面标红多栏）；**空条码归一成 `NULL` 而不是空串**
- **建档**：编码从 `P0001` 起递增；补上 `id` / 时间戳 / `sync_version` / `is_active`；
  6 个字段都落库（含金额转分）；**校验不过时抛 `ProductDraftInvalid` 且库里不留半条记录**
- **编码位数边界（关键回归守卫）**：`P9999 → P10000`，以及
  **已有 `P10000` 时必须得到 `P10001`** —— 这条**会失败在「只按 `code DESC` 排序」的实现上**
  （`P10000` 的字典序小于 `P9999`，会取回 `P9999` 再算出 `P10000` ⇒ 撞 UNIQUE）
- **编辑**：保留 `id` / `code` / `created_at`；`sync_version + 1`；
  **表单没有的列（`category` / `remark` / `is_active`）保持原值**；
  校验不过时**库里原值不变**（含版本号与 `updated_at`）
- **停用 / 恢复**：软删（行还在）、版本 +1；列表默认只看启用中的
- **列表**：排序 = 建档顺序（**不是编码字典序**）；`query` 命中名称 / 编码 / 条码
- **条码重复（R-15）**：`barcodeOwners` 返回**全部**匹配项、按建档顺序 ——
  「重复条码 → 两条都返回」这条**会失败在「静默取最早一条」的实现上**；
  `excludeId` 排除自己（编辑时不该提示「自己和自己重复」）；
  **停用的商品也算条码归属**（过滤掉会让条码看起来凭空消失）；
  建档与编辑**都不因条码重复而失败**（允许重复）
- **`barcodeNotice` 文案**：空列表 → `null`（界面什么都不显示）；
  一条 → 用**商品名**（不是编码，用户认名字不认编号），且第二句必须说清
  「保存后扫码会显示 N 条商品供选择」；两条 → 名字都列出来（`「甲」「乙」`）；
  3 条以上 → 只说第一个 + 「等 N 种商品」；条数 > 9 退回阿拉伯数字
- **事务硬约束**：`ProductCodeGenerator` 在事务外调用 → `StateError`
- **事务硬约束**：`ProductCodeGenerator` 在事务外调用 → `StateError`

> 📌 **案例 A（漂移 3，2026-09-26｜自检跨段复用）**：`selfcheck_products.dart` 里的 `before`
> 已经被成功 `update` 过一次，却拿它**更新前**的 `syncVersion` 去比 ⇒ 「编辑校验不过 → 库里原值不变」
> **假失败**；`test/` 版每个用例都是全新状态，所以正式测试是对的。
>
> 📌 **案例 B（漂移 7，2026-09-26｜`$X.y` 少花括号）**：`contains('$ProductDraft.maxNameLength')`
> —— Dart 把 `$ProductDraft` 当成**类型对象的 `toString()`**，`.maxNameLength` 退化成**字面量**，
> 断言的竟是一个不存在的字符串；报错长得像「值不对」，很费眼神。旁边的自检写的是
> `${ProductDraft.maxNameLength}`，所以**只有正式测试红**。**凡是 `$名字.成员`，先怀疑少了一对花括号。**

## N. 采购开单（`packages/shensuanzi_core/`）

对应 `test/purchase_draft_test.dart` 与 `tool/selfcheck_purchase.dart`。
规则本身在 RULE-001（C 组，`RuleEngine` 已覆盖），这里只测**表单草稿**与**提交服务**。

**必测清单**：

- **明细行**：`lines.isEmpty` 才报「至少要有一行」；**空行照常报行级错误**
  （用户加了一行就得填或删，不能让人以为那行被忽略了）；每行商品必选、
  数量**正整数**（`document_lines.quantity` 是 INTEGER —— 不支持按斤按米，
  已知限制，见 `docs/reply_review.md` §X）、单价 ≥ 0 且最多两位小数
- **预填**：`PurchaseLineDraft.fromProduct` 单价预填 `products.cost_price`
  （用户**主动填的**参考价，不做历史推算 —— 推算会引入用户没预期过的值），数量留待填写
- **立即付款**：金额留空 = 跳过该行（默认「全赊」靠这个表达）；金额填了 ⇒ 账户必选且 > 0；
  **付款合计 ≤ 本单合计**（挂 `PurchaseField.payments`，报错要说清超了多少）
- **散采**（未选供应商）必须当场结清 —— 挂 `PurchaseField.party`；
  行/付款本身不合法时**不报**（一次一个重点）
- **日期**：`YYYY-MM-DD` 原文；空 / 格式不对都报
- **服务提交**：`PurchaseService.create` 三组校验任一非空 ⇒ 抛 `PurchaseDraftInvalid`
  （三组原因齐全，库里不留半条）；散采全款 / 赊购 / 部分付款三条链路的库存、资金、
  往来、`paid_amount`；正式单号（**非**「待同步-」前缀）；供应商累计欠款
- ⚠️ **`outcome.document` 带回的是主单刷新前**（`paid_amount = 0`）——
  立即付款对 `paid_amount` 的刷新发生在 outcome 构造**之后**。
  服务层必须按 id **读库**取最终状态，不信任 outcome 的缓存值
- - ⚠️ **测试夹具的金额一律 `Money.format(分)` 生成** —— 手写整数除法
  （`qty * 350 ~/ 100`）会在非整除值上**截断差钱**，散采结清被拒时
  表面看是业务问题，实际是夹具算错（2026-09-28 真踩）
- ⚠️ **流水单号断言**：`dispatch` 会把占位单号换成正式单号 ——
  拿内存 `document.docNo` 比对必错；要么断言「非待同步前缀」，要么读库
- ⚠️ **服务段每用例独立内存库** —— 同一供应商连续开单会让「累计欠款」跨用例累计，
  `documents` 行数也会互相污染（§零 的跨段复用坑，本轮真踩）

## O. 账户建档 + 店内销售开单（`packages/shensuanzi_core/`）

对应 `test/account_draft_test.dart` / `test/party_service_test.dart` /
`test/sale_draft_test.dart` 与三个同名 selfcheck。规则本体在 RULE-002
（`RuleEngine._sale` 已有 11 处覆盖），这里测**表单草稿**与**提交服务**。

**必测清单**：

- **账户**：名称必填 ≤ 60；类型必选；期初余额可空（= 0）、只收 ≥ 0
  的两位小数金额；**`update` 不改期初余额**（Z-3 方案 A —— 草稿里的值被忽略，
  以库里原值写回，历史不可篡改）；停用是软删
- **ensureParty**（Z-4，采购/销售共用）：无同名 → 新建；同名无该 role →
  **追加 role**（phone 不动）；同名 role 齐全 → 原样返回。**绝不允许出现
  两条同名 party**（往来账分流是对账灾难）
- **销售草稿**（与采购逐条镜像）：明细 ≥ 1 且空行照常报行级错误；数量正整数；
  `fromProduct` 预填**售价** `sell_price`（**默认值不是约束**，改后不回写商品档）；
  收款合计 ≤ 合计；**散客必须当场结清**（散采同款文案）；散客检查在行不合法时不报
- **销售服务**：散客全款 / 赊销（客户欠款为**正** = 客户欠我）/ 部分收款；
  **负库存放行**（RULE-002 允许，告警在界面层）；`stockSnapshot()` 是**打开
  本页时**的快照（Z-2：只用于提示，不重查不校验）
- ⚠️ **服务段每用例独立内存库** —— 同一客户连续开单会让「累计欠款」跨用例
  累计（§零 跨段复用坑，本轮在 selfcheck 里又踩一次）
- ⚠️ **`now()` 这类递增时钟助手，先落变量再用** —— 在参数里调一次、
  在 `expect` 里又调一次，时钟被自己推走（2026-09-27 首跑翻车：
  期望 ...003 实际 ...002）。要么存变量，要么断言用关系（`greaterThan`）

## L. 根 Flutter 应用（`lib/`）

**能自动化的部分很少，而这是刻意的**：根应用只放「摆放控件、调插件、pop 结果」，
所有判断都在 `packages/shensuanzi_app`（由 `dart test` 覆盖）。
出错面越小，不可验证的那部分就越安全。

| 手段 | 能查出什么 |
|---|---|
| `flutter analyze`（**在仓库根跑**） | 类型错误、未使用导入、lint（**首选**） |
| `flutter test` | widget 测试（`test/widget_test.dart` + `test/startup_test.dart`）。启动流程靠**三个注入点**变得可测：`pickDirectory`（会真弹系统框）+ `configStore`（**不注入就会读写开发者真实的 `%APPDATA%`**）+ `defaultDataDirectory`（**一个值**，只在首启场景判定里替换「机器给的默认位置」——见 §BR·补 2 方案 B：**参数化 ≠ 假机器**）。⚠️ 还要 `useLocalSqlite()` —— `sqlite3_flutter_libs` 只把 DLL 放进**应用目录**，`flutter test` 不打包它 |
| `dart format --output=none lib test` | **语法**（解析文件但不解析导入）。⚠️ **它抓不住语义错**（构造函数少参数、方法不存在、await 非 Future、const 里掺表达式……
  以及「State 字段初始化器读 widget」—— 2026-09-27 账户页连踩两轮）——
  2026-09-27 采购页首轮 14 个 analyze issue 全部漏过它。**`flutter analyze` 在 AI 会话里能跑但间歇失败**（子进程管道耗尽，会话后期可能持续失败）—— 能跑时一律以它为准；跑不了时降级为`dart format`（仅语法）+ 语义自查 + 用户复跑。仍要跑 format 时：**别用管道接它再取 `$?`** —— 管道后取到的是 `tail` 的退出码，**语法错误会被静默放行**（2026-09-26 真实漏过一次）。要么直跑，要么取 `${PIPESTATUS[0]}` |

> ⚠️ **`flutter analyze` 是本项目唯一的全仓 lint 门禁。**
>
> 在仓库根运行时它会**连带分析 path 依赖的全部包**
> （`shensuanzi_core` / `shensuanzi_host` / `shensuanzi_app`）。
> 而 `dart run tool/typecheck.dart` 只**编译**不 **lint** —— 两者不可互相替代。
>
> 2026-09-26 第一次跑它时报出 **37 项**（其中 36 项是历次累积的），
> 说明**不跑就会有 lint 债静默堆积**。已清零，目标维持 **0 issues**。

> ⚠️ **不要为了「格式化」而运行 `dart format`**：Dart 3.7+ 换了默认风格，
> 全仓按新风格格式化会产生一个**纯风格的大 diff**（实测 `core` 32/53 文件、
> `host` 11/15、`app` 14/16 都会变）。要统一风格就单独提一个提交。

**已自动化的**：

| 文件 | 覆盖 |
|---|---|
| `test/widget_test.dart` | 主界面把「数据在哪」说清楚、闭环入口常驻可见、数据库没就绪时给出「怎么办」 |
| **`test/startup_test.dart`** | **启动流程八条**：① 没配置过 → 弹对话框 ② 配置过且可用 → 不弹、直接进主界面 ③ 选了目录 → 对话框消失、进主界面、配置落到**沙箱** ④ 选择器取消（`null`）→ 对话框仍在、不崩 ⑤ 目录能用但**库打不开** → 错误页 ⑥ **空库启动不自动备份**（§AE 遗漏 1，备份目录连建都不建） ⑦ **备份目录不可用 → 自动备份静默失败**（`tester.takeException()` 必须为 `null`）+ **概览页橙卡出现**（§AE-3 两层机制） ⑧ **正常链路启动即出一份备份**（schema 版本进文件名）且橙卡不出现 |
| **`test/overview_page_test.dart`** | **概览页六条**（§AE）：无提醒不摆卡 / 有提醒摆卡 + `Key('overview-backup-now')` / 备份不可用只说不给空按钮 / 点击 → 回调一次 + SnackBar 带**完整路径** / 失败 SnackBar 说「怎么办」 / `Completer` 卡住 Future 验证**进行中再点不触发回调**。⚠️ 提醒文案里含「立即备份」四字，断言一律用**精确文本或 Key**，不要 `textContaining` |
| **`test/purchase_page_test.dart`** | **采购开单五条**：① 空表单保存 → 报缺明细 ② 散采全款 → SnackBar 已保存 + 库存 ③ 散采欠款 → 「散采要当场结清」 ④ 供应商 + 部分付款 → SnackBar 带累计欠款 ⑤ 取消有内容 → 确认后清空 ⑥ 供应商搜索打字不崩（⚠️ DAO 返回**定长列表**，`removeWhere` 会逐字崩 —— 过滤一律 `where().toList()`）。⚠️ 商品选择器**空查询显示「最近采购」**（首次为空，先搜索再点选）；**搜索框必须用 `Key('picker-search')` 定位** —— `byType(TextField).first` 会命中弹层底下页面的输入框（树的先序遍历）；**底部按钮先 `scrollUntilVisible` 再点**（800×600 测试视口装不下整页）；`widgetWithText` 匹配不到 `InputDecoration.label` |
| **`test/account_page_test.dart`** | **账户页四条**：① 空列表给「怎么办」 ② 新建 → 列表出现、余额含期初 ③ **编辑时期初余额只读**（Z-3 方案 A：保存后期初不变） ④ 空名保存 → 字段级报错。⚠️ 下拉选项要先点开下拉框才在树上（直接 `find.text('微信')` 会扑空） |
| **`test/sale_page_test.dart`** | **销售页七条**：① 空表单行级报错 ② 散客全款（库存归零） ③ 散客欠款 →「散客要当场结清」 ④ **负库存：红色提示标明「打开本页时」且保存放行**（Z-2） ⑤ 选客户+议价+部分收款 → SnackBar 带累计欠款 ⑥ 客户选择器：空查询=最近往来、新建同名=追加 role（Z-4） ⑦ 取消确认。⚠️ 售价预填是**默认值**（议价可改，不回写商品档） |
| **`test/products_page_test.dart`** | **商品页两条**（§AF）：① 导出全部商品 → 表 8 列、**含停用**、**不受搜索框影响** ② 没接导出服务 → 不显示按钮。⚠️ 导出走 `test/support/fake_export.dart` 的 `FakeExport`（**注桩，不写盘**）—— 有了它还能顺带断言「页面拼出来的表几行几列」，比只看 SnackBar 有价值 |
| **导出（§AF，三层）** | ① `packages/shensuanzi_app/test/csv_test.dart`：转义 / **公式注入**（含 `[+-]?\d+(\.\d+)?` 纯数字放行）/ BOM / CRLF / 日期与措辞 / **千分位会被转义成文本**（所以导出金额不带千分位）；② `…/export_test.dart`：文件名（含非法字符清洗）/ 空结果不生成 / 目录不可写 / 同名并发单飞 / 五张表列与值 / **五表金额无千分位 + 检测器哨兵**；③ `packages/shensuanzi_core/test/export_reads_test.dart`：三个导出读取入口**不分页**（>200 行）、默认**含停用**。⚠️ widget 侧另有五页各一条（单据/商品/库存/往来方/流水），全部注入 `ExportSink` 桩。⚠️ **「金额不带千分位」的夹具里必须有一笔 ≥ 1000 元** —— 千分位要 ≥ 1000 元才出现，全是小额的夹具会让断言**空转**（本批真实踩过） |

启动流程这五条以前**一条都没有**，根因是缺接缝：只有 `pickDirectory` 不够，
还得有 `configStore` —— 否则测试既**不确定**（真机上配置已存在，对话框永远不弹），
又**有破坏性**（`prepare()` 会把真实配置改写成测试的临时目录）。
2026-09-26 真踩过一次同类问题：在 `MaterialApp` **之上**拿 context 弹对话框 ⇒
`No MaterialLocalizations found.`，界面停在兜底页，看着像「按钮没反应」，
而所有单元测试都是绿的。裁定与论证见 `docs/reply_review.md` §W。

> ⚠️ **写 widget 断言前，先想想「同一段文字会不会在屏幕上出现两次」。**
> 首轮 `startup_test` 三条红，全是同一个原因：断言对话框标题用了裸
> `find.text('选择数据存放位置')`，而**兜底页的按钮文字也叫这个** ——
> 对话框开着时底下那个按钮还在，恰好找到 2 个。
> 「某 UI 元素在不在」要**限定作用域**（`find.descendant(of: find.byType(AlertDialog), …)`），
> 不要靠「恰好只有一个」碰运气。

**不能自动化的**（必须手动跑一次真机）：

- 系统「选择文件夹」对话框本身（`file_selector` 插件）
- 真实盘类型与剩余空间（纯 Dart 拿不到，需要 Win32 / 插件）

### 根层交付清单（**本侧编译不了，只能眼过**）

> ⚠️ **这不是工具能替代的**——这是**交付纪律**。凡 AI 会话**编译不到**的改动，
> 提交前都要逐条走一遍。
>
> 背景：`tool/import_guard.dart` 只查**导入面**；根 `lib/` + `test/` **没有**
> `typecheck.dart`（它只存在于三个 `packages/`）⇒ **纯 Dart 语言规则**在本侧是**盲区**。
> 2026-10-03（`reply_review.md` §BC）判定：**不做**「局部声明顺序」静态检查工具 ——
> 纯文本近似的**假阴性**比没有工具更危险（「检查过了」会变成**假信心**）。
> 改用 **`Agents.md` 纪律 16 + 本清单**。

| # | 必过项 | 怎么过 |
|---|---|---|
| 1 | **局部声明顺序** | 有没有局部函数 / 变量在**声明前**被引用？（`main()` 里的助手一律排在最早调用点之前；要跨序引用就**放顶层**）—— 纪律 16 |
| 2 | **缺 import** | `import_guard` 报 0 处之后，**再眼过一遍本次新增的 import** |
| 3 | **类型不匹配** | 尤其**跨包调用**：测试里传的值，Flutter 侧也这么传吗？（§BB·七：`hostIdentityFile` 的 `Directory` vs `String` —— 测试与自检**互相印证**、一路绿灯，只有真实调用点暴露了） |
| 4 | **同名冲突** | 新符号有没有和已有符号重名（本文件内 / 导入面内） |
| 5 | **未使用导入** | 本次改完有没有多余 import（门禁是 **0 issues，`info` 也算**） |
| 6 | **`$` 插值里的标识符** | 有没有写错（§AO·四 第一轮） |
| 7 | **覆写检查** | 引入**继承层**后（如将来的 `DocumentDraft` 基类），逐个核对子类**该覆写的方法有没有 `@override`** —— 漏写时父类默认实现会**静默接管**，`import_guard` 抓不到（§BE·二：`import_guard` 只覆盖导入面） |

---

## P. Schema 迁移（`packages/shensuanzi_core/`）

**两层保护**（`docs/reply_review.md` §AK·二 / reply.md Schema 篇）：

| 层 | 位置 | 管什么 |
|---|---|---|
| **化石库**（端到端） | `test/fixtures/v1_empty.db` + `schema_test.dart`「化石库升到当前版」 | **历史真库能不能升上来** —— 结构补列、数据不丢、新列可写 |
| **执行器单元** | `schema_test.dart`「降级构造的 v1 库」 | ALTER / 事务 / 回滚**本身**对不对（用当前 DDL 建表再降级造形状） |
| **自检镜像** | `tool/selfcheck.dart` §M | `migrationStep` / `MissingMigrationException` / `SchemaTooNewException` / 化石升级（`dart run` 可跑，**不依赖 `dart test`**） |

### 化石的纪律（**命门**）

> ⚠️ **`test/fixtures/*.db` 一旦提交就不再修改。**
> 它是「历史版本的化石」—— 改了它 = **篡改历史**：迁移测试会通过，但真用户的库不会。
> 需要新场景 → **加新 fixture**（如将来的 `v2_empty.db`），**不改老的**。

化石的内嵌 DDL 抄自 git 历史，复核命令：

```bash
git show 7da3323~1:packages/shensuanzi_core/lib/src/db/schema.dart | \
  sed -n '/static const List<String> createStatements/,/^  \];$/p'
```

重新生成（**只在新增化石时**；文件已存在需显式 `--force`）：

```bash
cd packages/shensuanzi_core
dart run tool/make_fixture.dart
```

### ⚠️ 写迁移测试的两个坑

1. **打开化石前必须先拷到临时目录**：`Db.open` 会**就地**跑迁移 —— 直接打开
   `test/fixtures/v1_empty.db` 会把 v1 结构升成 v2，**化石就被改坏了**。
   测试里一律 `fixture.copySync(临时路径)` 之后再打开。
2. **`sqlite_master` 里的索引数 ≠ 你写的数量**：TEXT 主键与 UNIQUE 约束会自动生成
   `sqlite_autoindex_*`（v1 里是 13 个）—— 数索引要加
   `AND name NOT LIKE 'sqlite_autoindex_%'`（`make_fixture.dart` 的自检因此被拦过一次）。

### 迁移的硬约束（`Agents.md` 纪律 14/15）

迁移链**逐版本、不允许跳跃**；`Schema.version` 与 `Schema.migrationStep(N-1)` 必须同改；
**字段只增不删、语义变更视作新字段**；旧代码打开新库 → `SchemaTooNewException`（拒绝）。
