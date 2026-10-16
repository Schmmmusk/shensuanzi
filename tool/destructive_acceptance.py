#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`docs/desktop_acceptance.md` 第九节（异常与破坏性）的**现场准备 + 自动验库 + 人工清单**。

    python tool/destructive_acceptance.py --help

## 这个脚本**不做**什么（先看这一节，比看它能做什么更重要）

`docs/desktop_acceptance.md` 第九节开头写着「**这一节只能在真机上做**」。所以：

| ❌ 脚本绝不做的 | 为什么 |
|---|---|
| **常规流程启动 / 结束应用** | prepare / verify 不操作软件进程；9.1 的 `watch-write` 只用隔离配置启动指定程序，并只结束它自己启动的 PID |
| **改系统时间**（9.4） | 影响整机（日历 / 定时任务 / 别的程序），且需要管理员权限。脚本只做「伪造时间线」的策略验证 |
| **改目录 ACL / 权限**（9.2） | 万一恢复失败，那个目录会一直写不进去。脚本只**检测**只读现场是否摆好、事后报告结果 |
| **改、删任何业务数据** | 只往主数据表（`products` / `parties` / `accounts`）**新增**带哨兵前缀的测试行；不改不删 |

它做的三件事：

1. **造现场**：写哨兵数据、伪造备份文件；9.1 使用独立的应用写入监听流程；
2. **自动验库**：所有能靠**读 .db 文件**回答的判据，脚本直接给结论
   （完整性、数据还在不在、备份产物几份、超长串有没有被截断 …）；
3. **出人工清单**：判据落在**界面**上的部分，写成可照做的步骤 ——
   并且每条都写清「该看到什么」。

⚠️ **「待人工」不是「通过」**。报告里三态分开计数（通过 / 不通过 / 待人工），
别把「待人工」当成过了。

## 三个阶段（这是它和上一版最大的不同）

破坏性验收天然是「**摆现场 → 人去捣乱 → 回来验尸**」，所以脚本拆成三段：

    # ① 摆现场（写哨兵 / 造假备份 / 打印该做的动作）
    python tool/destructive_acceptance.py --phase prepare --data-dir D:\测试数据 --confirm-test-data

    # ② 人去做：拔电 / 改时间 / 连点备份 / 粘超长串 …

    # ③ 验尸（读库给结论 + 出报告）
    python tool/destructive_acceptance.py --phase verify --data-dir D:\测试数据

    # 图省事：一把过（prepare + verify 之间不给人留时间，只适合纯库层的几条）
    python tool/destructive_acceptance.py --phase all --data-dir D:\测试数据 --confirm-test-data

**为什么拆三段**：不拆的话，脚本必须在「人捣乱」和「脚本验尸」之间同步 ——
而上一次我正是在这里翻的车（脚本自作主张启停了软件）。

## 安全阀

- **开工前检查没有神算子进程**。检测到就**拒绝运行**并让你先关掉 ——
  因为「改数据目录名字」这类现场，必须在一个**没有被任何实例打开**的目录上做
  （有一个实例开着时改目录名，会绕过它的单实例锁，见 `docs/desktop_acceptance.md` 第九节 9.3 的说明）。
- **只动 `--data-dir` 与它的兄弟备份目录**，且只动脚本自己造的东西
  （哨兵行以 `S9验收哨兵` 开头、伪造备份名叫 `shensuanzi-schema3-*` / `shensuanzi-m-*`）。
- 9.1 的 `watch-write` 只启动系统临时目录中的测试账套；观察到数据库文件变动后，
  只强杀自己启动的应用 PID。不会按进程名结束既有实例。

## 依赖

