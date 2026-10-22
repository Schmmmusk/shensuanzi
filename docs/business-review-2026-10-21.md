# 业务代码审查报告（2026-10-21）

> **对象**：全部业务相关代码 —— `shensuanzi_core`（69 文件 / 15 152 行）、`shensuanzi_host`（7 / 2 228）、
> `shensuanzi_app`（32 / 6 236）、根 Flutter 层 `lib/`（36 / 18 822），合计 **约 42 400 行生产代码**；
> 测试 **34 265 行 / 1 350 个用例**（core 37 文件、host 8、app 25、根 23）。
> **判定基准**：`docs/data_model.md`、`docs/rules.md`、`docs/sync_protocol.md`、`docs/threat_model.md`、
> `docs/testing.md`、`Agents.md` 的纪律 1–19 与 §四裁定表。
> **方法**：按「代码 vs 文档」逐条对照；所有结论带 `文件:行号`；未读到的内容不写。
> **本次只读审查，未修改任何生产代码。**
> 配套阅读：上一轮界面审查 [`ui-review-2026-10-21.md`](ui-review-2026-10-21.md)（该报告已并入台账 §CV·八十）。

---

## 零、四问四答（一页纸）

| 问 | 结论 |
|---|---|
| **1 业务逻辑是否符合文档设计？** | **主干符合，且是我见过最贴合文档的实现之一** —— 「真相在流水」「立即收付挂收付款单」「核销五道门槛」「退货成本按原单比例精确回退」「盘点差额只在主机算」都在代码里逐条找得到，且有测试钉住。**但有 3 个 P0 级缺陷**：单号生成器同类型同日**第 1000 单**起撞号（商品编码器同类问题已修、单号器漏改）；商品「编辑」的 UPDATE 漏了两列 ⇒ 包装换算**改不动、清不掉**；同步「最近更新窗口」按 `updated_at` **升序**取，最新收款状态**永远排在队尾**。另有 4 条规则边界没拦住（拒收非全量、创建态 `status` 由 payload 直写、盘点录不进 0 件、退货按当前包装重算原单）。 |
| **2 界面与后台逻辑是否一致？** | **数字来源基本同源**（库存/资金/往来都来自流水聚合，导出金额用 `Money.format`），但有 **1 处会直接误导定价的标签错误**（库存页把「成本余值」标成「成本（均价）」，10 件 × ¥3.50 显示「均价 ¥35.00」，`stock_page_test.dart:300` 自己写的期望就是 10×3.50）；**1 处最严重的状态滞后**（§3.1 P0-3：手机看到的欠款状态可能滞后数天 ⇒ 重复催款/重复收款）；**3 份互不引用的「未收」实现**（详情用流水、列表用缓存、筛选也用缓存）。 |
| **3 如何评估性能？** | **当前没有任何性能门禁**（`flutter analyze` 只管 lint；1 350 个用例里没有一条断言时间）。但项目已有三块可复用的地基：`tool/seed_test_data.py`（会造主数据 + 注入数据）、`tool/destructive_acceptance.py`（会摆破坏性现场）、`docs/Stability_Test_Principles.md`（写了「30 天法则 = 1000 采购 + 1000 销售 + 500 核销」的**原则**）。缺的是把原则变成**可判定的门槛**：见 §五，四层方案（SQL 执行计划断言 → 纯 Dart 基准 → Flutter 时间线 → 低配真机）。 |
| **4 面向中老年用户与低配设备怎么优化？** | 关键不是「少画点」，而是 **别在主线程上做同步 IO、别在 build 里做全表聚合、别让单一数字失去语义**。按代码实测的放大点排序：备份同步拷贝（`File.copySync`）、CSV 同步写盘、单据列表 200 行非懒加载、库存页每次 rebuild 跑 5 次聚合、开单页每键 1 次聚合、期初录入每行一个控制器。前四项在**机械硬盘**上会从「无感」变成「卡顿」，后两项在 500+ 商品时开始可见。 |

**问题计数**：P0 **3** 项 · P1 **15** 项 · P2 **26** 项（逐条见 §三 / §四；§三.7 末尾那张 23 行表里有两行已按 P1 计入）。

---

## 一、范围、方法与局限

### 1.1 读了什么

| 层 | 文件 | 说明 |
|---|---|---|
| 规范 | `data_model.md`（702）· `rules.md`（615）· `sync_protocol.md`（579）· `threat_model.md` · `testing.md`（771）· `schema_migration.md` · `Stability_Test_Principles.md` · `Project_Audit_Principles.md` | 判定基准 |
| core | `db/`（schema 441、database 265、read_failures 284）· `dao/`（9 个）· `models/`（11 个）· `rules/`（rule_engine 1156、cost_policy 136、seq_counter 39、doc_no_generator 63、product_code_generator 61）· `documents/`（sale/purchase/delivery/return/settlement/stocktake service + drafts）· `sync/`（sync_client 724、whitelist 170、sync_pull 194 …）· `master_data/` | 业务主体 |
| host | `sync_server.dart`（1077）· `http_server.dart`（277）· `auth.dart`（174）· `pairing.dart` · `service_controller.dart` | 同步入站 |
| app | `mobile_sync_service.dart`（510）· `backup.dart`（463）· `data_directory*.dart` · `data_migrator.dart` · `export*.dart` · `mirror_view.dart` · `startup.dart` | 客户端与宿主 |
| UI（一致性面） | `sale_page` / `purchase_page` / `delivery_page` / `stock_page` / `documents_page` / `document_detail_page` / `overview_page` / `parties_page` / `account_page` / `*_flow_page` | 只核对「数字与状态从哪来」 |
| 工具 | `tool/seed_test_data.py`（1710）· `tool/destructive_acceptance.py`（1899）· `tool/import_guard.dart`（501）· `tool/README.md` | 性能评估地基 |

### 1.2 局限（先声明，免得把推演当实测）

1. **没有运行 `flutter analyze` / 测试**：仓库缺 `.dart_tool/package_config.json`，本次为只读审查，未改环境。
   因此「某处会不会溢出 / 会不会卡」类结论是**代码推演 + 既有测试覆盖情况**，落地时以门禁复跑为准。
2. **没有真机性能数据**：本报告给的是**评估方法与门槛**（§五），不是实测结论；唯一引用过的实测数字来自台账
   （二维码 `15.4 s → 3.1 ms`，§BF），用来说明「本项目的性能问题可以从『不可用』量级降到『无感』」。
3. 业务数据不能造（`tool/README.md` §一：只写主数据），所以**性能测试的数据集必须走 `RuleEngine` 生成** ——
   这条既是局限，也是 §五·4 建议的做法。

---

## 二、总体评价：文档里的硬约束，代码真的守住了

先给「守住了什么」，因为这份实现的可贵之处在于**纪律不是写在文档里，而是写在类型和断言里**。

### 2.1 逐条核对：纪律 → 代码证据 → 机械保证

| 纪律 | 代码里的证据 | 机械保证 |
|---|---|---|
| DAO 不开事务（纪律 1） | 9 个 DAO 内无 `BEGIN`；`Db.transaction` 用 `_depth` 计数可重入、最外层 `BEGIN IMMEDIATE`（`database.dart:231-258`） | `SeqCounter._next` / `DocNoGenerator.next` 在**非事务**调用时直接 `StateError`（`seq_counter.dart:28-33`、`doc_no_generator.dart:33-35`） |
| 业务数据只插不改（纪律 2） | `documents` 唯一 UPDATE 入口 `updateStatusAndPaid`，只写 `status` / `paid_amount` / `updated_at`（`document_dao.dart:494-520`）；四张流水无 UPDATE/DELETE | 全仓 grep `UPDATE`/`DELETE` 只在文档表 |
| 真相在流水（纪律 4） | `QueryDao` 五个聚合全从流水算、无余额表（`query_dao.dart:35-88`）；`paid_amount` 由 `_refreshPaidAmount` 依据 `SUM(settlements)` 回写（`rule_engine.dart:914-965`） | `document_dao.settledAmountOf` 用真相口径，注释写明用于校验缓存 |
| seq_no 每表独立、主机分配（纪律 5） | `SeqCounter` 四个方法分别对应四张流水；`MAX(seq_no)+1`（`seq_counter.dart:19-38`） | 唯一索引 `idx_stock_seq` / `idx_money_seq` / `idx_party_ledger_seq` / `idx_settle_seq`（`schema.dart:254/273/291/311`） |
| occurred_at 不参与计算（纪律 6） | 成本按 `seq_no` 取流水；`occurred_at` 只用于展示与筛选 | — |
| 同步落库走 RuleEngine（纪律 9） | `SyncServer` 只把 `Document` 交给 `RuleEngine.dispatch` | 客户端侧无 RuleEngine 调用 |
| 任何资金流挂收付款单（纪律 11） | `_applyImmediateSettlement` 自动生成 `receipt`/`payment` 并写 money/party/settlement 三本账（`rule_engine.dart:823-911`）；主单**从不**直接写 `money_ledger` | `_settle` 里 `doc.accountId == null` / `partyId == null` 直接抛（`:595-600`） |
| 核销五道门槛 | ①account/party ②类型白名单 ③方向 `settleDirections` ④往来方一致 ⑤**按目标求和**后比（`rule_engine.dart:595-701`） | 方向表与 `SettlementService.isInbound` 双视角对齐（`:185-191` vs `settlement_service.dart:213-217`） |
| 退货成本按原单比例精确回退（R-11） | `CostPolicy.returnCost` = `累计分摊 − 已分摊`（`cost_policy.dart:86-135`） | 累计超原单量 → `RuleRejection(returnExceedsOriginal)`（业务拒绝，说「怎么办」） |
| 盘点（RULE-009） | `quantity` = 盘点后实际数量、主机算 `diff`、`total_amount` 必须 0、不写 money/party（`rule_engine.dart:761-810`） | `diff == 0` 不产生流水 |
| 拒收收口 | 原单是 `in_transit` 送货单 ⇒ 同事务置 `cancelled`；已签收不动（`rule_engine.dart:549-562`） | 依赖状态判断而非调用方 |
| 读路径不静默 | `decodeRows` 逐行保护 + 计数（`document_dao.dart:442-453`），坏行不会让整页打不开 | 契约测试 `read_failures_test.dart` |

> 结论：**「真相在流水」不是口号，是 `QueryDao` 的全部实现方式**；「主机永远赢」不是策略，是
> `seq_no` 只能由主机的 `SeqCounter` 分配、且用事务断言兜住。这部分不建议为了「性能」去加余额表 ——
> 见 §六·5。

### 2.2 深审点名的「别动」清单（改其它地方时最容易顺手拆掉的东西）

