# 同步规范

> **本规范在数据层动工前冻结。** 幂等键与冲突策略反向决定字段与索引设计。

## 一、架构总览

```text
Windows 主机（权威）            Android 客户端（瘦）
─────────────────────           ─────────────────────
SQLite（真相）                  sync_queue（待推送 / 已推送待确认）
HTTP 服务（localhost + LAN）    sync_cursor（拉取游标，原样存主机返回值）
seq_no 分配                     clock_offset（时钟偏移）
RuleEngine 落地                 本地镜像（权威状态的副本，FK 关闭）
                                未同步影响（由 sync_queue 派生的 ± 数量 delta）
```

**客户端显示 = 权威镜像 + 未同步影响**，其中未同步影响来自两条来源：

| 来源 | 何时 | 为什么 |
|---|---|---|
| `pending_delta` | 用户开单 → push 成功之前 | 本地已发生，主机还不知道 |
| `in_flight_delta` | push 成功 → **pull 确认之前** | 主机已收下，但本地权威状态还没包含 |

**为什么 push 成功不删队列条目**：删了就等于「主机已收下，但界面装作没这回事」——
用户刚卖的 3 件会消失到下次 pull 为止。保留 `sent` 条目让这段窗口**可见**
（`data_model.md` §4.1）。

**客户端只做数量累加**，不算成本、不算往来、不算盘点（`data_model.md` §七）。

**信任边界**：家庭 / 店铺局域网。详见 `threat_model.md`。

## 二、幂等键

**幂等键 = 实体自身的 `id`（UUIDv7）**。

- 客户端生成 `id`，服务端无需参与
- 服务端用 `SELECT 1 FROM <table> WHERE id = ? LIMIT 1` 判重
- 已存在返回 `already_exists`，**不修改任何数据**
- `sync_queue` **不设** `idempotency_key` 字段

**为什么不设独立幂等键**：避免"幂等键与主键不同步"的经典 bug。UUIDv7 全局唯一，无需二级键。

## 三、操作类型

| 操作 | 幂等判定 | 冲突策略 |
|---|---|---|
| `createDocument` | `id` 已存在 → `already_exists` | 无冲突（只插入） |
| `createMasterData` | `id` 已存在 → `already_exists` | 无冲突 |
| `updateMasterData` | `base_version == 主机 sync_version` → 应用；否则拒绝 | **主机赢**，返回 `server_state` |
| `deleteMasterData` | 主数据软删。已删 → 幂等返回 | 主机赢 |
| `documentAction` | 状态判定（R-3.1）：`in_transit` → 应用；`delivered` / `settled` → `already_exists`；其余状态 → `conflict` | **FAW**（R-3.5）—— 谁先到达主机谁生效，后到者拿 `conflict` + `server_state` |

**业务数据永不 update / delete**。客户端只能 create 或执行 action。

> ✅ **`documentAction` 已于 2026-09-29 落地**（R-3 裁定，见 `docs/reply_review.md` §H）。
>
> - v1 唯一动作 **`mark_delivered`**（送货单 `in_transit → delivered`，规则本体在
>   `RuleEngine.markDelivered` —— 规则的实现只应有一处，纪律 9）；
>   未知动作 → `rejected` + `unknown_action: <名>`
> - **动作只做单向终态转变** —— 反向业务（如反签收）用**新建单据**表达，不修改历史；
>   幂等判定因此只看当前状态，**不需要 `document_actions` 表**。
>   出现双向动作时才需要建表（口子记在 `docs/reply_review.md` §H）
> - **判定不看时间**（R-3.3）：`occurred_at` 客户端提供、仅展示、不落库；
>   并发语义 = **FAW**（first-arrival-wins，R-3.5）—— 到达顺序是主机可观测的唯一真相
> - **Android 端「签收」按钮随 AH-B 解锁**
> - v1 的签收走**主机本地**路径：`RuleEngine.markDelivered`（`rules.md` RULE-003）
>
> 进入同步层时需要回答的五个问题（R-3.1 ~ R-3.5）见
> `docs/reply_review.md` §H「R-3.1 ~ R-3.5 待答清单」。

