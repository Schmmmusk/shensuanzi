# C-1：主数据 update↔update 乱序不收敛 —— 落地方案

> 来源：`docs/business-review-2026-10-21.md` §3.7 C-1（2026-10-21 业务审查）。
> 状态：**✅ 已裁定（2026-10-24，用户选「甲」）+ 已落地**，见 `docs/reply_review.md` §CV·九十四。
> ⚠️ **裁定附一处修正**：提案里的公式 `(op.baseVersion ?? 0) + 1` 对 `create` 会得 1，
> 与「create 仍 v0」自相矛盾 —— 用户指出后改为
> **`op.baseVersion == null ? 0 : op.baseVersion! + 1`**，落地以此为准。
> 相关：`docs/sync_protocol.md` §8.1（收敛措辞已于 2026-10-24 收窄，见 §CV·九十二）、
> `docs/data_model.md` §4.1、`Agents.md` §二·8「主机永远赢」。

---

## 一、一句话

主数据同一行的**两次 update 乱序到达**时，当前实现会让**旧值赢**（两个方向都会），
且客户端会把「第二次修改」当成冲突**静默回退**。修法只需一行：
**upsert 建档时把 `sync_version` 写成 `base_version + 1`**（而不是恒写 `0`）。

> One line: when two updates to the same master-data row arrive out of order, today's
> implementation lets the **older value win** (in both orders), and the client silently
> rolls back the second edit as a "conflict". The fix is one line: when the upsert path
> creates the row, write `sync_version = base_version + 1` instead of always `0`.

---

## 二、复现与根因

### 2.1 已核验的三个事实

| # | 事实 | 证据 |
|---|---|---|
| 1 | 客户端**逐次**本地 +1：第二次编辑的 `base_version` 是 1（不是 0） | `master_data_sink.dart:448`（`syncVersion: existing.syncVersion + 1`）+ `:458`（`baseVersion: existing.syncVersion`） |
| 2 | 主机「行不存在」分支**忽略 `base_version`**，一律写 `sync_version = 0` | `sync_server.dart:600`（`'sync_version': 0`） |
| 3 | 版本不等 ⇒ `conflict` ⇒ 客户端用 `server_state` 覆盖本地并**删掉队列条目** | `sync_server.dart:668`；`sync_client.dart:252-258` |

> Three verified facts: (1) the client bumps its local version per edit, so the second
> edit carries `base_version = 1`; (2) the host's "row missing" branch ignores
> `base_version` and always writes `sync_version = 0`; (3) a version mismatch yields
> `conflict`, and the client overwrites its local row with `server_state` and **deletes
> the queue entry**.

### 2.2 两条时间线（都是「旧值赢」）

设售价 12 → 11.5，U1 = 12（base 0）、U2 = 11.5（base 1）。

**分支 A：U2 先到（U1 在退避重试）**

| 步 | 主机 | 结果 |
|---|---|---|
| 1 | U2 到达，行不存在 ⇒ upsert 建档，写 `sync_version = 0` | 行 = 11.5 @ v0 |
| 2 | U1 到达，`version(0) == base(0)` ⇒ **通过**，覆盖成 12 | 行 = **12** @ v1 ✗ |

**分支 B：U1 先到**

| 步 | 主机 | 结果 |
|---|---|---|
| 1 | U1 到达，行不存在 ⇒ upsert 建档 `v0` | 行 = 12 @ v0 |
| 2 | U2 到达，`version(0) != base(1)` ⇒ **conflict**，回 `server_state`(12) | 行 = 12；客户端把本地改成 12 并**删掉 U2 条目** ✗ |

用户看到的：手机里刚改的 11.5 变回 12，还提示「已在别处被修改」（其实没有别处）。

> Timeline A: U2 arrives first and is inserted at v0; then U1 (base 0) matches v0 and
> **overwrites** the newer value. Timeline B: U1 is inserted at v0; U2 (base 1) then
> mismatches, the client takes `server_state` and **drops** its own newer edit.
> Either way the user's second edit is lost, with a misleading "modified elsewhere" hint.

### 2.3 根因

**upsert 建档时丢掉了 `base_version`** —— 版本号没有从客户端「接手」，
于是后续到达的旧 update 无法被识别为旧。
（`conflict` 那条分支本身是**对的**：它正是「主机赢」的表达，只是被错误地喂了错误的版本号。）

> Root cause: the upsert path **drops `base_version`**, so the host cannot tell a stale
> update from a fresh one. The `conflict` branch itself is correct — it is the "host wins"
> rule; it was simply fed a wrong version number.

---

## 三、选项

### 甲（推荐）：upsert 时 `sync_version = base_version + 1`

`_insertMasterData` 里 `'sync_version': 0` 改为 `'sync_version': (op.baseVersion ?? 0) + 1`。

- `create` 没有 `base_version` ⇒ 仍是 0（行为不变）。
- `update` 建档 ⇒ 版本「接着」客户端报的 base，客户端本地的版本号恰好就是 `base + 1`
  ⇒ 两侧版本号一致，不再有「主机 v0 / 客户端 v1」的错位。
- 之后任何**更旧**的 update（base ≤ 当前版本 − 1）都会被 `conflict` 挡住，
  客户端拿到的 `server_state` 是**新值** ⇒ 收敛到新值。

**Option A (recommended):** in the upsert path write `sync_version = base_version + 1`.
`create` has no base ⇒ stays 0 (unchanged). An `update`-upsert now inherits the client's
base, so both sides agree on the version, and any later, staler update is blocked by the
existing `conflict` branch — which returns the **newer** `server_state`.