1. **`updateStatusAndPaid` 的签名式白名单**（`document_dao.dart:494-520`）：参数里没有第四列，错误写不出来。比任何注释都可靠。
2. **`incoming` 求和上限**（`rule_engine.dart:660-691`）：注释把「为什么不能逐条比」写在代码旁边，是最容易被「优化回去」的一处。
3. **`CostPolicy.returnCost` 的「累计分摊 − 已分摊 + abs + 由类型定符号」**（`cost_policy.dart:86-135`）：一份代码同时服务三种原单，余数自动吸收。别为「可读性」拆成两个分支。
4. **`inboundCost(DocumentLine)` 收整行而不是收数字**（`cost_policy.dart:20-28`）：用签名挡住 `qty × unit_price` 回流。
5. **`_requirePayee`**（`rule_engine.dart:1117-1128`）：「有欠款就必须有往来方，否则欠款凭空消失」。
6. **送货 status 与 `paid_amount` 解耦**（`rule_engine.dart:923-948` + `markDelivered:985-1045`）：「未签收时钱到了状态不动」「重复签收不写 `updated_at`」。
7. **业务拒绝 / 内部 bug 双通道**（`rule_rejection.dart` + `dispatch:276-300`）：`detail` 恒不进 `reason`，让「把诊断细节写进用户文案」**不可表示**。
8. **白名单 fail-closed**（`whitelist.dart:126` 未知表 ⇒ 全部键判非法）+ **列名只来自白名单、值一律 `?` 绑定**（`sync_server.dart:1057-1076`）。
9. **复合游标谓词**（`sync_server.dart:821-837`）：`col > ? OR (col = ? AND id > ?)` + `ORDER BY col, id`，不是会死循环的「大于等于再过滤」。
10. **明细从「本页主单的实际结果」派生**（`sync_server.dart:848-851`），不重跑一遍谓词 —— 结构上排除页边界错位。
11. **队列清理用整轮累计 `appliedAll`**（`sync_client.dart:389/497/507`），不只是「拉到底才清」。
12. **镜像 `foreignKeys:false` 是构造期硬拒绝**（`sync_client.dart:51-60`）+ `ON CONFLICT DO UPDATE`（不用 `REPLACE`）。
13. **迁移的环级验证三连**（`database.dart:459-604`）：停在 v2 / 断点续跑 / `before-vN` 分版本备份，以及「降级形状 == 化石形状」的元测试 —— 解决的是「测了一个臆造的形状」这种失效模式。
14. **三处「必须在事务内」的 `StateError`**（`seq_counter.dart:28-33`、`doc_no_generator.dart:33-35`、`product_code_generator.dart:43-48`）：纪律写成了运行期断言。
15. **`read_failures` 的完整设计**（去重键、`_acknowledged`、「绝不记经营数据」、`withRow` 上下文、`decodeRows` 那个刻意的宽 catch）—— 别为「干净」把它收窄。

---

## 三、问题一：业务逻辑 vs 文档设计要求

### 3.1 P0（3 项）

| # | 一句话 | 影响面 | 证据 |
|---|---|---|---|
| **P0-1** | 单号生成器同类型同日**第 1000 单**起撞号 | 繁忙日整天开不了单 | `doc_no_generator.dart:32-47`、`document_dao.dart:525-533` |
| **P0-2** | 商品「编辑」的 UPDATE 漏了 v3 的 `package_unit`/`package_size` ⇒ 包装换算**改不动、清不掉** | 桌面 + 手机镜像的编辑路径；开单按箱换算会照旧值算 | `product_dao.dart:156-183` |
| **P0-3** | 同步「最近更新窗口」按 `updated_at **升序**` 取 limit 条 ⇒ 最新收款/签收状态**永远排在队尾进不来** | 手机看到的是几天前的旧状态（「未收」）⇒ 重复催款/重复收款 | `sync_server.dart:869-887` |

#### P0-1 单号生成器在同一类型、同一天第 1000 单起会撞号

| 项 | 内容 |
|---|---|
| 现象 | `DocNoGenerator.next` 取「同前缀最大单号」→ 解析序号 +1（`doc_no_generator.dart:32-47`），而取最大值靠 `ORDER BY doc_no DESC LIMIT 1`（`document_dao.dart:525-533`）—— **纯字典序**。 |
| 触发 | 单号格式 `XS20261021-001` 补零**三位**（`docNoGenerator.dart:46`）。当天第 **1000** 单会产出 `…-1000`（四位）。下一次取最大值时字典序比较 `…-999` vs `…-1000`，第一位 `9 > 1` ⇒ **取回 `999`** ⇒ 序号又是 `1000` ⇒ `documents.doc_no` UNIQUE 冲突。 |
| 后果 | **当天第 1001 单起，该类型全部无法开单**。`RuleEngine.dispatch` 的 `catch` 把它归为「内部 bug」，用户看到的是「规则执行失败，请再试一次」——**再试永远不会成功**。恢复办法只有改日期或等第二天。 |
| 影响面 | 每种类型每天 1000 单。收付款单（`SK`/`FK`）与销售（`XS`）同步增长：1000 笔生意 = 1000 张 `XS` + 视收款情况最多 1000 张 `SK`。繁忙小店促销日 / 春节前有实际可能。 |
| 关键对照 | **商品编码器已经解决了同一问题**：`ProductDao.latestCode` 用 `ORDER BY LENGTH(code) DESC, code DESC`（`product_dao.dart:126`），注释还专门写了「位数变化不会取错」。⇒ **这是纪律 18 说的同构代码漏改：两个生成器、一个按长度排、一个没排。** |
| 建议 | 两条任选：① `latestDocNo` 改 `ORDER BY LENGTH(doc_no) DESC, doc_no DESC`（**不改格式、不用迁移**，历史单号照旧可解析）；② 补 `padLeft(4)` 并把比较改成按解析后的整数（要写迁移/兼容，成本高）。**推荐 ①**，并给 `doc_no_generator_test` 补一条「同日 1000 单」用例（造 999 条现有单号直接断言 next 不重复）。 |
| 证据 | `doc_no_generator.dart:32-47`、`document_dao.dart:525-533`、`schema.dart:187`（UNIQUE）、对照 `product_dao.dart:123-127` |

#### P0-2 商品「编辑」会静默丢弃包装换算（`products` 的 UPDATE 列清单漏两列）

| 项 | 内容 |
|---|---|
| 现象 | v3 给 `products` 加了 `package_unit` / `package_size`（`schema.dart:139-140`，迁移 `:398-399`）。`Product.toRow()` 含这两列（`product.dart:99-100`），**`insert` 走 `toRow()` 所以建档正常**（`product_dao.dart:25-30`）；但 `update` 是**手写的 SET 列清单**，止于 `package_note`（`product_dao.dart:159-165`）—— **两列根本没进 SQL**。 |
| 调用链 | 桌面：`ProductService.update` 正确构造了带两列的 `Product`（`product_service.dart:175-186`）→ `_products.update(updated)`（`:194`）→ 两列被丢掉。手机镜像：`QueueMasterSink.updateProduct` 抄了同一套写法（`master_data_sink.dart:429-450`）→ 同样丢。 |
| 用户看到什么 | 在「编辑商品」里把「1 箱 = 48」改成 24 → 点保存 → 成功提示、表单回显 24 → **重开这个商品仍是 48**；把两格清空 → 清不掉，开单仍按箱换算。⇒ 「改了没生效」+「数量按 48 算」= 账目差一倍。 |
| 为什么测试没抓到 | `product_service_test.dart:827-834` 只测 **create 后读回**，全套无「update 后读回 `package_*`」用例；`schema_test` 只比对列存在。 |
| 为什么现在最容易踩 | `Agents.md:92` 刚在 2026-10-21 更正为「包装换算已完整落地，可以宣称该能力」—— **宣称为真，编辑路径为假**。上一轮界面审查还专门把「建档 UI 已接线」写成了正面结论。 |
| 建议 | ① `ProductDao.update` 的 SET 清单**以 `Product.toRow().keys` 为单一来源**生成（与 insert 同源，从结构上消除漂移）；② 补一条「update 后读回」测试（改包装 → 读回 → 清空 → 读回）；③ 顺手把 `party` / `account` 的 UPDATE 列清单与各自 `toRow()` 对一遍（本次核对这两处一致，只有 products 漏）；④ 加一条**通用**守卫：对每张主数据表断言「`toRow().keys` ⊆ `INSERT` 列 ∧ ⊆ `UPDATE` 列」。 |

#### P0-3 同步「最近更新窗口」取的是**最旧**的 limit 条

| 项 | 内容 |
|---|---|
| 机制 | `documents` 的主游标是 `created_at`（不可变），事后改 `status`/`paid_amount` 的老单靠一个**「最近更新窗口」**补齐：`WHERE updated_at > ? ORDER BY updated_at, id LIMIT ?`（`sync_server.dart:869-873`）。 |
| 缺陷 | `ORDER BY updated_at` **是升序** ⇒ 窗口取的是「窗口期内**最早**动过的那批」。而合并时只取 `room = limit - pageDocs.length` 条（`:883-887`），**主分页一满，窗口一条都进不来**；不满足时也只拿最旧的那些。下一轮同步窗口重算，**同样那批最旧的行仍排在最前** ⇒ 最新的收款/签收**永远轮不到**，直到旧行滑出 7 天窗口。 |
| 推演 | 店每天 200 单、每单都有收款 ⇒ 7 天内约 1400 张单在窗口里；`limit` 取 500 ⇒ 今天收的款要等约 **4.5 天**（7 − 500/200）才可能带上；`limit` 取 200 ⇒ 几乎永远差一步。 |
| 业务后果 | 手机端「单据 / 往来 / 概览」显示的是**几天前的欠款状态**。老板可能照着它**再催一次款**（客户已付）或**重复收款**。这是本报告里对「界面与后台不一致」最严重的一处 —— 不是显示歧义，是**状态滞后到能引发重复收钱**。 |
| 现有测试为何漏 | 测试里的窗口数据量始终小于 `limit`，没有一条覆盖「窗口内行数 > limit」。 |
| 建议 | ① `ORDER BY updated_at **DESC**, id DESC LIMIT ?` 后在内存反转（一行改动，语义从「最早动过的」变成「最近动过的」—— 与「补最新状态」的初衷一致）；② **顺手补索引** `CREATE INDEX idx_documents_updated ON documents(updated_at, id)`（`documents` 目前**没有** `updated_at` 索引，`schema.dart:202-208`；实测 `EXPLAIN` 是 `SCAN documents` + `TEMP B-TREE FOR ORDER BY`，2 万单 10–40 ms、10 万单 50–200 ms）；③ 窗口若被截断，**单独**置一个 `doc_window_truncated` 之类的标志（不要污染主分页的 `has_more`，`:874-877` 的理由成立），让客户端知道「还有更新没补上」；④ 补一条「窗口 2×limit 行」的测试，断言**最新的那批**在响应的 `documents` 里。 |

