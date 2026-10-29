# `tool/` 测试脚本

**九个**脚本：**七个 Python** 供**测试人员在干净机器上**使用（**Python 3.8+、只用标准库**，
不需要 Dart / Flutter / pip 包 / 网络），**两个 Dart** 是**开发机专用**（要 Dart SDK，不随测试机分发）。

| 脚本 | 干什么 | 会写库吗 | 会不会动软件进程 | 跑在哪 |
|---|---|---|---|---|
| [`seed_test_data.py`](seed_test_data.py) | 写**测试用主数据**（商品 / 往来方 / 账户），可生成 SQL 注入探针数据 | ✅ 只写指定的测试库 | ❌ 不会 | 测试机 |
| [`destructive_acceptance.py`](destructive_acceptance.py) | 跑 `docs/desktop_acceptance.md` **第九节（异常与破坏性）** 的现场准备 + 自动验库 + 人工清单 | ✅ | 仅 9.1 隔离模式启动并强杀**它自己启动的**进程 | 测试机 |
| [`perf_seed.py`](perf_seed.py) | 造一份体量真实、内部自洽的账本（每张流水表 ≥ 10 万行） | ✅ 只写指定的测试库 | ❌ 不会 | 测试机 |
| [`perf_bench.py`](perf_bench.py) | 15 条热路径查询的 p50/p95 + `EXPLAIN QUERY PLAN` | ❌ 只读（`mode=ro`） | ❌ 不会 | 测试机 |
| [`perf_monitor.py`](perf_monitor.py) | 实测期间按 0.2–0.5 秒记录进程/文件指标，并**自动发现进程、自动识别操作**（不用按键） | ❌ 只读 | ❌ 不会 | 测试机 |
| [`downgrade_to_v5.py`](downgrade_to_v5.py) | 把 v6 库降级成 v5 形状，用来验「老库升级」的迁移路径（机房机器会被还原，发旧包还得再解决旧库造数） | ✅ 只改指定的测试库（有数据要 `--yes`） | ❌ 不会 | 测试机 |
| [`db_audit.py`](db_audit.py) | **只读审计**账务不变量 INV-1~8（单据金额 / 缓存 / 纪律 11 / 孤儿行 / `seq_no` 唯一 / 退货累计） | ❌ 只读（`mode=ro`） | ❌ 不会（软件开着也能跑） | 测试机 |
| [`gen_schema_snapshot.py`](gen_schema_snapshot.py) | 从 `schema.dart` 生成/校验 `schema_snapshot.json` | ❌ 只写快照文件 | ❌ 不会 | 开发机 |
| [`import_guard.dart`](import_guard.dart) | 根层 `lib/` `test/` 的**导入守卫**（缺 import 的桶导出 / 同集公开类型） | ❌ | ❌ | **开发机**（要 Dart SDK） |
| [`selfcheck_import_guard.dart`](selfcheck_import_guard.dart) | 上面那个守卫的**自检**（造迷你仓库，断言它报的正好是那几条） | ❌ | ❌ | **开发机**（要 Dart SDK） |

**分发到测试机时，必须整目录带走**（至少：上面六个测试机脚本 + `schema_snapshot.json`）——
详见 §一·4 与 §七。**两个 `.dart` 不要分发**：测试机没装 Dart SDK 也跑不了。

> ⚠️ 常规验收不会启动或结束 `shensuanzi.exe`。9.1 的 `--phase watch-write`
> 是例外：它在系统临时目录创建空账套，使用隔离的 `APPDATA` 启动你指定的测试版，
> 监听该账套的 SQLite 文件变动后立即强杀**仅由它启动的那个 PID**，再重新启动供人工确认。
> 它不按进程名结束已有实例，也不接触已有正式数据库。

---

## 一、`seed_test_data.py` —— 写测试数据

### 1. 快速开始

