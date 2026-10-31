# 56 · Windows 写盘权限（`host.json` errno 5）—— 诊断与兜底提案

> **本文双语**：每节先中文，紧随 `English` 段。两段内容等价；若有出入，**以中文为准**。
>
> **性质**：诊断提案（**待裁定**，未动实现）。**不占主台账 §编号**，裁定后按常规并入
> `docs/reply_review.md`（对应联调待解决清单 **#1**）。
>
> **起因**：2026-10-31 真机联调，用户第 **三** 次强调：
> 「Windows 版的权限问题依然没得到完全解决，请务必记下。」
> 现状只有**降级**（内存令牌 + 原子写 + 三次重试），**根因仍未定**。
>
> ⚠️ 本文的立场：**「已降级」不等于「已解决」**。降级的代价是用户每次开机都要
> 重新生成配对码 —— 对一个每天开门的个体户，这是每天都在发生的功能损失。

---

## ✅ 裁定结果（2026-10-31，`docs/reply.md`）

| 项 | 裁定 |
|---|---|
| ① 诊断埋点 | **批准**，并补两个字段：**操作前目标是否存在**、**每步的具体结果**（临时创建 / 写入 / flush / rename 分别记） |
| ② L2 原地重写 | **有条件批准**：保留 L1→L2→L3；必须补**故障注入**测试（打开失败 / 截断后写入失败 / 写入中进程退出 / flush 失败 / L2 失败降级）；**不得**把内存恢复旧内容说成完全可靠的回滚；**不得**假设 L2 一定能绕过占用 |
| ③ 验收标准 | **修正**：重启后画不出原二维码是**安全设计**（只存哈希），不是写盘失败。验收改为「`host_id` 稳定 / 已配对手机仍能连 / 不因写盘失败重新生成令牌」 |
| ④ schema v8 | **暂缓**（等诊断与 L2 实测结果） |
| ⑤ ACL / 管理员 / manifest / 迁目录 | **不做** |

> 另有两处措辞被更正（已按裁定改口径）：
> - 「数据库能写 ⇒ 文件权限没问题」**说过头了** —— Windows 的写入 / 删除 / 替换是**三种不同权限**，
>   能写库不能证明能替换文件；只能说「证据更支持**文件替换受阻**」。
> - `ERROR_ACCESS_DENIED(5)` **不是**「被占用」的专属错误：杀软、受控文件夹访问、
>   文件系统过滤驱动都可能给同一个码。

### 落地状态（2026-10-31）

- ✅ ① 诊断埋点：`packages/shensuanzi_host/lib/src/host_write.dart` 的 `HostWriteReport`
  （`stage` / `errno` / `targetExisted` / 每步 `steps` / `retries` / `parentWritable` /
  `attrs` / `integrity` / `restoreOutcome`），失败时经 `onInternalError` 进日志。
- ✅ ② L1→L2→L3 + 故障注入：`host_write_test.dart` **9 条**（见下 §六 的表）。
- ✅ ③ 验收标准已按裁定改写（本文件 §六）。
- ⏸ ④ schema v8 未动。

---

## 零、结论速览

1. **现有证据更支持「文件替换受阻」，而不是「整个目录没权限」。** 证据：同一个进程、同一个目录里，
   `shensuanzi.db` 一整天都在写（WAL、事务、checkpoint），**从不报错**；
   唯独 `host.json` 那条「写临时文件 → `rename` 覆盖」失败。
   ⇒ 但**别把话说死**（裁定原文）：Windows 的「写入 / 删除 / 替换」是三种不同权限，
   能写库**不能**证明能替换文件；只能说 ACL 不是首要嫌疑。
2. 所以根因优先怀疑**两类**：
   ① **别的进程短暂持有 `host.json` 且不允许 delete-share**（杀软实时防护 / 云同步 /
   索引器 / 备份软件）—— Windows 上这种 `rename` 返回的正是 `ERROR_ACCESS_DENIED(5)`，
   **不是** `ERROR_SHARING_VIOLATION(32)`；
   ② **受控文件夹访问 / EDR 对「未受信 exe」的写入拦截**（只拦这一个扩展名或这一个文件名）。
3. 建议分三步走：**先加一次性诊断埋点**（把 errno、失败阶段、文件属性、父目录可写性、
   占用者一次记全）→ **再把写入策略做成三级降级**（rename → 原地重写 → 内存令牌）→
   **最后把身份从「一个文件」里搬出来**（进库，schema v8）。
4. **不建议**：改用户 ACL、要求「以管理员身份运行」、加 UAC manifest —— 三条都会把
   一个文件的小故障升级成「用户不敢双击」的大故障。