Python 3.8+，**只用标准库**。不需要软件在跑，不需要 Dart / Flutter / 网络。
"""

from __future__ import annotations

import argparse
import ctypes
import glob
import json
import os
import random
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

import seed_test_data

# ------------------------------------------------------------------ 常量

DATA_FILE = "shensuanzi.db"
MARKER_FILE = ".shensuanzi-data"
INSTANCE_LOCK = ".shensuanzi.lock"
RUN_MANIFEST = ".s9-acceptance-run.json"
BACKUP_FOLDER = "神算子备份"

SENTINEL_PREFIX = "S9验收哨兵"

PASS = "PASS"
FAIL = "FAIL"
HUMAN = "HUMAN"
STATUS_LABEL = {PASS: "通过", FAIL: "不通过", HUMAN: "待人工"}

#: 备份文件名的唯一权威格式（`packages/shensuanzi_app/lib/src/backup.dart`）
BACKUP_NAME_RE = re.compile(r"^shensuanzi(-m)?-schema(\d+)-(\d{8})-(\d{4})\.db$")

IS_WINDOWS = os.name == "nt"

#: 9.6 超长输入的档位（字符数 → 说明）
LONG_INPUTS: Tuple[Tuple[str, int], ...] = (
    ("1K", 1_024),
    ("10K", 10_240),
    ("64K", 65_536),
    ("1M", 1_048_576),
)

#: 9.7 非法 / 边界字符 —— 每一档对应一种真实的翻车方式
NASTY_STRINGS: Tuple[Tuple[str, str], ...] = (
    ("单引号", "O'Brien 五金"),
    ("双引号", '他说"要退货"'),
    ("反斜杠", r"C:\temp\a\b"),
    ("emoji", "牛奶🥛🍎🏪"),
    ("全角空格", "甲　乙　丙"),
    ("零宽", "商\u200b品"),
    ("双向控制", "\u202eabc\u202c"),
    ("换行", "第一行\n第二行"),
    ("制表", "甲\t乙"),
    ("SQL", "' OR '1'='1"),
    ("百分号", "100% 纯棉"),
    ("下划线", "a_b%c"),
    ("unicode", "𠮷野家 · naïve · Ω"),
    ("组合字符", "e\u0301 与 é"),
)


# ------------------------------------------------------------------ 小工具


def now_ms() -> int:
    return int(time.time() * 1000)


def script_directory() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)


def app_processes() -> List[Tuple[int, str]]:
    """正在运行的神算子进程 `[(pid, 路径)]`。查不到就返回空（**不猜**）。"""
    if not IS_WINDOWS:
        code, out = _run(["pgrep", "-af", "shensuanzi"])
        if code != 0 or not out.strip():
            return []
        found: List[Tuple[int, str]] = []
        for line in out.splitlines():
            parts = line.split(None, 1)
            if parts and parts[0].isdigit():
                found.append((int(parts[0]), parts[1] if len(parts) > 1 else ""))
        return found
    code, out = _run(
        [
            "powershell",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "Get-Process shensuanzi -ErrorAction SilentlyContinue | "
            "ForEach-Object { \"$($_.Id)|$($_.Path)\" }",
        ]
    )
    if code != 0 or not out.strip():
        return []
    found = []
    for line in out.splitlines():
        line = line.strip()
        if "|" not in line:
            continue
        pid, _, path = line.partition("|")
        if pid.strip().isdigit():
            found.append((int(pid), path.strip()))
    return found


def _run(cmd: Sequence[str], timeout: int = 30) -> Tuple[int, str]:
    """跑一条外部命令。**从不抛** —— 环境缺命令是常态，不该炸掉验收。"""
    try:
        proc = subprocess.run(list(cmd), capture_output=True, timeout=timeout, check=False)
        out = (proc.stdout or b"").decode("utf-8", "replace")
        err = (proc.stderr or b"").decode("utf-8", "replace")
        return proc.returncode, (out + err).strip()
    except FileNotFoundError:
        return 127, "找不到命令：%s" % cmd[0]
    except Exception as exc:
        return 1, "命令执行失败：%s" % exc


def read_only_connect(path: str) -> sqlite3.Connection:
    """**只读**打开一个库 —— 不迁移、不 checkpoint、不改它一个字节。

    ⚠️ 为什么必须只读：验收的「验尸」步骤如果顺手改了现场，
    那验的就不是软件的恢复能力，而是脚本自己的写入能力。
    """
    uri = "file:%s?mode=ro" % (
        path.replace("\\", "/").replace("?", "%3f").replace("#", "%23")
    )
    return sqlite3.connect(uri, uri=True, timeout=15)


def can_write_dir(path: str) -> bool:
    """真的写一个探针文件再删 —— 与 `fs.dart` 的 `ensureWritableDirectory` 同法。

    只看 `os.access` 不够：Windows 的 ACL 与只读属性都可能在 `access()` 说
    「能写」之后让 `open()` 失败。
    """
    probe = os.path.join(path, ".s9probe-%d" % random.randrange(10**9))
    try:
        os.makedirs(path, exist_ok=True)
        with open(probe, "w", encoding="utf-8") as fh:
            fh.write("probe")
        return True
    except Exception:
        return False
    finally:
        try:
            if os.path.exists(probe):
                os.remove(probe)
        except Exception:
            pass


def backup_directory_for(data_dir: str) -> str:
    """`DataDirectoryPolicy.backupDirectoryFor` 的等价物（数据目录的**兄弟**目录）。

    若数据目录自己就叫「神算子备份」，让位成「神算子备份-1」——
    否则会把数据搬进自己的备份里。
    """
    resolved = os.path.abspath(data_dir.rstrip("\\/"))
    parent = os.path.dirname(resolved)
    name = os.path.basename(resolved)
    if not parent:
        parent = os.path.abspath(os.sep)
    candidate = os.path.join(parent, BACKUP_FOLDER)
    if os.path.normcase(candidate) == os.path.normcase(resolved) or name == BACKUP_FOLDER:
        candidate = os.path.join(parent, BACKUP_FOLDER + "-1")
    return candidate


# ------------------------------------------------------- 备份规则复刻（带自检）
#
# ⚠️ 这里复刻的是**判据**，不是实现。Dart 侧的 `BackupFileName` /
# `expiredAutoBackups` / `shouldAutoBackup` 是**纯函数**，脚本要能在
# 不启动软件的前提下验「保留策略 / 文件名 / 时钟回跳判定」，只能复刻。
# 复刻的代价是可能漂移 ⇒ 所以 [compare_with_dart] 把它钉在 Dart 的
# **期望值**上（那些期望值直接抄自 `packages/shensuanzi_app/test/backup_test.dart`），
# 且每次运行都跑 —— 漂移会立刻现形，而不是等某个用例诡异地通过。


@dataclass(frozen=True)
class BackupName:
    manual: bool
    schema_version: int
    time: datetime
    file_name: str

    @staticmethod
    def build(manual: bool, schema_version: int, when: datetime) -> "BackupName":
        return BackupName(
            manual,
            schema_version,
            when,
            "shensuanzi%s-schema%d-%s-%s.db"
            % ("-m" if manual else "", schema_version, when.strftime("%Y%m%d"), when.strftime("%H%M")),
        )

    @staticmethod
    def parse(file_name: str) -> Optional["BackupName"]:
        m = BACKUP_NAME_RE.match(file_name)
        if not m:
            return None
        date, clock = m.group(3), m.group(4)
        when = datetime(
            int(date[0:4]), int(date[4:6]), int(date[6:8]),
            int(clock[0:2]), int(clock[2:4]),
        )
        return BackupName(m.group(1) is not None, int(m.group(2)), when, file_name)


def week_key(when: datetime) -> str:
    """自然周（**周一锚**）的键 —— 与 `weekKeyOf` 同构。"""
    monday = when - timedelta(days=when.weekday())
    return "%d-%d-%d" % (monday.year, monday.month, monday.day)


def expired_auto_backups(names: Iterable[BackupName], now: datetime) -> List[BackupName]:
    """30 天前的自动包；**每个自然周最早的一份豁免**；手动包永不清理。"""
    cutoff = now - timedelta(days=30)
    candidates = [n for n in names if not n.manual and n.time < cutoff]
    earliest: Dict[str, BackupName] = {}
    for n in candidates:
        key = week_key(n.time)
        cur = earliest.get(key)
        if cur is None or n.time < cur.time:
            earliest[key] = n
    return [n for n in candidates if earliest.get(week_key(n.time)) is not n]


def should_auto_backup(now: datetime, last: Optional[datetime]) -> bool:
    """首次 / **时钟回跳**（now < last）⇒ 备份一次重新锚定；否则 > 24h 才备份。"""
    if last is None:
        return True
    if now < last:
        return True
    return (now - last) > timedelta(hours=24)


def compare_with_dart() -> List[str]:
    """把上面的复刻钉在 Dart 侧行为上。返回不一致清单（空 = 一致）。"""
    problems: List[str] = []

    def n(y: int, mo: int, d: int, hh: int, mi: int, manual: bool = False) -> BackupName:
        return BackupName.build(manual, 3, datetime(y, mo, d, hh, mi))

    auto = n(2026, 9, 28, 15, 30)
    if auto.file_name != "shensuanzi-schema3-20260928-1530.db":
        problems.append("自动备份文件名不符：%s" % auto.file_name)
    manual = n(2026, 9, 28, 15, 30, manual=True)
    if manual.file_name != "shensuanzi-m-schema3-20260928-1530.db":
        problems.append("手动备份文件名不符：%s" % manual.file_name)
    for parsed in (auto, manual):
        again = BackupName.parse(parsed.file_name)
        if again is None or (again.manual, again.time) != (parsed.manual, parsed.time):
            problems.append("文件名解析往返失败：%s" % parsed.file_name)
    for bad in ("shensuanzi.db", "shensuanzi-schema3-20260928.db", "x.db", ""):
        if BackupName.parse(bad) is not None:
            problems.append("不该被当成备份的文件名：%r" % bad)

    # 保留策略：now = 9/24 ⇒ 30 天前 = 8/25。
    # 8/3 与 8/5 同周 ⇒ 8/5 删、8/3（代表）留；8/10 在 30 天内 ⇒ 留；手动包 ⇒ 永不删。
    now = datetime(2026, 9, 24, 9, 0)
    names = [
        n(2026, 8, 3, 9, 0),
        n(2026, 8, 5, 9, 0),
        n(2026, 8, 10, 9, 0),
        n(2026, 7, 1, 9, 0, True),
    ]
    expired = {e.file_name for e in expired_auto_backups(names, now)}
    want = {n(2026, 8, 5, 9, 0).file_name}
    if expired != want:
        problems.append("保留策略与 Dart 期望不符：删了 %s，应为 %s" % (sorted(expired), sorted(want)))
    if expired_auto_backups([n(2026, 8, 25, 9, 0)], now):
        problems.append("恰好 30 天的备份被判成过期（应为严格小于）")

    if not should_auto_backup(now, None):
        problems.append("首次没有备份时应当自动备份")
    if not should_auto_backup(now, now + timedelta(days=1)):
        problems.append("时钟回跳（上次备份在未来）时应当备份一次重新锚定")
    if should_auto_backup(now, now - timedelta(hours=5)):
        problems.append("距上次 5 小时不该自动备份")
    if not should_auto_backup(now, now - timedelta(hours=25)):
        problems.append("距上次 25 小时应当自动备份")
    return problems


# ---------------------------------------------------------------- 结果与报告


@dataclass
class Case:
    key: str
    title: str
    criterion: str
    status: str = HUMAN
    evidence: List[str] = field(default_factory=list)
    human_steps: List[str] = field(default_factory=list)
    problems: List[str] = field(default_factory=list)

    def ok(self, text: str) -> None:
        self.evidence.append("[自动] %s" % text)

    def note(self, text: str) -> None:
        self.evidence.append("[线索] %s" % text)

    def fail(self, text: str) -> None:
        self.status = FAIL
        self.problems.append(text)

    def need_human(self, *steps: str) -> None:
        if self.status != FAIL:
            self.status = HUMAN
        self.human_steps.extend(steps)

    def resolve(self) -> None:
        if self.status != FAIL and not self.human_steps:
            self.status = PASS


class Report:
    def __init__(self, ctx: "Context") -> None:
        self.ctx = ctx
        self.cases: List[Case] = []
        self.started = datetime.now()
        self.notes: List[str] = []
        self.phase = ctx.phase

    def add(self, case: Case) -> Case:
        self.cases.append(case)
        return case

    def counts(self) -> Dict[str, int]:
        out = {PASS: 0, FAIL: 0, HUMAN: 0}
        for c in self.cases:
            out[c.status] += 1
        return out

    def to_markdown(self) -> str:
        c = self.counts()
        lines: List[str] = []
        lines.append("# 桌面版验收 · 第九节（异常与破坏性）报告")
        lines.append("")
        lines.append("> 由 `tool/destructive_acceptance.py` 生成。判据出处：`docs/desktop_acceptance.md` 第九节。")
        lines.append("> 除 `watch-write` 外，本脚本不启动或结束神算子；该模式只结束本脚本亲自启动的隔离实例。脚本不改 ACL / 系统时间。")
        lines.append("")
        lines.append("| 项 | 值 |")
        lines.append("|---|---|")
        lines.append("| 生成时间 | %s |" % self.started.strftime("%Y-%m-%d %H:%M:%S"))
        lines.append("| 阶段 | %s |" % {"prepare": "**prepare**（摆现场）", "verify": "**verify**（只读验尸）", "all": "all（自动准备 + 核验）", "watch-write": "**watch-write**（9.1 应用强杀）"}.get(self.phase, self.phase))
        lines.append("| 机器 | %s（%s） |" % (os.environ.get("COMPUTERNAME", "?"), sys.platform))
        lines.append("| 数据目录 | `%s` |" % self.ctx.data_dir)
        lines.append("| 备份目录 | `%s` |" % self.ctx.backup_dir)
        lines.append("| 数据库 | `%s` |" % self.ctx.db_path)
        lines.append("| 软件版本 | %s |" % self.ctx.app_version())
        lines.append("")
        lines.append("## 汇总（本阶段）")
        lines.append("")
        lines.append("| 状态 | 条数 |")
        lines.append("|---|---|")
        lines.append("| ✅ 通过（自动断言已过） | %d |" % c[PASS])
        lines.append("| ❌ 不通过 | %d |" % c[FAIL])
        lines.append("| 🙋 待人工 | %d |" % c[HUMAN])
        lines.append("")
        # ⚠️ 一条用例**既**有自动断言**又**有人工步骤时，只报「待人工」——
        # 否则汇总里会出现「9.3 通过 1 · 9.3 待人工 1」这种自相矛盾的计数
        # （第一次生成报告就这么印了）。「待人工」才是它此刻的真实状态：
        # 自动部分过了，但整条还没做完。
        if c[HUMAN]:
            lines.append(
                "> ⚠️「通过」只表示**该条的自动断言**过了；带「待人工」的条目意味着"
                "**整条还没做完**（还有步骤要人看）。一条用例若既自动通过又需人工，"
                "只计入「待人工」。"
            )
            lines.append("")
        if self.phase == "prepare":
            lines.append("> ⚠️ 这是 **prepare** 阶段：只摆了现场。真正的结论请看 **verify** 阶段的报告。")
            lines.append("")
        if self.notes:
            lines.append("## 环境说明")
            lines.append("")
            for note in self.notes:
                lines.append("- %s" % note)
            lines.append("")
        for case in self.cases:
            lines.append("---")
            lines.append("")
            lines.append("## %s %s —— %s" % (case.key, case.title, STATUS_LABEL[case.status]))
            lines.append("")
            lines.append("**判据（原文）**：%s" % case.criterion)
            lines.append("")
            if case.evidence:
                lines.append("**脚本看到的**：")
                lines.append("")
                for e in case.evidence:
                    lines.append("- %s" % e)
                lines.append("")
            if case.problems:
                lines.append("**不通过的地方**：")
                lines.append("")
                for p in case.problems:
                    lines.append("- ❌ %s" % p)
                lines.append("")
            if case.human_steps:
                lines.append("**待人工（照着做，把结果填回本节）**：")
                lines.append("")
                for i, s in enumerate(case.human_steps, 1):
                    lines.append("%d. %s" % (i, s))
                lines.append("")
            if case.status == PASS:
                lines.append("> 自动断言已全部通过，**不需要人工复核**。")
                lines.append("")
        lines.append("---")
        lines.append("")
        lines.append("## 填回验收方案（第十二节回报格式）")
        lines.append("")
        lines.append("```")
        lines.append("九、异常与破坏性：%s" % self.verdict_line())
        lines.append("```")
        lines.append("")
        return "\n".join(lines)

    def verdict_line(self) -> str:
        failed = [c.key for c in self.cases if c.status == FAIL]
        human = [c.key for c in self.cases if c.status == HUMAN]
        return "不通过：%s；待人工：%s" % (
            "、".join(failed) if failed else "无",
            "、".join(human) if human else "无",
        )

    def print_console(self) -> None:
        print("")
        print("=" * 74)
        for case in self.cases:
            mark = {PASS: "✅", FAIL: "❌", HUMAN: "🙋"}[case.status]
            print("%s %s %s —— %s" % (mark, case.key, case.title, STATUS_LABEL[case.status]))
            for e in case.evidence:
                print("      %s" % e)
            for p in case.problems:
                print("      ❌ %s" % p)
            for s in case.human_steps:
                print("      🙋 %s" % s)
        print("=" * 74)
        c = self.counts()
        print("通过 %d · 不通过 %d · 待人工 %d" % (c[PASS], c[FAIL], c[HUMAN]))


# ------------------------------------------------------------------- 上下文


class Context:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.phase = args.phase
        self.data_dir = os.path.abspath(args.data_dir)
        self.db_path = os.path.join(self.data_dir, DATA_FILE)
        self.backup_dir = os.path.abspath(args.backup_dir or backup_directory_for(self.data_dir))
        self.report_path = os.path.abspath(args.report)
        self.run_id = args.run_id or ("%d" % time.time_ns())
        self._stray_processes: List[Tuple[int, str]] = []

    # ------------------------------------------------------------ 环境事实
    def app_version(self) -> str:
        """从启动日志里读软件版本（读不到就写「未知」—— **不猜**）。"""
        log = os.path.join(os.environ.get("APPDATA", ""), "神算子", "日志", "神算子-日志.txt")
        try:
            if os.path.exists(log):
                with open(log, "r", encoding="utf-8", errors="replace") as fh:
                    tail = fh.readlines()[-40:]
                for line in reversed(tail):
                    if "启动 神算子" in line:
                        m = re.search(r"神算子\s+v?(\S+)\s*·\s*schema\s+v?(\d+)", line)
                        if m:
                            return "v%s（schema v%s）" % (m.group(1), m.group(2))
                        return line.strip()
        except Exception:
            pass
        return "未知（没找到启动日志）"

    def db_schema_version(self) -> Optional[int]:
        try:
            conn = read_only_connect(self.db_path)
        except Exception:
            return None
        try:
            return int(conn.execute("PRAGMA user_version").fetchone()[0])
        except Exception:
            return None
        finally:
            conn.close()

    def app_running(self) -> List[Tuple[int, str]]:
        return app_processes()

    # ------------------------------------------------------------ 数据操作
    def sentinel_count(self) -> int:
        """库里还剩几条哨兵（-1 = 读不到）。"""
        try:
            conn = read_only_connect(self.db_path)
        except Exception:
            return -1
        try:
            total = 0
            for table in ("products", "parties", "accounts"):
                try:
                    total += conn.execute(
                        "SELECT COUNT(*) FROM %s WHERE name LIKE ?" % table,
                        (SENTINEL_PREFIX + "%",),
                    ).fetchone()[0]
                except sqlite3.Error:
                    return -1
            return total
        except Exception:
            return -1
        finally:
            conn.close()

    def db_tables(self) -> List[str]:
        try:
            conn = read_only_connect(self.db_path)
        except Exception:
            return []
        try:
            return [
                r[0]
                for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table' "
                    "AND name NOT LIKE 'sqlite_%' ORDER BY rowid"
                )
            ]
        except Exception:
            return []
        finally:
            conn.close()

    def integrity(self, path: Optional[str] = None) -> Tuple[bool, str]:
        target = path or self.db_path
        if not os.path.exists(target):
            return False, "文件不存在"
        try:
            conn = read_only_connect(target)
        except Exception as exc:
            return False, "打不开：%s" % exc
        try:
            verdict = str(conn.execute("PRAGMA integrity_check").fetchone()[0])
            return verdict == "ok", verdict
        except Exception as exc:
            return False, "校验失败：%s" % exc
        finally:
            conn.close()

    def fk_check(self) -> Optional[List[Any]]:
        try:
            conn = read_only_connect(self.db_path)
        except Exception:
            return None
        try:
            return conn.execute("PRAGMA foreign_key_check").fetchall()
        except Exception:
            return None
        finally:
            conn.close()

    def wal_state(self) -> Dict[str, Any]:
        """WAL 现场：三个伴随文件的大小 + 软件的自动 checkpoint 阈值。"""
        out: Dict[str, Any] = {
            "db": os.path.getsize(self.db_path) if os.path.exists(self.db_path) else None,
            "wal": os.path.getsize(self.db_path + "-wal") if os.path.exists(self.db_path + "-wal") else None,
            "shm": os.path.getsize(self.db_path + "-shm") if os.path.exists(self.db_path + "-shm") else None,
            "autocheckpoint": None,
            "page_size": None,
        }
        try:
            conn = read_only_connect(self.db_path)
            try:
                out["autocheckpoint"] = conn.execute("PRAGMA wal_autocheckpoint").fetchone()[0]
                out["page_size"] = conn.execute("PRAGMA page_size").fetchone()[0]
            finally:
                conn.close()
        except Exception:
            pass
        return out


# ------------------------------------------------------------------ 造现场


def seed_sentinel(ctx: Context, count: int = 12) -> Tuple[bool, str]:
    """写哨兵数据（只写三张主数据表，只新增）。

    ⚠️ 表不存在时**直接失败**，不再往下走 —— 上一版就是在「库是空的、没有
    products 表」的情况下继续跑完 6 条，既没验到东西又白开了一堆窗口。
    """
    if not os.path.exists(ctx.db_path):
        return False, "库不存在：%s（先让软件在这个位置打开一次）" % ctx.db_path
    tables = ctx.db_tables()
    if "products" not in tables:
        return False, (
            "库里没有 products 表（现有表：%s）—— 这不是一个可用的神算子库，"
            "请先让软件在这个位置正常打开一次" % (tables or "无")
        )
    try:
        conn = sqlite3.connect(ctx.db_path, timeout=15)
    except Exception as exc:
        return False, "打不开库：%s" % exc
    try:
        conn.execute("PRAGMA foreign_keys = ON")
        ts = now_ms()
        start = conn.execute(
            "SELECT code FROM products WHERE code LIKE 'P%' "
            "ORDER BY LENGTH(code) DESC, code DESC LIMIT 1"
        ).fetchone()
        seq = 1
        if start and re.match(r"^P(\d+)$", start[0] or ""):
            seq = int(re.match(r"^P(\d+)$", start[0]).group(1)) + 1
        conn.execute("BEGIN")
        for i in range(count):
            conn.execute(
                "INSERT INTO products (id, code, name, unit, cost_price, sell_price, "
                "safety_stock, is_active, created_at, updated_at, sync_version) "
                "VALUES (?,?,?,?,?,?,?,?,?,?,0)",
                (
                    "s9-%s-p%d" % (ctx.run_id, i),
                    "P%04d" % (seq + i),
                    "%s-商品%d" % (SENTINEL_PREFIX, i),
                    "件",
                    100 + i,
                    200 + i,
                    0,
                    1,
                    ts,
                    ts,
                ),
            )
        for i in range(count):
            conn.execute(
                "INSERT INTO parties (id, name, phone, roles, credit_limit, is_active, "
                "created_at, updated_at, sync_version) VALUES (?,?,?,?,?,?,?,?,0)",
                (
                    "s9-%s-q%d" % (ctx.run_id, i),
                    "%s-往来方%d" % (SENTINEL_PREFIX, i),
                    "1380000%04d" % i,
                    '["customer"]',
                    0,
                    1,
                    ts,
                    ts,
                ),
            )
        for i in range(count):
            conn.execute(
                "INSERT INTO accounts (id, name, type, initial_balance, is_active, "
                "created_at, updated_at, sync_version) VALUES (?,?,?,?,?,?,?,0)",
                (
                    "s9-%s-a%d" % (ctx.run_id, i),
                    "%s-账户%d" % (SENTINEL_PREFIX, i),
                    "cash",
                    1000 * (i + 1),
                    1,
                    ts,
                    ts,
                ),
            )
        conn.execute("COMMIT")
        return True, "哨兵 %d 条/表 × 3 张主数据表（共 %d 行）" % (count, count * 3)
    except Exception as exc:
        try:
            conn.execute("ROLLBACK")
        except Exception:
            pass
        return False, "写哨兵失败：%s" % exc
    finally:
        conn.close()


def fake_backup_names(ctx: Context) -> List[str]:
    """9.4 / 9.5 会造的**假备份文件名**（由 [fake_backup_files] 实际创建）。

    单独抽出来是给 9.5 用的：**「同一分钟多份」的检查必须排除脚本自己造的东西** ——
    否则 9.4 造的「45 天前 + 400 天前」两份会被算成「同一分钟出现多份」，
    报出一个**脚本自己造成的**假缺陷（第一次跑就这么踩了）。
    """
    now = datetime.now()
    return [
        BackupName.build(manual, 3, when).file_name
        for manual, when in (
            (False, now + timedelta(days=3)),
            (False, now - timedelta(days=45)),
            (False, now - timedelta(days=400)),
            (True, now - timedelta(days=400)),
        )
    ]


def fake_backup_files(ctx: Context) -> List[str]:
    """为 9.4 / 9.5 造「假备份」（**0 字节、只为文件名存在**）。

    严格对齐 9.4 要验的两件事：
    - 一条**未来时间**的包（时钟回跳的现场）
    - 一份超 30 天的自动包 + 一份超 30 天的手动包（保留策略的现场）

    返回造出来的文件名。
    """
    os.makedirs(ctx.backup_dir, exist_ok=True)
    made: List[str] = []
    for name in fake_backup_names(ctx):
        path = os.path.join(ctx.backup_dir, name)
        try:
            with open(path, "wb") as fh:
                fh.write(b"")  # 0 字节：本文件的存在只为文件名语义
            made.append(name)
        except Exception as exc:
            eprint("⚠️ 造不出来：%s（%s）" % (name, exc))
    return made


# ------------------------------------------------------------ 9.1 应用写入监听


def _windows_db_change_watcher(directory: str, stop: threading.Event,
                               changed: threading.Event, details: Dict[str, str]) -> None:
    """用 ReadDirectoryChangesW 等 SQLite 文件事件，避免短写入被轮询漏掉。"""
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    create_file = kernel32.CreateFileW
    create_file.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                            ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32,
                            ctypes.c_void_p]
    create_file.restype = ctypes.c_void_p
    read_changes = kernel32.ReadDirectoryChangesW
    read_changes.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32,
                             ctypes.c_int, ctypes.c_uint32,
                             ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p,
                             ctypes.c_void_p]
    read_changes.restype = ctypes.c_int
    close_handle = kernel32.CloseHandle
    close_handle.argtypes = [ctypes.c_void_p]
    close_handle.restype = ctypes.c_int
    cancel_io = getattr(kernel32, "CancelIoEx", None)
    if cancel_io is not None:
        cancel_io.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        cancel_io.restype = ctypes.c_int

    handle = create_file(directory, 0x0001, 0x00000007, None, 3,
                         0x02000000, None)  # FILE_LIST_DIRECTORY / BACKUP_SEMANTICS
    if handle == ctypes.c_void_p(-1).value:
        details["error"] = "无法监听数据目录（Win32=%d）" % ctypes.get_last_error()
        changed.set()
        return
    try:
        while not stop.is_set():
            buffer = ctypes.create_string_buffer(64 * 1024)
            returned = ctypes.c_uint32()
            ok = read_changes(handle, buffer, len(buffer), 0,
                              0x00000001 | 0x00000002 | 0x00000008 | 0x00000010,
                              ctypes.byref(returned), None, None)
            if not ok:
                if not stop.is_set():
                    details["error"] = "目录监听失败（Win32=%d）" % ctypes.get_last_error()
                    changed.set()
                break
            offset = 0
            while offset < returned.value:
                next_offset = int.from_bytes(buffer.raw[offset:offset + 4], "little")
                name_size = int.from_bytes(buffer.raw[offset + 8:offset + 12], "little")
                name = buffer.raw[offset + 12:offset + 12 + name_size].decode("utf-16-le", "replace")
                lower = name.lower()
                if lower in (DATA_FILE.lower(), (DATA_FILE + "-wal").lower()):
                    details["file"] = name
                    changed.set()
                    return
                if next_offset == 0:
                    break
                offset += next_offset
    finally:
        if cancel_io is not None:
            cancel_io(handle, None)
        close_handle(handle)


def wait_for_app_database_write(ctx: Context, proc: subprocess.Popen,
                                timeout: int) -> Tuple[bool, str]:
    """等待目标库文件变更；Windows 用目录事件，其他系统退回短间隔轮询。"""
    if IS_WINDOWS:
        stop = threading.Event()
        changed = threading.Event()
        details: Dict[str, str] = {}
        watcher = threading.Thread(
            target=_windows_db_change_watcher,
            args=(ctx.data_dir, stop, changed, details),
            daemon=True,
        )
        watcher.start()
        deadline = time.monotonic() + timeout
        try:
            while time.monotonic() < deadline:
                if changed.wait(0.1):
                    if "error" in details:
                        return False, details["error"]
                    return True, details.get("file", "数据库文件")
                if proc.poll() is not None:
                    return False, "应用在检测到数据库写入前退出（exit=%s）" % proc.returncode
            return False, "等待数据库写入超时（%d 秒）" % timeout
        finally:
            stop.set()
            watcher.join(timeout=1)

    def snapshot() -> Tuple[Tuple[int, int], ...]:
        values = []
        for path in (ctx.db_path, ctx.db_path + "-wal"):
            try:
                stat = os.stat(path)
                values.append((stat.st_size, stat.st_mtime_ns))
            except OSError:
                values.append((-1, -1))
        return tuple(values)

    baseline = snapshot()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return False, "应用在检测到数据库写入前退出（exit=%s）" % proc.returncode
        if snapshot() != baseline:
            return True, "数据库文件发生变化"
        time.sleep(0.005)
    return False, "等待数据库写入超时（%d 秒）" % timeout


def run_app_crash_on_write(ctx: Context) -> Tuple[bool, str]:
    """启动隔离配置的应用，监测所选测试库写入并立即强杀本脚本启动的进程。"""
    if not IS_WINDOWS:
        return False, "应用强杀自动化目前仅支持 Windows 桌面版"
    if not sys.stdin.isatty():
        return False, "此模式需要交互式终端，以便等待应用启动和测试人员确认"
    exe = os.path.abspath(ctx.args.exe or "")
    if not exe or not os.path.isfile(exe):
        return False, "请用 --exe 指定存在的 shensuanzi.exe"
    if os.path.basename(exe).lower() != "shensuanzi.exe":
        return False, "--exe 必须指向文件名为 shensuanzi.exe 的测试版程序"
    if not os.path.isfile(ctx.db_path):
        return False, "测试库不存在：%s（先用软件初始化这个测试目录）" % ctx.db_path
    marker = os.path.join(ctx.data_dir, MARKER_FILE)
    restarted: Optional[subprocess.Popen] = None
    try:
        with open(marker, "r", encoding="utf-8") as fh:
            marker_data = json.load(fh)
        conn = read_only_connect(ctx.db_path)
        try:
            schema = int(conn.execute("PRAGMA user_version").fetchone()[0])
            integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
        finally:
            conn.close()
    except Exception as exc:
        return False, "测试目录缺少有效标记或数据库不可读：%s" % exc
    if not isinstance(marker_data, dict) or marker_data.get("schema_version") != schema:
        return False, "标记文件与数据库 schema 不匹配，请先用软件正常初始化测试目录"
    if integrity != "ok":
        return False, "测试库完整性检查失败：%s" % integrity

    appdata = os.path.join(ctx.data_dir, ".s9-crash-appdata")
    config = {"data_directory": ctx.data_dir, "ui_scale": 1.25, "shop_name": "S9 强杀测试"}
    config_path = os.path.join(appdata, "神算子", "config.json")
    if os.path.exists(appdata):
        try:
            with open(config_path, "r", encoding="utf-8") as fh:
                existing_config = json.load(fh)
            if os.path.normcase(os.path.abspath(existing_config.get("data_directory", ""))) != os.path.normcase(ctx.data_dir):
                return False, "隔离配置目录已存在且指向其他位置，拒绝覆盖：%s" % appdata
        except Exception as exc:
            return False, "隔离配置目录已存在但配置不可验证，拒绝覆盖：%s" % exc
    else:
        os.makedirs(os.path.join(appdata, "神算子"), exist_ok=False)
        with open(config_path, "w", encoding="utf-8") as fh:
            json.dump(config, fh, ensure_ascii=False, indent=2)

    env = os.environ.copy()
    env["APPDATA"] = appdata
    env["LOCALAPPDATA"] = os.path.join(appdata, "Local")
    os.makedirs(env["LOCALAPPDATA"], exist_ok=True)
    try:
        proc = subprocess.Popen([exe], env=env, cwd=os.path.dirname(exe),
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
    except Exception as exc:
        return False, "启动指定应用失败：%s" % exc

    try:
        print("   已启动隔离实例 PID %d；配置只写在：%s" % (proc.pid, appdata))
        input("   等窗口进入主界面后按 Enter；在此之前不要执行写操作……")
        if proc.poll() is not None:
            return False, "应用在监测开始前退出（exit=%s）" % proc.returncode
        print("   现在在该窗口保存一次新商品或修改商品名；检测到目标库文件变化后会立即强杀此实例。")
        changed, detail = wait_for_app_database_write(ctx, proc, ctx.args.watch_timeout)
        if not changed:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=10)
            return False, detail
        # 只杀本函数亲自启动的 PID，不按进程名扫描或结束其他应用实例。
        proc.kill()
        proc.wait(timeout=10)
        print("   已强杀 PID %d；现在用同一隔离配置重新启动，验证 WAL 恢复……" % proc.pid)
        restarted = subprocess.Popen([exe], env=env, cwd=os.path.dirname(exe),
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        input("   软件重新启动后，确认已进入主界面且数据可读，再按 Enter……")
        if restarted.poll() is not None:
            return False, "强杀后重新启动的应用已退出（exit=%s）" % restarted.returncode
        ok, verdict = ctx.integrity()
        if not ok:
            return False, "应用重启后数据库完整性检查失败：%s" % verdict
        return True, (
            "检测到 %s 写入，已立即强杀本脚本启动的应用 PID %d；"
            "重启后人工确认已进主界面，integrity_check=ok。恢复验证实例 PID %d 保持运行"
            % (detail, proc.pid, restarted.pid)
        )
    except KeyboardInterrupt:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)
        if restarted is not None and restarted.poll() is None:
            restarted.kill()
            restarted.wait(timeout=10)
        return False, "测试人员中断；已结束本脚本启动的应用进程"
    except Exception as exc:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)
        if restarted is not None and restarted.poll() is None:
            restarted.kill()
            restarted.wait(timeout=10)
        return False, "监听或强杀失败：%s" % exc


def initialize_crash_test_directory(ctx: Context) -> Tuple[bool, str]:
    """在系统临时目录创建独立空账套；9.1 绝不打开或改写用户指定的正式库。"""
    try:
        statements, version = seed_test_data.load_ddl_from_schema_source()
        if os.path.isdir(ctx.data_dir):
            if os.listdir(ctx.data_dir):
                return False, "9.1 临时测试目录非空，拒绝复用：%s" % ctx.data_dir
        else:
            os.makedirs(ctx.data_dir, exist_ok=False)
        conn = sqlite3.connect(ctx.db_path)
        try:
            seed_test_data.create_schema(conn, statements, version)
        finally:
            conn.close()
        with open(os.path.join(ctx.data_dir, MARKER_FILE), "w", encoding="utf-8") as fh:
            json.dump({"app": "神算子", "schema_version": version,
                       "created_at": now_ms(), "marker_file": MARKER_FILE},
                      fh, ensure_ascii=False, indent=2)
        ok, note = seed_sentinel(ctx, count=3)
        if not ok:
            return False, note
        return True, "已创建隔离空账套并写入基线哨兵：%s" % ctx.data_dir
    except Exception as exc:
        return False, "创建 9.1 隔离测试账套失败：%s" % exc
# ------------------------------------------------------------------- 7 条


def case_9_1(ctx: Context, rep: Report) -> None:
    case = rep.add(Case(
        key="9.1",
        title="强杀 / 断电（WAL 恢复）",
        criterion="写入过程中直接结束进程 ⇒ 重启后**能打开**、无损坏、最近一次已保存的数据在（WAL 恢复）",
    ))
    before = getattr(ctx.args, "baseline_sentinels", None)
    if before is None:
        before = ctx.sentinel_count()
    case.ok("强杀前：库里哨兵 %d 条" % before)
    if before < 0:
        case.fail("读不到库（%s）—— 先让软件在这个位置正常打开一次" % ctx.db_path)
        return

    if ctx.phase == "watch-write":
        ok, note = run_app_crash_on_write(ctx)
        if not ok:
            case.fail(note)
            return
        case.ok(note)
        after = ctx.sentinel_count()
        if after < before:
            case.fail("应用强杀 / 重启后哨兵数据减少：%d → %d" % (before, after))
        else:
            case.ok("重启后哨兵数据仍在：%d → %d" % (before, after))
        case.need_human(
            "请在刚重启的隔离实例中核对你刚才保存的商品 / 修改内容仍在，且没有异常堆栈；"
            "完成后关闭这个实例。",
        )
        case.resolve()
        return

    # 此阶段只读核验；真正的应用强杀由 `watch-write` 启动隔离实例完成。
    integ_ok, verdict = ctx.integrity()
    if not integ_ok:
        case.fail("当前库 integrity_check 不通过：%s" % verdict)
        return
    case.ok("当前库 integrity_check = ok（库能打开、无损坏）")
    after = ctx.sentinel_count()
    case.ok("当前哨兵：%d 条（运行清单记录前值 %d 条）" % (after, before))
    if after < before:
        case.fail(
            "**最近一次已保存的数据丢了**：基线 %d 条 → 现在 %d 条"
            "（原文要求「最近一次已保存的数据在」）" % (before, after)
        )
    else:
        case.ok("最近一次已保存的数据**在**（%d ≥ %d）" % (after, before))

    case.need_human(
        "应用强杀自动化使用独立流程，避免误杀已运行的正式实例：",
        "使用 `--phase watch-write --exe <测试版 shensuanzi.exe> --confirm-app-kill`（脚本自动创建临时空账套）；",
        "在脚本启动的隔离实例中保存商品，脚本侦测该测试库文件写入后立即结束该 PID，并重新启动实例；",
        "重启后确认刚保存的数据在、主界面可用且日志无异常。真断电仍须人工补测。",
    )
    case.resolve()


def case_9_2(ctx: Context, rep: Report) -> None:
    case = rep.add(Case(
        key="9.2",
        title="只读 / 磁盘满",
        criterion="数据目录设为只读（或用小容量盘）⇒ 报错给「怎么办」，不崩、不静默丢数据",
    ))
    if ctx.phase == "verify":
        data_writable = backup_writable = None
        case.note("verify 为只读核验阶段；不创建目录、不写探针文件。请根据人工记录确认权限恢复情况。")
    else:
        os.makedirs(ctx.backup_dir, exist_ok=True)
        data_writable = can_write_dir(ctx.data_dir)
        backup_writable = can_write_dir(ctx.backup_dir)
        case.ok("探针实测：数据目录可写=%s · 备份目录可写=%s" % (data_writable, backup_writable))
    if backup_writable is False:
        case.fail(
            "备份目录现在**就写不进去**（%s）—— 现场已经不干净了，请先把权限恢复再跑，"
            "否则测不出「新出现的只读」是什么表现" % ctx.backup_dir
        )
        return

    before_sentinels = ctx.sentinel_count()
    before_files = sorted(
        f for f in os.listdir(ctx.backup_dir)
        if os.path.isfile(os.path.join(ctx.backup_dir, f))
    ) if os.path.isdir(ctx.backup_dir) else []
    case.ok("备份目录现有 %d 个文件；库内哨兵 %d 条" % (len(before_files), before_sentinels))

    if IS_WINDOWS:
        deny = 'icacls "{d}" /deny "%USERNAME%:(OI)(CI)(W,D)"'.format(d=ctx.backup_dir)
        allow = 'icacls "{d}" /remove:d "%USERNAME%"'.format(d=ctx.backup_dir)
    else:
        deny = "chmod a-w '%s'" % ctx.backup_dir
        allow = "chmod u+w '%s'" % ctx.backup_dir

    case.need_human(
        "**脚本故意不改权限**（万一恢复失败，那个目录会一直写不进去）。请你自己动手，两步：",
        "① 把**备份目录**设为拒绝写入：`%s`" % deny,
        "② 打开软件 → 设置 → 点「立即备份」⇒ 观察界面**说了什么**",
        "期望：提示里说清「怎么办」（例如「备份文件夹用不了 …」），**不是** SQLite 异常串 / 英文堆栈 / 白屏",
        "期望：软件**不崩**；界面上原有数据**一条都没少**（当前哨兵 %d 条）" % before_sentinels,
        "期望：备份目录里**不出现** `.tmp` 残件、也不出现半个 `.db`",
        "③ 恢复权限：`%s`" % allow,
        "④ 做完再跑一次 `--phase verify`，脚本会自动核对「数据有没有少 / 库有没有坏 / 有没有残件」",
        "（可选、更狠的一档）把数据目录本身设为只读，或把软件装在小容量盘上写满 —— 同上观察",
    )
    case.resolve()


def case_9_3(ctx: Context, rep: Report) -> None:
    case = rep.add(Case(
        key="9.3",
        title="数据目录被删 / 改名",
        criterion="运行中把数据目录改名 ⇒ 行为可理解（**不静默重建空库**）",
    ))
    renamed = ctx.data_dir + ".renamed"
    running = ctx.app_running()

    if os.path.isdir(renamed):
        # verify 阶段：人已经改过名了，脚本核对结果
        case.ok("发现改名后的目录：%s" % renamed)
        if running:
            case.fail(
                "此刻**还有 %d 个神算子实例在跑**：%s —— 请先全部关掉再验尸，"
                "否则读到的状态说不清是谁写的"
                % (len(running), [p for p, _ in running])
            )
            return

        stale = os.path.join(ctx.data_dir, DATA_FILE)
        if not os.path.exists(stale):
            case.ok("原路径下**没有库文件**（%s 不存在）—— 没有静默重建 ✔" % stale)
        else:
            # ⚠️ 「原路径下有 .db」**不等于**「软件偷偷建了个空库」：可能只是
            # 你把目录**拷**成了 .renamed（原目录仍在），也可能改名失败没改成。
            # 所以判据必须是「**这个库是空的、和改名前那份没关系**」，
            # 而不是「这个路径下有文件」。
            size = os.path.getsize(stale)
            empty = size < 65536 and not ctx.db_tables()
            sentinels = ctx.sentinel_count()
            if empty:
                case.fail(
                    "**软件静默重建了一个新库**：%s（%d 字节、**一张用户表都没有**）—— "
                    "原文要求「行为可理解（不静默重建空库）」。请确认界面上是否**明确提示**了这件事。"
                    % (stale, size)
                )
            elif sentinels > 0:
                case.ok(
                    "原路径下的库（%d 字节）里还有 %d 条哨兵 ⇒ 这是**改名前那一份**没被搬走"
                    "（或者是拷贝而非改名留下的），**不是**重建的空库 ✔"
                    % (size, sentinels)
                )
            elif not ctx.db_tables():
                case.fail("原路径下的库是空的（%d 字节、无用户表）却又有表结构 —— 需人工判断" % size)
            else:
                case.note(
                    "原路径下的库（%d 字节）表结构完整、但**一条哨兵都没有** —— "
                    "不排除是软件重建后又正常建表了。请对照界面文案人工判断。" % size
                )

        moved_db = os.path.join(renamed, DATA_FILE)
        ok, verdict = ctx.integrity(moved_db)
        case.ok("被改名的那份库：%s（%s）" % (verdict, "ok" if ok else "不 ok"))
        if not ok:
            case.fail("被改名的库校验失败 —— 改目录名不该影响文件内容")
        moved_sentinels = -1
        try:
            conn = read_only_connect(moved_db)
            moved_sentinels = conn.execute(
                "SELECT COUNT(*) FROM products WHERE name LIKE ?", (SENTINEL_PREFIX + "%",)
            ).fetchone()[0]
            conn.close()
        except Exception as exc:
            case.fail("读不回改名后的库：%s" % exc)
        case.ok("改名后的库里哨兵 %d 条" % moved_sentinels)
        if moved_sentinels == 0:
            case.fail("改名后的库里**一条哨兵都没有** —— 数据没跟过去？")
        case.need_human(
            "自动部分只证明了「改名不会毁数据」。**界面说什么**必须人看：",
            "看软件当时/此刻的界面：是否给出可理解的中文提示（不是英文异常串 / 白屏）",
            "是否**声称**「已重建数据目录 / 已新建空库」而用户不知情 —— 若是，就是缺陷",
            "看完把目录名改回来：`%s` → `%s`" % (renamed, ctx.data_dir),
        )
        case.resolve()
        return

    # prepare 阶段：只出清单，**脚本绝不自己改名**
    if running:
        case.ok(
            "检测到 %d 个神算子实例正在运行（PID %s）—— 这正是这一条**需要**的状态。"
            "脚本不会去碰正在被打开的数据目录，改名动作归你。"
            % (len(running), [p for p, _ in running])
        )
    else:
        case.note(
            "此刻没有神算子实例在跑 —— 这一条要求「**运行中**把数据目录改名」，"
            "所以请先打开软件再动手（脚本不代你启动）"
        )
    case.ok("当前库：%s（哨兵 %d 条）" % (ctx.db_path, ctx.sentinel_count()))
    case.need_human(
        "**这一条必须在软件运行时做，且由你亲手改名**（脚本不代劳）：",
        "① 先确认软件**正开着**，并且已经进到主界面",
        "② 记下当前哨兵条数（脚本已算出：%d 条）" % ctx.sentinel_count(),
        "③ 在资源管理器里把数据目录改名：`%s` → `%s`" % (ctx.data_dir, renamed),
        "④ 回到软件：点一下任意页面 / 做一次会读写数据的动作 ⇒ 观察**行为是否可理解**",
        "⑤ 期望：**不静默重建空库**，而是给出可理解的报错或提示；期望软件不崩",
        "⑥ 再点「设置 → 立即备份」⇒ 期望：说「怎么办」，不是英文异常串",
        "⑦ 把目录名改回来（或保持改名状态），然后跑 `--phase verify` —— 脚本会核对："
        "原路径下有没有被偷偷建出新空库、被改名的库里数据少没少",
        "⚠️ 注意（这一条踩过坑）：软件的单实例锁是数据目录里的 `%s`。"
        "**把数据目录改名会绕过这个锁** —— 改名后再启动第二个实例，它会在原路径上"
        "看不到锁而照常启动。做这一步时请手动确认只有一个软件窗口。" % INSTANCE_LOCK,
    )
    case.resolve()


def case_9_4(ctx: Context, rep: Report) -> None:
    case = rep.add(Case(
        key="9.4",
        title="时钟回跳",
        criterion="把系统时间往回拨 ⇒ 备份仍按策略走（**重新锚定**），不刷屏",
    ))
    now = datetime.now()
    # ---- 自动：策略判定（时钟回跳 ⇒ 应当重新锚定）
    future = now + timedelta(days=3)
    if should_auto_backup(now, future):
        case.ok(
            "策略判定：上次备份在**未来**（%s）⇒ `should_auto_backup` = true "
            "⇒ 会**备份一次重新锚定** ✔（这正是 `backup.dart` 遗漏 9 的行为）"
            % future.strftime("%Y-%m-%d %H:%M")
        )
    else:
        case.fail("时钟回跳时判定为「不需要备份」—— 原文要求「重新锚定」（= 备份一次）")

    # ---- 自动：保留策略在搅乱的时间线上仍然稳定
    messy = [
        BackupName.build(False, 3, now - timedelta(days=45)),
        BackupName.build(False, 3, now - timedelta(days=40)),
        BackupName.build(False, 3, now - timedelta(days=2)),
        BackupName.build(True, 3, now - timedelta(days=400)),
    ]
    expired = expired_auto_backups(messy, now)
    case.ok(
        "保留策略在搅乱的时间线上：%d 份超 30 天的自动包里，应清理 %d 份 —— %s"
        "（每自然周最早的一份豁免，手动包永不清理）"
        % (
            len([m for m in messy if not m.manual and m.time < now - timedelta(days=30)]),
            len(expired),
            [e.file_name for e in expired] or "（无）",
        )
    )
    if any(e.manual for e in expired):
        case.fail("保留策略把手动包（`m-` 前缀）判成了过期 —— 原文：手动包**永不**自动清理")
    if len(expired) > 2:
        case.fail("保留策略清理得太多：%d 份（超过 30 天的自动包只有 2 份）" % len(expired))

    # ---- 现场：伪造时间线
    made = [] if ctx.phase == "verify" else fake_backup_files(ctx)
    case.ok("已在备份目录造出假时间线（0 字节，只为文件名语义）：%s" % (made or "（没造出来）"))
    case.ok("备份目录现在：%s" % sorted(os.path.basename(p) for p in glob.glob(os.path.join(ctx.backup_dir, "*.db"))))
    before_files = sorted(os.path.basename(p) for p in glob.glob(os.path.join(ctx.backup_dir, "shensuanzi-schema3-*.db")))

    if not ctx.args.use_system_time:
        case.need_human(
            "自动部分只验了「策略怎么判」。**真拨系统时间**这一步得你来做（会影响整机、需要管理员）：",
            "① 先让软件正常跑一次自动备份（或点一次「立即备份」），记下备份目录里最新的文件名",
            "② 确认此刻没有别的程序依赖正确时间（日历 / 定时任务 / 其它数据库）",
            "③ 把 Windows 系统时间**往回拨 1 天**",
            "④ 重新打开软件（或等它的自动备份时机）⇒ 期望：**又备份了一份**（重新锚定），不是一直不备份",
            "⑤ 看界面：备份提醒**不刷屏**（不出现连环弹窗 / 重复提示堆积）",
            "⑥ 把系统时间改回来 ⇒ 期望：一切正常，没有因为时间变化而报错",
            "⑦ 改回时间后跑 `--phase verify`，脚本会核对保留策略有没有把该留的留错、把该删的漏删",
        )
    else:
        case.need_human(
            "你加了 `--use-system-time`，但脚本**依然不代改系统时间** —— "
            "改坏的是整台机器，不是这个测试目录，这件事必须由人按下去：",
            "按上面 ①~⑥ 手工做",
            "（脚本能帮的是：改回时间后跑 `--phase verify`，核对策略结果）",
        )
    case.note("本次用于对照的自动包清单：%s" % before_files)
    case.resolve()


def case_9_5(ctx: Context, rep: Report) -> None:
    case = rep.add(Case(
        key="9.5",
        title="并发备份",
        criterion="备份进行中连点「立即备份」⇒ **只有一份产物**（请求复用，不并写出多个文件）",
    ))
    # ---- 自动：同一自然分钟 ⇒ 同一文件名（「只有一份产物」的文件名层面保证）
    now = datetime.now()
    names = {BackupName.build(True, 3, now).file_name for _ in range(5)}
    case.ok("同一分钟发起 5 次手动备份 ⇒ 文件名集合：%s" % sorted(names))
    if len(names) != 1:
        case.fail(
            "同一分钟的 5 次请求生成了 %d 个不同文件名 —— 「只有一份产物」在**文件名层面**"
            "就不成立" % len(names)
        )

    # ---- 自动：目录里有没有同一分钟出现多份
    #
    # ⚠️ 只统计**非空**的备份文件，这一步很关键：脚本自己为 9.4 造的「假备份」
    # 一律是 **0 字节**（只为文件名语义存在），而**真备份永远不可能是 0 字节**
    # （它是一份拷出来的完整 SQLite 库）。用大小区分，比按文件名排除更稳 ——
    # 上一轮跑剩的假备份（时间戳与本轮不同）也能被排除掉。
    if ctx.phase != "verify":
        os.makedirs(ctx.backup_dir, exist_ok=True)
    real: List[str] = []
    fakes = 0
    for p in glob.glob(os.path.join(ctx.backup_dir, "*.db")):
        base = os.path.basename(p)
        if BackupName.parse(base) is None:
            continue
        try:
            if os.path.getsize(p) == 0:
                fakes += 1
                continue
        except OSError:
            continue
        real.append(base)

    by_minute: Dict[str, List[str]] = {}
    for f in real:
        parsed = BackupName.parse(f)
        if parsed is None:
            continue
        by_minute.setdefault(parsed.time.strftime("%Y%m%d-%H%M"), []).append(f)
    crowded = {k: v for k, v in by_minute.items() if len(v) > 1}
    case.ok(
        "备份目录里**非空**的合法备份 %d 份，覆盖 %d 个自然分钟"
        "（另有 %d 份 0 字节的假备份 —— 那是脚本为 9.4 造的现场，不计入）"
        % (len(real), len(by_minute), fakes)
    )
    if crowded:
        case.fail(
            "**同一个自然分钟里出现了多份备份**：%s —— 原文要求「只有一份产物」"
            "（`backup.dart` 的同一分钟防连点是靠「已有同名文件就跳过重拷」实现的，"
            "出现多份说明这条不变量被破坏了）" % crowded
        )
    else:
        case.ok("没有任何一分钟出现多份 ⇒ 「同一分钟只有一份」仍然成立 ✔")

    case.need_human(
        "「连点」必须你点（脚本点不了界面按钮）：",
        "① 打开软件 → 设置 → 找到「立即备份」",
        "② **连续快速点 10 次**（越快越好，最好在 2 秒内点完）",
        "③ 立刻看备份目录（%s）：期望**只多出 1 份** `shensuanzi-m-schema3-*.db`" % ctx.backup_dir,
        "④ 看界面：期望每次都给出结果（成功 / 「这一分钟里已经备份过了」），**没有报错、没有卡死**",
        "⑤ 看目录里有没有 `.tmp` 残留 ⇒ 期望没有（`backup.dart` 收尾会清）",
        "⑥ 做完跑 `--phase verify` ⇒ 脚本会核对「有没有哪一分钟出现多份」",
    )
    case.resolve()


def case_9_6(ctx: Context, rep: Report) -> None:
    case = rep.add(Case(
        key="9.6",
        title="超长输入",
        criterion="名称 / 备注填超长串 ⇒ 不溢出、不崩；**落库后重启仍在**",
    ))
    if not os.path.exists(ctx.db_path):
        case.fail("库不存在：%s" % ctx.db_path)
        return
    if "products" not in ctx.db_tables():
        case.fail("库里没有 products 表 —— 先让软件在这个位置正常打开一次")
        return

    # ---- 自动：超长串落库 → 重开连接逐字节读回
    ids: List[Tuple[str, int, str]] = [
        (label, length, "s9-%s-long-%s" % (ctx.run_id, label))
        for label, length in LONG_INPUTS
    ]
    party_id = "s9-%s-long-party" % ctx.run_id
    if ctx.phase != "verify":
        try:
            conn = sqlite3.connect(ctx.db_path, timeout=30)
        except Exception as exc:
            case.fail("打不开库：%s" % exc)
            return
        try:
            conn.execute("PRAGMA foreign_keys = ON")
            ts = now_ms()
            conn.execute("BEGIN")
            for label, length in LONG_INPUTS:
                pid = "s9-%s-long-%s" % (ctx.run_id, label)
                conn.execute(
                    "INSERT INTO products (id, code, name, unit, remark, cost_price, sell_price, "
                    "safety_stock, is_active, created_at, updated_at, sync_version) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?,0)",
                    (pid, "P9%s" % label, "%s-%s" % (SENTINEL_PREFIX, label), "件", "长" * length, 1, 2, 0, 1, ts, ts),
                )
            conn.execute(
                "INSERT INTO parties (id, name, remark, roles, credit_limit, is_active, "
                "created_at, updated_at, sync_version) VALUES (?,?,?,?,?,?,?,?,0)",
                (party_id, "%s-超长备注" % SENTINEL_PREFIX, "注" * 1_048_576, '["customer"]', 0, 1, ts, ts),
            )
            conn.execute("COMMIT")
        except Exception as exc:
            try:
                conn.execute("ROLLBACK")
            except Exception:
                pass
            case.fail("超长串写入失败：%s" % exc)
            return
        finally:
            conn.close()

    case.ok(("已写入" if ctx.phase != "verify" else "核验本轮") + "超长串：%s（另有往来方备注 1M 字符）"
            % ", ".join("%s=%d 字符" % (l, n) for l, n, _ in ids))

    # 重开连接（= 软件重启会做的事）逐字节核对
    try:
        conn2 = read_only_connect(ctx.db_path)
    except Exception as exc:
        case.fail("重开连接失败：%s" % exc)
        return
    try:
        bad = 0
        for label, length, pid in ids:
            row = conn2.execute("SELECT name, remark FROM products WHERE id = ?", (pid,)).fetchone()
            if row is None:
                case.fail("%s 档的数据**重启后不见了**" % label)
                bad += 1
                continue
            if row[1] != "长" * length:
                case.fail(
                    "%s 档的备注被改写：写入 %d 字符，读回 %d 字符"
                    % (label, length, len(row[1] or ""))
                )
                bad += 1
        party = conn2.execute("SELECT remark FROM parties WHERE id = ?", (party_id,)).fetchone()
        if party is None or len(party[0] or "") != 1_048_576:
            case.fail("往来方 1M 备注重启后被改写或丢失")
            bad += 1
        if bad == 0:
            case.ok("重开连接后**逐字节一致**（长度与内容都对）—— 数据库层没有截断 ✔")
    finally:
        conn2.close()

    ok, verdict = ctx.integrity()
    if not ok:
        case.fail("写入超长串后库校验失败：%s" % verdict)
    else:
        case.ok("写入超长串后 integrity_check = ok")

    case.need_human(
        "「界面不溢出、不崩」**只能人看**（脚本读不到渲染结果）：",
        "① 商品页 → 新建商品 → 名称粘 200 个中文、备注粘 10 万字符 → 保存",
        "② 期望：输入框**不溢出**、界面不卡死、保存能成功（或给出明确的「怎么办」，而不是白屏）",
        "③ 保存后重启软件 ⇒ 期望：那条商品还在，点开详情能看到（内容可滚动）",
        "④ 提醒：脚本刚写进去的那条 **1M 字符备注**的商品，用界面打开时留意是否明显卡顿 —— 卡顿也要记下来",
    )
    case.resolve()


def case_9_7(ctx: Context, rep: Report) -> None:
    case = rep.add(Case(
        key="9.7",
        title="非法字符",
        criterion="单引号 / emoji / 全角空格 ⇒ 正常落库（**参数化查询**）",
    ))
    if not os.path.exists(ctx.db_path):
        case.fail("库不存在：%s" % ctx.db_path)
        return
    if "products" not in ctx.db_tables():
        case.fail("库里没有 products 表 —— 先让软件在这个位置正常打开一次")
        return

    written = [
        (label, text, "s9-%s-nasty-%d" % (ctx.run_id, i))
        for i, (label, text) in enumerate(NASTY_STRINGS)
    ]
    if ctx.phase != "verify":
        try:
            conn = sqlite3.connect(ctx.db_path, timeout=30)
        except Exception as exc:
            case.fail("打不开库：%s" % exc)
            return
        try:
            conn.execute("PRAGMA foreign_keys = ON")
            ts = now_ms()
            conn.execute("BEGIN")
            for i, (label, text, pid) in enumerate(written):
                conn.execute(
                    "INSERT INTO products (id, code, name, unit, remark, cost_price, sell_price, "
                    "safety_stock, is_active, created_at, updated_at, sync_version) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?,0)",
                    (pid, "P8%03d" % i, text, "件", text, 1, 2, 0, 1, ts, ts),
                )
            conn.execute("COMMIT")
        except Exception as exc:
            try:
                conn.execute("ROLLBACK")
            except Exception:
                pass
            case.fail("非法字符写入失败：%s" % exc)
            return
        finally:
            conn.close()

    case.ok(("已写入 " if ctx.phase != "verify" else "核验本轮 ") + "%d 种非法 / 边界字符：%s"
            % (len(written), "、".join(l for l, _, _ in written)))

    try:
        conn2 = read_only_connect(ctx.db_path)
    except Exception as exc:
        case.fail("重开连接失败：%s" % exc)
        return
    try:
        bad = 0
        for label, text, pid in written:
            row = conn2.execute("SELECT name, remark FROM products WHERE id = ?", (pid,)).fetchone()
            if row is None:
                case.fail("「%s」落库后查不回来" % label)
                bad += 1
                continue
            if row[0] != text or row[1] != text:
                case.fail("「%s」被改写：%r → %r" % (label, text, row))
                bad += 1
        # 参数化基本功：把这些串当**查询条件**再走一遍
        for label, text, pid in written:
            row = conn2.execute("SELECT id FROM products WHERE name = ? LIMIT 1", (text,)).fetchone()
            if row is None or row[0] != pid:
                case.fail("用「%s」当查询条件查不回自己（等值匹配失败）" % label)
                bad += 1
        if bad == 0:
            case.ok("全部逐字节一致，且**等值查询**都能查回自己 ⇒ 参数化往返成立 ✔")
    finally:
        conn2.close()

    ok, verdict = ctx.integrity()
    if not ok:
        case.fail("写入非法字符后库校验失败：%s" % verdict)
    else:
        case.ok("写入非法字符后 integrity_check = ok")

    fk = ctx.fk_check()
    if fk:
        case.fail("外键校验不通过：%s" % fk[:3])
    elif fk is not None:
        case.ok("外键校验通过（foreign_key_check 为空）")

    case.need_human(
        "数据库层已证明「参数化查询正常落库」。**界面上正常不正常**要人看：",
        "① 商品页搜「O'Brien」⇒ 期望：能搜到（不是报错、也不是搜出全表）",
        "② 商品页搜「%」⇒ 期望：**不被当成通配符**搜出全部（若搜出全部，是 LIKE 没转义 —— 记缺陷）",
        "③ 商品页搜「_」⇒ 同上",
        "④ 打开含 emoji 的那条商品详情 ⇒ 期望：emoji 正常显示（不是方框 / 乱码）",
        "⑤ 把那条商品导出到 CSV ⇒ Excel 打开 ⇒ 期望：中文与 emoji 不乱码、引号没把列撑错",
        "⑥ 往来方页搜一个含**全角空格**的名称 ⇒ 期望：匹配行为可预期（精确匹配上，或明确搜不到）",
    )
    case.resolve()


#: 用例表 —— 顺序与 `docs/desktop_acceptance.md` 第九节一致
CASE_TABLE: Tuple[Tuple[str, Any, str, str], ...] = (
    ("9.1", case_9_1, "强杀 / 断电（WAL 恢复）",
     "写入过程中直接结束进程 ⇒ 重启后能打开、无损坏、最近一次已保存的数据在"),
    ("9.2", case_9_2, "只读 / 磁盘满",
     "数据目录设为只读（或用小容量盘）⇒ 报错给「怎么办」，不崩、不静默丢数据"),
    ("9.3", case_9_3, "数据目录被删 / 改名",
     "运行中把数据目录改名 ⇒ 行为可理解（不静默重建空库）"),
    ("9.4", case_9_4, "时钟回跳",
     "把系统时间往回拨 ⇒ 备份仍按策略走（重新锚定），不刷屏"),
    ("9.5", case_9_5, "并发备份",
     "备份进行中连点「立即备份」⇒ 只有一份产物（请求复用，不并写出多个文件）"),
    ("9.6", case_9_6, "超长输入",
     "名称 / 备注填超长串 ⇒ 不溢出、不崩；落库后重启仍在"),
    ("9.7", case_9_7, "非法字符",
     "单引号 / emoji / 全角空格 ⇒ 正常落库（参数化查询）"),
)


# ------------------------------------------------------------------- CLI


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="destructive_acceptance.py",
        description="第九节（异常与破坏性）的现场准备 + 自动验库 + 人工清单。"
                    "watch-write 只强杀本脚本亲自启动的隔离应用实例。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "典型用法（三段式，推荐）：\n"
            "  python tool/destructive_acceptance.py --phase prepare --data-dir D:\\测试数据 --confirm-test-data\n"
            "  （然后人去做：拔电 / 改时间 / 连点备份 / 粘超长串 …）\n"
            "  python tool/destructive_acceptance.py --phase verify  --data-dir D:\\测试数据\n\n"
            "9.1 自动强杀（用隔离 APPDATA 启动指定程序，手工保存一次触发）：\n"
            "  python tool/destructive_acceptance.py --phase watch-write "
            "--exe C:\\path\\shensuanzi.exe --confirm-app-kill\n\n"
            "只跑某几条：\n"
            "  python tool/destructive_acceptance.py --phase all --only 9.1,9.7 --data-dir D:\\测试数据 --confirm-test-data\n"
        ),
    )
    p.add_argument(
        "--phase",
        choices=("prepare", "verify", "all", "watch-write"),
        default="all",
        help="prepare = 只摆现场；verify = 只验尸；all = 一把过（默认）；"
             "watch-write = 9.1 监听应用写库并强杀本脚本启动的隔离实例；"
    )
    p.add_argument(
        "--data-dir",
        help="prepare / verify / all 使用的隔离测试数据目录；watch-write 自建临时空账套",
    )
    p.add_argument(
        "--backup-dir",
        help="备份目录（默认 = 数据目录的兄弟「%s」，与软件一致）" % BACKUP_FOLDER,
    )
    p.add_argument(
        "--only", help="只跑这几条（逗号分隔，如 9.1,9.7）",
    )
    p.add_argument(
        "--report",
        default=os.path.join(script_directory(), "desktop_acceptance_s9_report.md"),
        help="Markdown 报告的落点（默认写入脚本所在目录）",
    )
    p.add_argument(
        "--use-system-time",
        action="store_true",
        help="**仅表示你已授权改系统时间**（9.4 的完整形态）。脚本自己**依然不会**改 —— "
             "它只用这个开关决定清单怎么写",
    )
    p.add_argument(
        "--allow-running-app",
        action="store_true",
        help="即使检测到神算子实例在跑也继续（默认拒绝 —— 9.3 改目录名时最危险）",
    )
    p.add_argument(
        "--confirm-test-data",
        action="store_true",
        help="prepare / all 必需：确认 --data-dir 是可写入哨兵与测试数据的隔离测试账套",
    )
    p.add_argument(
        "--keep-sentinel-files",
        action="store_true",
        help="收尾时保留脚本造的哨兵行与假备份（默认也不删 —— 它们是你验尸的证据）",
    )
    p.add_argument("--dry-run", action="store_true", help="只打印会做什么与自检结果，不动任何东西")
    p.add_argument(
        "--exe",
        help="watch-write 使用的 shensuanzi.exe（只启动该路径程序）",
    )
    p.add_argument(
        "--confirm-app-kill",
        action="store_true",
        help="watch-write 必需：明确确认将强杀本脚本启动的测试应用进程",
    )
    p.add_argument(
        "--watch-timeout",
        type=int,
        default=600,
        help="watch-write 等待数据库写入的秒数（默认 %(default)s）",
    )
    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except Exception:
            pass
    raw = list(sys.argv[1:] if argv is None else argv)
    args = build_parser().parse_args(raw)
    if args.phase == "watch-write" and args.only:
        selected = {value.strip() for value in args.only.split(",") if value.strip()}
        if selected != {"9.1"}:
            eprint("⛔ watch-write 只执行 9.1；请移除 --only 或仅指定 9.1。")
            return 2
    if not args.dry_run and args.phase in ("prepare", "all") and not args.confirm_test_data:
        eprint("⛔ prepare / all 会向数据库插入哨兵与测试行；请确认隔离测试库并加 --confirm-test-data。")
        return 2

    # 默认路径曾指向真实用户数据目录；破坏性验收必须由操作者明确选定
    # 隔离的测试数据目录。dry-run 使用临时目录名仅展示计划，不创建目录。
    if args.phase == "watch-write":
        if args.data_dir and not args.dry_run:
            eprint("⛔ watch-write 自动创建系统临时隔离账套，不接受 --data-dir，以免误触已有库。")
            return 2
        args.data_dir = (
            os.path.join(tempfile.gettempdir(), "shensuanzi-s9-crash-dry-run")
            if args.dry_run
            else tempfile.mkdtemp(prefix="shensuanzi-s9-crash-")
        )
    elif not args.data_dir:
        if not args.dry_run:
            eprint("⛔ 必须通过 --data-dir 明确指定隔离的测试数据目录。")
            eprint("   此脚本会写数据库哨兵并创建验收现场，不能默认触碰正式数据目录。")
            return 2
        args.data_dir = os.path.join(tempfile.gettempdir(), "shensuanzi-s9-dry-run")

    args.run_id = None
    if args.phase == "verify":
        candidates = [
            os.path.join(os.path.abspath(args.data_dir), RUN_MANIFEST),
            os.path.join(os.path.abspath(args.data_dir) + ".renamed", RUN_MANIFEST),
        ]
        manifest_path = next((p for p in candidates if os.path.isfile(p)), None)
        if manifest_path is None:
            eprint("⛔ verify 找不到 prepare 生成的运行清单（%s）。" % RUN_MANIFEST)
            eprint("   请先在同一个测试数据目录执行 --phase prepare。")
            return 2
        try:
            with open(manifest_path, "r", encoding="utf-8") as fh:
                manifest = json.load(fh)
            if os.path.normcase(os.path.abspath(manifest.get("data_dir", ""))) != os.path.normcase(os.path.abspath(args.data_dir)):
                raise ValueError("运行清单的数据目录与当前 --data-dir 不一致")
            args.run_id = str(manifest["run_id"])
            args.baseline_sentinels = int(manifest.get("baseline_sentinels", 0))
        except Exception as exc:
            eprint("⛔ 运行清单无效：%s" % exc)
            return 2

    print("桌面版验收 · 第九节（异常与破坏性）  —— 阶段：%s" % args.phase)
    print("=" * 74)
    if not args.dry_run and args.phase == "watch-write" and (not args.exe or not args.confirm_app_kill):
        eprint("⛔ watch-write 必须同时提供 --exe 和 --confirm-app-kill。")
        return 2
    if args.watch_timeout <= 0:
        eprint("⛔ --watch-timeout 必须大于 0。")
        return 2

    # ---- 复刻自检（永远跑）
    drift = compare_with_dart()
    if drift:
        print("❌ 脚本内部的「备份规则复刻」与 Dart 期望不符：")
        for d in drift:
            print("   · %s" % d)
        print("   这是**脚本自身**的问题（不是软件缺陷）—— 先修脚本再跑验收。")
        return 2
    print("✅ 备份规则复刻自检通过（文件名 / 保留策略 / 自动备份判定 = Dart 期望）")

    ctx = Context(args)

    # ---- 阶段与落点
    print("   数据目录：%s" % ctx.data_dir)
    print("   备份目录：%s" % ctx.backup_dir)
    if args.dry_run:
        print("")
        print("--dry-run：只报告计划，不动任何东西")
        print("   报告落点：%s" % ctx.report_path)
        print("")
        for key, _, title, crit in CASE_TABLE:
            print("   %s  %s" % (key, title))
            print("       判据：%s" % crit)
        print("")
        print("   prepare 阶段会做：写本轮哨兵、9.6/9.7 数据并保存运行清单")
        print("   verify 阶段只读数据库和目录；watch-write 才启动/强杀隔离应用")
        if args.phase == "watch-write":
            print("   watch-write 将在系统临时目录创建空账套，不碰现有库")
        return 0

    # ⚠️ 9.3 的正当现场就是「数据目录已被改名搬走」—— 此时 data_dir 不存在，
    # 但那正是要验的状态，不能因此拒绝运行。所以只要 `.renamed` 在，就放行。
    renamed_probe = ctx.data_dir + ".renamed"
    if not os.path.isdir(ctx.data_dir):
        if os.path.isdir(renamed_probe):
            print("   ℹ️ 数据目录本身不存在，但发现改名后的 `%s` —— 这是 9.3 的正当现场，继续。" % renamed_probe)
        else:
            print("❌ 数据目录不存在：%s" % ctx.data_dir)
            print("   请先用软件在这个位置打开一次（它会建库），或指定一个已有数据目录。")
            return 3
    print("   数据库  ：%s（%s）" % (
        ctx.db_path,
        "存在，%d 字节" % os.path.getsize(ctx.db_path) if os.path.exists(ctx.db_path) else "**不存在**",
    ))

    # ---- 安全阀：拒绝在有实例运行时动手
    running = [] if args.phase == "watch-write" else ctx.app_running()
    if running:
        print("")
        print("⚠️ 检测到 %d 个神算子实例正在运行：" % len(running))
        for pid, path in running:
            print("     PID %s  %s" % (pid, path))
        print("")
        print("   为什么要在动手前关掉它：")
        print("   · **9.3 要改数据目录的名字** —— 有实例开着时改，会绕过它的单实例锁")
        print("     （锁文件 `%s` 会被一起改走，新实例在原路径看不到锁就照常启动）；" % INSTANCE_LOCK)
        print("   · 9.6 / 9.7 要往库里写数据，实例同时写会让现场说不清是谁写的。")
        print("")
        if not args.allow_running_app:
            print("   ⇒ 请先关闭所有神算子窗口，然后重跑。")
            print("   （确认你就是要这样跑：加 --allow-running-app）")
            return 4
        print("   ⇒ 你加了 --allow-running-app，继续；但 9.3 的结论会不可信。")

    print("")
    print("   软件版本（从启动日志读）：%s" % ctx.app_version())
    ver = ctx.db_schema_version()
    print("   库 schema 版本：%s" % ("v%s" % ver if ver is not None else "读不到"))

    if args.phase == "watch-write" and not args.confirm_app_kill:
        eprint("⛔ 9.1 会强杀本脚本启动的应用；必须显式加 --confirm-app-kill。")
        return 2

    if args.phase == "watch-write":
        ok, note = initialize_crash_test_directory(ctx)
        if not ok:
            eprint("❌ %s" % note)
            return 2
        print("   %s" % note)

    # ---- 布局与哨兵
    if args.phase != "verify" and args.phase != "watch-write":
        os.makedirs(ctx.backup_dir, exist_ok=True)
    if args.phase in ("prepare", "all"):
        if os.path.exists(ctx.db_path):
            ok, note = seed_sentinel(ctx)
            print("   → %s" % note)
            if not ok:
                print("   ⚠️ 哨兵没写进去。9.6 / 9.7 会因此判为不通过（它们需要库可用）。")
        else:
            print("   ⚠️ 库不存在，跳过哨兵写入")
        args.baseline_sentinels = ctx.sentinel_count()
    elif args.phase == "verify":
        args.baseline_sentinels = int(getattr(args, "baseline_sentinels", 0))

    report = Report(ctx)
    wanted = {s.strip() for s in args.only.split(",") if s.strip()} if args.only else None
    if args.phase == "watch-write" and wanted is None:
        wanted = {"9.1"}
    for key, runner, title, crit in CASE_TABLE:
        if wanted and key not in wanted:
            continue
        print("")
        print("── %s 开始 ──" % key)
        case = report.add(Case(key=key, title=title, criterion=crit))
        try:
            runner(ctx, report)
        except Exception as exc:
            import traceback

            case.fail("脚本自身跑挂：%s\n%s" % (exc, traceback.format_exc(limit=3)))
        finally:
            case.resolve()
        print("── %s 结束：%s ──" % (key, STATUS_LABEL[case.status]))

    report.print_console()
    report_write_failed = False
    try:
        with open(ctx.report_path, "w", encoding="utf-8") as fh:
            fh.write(report.to_markdown())
        print("")
        print("Markdown 报告：%s" % ctx.report_path)
        if args.phase == "prepare":
            print("下一步：人去做现场动作，然后跑 `--phase verify` 出结论。")
    except Exception as exc:
        eprint("⚠️ 报告写不出来：%s" % exc)
        report_write_failed = True

    if args.phase in ("prepare", "all"):
        manifest_path = os.path.join(ctx.data_dir, RUN_MANIFEST)
        with open(manifest_path, "w", encoding="utf-8") as fh:
            json.dump(
                {"run_id": ctx.run_id, "data_dir": ctx.data_dir,
                 "created_at": now_ms(), "schema_version": ver,
                 "baseline_sentinels": getattr(args, "baseline_sentinels", 0)},
                fh, ensure_ascii=False, indent=2,
            )

    c = report.counts()
    if report_write_failed:
        return 6
    return 1 if c[FAIL] else 0


if __name__ == "__main__":
    raise SystemExit(main())
