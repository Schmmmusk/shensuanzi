# Schema 迁移与兼容性

> 裁定来源：`docs/reply_review.md` **§AK·二**（消歧）/ **§AM·一**（落地）/ **§AO**
> （reply.md《Schema 兼容性：现在必须做的事》）。
> 本文件是**操作与纪律**的汇总；可执行版本在
> `packages/shensuanzi_core/lib/src/db/schema.dart` 与 `src/db/database.dart`。

---

## 一、版本号的三处关系（**唯一依据是 `PRAGMA user_version`**）

| 位置 | 是什么 | 参与迁移判定？ |
|---|---|---|
| `Schema.version` | 当前**代码的能力**（期望值） | — |
| **`PRAGMA user_version`** | 这个**库文件的现状** | ✅ **唯一依据** |
| 标记文件的 `schema_version` | 这个目录**最后一次被哪个版本操作过**（目录身份证） | ❌ 不参与 |

- 迁移的真相**只在 `PRAGMA user_version`**
- 迁移成功后 `AppBootstrap.refreshMarker` 把「身份证」刷新到库的真实版本
  （不刷新的话，每次启动都会觉得三处不一致）
- **备份文件名里的 schema 版本 = 库的真实数据格式版本**（§AJ 追认；不是标记版本）

## 二、迁移链：逐版本、不许跳跃

```dart
static const int version = 2;

static List<String> migrationStep(int from) => switch (from) {
  1 => <String>['ALTER TABLE products ADD COLUMN package_note TEXT NULL'],
  // 2 => <String>[...],   ← 将来 v2 → v3：加一行即可，不要动上面那步
  _ => throw MissingMigrationException(from),
};
```

- **一段管一版**：`migrationStep(N-1)` 负责 v(N-1) → vN
- 执行器**逐版本跑**，**每版一个事务**（失败只影响那一版）
- ⚠️ **别写成累积判断**（`if (from < N)`）—— 只有一步时看着对，**两步以上就是错的**
  （from=1 → v3 时会跑 v1→v2 的步骤却跳过 v2→v3）
- 改了 `Schema.version` 却漏写迁移 ⇒ `MissingMigrationException`，**启动即拦**

## 三、迁移前自动备份（**第一道防线**）

| 项 | 决定 |
|---|---|
| 时机 | 只在「存量库」分支（`0 < current < version`）；空库（v0）与已最新都不备份 |
| 位置 | **数据目录内**，文件名 `<db>.before-v{N}`（`N` = **迁移前**的版本） |
| 前置 | **先 `PRAGMA wal_checkpoint(TRUNCATE)` 再拷** —— WAL 模式下直接拷 `.db` 会丢未 checkpoint 的事务 |
| 成功后 | **保留一份** —— 它是「升级完立刻后悔」的唯一退路；不同版本各自留档（`before-v1` / `before-v2` …），互不覆盖 |
| 备份失败 | **不迁移**（连备份都做不了，就不该改用户的数据）⇒ 抛错并说「检查磁盘空间和文件夹权限」 |
| 迁移失败 | 关连接 → **抛原始异常**（不掩盖根因）。**库停在「最后一版已提交的版本」**，下次打开**从断点继续**（只跑没跑过的那几版）—— ⚠️ **不会自动回滚**（2026-10-03 裁定 · §BE） |

**⚠️ 备份是「人工退路」，不是自动回滚点**：软件**不会**在失败时拿它覆盖回去 ——
自动回滚会让下一轮**从头重跑**并**重蹈同一失败**；「停在断点、修好再继续」
既保住已完成的工作，也让失败点更可诊断。**用户侧**的恢复流程见帮助页
「备份与恢复」一章（六步）；`before-v{N}` 是其中一个**可能的输入**，**不是**软件自动执行的。

**为什么它比回滚更重要**：回滚只能保证「结构没有半成品」，回不到「升级前的样子」；
而文件级备份与崩溃时机无关。

## 四、旧代码打开新库：**拒绝**，不是崩溃

`SchemaTooNewException`。用户装回旧版时，旧代码读新结构会**静默错误或崩溃** ——
拒绝能明确告诉用户「升级软件，或从备份恢复」。

## 五、兼容性原则：**字段只增不删**

| 变更 | 兼容 | 处理 |
|---|---|---|
| 加列（可空 / 有默认） | ✅ | `ALTER TABLE ADD COLUMN` |
| 加表 / 加索引 | ✅ | `CREATE TABLE` / `CREATE INDEX` |
| 删列 | ⚠️ **禁止**（至少一个发布周期） | 先标 deprecated，下个大版本再删 |
| 改类型 / 约束 / 主键 | ❌ | **重建表 + 数据搬迁** |
| 改列语义 | ⚠️ **禁止** | **新加一列 + 双写**，旧列留到下一个大版本 |

目的：**旧客户端还能读新库** —— 个体工商户不会同时更新所有设备。

## 六、客户端镜像：**重建而非迁移**

镜像是**派生数据**（真相在主机）⇒ 客户端**不写迁移逻辑**：存 `mirror_schema_version`，
每次 pull 前比对主机版本，低了就 **drop 全部镜像表 + 重建 + 从头全量拉**。
代价是升级后第一次 pull 是全量的（可接受）；收益是客户端零迁移代码。
见 `sync_protocol.md` §8.2「客户端落库的约束」。

## 七、测试：两层保护

| 层 | 位置 | 管什么 |
|---|---|---|
| **化石库**（端到端） | `test/fixtures/v1_empty.db`（由 `tool/make_fixture.dart` 从 **git 历史**生成） | 历史真库能不能升上来 |
| **执行器单元** | `schema_test.dart` 的「降级构造」用例 | ALTER / 事务 / 回滚本身对不对 |

- **化石一旦提交就不再修改**（`docs/testing.md` §P）；**打开化石前必须先拷贝**
  （`Db.open` 会就地迁移）
- 自检镜像：`tool/selfcheck.dart` **§M**（`dart run` 可跑，不依赖 `dart test`）

## 八、当前状态

`Schema.version = 2`（`products.package_note`，§AJ·AI-5）。迁移链目前只有 **v1 → v2** 一段。
未落地（记在案）：客户端 `mirror_schema_version` + 重建逻辑（随 AH-B Android 端）。