```bash
# 看看会写什么（指定测试目录；一个字节都不写）
python tool/seed_test_data.py --data-dir "D:\\测试数据" --dry-run

# 往明确指定的测试目录写 100 条（= 默认值）
python tool/seed_test_data.py --data-dir "D:\\测试数据"

# 指定位置、一次写 500 条
python tool/seed_test_data.py --db "D:\测试数据\shensuanzi.db" --count 500

# 指定数据目录（库名固定 shensuanzi.db，与软件一致）
python tool/seed_test_data.py --data-dir "D:\测试数据" --count 100

# 额外生成「可能触发 SQL 注入」的数据
python tool/seed_test_data.py --db "D:\测试数据\shensuanzi.db" --inject
```

### 2. 三个参数就是任务书里的三条要求

| 要求 | 实现 |
|---|---|
| 允许设置**写入位置** | 写入时必须明确指定 `--db <库文件>` 或 `--data-dir <目录>`；脚本没有任何本机数据目录默认值，未指定只允许不访问库文件的 `--dry-run` |
| 允许设置**一次写入量**（默认 100） | `--count N`，默认 `100`。**记录条数**，三张表按 3:3:2 分配 |
| 写入范围 = **除单据以外的可写入表**；写入方法**尽量为新增** | 只写 `products` / `parties` / `accounts` 三张**主数据**表；**只 INSERT，不 UPDATE、不 DELETE** |
| 生成**可能发生 SQL 注入**的数据 | `--inject [KIND]` |

### 3. 为什么**不**写单据与四张流水（重要）

`Agents.md` 把数据分两类：**主数据**（可增可改）与**业务数据**（`documents` +
`document_lines` + `stock_ledger` / `money_ledger` / `party_ledger` / `settlements`，
**只插入、不更新、不删除**）。业务数据还有两个绕不过去的约束：

1. **纪律 11**：任何资金流动必须挂在一张 `receipt` / `payment` 单下 ——
   直接写 `money_ledger` 而不写收付款单，造出的是**规则上不可能存在**的账；
2. **真相在流水**：库存 = `SUM(stock_ledger.quantity)`、资金 =
  `accounts.initial_balance + SUM(money_ledger.amount)`、往来 = `SUM(party_ledger.amount)` ——
   单据与流水一旦不自洽，测出来的「账不对」是**造数造的**，不是软件的缺陷。

要造**真实可信**的单据，唯一正确的路是走 `RuleEngine`（就是「打开软件 → 开单 → 保存」），
那是功能验收的事（`docs/desktop_acceptance.md` 第四节），不是本脚本的事。
本脚本负责把**档案**填满：开单页的选人 / 选货 / 选收款账户、库存页搜索、
导出与备份的体量，都靠这些。

### 4. schema 在开发机读源码，测试机使用随工具分发的快照

干净环境（库不存在、或 `user_version = 0`）时脚本会先建表。它**不内嵌一份 DDL**，
而是从

    packages/shensuanzi_core/lib/src/db/schema.dart

里解析 `createStatements` 并做 `$` 插值。测试设备通常没有源码，所以 `tool/` 同时提供
`schema_snapshot.json`：它是从当前 `schema.dart` 生成的离线快照。**分发时必须把
`seed_test_data.py`、`destructive_acceptance.py` 和 `schema_snapshot.json` 放在同一个目录**；
脚本会优先读取旁边的源码，找不到源码时自动回退到快照，不要求测试人员访问开发机路径。
在开发仓库中，如果快照与 `schema.dart` 版本或 DDL 指纹不一致，脚本会明确报快照过期。

脚本会打印**建表语句指纹**；同一个结构无论是一次性建的还是逐版迁移来的，
指纹都相同（列顺序差异已归一化 —— `ALTER TABLE ADD COLUMN` 只能追加到列尾，
所以迁移来的真库与 `CREATE TABLE` 的文本顺序本来就不同）。

### 5. 注入数据的用法

