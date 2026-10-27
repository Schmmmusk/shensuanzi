# I 组（性能）今晚执行方案 —— 新电脑 · 2026-10-27

> **性质声明**：本文是**执行清单**，不是新手册。判读口径、脚本用法、常见问题一律以
> `docs/perf_test_guide.md` 为准（本文只负责「今晚照这个顺序敲」）。
> **不占主台账 §编号**；结果并入 `docs/reply_review.md`，并回填 `docs/proposals/README.md` 状态表。
>
> **为什么要有这份**：0.6.5 复跑里 I 组是「⬜ 未做（清单标注可选，时间不够）」。
> 而且**换了一台新电脑**——这正好回答手册里那句「测试机的数字本来就会更差，它只用来回答
> 『我这边的数字是不是离谱』」。

---

## 〇、开测前必须先做的一件事（**已替你做好，但今晚要确认**）

⚠️ **分发的 `schema_snapshot.json` 原来还是 v4，而代码已经是 v5。**
测试机上没有源码，`perf_seed.py` 只能靠这份快照 ⇒ 用旧快照会直接
`⛔ 库的 schema 版本是 4` 退出，今晚第 ② 步就卡死。

**已重新生成**（2026-10-27）：

```
源码 v5 / 40 条语句 / 指纹 3265deb2dc442c82
回读校验：✅ 指纹一致
```

**今晚在测试机上先跑这一条自检**（10 秒，不通过就别往下走）：

```bat
cd /d D:\perf-tools
python -c "import json;d=json.load(open('schema_snapshot.json',encoding='utf-8'));print(d['schema_version'],d['fingerprint'])"
```

期望输出：`5 3265deb2dc442c82`

> v5 就是那次「库存查询 1.3 秒 → 35 ms」的覆盖索引版本（§CV·九十八）。
> **今晚最有价值的一条，就是验证它在新机器上没退化** —— 见 §三·重点 A。

---

## 一、今晚要回答的三个问题

1. **数据涨到 10 万行/表（≈450 MB 库）以后，软件还能不能用？**
2. **卡在哪一步？**（哪个动作、几秒）
3. **卡的原因是库、是界面，还是机器？**（靠 `before.csv`/`after.csv` + 采样对照）

**明确不做**：不验收账对不对（造数是直写 SQL，不跑 RuleEngine）；不测手机同步（见 §七）；
不加 `--stress-docno`（那是另一条已知缺陷，单独一轮）。

---

## 二、准备（10 分钟）

### 2.1 拷到 `D:\perf-tools\`（5 个文件，缺一不可）

| 文件 | 作用 |
|---|---|
| `perf_seed.py` | 造数 |
| `perf_bench.py` | 库侧基线（只读） |
| `perf_monitor.py` | 人工实测记录（只读） |
| `seed_test_data.py` | 被 `perf_seed` 复用（加载 schema / 指纹校验） |
| `schema_snapshot.json` | **必须是刚生成的 v5**（见 §〇） |

### 2.2 环境

- Python **3.8+**（只用标准库，不装包）：`python --version` 能打印即可
- 磁盘 **≥ 3 GB** 空闲（450 MB 库 + 备份 + 导出）
- 电源策略 **「高性能」**（节能会降频，测出来是电源的锅）
- **记下这四件事**（写进报告，否则数字没法比）：

| 项 | 填这里 |
|---|---|
| CPU 型号 / 核数 | |
| 内存 | |
| 磁盘是机械还是固态 | |
| 系统显示缩放 + 软件里「界面大小」档位 | |
| 杀软实时防护开没开 | |

> 建议：**造数时**临时关杀软（否则慢的是杀软）；**人工实测时**按真实环境（开着）。

---

## 三、五步流程（命令已填好，路径按你的盘改）

### 第 ① 步：先让软件自己建一次目录（1 分钟）

打开神算子 → 选一个**全新**目录（如 `D:\perf-data`）→「开始使用」→ 看到主界面后**关掉软件**。

