# R-13 裁定：方案 A —— 主数据并入 `pull`

## 一、为什么选 A 而不是 B

**核心判断：`pull` 是"同步"这件事的唯一入口，不应该被拆成两个。**

| 维度 | 方案 A（并入 pull） | 方案 B（§8.3 加 since） |
|---|---|---|
| 客户端同步循环 | 一个游标状态对象，一次请求 | 两套循环，两套状态 |
| 与 push 对称性 | push 单端点处理 5 类 op | pull 单端点处理 9 个实体 |
| §8.3 的定位 | 保持"手动/UI 便利接口"，不承担同步职责 | 被迫升级为"增量同步端点" |
| 未来扩展 | 加实体 = 加游标 + 加数组 | 每个实体要设计一遍 REST 增量语义 |
| 一致性幻觉 | 一次 pull ≈ 同一时刻的快照 | 两次请求之间状态可能变 |

方案 B 看起来"职责分离更干净"，但实际上把**同步**的职责偷偷塞进了一个原本定位为"便利接口"的 REST 端点——`§8.3` 现在明确标注"v1 未实现"，B 会让它变成 v1 必须实现的东西。这与"最小 v1"的原则相悖。

**A 的一个真实代价**：`pull` 会变宽。但增量游标决定它每次只拉变化的部分，主数据变化频率远低于业务数据，实际带宽增量可忽略。

## 二、游标设计：`(updated_at, id)` 复合

主数据的游标列是 `updated_at`（毫秒时间戳），但它**不唯一**——同一毫秒内两次更新会撞。与 `documents` 的 `(created_at, id)` 完全同构：

```
游标格式： "1700000000000|0192abc..."
谓词：     (updated_at, id) > (cursor_ts, cursor_id)
排序：     ORDER BY updated_at, id
```

**为什么不用 `sync_version`**：它是**每实体独立的乐观锁计数**，不是全局游标。实体 A 的 `sync_version = 5` 与实体 B 的 `sync_version = 5` 之间没有任何顺序关系，用它做游标会在分页时丢行或死循环。

**为什么不用 `created_at`**：主数据**会被更新**——`updated_at` 才是变化的信号。用 `created_at` 做游标，客户端永远拉不到"改了价格"这件事。

**索引**（纯增量，无迁移）：

```sql
CREATE INDEX idx_products_updated ON products(updated_at, id);
CREATE INDEX idx_parties_updated  ON parties(updated_at, id);
CREATE INDEX idx_accounts_updated ON accounts(updated_at, id);
```

## 三、接口变更（`sync_protocol.md` §8.2）

### 请求

```
GET /api/sync/pull
  ?stock_since=123
  &money_since=45
  &party_since=67
  &settle_since=12
  &doc_since=1700000000000|0192...
  &products_since=1700000000000|0192...
  &parties_since=1700000000000|0192...
  &accounts_since=1700000000000|0192...
  &limit=100
```

### 响应

```json
{
  "documents":       [ ... ],
  "document_lines":  [ ... ],
  "stock_ledger":    [ ... ],
  "money_ledger":    [ ... ],
  "party_ledger":    [ ... ],
  "settlements":     [ ... ],
  "products":        [ ... ],
  "parties":         [ ... ],
  "accounts":        [ ... ],
  "next_cursors": {
    "stock_since":     "200",
    "money_since":     "88",
    "party_since":     "134",
    "settle_since":    "25",
    "doc_since":       "1700000000100|0192def...",
    "products_since":  "1700000000100|0192ghi...",
    "parties_since":   "1700000000100|0192jkl...",
    "accounts_since":  "1700000000100|0192mno..."
  }
}
```

### 关键语义

| 项 | 决定 |
|---|---|
| **软删除行** | **包含**在响应中（`is_active = 0`）。客户端据此在本地标记删除。不包含则客户端永远无法感知删除 |
| **返回列** | **全部列**（含 `sync_version` / `updated_at` / `created_at`）。客户端需要 `sync_version` 做下次 `updateMasterData` 的 `base_version`，需要 `updated_at` 做游标 |
| **`limit` 语义** | 相同 `limit` 应用于每个分页实体，**各自独立推进**。某一实体先拉完不影响其它 |
| **`document_lines`** | 仍随 `documents` 同页返回，无独立游标（R-4 已定） |