`--inject` 取值为 `all`（默认）/ `sql` / `xss` / `path` / `fmt` / `misc` / `encoded`。
载荷覆盖：经典 SQL 注入（引号 / OR 1=1 / UNION / 堆叠 / ATTACH / PRAGMA …）、
XSS、路径穿越、格式串、编码混淆（`%27` / 双重编码 / Unicode 转义 / HTML 实体 /
UTF-7 / 全角撇号）、以及多语言与边界字符（emoji / 零宽 / 双向控制 / 全角空格 / 换行）。

它们落在**所有文本列**上（`name` / `remark` / `barcode` / `phone` / `address` /
`roles` / `unit` / `code` …），因为这正是软件真正拼串的地方 ——
搜索框、建档内联提示、扫码、导出 CSV、同步 upsert。

**所有写入都走参数化查询**，注入串是**当数据存进去的字面文本**；脚本自己不拼 SQL，
所以脚本本身不会因为注入串损坏库。脚本跑完会**逐字节核对**每条载荷能否原样读回，
并把清单打出来，供测试人员逐条去界面上试（清单里附了「怎么用这串数据」的步骤）。

### 6. 其它开关

| 开关 | 用途 |
|---|---|
| `--dry-run` | 只打印计划、样本、载荷清单，不写库 |
| `--allow-nonempty` | 默认发现任何用户表已有数据就拒绝；仅对隔离测试库显式加此项才继续 |
| `--seed <值>` | 随机种子（默认 `shensuanzi`）—— 同种子同结果，便于复现 |
| `--on-conflict fail\|skip` | 撞 UNIQUE 时：`fail` 报出来（默认）/ `skip` 跳过（幂等重跑用） |
| `--schema-source <路径>` | 可选，显式指定 `schema.dart`；默认仓库内读源码，无源码时使用同目录快照 |
| `--quiet` | 只打结论，不打样本与载荷清单 |

退出码：`0` 成功 · `3` 读不到 schema 单一来源 · `4` 库的 schema 版本不符（**拒绝写入**）·
`5` 写入成功但有需要看一眼的问题。

---

## 二、`destructive_acceptance.py` —— 第九节验收

### 1. 它对应 `docs/desktop_acceptance.md` 第九节逐条

| # | 场景 | 脚本能自动验的 | 必须人做的 |
|---|---|---|---|
| 9.1 | 强杀 / 断电 | `watch-write` 启动隔离应用，监听 SQLite 文件写入后强杀本进程；重启后验完整性 | 确认重启进入主界面、数据仍在；断电仍须人工 |
| 9.2 | 只读 / 磁盘满 | 探针实测目录可写性；造现场 | **改权限**（脚本不代改）、看界面说了什么 |
| 9.3 | 数据目录被删 / 改名 | 区分「重建了空库」与「老库还在」；验改名后的库数据完整 | **在软件运行时改名**（脚本不代做） |
| 9.4 | 时钟回跳 | 伪造未来时间的备份，验「回跳 ⇒ 重新锚定」；验保留策略 | **拨系统时间**（脚本不代改） |
| 9.5 | 并发备份 | 同一分钟的文件名唯一性；扫目录里有没有哪一分钟出现多份 | **连点 10 次「立即备份」** |
| 9.6 | 超长输入 | 写 1K/10K/64K/1M 字符并逐字节读回；验完整性 | 看界面溢不溢出、卡不卡 |
| 9.7 | 非法字符 | 14 种非法/边界字符落库 → 等值查询往返 → 外键校验 | 看搜索、emoji 显示、CSV 导出 |

### 2. 推荐用法：三段式

破坏性验收天然是「**摆现场 → 人去捣乱 → 回来验尸**」，所以拆三段：

```bash
# ① 准备现场、写本轮哨兵并生成运行清单（verify 将据此只读核对）
python tool/destructive_acceptance.py --phase prepare --data-dir "D:\测试数据" --confirm-test-data

# ② 人去做：强杀请用下方 watch-write；其余按报告执行人工步骤

# ③ 验尸（读库给结论 + 出报告）
python tool/destructive_acceptance.py --phase verify --data-dir "D:\测试数据"
```