## 四、主机赢（Host-Wins）

```text
客户端发送 update (base_version=N)
├─ 主机 sync_version == N → 应用更新，sync_version = N+1，返回 { status: "applied" }
└─ 主机 sync_version > N  → 拒绝，返回 { status: "conflict", server_state: {...} }
                           客户端：本地覆盖为 server_state，UI 提示"该记录已在别处被修改"
```

**客户端处理冲突**：

1. 用 `server_state` 覆盖本地
2. 从 `sync_queue` 删除该条目
3. UI 提示用户

**冲突不可避免**。两台 Android 同时改一个商品价格，后到的输。这是有意识的取舍：简单、可预测。

## 五、落库路径（关键裁定）

**客户端只推 `Document` + lines，主机走 RuleEngine 落地。**

```text
客户端                          主机
────────                        ─────
创建 Document（本地）
  → 写 sync_queue
  → 本地估算视图更新

推送 sync_queue
                                SyncServer 收到
                                ├─ 主数据：白名单校验 → 通用 upsert
                                └─ documents：RuleEngine.dispatch
                                     ├─ 按 doc_type 分派 RULE-XXX
                                     ├─ 分配 seq_no
                                     ├─ 写入 4 张流水
                                     └─ 刷新 paid_amount 缓存

收到响应
├─ applied / already_exists → 删除队列条目
├─ conflict                → 覆盖本地 + 删除
└─ rejected                → 标记 failed
```

**为什么不让客户端推流水行**：

1. `seq_no` 由主机分配，客户端无法预先确定
2. 客户端推流水行需要客户端实现全套 RULE，代码重复
3. 主机是唯一真相源，RuleEngine 只在主机实现一份，bug 面积最小

**`RuleEngine.dispatch` 的约束**：

- 按 `doc_type` 分派
- **没有对应规则的 `doc_type` 一律 `rejected`**（如 v1 的 `transfer`）
- 所有操作在**同一个主机事务内**完成
- 事务失败 → 整单回滚 → 返回 `rejected`

**`SyncServer` 的边界**（实现见 `packages/shensuanzi_host/lib/src/sync_server.dart`）：

- **协议 DTO 在 core**（`shensuanzi_core` 的 `lib/src/sync/`），
  **服务端实现在 host**（`shensuanzi_host`）—— 见 `README.md` 的包边界图
- **本类不含 HTTP**：它接收 `SyncOperation`、返回 `SyncResponse`；
  HTTP 适配层（shelf）在 host 的 `http_server.dart`，只做 JSON ↔ 对象的搬运。
  这样同步逻辑是**纯 Dart**，可在没有网络、没有 Flutter 的环境里测试
- **同步层自己不写任何流水** —— `createDocument` 全部委托给 `RuleEngine`
- **一条 op 一个事务**：一条失败只影响该条，**不回滚同一批里的其它条目**
  （它们是各自独立的队列条目）
- **拼 SQL 的表名只来自白名单常量或 `Schema.*` 常量**，没有任何一处来自客户端输入

## 六、同步队列与重试

**`sync_queue.operation` 五类**：

1. `createDocument`
2. `createMasterData`
3. `updateMasterData`
4. `deleteMasterData`
5. `documentAction`

**重试策略**：

- **push 成功**（`applied` / `already_exists`）→ 条目转 `sent`，**不删除**；
  **pull 确认**（本次拉到该 `entity_id`）→ 删除
- **push 失败** → `retry_count += 1`，指数退避：1s, 4s, 16s, 64s, ...
- `retry_count > 10` → 标记 `failed`（**死信，退出自动重试**），UI 提示人工处理；
  人工处理完 `requeue` 放回队列（`data_model.md` §4.1）
