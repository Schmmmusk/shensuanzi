# 归档：早期落地记录（§F ~ §K，2026-09-25）

> 📦 **本文件是 `reply_review.md` 的归档部分**（**第二批**，2026-09-28）。
> 收录 §F 方案 C / §G R-11 / §H R-3 落地记录 / §I RULE-006 + SyncServer /
> §J 包拆分 + host 传输层 / §K host 首轮测试修复。
> ⚠️ **新裁定不写入本文件。** 在用的台账始终是主文件。
>
> ## 为什么是 v2，不与 v1 合并
>
> - `reply_review_archive_v1.md` 收的是**外部**审查报告（v0.2/v0.3，§0-§7）
> - 本文件收的是**本项目自己的**早期落地记录（§F-§K）
>
> 两者是「两代」的东西 —— 各自成文件才查得动（命名规律见 `Agents.md` §六）。
>
> ## 两个必须知道的点
>
> 1. **§H 只归档了一半**：它的「R-3.1 ~ R-3.5 待答清单」**留在主文件的 §H**
>    （活跃项，且被 7 个文件 9 处引用），**字母 `H` 原地不动**。
>    归档的只是 R-3 的**落地记录**。
> 2. **编号仍然有效**：主文件里 §F/§G/§I/§J/§K 已不存在，引用它们的读者来本文件找。
>    归档前已 grep 过：外部引用 **0 处**（`testing.md` 里的「见 §F」指的是
>    `testing.md` 自己的 §F，与本文件无关）。

---

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


---

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


---

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


---

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


---

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





---

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