`--phase all` 可一把过（prepare + verify 之间不留时间），只适合纯库层的几条；prepare / all
会向数据库插入哨兵与测试行，必须显式加 `--confirm-test-data`，确认目录指向隔离测试账套。

正式执行必须显式提供 `--data-dir`，避免默认路径误指向正式数据目录；`--dry-run`
不要求目录存在，也不写报告或创建目录。

9.1 的应用级强杀单独运行，自动创建系统临时空账套，不接受 `--data-dir`：

```bash
python tool/destructive_acceptance.py --phase watch-write --exe "C:\\path\\shensuanzi.exe" --confirm-app-kill
```

程序启动后，等它进入主界面按 Enter，再在窗口中保存商品或修改商品名。脚本监听到测试库的
`.db` / `-wal` 文件事件后立刻强杀自己启动的进程，随后重启并等待人工确认。
临时账套和隔离配置会保留，供查看和排查。

**prepare / verify / all 开工前请先关掉所有神算子窗口** —— 脚本检测到实例在跑会**拒绝运行**
（加 `--allow-running-app` 可强行继续）。理由：9.3 要改数据目录的名字，
有实例开着时改会绕过它的单实例锁（锁文件 `.shensuanzi.lock` 会被一起改走，
新实例在原路径看不到锁就照常启动）。

### 3. 安全边界（脚本**绝不**越过的线）

| 不做 | 为什么 |
|---|---|
| 常规阶段启动 / 结束应用 | prepare / verify / all 不操作软件进程；9.1 `watch-write` 是唯一例外，只启动并结束它自己的隔离实例 |
| 改系统时间 | 影响整机、需要管理员权限；`--use-system-time` 只表示「你已授权」，脚本自己仍不改 |
| 改目录 ACL | 万一恢复失败，那个目录会一直写不进去。脚本只**检测**现场、事后报告 |
| 改 / 删业务数据 | 只往主数据表**新增**带前缀的哨兵行（`S9验收哨兵*`），不改不删 |

常规 prepare / verify 不结束应用进程。`watch-write` 仅结束本脚本启动的隔离测试应用实例。

### 4. 三态，不是一个「通过」

| 状态 | 含义 |
|---|---|
| ✅ **通过** | 自动断言过了 |
| ❌ **不通过** | 自动断言失败 —— 这是真缺陷，按第十二节回报 |
| 🙋 **待人工** | 判据落在界面上，脚本读不到。**它已经把现场摆好**，人照 `🙋` 那几行做 |

⚠️ **「待人工」不是「通过」**。一条用例若既自动通过又需人工，报告里**只计入「待人工」** ——
因为整条还没做完。

### 5. 其它开关

| 开关 | 用途 |
|---|---|
| `--only 9.1,9.7` | 只跑这几条 |
| `--report <路径>` | Markdown 报告落点（默认写在 `destructive_acceptance.py` 同一目录） |
| `--backup-dir <路径>` | 备份目录（默认 = 数据目录的兄弟「神算子备份」，与软件一致） |
| `--use-system-time` | 表示你已授权改系统时间（只是让 9.4 的清单换个写法） |
| `--allow-running-app` | 检测到实例在跑也继续（会让 9.3 的结论不可信；watch-write 不需要此项） |
| `--confirm-app-kill` | watch-write 必须项，确认将强杀本脚本启动的测试应用 |
| `--watch-timeout` | watch-write 等待一次数据库写入的秒数（默认 600） |
| `--dry-run` | 只打印会做什么，不动任何东西 |

退出码：`0` 无「不通过」 · `1` 有「不通过」 · `2` 脚本自身的规则复刻与 Dart 期望不符 ·
`3` 数据目录不存在 · `4` 常规阶段检测到软件实例在运行 · `6` 报告文件写入失败。

### 6. 脚本内部有一处**复刻**，它每次运行都自检

9.4 / 9.5 要验的「备份文件名格式 / 保留策略 / 时钟回跳判定」，在 Dart 侧是
**纯函数**（`BackupFileName` / `expiredAutoBackups` / `shouldAutoBackup`）。
脚本要能在**不启动软件**的前提下验它们，只能复刻。