- **自动重试只取 `pending` 且退避到期**的条目；`sent` 与 `failed` 都不自动推送
- **冲突**（`conflict`）→ 用 `server_state` 覆盖本地 + **删除条目**（§四）

**匹配规则**：响应与队列条目**按 `entityId` 匹配**，不按下标。服务端顺序变化不能影响客户端配对。

**整次通信失败与业务拒绝必须分开**：

| 情形 | 归类 | 处置 |
|---|---|---|
| 连不上 / 非 200 / 401 | **协议层失败** | 整批退避，条目**仍是 `pending`**；401 另需重新配对 |
| 回执 `rejected` | **业务拒绝** | 该条退避 + 记原因（如 `unknown_action`） |
| 该条没有回执 | 主机未处理 | 该条退避，**不影响同批其它条** |

把 401 当成 `rejected` 写进队列，会让「令牌过期」伪装成「单据被业务规则拒绝」。

## 七、时钟与排序

- **排序一律用 `seq_no`**（每表独立单调）
- **`occurred_at` 仅用于展示与筛选**
- 客户端首次配对时记录 `offset = server_time - client_time`
- 客户端离线期间用 `client_time + offset` 估算 `occurred_at`，并标记 `time_estimated = 1`
- 主机收到后**保留 `time_estimated` 标记**，用主机时钟分配 `created_at` 与 `seq_no`

**`seq_no` 语义**：每张流水表内独立单调递增。

- 成本计算在 `stock_ledger` 表内自洽
- 跨表因果由 `document_id` 关联
- 同步游标按实体分开传

## 八、同步接口

### 8.0 鉴权范围

| 端点 | 鉴权 | 为什么 |
|---|---|---|
| `GET /api/health` | **否** | 客户端在**扫码之前**就要能判断「这个 IP:端口是不是主机」。它只返回 `ok` / `api_version` / `server_time` / `schema_version`，**不含任何业务数据** |
| 其余全部 | **是**（`Authorization: Bearer <token>`） | 令牌来自二维码（§9.1），只经带外通道（人眼 → 摄像头）传播 |

令牌错误或缺失一律 `401` + `{"error": "..."}`；
请求体不是合法 JSON 或缺字段一律 `400`；未捕获异常一律 `500`（**不外泄 stack trace**）。

#### 请求体编码（跨端约定）

**所有 `POST` 请求体必须是 UTF-8**（业务数据里有中文，用其他编码会直接抛）。
客户端实现 `Transport` 时**必须显式** `utf8.encode` ——
**不要把编码交给底层 HTTP 库的默认值**（`HttpClientRequest.write` 默认就不是 UTF-8）。

> 这条是**协议层**约定，不是实现细节：一个只读本规范的 Android 端实现者，
> 有权知道请求体该用什么编码。实现视角的写法见 `Transport` 的文档注释；
> 「为什么这么定」的过程记录见 `reply_review.md` §N（R-14 方案 A 落地记录）。
>
> 三处**读者不同、写法不同，缺一不可**：实现者看 `transport.dart`、协议读者看本节、
> 想知道「为什么」的看台账 §N。

### 8.1 推送

```text
POST /api/sync/push
Authorization: Bearer <token>
Body: {
  "operations": [
    { "entity": "documents", "entity_id": "...", "operation": "createDocument",
      "payload": { "document": {...}, "lines": [...],
                   "immediate_payments": [ { "account_id": "...", "amount": 3000 } ] } },
    { "entity": "products", "entity_id": "...", "operation": "updateMasterData",
      "base_version": 3, "payload": {...} },
    { "entity": "documents", "entity_id": "...", "operation": "documentAction",
      "payload": { "action": "mark_delivered", "occurred_at": 123 } }
  ]
}
Response: {
  "results": [
    { "entity_id": "...", "status": "applied" },
    { "entity_id": "...", "status": "conflict", "server_state": {...} },
    { "entity_id": "...", "status": "rejected", "reason": "..." }
  ]
}
```