> 作用：拿到标记文件、配置、备份目录，以及一份**与软件同版本**的库结构。

### 第 ② 步：造数（机械盘 5–15 分钟，固态 1–5 分钟）

```bat
cd /d D:\perf-tools
python perf_seed.py --data-dir "D:\perf-data" --dry-run
```

先看计划（**确认目标目录是那个测试目录**，别看错指向正式账套），再去掉 `--dry-run`：

```bat
python perf_seed.py --data-dir "D:\perf-data"
```

**成功标志**：最后打印 `✅ 自检全过，可以用作性能基线。`
出现 `❌` 或退出码 5 ⇒ **把输出整段留下**，别继续往下测。

**本次 dry-run 实测（开发机，2026-10-27）**：

| 项 | 量级 |
|---|---|
| 单据 | 约 **15.4 万**张 |
| 全部行 | 约 **128 万**行 |
| 库 | 约 **450 MB** |
| 造数耗时 | 开发机约 257 秒（固态）；机械盘按 5–15 分钟估 |

> 手册表格里写的是「26 万单 / 146 万行 / 476 MB」—— 那是更早一次的实测值。
> **以你自己跑完的汇总为准**，别拿手册的数去对。

### 第 ③ 步：库侧基线（造完立刻跑，**软件不要开**）

```bat
python perf_bench.py --data-dir "D:\perf-data" --csv before.csv --explain > before-explain.txt
```

**这一步的数字 = 「软件没开时的库」**，用来和人工实测期间探针对照。

**重点看这几条**（括号里是 v5 后的期望值）：

| 查询 | 期望 | 不达标意味着 |
|---|---|---|
| `stock_group`（库存合计） | **30–40 ms** | 回到几百 ms ⇒ **v5 覆盖索引没生效 / 退化了**，立刻报 |
| `stock_cost`（成本余值） | **30–40 ms** | 同上 |
| `party_balances`（往来余额） | **约 27 ms** | 同上（`idx_party_covering`） |
| `recent_products` | 400 ms 量级 | 商品选择器会慢，可接受 |
| `doc_search` / `list_documents` | 300 ms 量级 | 单据页首屏 |
| `pull_*` / `lines_of_page` | **< 1 ms** | 到几十 ms ⇒ 索引没被用上，把 `--explain` 交回 |

> `--explain` 的输出**一定要留**（已重定向到 `before-explain.txt`）。
> 它能直接回答「索引有没有用上」：例如 `pull_window` 应走 `idx_documents_updated`，
> 显示 `SCAN documents` 就是缺陷。

### 第 ④ 步：人工实测（核心，20–40 分钟）

**开两个窗口**：一个开软件（最大化，别最小化——最小化会停绘制），一个跑记录器：

```bat
python perf_monitor.py run --data-dir "D:\perf-data" --out D:\perf-run1 ^
  --label "新电脑-第1轮" --app-version 0.6.5 ^
  --session-note "CPU/内存/磁盘类型/系统缩放/应用界面大小/杀软" ^
  --spool D:\perf-run1\events.jsonl --probe-interval 60 --interval 5
```

> `--session-note` 里把 §2.2 那四件事写全 —— 少了它，这些数字以后没法用。

按 `c` 打印清单，逐项走。**规则**：

- 每次动作**只测一件事**；
- 同一动作**做 3 次，取最差的一次**记 `e`；
- 冷启动要**真关掉软件**再开（第一次 page cache 是空的，第二次是热的，**两者都要测**）；
- 出问题先按 `m` 记一句（时间点 + 现象），再决定要不要继续。

**观感分值**（跨机器可比的前提，别自创）：

