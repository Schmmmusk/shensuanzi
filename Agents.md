# Agents.md

> 本文件是 AI Agent 与本项目开发者的**唯一入口**。
> 任何实体定义、规则细节、同步语义，以 `docs/` 下对应文档为准。
> 若本文件与 `docs/` 冲突，**以 `docs/` 为准**，并提 issue 修正本文件。

## 一、项目一句话

神算子是一个离线优先的进销存系统。Windows 端是唯一权威数据源，跑 SQLite + 本地 HTTP 服务；
Android 端是瘦客户端，只做扫码、查询和离线操作队列。

## 二、纪律（违反即返工）

1. **DAO 不开事务**。事务由 RuleEngine / SyncServer 统一开。`Db.transaction` 必须可重入。
2. **业务数据只插入，不更新，不删除**。
   业务数据 = `documents` + `document_lines` + `stock_ledger` + `money_ledger` + `party_ledger` + `settlements`。
3. **`documents` 表只允许 UPDATE 三个字段**：`status`、`paid_amount`、`updated_at`。
   无 `sync_version` 列。其余字段禁止 UPDATE。
4. **真相在流水**。
   - 库存 = `SUM(stock_ledger.quantity)`
   - 资金 = `accounts.initial_balance + SUM(money_ledger.amount)`
   - 往来 = `SUM(party_ledger.amount)`
   - 核销 = `SUM(settlements.amount)`
   `documents.paid_amount` 是**缓存**，不是真相。
5. **`seq_no` 每表独立单调递增**，由主机在事务内分配。客户端不持久化、不引用。
6. **`occurred_at` 仅用于展示与筛选**，不参与任何计算。排序与成本计算用 `seq_no`。
7. **同步幂等键 = 实体 `id`**。服务端 `SELECT 1 ... LIMIT 1` 判重，已存在返回 `already_exists`。
8. **主机永远赢**。客户端 update 用 `base_version` 乐观锁，冲突时返回主机状态。
9. **同步落库必须走 RuleEngine**。客户端只推 `Document` + lines，主机按 `doc_type` 分派规则落地。
10. **服务端拼 SQL 必须先过表名/列名白名单**。`op.entity` 与 `op.payload.keys` 一律校验。
11. **任何资金流动必须挂在一张 `receipt` / `payment` 单下**。禁止只写 `money_ledger` 不写收付款单。

## 三、一句话规格

> 神算子的真相来源是四张不可变流水表：`stock_ledger`（货）、`money_ledger`（钱）、
> `party_ledger`（债）、`settlements`（核销）。任何业务动作只能通过创建 `Document` +
> 写入流水实现，禁止直接 UPDATE 金额、库存、余额。
>
> **任何一笔钱的进或出，都对应一张独立的收付款单。** 立即收付款由主机自动生成
> `receipt` / `payment` 单，主单**不直接写** `money_ledger`，也**不直接设置**
> `status = settled`。
>
> `documents` 表只允许更新 `status`、`paid_amount`、`updated_at`。所有流水按主机分配的
> `seq_no` 排序。同步以客户端 UUID 为幂等键，主机永远赢。

## 四、关键裁定（v0.4）