`status` 枚举：`applied` / `already_exists` / `conflict` / `rejected`

**`createDocument` 的 payload 结构（R-1 / R-6 裁定，2026-09-25）**：

| 字段 | 必填 | 说明 |
|---|---|---|
| `document` | 是 | 单据主表字段 |
| `lines` | 是（收/付款单为空数组） | 商品明细，对应 `document_lines` |
| `immediate_payments` | 主单有立即收付款时 | `[{ account_id, amount }]` → 主机**自动生成**收付款单 |
| `allocations` | **仅手动创建的 `receipt` / `payment` 单** | `[{ target_doc_id, amount }]` → 主机按 RULE-004 / RULE-005 核销 |

- `allocations` 中 `target_doc_id = null` 表示预收/预付
- 两者都**不是** `document_lines` 的行，只在 payload 中存在（`rules.md` §零）

**`document` 与 `lines` 的元素都是完整的 wire 行**（列名与值同 `toRow()`，见 §8.2 前）。
其中 **`document_lines.id` 由客户端生成，主机原样落库、不重新生成**：

- 客户端本地镜像已经用这个 `id` 建了明细行；主机若换一个 id，
  `pull` 回来的明细与本地**对不上**（同一明细两份）
- 因此明细的 `id` 是**必填**。漏了会被判 `rejected`（`document_lines` 的可写列见 §8.4）
- 与 `document.id` 的区别：后者是**幂等键**（§二），必须是客户端生成且稳定的；
  前者只是本地主键，无幂等语义 —— 重推同一张单时，`already_exists` 在 `document.id` 上就短路了

**互斥规则（硬性）**：`immediate_payments` 与 `allocations` **不能同时非空**。

| 哪个非空 | 说明该 op 是 |
|---|---|
| `immediate_payments` | **主单**（`purchase` / `sale` / `sale_return` / `purchase_return`） |
| `allocations` | **独立收付款单**（`receipt` / `payment`） |

主机校验：违反互斥规则 → `rejected`。

**自动生成的收付款单不进 payload、也不需要客户端预生成** ——
id、单号、`seq_no` 全部由主机生成；客户端随后从 `/api/sync/pull` 拉取。

**收付款单的 `lines` 为空**，因此不变量 B5
（`SUM(document_lines.amount) = total_amount`）对它们**不适用**（见 `data_model.md` §五）。

### 8.2 拉取

```text
GET /api/sync/pull
  ?stock_since=123
  &money_since=45
  &party_since=67
  &settle_since=12
  &doc_since=1700000000000|0192…
  &products_since=1700000000000|0192…
  &parties_since=1700000000000|0192…
  &accounts_since=1700000000000|0192…
  &limit=100
Authorization: Bearer <token>
Response: {
  "documents": [...],
  "document_lines": [...],
  "stock_ledger": [...],
  "money_ledger": [...],
  "party_ledger": [...],
  "settlements": [...],
  "products": [...],
  "parties": [...],
  "accounts": [...],
  "next_cursors": {
    "stock_since": "200",
    "doc_since": "1700000000000|0192…",
    "products_since": "1700000000000|0192…",
    "parties_since": "1700000000000|0192…",
    "accounts_since": "1700000000000|0192…"
  }
}
```

**`pull` 是同步的唯一入口**（R-13 方案 A，2026-09-26）—— **9 个实体**：
6 个业务实体 + 3 个主数据实体。主数据的增删改**不再只靠** §8.3 的 GET
（那组接口不承担同步职责，见 §8.3）。

**为什么按实体分开传游标**：`seq_no` 每表独立，单游标无法跨表分页。

**游标语义（R-4 + R-13 处置）**：

