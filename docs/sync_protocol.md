# 同步规范

> **本规范在数据层动工前冻结。** 幂等键与冲突策略反向决定字段与索引设计。

## 一、架构总览

```text
Windows 主机（权威）            Android 客户端（瘦）
─────────────────────           ─────────────────────
SQLite（真相）                  sync_queue（待推送）
HTTP 服务（localhost + LAN）    只读快照（估算）
seq_no 分配                     (created_at, id) 本地排序
RuleEngine 落地                 调 API 提交动作
```

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
| `documentAction` | **v1 未实现** → 一律 `rejected` + `action_not_implemented` | —（待 R-3） |

**业务数据永不 update / delete**。客户端只能 create 或执行 action。

> ⚠️ **`documentAction` 在 v1 不落地**（2026-09-25 裁定，见 `docs/reply.md`）。
>
> 「动作」这个抽象还没定型 —— 它会影响 `sync_queue` 的操作枚举、`SyncServer`
> 的处理路径、甚至是否需要一张动作表。现在猜，等于把 `sync_queue` 的字段设计
> 押在一个未验证的假设上。
>
> - **枚举值保留**，客户端可以入队，但主机返回 `rejected` + `action_not_implemented`
> - **Android 端的"签收"按钮在 v1 禁用**（标注"v1.1 开放"）
> - v1 的签收走**主机本地**路径：`RuleEngine.markDelivered`（`rules.md` RULE-003）
>
> 进入同步层时需要回答的五个问题（R-3.1 ~ R-3.5）见 `docs/reply.md`。

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

- 成功 → 删除队列条目
- 失败 → `retry_count += 1`，指数退避：1s, 4s, 16s, 64s, ...
- `retry_count > 10` → 标记 `failed`，UI 提示人工处理

**匹配规则**：响应与队列条目**按 `entityId` 匹配**，不按下标。服务端顺序变化不能影响客户端配对。

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
  &doc_since=1700000000000
Authorization: Bearer <token>
Response: {
  "documents": [...],
  "document_lines": [...],
  "stock_ledger": [...],
  "money_ledger": [...],
  "party_ledger": [...],
  "settlements": [...],
  "next_cursors": { "stock_since": "200", "doc_since": "1700000000000|0192…" }
}
```

**为什么按实体分开传游标**：`seq_no` 每表独立，单游标无法跨表分页。

**游标语义（R-4 处置，2026-09-25）**：

| 实体 | 游标 | 取值 |
|---|---|---|
| `stock_ledger` / `money_ledger` / `party_ledger` / `settlements` | `seq_no` | 整数字符串，**开区间** `seq_no > ?` |
| `documents` | `(created_at, id)` 复合 | 形如 `"1700000000000\|0192…"` |
| `document_lines` | **无独立游标** | 随主单同页返回，见下 |

**为什么 `documents` 不能用单个 `created_at`**：它**不唯一**。
用 `>` 会丢掉同一毫秒里剩下的行；用 `>=` 又会在「同一毫秒的行数 > `limit`」时
**永远取回同一页**（死循环）。复合游标 `(created_at, id)` 是唯一既**不丢行**
又能**保证推进**的方案，且与 §七「客户端按 `(created_at, id)` 排序」一致。
为此新增索引 `idx_documents_created`（`data_model.md` §3.1）。

**为什么 `document_lines` 没有独立游标**：它**没有时间列**（`data_model.md` §3.2），
且明细与主单**在同一事务里写入**、永远不会单独存在。所以它按「本页 `documents`」
取（谓词与主单页边界完全一致），这正是本节只列 `doc_since` 的原因。

- `limit` 限制的是**主单条数**；明细条数由「本页主单的明细总数」决定，
  **不额外截断** —— 截断会造出「有主单但明细不全」的镜像
- 四张流水表的游标是**开区间**（`seq_no` 唯一），`documents` 是**闭区间 + id 判别**
  （`created_at` 不唯一），两者语义不同，不可互换

**wire 值的形态**：**列名 = 数据库列名（snake_case），值 = `toRow()` 的形态** ——
布尔用 `1` / `0`，时间用 UTC 毫秒整数，金额用整数分。
这样 wire ↔ DB row 之间**没有转换层**，也就没有转换漂移。

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
> `deleteMasterData`。本节留给 Windows UI 与手工调用，实现优先级低于
> 「主数据增量同步」这条缺口（见下）。
>
> ⚠️ **已知缺口：主数据的增量同步没有游标。**
>
> §8.2 的 `pull` **只返回 6 个业务实体**（`documents` / `document_lines` /
> 四张流水），**不含主数据**；而本节这些 GET 接口只有 `?q=&active=`，
> 没有 `since`。两端合起来的结果是：
>
> **一台客户端改了商品价格，另一台客户端无法通过 `pull` 得知。**
>
> 修法有两种，各有代价：
>
> | 方案 | 代价 |
> |---|---|
> | A. 把主数据并入 `pull`（`products_since` / `parties_since` / `accounts_since`） | 要决定主数据的游标列（`updated_at`？`sync_version`？软删怎么表达？） |
> | B. 给本节接口加 `?since=` | 拉取要分两个端点，客户端逻辑分叉 |
>
> **待裁定**（列在 `docs/reply_review.md` 附录 J）。

### 8.4 表名 / 列名白名单

**唯一实现**：`shensuanzi_core/lib/src/sync/whitelist.dart` 的 `SyncWhitelist`。
下表是它的镜像；**改一处必须改另一处**。

**可写表**（`op.entity` 必须在此）：

| 表 | 允许的操作 |
|---|---|
| `products` / `parties` / `accounts` | `createMasterData` / `updateMasterData` / `deleteMasterData` |
| `documents` | `createDocument` / `documentAction`（v1 返回 `action_not_implemented`） |

**任何其它表名一律 `rejected`** —— 包括四张流水表、`document_lines`（随主单走）、
`sync_queue`、`clock_offset`，以及 `sqlite_master` 这类注入尝试。

**客户端可写的列**：

| 表 | 列 |
|---|---|
| `products` | `id` `code` `name` `barcode` `unit` `cost_price` `sell_price` `safety_stock` `category` `is_active` `remark` |
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
| `action_not_implemented` | `documentAction` | v1 不落地「动作」通道（R-3） |
| `return_exceeds_original` | RULE-007 / RULE-008 | 累计退货量超过原单量 |

其余拒绝原因是**自由文本**（含中文诊断信息），客户端只需展示，不要解析。

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
documentAction → rejected + action_not_implemented（v1 不落地）
响应与队列按 entityId 匹配（顺序打乱不影响）
批量 push 里一条失败不影响其它条目
同一 created_at 的多张单：分页不丢行、不重复、游标必推进
明细随主单同页返回，且不按 limit 截断
health 不需要鉴权，且不泄露业务数据
push / pull 缺令牌或错令牌 → 401
请求体不是 JSON / 缺 operations → 400
`pull` 恰好返回 6 个业务实体 + next_cursors（**不含主数据**）
```

> ⏸ **暂缓**：原「`documentAction` 幂等」一项**推迟到 R-3 裁定后**（见 `docs/reply.md`）。
> 其余各项不受影响。