### 乙：update 做版本单调判断（「后到不覆盖更高版本」）

当前版本 > `base_version` 时，不覆盖、直接回 `applied`（或回 `conflict`）。

- 单独用**修不了分支 A**（U1 到达时 `version == base`，不是「更高版本」）。
- 若把返回改成 `applied`：客户端会标记 `sent`，pull 后再被主机值覆盖 ⇒ 终态相同，
  但**并发编辑**（电脑上同时改过价）也会被**静默丢弃**，连提示都没有。

**Option B:** treat a lower `base_version` as "stale, don't apply". Alone it does **not**
fix timeline A. If it answers `applied`, genuine concurrent edits are silently dropped
with no hint at all.

### 丙（不做）：服务端按 base 排序 / 等待缺口

需要「等 U1 到了再处理 U2」的排序缓冲，等于在主机上重建有序队列。
与「客户端队列顺序 + 重试退避」的现有设计冲突，收益为零（甲已足够）。

**Option C (rejected):** server-side reordering/buffering. It rebuilds an ordered queue on
the host, conflicts with the existing "client queue order + backoff" design, and adds
nothing over A.

### 丁（不做）：客户端合并同 id 的多次 update

客户端队列「不合并」是 2026-10-08 的既定契约（`data_model.md §4.1`），
合并会引入新的乱序来源（合并后的条目该排在哪？）。

**Option D (rejected):** merge same-id updates on the client. "Do not merge" is the
standing contract; merging would create a new source of ordering ambiguity.

---

## 四、甲的时间线验证

| 顺序 | 主机最终 | 客户端最终 | 结论 |
|---|---|---|---|
| U1 → U2 | insert v1(12) → U2 `v1 == base1` 通过 → 11.5 @ v2 | pull 得 11.5 | ✅ |
| U2 → U1 | insert v2(11.5) → U1 `v2 != base0` ⇒ conflict，回 11.5 | 覆盖成 11.5、删 U1 条目 | ✅ 收敛到新值 |
| create → update | create v0 → U `v0 == base0` 通过 | 一致 | ✅（不变） |
| update → create | insert v1 → create ⇒ `already_exists`（不改行） | pull 得新值 | ✅（不变） |

> Both orders converge to the newer value; create↔update behaviour is unchanged.

---

## 五、改动清单（预计 4 个文件）

| 文件 | 改动 |
|---|---|
| `packages/shensuanzi_host/lib/src/sync_server.dart` | `_insertMasterData` 的 `'sync_version': 0` → `(op.baseVersion ?? 0) + 1`，并加注释说明「upsert 接手 base」 |
| `packages/shensuanzi_host/test/sync_server_test.dart` | 新增 4 条（见 §六） |
| `packages/shensuanzi_host/tool/selfcheck_sync.dart` | 镜像同场景（纪律：`test/**` ↔ `tool/selfcheck*.dart` 成对） |
| `docs/sync_protocol.md` §8.1 | 把 2026-10-24 的「不保证」收窄段改为「**收敛到版本更高者**」+ 一句「upsert 建档时版本接手 base」 |

> Four files: one production line, four tests, one mirror, one doc paragraph.

---

## 六、红测试设计（先红后改）

1. **分支 A**：行不存在时先推 U2(base 1) ⇒ 再推 U1(base 0) ⇒ 主机值仍是 **11.5**（旧实现是 12）。
2. **分支 B**：先推 U1(base 0) ⇒ 再推 U2(base 1) ⇒ `applied`，主机值 **11.5**。
3. **两种顺序终态相同**（同一条断言两遍，参数化）。
4. **回归护栏**：`create`（无 base）仍写 `sync_version = 0`；`update` 建档后行版本 = base + 1。

> Red tests: both orders must end at 11.5; `create` still writes v0; an update-upsert lands
> at `base + 1`.

---

## 七、风险与回归

| 风险 | 评估 |
|---|---|
| 旧客户端（永远发 base 0） | **不更差**：今天它只要遇到「行已在 v≥1」就已经 conflict；甲不改这条路径 |
| `base_version` 异常大（如 999999） | 建档后版本极大 ⇒ 后续全部 conflict。属客户端 bug，**不额外兜底**（与「不静默兜底」一致），可留一句日志 |
| 与「主机永远赢」冲突？ | 不冲突 —— 甲让 `conflict` 分支拿到**正确**的版本号，正是主机赢的正确表达 |
| schema / 数据迁移 | **无**（只改写入值，不改列） |

> No schema change. Old clients are not made worse. A bogus huge `base_version` degrades to
> permanent conflicts (client bug, not silently patched). The "host wins" rule is preserved —
> A simply feeds the conflict branch the correct version.

---

## 八、已知残余（不修）

`conflict` 时客户端会提示「已在别处被修改」。在「旧编辑被新编辑覆盖」的场景里，
这句话**字面不准**（并没有别处）。但它传达的处置是**对的**（本地已按主机对齐），
且改成别的文案会让真正的并发编辑提示变弱 ⇒ **保留**，只在本提案留档。

> Known residual: the "modified elsewhere" hint is imprecise when the edit was merely
> superseded, but its action is correct; rewording would weaken genuine concurrent-edit
> warnings. Keep as is, documented here.

---

## 九、推荐回法

**`甲`**（一行改动 + 4 条测试 + 1 处协议措辞）。若你更在意「不出现 conflict 提示」，
可以叠 `乙` 的 `applied` 变体，但代价是并发编辑静默丢弃 —— **不推荐**。

> **Answer: `甲`.** Optionally stack B's `applied` variant to suppress the conflict toast,
> at the cost of silently dropping genuine concurrent edits — not recommended.