| 分 | 含义 | 参考 |
|---|---|---|
| 1 顺畅 | 点下去立刻有反应 | < 0.3 s |
| 2 一般 | 短暂等待，不影响操作 | 0.3–1 s |
| 3 卡顿 | 明显等一下，能察觉 | 1–3 s |
| 4 明显卡顿 | 等到怀疑没点上 | 3–10 s |
| 5 无响应 | 出现「未响应」/转圈很久 | > 10 s |

结束时按 `q`，自动生成 `report.md` / `samples.csv` / `events.csv` / `session.json`。

### 第 ⑤ 步：收尾（1 分钟）

**关掉软件**，再跑一次基线：

```bat
python perf_bench.py --data-dir "D:\perf-data" --csv after.csv --explain > after-explain.txt
```

---

## 四、本轮**重点看**的三件事（0.6.5 专属，别漏）

### A. v5 覆盖索引有没有退化（**最高优先级**）

`stock_group` / `stock_cost` 从 1336 ms / 648 ms 降到 35 ms / 27 ms 全靠
`idx_stock_covering(product_id, seq_no, quantity, total_cost)` 与 `idx_party_covering`。

- **期望**：新机器上仍是 **30–40 ms** 量级；
- **若回到几百毫秒**：先看 `before-explain.txt` 里那两条是不是**退化成非 covering**；
- **这一条比任何「界面卡不卡」都重要** —— 它一旦退化，库存页和开单页会一起变慢。

### B. 首次启动的自动备份（450 MB 拷贝）

手册 §五 已写明：备份是**同步拷贝整库**，且「距上次超过 24 小时」才再备一次。
库 450 MB 时，**那一天的首启会多拷 450 MB**。

- 今晚请**专门记一次**：造完数后第一次启动软件，从双击到主界面可用**用了多久**；
- 再**关掉重开**一次（24h 内不会再备份）→ 对比两次的差；
- 这个差值就是「备份拷贝」的真实代价。**照实记，不要归因给机器。**

### C. 索引自愈（F19）在新库上的表现

F19（2026-10-26）修的是「镜像重建后丢索引」——桌面库不重建，但**迁移链**会建索引。
今晚只需确认一件事：`before-explain.txt` 里没有任何 `SCAN`（全表扫）出现在
`pull_*` / `lines_of_page` / `stock_*` 这几条上。有的话把那段贴回来。

---

## 五、结果怎么读（沿用手册 §4.3，本轮统一）

| 场景 | 门槛 |
|---|---|
| 人工动作 | **> 2 s 标 ⚠️** |
| 持续高 CPU | 连续 3 个采样点 ≥ 85% |
| 内存 | 首末涨 ≥ 30% 且 > 100 MB |
| 采样缺口 | 间隔 > 2.5 倍（说明整机被压住） |
| 库侧探针 | 与 `before.csv` 比 p95 涨 ≥ 2 倍 |

**「可复现的退化」要同时满足三条**：① 同动作同数据同缩放下比参照机慢 ≥2 倍；
② `samples.csv` 那一刻有客观信号（CPU 打满 / I/O 等待 / gap）；③ 换一次会话还能重现。
**只有第 ① 条的先记「观察」，别急着报缺陷。**

---

## 六、交回给我的四样（**缺一样我就只能看观感**）

| # | 交什么 | 从哪来 |
|---|---|---|
| 1 | `report.md`（每轮一份） | 记录器自动生成 |
| 2 | `samples.csv` / `events.csv` / `session.json` | 同上 |
| 3 | `before.csv` / `after.csv` / `before-explain.txt` / `after-explain.txt` | 第 ③ ⑤ 步 |
| 4 | **一句话总结**：这一轮最卡的一次是哪个动作、当时在做什么、机器什么反应 | 你写 |

**另外请顺手填这张表**（我按它做归因）：