### 3.2 P1：其余正确性问题

| 项 | 内容 |
|---|---|
| 文档说 | `docs/rules.md:316`「超收/预收 = N 条指向具体单 + **1 条 `target_doc_id = null`**」；`:317`「用预收核新单 = 新建 1 条 settlement，`receipt_doc_id` 指向原收款单」。 |
| 代码做 | **超收 = 找零，不落库**：UI 侧按未收额**封顶**（`settlement_service.dart:318-327`），差额作为找零只在界面提示；规则层对 `requested > total` 直接**拒绝**（`rule_engine.dart:692-701`）。全程**不生成** `target_doc_id = null` 的 settlement。 |
| 谁对 | 裁定对：§AJ·AI-4（「落库永远是应收，找零是现金箱内部流动，不进账、不持久化」）+ §AX·一（3甲：超收改为封顶 + 按钮文字「记 ¥93 并找零 ¥7」）。**过时的是 `rules.md` 那张表。** |
| 连带过时 | `docs/testing.md:263`「超收 → 预收余额（`target_doc_id = null`）正确」—— 这条测试要求与现行行为相反，实际存在的是 `immediate_payment_test.dart:551`「预收（`target_doc_id = null`）→ 记录但不核销任何单」，测的是**直接传 null allocation** 的路径，不是「超收」。 |
| 风险 | 下一个人读 `rules.md` 会照它实现「预收余额」，与 `settlement_service` 冲突；审计（`Project_Audit_Principles.md` 第一层）会判定为「实现漏了」。 |
| 建议 | 改文档而不是改实现（纪律 17 的反向用法）：`rules.md` §RULE-004 场景表加一行「超收 → **找零，不落库**（§AJ·AI-4）」，并把「用预收核新单」标为 **v1.1 候选**（`:319-321` 已有这个口子，但表里没标）。`testing.md:263` 同步改口径。 |

### 3.3 P1：`rule_engine.dart` 头注释仍在说「离线签收未实现、R-3 待裁定」

- 文件头 `rule_engine.dart:114-118`：「## 未实现（有意）**离线签收**（`documentAction: mark_delivered`）需要…属待裁定项 **R-3**，随 `SyncServer` 落地…v1 的替代路径是主机本地的 `markDelivered`」。
- 同一文件 `:969-984`：`markDelivered` 的注释写「两条路径共用这里：① 主机 UI；② 同步通道 `documentAction: mark_delivered`（**R-3 已于 2026-09-29 裁定**）」。
- `Agents.md` §4.2「动作归约（R-3）」也写「已裁定并落地」。⇒ 头注释那段是**旧状态**，且**同一文件内自相矛盾**。
- 风险：这正是 `Project_Audit_Principles.md:7` 点名的「文档-代码漂移」类型（前车之鉴 §AI-1、§AQ·五）。读者按头注释会以为同步签收没做。
- 建议：删掉「未实现（有意）」整段，或改成一句「历史：R-3 曾未裁定，2026-09-29 已落地（见 §H）」——保留历史、不保留错误状态。

### 3.4 P1：部分核销（收付款单金额 > 分配合计）在规则层合法，但账上看不出来

- 规则层允许 `requested < doc.totalAmount`（只拦「大于」，`rule_engine.dart:692`）；`rules.md:302` 的约束也是 `≤`。
- 此时：`money_ledger` 记了全额进账、`party_ledger` 冲了全额欠款、`settlements` 只记了部分 ⇒
  **往来余额比「单据未收合计」少「未分配额」**，而**没有任何查询/界面**能显示这笔未分配的钱
  （`settlement_dao` 的「预收余额」只在存在 `target_doc_id = null` 行时才算得出来，`settlement_dao.dart:38/78`）。
- **v1 不会发生**：UI 走 `SettlementService.settle`，一律按未收额封顶（`settlement_service.dart:326-327`）。
- **什么时候会发生**：① 同步通道直接推 `receipt` + 部分 `allocations`（`SyncServer` 只过类型白名单）；
  ② v1.1 的「批量收款 / 预收入口」接上以后（`rules.md:319-321` 已登记为候选）。
- 建议：二选一 —— ① 规则层要求「收付款单金额 = 分配合计」（**最省事、语义最干净**，与「找零不落库」一致）；
  ② 保留合法性，但把差额显式落成 `target_doc_id = null` 的 settlement（回到 `rules.md` 原设计），
  并需要一个「预收余额」查询面。**先做 ①，等 v1.1 再谈 ②** —— 否则账上会先出现一笔没人能解释的钱。

### 3.5 P2：其余偏差（逐条短记）

| # | 问题 | 证据 | 影响 | 建议 |
|---|---|---|---|---|
| 1 | `_prepare` 只在单号是「待同步-」前缀时才重新生成正式号，**客户端若发来一个像正式号的 `doc_no`，主机会原样采用** | `rule_engine.dart:1050-1059`、`document.dart:152-153` | 与「单号主机生成」不一致；恶意/异常客户端可指定单号（撞 UNIQUE ⇒ 内部错误） | `_prepare` 无条件重新生成，或在 `SyncServer` 入站时剥掉 `doc_no` |
| 2 | `_stocktake` 用 `Map<productId, 实际数量>` 收集，同商品重复行会**静默合并**（后者覆盖前者） | `rule_engine.dart:1131-1133` | 盘点单里同一商品出现两次 ⇒ 少盘一次、差额算错 | 收集时检测重复并拒绝（业务拒绝，文案：「同一商品出现了两次」） |
| 3 | `cost_policy.dart:50-51` 说盘盈成本边界「**已在 R-8 记录待裁定**」，而 `Agents.md` §五写「R-8…**已按当前处置实现、不阻断**」 | `cost_policy.dart:48-63` vs `Agents.md` §五 | 读者分不清「未裁」还是「已裁」 | 改注释为「R-8 已按当前处置实现（盘盈用加权均价），见台账附录 D」 |
| 4 | 数据库只设了 `synchronous = NORMAL`、`foreign_keys`，**没有 `busy_timeout`**、也没有显式 `wal_autocheckpoint` | `database.dart:125-126` | 与 `tool/README.md:226-230` 记录的「WAL 长期 900 KB 不归并」「改目录名绕过单实例锁」两现象直接相关：一旦出现第二个写者，SQLite 立即 `SQLITE_BUSY` 而不是等锁 | `Db.open` 加 `PRAGMA busy_timeout = 3000`；WAL 大小写进性能基线（§五） |
| 5 | 单行插入时 `SeqCounter` 每次 `SELECT MAX(seq_no)+1`，一张 20 行明细的单要跑约 **24 次** MAX 查询 | `seq_counter.dart:34-37` + `rule_engine.dart:513-530` | 索引 seek，单次微秒级，**不是瓶颈**；但它是「每行一次 FFI 往返」的结构，批量导入时会放大 | 不必现在改；若做批量导入（v1.1）再改成「事务内取一次 + 内存自增」 |
| 6 | `_settle` 对 `allocations` 的**方向校验**只在 `required != null` 时生效 | `rule_engine.dart:635-644` | 若将来往 `allocatableTargetTypes` 里加了新类型却忘了写 `settleDirections`，新类型会**跳过方向校验**（静默放行） | 把「白名单 ⊆ 方向表」写成一条启动期/测试期断言 |

### 3.6 P1：规则边界（深审补充，4 项）

#### B-1 拒收没有校验「全量」⇒ 部分退货也能把送货单整单作废