### English

The symptom is not "no permission" — it is "cannot rename". Decisive evidence: the same process
writes `shensuanzi.db` all day long in the same directory without a single error, while only the
`host.json` "temp file → rename" step fails. If ACLs were the problem, the database would have
failed long ago. So the prime suspects are (a) another process briefly holding `host.json` without
delete-share (AV real-time scan, cloud sync, indexer, backup tool) — on Windows that makes `rename`
return `ERROR_ACCESS_DENIED(5)`, not `ERROR_SHARING_VIOLATION(32)` — and (b) Controlled Folder
Access / EDR blocking writes from an untrusted exe. Plan: add one-shot diagnostics (errno, failing
step, file attributes, parent-dir writability, open handles), then a three-level write fallback
(rename → in-place rewrite → memory token), then move the identity out of a single file (into the
database, schema v8). Explicitly **not** doing: changing ACLs, requiring "run as administrator", or
adding a UAC manifest.

---

## 一、现场（事实清单）

| 事实 | 证据 / 出处 |
|---|---|
| 失败发生在**写 `host.json`** | `PathAccessException ... errno = 5`（2026-10-31 真机日志） |
| 同一进程、同一目录的**库写入正常** | `shensuanzi.db` 全天读写、自动备份、迁移都在同一目录 |
| 已排除：ACL / SDDL | `icacls` 与 `shensuanzi.db` 逐字节相同的权限串 |
| 已排除：只读属性 / 隐藏 / 系统位 | `attrib` 对比一致 |
| 已排除：完整性标签（MIC） | 与库文件同级 |
| 已排除：文件被本进程占用 | 失败时本进程尚未打开它 |
| 已上线降级 | 原子写（`.tmp` + rename）+ 三次重试（60/120/180 ms）+ 内存令牌 + 界面明说「只对这次运行有效」 |
| 降级后的代价 | **每次开机都要重新生成配对码**（明文不落盘，重启后画不出码） |

> ⚠️ 一个容易被忽略的细节：**`errno 5` 在 `rename` 上的含义与在 `write` 上不同**。
> `write` 报 5 = 真的没权限；`rename`/`MoveFileEx` 报 5 = **目标文件被别的进程打开着、
> 且那个打开没有带 `FILE_SHARE_DELETE`**。当前实现恰好走的是 rename。

### English

The failure is on writing `host.json` (`errno = 5`). The same process writes `shensuanzi.db` in the
same directory all day. Already ruled out: ACLs/SDDL, read-only/hidden/system attributes, integrity
level, and "held by our own process". What is shipped today is a mitigation (atomic write + three
retries + in-memory token + honest UI note); its cost is that the user must regenerate the pairing
code on every boot. Key subtlety: `errno 5` from `rename`/`MoveFileEx` usually means the target is
open by another process without `FILE_SHARE_DELETE` — not that we lack permission.

---

## 二、五个假设与「十分钟判定法」