| 动作 | 第1次 | 第2次 | 第3次 | 最差 | 观感(1-5) | 备注 |
|---|---|---|---|---|---|---|
| 冷启动 → 主界面 | | | | | | 第一次含自动备份？ |
| 库存页 | | | | | | |
| 单据列表首屏 | | | | | | |
| 单据搜索（输一个字） | | | | | | |
| 开单 → 选商品 | | | | | | |
| 开单 → 保存 | | | | | | |
| 概览页 | | | | | | |
| 导出 CSV | | | | | | |
| 商品页 / 往来方页 | | | | | | |

---

## 七、时间预算与两条路径

| 路径 | 内容 | 耗时 |
|---|---|---|
| **完整** | 五步全做 + 重点 A/B/C | 60–90 分钟（机械盘造数另加） |
| **精简**（今晚时间紧就走这条） | 只做 ① ② ③ ⑤ + 人工测**四个动作**（冷启动 / 库存页 / 单据列表 / 开单保存） | **25–30 分钟** |

> 精简路径也够回答「10 万行/表还能不能用」—— 四个动作正好覆盖
> 「库最重（库存）」「行数最多（单据列表）」「写路径（保存）」「冷启动（含备份）」。

**手机同步的性能另开一轮**，不在今晚：手机镜像要把 450 MB 拉到手机上、
首次 pull 的分页与重建索引都值得单独量。今晚先不掺进来（会把桌面数字搅浑）。

---

## 八、如果卡住了（先看这几条，别硬试）

| 现象 | 处理 |
|---|---|
| `⛔ 库的 schema 版本是 4` | **就是 §〇 那个坑**：换 v5 快照，别用旧的 |
| `⛔ 这个库里已经有 N 行业务数据` | 脚本在保护你；确认是测试目录后加 `--allow-nonempty`（重造再加 `--confirm-wipe`） |
| `数据库操作失败（库被占用）` | 关掉软件再跑（SQLite 同时只允许一个写者） |
| 造数很慢 | 杀软在扫 → 临时关；机械盘 → 正常 |
| `没找到进程 shensuanzi.exe` | 软件没开或进程名不同；也可 `--pid N`。找不到时进程指标显示 `—`，其余照常 |
| 记录器读不到进程 | 用管理员权限跑命令行 |
| Python 中文乱码 | `chcp 65001`，或 PowerShell 里 `$env:PYTHONIOENCODING='utf-8'` |

---

## 九、English

**Scope.** This is a run sheet for tonight's I-group (performance) session on a new machine — not a
replacement for `docs/perf_test_guide.md`. It fixes the order, the commands (with parameters filled
in), and what counts as pass/fail.

**Blocking fix made today.** The distributed `schema_snapshot.json` was still **v4** while the code is
**v5**. On a test machine (no source), `perf_seed.py` can only read that snapshot, so step ② would have
failed immediately with `⛔ schema 版本是 4`. Regenerated: `v5 / 40 statements / fingerprint
3265deb2dc442c82`, round-trip verified. §〇 gives a 10-second pre-flight check.

**Three things this round specifically looks at** (0.6.5-specific):

1. **v5 covering indexes did not regress** — `stock_group` / `stock_cost` must stay at **30–40 ms**
   (they were 1336 / 648 ms before v5). If they are back to hundreds of ms, that is the single most
   important finding of the night.
2. **First-launch auto-backup** — the backup is a synchronous full copy; with a 450 MB database the
   first launch of the day copies 450 MB. Measure it explicitly (first launch vs second launch).
3. **No `SCAN` in `--explain`** for `pull_*` / `lines_of_page` / `stock_*`.

**Judgement thresholds** follow the manual (§4.3): actions over 2 s are flagged; "reproducible
regression" requires all three of (slower than reference, objective signal in `samples.csv`, repeats).

**Deliverables**: `report.md`, `samples.csv` / `events.csv` / `session.json`,
`before.csv` / `after.csv` / `before-explain.txt` / `after-explain.txt`, plus a one-sentence summary
and the action table in §六.

**Out of scope tonight**: phone-side sync performance (450 MB mirror pull deserves its own round) and
`--stress-docno` (a separate known defect).