| 实体 | 游标 | 取值 |
|---|---|---|
| `stock_ledger` / `money_ledger` / `party_ledger` / `settlements` | `seq_no` | 整数字符串，**开区间** `seq_no > ?` |
| `documents` | `(created_at, id)` 复合 | 形如 `"1700000000000\|0192…"` |
| `products` / `parties` / `accounts` | `(updated_at, id)` 复合 | 同上形态 |
| `document_lines` | **无独立游标** | 随主单同页返回，见下 |

**为什么 `documents` 不能用单个 `created_at`**：它**不唯一**。
用 `>` 会丢掉同一毫秒里剩下的行；用 `>=` 又会在「同一毫秒的行数 > `limit`」时
**永远取回同一页**（死循环）。复合游标 `(created_at, id)` 是唯一既**不丢行**
又能**保证推进**的方案，且与 §七「客户端按 `(created_at, id)` 排序」一致。
为此新增索引 `idx_documents_created`（`data_model.md` §3.1）。

**为什么主数据游标用 `updated_at` 而不是 `created_at` / `sync_version`**（R-13）：

- **不是 `created_at`**：主数据**会被更新**，`created_at` 从不变 ——
  用它做游标，客户端永远拉不到「改了价格」这件事
- **不是 `sync_version`**：它是**每实体独立的乐观锁计数**，
  实体 A 的 `sync_version = 5` 与实体 B 的 `sync_version = 5`
  之间没有任何顺序关系，做游标会在分页时丢行或死循环
- **`updated_at` 也不唯一**，所以同样要 `(updated_at, id)` 复合。
  为此新增三个索引（`data_model.md` §2.1 / §2.2 / §2.3）

**主数据的返回语义**（R-13）：

| 项 | 决定 | 为什么 |
|---|---|---|
| **软删行** | **照常返回**（`is_active = 0`） | 不返回则客户端永远无法感知删除。客户端据此在本地把该行标为非活跃 |
| **返回列** | **全部列**（含 `sync_version` / `updated_at` / `created_at`） | 客户端要 `sync_version` 做下次 `updateMasterData` 的 `base_version`，要 `updated_at` 存游标 |
| **`limit`** | 对**每个分页实体独立生效**、各自推进 | 某一个先拉完不影响其它 |

**为什么 `document_lines` 没有独立游标**：它**没有时间列**（`data_model.md` §3.2），
且明细与主单**在同一事务里写入**、永远不会单独存在。所以它**直接由本页
`documents` 的结果派生**（`WHERE document_id IN (本页主单 id)`），
这正是本节只列 `doc_since` 的原因。

- `limit` 限制的是**主单条数**；明细条数由「本页主单的明细总数」决定，
  **不额外截断** —— 截断会造出「有主单但明细不全」的镜像
- 对称地，明细**不越过本页**：`limit=1` 时只返回那 1 张主单的明细。
  「不截断」与「不越界」是两件事 —— 前者指本页明细全给，后者指页边界一致。
  实现上不重写一遍谓词，而是从本页 `documents` 的实际结果派生，
  **从结构上排除两次查询页边界错位**
- 四张流水表的游标是**开区间**（`seq_no` 唯一），`documents` 与主数据是
  **闭区间 + id 判别**（时间列不唯一），两者语义不同，不可互换

**wire 值的形态**：**列名 = 数据库列名（snake_case），值 = `toRow()` 的形态** ——
布尔用 `1` / `0`，时间用 UTC 毫秒整数，金额用整数分。
这样 wire ↔ DB row 之间**没有转换层**，也就没有转换漂移。

**⚠️ 客户端要持久化什么**：`sync_queue`（待推送的 op）与 **8 个游标**
（`sync_cursor`）。前者见 `data_model.md` §4.1，后者见 §4.3 ——
**游标必须原样保存主机返回值，不得从本地镜像推算**（R-14）。

**客户端落库的五条约束**（实现细节，但会决定正确性）：