复刻的代价是可能漂移，所以每次运行都会跑
[`compare_with_dart()`](destructive_acceptance.py)（期望值抄自
`packages/shensuanzi_app/test/backup_test.dart`）；一旦不一致，
脚本会**以退出码 2 停下**并说明「这是脚本自身的问题，不是软件缺陷」。

---

## 三、已知发现（脚本在真机上踩出来的，待单独处理）

> 这两条**不是**脚本缺陷，是脚本在真机上撞出来的**软件侧**观察。
> 按纪律 12（测试红不是修改生产代码的授权），此处**只记录**，不动生产代码。

1. **改数据目录名会绕过单实例锁**（9.3 踩出）。
   单实例互斥靠数据目录里的 `.shensuanzi.lock`
   （`packages/shensuanzi_app/lib/src/instance_lock.dart`）。
   把数据目录**改名**后，锁文件跟着目录走；此时在原路径启动第二个实例，
   它在那里**看不到任何锁**，于是照常启动 —— 结果是两个实例各自操作
   「同一份数据的两个路径」。
   *影响面猜测*（未验证）：双实例 = 双写路径，同步上线后还会是两个 `SyncServer`
   抢端口。**复现步骤**：开着软件 → 把数据目录改名 → 再启动一次软件。
2. **`-wal` 可能长期不归并**。真库上观察到 `shensuanzi.db-wal` = 955872 字节、
   而 `.db` 只有 233472 字节。`Db.open` 没设过 `wal_autocheckpoint`
   （SQLite 默认 1000 页 ≈ 4 MB），所以 WAL 在 4 MB 以内不归并是**正常**的；
   但「软件正常退出后 WAL 还剩 900 KB」值得看一眼是不是连接没关干净。
   *未做验证*，仅记录。

---

## 四、开发这两个脚本时踩过的坑（留给下一个改它的人）

| 坑 | 症状 | 教训 |
|---|---|---|
| `CREATE UNIQUE INDEX` 的对象名 | 固定取第 3 个 token 会取到 `INDEX` 而不是索引名 | 解析 DDL 用正则匹配完整形态 |
| Dart 的 `sqlite3` 会**剥掉 SQL 注释** | 从源码抽出的 DDL 与库里 `sqlite_master.sql` 对不上 | 抽取后要跟着剥一次注释，否则指纹永远对不上 |
| `ALTER TABLE ADD COLUMN` **只能追加到列尾** | 迁移来的真库与 `CREATE TABLE` 的列顺序不同 ⇒ 指纹假报警 | 指纹要**归一化列顺序**再比 |
| `re.sub(r"\bnull\b", "", s)` | 把 `not null` 删成了 `not`（然后看似 `not unique`） | 用否定后顾：`(?<!not )\bnull\b` |
| 脚本自己造的假备份被自己当成「脏数据」 | 9.5 报出「同一分钟出现多份」的**假缺陷** | 真备份**永远非空** ⇒ 用「0 字节」区分现场与真实产物 |
| 局部连接出作用域即被 finalize | 「未 checkpoint 的 WAL」现场留不下来（被自动 checkpoint 了） | 要模拟「进程被杀」得**真的留一个进程**，别靠 `del` |
| 拿「路径下有没有 .db」当「软件重建了空库」 | 只是拷贝而非改名时误报 | 判据要能区分「空的新库」与「老库还在」 |

## 五、自验方式（改完脚本请跑一遍）

```bash
# 任务1：与真库做结构同构比对 + 三种写入模式
python tool/seed_test_data.py --dry-run
python tool/seed_test_data.py --db /tmp/干净.db --count 100
python tool/seed_test_data.py --db /tmp/干净.db --count 40 --inject --quiet

# 任务2：内部复刻自检（不依赖任何现场）
python tool/destructive_acceptance.py --dry-run

# 任务2：对**一份真库的副本**跑全套（不要直接拿生产库当小白鼠）
cp "D:\神算子数据\shensuanzi.db" /tmp/fixture/shensuanzi.db
python tool/destructive_acceptance.py --phase all --data-dir /tmp/fixture --confirm-test-data
```