| 项 | 内容 |
|---|---|
| 文档 | `Agents.md:94`「**拒收 = 全量 `sale_return` ref delivery`**」；`rules.md:215-219` 同义。 |
| 实现 | `rule_engine.dart:555-562` 的收口条件只有 `original.docType == delivery && original.status == inTransit` —— **不看本次退货量是否等于剩余可退量**。 |
| 可达路径 | 退货页的「拒收」只做**预填**全部可退量（`return_page.dart:12`、`:34`），数量框仍然可编辑（`:459-469`）。用户把 10 件改成退 4 件 → 引擎照样把送货单置 `cancelled`。 |
| 后果（账实不符） | ① `inTransitByProduct` 不再含剩余 6 件（`query_dao.dart:53-60`）⇒「在店可售」多算 6 ⇒ **低库存告警失真**；② 单据详情印「已作废（客户拒收，货已退回）」（`document_detail_page.dart:617-618`），而 6 件的欠款仍挂在 `party_ledger`；③ 测试 `return_test.dart:584-620` 走的就是 4/10 部分退货，只断言库存与往来、**没断言原单状态**，所以没拦住。 |
| 建议 | 规则层加判据：本次退货量（同商品逐项）= 原单剩余可退量 才允许收口；否则保持 `in_transit`。更干净的做法是给送货单独一个动作（`refuse_delivery`），语义显式，不靠 `sale_return` 反推。两种做法都要补「4/10 部分退 ⇒ 原单仍 `in_transit`、在途 = 6」的测试。 |

#### B-2 主单创建态 `status` 由同步 payload 直写，引擎不归一

- `whitelist.dart:75-87` 把 `status` 列进 `documents` 的可写列；`sync_server.dart:337-347` 只补 `doc_no` / `paid_amount` / `time_estimated` / 时钟，**`status` 原样来自客户端**；`_prepare`（`rule_engine.dart:1050-1059`）只改单号与时钟；全仓唯一强制状态的地方是送货的 `_delivery:419-423`。且 `_applyImmediateSettlement` 在 `entries.isEmpty` 时直接 return（`:829`），**没有立即收付款就不会触发 `_refreshPaidAmount`**。
- 后果：可造出 `status = settled` 而 `paid_amount = 0` 的单（破 `data_model.md` 不变量 B4 与「status 不直接设置」）；「未结清」筛选、详情页金额卡、状态列三者互相打架。同一路径还能造出 `status = cancelled` 的盘点单却照样写库存流水（`_stocktake` 不看 status）。
- 建议：`_prepare` 之后按 `doc_type` **归一化创建态**（销售/采购/退货/盘点 → `confirmed`；送货 → `in_transit`；收付款 → `settled`），客户端给别的值直接拒绝；同步层把 `status` 从 `createDocument` 的可写面里去掉。

#### B-3 盘点录不进「实盘 0 件」

- `stocktake_draft.dart:71` 把 `qty <= 0` 判成「数量要填正整数，比如 10」；`:78` 的 `quantityValue` 对 0 返回 `null`，于是该行被**静默丢弃**（`:172`）。而规则层接受 0（`rule_engine.dart:789` 只拒 `actual < 0`），`data_model.md` 的 `diff = 实际数量 − 账面数量` 也不排除 0。
- 后果：货卖光 / 报损 / 清空时，**盘点这条唯一合法通道走不通**；用户只能开一张金额 0 或虚构价格的销售单去冲库存 —— 那不是盘点，是伪造交易额（销售额虚增、毛利错、流水里留下一笔不存在的交易）。
- 建议：把「数量」的合法域从「正整数」改成「非负整数」（0 合法、空 = 不参与），文案改「填店里实际有多少，卖光了就填 0」。这是**改现状 + 改测试**的动作，按纪律 12 只报告，等裁定。

#### B-4 退货行用**当前** `package_size` 重新解释原单的单位

- `return_service.dart:174-198` 把 `product.packageSize`（**当前档案**）灌进可退额度，`return_draft.dart:103-109` 用它做 `toBaseQuantity`。而 `data_model.md` §3.2 第 7 条要求 `entry_*` **不因档案变化而重解释**。
- 后果：原单按「1 箱 = 12」录了 36 瓶，之后档案改成 24 ⇒ 退 1 箱会落库 **24** 瓶：库存多回 12、可退额度判断错、默认退货金额也错。
- 建议：退货按**原单行**的比例反算（原单行自带 `entry_quantity` / `quantity`），或给 `document_lines` 落一个换算快照；补「改 size 后退货仍按原 size」的测试。

### 3.7 P1 / P2：同步与数据层（深审补充）

#### C-1 主数据 update↔update 乱序不收敛（同步协议 §8.1 的「收敛」只对 create↔update 成立）

- `sync_server.dart:648-657`：主机**没有该行**时按 payload 建档并写 `sync_version = 0`、**忽略 `base_version`**；随后旧的那次 update（`base = 0`）到达时 `version(0) == baseVersion(0)` ⇒ **旧值覆盖新值**。
- 另一支：U1(`base=0`) 进退避、U2(`base=1`) 先到 ⇒ 版本不等 ⇒ `conflict` ⇒ 客户端用 `server_state` 覆盖本地并**删掉 U2 条目**（`sync_client.dart:252-258`）⇒ 用户「第二次改价」被静默回退，还提示「已在别处被修改」（其实没有别处）。
- 现实场景：手机改两次售价（12 → 11.5），中间网络抖了一下 ⇒ 最终两侧都是 12，老板以为改成了 11.5。
- 建议：`_updateMasterData` 在「行不存在」分支也校验/收敛（例如把 `base_version == 0` 视为「无版本要求」并在建档后**把 payload 的 sync_version 设为 1**，或对同 id 的 update 做「后到不再覆盖」的版本单调判断）；并把 `sync_protocol.md:706-714` 的「什么顺序都收敛」限定为「create↔update 收敛，update↔update 按主机版本单调」。

#### C-2 换主机：`sent` 条目两头落空（静默丢数据 + 一条永远清不掉的残留）

- `resetForNewHost` 只挂起 `queue.unsent()`（`mobile_sync_service.dart:156`），而 `unsent()` 明确 `WHERE status != 'sent'`（`sync_dao.dart:124-133`）；随后 `rebuildMirror()` 把 9 张业务表 drop（`:167-172`）。
- 场景：手机离线新建商品「冰红茶」→ push 成功转 `sent` → **pull 还没跑** → 扫另一台电脑的码 ⇒ 新主机没有、镜像被重建掉、三态条不显示 `sent` ⇒ **用户刚建的商品凭空消失**；队列里留一条永远不会被确认的 `sent`。
- 建议：`resetForNewHost` 改成「`pending` + `failed` + `sent` 一律转 `failed` 并说明原因」；`sent` 条目的语义是「主机已收下但本机没确认」，换主机后它**必须**降级为可处置状态。另：`lastHostSwitchHeldEntries`（`:428`）全仓无 UI 读取（grep `lib/` 零命中），注释承诺的「多说一句」没接线。

#### C-3 「重新生成配对码」＝换 hostId ⇒ 重扫即全量重置

- `auth.dart:137-147` 的 `reset()` 生成**新 `hostId`**，`service_controller.dart:295-302` 的 `resetToken()` 调它；客户端只比 `hostId`（`mobile_sync_service.dart:415-419`）。
- 后果：用户重启电脑后想再看二维码（明文不落盘）→ 手机重扫 → `hostId` 变了 → **全量重建镜像 + 离线队列全部转 `failed`**。`Agents.md` §4.2「同主机重新配对（`host_id` 不变）不清」只在「扫同一张旧码」时成立，实际几乎总是走 `resetToken`。
- 建议：把「主机身份」与「配对令牌」拆开 —— `host_id` 持久化（不随 token 重置变），令牌可轮换。这是一处**协议级**改动，需要裁定。

#### 数据层与同步层的 P2（合并清单）

| # | 问题 | 证据 | 建议 |
|---|---|---|---|
| 1 | 「未结清」筛选拿 `paid_amount` **缓存**当真相（注释却写「与 `unsettledCentsOf` 同一口径」） | `document_dao.dart:351-357` vs `settlement_service.dart:125-132` | 改 JOIN `settlements`（`idx_settle_target` 已有，`_summaries` 里已有同款 JOIN）；并把「缓存只许出现在 INSERT 与 updateStatusAndPaid，读路径一律用流水」写进 `data_model.md §3.1` |
| 2 | 导出不检查「跳过坏行」的计数就落一份缺行 CSV；客户端库存估算会因跳一条队列行而少算 | `read_failures.dart:238-254`；四个导出入口 `documents_page.dart:286-300`、`products_page.dart:175`、`parties_page.dart:141`、`stock_page.dart:281`；`stock_delta.dart:79-87` | 任何「把数据交出去」的出口自己确认完整性：至少把「跳过 N 条」写进导出结果，或拒绝并说明；别只依赖全局横幅 |
| 3 | `documents.party_id / account_id / ref_doc_id` **无外键**（其它表都有） | `schema.dart:190-194` | 补 FK，或在 `data_model.md` 写明「为什么这三列不建 FK」（软引用：允许往来方先删？） |
| 4 | `SettlementView.occurredAt` 实际装的是 `created_at`（`settlements` 没有 `occurred_at` 列） | `settlement_dao.dart:113-118` | 改字段名或加列，别让「发生时间」在 UI 上悄悄变成「录入时间」 |
| 5 | `todaySummary` 没有上界 ⇒ **未来日期的单据**（补录/时钟错）会被算进「今日」 | `query_dao.dart:102-111` | 加 `AND occurred_at < 明日零点` |
| 6 | `limit` 不校验；`limit = 0` ⇒ `has_more` 恒 true | `http_server.dart:220-221`、`sync_server.dart:813/836` | 校验 `1 ≤ limit ≤ N`，越界返回 `malformed_parameter` |
| 7 | `reason_code` 解析了但**从不参与分支**；所有 `rejected` 一律退避 11 次进死信 | `sync_operation.dart:179`、`sync_client.dart:259-265` | 按 §8.5.2 用 `reason_code` 分类（尤其 `reference_missing`），协议性错误不要白烧 11 次 |
| 8 | 401/403 只在「立即同步」清 pairing | `app.dart:1268-1270`；`autoPush` 不清（`mobile_sync_service.dart:371-374`） | 把「认证失效 → 清配对」收进 `MobileSyncService` 一处，三条路径共用 |
| 9 | 客户端下界用**手机裸时钟**（`_clock()`），而 `estimatedServerTime()` / `recordClockOffset` **生产零调用** | `sync_client.dart:445/454/269`、`:603-611` | 手机时钟快 > 7 天 ⇒ 窗口恒空、状态永不更新。把手表偏移接进下界（`/api/health` 已返回 `server_time`） |
| 10 | `documentAction` 的 conflict 判据只看「存在且是 delivery」⇒ 主机内部错误也被判成 conflict，客户端删条目 | `sync_server.dart:258-267` | 判据改成 `outcome.code == actionNotApplicable` |
| 11 | 窗口只带主单、不带明细，而 `document_lines` 无独立游标 | `sync_server.dart:848-851`（明细先算）vs `:865-888`（窗口后并） | 只经窗口到达的主单**永久缺明细**；窗口合并后要补 `_linesOf` |
| 12 | `PairingPayload` 不校验 `v` | `pairing_payload.dart:75` | 版本不符拒绝并给「请升级」 |
| 13 | `data_directory.dart:235` 的**用户可见文案**含禁用词「数据库」 | `user_text.dart:52` 明确禁用；`expectNoDevTerms` 只覆盖手册/引导/扫码/HTTP | 改「数据文件」；把 `DirectoryAdvice` 的文案也纳入禁用词断言（这是契约测试的覆盖缺口） |
| 14 | 「普通退货单是否进默认列表」有两套口径：DAO 默认 `rootsOnly: false`，UI 传 `true` | `document_dao.dart:150` vs `documents_page.dart:259` | 把默认改成 `true`（旧分支只留给导出/明确筛选），或删旧分支并改测试 |
| 15 | 核销五道门槛缺「目标未作废」：已作废的单仍可被收款/付款核销 | `rule_engine.dart:589-751` 全程不看 `target.status` | 加第 6 道门槛（`cancelled` ⇒ 拒绝，文案由 core 给）；测试「用 receipt 核销 cancelled delivery ⇒ rejected 且四表零行」 |
| 16 | 退货超额两处文案不同源，规则层把单位写死成「件」 | `cost_policy.dart:120-121` vs `return_draft.dart:155-168` | 规则层只报数量与单号，单位化文案统一走 `return_draft` |
| 17 | `_stocktake` 用 Map 收集实际数量，同商品重复行**静默后者覆盖前者** | `rule_engine.dart:1131-1133`（草稿层有拦截 `stocktake_draft.dart:144-159`） | 规则层检测重复 `productId` ⇒ 业务拒绝 |
| 18 | `Money.fromYuan(double)` 是公共 API 但仅测试使用 | `money.dart:8` | 标 `@visibleForTesting` 或移进测试工具 |
| 19 | `Document.updatableColumns` 是**死常量**（全仓无引用） | `document.dart:155-160` | 删掉，或让它成为 `updateStatusAndPaid` 的唯一来源 |
| 20 | `stock_ledger.dart:11` 的注释仍是 v2 口径（`qty × unit_price`），v3 已是 `line.amount` | `stock_ledger.dart:11` vs `cost_policy.dart:20-28` | 改注释 |
| 21 | `schema_migration.md:26` 示例仍写 `version = 2`，与同文档 §八 的 `3` 冲突 | `schema_migration.md:26` | 改文档 |
| 22 | `Db.probe` 对不存在的文件是**创建**而非探测 | `database.dart:68-80`，现靠三处注释规避（`bootstrap.dart:136/173`） | `open(readOnly: true)` 或改名 `ensureOpenable` |
| 23 | 迁移第 5 条「备份失败即不迁移」**实现到位但零测试** | `database.dart:176`、`:209-224` | 造不可写路径即可测（唯一缺测的硬约束） |

---

## 四、问题二：界面展示与后台逻辑的一致性

### 4.1 先给「一致」的部分（这是主体）

| 界面数字 | 数据来源 | 是否同源 |
|---|---|---|
| 库存「账面」 | `QueryDao.stockByProduct()` = `SUM(stock_ledger.quantity)` | ✅ 与纪律 4 同源 |
| 库存「在途」 | `QueryDao.inTransitByProduct()` = 送货单 `in_transit` 的明细合计 | ✅ |
| 库存「在店可售」 | 账面 − 在途（`query_dao.dart:66-72`） | ✅ 且注释写明「低库存告警必须用它」 |
| 账户余额 | `initial_balance + SUM(money_ledger.amount)`（`query_dao.dart:77-82`） | ✅ |
| 往来余额 | `SUM(party_ledger.amount)`，正=应收（`query_dao.dart:85-88`） | ✅ |
| 单据「未收」 | `SettlementService.unsettledCentsOf` = 金额 − 已核销 − 退货冲减（`settlement_service.dart:125-132`） | ✅ 详情页用它（`document_detail_page.dart:131/331/419`） |
| 单据「状态」 | `status` 缓存 + `displayStatus` 在 `confirmed` 上按真实未收覆盖（`settlement_service.dart:176-179`） | ✅ 有明确「只覆写 confirmed」的边界 |
| 导出金额 | 全部 `Money.format`（无千分位），`export_tables.dart:12-24` 有说明与断言 | ✅ 与纪律「导出的金额不带千分位」同源 |
| 手机「未同步影响」 | `StockDelta` + `PendingMarks`，UI 标「待同步 / 简算」 | ✅ 诚实口径 |

### 4.2 P1：库存页把「成本余值」标成了「成本（均价）」——会直接误导定价

| 项 | 内容 |
|---|---|
| 界面 | 库存行第二行显示 `成本（均价）` + `¥35.00`（`stock_page.dart:588-604` 的 Tooltip 标签、`:632-633` 的金额） |
| 后台 | `costCents` 来自 `QueryDao.costByProduct()` = **`SUM(stock_ledger.total_cost)`**，即「剩余存货的成本**总额**」（`query_dao.dart:40-49`，注释自己写的是「库存成本**余值**」） |
| 反证 | `test/stock_page_test.dart:290-300`：采购 10 件 @3.50 ⇒ 断言出现「成本（均价）」且 `¥35.00`；`reason` 写「成本 = 10 × 3.50」。⇒ **显示的是总额，标签说的是单价。** |
| 对照（同一件事在别处做对了） | 商品流水页显示「成本 ¥35.00（**每件 ¥3.50**）」（`stock_flow_page.dart:207-215`，用的是 `unit_cost` 派生字段） |
| 为什么严重 | 目标用户会拿「成本」定价。10 件货的真均价 ¥3.50，界面写「均价 ¥35.00」——按它定价会**贵 10 倍**或**以为亏本**。这是本报告里唯一会直接导致经营决策错误的显示问题 |
| 建议 | 二选一并保持一致：① 标签改「成本（余值）」/「存货成本」；② 显示均价 `¥3.50` + 小字「共 ¥35.00」。**推荐 ②**（用户关心单价），并在 Tooltip 里说清「均价 = 存货成本 ÷ 数量」。同时把 `stock_page_test.dart:300` 的期望一起改对。 |

### 4.3 P1：「未收」有三份实现，其中一份用缓存、一份用真相，还有一份是**筛选条件**

| 位置 | 算法 | 数据源 |
|---|---|---|
| 详情页 / 核销 | `unsettledCentsOf` = `total − SUM(settlements) − returned`（`settlement_service.dart:125-132`） | **真相** |
| 单据列表行 | `unsettled = doc.totalAmount − doc.paidAmount − returnedCents`（`documents_page.dart:537`） | **缓存** `paid_amount` |
| 单据列表「未结清」筛选 | `(d.total_amount − d.paid_amount − COALESCE(r.rsum,0)) > 0`（`document_dao.dart:351-357`），注释却写「与 `unsettledCentsOf` 同一口径」 | **缓存** |

- 目前三者应恒等（`paid_amount` 在同一事务里由 `SUM(settlements)` 回写），所以**不是当前 bug**；
  但它是三条互不引用的实现（纪律 18 的同构漂移温床），而且**注释在撒谎**（说同一口径，实际不同源）。
  一旦 §AR #38 的「退货冲减与退款是否同一笔钱」裁定落地，极易只改一处 ⇒
  **列表说「未结清」，点进去显示「已结清」**。
- 建议：把「真实未收」做成 core 里的一个**纯函数**（输入 `total` / `settled` / `returned`），
  详情页、列表行、列表筛选（改成对 `settlements` 的 `LEFT JOIN`）三处共用；
  并把「缓存列只许出现在 INSERT 与 `updateStatusAndPaid`，读路径一律用流水」写进 `data_model.md §3.1`。

### 4.4 P2：同一张单据详情页上，「已收」用缓存、「未收」用真相

- `document_detail_page.dart:365-369`「已收 ¥X」读 `doc.paidAmount`（缓存）；
  同一张卡的「未收」来自 `unsettledCentsOf`（真相，`:331`）。
- 两者之和在正常情况下 = 总额；若缓存与流水曾不一致（历史数据、手工修库、迁移异常），
  用户会看到「已收 30 + 未收 70 ≠ 100」而没有任何解释。
- 建议：同一个卡片内**只用一种来源**（要么都读真相，要么都读缓存 + 一行「以 X 为准」）。

### 4.5 P2：负的「未收」被钳成 0（已知未裁，但界面会给出反事实结论）

- 先全额收款、再部分退货 ⇒ `unsettledCentsOf` 为负（我方该退钱），而展示函数钳到 0
  （`settlement_service.dart:146-149`，注释点名这是 §AR·二 #38 的第二步待裁）。
- 界面结果：单据显示「不欠」，**实际上我方欠对方一笔退款**。全退的情况另有「已全部退清」文案覆盖，
  但**部分退 + 已全收**这个残角没有文案。
- 建议：在裁定之前，至少把负数显式显示为「多收 ¥X（待退/待抵）」而不是 0 ——
  0 是一个**结论**，负数是一个**事实**，把事实说成结论才是危险的那一步。

### 4.6 P1：导出与界面是**三套口径**（不只是「已收」列）

| 项 | 界面（列表 / 详情） | 导出（`export_tables.dart:130-145`） | 差在哪 |
|---|---|---|---|
| 「已收」 | 详情卡读 `paid_amount`（缓存） | 读 `paid_amount`（缓存） | 同源，但都不是真相 |
| 「未收」 | 详情读 `unsettledCentsOf`（真相）；列表读 `total − paid − returned`（缓存） | **没有这一列** | 会计拿「金额 − 已收付」手工算，**算不出**「未收」—— 因为导出里没有「退货冲减」列，而真相公式是 `total − settled − returned` |
| 「状态」 | `displayStatus(doc, 真实未收)`（`settlement_service.dart:176-179`）：全退/收满后显示「已结清」 | 直接 `docStatusLabel(doc.status)`（原始缓存状态） | **同一张单：界面「已结清」，CSV 写「已确认」** |

- 这不是格式问题，是**同一份账在屏幕与文件里说法不同**（与纪律「导出的金额不带千分位」同一类：用户看不出来，但对账必错）。
- 建议：① 导出补两列「已退货冲减」「未收（真实）」；② 状态列改用 `SettlementService.displayStatus`（与界面同一个函数）；③ 列名把口径写进去（例如「已收付（按单据记录）」）。

### 4.7 P1：库存「在店可售」有唯一定义，但**没有任何页面调用它**

| 项 | 内容 |
|---|---|
| core 的定义 | `QueryDao.availableInStore()` = 账面 − 在途，注释明写「**低库存告警必须用这个，不能用账面库存**」（`query_dao.dart:62-72`） |
| 实际情况 | `grep` 全仓：`availableInStore(` 的调用点**只有测试与自检**，生产代码零调用。 |
| 页面自己算 | 库存页内联重算 `book − inTransit`（`stock_page.dart:249-251`、`:482`）；**开单页干脆不减在途** —— `stockSnapshot()` 返回的是 `stockByProduct()`（账面），负库存提示用的是 `snapshot + unsynced`（`sale_page.dart:1362-1369`）。 |
| 后果 | 有未签收送货单时，**开单页显示的可售比真实多**（那批货已离店、正在路上）⇒ 提醒「库存充足」而实际已该报警 ⇒ **卖超**。而库存页显示的是正确的在售，两页对同一商品给出不同的「还剩多少」。 |
| 建议 | ① 开单页/送货页的库存提示改用 `availableInStore()`（或让 `stockSnapshot()` 直接返回在店可售并同步改文案）；② 库存页改调同一个函数；③ 给 `availableInStore` 补一条「生产调用点存在」的守卫，或干脆删掉它、只留一处实现 —— **现在这个状态最坏：两处实现，core 那份没人用，注释还在说「必须用它」**。 |

### 4.8 P2：几处「看起来精确其实滞后」的漏标，与两处格式不一致

| # | 项 | 内容 |
|---|---|---|
| 1 | 手机**往来页 / 账户页**的余额没有任何「未同步」标注 | 库存页有 `≈ 台账 + 未同步`（`stock_page.dart:744`）、商品/往来/账户行有「待同步」小字，但**余额数字本身**没有：离线开的赊账单未推上去之前，手机上的「应收合计」比真实**少**，而界面看不出这一点（`sync_protocol.md` 要求离线显示一律标注估算）。 |
| 2 | 概览「负库存 N 种」无「仅已同步」标注 | `overview_page.dart:258-262` 只数权威镜像的 `stockByProduct()`；同一张卡上的「今日销售」却有「仅已同步 · 有 N 条未同步」（`:281-289`）。⇒ 手机上「负库存 0 种」可能只是还没同步。 |
| 3 | 手机「导出库存」是权威镜像、屏幕是估算值，文件里无标注 | `stock_page.dart:278-286` + `export_tables.dart:64-98`；拿文件对账会与屏幕不符。 |
| 4 | UI 金额格式**混用** `Money.format` 与 `formatGrouped` | 库存页成本（`stock_page.dart:504`/`:639`）、账户期初（`account_page.dart:305`）、详情让价（`document_detail_page.dart:733`）、选择器售价（`sale_page.dart:1970`）用 `format`（无千分位）；而同屏的找零行用 `formatGrouped`（`sale_page.dart:1147`）⇒ 同一屏出现 `¥12000.00` 与 `¥12,000.00`。导出必须用 `format`（纪律），**界面应统一用 `formatGrouped`**。 |
| 5 | 单据列表/详情**完全不显示 `time_estimated`** | 手机离线单的 `occurred_at` 是估算时刻，桌面上看不出「这是估算时间」；只有三个流水页标「离线」（`stock_flow_page.dart:200` 等）。`data_model.md` 有 `time_estimated` 语义、纪律 6 说它只用于展示 —— 但**展示层没展示**。 |

### 4.9 P2：「小字」与实际数据不符的三处
| 项 | 内容 |
|---|---|
| **「估算」二字没有出现在界面上** | `sync_protocol.md` 与 `Agents.md` §一都写「离线时的库存/往来显示**一律标注估算**」。手机库存行的实际文案是 `≈ 台账 12 + 未同步 +3 = 15（可能负库存）—— 点看是哪几张单`（`stock_page.dart:744-749`）。`≈` + 「未同步」在语义上等价于估算，但**字面上没有兑现承诺**；需二选一：改文案（加「（估算）」）或改文档（承认 `≈` 即标注）。 |
| **展开明细把单位写死成「件」** | `stock_page.dart:757` 的 `'${_signed(...)} 件'` —— 商品单位可能是「瓶 / 箱 / 斤」。按瓶卖的商品这里显示「件」，与同一行的「期初 N（瓶）」（`:746` 用的是 `product.unit`）自相矛盾。建议改用 `product.unit`。 |
| **「今日销售」不含退货冲减，但标签没说** | `QueryDao.todaySummary` 只统计 `sale` / `delivery` 两类，退货与收付款明确不进这张卡（`query_dao.dart:90-132` 的注释），而卡片标题是「今日销售（按单据日期）」（`overview_page.dart:270`）。某天卖 1000 退 200 时，卡片显示 1000 —— 对账时用户会认为「今天卖了 1000」。这是**刻意的口径**，但**没有在界面上说**。建议标题补「（不含退货）」或加一行「已退 ¥200」。 |

---

## 五、问题三：如何评估运行性能

### 5.1 现状盘点（先说不存在的东西）

| 项 | 现状 |
|---|---|
| 性能门禁 | **没有**。`flutter analyze` 是唯一全仓门禁（`Agents.md` §4.4），只管 lint；`tool/typecheck.dart` 只编译 |
| 性能测试 | **没有**。1 350 个用例里无一条时间断言；唯一 `Stopwatch` 是测试辅助的 5 秒超时（`mobile_sync_service_test.dart:264-271`） |
| 性能文档 | `docs/Stability_Test_Principles.md` **有原则、无实现**：第二节写了「连续写入 1000 采购 + 1000 销售 + 500 核销，观察内存/文件/响应时间」，但仓库里没有这个脚本 |
| 数据集 | `tool/seed_test_data.py` **只造主数据**（商品/往来方/账户），且明确拒绝造业务数据（理由正确：绕开 RuleEngine 造出的流水不自洽）。⇒ **没有任何工具能造出「2 万张单据」这种真实体量** |
| 已有实测 | 台账 §BF 有一次完整的方法论示范：二维码 `paint` 里 15.4 s → 缓存后 3.1 ms（5000 倍），并给了「不是机器慢，是 O(n²×9) 对 O(1)」的判据 |

### 5.2 热路径清单（按触发频率 × 复杂度排）

| # | 页面/动作 | 查询 | 触发频率 | 复杂度 | 索引 | 风险 |
|---|---|---|---|---|---|---|
| 1 | 销售/采购/送货开单（**每敲一键**） | `Service.stockSnapshot()` → `SELECT product_id, SUM(quantity) FROM stock_ledger GROUP BY product_id`（`query_dao.dart:35-38`） | 每次 `setState`（`:978/:1127/:1251/:1397/:1415`） | O(全部流水行) | 走 `idx_stock_product_seq` 前缀，仍需扫全表 | **高**：30 万行流水时每键一次全表聚合 |
| 2 | 送货开单（第二张起） | 同上，但 `late final`（`delivery_page.dart:263`） | 每页一次 | 同上 | 同上 | 中：不卡输入，但**数据是过期的**（见上一轮报告 P1） |
| 3 | 库存页（每次 rebuild） | `stockByProduct` + `inTransitByProduct` + `costByProduct` + `inboundProductIds` + `hasAnyStockLedger`（`stock_page.dart:168-172`） | 每次进页/搜索/勾选 | 5 次聚合，其中 1 次带 JOIN | 同上 | 中高：5 次全表扫 |
| 4 | 单据列表 | 单条大 JOIN + 派生表按 `ref_doc_id` 聚合 + `ORDER BY ((occurred_at+?)/86400000) DESC, created_at DESC`（`document_dao.dart:407-440`） | 每次进页/改筛选 | 排序表达式**不可用索引**⇒ 必须全排序 | `idx_documents_occurred` 只能帮 WHERE | 中：2 万单量级可接受；10 万单时排序占主导 |
| 5 | 单据列表核销笔数 | 一次 `IN (...) + GROUP BY`（`document_dao.dart:455-458`） | 同上 | O(200) | `idx_settle_target` | 低（已避免 N+1） |
| 6 | 商品/客户选择器 | `recentProducts` / `recentParties`：先聚合取 20 个 id，**再逐条 `findById`**（`query_dao.dart:249-255`、`:281-287`） | 每次打开选择器 | **N+1（20 次）** | 主键 | 低-中：20 次主键查询 ≈ 亚毫秒，但形态是 N+1 |
| 7 | 概览页 | `todaySummary` + `receivablesSummary`（全表 `party_ledger` 分组）+ `deliveryInTransitCount` + `stockByProduct` + `pendingMarks`（`overview_page.dart:257-265`） | 每次进概览 | 2 次全表聚合 + 2 次全表扫 | 部分 | 中：概览是落地页，冷启动即触发 |
| 8 | 单据保存 | 每条明细分派 1 次 `CostPolicy.outboundCost` → `costSnapshotOf`（聚合该商品）+ `nextStock`（MAX） | 每单 | O(该商品流水) | `idx_stock_product_seq` | 低-中：单商品流水几千行时线性 |
| 9 | 期初录入页 | 每行一个 `TextEditingController` + 一次性 `Column` 全建 | 每页 | O(商品数) | — | 中：**500 商品已记录在案会慢**（`opening_stock_page.dart:15`、台账遗漏 6） |
| 10 | 备份 / 导出 / 迁移 | 备份 `File.copySync` + 副本 `integrity_check`（同步）、导出 `writeAsBytesSync`、迁移走 isolate | 手动/启动 | O(库大小) | — | **高（低配设备）**：库 100 MB 时同步拷贝在 UI 线程 |
| 11 | **单据页搜索（每键）** | `_summaries` + 四路 `LIKE '%q%'` + 每行 2 个相关子查询（`document_dao.dart:305-328`） | 每敲一键 | 实测 `SCAN d`（全表）+ `TEMP B-TREE ORDER BY` | `LIKE %x%` 用不上索引 | **高**：2 万单约 60–300 ms/键 |
| 12 | 成单保存末尾 | `partyBalances()` —— 只是为 SnackBar 说一句「累计欠款」（`sale_service.dart:173-176`，采购/送货同款） | 每单 | **`SCAN party_ledger` 全表** | 无 | 中：每单 10–40 ms，且随经营年限线性增长 |
| 13 | 往来页 / 账户页 | `listVisible()` 内部算一次 balances + 页面**再算一次**（`parties_page.dart:97` vs `party_service.dart:319`；`account_page.dart:84` 同款） | 每次 build | **2 × 全表聚合** | 有 | 中：白白多扫一整张流水表 |

> 上表的「实测」一列来自**在内存库复刻 `Schema.createStatements` 后跑 `EXPLAIN QUERY PLAN`**（SQLite 3.53.1；应用打包 3.52.0，这批形态的规划器行为一致）。见 §5.4 层 1 的实测表。

### 5.3 数据量推演（给「什么时候开始卡」一个依据）

设一个开了 5 年的个体户：**300 商品、2 万张单据、10 万行明细、30 万条库存流水**。

| 热路径 | 扫描量级 | 推演依据 | 结论 |
|---|---|---|---|
| #1 每键全表聚合 | 30 万行 / 次 | SQLite 全表聚合约 **10–50 ns/行**（**量级估计**：桌面 SSD、单进程、含 FFI 往返固定开销；真值须按 §5.4 测） | 单次 ≈ **3–15 ms**。在 `onChanged` 里 ⇒ **打字时每键卡一下**，200% 缩放下更明显 |
| #3 库存页 5 次聚合 | 30 万 × 2 + 10 万 × 1 | 同上 | 单次进页 ≈ **10–40 ms**（可感知） |
| #4 单据列表 | 2 万行排序 + 200 行 JOIN | 排序约 100 ns/行级 | ≈ 2–5 ms（可接受）；**10 万单 ⇒ 10–25 ms**，且全部在主线程 |
| #2 `recentProducts` | 20 次主键 | O(log n) | < 1 ms（形态难看，不是瓶颈） |
| #10 备份 | 库文件 50–200 MB | HDD 顺序写约 **60–100 MB/s** | **0.5–3.5 s 的主线程阻塞**；SSD 约 0.2–0.5 s |

> 上表是**量级推演**，用于排优先级；真值必须按 §5.4 的方法测。判据是：**「打字是否掉帧」看 #1，「进页是否停顿」看 #3，#10 在机械硬盘用户上会成为最明显的一次卡顿**。

### 5.4 可落地的评估方案（四层，从便宜到贵）

#### 层 1：**SQL 执行计划断言**（最有价值，因为确定性）

不测时间、只测**计划形态** —— 在任何机器上结果都一样，可以直接进 `dart test` 当门禁：

```dart
// packages/shensuanzi_core/test/perf/query_plan_test.dart（建议新增）
// 造 1 个商品 + 3 张单 + 若干流水，然后：
final List<Row> plan = db.raw.select(
  'EXPLAIN QUERY PLAN SELECT product_id, SUM(quantity) FROM stock_ledger GROUP BY product_id');
expect(plan.map((r) => r['detail']).join('\n'), contains('idx_stock_product_seq'));
expect(/* 禁止整表临时表 */ ..., isNot(contains('USE TEMP B-TREE')));
```

要覆盖的 6 条：`stockByProduct`、`inTransitByProduct`、`accountBalances`、`partyBalances`、
`listDocuments`（排序那条**预期会**出现 `USE TEMP B-TREE`，那就断言它「只在 2 万行以内出现」并把结论写进注释）、
`recentProducts`。

**已实测的计划（内存库复刻 schema，SQLite 3.53.1）**——把它当基线，收紧成断言：

| 查询 | 实际计划 | 判断 |
|---|---|---|
| `stockByProduct`（`GROUP BY product_id`） | `SCAN stock_ledger USING INDEX idx_stock_product_seq`（**非 covering**） | 可接受，但加 covering 索引能省 30–50% |
| `pull` 的 `updated_at > ? ORDER BY updated_at, id` | **`SCAN documents` + `TEMP B-TREE FOR ORDER BY`** | **要修**（§3.1 P0-3 + 新索引） |
| 单据列表（分桶排序） | `TEMP B-TREE FOR ORDER BY` + 每张收付款单一个相关子查询（内含 `TEMP B-TREE`） | **要修**（两段查询，见 §5.4 建议） |
| 单据搜索 | `SCAN d` + 2× 相关子查询 + `TEMP B-TREE` | **要修** |
| `todaySummary` | **`SCAN documents USING INDEX idx_documents_type_status`（全表，没按日期收窄）** | 加 `INDEXED BY idx_documents_occurred` 或把 `occurred_at >= ?` 提为驱动条件 |
| `recentProducts` | 扫全部 `doc_type='sale'` 单 + 每单 lines + 2 个 temp b-tree | 改成「先取最近 50 个 id，再 `IN`」 |
| `settlementCountsMany` / `returnedAgainstMany` | `COVERING INDEX idx_settle_target` / `idx_documents_ref` | **好样板**，照抄 |

#### 层 2：**纯 Dart 基准工具**（`tool/bench.dart`，建议新增）

关键点：**业务数据必须走 `RuleEngine` 生成**（`tool/README.md` §一 的纪律）。骨架：

```bash
dart run tool/bench.dart --db /tmp/bench.db --products 300 --docs 20000 --lines 5
```

```
1) 建库（Schema.createStatements）→ 造 300 商品
2) 循环 dispatch：purchase(N) + sale(N) + 30% 单据带 immediatePayments + 5% 退货
   计时项：dispatch p50/p95、单均价（含 5 行明细）