| 约束 | 为什么 |
|---|---|
| 游标**原样回传**，不解析 | 主机可换游标编码而不需客户端升级 |
| **行与游标同事务** | 崩溃只会「重复拉」（幂等无害），不会「存了游标没存行」（静默丢数据） |
| 镜像 **`foreignKeys: false`** | 本页某行引用的主数据可能落在页外；开着 FK 会让 pull 变**毒丸**（整批回滚 → 游标退回 → 死循环） |
| 落库**按依赖顺序**（主数据先） | §8.2 的字段顺序是**阅读顺序**（主数据在后），而 `document_lines` / `stock_ledger` 都引用 `products` |
| **镜像重建，而非迁移** | 镜像是**派生数据**（真相在主机）⇒ 客户端**不写迁移逻辑**：存 `mirror_schema_version`，pull 前比对主机版本，低了就 **drop 全部镜像表 + 重建 + 从头全量拉**。客户端写一份迁移 = 同一件事两处实现（违反 `Agents.md` 纪律 9 的精神）；代价是升级后第一次 pull 是全量的。见 `docs/schema_migration.md` §六 |

### 8.3 主数据接口

```text
POST   /api/products              # upsert
DELETE /api/products/:id          # 软删除
GET    /api/products?q=&active=
GET    /api/products/:id
GET    /api/products/:id/stock

POST   /api/parties
DELETE /api/parties/:id
GET    /api/parties?role=
GET    /api/parties/:id/balance

POST   /api/accounts
DELETE /api/accounts/:id
GET    /api/accounts
GET    /api/accounts/:id/balance

POST   /api/documents
GET    /api/documents/:id
GET    /api/documents?type=&since=&party_id=
POST   /api/documents/:id/cancel
POST   /api/documents/:id/settle
POST   /api/documents/:id/actions

GET    /api/stock_ledger?product_id=&since=
GET    /api/money_ledger?account_id=&since=
GET    /api/party_ledger?party_id=&since=
```

所有 POST 接受 **upsert 语义**（body 带 `id` 即更新，无 `id` 即创建）。
所有写接口要求 `Authorization: Bearer <token>`。

> ⚠️ **v1 未实现**。本节是**便利接口**：同步本身不依赖它 ——
> 主数据的增删改都走 §8.1 的 `createMasterData` / `updateMasterData` /
> `deleteMasterData`，主数据的**增量拉取**走 §8.2 的 `pull`。
> 本节留给 Windows UI 的查询与调试，实现优先级最低。
>
> ### ⛔ 本节**不承担同步职责**（R-13 裁定，2026-09-26）
>
> 增量同步**一律**走 §8.2 的 `pull`。本节这些 GET 接口**不会**加 `?since=`，
> 也**不要求**客户端在这里轮询 —— 客户端的两条数据通路必须清晰：
>
> | 目的 | 走哪 |
> |---|---|
> | 增量同步（业务数据 + 主数据） | §8.2 `pull`，**唯一入口** |
> | 主数据的写入 | §8.1 `createMasterData` / `updateMasterData` / `deleteMasterData` |
> | 人看数据 / UI 查询 / 调试 | 本节（可选，v1 未实现） |
>
> **这条写在这里是为了防止未来有人再把同步职责往这两个端点里塞。**
> 方案 B（给本节加 `?since=`）曾在 R-13 里被否决：它会把一个定位为
> 「便利接口」的端点**升级成 v1 必须实现的增量同步端点**，
> 客户端也要维护两套循环与两套游标状态 —— 与「最小 v1」相悖。
> 完整论述见 `docs/reply_review.md` §L（**不引用 `docs/reply.md`** ——
> 那是逐轮覆盖的裁定书，见 `Agents.md` §六的文档治理规则）。

### 8.4 表名 / 列名白名单

**唯一实现**：`shensuanzi_core/lib/src/sync/whitelist.dart` 的 `SyncWhitelist`。
下表是它的镜像；**改一处必须改另一处**。

**可写表**（`op.entity` 必须在此）：