判据：任务1 退出码 `0` 且打印「校验：通过」；任务2 打印
「备份规则复刻自检通过」且**没有** ❌ 条目。

> ⚠️ **`--db /tmp/干净.db` 那一行是关键**（别只跑 `--dry-run`）：`--dry-run`
> 不碰库，**永远不会**走到建表。2026-10-27 那个「空库建表必炸」的缺陷就是这样
> 藏了 3 天 —— 只跑 dry-run 一直是绿的。

---

## 六、长时间性能实测（`perf_*.py`）

三个脚本 + 一份手册，用于**外部测试机**上的「长时间使用」性能实测。
完整流程见 **[`docs/perf_test_guide.md`](../docs/perf_test_guide.md)**（测试人员只看那份）。

| 脚本 | 干什么 | 会写库吗 |
|---|---|---|
| [`perf_seed.py`](perf_seed.py) | 造一份**体量真实、内部自洽**的账本（每张流水表 ≥ 10 万行） | ✅ 只写指定的测试库 |
| [`perf_bench.py`](perf_bench.py) | 15 条热路径查询的 p50/p95 + `EXPLAIN QUERY PLAN` | ❌ 只读（`mode=ro`） |
| [`perf_monitor.py`](perf_monitor.py) | 实测期间按 0.2–0.5 秒记录进程/文件指标 + **自动发现进程、自动识别操作**（不用按键） | ❌ 只读 |
| [`downgrade_to_v5.py`](downgrade_to_v5.py) | 把 v6 库降级成 v5 形状，用来验迁移路径 | ✅ 只改指定的测试库 |
| [`gen_schema_snapshot.py`](gen_schema_snapshot.py) | 从 `schema.dart` 重新生成 `schema_snapshot.json`（**改 schema 后必跑**） | ❌ 写快照 |

参考基线（开发机实测，默认参数 ≈ 15–26 万单 / 36 万条库存流水 / 450–476 MB）：

| 查询 | **现在（schema v5 之后）** | v5 之前（留作对照） |
|---|---|---|
| `stock_group` / `stock_cost` | **30–40 ms** | 1336 / 648 ms |
| `party_balances` | **约 27 ms** | 620 ms |
| `recent_products` | **约 7 ms**（2026-10-27 实测） | 旧记录写 400 ms，量级已不符 |
| `doc_search` / `list_documents` | 300 ms / 150 ms 量级 | 同 |
| `today_summary` | **约 270 ms**（26 万单时） | 未记录 —— 概览页那张卡，大库上是第二慢 |
| `pull_*` / `lines_of_page` | **< 1 ms** | 同 |

> **v5（2026-10-24，§CV·九十八）把 `stock_ledger` / `party_ledger` 的聚合索引加宽成
> covering**（`idx_stock_covering` / `idx_party_covering`），每行不再回表 ⇒
> 1336 ms → 35 ms。**若你的 `stock_group` 又回到几百毫秒，先看 `--explain`
> 是不是退化成了非 covering** —— 那是缺陷，不是机器慢。
>
> 测试机的数字本来就更大，用来看「量级对不对」；完整表见手册 §4.5。

三条硬规矩：
1. **这份数据只能用于性能/容量，不能用于业务正确性验收** —— `perf_seed.py`
   直写 SQL（不是 RuleEngine），它只保证「四张流水 + 缓存字段自洽」；
2. **必须指定独立的测试目录**，且默认拒绝往已有业务数据的库里写
   （要重造须 `--allow-nonempty --confirm-wipe`）；
3. **改过 `schema.dart` 就必须重生成快照**，否则两个造数脚本都会以
   「快照已过期」停下（这是故意的）：
   ```bash
   python tool/gen_schema_snapshot.py            # 生成
   python tool/gen_schema_snapshot.py --check    # 校验（CI / 发版前）
   ```