3) 计时项（各跑 20 次取中位）：
   - QueryDao.stockByProduct()
   - QueryDao.availbleInStore()
   - DocumentDao.listDocuments(limit: 200)
   - QueryDao.recentProducts(limit: 20)
   - QueryDao.todaySummary()
4) 采样：库文件大小、-wal 大小、页面缓存命中（PRAGMA page_count / freelist_count）
5) 输出 CSV（机器/版本/参数 → 结果），便于跨版本对比
```

**为什么不放在 widget 测试里**：widget 测试的时钟与渲染管线会掩盖 SQL 成本；这一层只测数据层。

#### 层 3：**Flutter 时间线**（页面级）

- 用 `dart:developer` 的 `Timeline.startSync('stock-page-build')` 包住 `build()` 与首次 DAO 调用，跑 `flutter run --profile` 看 DevTools 的 **Frame Chart**。
- 抓三项：**首帧**（进入页面到可交互）、**输入帧**（开单页连打 10 个数字，看有无 > 16 ms 的帧）、**滚动帧**（单据列表 200 行）。
- 判据：`--profile` 下 **jank 帧占比 < 5%**、单帧 **< 32 ms**（低配目标 30 fps）。

#### 层 4：**低配真机**（唯一能回答「中老年用户的机器上卡不卡」）

| 设备 | 怎么配 | 测什么 |
|---|---|---|
| Windows 低配 | 2 核 / 4 GB / **机械硬盘** / 核显；`--release` 构建 | 冷启动到首帧、开单保存、单据列表、备份、导出、打印（将来） |
| Windows 中配 | 4 核 / 8 GB / SSD，系统 125% + 应用 200% | 同一组，验证缩放档位下的帧率 |
| Android 入门机 | 4 GB RAM / eMMC / Android 9–11 | 首拉、开单、库存页滚动、同步一次 pull 的耗电与发热 |

测法：手机用 `adb shell dumpsys gfxinfo`；桌面用 DevTools 时间线 + 手表计时（用户能感知的是「点下去到界面反应」）。

### 5.5 门槛建议（可判定，写进 `docs/testing.md`）

| 指标 | 目标 | 依据 |
|---|---|---|
| 开单保存 p95（5 行明细，2 万单库） | **< 200 ms** | 用户点「保存」到看到回执的可接受上限 |
| 打字输入帧（开单页，20 行） | **无 > 32 ms 的帧** | 30 fps 下限；配合 #1 的修复 |
| 库存页首屏（300 商品） | **< 300 ms** | 表格页的「不等待」阈值 |
| 单据列表首屏（200 行聚合视图） | **< 300 ms** | 同上 |
| 冷启动到首帧（低配 HDD） | **< 5 s** | 中老年用户对「启动慢」的容忍度低，但机械盘上 5 s 是现实目标 |
| 自动备份（50 MB 库，HDD） | **< 2 s 且不阻塞首屏** | 当前是同步拷贝，需要评估「让出事件循环」是否足够 |
| 同步一次 pull（1000 条单据，弱网） | **< 5 s** | 手机端体验 |

### 5.6 已有可复用资产（别重造）

1. `tool/seed_test_data.py` 的**架构**（解析 `schema.dart` 的 `createStatements` + 离线快照 + 指纹自检）—— 一个新的 benchmark 工具应沿用同一套「从单一来源取 schema」的做法，否则 DDL 漂移会让基准测的是旧结构。
2. `tool/destructive_acceptance.py` 的**三段式**（prepare → 人做 → verify）：性能测试同样适合「准备数据集 → 手动/自动跑 → 出报告」。
3. `packages/shensuanzi_core/test/fixtures.dart`（235 行）—— 已经有建库/造单的辅助函数，基准工具应复用它而不是另写一套。
4. 台账 §BF 的方法论：**先量出「一次操作的真实成本」，再决定改不改**（15.4 s 那次是量出来的，不是猜的）。

---

## 六、问题四：面向中老年用户与低配设备的优化

### 6.1 从代码反推的设备画像

代码里已经留下了三条硬约束，可直接当设备画像用：

1. **数据目录默认非系统盘、三档校验**（`data_directory.dart`）⇒ 用户会在 D 盘/E 盘、U 盘、甚至移动硬盘上跑；**I/O 延迟不受控**。
2. **界面缩放最高 200% + 系统 125%**（`app_config.dart:16-21`）⇒ 逻辑分辨率可能只有 960×540，**一屏可见行数极低**。
3. **单进程 + 本地 SQLite + 无服务器**（`Agents.md` §一）⇒ 全部计算都在用户那台机器上，**没有可借力的后端**。

⇒ 目标设备的现实下界应设为：**Windows 10 / 2 核 / 4 GB / 机械硬盘** 与 **Android 4 GB / eMMC**。

### 6.2 低配设备上会被放大的 8 个点（按放大倍数排）

| # | 代码位置 | 为什么在低配上放大 | 改法 |
|---|---|---|---|
| 1 | `backup.dart` 的 `File.copySync`（同步拷贝，`Agents.md` §4.5 明确「备份是同步拷贝」） | HDD 上 100 MB 库 ≈ 1.5–3 s **主线程阻塞**；期间界面完全不动，用户会连点或强杀 | 保留「同步拷贝」的语义（WAL 已 checkpoint），但把拷贝挪到 `Isolate.run`（迁移已经这么做了，`app.dart:1907-1911` 有现成写法）；或分块拷贝并在进度条上报 |
| 2 | `export.dart` 的 `writeAsBytesSync`（`export.dart:259`） | 几千行 CSV 是毫秒级，但 HDD + 杀软扫描会放大到几百 ms；导出在点击后同步执行 | 与 #1 同一处改造（异步写 + 进度） |
| 3 | 单据列表一次性建 200 行（`documents_page.dart:478-495` 的 `Card` + `for` 循环） | 低端机每行 3–5 个 Text，200 行 ≈ 1000 个 widget 一次性 layout；200% 缩放下每行更高 | 换 `ListView.builder` + 固定行高；或把「200 条」降到 100 条并给「加载更多」 |
| 4 | 库存页每次 rebuild 跑 5 次聚合（`stock_page.dart:168-172`） | 聚合成本 × 5，且每次搜索输入都重跑（`onChanged: setState`） | 一次查询取全部（把 5 个聚合合成 1 条 SQL，或缓存到 `_stockDirty` 标志失效） |
| 5 | 开单页每键 1 次全表聚合（§5.2 #1） | 机械盘 + 30 万行 ⇒ 打字肉眼可见掉字 | 快照改为「进页 / 保存后 / 删行后」失效 |
| 6 | 期初录入每行一个控制器（`opening_stock_page.dart:15` 自陈 500 行会慢） | 低端机内存与构建成本双高 | 已在案；若要修，用「只给可见行建控制器」的懒加载行 |
| 7 | 设置页店名**每键 3 次同步文件 IO**（`settings_page.dart:199-203` 写一次、`app.dart:1826` 再写一次、`app_shell.dart:427` 每 build 读一次）+ 全应用 `setState` | 机械盘 + 杀软扫描 ⇒ 打字一顿一顿；低端机上最明显 | 失焦 / 300 ms debounce 后写一次；`app_shell` 别在 build 里 `load()`（宿主已有内存值） |
| 8 | 成单保存末尾为一句 SnackBar 扫全 `party_ledger`（`sale_service.dart:173-176`，采购/送货同款） | 每单固定成本，随经营年限线性增长；低配机上叠加在保存耗时里 | 改成 `WHERE party_id = ?` 点查 |

### 6.3 中老年用户的「等待容忍度」：三个必须改的反馈点

低配设备上的问题往往不是「慢」本身，而是**慢的时候界面不说自己在干什么**。三处：

1. **自动备份**（启动时 `unawaited(_autoBackup())`，`app.dart:881`）：库大时会有一次无提示的停顿。建议：超过 300 ms 时在概览页显示一行「正在备份…」，完成后再变成「上次备份：今天 09:05」。
2. **导出**（`export_button.dart:52-83`）：已有「导出中…」+ 禁用，**这点做对了**，但成功文案只活 6 秒。建议：把「上次导出到哪」留在页面上（一行小字），而不是只靠 SnackBar。
3. **保存**（四个提交页）：已有「保存中」防重复，但失败时**只标红不定位**（上一轮报告 P1）。低配机上保存会慢，用户更容易在等待中改输入 —— 建议保存期间**锁住输入**（`enabled: !_saving`）而不只是锁按钮。

### 6.4 数据规模的五道坎（写进验收清单）

| 坎 | 触发条件 | 会出现什么 | 当前是否已知 |
|---|---|---|---|
| **500 商品** | 期初录入 / 库存页 | 期初页构建慢（已记录在案）、库存页每次 rebuild 多跑 4 次全扫 | 已知（台账遗漏 6） |
| **单日同类型 1000 单** | 繁忙小店 / 促销日 | **单号撞号，当天无法继续开单**（§3.1 P0-1） | **未知** —— 本报告新增 |
| **`stock_ledger` 约 5 万行**（SSD）/ **2–3 万行**（4GB 机械盘） | 2–3 年老店（每天 30–50 行流水） | 开单页**每敲一键**跑一次全表聚合 ⇒ 开始吃掉 16 ms 帧预算（§5.2 #1，EXPLAIN 已证实 `SCAN stock_ledger` 非覆盖） | 部分已知（"级别会慢"），**没有门槛** |
| **`documents` 约 1 万单** | 1–2 年老店（每天 20–30 单） | 单据页搜索「每键一顿」（`SCAN documents` + 每行 2 个相关子查询）；2 万单时列表排序接近 4 MB 排序负载（会落临时文件） | **未知** —— 本报告新增 |
| **30 万条流水 / 10 万行明细** | 3–5 年老店 | 开单页打字卡、库存页进页停顿、概览页三张大表全扫 | 部分已知 |

> 三档数字都来自 §5.4 的**实测 `EXPLAIN` + 量级外推**，不是拍脑袋；落地时应由 `tool/bench.dart` 跑出真值再写进验收清单。

### 6.5 不该做的优化（避免为了性能破坏纪律）

1. **不要加余额表**（`accounts.balance` / `products.stock`）—— 那会直接推翻「真相在流水」，且多一条缓存不一致的路径。要快就快在**查询聚合的方式**（索引、一次查多值、缓存失效策略），不是加冗余存储。
2. **不要把 `Money` 改成 `double`** 来省转换 —— 金额精度是账本底线。
3. **不要为省一次查询把 `RuleEngine` 的校验挪到 UI** —— 「服务层自己校验一遍，不假设调用方校验过」是 `settlement_service.dart:294-295` 写明的设计。
4. **不要在低配上把字号默认调小** —— 目标用户看不清；该做的是**减少同屏信息量**（分页、折叠），不是缩字号。
5. **不要给「慢」加一个假的进度条** —— 台账 §CV 已裁定「拿不到总数就不放假进度条」。

---

## 七、排期建议

**第 0 批（正确性，先修）**
1. §3.1 P0-2 商品编辑丢包装换算（**已宣称的能力其实是坏的**，一行 SET 清单）。
2. §3.1 P0-3 同步窗口改 `DESC`（手机看到旧欠款会引发重复收款）+ 补「窗口 2×limit」测试。
3. §3.1 P0-1 单号改长度感知排序（照 `latestCode` 的现成写法）+ 补「同日 1000 单」测试。
4. §4.2 库存页「成本（均价）」标签与数值口径（会误导定价）。
5. §3.6 B-1 拒收必须全量 + B-2 创建态 `status` 归一。

**第 1 批（文档与实现对齐，便宜且防回归）**
6. §3.2 `rules.md` RULE-004 场景表 + `testing.md:263`；附录 A 其余 4 条。
7. §3.3 `rule_engine.dart` 头注释删旧状态。
8. §3.6 B-3 盘点 0（要裁定）、B-4 退货单位（要裁定）。
9. §3.7 的 P2 #3 / #6 / #10 / #12 / #13 / #14 / #15 / #17（各一两行改动，聚类做）。

**第 2 批（同步正确性，需裁定）**
10. §3.7 C-1 主数据 update↔update 收敛。
11. §3.7 C-2 换主机时 `sent` 转可处置 + 接上 `lastHostSwitchHeldEntries`。
12. §3.7 C-3 `host_id` 与配对令牌拆分（协议级改动）。
13. §3.7 P2 #7 / #8 / #9 / #11（reason_code、401 集中处置、时钟偏移、窗口补明细）。

**第 3 批（一致性收口）**
14. §4.3 / §4.4 / §4.6 未收与已收统一来源（列表、筛选、详情、导出四处）。
15. §4.5 负未收显示「多收 ¥X（待退/待抵）」而不是 0。
16. §3.7 P2 #2 导出完整性（跳过坏行必须自曝）。

**第 4 批（性能：先建度量，再优化）**
17. 新增 `EXPLAIN QUERY PLAN` 断言测试（层 1，§5.4 已给实测基线 + 可直接抄的代码形状）—— **零风险、立刻能防回退**。
18. 新增 `tool/bench.dart`（层 2），跑出第一份基线（300 商品 / 2 万单）。
19. 按基线修 §5.2 #1（开单页每键聚合）、#3（库存页 4 次全扫）、#11（单据搜索）、#13（双算 balances）。
20. **单据列表两段查询**（先 `SELECT d.id … ORDER BY … LIMIT 200`，再 `WHERE id IN (…)` 取行）：排序负载从 2 万整行降到 200 行，**语义与显示顺序一个字不改**。
21. §5.2 #12（保存末尾为一句 SnackBar 扫全表）改点查；#4 加 `updated_at` 索引（与 §3.1 P0-3 同批）。
22. 低配真机跑一轮（层 4），把 §5.5 的门槛写进 `docs/testing.md`。

**第 5 批（低配体验）**
21. 备份 / 导出移出主线程（`Isolate.run`，迁移已有现成写法）。
22. 单据列表换懒加载；导出成功路径常驻。
23. 500 商品 / 1000 单日 / 30 万流水三档进验收清单（`docs/desktop_acceptance.md`）。

---

## 附录 A：本报告新增的「文档 vs 实现」对照表

| # | 文档说 | 代码做 | 谁对 | 处置 |
|---|---|---|---|---|
| 1 | `rules.md:316` 超收 → 1 条 `target_doc_id = null` | 超收 = 找零、不落库（封顶） | 代码（§AJ·AI-4 / §AX·一） | 改文档 |
| 2 | `rules.md:317` 用预收核新单 | 无此代码路径（settlements 只追加，无重分配入口） | 文档超前 | 标 v1.1 |
| 3 | `testing.md:263` 超收 → 预收余额 | 同 #1 | 代码 | 改文档 |
| 4 | `rule_engine.dart:114-118` 离线签收未实现 | `markDelivered` 已支持两条路径（`:969-1050`） | 代码 | 删旧注释 |
| 5 | `cost_policy.dart:50-51` R-8 待裁定 | 已按加权均价实现；`Agents.md` §五也说已处置 | 实现 | 改注释 |
| 6 | `Agents.md`「单号 主机生成」 | `_prepare` 会保留客户端发来的非「待同步-」单号 | 文档 | 收紧实现 |
| 7 | `Stability_Test_Principles.md:16` 30 天法则 | 无实现、无工具 | 文档超前 | 见 §5.4 |
| 8 | `rules.md:71` 与 `data_model.md:309`「入库 `total_cost = qty × unit_price`」 | 实现按 `line.amount`（`cost_policy.dart:20-28`），且同文档 §零·乙 已说 `amount` 是真相 | 实现 | **改文档**（否则后来人会「修回去」，让让价信息丢失） |
| 9 | `data_model.md:663` 出库成本注记（`WHERE seq_no < … AND quantity > 0`） | 实现是净额 `Σtotal_cost / Σquantity`（`cost_policy.dart:36-46`） | 实现（与 §3.3 的净额公式一致） | 删/改该注记 |
| 10 | `data_model.md:669` 列表排序口径 | 实现 2026-10-18 起按「日桶 + created_at」排（`document_dao.dart:422-439`） | 实现 | 同步文档 |
| 11 | `sync_protocol.md:706-714`「create/update 无论谁先到都收敛」 | **update↔update 不收敛**（§3.7 C-1） | 实现（文档把结论说宽了） | 收窄措辞 + 修实现 |
| 12 | `schema_migration.md:26` 示例 `version = 2` | 同文档 §八 写 3，`schema.dart:37` 是 3 | 后者 | 改文档 |
| 13 | 「客户端不持久化、不引用 `seq_no`」（`Agents.md` 纪律 5 / `data_model.md:671`） | 镜像 upsert 全列含 `seq_no`，且 `ledger_dao` 用 `ORDER BY seq_no` | 措辞问题 | 改成「客户端不**分配** `seq_no`」（分配权在主机），保留只读排序 |

## 附录 B：证据索引（本报告引用的关键位置）

| 主题 | 位置 |
|---|---|
| 事务可重入 / BEGIN IMMEDIATE | `packages/shensuanzi_core/lib/src/db/database.dart:228-258` |
| 唯一 UPDATE 入口（三列） | `packages/shensuanzi_core/lib/src/dao/document_dao.dart:494-520` |
| 聚合读 5 条 | `packages/shensuanzi_core/lib/src/dao/query_dao.dart:35-213` |
| 核销五道门槛 | `packages/shensuanzi_core/lib/src/rules/rule_engine.dart:589-751` |
| 立即收付自动生成收付款单 | `packages/shensuanzi_core/lib/src/rules/rule_engine.dart:823-911` |
| paid_amount 刷新 + 送货例外 | `packages/shensuanzi_core/lib/src/rules/rule_engine.dart:914-965` |
| 退货成本精确回退 | `packages/shensuanzi_core/lib/src/rules/cost_policy.dart:86-135` |
| 盘点差额 | `packages/shensuanzi_core/lib/src/rules/rule_engine.dart:761-810` |
| 单号生成 / 取最大值 | `packages/shensuanzi_core/lib/src/rules/doc_no_generator.dart:32-47`、`dao/document_dao.dart:525-533` |
| 商品编码（正解对照） | `packages/shensuanzi_core/lib/src/dao/product_dao.dart:123-127` |
| 库存页成本显示 | `lib/src/ui/stock_page.dart:574-641`、`test/stock_page_test.dart:290-300` |
| 流水页成本显示（正解） | `lib/src/ui/stock_flow_page.dart:207-215` |
| 未收真相 / 展示 clamp | `packages/shensuanzi_core/lib/src/documents/settlement_service.dart:125-149` |
| 列表行未收（缓存口径） | `lib/src/ui/documents_page.dart:537` |
| 备份同步拷贝 | `packages/shensuanzi_app/lib/src/backup.dart`、`Agents.md` §4.5 |
| 迁移 isolate（可复用的写法） | `lib/src/app.dart:1907-1911` |

## 附录 C：审查局限

1. **未跑门禁**：无 `.dart_tool/package_config.json`，`flutter analyze` / `flutter test` 未执行；所有「会不会」结论都标注了推理依据。
2. **未做真机性能实测**：§五给的是方法与门槛；§5.3 的数字是量级推演，用于排序，不用于验收。
3. **未逐行读**：`manual_content.dart`（文档文案，上一轮已审）、`windows/` 原生代码、`android/` 构建脚本不在本次业务逻辑范围内。
4. 引用行号基于 2026-10-21 的工作区快照。