| 表 | 允许的操作 |
|---|---|
| `products` / `parties` / `accounts` | `createMasterData` / `updateMasterData` / `deleteMasterData` |
| `documents` | `createDocument` / `documentAction`（落地 `mark_delivered`；未知动作 `unknown_action`） |

**任何其它表名一律 `rejected`** —— 包括四张流水表、`document_lines`（随主单走）、
`sync_queue`、`clock_offset`，以及 `sqlite_master` 这类注入尝试。

**客户端可写的列**：

| 表 | 列 |
|---|---|
| `products` | `id` `code` `name` `barcode` `unit` `cost_price` `sell_price` `safety_stock` `category` `is_active` `remark` `package_note` |
| `parties` | `id` `name` `phone` `address` `roles` `credit_limit` `is_active` `remark` |
| `accounts` | `id` `name` `type` `initial_balance` `is_active` |
| `documents` | `id` `doc_no` `doc_type` `status` `party_id` `account_id` `total_amount` `ref_doc_id` `occurred_at` `time_estimated` `remark` |
| `document_lines` | `id` `document_id` `product_id` `quantity` `unit_price` `amount` `remark` |

**主机专属列 —— 客户端永远不能写**，出现即 `rejected`：

| 列 | 为什么 |
|---|---|
| `created_at` / `updated_at` | 主机时钟（§七） |
| `sync_version` | 主机乐观锁计数，由 `base_version + 1` 推出 |
| `seq_no` | 主机在事务内分配（`Agents.md` 纪律 5） |
| `paid_amount` | 派生缓存，真相是 `SUM(settlements.amount)` |

`op.entity` 与 `op.payload.keys` **一律校验**。**拒绝一切不在白名单内的输入。**

`delete` 只允许主数据。`documents` 无 `is_active` 列，`delete` 会被拒。

### 8.5 错误码

`rejected` 的 `reason` 里**可机读的前缀**（客户端可以按前缀分类，其余部分给人看）：

| 错误码 | 出处 | 含义 |
|---|---|---|
| `unknown_action` | `documentAction` | 未知的动作名（v1 只支持 `mark_delivered`） |
| `return_exceeds_original` | RULE-007 / RULE-008 | 累计退货量超过原单量 |

其余拒绝原因是**自由文本**（含中文诊断信息），客户端只需展示，不要解析。

#### `rejected` 与 `conflict` 的分类原则（R-3.4）

两者都**重试无意义**，但客户端处置不同 —— 这就是区分的标准：

| 回执 | 何时用 | 客户端行为 |
|---|---|---|
| `rejected` | **规则不允许**：参数错、类型不符、约束违反 | 停在失败队列，给人看原因 |
| `conflict` | **状态不匹配**：乐观锁落后、动作前提不成立 | 用 `server_state` **自动对齐**本地，删队列条目 |

> 典型：`cancelled` 的单收到 `mark_delivered` → `conflict`。客户端的用户看到的
> 不是「同步失败」，而是「这单在主机上已取消」—— 真相对齐，困惑消失。

#### 动作并发：FAW（R-3.5）

多端并发动作的判定是 **FAW（first-arrival-wins，先到主机者赢）**，**不是 LWW** ——
客户端时钟不可信（R-3.3），到达顺序才是主机可观测的唯一真相。后到者拿
`conflict` + `server_state` 自动对齐。v1 没有 cancel 动作，此场景暂不发生；
**将来加 cancel 必须按 FAW 实现**，不要默认「最后写入的赢」。

## 九、配对与发现

**v1 只做二维码配对。mDNS 延后到 v1.5。**

### 9.1 配对流程

1. Windows 启动 HTTP 服务，端口从 17890 起探测到 17900
2. 生成 token（32 字节随机数，Base64）
3. 显示二维码：`shensuanzi://pair?host_id=<uuid>&ip=<lan_ip>&port=<port>&token=<token>&v=1`
4. Android 扫码，存 `host_id` / `ip` / `port` / `token`
5. 后续请求带 `Authorization: Bearer <token>`