| # | 假设 | 为什么像 | 十分钟怎么判 |
|---|---|---|---|
| H1 | **杀软 / EDR 实时防护**（360 / 火绒 / Defender）拦住对已存在文件的 rename | 只拦「覆盖已有文件」，放行新文件与库的原地写；对未签名 exe 尤其严格 | 临时关实时防护再点「重新生成配对码」；或用 Process Monitor 过滤 `Path endswith host.json`，看 `Result = ACCESS DENIED` 的 `Process Name` 与 `Desired Access` |
| H2 | **别的进程持着 `host.json`**（云同步 / 索引器 / 备份） | 与 H1 同一症状，区别是「谁开的」 | `handle.exe host.json`（Sysinternals）或 `Restart Manager` 查占用；关掉 OneDrive / 索引服务再试 |
| H3 | **受控文件夹访问（CFA）** | 若数据目录在 `文档/桌面/图片` 下，Defender 会拦未受信应用 | `Get-MpPreference \| Select ControlledFolderAccess*`；或把数据目录换到 `D:\` 再试 |
| H4 | **进程令牌/完整性级别不同**（Explorer 启动 vs 终端启动） | 我们验证时用的是终端里的 dart 进程，App 由 Explorer 起 | 日志里记 `whoami /groups` 的完整性级别 + `GetNamedSecurityInfo` 的有效访问；同一个 exe 从终端启动对比 |
| H5 | **路径/名字层面**（超长路径、`host.json ` 尾随空格、`\\?\` 前缀缺失） | 廉价排除 | 日志里打完整路径的**字符数与码点**；`dir /x` 看短名 |

> 判定顺序建议 **H1 → H2 → H3**：三者覆盖了「同一用户、同一文件、别的进程能写」的
> 绝大多数真实现场，而且都不需要改代码就能验证。

### English

Five hypotheses with a ten-minute test each: H1 AV/EDR intercepting rename-over-existing (disable
real-time protection, or Process Monitor filtered on `host.json`); H2 another process holding the
file without delete-share (`handle.exe`, Restart Manager, stop OneDrive/indexer); H3 Controlled
Folder Access (`Get-MpPreference`, or move the data directory off `Documents/Desktop`); H4 differing
process token/integrity (log `whoami /groups` and effective access); H5 path-level oddities (length,
trailing space, missing `\\?\`). Test order H1 → H2 → H3 covers most real-world cases without code
changes.

---

## 三、建议的诊断埋点（一次失败就把现场记全）

现在失败时只留一个布尔值 + 一句原文。建议在 `HostIdentityStore._write` 的 catch 里记**一条**
结构化日志（只进日志文件，不进界面）：

| 字段 | 取法 | 为什么需要 |
|---|---|---|
| `stage` | `write-temp` / `rename` / `create-parent` | **最关键**：区分「没权限写」与「改不了名」 |
| `errno` | `PathAccessException.osError?.errorCode` | 5 / 32 / 183 指向完全不同的原因 |
| `target` / `temp` | 完整路径 + 长度 | 排除超长路径 |
| `attrs` | `GetFileAttributes`：R/H/S/A/E(加密)/C(压缩)/P(重解析点) | 一次性排除属性类 |
| `parentWritable` | 在父目录写一个探针文件再删 | 区分「目录不可写」与「文件不可改」 |
| `otherHandle` | `MoveFileEx` 失败后立刻再试一次 rename，记录两次间隔与结果 | 若是 H1/H2，重试有概率成功 —— 间隔本身就是证据 |
| `integrity` | `whoami /groups` 里的 `Mandatory Label` | H4 |
| `cfa` | `Get-MpPreference` 的 `ControlledFolderAccess*`（可选，需 PowerShell） | H3 |

日志长这样（一行，便于 grep）：

```text
host.json 写失败诊断：stage=rename errno=5 target=...\host.json(61) attrs=A parentWritable=true
retry=3/3 lastErr=PathAccessException ... integrity=Medium cfa=unknown
```

> 这一条日志的价值：**下次真机复现时，不需要再问用户任何问题**。
> 现在的问题是「复现了也拿不到信息」，等于每次都从零查。

### English

Today a failure leaves only a boolean and a raw message. Proposed: one structured log line from the
`catch` in `HostIdentityStore._write`, carrying `stage` (write-temp / rename / create-parent — the
single most useful field), `errno`, full target/temp paths with lengths, file attributes
(R/H/S/A/E/C/P), whether the parent directory is writable (probe file), the retry timing, process
integrity level, and (optionally) Controlled Folder Access state. One greppable line means the next
reproduction needs no follow-up questions.

---

## 四、写入策略的三级降级（不需要等根因）

| 级别 | 做法 | 代价 | 现状 |
|---|---|---|---|
| L1 | `.tmp` 写 + `rename` 覆盖（**原子**，首选） | 需要 delete 权限 | ✅ 已实现 |
| L2 | **原地重写**：先把旧内容读进内存 → `open(mode: write)` 截断写 → 失败则用内存里的旧内容写回 | 有极小的「截断后没写成」窗口；用「旧内容在内存里」兜住 | ⬜ 建议加 |
| L3 | **内存令牌**：本次能配对，重启后失效 | 用户每次开机重新生成码 | ✅ 已实现（兜底） |

L2 的意义：**如果根因是 H1/H2（rename 被拦），L2 直接绕过** —— 因为原地写只需要
`FILE_WRITE_DATA`，不需要 delete。风险可控：文件只有几十字节，写失败时用内存里的旧内容回写，
最坏情况是「文件内容与内存不一致」→ 下次启动读文件，读不到新令牌 ⇒ 与今天的 L3 同结果。

建议顺序：**L1 →（失败）L2 →（失败）L3**，并把「降到了哪一级」记进日志与界面文案
（界面只在降到 L3 时才说「只对这次运行有效」）。

### English

Three-level write fallback: L1 atomic temp+rename (shipped), L2 in-place rewrite (read old bytes
into memory, truncate-write, restore from memory on failure), L3 in-memory token (shipped). L2
matters because if the root cause is H1/H2 (rename blocked), an in-place write only needs
`FILE_WRITE_DATA`, no delete. Worst case for L2 equals today's L3 outcome, so it is a cheap bet.
Record which level was reached in the log, and only tell the user "valid for this run only" when L3
is hit.

---

## 五、长期：把身份从「一个文件」里搬出来

`host.json` 里只有 `host_id` + `token_hash` + `created_at`（几十字节）。它住在数据目录里，
**和库同一个目录**。而库天天写、从不失败 ⇒ 把身份写进库，等于把「一个可能被拦的文件」
换成「一个已经证明能写的文件」。

草案（**schema v8**，需裁定）：

```sql
CREATE TABLE host_identity (
  k TEXT PRIMARY KEY,      -- 'host_id' / 'token_hash' / 'created_at'
  v TEXT NOT NULL
);
```

- **读取顺序**：库 → `host.json`（老用户升级上来时库里没有，得先认文件）；
- **写入**：先写库（事务），再尽力写 `host.json`（保持「拷走数据目录就能带走身份」的可用性）；
- **迁移风险**：动 schema 要走迁移链（`Schema.version` 8 + `migrationStep(7)`），
  且**镜像侧不需要这张表**（手机不是主机）。成本不小，所以放在 L1/L2 与诊断之后。

> 用户提过一条同类思路（`docs/reply.md` §四 末）：`sync_queue` 长期应与可重建的镜像业务表
> **物理分库**。两条是同一个道理：**不可重建的数据，不该和「可能被拦/可能坏」的东西共命运。**

### English

`host.json` holds only `host_id`, `token_hash`, `created_at` — tens of bytes — in the same directory
as a database the app writes all day without failure. Moving the identity into the database replaces
"a file that may be blocked" with "a file already proven writable". Draft: schema v8 with a
`host_identity(k, v)` table; read order DB → file (so upgrades work); write DB first, then best-effort
file (keeps "copy the data folder and take the identity with you"). It touches the migration chain,
so it comes after diagnostics and L2.

---

## 六、施工顺序与验收判据

| 步 | 内容 | 验收判据 |
|---|---|---|
| 1 | 诊断埋点（§三） | 人为制造一次失败（把 `host.json` 用别的进程以 deny-delete 打开），日志里 `stage=rename errno=5` 齐全 |
| 2 | L2 原地重写（§四） | 同上场景下，**配对码能落盘**、重启后仍能画码 |
| 3 | 真机复现与定性（§二 H1/H2/H3） | 至少确定一个根因；若确认为 H1/H2，记录「哪个软件、什么条件下」 |
| 4 | （视裁定）schema v8（§五） | 迁移链 v7→v8 有测试；老用户 `host.json` 仍能读 |

**总验收（2026-10-31 按裁定改写）**：

1. 连续两次重启，**`host_id` 保持不变**；
2. **已经配对的手机仍能用原令牌正常连接**；
3. **不需要因为写盘失败而重新生成令牌**；
4. 需要给新手机展示二维码时，仍按现有安全设计**明确执行一次令牌重置**。

> ⚠️ 原稿写的「重启后不点重新生成也能画出同一个二维码」**做不到也不该做**：
> `host.json` 只存 `token_hash`，明文不落盘（`HostIdentity.load()` 的 `plaintextToken`
> 恒为 `null`）—— 这是**安全设计**，不是写盘失败的后果。若真要「重启后直接显示原码」，
> 需另立**令牌明文安全持久化**提案（如 Windows DPAPI），不在本文范围。

### English

Order: (1) diagnostics — verify by holding `host.json` open with deny-delete and checking the log
line; (2) L2 in-place rewrite — same scenario must now persist the token across restart; (3) real
device root-cause narrowing (H1/H2/H3); (4) optional schema v8 behind a ruling. Overall acceptance:
restart twice, the same QR code appears without regenerating, and the log carries no unexplained
`host.json` write failure.

---

## 七、不做的事（以及为什么）

| 不做 | 为什么 |
|---|---|
| 改用户数据目录的 ACL | 动了用户系统设置，出问题我们背；且已被证据否定（库能写） |
| 要求「以管理员身份运行」 | 中老年用户看到 UAC 会直接放弃；也解释不了「同一个用户、库能写」 |
| 加 UAC manifest（`requireAdministrator`） | 同上，且会让「双击启动」失效 |
| 把 `host.json` 换到 `%APPDATA%` 就完事 | 身份属于**数据目录**（换电脑/换目录应当换身份），搬走会破坏「拷走目录即带走身份」 |

### English

Not doing: changing ACLs on the user's data directory (we would own the consequences, and evidence
already rules it out), requiring "run as administrator" or a `requireAdministrator` manifest (elderly
users abandon at UAC; also does not explain "same user, DB writable"), or simply relocating
`host.json` to `%APPDATA%` (identity belongs to the data directory; moving it breaks "copy the folder,
take the identity").