## 四、§8.3 的重新定位

§8.3 保持为**手动/UI 便利接口**，**明确不承担同步职责**：

> §8.3 的 GET 接口服务于 Windows UI 的查询与调试。**它不是同步机制**——
> 增量同步一律走 §8.2 的 `pull`。§8.3 保持"v1 未实现"状态不影响同步功能完整性。

这条写进 §8.3 开头，防止未来有人再次把同步职责往这两个端点里塞。

## 五、客户端处理逻辑

```
for entity in [products, parties, accounts]:
  rows = response[entity]
  for row in rows:
    if row.id 已在本地:
      if row.sync_version > 本地.sync_version:
        覆盖本地
    else:
      插入本地
  cursor[entity] = response.next_cursors[entity + "_since"]
```

**关于"本地已有但 `is_active=0`"**：客户端不主动删除行，只把 `is_active` 更新为 0。这保留了"已删除商品"的历史引用（例如历史单据里引用的 `product_id` 仍能查到名称）。

## 六、连带影响

| 位置 | 影响 |
|---|---|
| `docs/data_model.md` §2.1 / §2.2 / §2.3 | 各加一行索引说明：`(updated_at, id)` |
| `docs/data_model.md` §五 | 新增不变量 B7：主数据的 `updated_at` 在每次写操作后被主机刷新 |
| `docs/sync_protocol.md` §8.2 | 请求/响应/游标语义全部更新（如上） |
| `docs/sync_protocol.md` §8.3 | 开头加"不承担同步职责"声明 |
| `docs/sync_protocol.md` §十一 | 测试项补：主数据增量同步、软删除可见、`(updated_at, id)` 不丢行 |
| `docs/testing.md` §G2 | HTTP 层测试补：pull 返回 **9 个实体**（不再是 6 个），含主数据游标 |
| `packages/shensuanzi_core` | `SyncPullResult` 加 3 个字段；`SyncCursorKeys` 加 3 个键 |
| `packages/shensuanzi_host` | `SyncServer.pull` 加 3 个实体的分页逻辑；`SyncCursor` 解析支持复合游标 |
| schema | 3 个新索引，纯增量 |
| 现有断言 | "pull 恰好返回 6 个业务实体"必须改为 9 个——**这是一次会真实失败的既有测试**，要主动修 |

## 七、测试要点

```
- 客户端 A 改商品价格 → 客户端 B 带游标 pull → B 拿到新价格
- 客户端 A 软删商品 → 客户端 B pull → B 拿到 is_active=0 的行
- 同一毫秒内两次更新主数据 → (updated_at, id) 游标不丢行、不重复、必推进
- pull 返回 9 个实体 + next_cursors（不再是 6 个）
- §8.3 的 GET 接口与 pull 互不影响（两个端点返回的主数据视图一致）
- 客户端 B 从未见过某商品 → pull 到 is_active=0 的行 → 本地存储为非活跃
```

## 八、R-13 状态

| 项 | 状态 |
|---|---|
| R-13 | ✅ 已裁定：方案 A |
| 实现阻断 | ✅ 解除 |
| 连带文档 | `data_model.md` §2.x + §五、`sync_protocol.md` §8.2 + §8.3 + §十一、`testing.md` §G2 |

---

## 九、一个观察

这个缺口暴露出一个模式：**`pull` 的初始设计只考虑了"业务数据"（只插入、无更新），把"主数据"（可更新、有软删）留在了外面**。这不是疏漏，是当初对"同步"这件事的心智模型偏窄——下意识认为"同步 = 把新单据推上来"，而忘了"另一台设备也要知道你改了商品名"。

方案 A 的真正价值不是"少一个端点"，而是把 `pull` 的心智模型从"业务数据拉取"扩展为"**所有权威状态的增量拉取**"。这个扩展会让未来加任何新实体（仓库、用户、设置）都有统一的落点，不再需要重新讨论一遍。