### 9.2 IP 变化处理

- IP 变化时，客户端请求失败
- 提示用户**重新扫码**
- v1 不做 mDNS 自动发现

### 9.3 安全

- Token 首次启动生成，存本地
- 设置页显示"已配对设备列表"，可踢出
- Token 可一键重置（所有设备需重新配对）
- **v1 不引入 TLS**。信任边界：局域网可信

## 十、冲突与死信

- `status = 'failed'` 的队列条目不自动重试
- UI 提供"查看失败详情"和"手动重试"入口
- 死亡条目保留 30 天，之后清理

## 十一、测试要求

同步协议必须覆盖：

```text
重复推送同一 Document → 数据库一条
冲突 update → 返回 server_state，客户端覆盖本地
断网 → 离线队列 → 恢复 → 全部同步
重试 > 10 → 进死信
时钟偏移 +1 小时 → seq_no 顺序仍正确
delete 非主数据 → rejected
表名/列名白名单外 → rejected（含 sqlite_master 这类注入尝试）
mark_delivered：in_transit → applied；重复 → already_exists；
cancelled → conflict + server_state；未知动作 → rejected + unknown_action
purchase 收签收 → rejected（规则不允许，进重试）
响应与队列按 entityId 匹配（顺序打乱不影响）
批量 push 里一条失败不影响其它条目
同一 created_at 的多张单：分页不丢行、不重复、游标必推进
明细随主单同页返回，且不按 limit 截断
明细不越过本页主单的边界（limit=1 → 只有那 1 张主单的明细）
health 不需要鉴权，且不泄露业务数据
push / pull 缺令牌或错令牌 → 401
请求体不是 JSON / 缺 operations → 400
`pull` 恰好返回 9 个实体（6 业务 + 3 主数据）+ next_cursors（R-13 方案 A）
客户端 A 改商品价格 → 客户端 B 带游标 pull → B 拿到新价格
客户端 A 软删商品 → 客户端 B pull → B 拿到 is_active = 0 的行
从未见过该商品的新客户端：全量首拉就能拿到 is_active = 0 的行
同一毫秒内多次更新主数据：(updated_at, id) 游标不丢行、不重复、必推进
未改动的主数据不会重复出现在增量页里
§8.3 的 GET 接口与 pull 互不影响（两个端点返回的主数据视图一致）
--- 客户端（SyncClient）---
游标空表 → 从头拉；写入后被主机返回值覆盖；不透明游标原样存回（B8）
pull 单事务：非法行 → 行与游标都不落库
pull 幂等：同一页重复拉不产生重复行
本地占位单据被主机版本覆盖（含 doc_no 回填）
未知实体键被忽略，不落库（也不会当表名拼进 SQL）
**push 不推进拉取游标** —— 陷阱 1 的回归守卫（先 push 后 pull 不跳段）
客户端时钟快 1 小时也不跳过服务器数据 —— 陷阱 2 的回归守卫
push 回执按 entity_id 配对（顺序打乱不影响）
applied → 条目转 sent（不删除）；pull 确认后才删除；分页之外的保留
rejected → 退避 1s/4s/16s/64s；>10 进死信并**退出自动重试**
conflict → server_state 覆盖本地 + 删除条目
传输异常 / 非 200 → 整批退避且**仍为 pending**（不伪装成业务拒绝）
deltaOf 符号表：purchase/sale_return 为 +，sale/delivery/purchase_return 为 −，
  stocktake/receipt/payment 为 0
库存视图 = 权威镜像 + 未同步影响，且能列出贡献者
镜像开着外键 → 构造时明确拒绝
```

> ✅ **已落地（2026-09-29）**：原「`documentAction` 幂等」一项随 **R-3 裁定**实现
> （`docs/reply_review.md` §H；自检 `selfcheck_sync.dart` 含动作矩阵 8 项）。