最小自验（开发机上，不写仓库外任何东西）：

```bash
python tool/gen_schema_snapshot.py --check
python tool/perf_seed.py --data-dir /tmp/perf --dry-run
python tool/perf_seed.py --data-dir /tmp/perf --min-rows 800 --days 30 --products 40 --parties 30
python tool/perf_seed.py --data-dir /tmp/perf --verify
python tool/perf_bench.py --data-dir /tmp/perf --rounds 5 --explain
python tool/perf_monitor.py checklist
python tool/perf_monitor.py selftest     # 两秒钟：钉住「进程发现 + 动作识别」的逻辑
```

---

### 六之三、`perf_monitor.py` 的两件自动化（2026-10-27 实地反馈后重做）

用户原话：「不能自动发现进程，也不能自动记录用户操作，导致大部分性能数据都要
测试人员手动记录，出来的数据基本不可信」。这两条都改了：

| 以前 | 现在 |
|---|---|
| 要 `--process shensuanzi.exe`；软件改名就**静默没有进程指标** | **按窗口标题「神算子」自动发现**（`EnumWindows`），找不到才退回 exe 名；进程重启自动重挂并记一条 `process_restart` |
| 每个动作前敲 `s`、做完敲 `e`，耗时靠人按秒表（±0.3–0.5 秒） | **不用按键**：按 CPU / 读库 / 写库自动切分「操作事件」，空闲 0.5 秒一采、忙时 0.2 秒，**误差 = 采样间隔** |
| 忘了按就漏一条 | 有读写就会记（单点纯 CPU 尖峰会被当噪声丢掉） |

**它不猜页面名**：软件窗口标题是固定的，脚本看不到「你在库存页」。所以事件类型只有
`读库/界面重建` 与 `写库` 两种 —— 宁可说「不知道你在哪页」，也不编一个像真的标签。
想贴名字仍可 `s/e`，报告会把「自动 vs 人工」对齐并给出偏差（§二之一末尾）。

阈值可调：`--busy-cpu`（默认 25%）· `--busy-read-kb`（2048）· `--busy-write-kb`（256）·
`--idle-gap`（1.5 秒）。低配机上跑不动大查询时，`--busy-cpu 10 --busy-read-kb 512`。

**开测前先跑 `python tool/perf_monitor.py selftest`**（两秒、不需要软件）：
10 条合成用例钉住「进程发现 + 动作识别」（含「不许无中生有」「连点两下算一次」）。
它红了就别去测 —— 那一轮数据全是废的。

### 六之四、默认参数实测（2026-10-27，开发机）—— 数据量够不够

`python tool/perf_seed.py --data-dir <空目录>`（默认 `--min-rows 100000`）真跑：

| 表 | 行数 | 要求 |
|---|---|---|
| `document_lines` | 366,076 | ≥ 10 万 ✅ |
| `stock_ledger` | 366,076 | ≥ 10 万 ✅ |
| `party_ledger` | 262,614 | ≥ 10 万 ✅ |
| `money_ledger` | **100,000** | ≥ 10 万 ✅ 刚好 |
| `settlements` | **100,000** | ≥ 10 万 ✅ 刚好 |

**56 秒 / 479 MB / 147,708 张主单**（`documents` 共 262,614 行，含自动生成的收付款单）。

> 后两张**恰好 10 万**不是截断：主循环按天停会超额，**第二阶段「补收付款」精确顶到线**
> 就收手。⇒ **零余量**。想要余量传 `--min-rows 150000`（多花十几秒）。

同一份库的基准（`perf_bench --rounds 5`）：`stock_group` 41.5 ms · `stock_cost` 42.0 ms ·
`party_balances` 28.2 ms · `doc_search` 364 ms · `list_documents` 153 ms ·
`today_summary` 273 ms · `pull_*` < 1 ms —— 量级与 §六 基线对得上，**够用来测**。