| 编号 | 内容 |
|---|---|
| 事务 | `Db.transaction` 用 depth 计数器实现可重入 |
| 同步落库 | 客户端只推 `Document`，主机走 RuleEngine |
| 单号 | 主机生成。客户端离线用 `待同步-XXXXXX` 临时展示号 |
| seq_no | 每表独立单调。同步游标按实体分开 |
| 成本 | `stock_ledger.total_cost` 精确追踪。`unit_cost` 是派生展示字段 |
| 负库存 | 允许。UI 红色告警 |
| 盘点 | `document_lines.quantity` 语义为"盘点后实际数量"，`total_amount = 0` |
| 时钟 | `time_estimated` 标记离线估算时间 |
| 发现 | v1 只做二维码配对，mDNS 延后到 v1.5 |
| 收款单 | `allocations` 随 `createDocument` 的 payload 传入，**不进 `document_lines`**（R-1 / 2026-09-25） |
| 立即收付 | 所有"立即收/付款"由主机**自动生成** `receipt` / `payment` 单 + `settlement`，主单通过刷新 `paid_amount` 派生 `status`。UI 可合并展示，但数据层**永不分叉**（R-6 方案 C / 2026-09-25） |
| 依赖 | `sqlite3_flutter_libs` 加在**根 Flutter 应用**；`shensuanzi_core` 保持**纯 Dart**，只依赖 `sqlite3` 绑定（否则纯 Dart 测试无法运行） |
| 退货成本 | 按**原单比例精确回退**（累计分摊 − 已分摊，消除多次退货的舍入余数）。不加 `document_line_id`（R-11 / 2026-09-25） |
| 送货签收 | v1 走**主机本地** `RuleEngine.markDelivered`；**离线签收**（`documentAction`）推迟到 R-3（2026-09-25） |
| 拒收 | `sale_return.ref_doc_id` 可指向 `delivery`，成本按原送货单比例回退（RULE-003 → RULE-007） |
| 同步游标 | 四张流水用 `seq_no`（开区间）；`documents` 用 **`(created_at, id)`**、主数据用 **`(updated_at, id)`**（均复合）；`document_lines` **无独立游标**（由本页 `documents` 派生）。见 §8.2（R-4 / R-13） |
| pull 的实体面 | **9 个实体**（6 业务 + 3 主数据），是同步的**唯一入口**；§8.3 的 REST **不承担同步职责**（R-13 方案 A / 2026-09-26） |
| wire 形态 | **列名 = 数据库列名（snake_case），值 = `toRow()` 的形态** —— 布尔 `1/0`、时间毫秒、金额整数分。模型自带编解码器，无转换层 |
| **客户端游标** | **原样保存主机返回的 `next_cursors`**（`sync_cursor` 表），**不得从本地镜像推算** —— 游标是「服务器已交付到哪里」（通信状态），不是「我本地有什么」（数据状态）（R-14 方案 A / 2026-09-26） |
| **客户端不跑规则** | 客户端**不实现 `RuleEngine`**，只做 `±quantity` 数量累加（由 `sync_queue` 派生）。**不算成本、不算往来、不算盘点** —— 宁可诚实地不提供，也不要「看起来精确的错误」，因为客户端侧**没有任何门禁**能发现规则漂移（R-14 附带问题 3 / 2026-09-26） |
| **未同步影响** | push 成功后队列条目转 `sent` 而**不删除**，等 pull 确认后才删 —— 否则「用户刚卖的货」在下次 pull 前不可见。UI：`显示 = 权威镜像 + 未同步影响`（R-14 附带问题 3 / 2026-09-26） |
| **客户端镜像** | 必须 `foreignKeys: false`（否则 pull 变毒丸）；落库按**依赖顺序**（主数据在前），不照 §8.2 的字段顺序（2026-09-26） |
| **客户端传输** | `Transport` 抽象类（请求/响应对象 + `method`/`headers`）；**绑定由应用层提供**，core 零新依赖。⚠️ 实现方必须**显式 utf8 编码**请求体（中文 payload 否则直接抛） |
| SyncServer 边界 | **不含 HTTP**。接 `SyncOperation`、返 `SyncResponse`；shelf 适配层属 Windows 应用侧。保持纯 Dart、零新依赖 |
| **包边界** | `shensuanzi_core` = 模型 / DAO / 规则 / **同步协议（DTO + 白名单 + 游标）+ `SyncClient`**；`shensuanzi_host` = **shelf 服务 / SyncServer / 令牌 / 端口 / 二维码数据**；`shensuanzi_app` = **数据目录策略 / 配置 / 标记文件 / 启动恢复 / 缩放档位**；二维码**渲染**留 Flutter 层。三包都无 Flutter 依赖 ⇒ `dart test` 全程可跑（2026-09-25 / 09-26） |
| **数据目录** | **默认非系统盘 + 用户可改 + 立刻校验**（三档：拒绝 / 警告 / 放行）。**警告不拦人** —— 中老年用户被拦住会认为「软件坏了」。配置（`%APPDATA%\神算子\config.json`）与数据分离；数据目录里放 `.shensuanzi-data` 标记，**配置被清后重选原目录即可复用**（2026-09-26） |
| **备份位置** | 数据目录的**兄弟目录**（`D:\神算子数据\` + `D:\神算子备份\`），**不放 `文档`**（OneDrive 会同步它，SQLite 有损坏风险） |
| **UI 基线** | 面向中老年用户：**所有功能有常驻可见入口 + 文字标签**（图标可以加，文字必须在）；尺寸用相对单位；错误信息**说「怎么办」不说「哪里错了」**，且由领域层给出、UI 不造句。见 `docs/ui_principles.md` |

## 五、待裁定清单

**冻结的标准**：某个问题**是否反向决定表结构或字段**。

- **是** → 动工前必须裁定。例：R-1 的 `allocations` 承载、R-6 的资金流口径。
- **否** → 留到对应实现层再定，**不要为了完备而提前猜**。
  例：R-3 动作的幂等存储、R-4 `documents` 的 pull 游标字段、
  R-5 客户端本地镜像的可覆盖性、R-7 负数舍入方向。

| 编号 | 内容 | 处理 |
|---|---|---|
| R-3 | `documentAction` 的幂等判定与存储 | 待同步层实现时裁定。目前 RULE-003 的动作部分暂缓，v1 用主机本地改状态替代。**R-3.1 ~ R-3.5 五问清单**见 `docs/reply_review.md` §H |
| R-8 / R-9 / R-10 / R-12 | 实现期边界（盘盈无成本、超卖符号、`delivery` 状态机、散客赊账） | 已按当前处置实现、**不阻断**；详见 `docs/reply_review.md` 附录 D |

**已裁定并落地**：R-1（`allocations` 随 payload）、R-2（B5 排除收付款单）、
R-6（方案 C：任何资金流都挂收付款单）、R-11（退货成本精确回退）、
R-7（负数舍入 = 半数远离零，随实现确定）、
**R-13（方案 A：主数据并入 `pull`，游标 `(updated_at, id)`）**、
**R-14（方案 A：新表 `sync_cursor` 存拉取游标；客户端只做数量累加）**。

**进入同步层时要回答的 5 个动作问题**（R-3.1 ~ R-3.5）见
`docs/reply_review.md` §H（**不要在 `reply.md` 里找——那是逐轮覆盖的裁定书**）。

## 六、文档索引

**权威规范**（只增不改，改动必须同步引用方）：

- `docs/data_model.md` —— 实体、字段、索引、不变量
- `docs/sync_protocol.md` —— 幂等、冲突、重试、同步队列
- `docs/rules.md` —— RULE-001 ~ RULE-009 + 核销约束
- `docs/threat_model.md` —— 信任边界、已知风险、缓解措施（含 §4.4 数据目录策略）
- `docs/data_directory.md` —— 数据放哪、校验规则、标记文件、恢复与迁移
- `docs/ui_principles.md` —— 面向中老年用户的界面原则（字号 / 对比度 / 缩放 / 向导 / 错误信息）
- `docs/testing.md` —— 测试要求（DAO / 不变量 / 规则 / 同步 / 端到端）

**过程文档**：

- `docs/reply_review.md` —— **裁定台账**（只增不改）。待裁定项、落地记录、
  长期有效的清单都放这里
- `docs/reply.md` —— ⚠️ **逐轮覆盖的裁定书**。每轮由用户重写为新裁定的内容，
  **旧内容会被覆盖**。因此：
  - 规范条文**不要**用「见 `docs/reply.md`」引用它 —— 指向 `reply_review.md` 的对应小节
  - 从它里面摘出来的、需要长期有效的东西（清单、候选答案），**必须迁进 `reply_review.md`**
  - 已被覆盖仍需追溯的内容 → 从 git 历史取（`git show <commit>:docs/reply.md`）

## 七、开发顺序

1. 同步协议单测（第 1 天，不依赖 UI）
2. schema + DAO（含所有索引）
3. RuleEngine + seq_counter
4. 不变量测试 + 核销测试
5. Windows HTTP 服务 + SyncServer
6. Windows UI
7. Android 客户端 + SyncClient
8. 备份 + 打包
9. 端到端 + 开源准备

> **进度（2026-09-26）**：1–5、7 的**逻辑层**已完成（同步协议 / schema + DAO /
> RuleEngine / 不变量与核销测试 / shelf + SyncServer / `SyncClient`），
> 加上 6 的前置「数据目录策略」；当前进行到 **6. Windows UI**。
> 剩余：备份打包（8）、开源准备（9）。