⚠️ **这份数据跑 `db_audit` 应当全绿**（2026-10-27 起）。若看到 `INV-1b` / `INV-7` 报 ❌，
那是造数脚本的缺陷回来了，不是软件的账错了 —— 先看 `perf_seed.py` 里
`retune_line_amount()` 与「退货按原单」那两段。

## 七、schema 快照过期了怎么办（2026-10-27 真踩过）

### 7.1 症状

| 你会看到 | 说明 |
|---|---|
| `⛔ 库的 schema 版本是 4，脚本支持 5` | 你手上的 `schema_snapshot.json` 比软件旧 |
| `⛔ …第 N 条不是完整语句（很可能是被切碎的残句）` | 快照是**坏的**（见 §7.5）—— 别绕过，回开发机重生成 |
| `⚠️ 随脚本分发的 schema 快照已过期` | **开发机上**才会出现（有源码，脚本改读源码继续跑）；测试机上不会 |
| 造数跑到一半报 `no such column` | 极可能是快照与软件版本错位 |

### 7.2 一条命令修（在**开发机**上）

```bash
python tool/gen_schema_snapshot.py          # 重新生成
python tool/gen_schema_snapshot.py --check  # 只校验（CI / 发版前必跑）
```

`--check` 一致时打印 `✅ 快照与源码一致：源码 v5 / 39 条语句 / 指纹 …`，不一致时以非 0 退出。

### 7.3 出发前 30 秒自检（在**测试机**上，不需要源码）

```bat
cd /d D:/perf-tools
python -c "import json;d=json.load(open('schema_snapshot.json',encoding='utf-8'));print(d['schema_version'],d['fingerprint'])"
```

**随本仓库分发的快照**（2026-10-27 生成，对应 schema v5）：

```
schema_version = 5
statements     = 39
fingerprint    = 96443aa85b0552bb
```

> 这两个数对不上 ⇒ **停下**，回开发机跑一次 `gen_schema_snapshot.py`，别硬着头皮测 ——
> 用旧结构造出来的库，后面所有数字都不可信。

### 7.4 为什么会过期（写给人看的）

`tool/README.md` 与 `tool/gen_schema_snapshot.py` 都写着「改过 `schema.dart` 就必须重生成快照」，
但那是**靠人记**。2026-10-24 加了 v5（覆盖索引，见 §六 基线），快照一直没重生成，
到 10-27 已经**过期 3 天** —— 那天晚上要跑性能测试，第 ② 步会直接以
`⛔ 库的 schema 版本是 4` 停下。

⇒ **规矩**：凡改 `Schema.version` 或 `createStatements`，同一个提交里跑一次
`python tool/gen_schema_snapshot.py`，并把 `schema_snapshot.json` 一起提交。
发版前再跑一次 `--check` 兜底。

### 7.5 2026-10-27 那次「快照是坏的」（比过期更严重）

| 项 | 内容 |
|---|---|
| 现象 | 空库建表一律 `sqlite3.OperationalError: near ";": syntax error` |
| 根因 | `schema.dart` 里 v5 覆盖索引写成**两个相邻字面量拼接**（`'…stock_ledger('` 换行 `'product_id, …)'`），旧解析器「一个字面量 = 一条语句」⇒ 切出 `…stock_ledger(;` 和 `product_id, …);` 两条残句 |
| 影响面 | 两个造数脚本**都**中；分发的快照里存的也是残句 ⇒ 测试机同样炸 |
| 为什么没早发现 | `--check` 是**假绿** —— 源码侧与快照侧用同一个坏解析器，指纹当然一致 |
| 修法 | 解析器合并「相邻字面量」；另加 `check_statement_shape()`：每条必须以 DDL 关键字开头、以 `;` 结尾，切碎立刻停 |

⇒ **判据**：`--check` 通过 ≠ 快照可用。真正能证明的是**空库能建出来**：

```bash
python tool/seed_test_data.py --db /tmp/空库.db --count 10
```

这条过不了，就别去测试机上折腾。
