#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""人工实测期间的实时记录器：边用软件，边把「机器在忙什么」按秒记下来。

    # ① 打开软件，进入主界面（建议全屏，别最小化）
    # ② 另开一个窗口跑：
    python tool/perf_monitor.py run --data-dir "D:\\神算子数据" --out D:\\perf-run1
    # ③ **正常用软件，不用碰这个窗口** —— 动作按 CPU/读写自动切分，
    #    写库的动作还会从账本里查出「刚才是哪张单」
    # ④ 关掉软件 ⇒ 脚本自动收尾；看 D:\\perf-run1\\report.md
    #    （报告 §七 是「事后补全表」：把脚本猜不出的部分列成一张表，测完再填）

## 防呆三件（2026-11-03 裁定「必须选流程甲」：测试者全程不碰控制台）

1. **挂错进程 = 整轮作废** ⇒ 标题命中后**验 exe 名**，并在报告 §⓪ 用线程数/
   工作集/CPU 判「这数据到底能不能用」（第三台机器 711 个采样点全废那次）。
   `--process` 认任务管理器里显示的那个名字（FileDescription），不必是 exe 文件名。
2. **忘了记录 = 漏数据** ⇒ 不依赖按键，自动切分事件；写库动作直接查账本命名。
3. **细节说不清 = 事后补** ⇒ 报告 §七 列出每条自动事件的时间窗、CPU 峰值、
   读写量、账本里刚落的单据，留一列「你刚才在做什么」给人填。

## 它记什么（全部写进 CSV，一行一个采样点）

| 来源 | 指标 | 为什么重要 |
|---|---|---|
| 进程 | CPU（以「单核 100%」为刻度）、内存（工作集/私有）、句柄数、线程数、读写字节 | 区分「机器慢」与「软件慢」：CPU 打满 = 算法/轮询；内存一路涨 = 泄漏；句柄涨 = 资源没释放 |
| 文件 | `shensuanzi.db` / `-wal` / `-shm` 大小 | WAL 长期不归并、备份/导出把文件撑大，都在这里看得见 |
| 探针 | 三条只读查询的耗时（可选，默认关） | 把「界面卡」拆成「库慢」还是「界面重建慢」。⚠️ **不等于页面耗时**，只看趋势 —— 形状是简化版（`list` 那条尤其），见 `PROBES` 上方对照表 |
| 人工 | 每个动作的**用时**（脚本计时，不用秒表）+ 观感 1–5 + 备注 | 这是唯一能回答「用户觉得卡不卡」的数据 |
| 自检 | 采样间隔的**缺口**（gap） | 脚本自己都晚了，说明整机被压住了 —— 客观证据 |

## 三种记录方式（按现场条件挑）

1. **原地交互**（最常用）：`run` 之后在同一个窗口敲命令
   （`s 保存销售单` → 操作 → `e 3 卡了半秒`），见下方命令表。
2. **双窗口**：软件占全屏时，另开窗口用 `mark` 往同一个 spool 文件里写
   （`python tool/perf_monitor.py mark --spool D:\\perf-run1\\events.jsonl --action 保存销售单 --start`），
   `run` 会自动读进来。
3. **只采不记**：`--no-input`（采样照跑，人工动作靠 spool 或事后补）。

## 命令表（`run` 之后）

    s <动作名>        开始计时（例：s 保存销售单）
    e [观感] [备注]    结束计时；观感 1=顺畅 2=一般 3=卡顿 4=明显卡顿 5=无响应
    m <备注>          记一条瞬间观察（不配计时）
    p                立即跑一次探针
    r                打印当前摘要
    c                打印标准测试清单（看还差哪几项）
    q                结束并生成 report.md / report.html

## 判据（报告里自动标出来）

- 动作用时超过 `--slow-action`（默认 2.0 秒）⇒ 标「超过门槛」；
- 连续 ≥3 个采样点 CPU ≥ `--cpu-busy`（默认 85）⇒ 标「持续高 CPU」；
- 内存首末增长 ≥ `--rss-growth`（默认 30%）且 > 100 MB ⇒ 标「疑似泄漏」；
- 采样间隔 > 2.5 倍设定值 ⇒ 记一次 gap（整机被压住的证据）。

## 这台机器测出什么、测不出什么（2026-11-06 用户审查 §四）

**测得出**：整机有没有被压住（gap）、进程 CPU 有没有打满、内存有没有一路涨、
库文件与 WAL 的变化、每个动作**人觉得**卡不卡、库侧趋势。

**测不出**（别在报告里声称）：

1. **帧耗时 / 掉帧**。采样间隔是**自适应**的（空闲 0.5 s、忙 0.2 s），
   比一帧（16.7 ms）粗两个数量级 —— 「切页卡不卡」只能靠 `s`/`e` + 观感分，
   不能写成「帧耗时 X ms」。
2. **CPU 的绝对含义**。刻度是**单核 100%**：2 逻辑处理器的机器（VM / 低配本）
   满载会显示到 **~200%**，而 8 核机 200% 只用了 1/4。
   ⇒ **跨机器比 CPU 之前先比核数**，`--cpu-busy 85` 在 2 核机上意味着
   「一个核基本打满」，在 8 核机上意味着「八分之一都不到」。
   报告里请连同 `machine_info.py` 的逻辑处理器数一起读。
3. **渲染后端**。VM 关掉 3D 加速后，Flutter 实际用哪条渲染路径**未确认**
   （`main.cpp` 里没有 Impeller 开关，SDK 3.41.1 也还没到 Windows 默认 Impeller
   的版本）。所以低配 VM 的帧耗时/切页数据**不能代表正常目标机**，
   只能回答「2 vCPU / 4 GB 下这软件还能不能用」。

## 依赖

Python 3.8+，只用标准库（Windows 侧用 `ctypes` 读进程计数器，不装 psutil）。
非 Windows 上仍可用，但只有文件大小与探针，进程指标为 `—`。

> ⚠️ 本脚本**绝不修改**数据库：探针用 `mode=ro` 打开，只读。
> 它也不会启动/结束软件进程 —— 谁开的谁关，避免把「强杀」误算成一次「崩溃」。
"""

from __future__ import annotations

import argparse
import csv
import ctypes
import json
import os
import platform

import machine_info
import queue
import sqlite3
import statistics
import sys
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

DATA_FILE_NAME = "shensuanzi.db"

#: 标准动作清单：报告里用它算「覆盖了几项」。
#: 顺序照真实使用顺序：先冷启动，再查，再开单，再收钱，最后导/备份。
CHECKLIST: Tuple[Tuple[str, str], ...] = (
    ("冷启动", "双击打开软件 → 进到主界面（第一次打开，page cache 是空的）"),
    ("概览页", "看「今日销售 / 要留心」三张卡是否立刻出来"),
    ("库存页", "进库存页，等列表出来（商品多时最吃力）"),
    ("库存页搜索", "在库存页搜索框连打 5 个字符"),
    ("单据页首屏", "进单据页，默认范围，等列表出来"),
    ("单据页搜索", "在单据页搜索框连打 5 个字符"),
    ("单据详情", "点开一张有明细的单"),
    ("商品页搜索", "进商品页，连打 5 个字符"),
    ("往来方页", "进往来方页（余额列要算）"),
    ("账户页", "进账户页 → 点开一个账户的流水"),
    ("销售开单", "销售开单：选客户 → 选 3 个商品 → 改数量 → 保存"),
    ("采购开单", "采购入库：选商品 → 填进价 → 保存"),
    ("送货开单", "送货：选客户 → 保存（会扣库存）"),
    ("收款核销", "单据详情 → 收款 → 确认"),
    ("退货", "单据详情 → 退货 → 填数量 → 保存"),
    ("导出 CSV", "单据页 → 导出"),
    ("立即备份", "概览/设置 → 立即备份"),
    ("二次冷启动", "关掉软件再打开（这次 page cache 是热的）"),
)

#: 单据类型 → 中文名。**与 `packages/shensuanzi_core/lib/src/models/document.dart`
#: 的 `DocType.label` 逐字一致**（纪律 17：描述要跟实现一致）。
#: 只用来给「自动识别」的事件贴名字，不参与任何计算。
DOC_TYPE_LABEL: Dict[str, str] = {
    "purchase": "采购入库",
    "sale": "店内销售",
    "delivery": "送货",
    "sale_return": "销售退货",
    "purchase_return": "采购退货",
    "stocktake": "盘点",
    "receipt": "收款",
    "payment": "付款",
    "transfer": "调拨",
}

FEEL_LABEL: Dict[int, str] = {

    1: "顺畅",
    2: "一般",
    3: "卡顿",
    4: "明显卡顿",
    5: "无响应/卡死",
}

SAMPLE_COLUMNS: Tuple[str, ...] = (
    "ts",
    "epoch_ms",
    "interval_ms",
    "gap_ms",
    "cpu_pct",
    "rss_mb",
    "private_mb",
    "handles",
    "threads",
    "io_read_mb",
    "io_write_mb",
    "db_mb",
    "wal_mb",
    "shm_mb",
    "rows_documents",
    "rows_stock_ledger",
    "rows_settlements",
    "probe_stock_ms",
    "probe_list_ms",
    "probe_window_ms",
    # ---- 自动识别用（2026-10-27）：增量按「本采样区间」算，不依赖累计值
    "read_kb",
    "write_kb",
    "busy",
    "event_id",
    "fg_title",
    "pid",
    "note",
)

EVENT_COLUMNS: Tuple[str, ...] = (
    "ts",
    "epoch_ms",
    "kind",
    "name",
    "duration_s",
    "feel",
    "note",
    # ---- 2026-10-27：`source` 区分「脚本自己发现的」与「人按的」，
    # 报告里两者分开展示，绝不把推断冒充成人工确认。
    "source",
    "peak_cpu",
    "read_mb",
    "write_mb",
)


# --------------------------------------------------------------------------- 窗口发现

#: 主窗口标题（`windows/runner/main.cpp` 里写死的那一个）。
#: 找进程时**优先按它匹配**，不靠 exe 名 —— 测试机上软件可能被改名。
WINDOW_KEYWORD = "神算子"


class _WindowsWindow:
    """按**窗口标题**找应用进程，并读「前台窗口是谁」。

    ## 为什么不能只靠 exe 名（2026-10-27 实地反馈）

    测试机上软件可能被改名（绿色版 / 换个名字分发），`--process shensuanzi.exe`
    找不到就**静默没有进程指标**，测试人员只看到一列 `—`，还以为脚本坏了。
    窗口标题是唯一稳定信号：主窗口标题恒为「神算子」。

    顺带提供前台窗口标题 —— 用来判断「这段时间人是不是在软件里」，
    避免把「用户切去回微信」算成软件卡。
    """

    def __init__(self) -> None:
        self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        self.user32.GetForegroundWindow.restype = ctypes.c_void_p
        self.user32.IsWindowVisible.argtypes = [ctypes.c_void_p]
        self.user32.GetWindowTextLengthW.argtypes = [ctypes.c_void_p]
        self.user32.GetWindowTextW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
        self.user32.GetWindowThreadProcessId.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_ulong),
        ]

    def _title(self, hwnd: int) -> str:
        length = self.user32.GetWindowTextLengthW(hwnd)
        if not length or length <= 0:
            return ""
        buf = ctypes.create_unicode_buffer(length + 1)
        self.user32.GetWindowTextW(hwnd, buf, length + 1)
        return buf.value

    def foreground_title(self) -> str:
        """当前前台窗口的标题（拿不到就是空串）。"""
        hwnd = self.user32.GetForegroundWindow()
        return self._title(hwnd) if hwnd else ""

    def top_windows(self) -> List[Tuple[int, int, str]]:
        """`[(hwnd, pid, title)]`，只含**可见且有标题**的顶层窗口。"""
        found: List[Tuple[int, int, str]] = []
        enum_proc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

        def _callback(hwnd: Any, _lparam: Any) -> bool:
            if not self.user32.IsWindowVisible(hwnd):
                return True
            title = self._title(hwnd)
            if not title:
                return True
            pid = ctypes.c_ulong(0)
            self.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            found.append((int(hwnd or 0), int(pid.value), title))
            return True

        self.user32.EnumWindows(enum_proc(_callback), 0)
        return found


def _exe_norm(name: str) -> str:
    """exe 名 / 任务管理器显示名 → 可比较的形态（小写、去 .exe、去空格标点）。"""
    s = (name or "").strip().lower()
    if s.endswith(".exe"):
        s = s[: -len(".exe")]
    return "".join(ch for ch in s if ch.isalnum())


def exe_name_matches(candidate: str, want: str) -> bool:
    """`candidate` 是否就是 `want` 指的那个程序。

    ## 为什么不直接比字符串（2026-11-03 用户实地指出）

    任务管理器「名称」列显示的是 exe 版本资源里的 **FileDescription**，
    不是 exe 文件名。神算子的 exe 是 `shensuanzi.exe`
    （`windows/../CMakeLists.txt` 的 `BINARY_NAME`），任务管理器里却是
    **「Shensuanzi - Inventory & Bookkeeping」**（`windows/runner/Runner.rc`
    的 FileDescription）。测试者照任务管理器抄名字填给 `--process` 是**最自然
    的做法** —— 他已经打开了正确的程序，只比文件名会把他挡在门外。

    所以判据放宽成「归一化后互相包含」：`shensuanzi.exe` 与
    `Shensuanzi - Inventory & Bookkeeping` 都归一到 `shensuanzi…` 前缀 ⇒ 认。
    ⚠️ 这是**放宽匹配**，代价是理论上可能误认（如 `shensuanzi_updater`）；
    权衡是「挂错进程」由 `sanity_check` 兜底，而「挂不上」直接毁掉一整轮实测。
    """
    a, b = _exe_norm(candidate), _exe_norm(want)
    if not a or not b:
        return False
    return a == b or (len(a) >= 6 and (a in b or b in a))


def discover_app(
    proc: Optional["_WindowsProcess"],
    window: Optional["_WindowsWindow"],
    keyword: str,
    exe_hint: str,
    exe_verifier: Optional[Callable[[int], str]] = None,
) -> Tuple[int, str, str, str]:
    """找软件进程。返回 `(pid, 依据, 窗口标题, 警告)`；找不到 = `(0, "", "", 警告)`。

    顺序：**① 窗口标题含关键词**（不怕软件改名）→ ② exe 名（兜底，
    比如软件最小化到托盘、窗口标题被临时改掉）。

    ## 为什么标题命中后还要**验 exe 名**（2026-11-02，第三台机器）

    标题匹配是**字符串包含**，会撞车：浏览器标签页写着「神算子」、
    记事本打开一个叫「神算子」的文档，都会命中。第三台机器就挂到了
    别的进程上，跑完 711 个采样点才发现 CPU 全程 0.0%、工作集 4.9 MB、
    1 个线程 —— 整轮数据作废，而脚本从头到尾一声不吭。

    现在：**标题命中但 exe 名对不上 ⇒ 不挂**，继续找下一个候选，
    最后退回按 exe 名找，并把「跳过了哪些标题」写进警告。
    判据用 exe 名而不是 CPU/内存阈值 —— 后者是猜，exe 名是事实。

    `exe_verifier=None`（非 Windows、或 `--no-exe-check`）⇒ 退回旧行为，
    并在警告里说明「没验 exe 名」。
    """
    warn = ""
    if window is not None and keyword:
        hits = [w for w in window.top_windows() if keyword in w[2]]
        if exe_verifier is None:
            if hits:
                _hwnd, pid, title = hits[0]
                if exe_hint:
                    warn = "没验 exe 名（非 Windows 或 --no-exe-check）—— 标题撞车会挂错进程"
                return pid, "窗口标题含「%s」" % keyword, title, warn
        else:
            want = (exe_hint or "").strip()
            skipped: List[str] = []
            for _hwnd, pid, title in hits:
                got = exe_verifier(pid)
                if not want or not got or exe_name_matches(got, want):
                    return pid, "窗口标题含「%s」" % keyword, title, warn
                skipped.append("「%s」→ %s" % (title, got))
            if skipped:
                warn = (
                    "有窗口标题含「%s」但 exe 不是 %s，已跳过：%s。"
                    % (keyword, exe_hint, "；".join(skipped))
                )
    if proc is not None and exe_hint:
        pid = proc.find_by_name(exe_hint)
        if pid:
            return pid, "进程名 %s" % exe_hint, "", warn
    if not warn:
        warn = "没找到标题含「%s」的窗口，也没有 %s 进程 —— 先把软件打开" % (keyword, exe_hint or "对应 exe")
    return 0, "", "", warn


# --------------------------------------------------------------------------- 挂接体检


#: Flutter 桌面应用**不可能**只有这么点线程：UI + raster + IO + platform
#: 至少 4–5 个，加上 Dart VM / sqlite 更多。1 个线程 ⇒ 挂到的绝不是软件。
MIN_PLAUSIBLE_THREADS = 3
#: Flutter 桌面应用工作集不可能低于这个量级（引擎 + 字体 + 首屏）。
MIN_PLAUSIBLE_RSS_MB = 40.0


def sanity_check(
    samples: Sequence[Dict[str, Any]],
    min_threads: int = MIN_PLAUSIBLE_THREADS,
    min_rss_mb: float = MIN_PLAUSIBLE_RSS_MB,
) -> List[str]:
    """跑完之后回答一句人话：**「这些进程指标是不是真的？」**

    ## 为什么必须有这一步（2026-11-02，第三台机器）

    那一轮 711 个采样点，CPU 全程 0.0%、工作集 4.9 MB、1 个线程、74 个句柄。
    报告照样生成得漂漂亮亮，测试人员照样交回来 —— 因为**没有任何一步说
    「这不可能」**。挂错进程时指标不是「缺失」而是「看起来正常地很小」，
    人眼扫过去根本不会起疑。

    ## 判据（只用「物理上不可能」的事实，不用「我觉得慢」）

    | 现象 | 结论 |
    |---|---|
    | 有采样点，但**一个都没有**进程指标 | 全程没挂上进程 ⇒ 只有库体积可用 |
    | 线程数中位数 < `min_threads` | 挂到的不是 Flutter 应用 |
    | 工作集中位数 < `min_rss_mb` | 同上（Flutter 桌面版不可能这么小） |
    | CPU **全程** ≤ 0.05% 且全程无读无写 | 那个进程根本没干活 ⇒ 大概率挂错 |

    最后一条要**同时**满足「无 CPU 且无读写」才报警：软件开着不动时确实
    CPU≈0，但那时也没有 IO；一旦有 IO 就说明进程在动、CPU 0 只是采样窗口太短。

    返回**空列表 = 没发现问题**。返回的是给人看的句子，不是错误码。
    """
    if not samples:
        return ["一个采样点都没有 —— 本轮没有任何数据。"]

    def vals(key: str) -> List[float]:
        out: List[float] = []
        for s in samples:
            v = s.get(key)
            if v in ("", None):
                continue
            try:
                out.append(float(v))
            except (TypeError, ValueError):
                pass
        return out

    problems: List[str] = []
    cpu = vals("cpu_pct")
    if not cpu:
        problems.append(
            "全程没有进程指标（CPU / 内存 / 线程全空）⇒ 一直没挂上软件进程，"
            "本轮只有库体积与前台窗口可用。"
        )
        return problems

    threads = vals("threads")
    rss = vals("rss_mb")
    if threads and percentile(threads, 0.5) < min_threads:
        problems.append(
            "线程数中位数只有 %.0f（Flutter 桌面应用至少 %d 个）⇒ **挂到的进程多半不是软件**，"
            "本轮进程指标作废。" % (percentile(threads, 0.5), min_threads)
        )
    if rss and percentile(rss, 0.5) < min_rss_mb:
        problems.append(
            "工作集中位数只有 %.1f MB（Flutter 桌面应用不可能这么小）⇒ **挂到的进程多半不是软件**。"
            % percentile(rss, 0.5)
        )
    reads = vals("read_kb")
    writes = vals("write_kb")
    ever_moved = max(reads or [0.0]) > 0 or max(writes or [0.0]) > 0
    if max(cpu) <= 0.05 and not ever_moved:
        problems.append(
            "CPU 全程 ≤ 0.05% 且全程零读写 ⇒ 那个进程整轮没干过任何事，"
            "**几乎可以确定挂错了**（软件被操作过就不可能一次读写都没有）。"
        )
    return problems


# --------------------------------------------------------------------------- 动作自动识别


class ActionDetector:
    """从采样序列里**自动识别「用户做了一次操作」**，不靠人按键。

    ## 为什么要它（2026-10-27 实地反馈）

    用户原话：「不能自动记录用户操作，导致大部分性能数据都要测试人员手动记录，
    出来的数据基本不可信」。手动 `s`/`e` 有两个硬伤：

    1. 人按秒表的误差本身就有 0.3–0.5 秒，跟要测的 200 ms 卡顿**同量级**；
    2. 一紧张就忘了按，事后补记的时间是**编的**。

    ## 它看什么信号

    软件窗口标题是固定的（「神算子」），**看不出在哪个页面**。所以这里不猜页面名，
    只认「**机器在忙**」这一段：用户点了一下，页面要读库、要重建，CPU 与读字节
    就会跳；保存单据会写库。

    | 信号 | 含义 |
    |---|---|
    | `cpu_pct` ≥ `busy_cpu` | 在算（重建列表 / 聚合） |
    | `read_kb` ≥ `read_kb` | 在读库（页面加载） |
    | `write_kb` ≥ `write_kb` | 在写库（保存 / 开单 / 备份） |

    连续「忙」的采样段 = 一次操作；中间空闲 ≥ `idle_gap` 秒才算两次
    （用户连点两下本来就是一个动作）。

    ## 诚实边界

    它给的是「**这段时间机器在忙**」，不是「用户点了库存页」。所以报告里标
    「自动识别」，**不冒充**人工确认的动作名；想贴名字仍可 `s <动作名>`，
    报告会把两者对齐并给出偏差（§二之一）。

    这个类是**纯逻辑**（只吃 dict、只吐 dict），所以 `selftest` 能用合成序列
    直接钉住它 —— 不用真开软件。
    """

    def __init__(
        self,
        busy_cpu: float = 25.0,
        read_kb: float = 2048.0,
        write_kb: float = 256.0,
        idle_gap: float = 1.5,
        min_duration: float = 0.10,
    ) -> None:
        self.busy_cpu = busy_cpu
        self.read_kb = read_kb
        self.write_kb = write_kb
        self.idle_gap = idle_gap
        self.min_duration = min_duration
        self._open: Optional[Dict[str, Any]] = None
        self._last_busy_ms = 0
        self._seq = 0
        self.events: List[Dict[str, Any]] = []

    @property
    def in_burst(self) -> bool:
        """当前是不是正处在一个「忙」段里（采样循环据此切到快速档）。"""
        return self._open is not None

    @property
    def current_id(self) -> int:
        """当前这段忙会被记成几号事件（写进 samples.csv 的 `event_id`）。"""
        return self._seq + 1 if self._open is not None else 0

    def is_busy(self, sample: Dict[str, Any]) -> bool:
        cpu = sample.get("cpu_pct")
        read_kb = sample.get("read_kb") or 0
        write_kb = sample.get("write_kb") or 0
        return bool(
            (isinstance(cpu, (int, float)) and float(cpu) >= self.busy_cpu)
            or float(read_kb) >= self.read_kb
            or float(write_kb) >= self.write_kb
        )

    def feed(self, sample: Dict[str, Any]) -> List[Dict[str, Any]]:
        """喂一个采样点；返回**刚刚闭合**的事件（0 或 1 个）。"""
        closed: List[Dict[str, Any]] = []
        ms = int(sample.get("epoch_ms") or 0)
        cpu = sample.get("cpu_pct")
        read_kb = float(sample.get("read_kb") or 0)
        write_kb = float(sample.get("write_kb") or 0)
        busy = self.is_busy(sample)
        sample["busy"] = 1 if busy else 0

        if busy:
            if self._open is None:
                self._open = {
                    "start_ms": ms,
                    "end_ms": ms,
                    "last_interval_ms": int(sample.get("interval_ms") or 0),
                    "peak_cpu": float(cpu) if isinstance(cpu, (int, float)) else 0.0,
                    "read_kb": read_kb,
                    "write_kb": write_kb,
                    "samples": 1,
                }
            else:
                self._open["end_ms"] = ms
                self._open["last_interval_ms"] = int(sample.get("interval_ms") or 0)
                if isinstance(cpu, (int, float)):
                    self._open["peak_cpu"] = max(self._open["peak_cpu"], float(cpu))
                self._open["read_kb"] += read_kb
                self._open["write_kb"] += write_kb
                self._open["samples"] += 1
            self._last_busy_ms = ms
            return closed

        if self._open is not None and (ms - self._last_busy_ms) / 1000.0 >= self.idle_gap:
            event = self._close()
            if event is not None:
                closed.append(event)
        return closed

    def flush(self) -> List[Dict[str, Any]]:
        """收尾：把还开着的那个事件闭合。"""
        event = self._close()
        return [] if event is None else [event]

    def _close(self) -> Optional[Dict[str, Any]]:
        item = self._open
        self._open = None
        if not item:
            return None
        # 结束时刻取「最后一个忙采样 + 该采样的间隔」—— 否则 300 ms 的动作
        # 在 200 ms 采样下会被算成 200 ms（少一个间隔）。
        span_ms = int(item["end_ms"]) - int(item["start_ms"]) + int(item["last_interval_ms"])
        duration = max(0.0, span_ms / 1000.0)
        # 噪声过滤：**只有一个采样点、且没有任何读写证据** ⇒ 丢掉。
        # 依据：真实操作（点一下页面 / 保存）必然读库或写库；纯 CPU 的单点尖峰
        # 多半是 GC、杀软扫描、采样抖动 —— 当成操作会把「次数」灌水（自检场景 F）。
        if item["samples"] <= 1 and item["read_kb"] < self.read_kb and item["write_kb"] < self.write_kb:
            return None
        if duration < self.min_duration:
            return None
        self._seq += 1
        kind = (
            "写库"
            if item["write_kb"] >= self.write_kb
            else "读库/界面重建"
        )
        event = {
            "id": self._seq,
            "start_ms": int(item["start_ms"]),
            "end_ms": int(item["end_ms"]),
            "duration_s": round(duration, 2),
            "kind": kind,
            "peak_cpu": round(item["peak_cpu"], 1),
            "read_mb": round(item["read_kb"] / 1024.0, 2),
            "write_mb": round(item["write_kb"] / 1024.0, 2),
            "samples": int(item["samples"]),
        }
        self.events.append(event)
        return event


# --------------------------------------------------------------------------- 进程指标

class _WindowsProcess:
    """用 ctypes 读进程计数器。任何一步失败都返回 None（不影响主流程）。"""

    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    PROCESS_QUERY_INFORMATION = 0x0400
    PROCESS_VM_READ = 0x0010
    TH32CS_SNAPPROCESS = 0x00000002
    TH32CS_SNAPTHREAD = 0x00000004
    INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

    class PROCESS_MEMORY_COUNTERS_EX(ctypes.Structure):
        _fields_ = [
            ("cb", ctypes.c_ulong),
            ("PageFaultCount", ctypes.c_ulong),
            ("PeakWorkingSetSize", ctypes.c_size_t),
            ("WorkingSetSize", ctypes.c_size_t),
            ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
            ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
            ("PagefileUsage", ctypes.c_size_t),
            ("PeakPagefileUsage", ctypes.c_size_t),
            ("PrivateUsage", ctypes.c_size_t),
        ]

    class PROCESSENTRY32(ctypes.Structure):
        _fields_ = [
            ("dwSize", ctypes.c_ulong),
            ("cntUsage", ctypes.c_ulong),
            ("th32ProcessID", ctypes.c_ulong),
            ("th32DefaultHeapID", ctypes.c_void_p),
            ("th32ModuleID", ctypes.c_ulong),
            ("cntThreads", ctypes.c_ulong),
            ("th32ParentProcessID", ctypes.c_ulong),
            ("pcPriClassBase", ctypes.c_long),
            ("dwFlags", ctypes.c_ulong),
            ("szExeFile", ctypes.c_char * 260),
        ]

    class THREADENTRY32(ctypes.Structure):
        _fields_ = [
            ("dwSize", ctypes.c_ulong),
            ("cntUsage", ctypes.c_ulong),
            ("th32ThreadID", ctypes.c_ulong),
            ("th32OwnerProcessID", ctypes.c_ulong),
            ("tpBasePri", ctypes.c_long),
            ("tpDeltaPri", ctypes.c_long),
            ("dwFlags", ctypes.c_ulong),
        ]

    class IO_COUNTERS(ctypes.Structure):
        _fields_ = [
            ("ReadOperationCount", ctypes.c_ulonglong),
            ("WriteOperationCount", ctypes.c_ulonglong),
            ("OtherOperationCount", ctypes.c_ulonglong),
            ("ReadTransferCount", ctypes.c_ulonglong),
            ("WriteTransferCount", ctypes.c_ulonglong),
            ("OtherTransferCount", ctypes.c_ulonglong),
        ]

    def __init__(self) -> None:
        self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.psapi = ctypes.WinDLL("psapi", use_last_error=True)
        self._handle = None
        self.pid = 0
        self._last_cpu: Optional[float] = None
        self._last_wall: Optional[float] = None

    # -- 找进程
    def find_by_name(self, exe_name: str) -> Optional[int]:
        """按 exe 名找 PID。也接受任务管理器显示名（FileDescription）。

        见 `exe_name_matches`：测试者从任务管理器抄到的是
        「Shensuanzi - Inventory & Bookkeeping」而不是 `shensuanzi.exe`，
        照字面填进来必须能用，否则等于把他挡在门外。
        """
        snapshot = self.kernel32.CreateToolhelp32Snapshot(self.TH32CS_SNAPPROCESS, 0)
        if not snapshot or snapshot == self.INVALID_HANDLE_VALUE:
            return None
        try:
            entry = self.PROCESSENTRY32()
            entry.dwSize = ctypes.sizeof(self.PROCESSENTRY32)
            ok = self.kernel32.Process32First(snapshot, ctypes.byref(entry))
            target = exe_name.lower()
            while ok:
                name = entry.szExeFile.decode("mbcs", "replace").lower()
                # 先精确比（默认 `shensuanzi.exe` 走这条，行为与从前一致），
                # 再放宽比（用户手填任务管理器显示名走这条）
                if name == target or exe_name_matches(name, exe_name):
                    return int(entry.th32ProcessID)
                ok = self.kernel32.Process32Next(snapshot, ctypes.byref(entry))
            return None
        finally:
            self.kernel32.CloseHandle(snapshot)

    def exe_by_pid(self, pid: int) -> str:
        """PID → exe 文件名（小写）。拿不到返回空串。

        这是「挂错进程」的**唯一硬判据**：窗口标题会撞车（浏览器标签页、
        记事本里打开一个叫「神算子」的文档，标题里都有「神算子」），
        exe 名不会。2026-11-02 第三台机器就是这么挂错的 —— 全程 CPU 0.0%、
        工作集 4.9 MB、1 个线程，711 个采样点**全部作废**，而脚本一声不吭。
        """
        if not pid:
            return ""
        snapshot = self.kernel32.CreateToolhelp32Snapshot(self.TH32CS_SNAPPROCESS, 0)
        if not snapshot or snapshot == self.INVALID_HANDLE_VALUE:
            return ""
        try:
            entry = self.PROCESSENTRY32()
            entry.dwSize = ctypes.sizeof(self.PROCESSENTRY32)
            ok = self.kernel32.Process32First(snapshot, ctypes.byref(entry))
            while ok:
                if int(entry.th32ProcessID) == int(pid):
                    return entry.szExeFile.decode("mbcs", "replace").lower()
                ok = self.kernel32.Process32Next(snapshot, ctypes.byref(entry))
            return ""
        finally:
            self.kernel32.CloseHandle(snapshot)

    def open(self, pid: int) -> bool:
        access = (
            self.PROCESS_QUERY_INFORMATION | self.PROCESS_VM_READ | self.PROCESS_QUERY_LIMITED_INFORMATION
        )
        handle = self.kernel32.OpenProcess(access, False, pid)
        if not handle:
            access = self.PROCESS_QUERY_LIMITED_INFORMATION
            handle = self.kernel32.OpenProcess(access, False, pid)
        if not handle:
            return False
        self._handle = handle
        self.pid = pid
        return True

    def close(self) -> None:
        if self._handle:
            self.kernel32.CloseHandle(self._handle)
            self._handle = None

    # -- 指标
    def cpu_seconds(self) -> Optional[float]:
        if not self._handle:
            return None
        creation = ctypes.c_ulonglong()
        exit_t = ctypes.c_ulonglong()
        kernel = ctypes.c_ulonglong()
        user = ctypes.c_ulonglong()
        ok = self.kernel32.GetProcessTimes(
            self._handle,
            ctypes.byref(creation),
            ctypes.byref(exit_t),
            ctypes.byref(kernel),
            ctypes.byref(user),
        )
        if not ok:
            return None
        return (kernel.value + user.value) / 1e7

    def cpu_pct(self) -> Optional[float]:
        now_cpu = self.cpu_seconds()
        now_wall = time.monotonic()
        if now_cpu is None:
            return None
        pct = None
        if self._last_cpu is not None and self._last_wall is not None:
            delta_cpu = now_cpu - self._last_cpu
            delta_wall = max(1e-6, now_wall - self._last_wall)
            # ⚠️ 进程重启 / 换了句柄 ⇒ 累计 CPU 归零 ⇒ 差值是负数。
            # 2026-10-28 实测跑出过 -1895.8%（报告里那个「最小 CPU」）。
            # 负值没有任何物理意义，夹到 0。
            pct = max(0.0, 100.0 * delta_cpu / delta_wall)
        self._last_cpu = now_cpu
        self._last_wall = now_wall
        return pct

    def memory(self) -> Tuple[Optional[float], Optional[float]]:
        if not self._handle:
            return None, None
        counters = self.PROCESS_MEMORY_COUNTERS_EX()
        counters.cb = ctypes.sizeof(self.PROCESS_MEMORY_COUNTERS_EX)
        ok = self.psapi.GetProcessMemoryInfo(
            self._handle, ctypes.byref(counters), counters.cb
        )
        if not ok:
            return None, None
        return (
            counters.WorkingSetSize / (1024.0 * 1024.0),
            counters.PrivateUsage / (1024.0 * 1024.0),
        )

    def handles(self) -> Optional[int]:
        if not self._handle:
            return None
        count = ctypes.c_ulong()
        ok = self.kernel32.GetProcessHandleCount(self._handle, ctypes.byref(count))
        return int(count.value) if ok else None

    def io_mb(self) -> Tuple[Optional[float], Optional[float]]:
        if not self._handle:
            return None, None
        counters = self.IO_COUNTERS()
        ok = self.kernel32.GetProcessIoCounters(self._handle, ctypes.byref(counters))
        if not ok:
            return None, None
        return (
            counters.ReadTransferCount / (1024.0 * 1024.0),
            counters.WriteTransferCount / (1024.0 * 1024.0),
        )

    STILL_ACTIVE = 259

    def alive(self) -> bool:
        """进程还在不在（**用来发现「用户重启了软件」**）。

        ⚠️ 用 `GetExitCodeProcess` 而不是 `WaitForSingleObject`：
        后者要求句柄带 `SYNCHRONIZE` 权限，而 `open()` 没申请它 ⇒ 调用失败、
        恒返回「已退出」⇒ 采样循环每轮都重新挂接、把 IO 增量清零
        （2026-10-27 实测：`read_kb` 一直是 0，就是这条引起的）。
        """
        if not self._handle:
            return False
        code = ctypes.c_ulong(0)
        if not self.kernel32.GetExitCodeProcess(self._handle, ctypes.byref(code)):
            return False
        return code.value == self.STILL_ACTIVE

    def threads(self) -> Optional[int]:
        snapshot = self.kernel32.CreateToolhelp32Snapshot(self.TH32CS_SNAPTHREAD, 0)
        if not snapshot or snapshot == self.INVALID_HANDLE_VALUE:
            return None
        try:
            entry = self.THREADENTRY32()
            entry.dwSize = ctypes.sizeof(self.THREADENTRY32)
            ok = self.kernel32.Thread32First(snapshot, ctypes.byref(entry))
            count = 0
            while ok:
                if int(entry.th32OwnerProcessID) == self.pid:
                    count += 1
                ok = self.kernel32.Thread32Next(snapshot, ctypes.byref(entry))
            return count
        finally:
            self.kernel32.CloseHandle(snapshot)


# --------------------------------------------------------------------------- 探针
#
# ⚠️⚠️ **探针只是「库侧趋势」，不是页面真实耗时**（2026-11-06 用户审查 §三·3）。
#
# 三条探针的形状**故意**是简化版 —— 它们回答的是「这一刻库有多快」，用来把
# 「界面卡」拆成「库慢」还是「界面重建慢」。它们**不等于**对应页面的耗时：
#
# | 探针 | 它测的 | 页面**实际**跑的 | 差在哪 |
# |---|---|---|---|
# | `stock` | `stock_ledger` 全表 GROUP BY | 库存页 `stockAggregates()` | 页面那条还带「进过货」的 `MAX(CASE…)`，略贵 |
# | `list` | 单段取 id，**表达式**排序、**无** roots 过滤 | 单据页 `listDocuments(rootsOnly)` **两段** + `business_day` 索引 | 三处都不同，**数字不可当首屏耗时引用** |
# | `window` | `updated_at > ?` 一页 | `pull` 的最近更新窗口 | 基本同形 |
#
# 所以：**报告里 `probe_list_ms` 绝不能写成「单据页首屏耗时」**。要那个数字，
# 用 `perf_bench.py --only list_roots`（与 DAO 逐字同形），或用 monitor 的
# `s` / `e` 人工标记量真实动作。
#
# 为什么仍保留旧形状而不改成与 bench 一致：探针**每 60 秒在采样循环里跑**，
# 换成两段 + 全量聚合会给被监测进程多加 I/O，反而污染正在测的东西。
# 结论：**趋势看探针，绝对值看 bench，主观卡不卡看 `s`/`e`。**

PROBES: Tuple[Tuple[str, str], ...] = (
    (
        "stock",
        "SELECT product_id, COALESCE(SUM(quantity), 0) FROM stock_ledger GROUP BY product_id",
    ),
    (
        # ⚠️ 见上方表格：这条**不是**单据页首屏（表达式排序 + 无 roots 过滤 + 单段）。
        # 保持旧形状是有意的（省 I/O），别拿它的数字去和 bench 的 `list_roots` 比。
        "list",
        "SELECT d.id FROM documents d LEFT JOIN parties pa ON pa.id = d.party_id "
        "ORDER BY ((d.occurred_at + 28800000) / 86400000) DESC, d.created_at DESC LIMIT 200",
    ),
    (
        "window",
        "SELECT id FROM documents WHERE updated_at > ? ORDER BY updated_at, id LIMIT 500",
    ),
)


def run_probes(db_path: str, window_ms: int) -> Dict[str, Optional[float]]:
    """只读探针：量「库在这一刻有多快」。失败返回 None，不打断采样。"""
    out: Dict[str, Optional[float]] = {name: None for name, _sql in PROBES}
    if not os.path.isfile(db_path):
        return out
    try:
        uri = "file:%s?mode=ro" % db_path.replace("\\", "/")
        conn = sqlite3.connect(uri, uri=True, timeout=2.0)
    except sqlite3.Error:
        return out
    try:
        conn.execute("PRAGMA busy_timeout = 2000")
        since = int(time.time() * 1000) - window_ms
        for name, sql in PROBES:
            params: Tuple[Any, ...] = (since,) if name == "window" else ()
            try:
                best = None
                for _ in range(2):  # 取较快的一次，减少抖动
                    t0 = time.perf_counter()
                    conn.execute(sql, params).fetchall()
                    ms = (time.perf_counter() - t0) * 1000.0
                    best = ms if best is None else min(best, ms)
                out[name] = round(best, 2) if best is not None else None
            except sqlite3.Error:
                out[name] = None
    finally:
        conn.close()
    return out


# --------------------------------------------------------------------------- 会话

def mb(path: str) -> float:
    try:
        return round(os.path.getsize(path) / (1024.0 * 1024.0), 2)
    except OSError:
        return 0.0


def percentile(values: Sequence[float], p: float) -> float:
    if not values:
        return 0.0
    data = sorted(values)
    if len(data) == 1:
        return data[0]
    k = (len(data) - 1) * p
    low = int(k)
    high = min(low + 1, len(data) - 1)
    return data[low] + (data[high] - data[low]) * (k - low)


class Session:
    def __init__(self, args: argparse.Namespace, db_path: str) -> None:
        self.args = args
        self.db_path = db_path
        self.out_dir = os.path.abspath(args.out)
        os.makedirs(self.out_dir, exist_ok=True)
        self.samples_path = os.path.join(self.out_dir, "samples.csv")
        self.events_path = os.path.join(self.out_dir, "events.csv")
        self.spool_path = os.path.abspath(args.spool) if args.spool else None
        self.started = time.time()
        self.started_iso = time.strftime("%Y-%m-%dT%H:%M:%S")
        self.samples: List[Dict[str, Any]] = []
        self.events: List[Dict[str, Any]] = []
        self.actions: Dict[str, float] = {}  # 动作名 → 开始时刻（monotonic）
        self.action_records: List[Dict[str, Any]] = []
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self._sample_file = open(self.samples_path, "w", encoding="utf-8-sig", newline="")
        self._sample_writer = csv.DictWriter(self._sample_file, fieldnames=list(SAMPLE_COLUMNS))
        self._sample_writer.writeheader()
        self._event_file = open(self.events_path, "w", encoding="utf-8-sig", newline="")
        self._event_writer = csv.DictWriter(self._event_file, fieldnames=list(EVENT_COLUMNS))
        self._event_writer.writeheader()
        self._last_sample_wall: Optional[float] = None
        self._spool_pos = 0
        self._spool_buf = ""
        self.notes: List[str] = []
        self.proc = _WindowsProcess() if os.name == "nt" else None
        self.window = _WindowsWindow() if os.name == "nt" else None
        self.pid = 0
        self._proc_warned = False
        # ---- 自动识别（2026-10-27）
        self.detector = ActionDetector(
            busy_cpu=args.busy_cpu,
            read_kb=args.busy_read_kb,
            write_kb=args.busy_write_kb,
            idle_gap=args.idle_gap,
        )
        self.auto_events: List[Dict[str, Any]] = []
        self.attach_reason = ""
        self.window_title = ""
        # 挂接过的 PID 历史（换过就说明重启过）—— 报告用它，而不是「此刻的 pid」
        self.pid_history: List[int] = []
        self._prev_io: Optional[Tuple[float, float]] = None
        self._fast_until = 0.0
        # 「没找到窗口」限流：每 30 秒最多说一次（每轮都刷会把终端冲掉）
        self._last_warn = 0.0
        self._last_probe = 0.0
        self._attach()

    # -- 进程挂接
    def _attach(self) -> None:
        if self.args.pid:
            pid = int(self.args.pid)
            if self.proc and self.proc.open(pid):
                self.pid = pid
                self.attach_reason = "--pid 指定"
                # --pid 也要验 exe 名：手填 PID 填错（挂到浏览器/资源管理器）
                # 和标题撞车是同一类事故，判据也一样是 exe 名。
                if not self.args.no_exe_check:
                    got = self.proc.exe_by_pid(pid)
                    self.attach_reason += "（exe %s）" % (got or "未知")
                    want = (self.args.process or "").lower()
                    if got and want and got != want:
                        msg = (
                            "--pid %d 的进程是 %s，不是 %s —— 进程指标大概率不是软件的！"
                            % (pid, got, self.args.process)
                        )
                        print("⛔ %s" % msg)
                        self.notes.append("%s ⛔ %s" % (time.strftime("%H:%M:%S"), msg))
                        self.record_event("attach_warning", msg, source="auto")
            else:
                print("⚠️ 打不开 PID %s 的进程（权限？）—— 进程指标将为 —" % self.args.pid)
            return
        if self.proc is None and self.window is None:
            return
        self._try_discover(announce=True)

    def _try_discover(self, announce: bool) -> bool:
        """自动找软件进程（窗口标题优先 + **exe 名验证**，exe 名兜底）。

        2026-10-27：从前只按 `--process shensuanzi.exe` 找，测试机上软件一改名
        就**静默没有进程指标**，测试人员只看到一列 `—`。
        2026-11-02：反过来又栽在「标题命中但进程不对」—— 见 `discover_app`。
        """
        verifier = None
        if self.proc is not None and not self.args.no_exe_check:
            verifier = self.proc.exe_by_pid
        pid, reason, title, warn = discover_app(
            self.proc, self.window, self.args.window_title, self.args.process, verifier
        )
        if warn and announce and time.monotonic() - self._last_warn >= 30.0:
            self._last_warn = time.monotonic()
            print("⚠️ %s" % warn)
            self.notes.append("%s 挂接警告：%s" % (time.strftime("%H:%M:%S"), warn))
        if not pid:
            return False
        if self.proc is None or not self.proc.open(pid):
            if announce:
                print(
                    "⚠️ 找到了 %s（PID %d）但打不开（试试以管理员身份运行本脚本）—— 进程指标将为 —"
                    % (reason, pid)
                )
            return False
        restarted = self.pid not in (0, pid)
        if pid not in self.pid_history:
            self.pid_history.append(pid)
        self.pid = pid
        self.attach_reason = reason
        self.window_title = title
        # 换了进程 ⇒ IO 计数器归零，**不能跨进程求差**（否则第一次是负数）
        self._prev_io = None
        if restarted:
            self.record_event(
                "process_restart",
                "软件重启（PID 换成 %d）" % pid,
                source="auto",
                note="重启期间的数据要单独看：page cache 是冷的",
            )
        if announce or restarted:
            print("已挂接进程（PID %d，依据：%s）%s" % (pid, reason, "；检测到重启" if restarted else ""))
        return True

    # -- 采样
    def sample_once(self) -> Dict[str, Any]:
        wall = time.monotonic()
        interval_ms = 0 if self._last_sample_wall is None else int((wall - self._last_sample_wall) * 1000)
        gap_ms = 0
        expected = int(self.args.interval * 1000)
        if interval_ms and expected and interval_ms > expected * 2.5:
            gap_ms = interval_ms - expected
        self._last_sample_wall = wall

        # 进程掉了 / 还没找到 ⇒ 每轮都重试自动发现（用户可能刚打开软件）
        if self.proc is not None:
            if self.pid and not self.proc.alive():
                self.record_event(
                    "process_exit", "软件已退出（PID %d）" % self.pid, source="auto"
                )
                self.pid = 0
                self._prev_io = None
            if not self.pid:
                self._try_discover(announce=not self._proc_warned)
                if self.pid:
                    self._proc_warned = True

        row: Dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "epoch_ms": int(time.time() * 1000),
            "interval_ms": interval_ms,
            "gap_ms": gap_ms,
            "pid": self.pid or "",
            "note": "",
        }
        for key in ("cpu_pct", "rss_mb", "private_mb", "handles", "threads", "io_read_mb", "io_write_mb",
                    "db_mb", "wal_mb", "shm_mb", "rows_documents", "rows_stock_ledger",
                    "rows_settlements", "probe_stock_ms", "probe_list_ms", "probe_window_ms"):
            row[key] = ""

        if self.proc is not None and self.pid:
            cpu = self.proc.cpu_pct()
            rss, private = self.proc.memory()
            handles = self.proc.handles()
            threads = self.proc.threads()
            io_read, io_write = self.proc.io_mb()
            row["cpu_pct"] = "" if cpu is None else round(cpu, 1)
            row["rss_mb"] = "" if rss is None else round(rss, 1)
            row["private_mb"] = "" if private is None else round(private, 1)
            row["handles"] = "" if handles is None else handles
            row["threads"] = "" if threads is None else threads
            row["io_read_mb"] = "" if io_read is None else round(io_read, 1)
            row["io_write_mb"] = "" if io_write is None else round(io_write, 1)
            # 本采样区间的**增量**（KB）—— 自动识别只看增量，累计值没法比阈值
            read_kb = write_kb = 0.0
            if io_read is not None and io_write is not None:
                if self._prev_io is not None:
                    read_kb = max(0.0, (io_read - self._prev_io[0]) * 1024.0)
                    write_kb = max(0.0, (io_write - self._prev_io[1]) * 1024.0)
                self._prev_io = (io_read, io_write)
            row["read_kb"] = round(read_kb, 1)
            row["write_kb"] = round(write_kb, 1)

        row["db_mb"] = mb(self.db_path)
        row["wal_mb"] = mb(self.db_path + "-wal")
        row["shm_mb"] = mb(self.db_path + "-shm")

        if self.args.rowcount_every and len(self.samples) % self.args.rowcount_every == 0:
            counts = self._row_counts()
            row["rows_documents"] = counts.get("documents", "")
            row["rows_stock_ledger"] = counts.get("stock_ledger", "")
            row["rows_settlements"] = counts.get("settlements", "")

        # 探针按**真实时间**调度：自适应采样下「每 N 个采样点」会随快慢漂掉
        if self.args.probe_interval and time.monotonic() - self._last_probe >= self.args.probe_interval:
            self._last_probe = time.monotonic()
            probes = run_probes(self.db_path, max(1, self.args.window_days) * 86400000)
            row["probe_stock_ms"] = "" if probes.get("stock") is None else probes["stock"]
            row["probe_list_ms"] = "" if probes.get("list") is None else probes["list"]
            row["probe_window_ms"] = "" if probes.get("window") is None else probes["window"]

        # 前台窗口标题：判断「这段时间人是不是在软件里」
        row["fg_title"] = self.window.foreground_title() if self.window is not None else ""

        # ---- 自动识别（2026-10-27）：喂给探测器，闭合成事件就记一条
        for event in self.detector.feed(row):
            self._on_auto_event(event)
        row["event_id"] = self.detector.current_id or ""
        if row.get("busy"):
            # 忙过之后的一小段时间保持快速档 —— 用户通常连着做几个动作
            self._fast_until = time.monotonic() + self.args.fast_hold
        return row

    def _on_auto_event(self, event: Dict[str, Any]) -> None:
        """把探测器识别出的一段「忙」记成事件（**标 source=auto，不冒充人工**）。

        名字从**库里查**（`journal_label`）而不是让人按：测试人员只管用软件，
        「刚保存了哪张单」由脚本自己回头看。查不到就老实写「读库/界面重建」，
        进事后补填清单 —— 宁可留空，不编名字。
        """
        label = ""
        if event.get("kind") == "写库":
            try:
                label = self.journal_label(int(event["start_ms"]), int(event["end_ms"]))
            except Exception:
                label = ""
        name = "自动识别 #%d %s" % (event["id"], label or event["kind"])
        self.auto_events.append(dict(event, label=label))
        self.record_event(
            "auto_action",
            name,
            duration_s=event["duration_s"],
            note="峰值 CPU %.0f%%；读 %.2f MB；写 %.2f MB；%d 个采样点"
            % (event["peak_cpu"], event["read_mb"], event["write_mb"], event["samples"]),
            source="auto",
            peak_cpu=event["peak_cpu"],
            read_mb=event["read_mb"],
            write_mb=event["write_mb"],
        )
        if not self.args.quiet:
            print("  · %s：%.2f 秒（峰值 CPU %.0f%%）" % (name, event["duration_s"], event["peak_cpu"]))

    # -- 事后归因：这段「忙」到底写了什么（2026-11-02）
    def journal_label(self, start_ms: int, end_ms: int) -> str:
        """从**库本身**读出「这段时间软件刚落了什么单」，给自动识别的事件贴名字。

        ## 为什么这么做

        软件是单窗口应用，窗口标题恒为「神算子」—— 从外面**看不出**用户点了
        什么。而写库这一段不一样：本项目「业务数据只插入」（纪律 2），
        任何动作最后都落成一张 `documents`（或一条主数据）。所以
        「按 rowid 倒序取最后一行」就是「刚刚发生了什么」的**事实**，
        不需要猜，也不需要测试人员按键。

        读操作（进页面、搜索）库里不留痕，**不硬凑名字** —— 报告里仍写
        「读库/界面重建」，并出现在事后补填清单里。

        只读（`mode=ro`）、`ORDER BY rowid DESC LIMIT 1`（rowid 表上是 O(1)），
        失败就返回空串，绝不影响采样。
        """
        try:
            uri = "file:%s?mode=ro" % self.db_path.replace("\\", "/")
            conn = sqlite3.connect(uri, uri=True, timeout=1.0)
        except sqlite3.Error:
            return ""
        try:
            conn.text_factory = str
            row = conn.execute(
                "SELECT doc_type, status, total_amount, created_at, ref_doc_id"
                " FROM documents ORDER BY rowid DESC LIMIT 1"
            ).fetchone()
            parts: List[str] = []
            if row and int(row[3] or 0) >= start_ms - 2000 and int(row[3] or 0) <= end_ms + 5000:
                label, amount, status = DOC_TYPE_LABEL.get(row[0], row[0]), row[2], row[1]
                text = "落单：%s ¥%.2f" % (label, (amount or 0) / 100.0)
                if status == "cancelled":
                    text += "（已取消）"
                if row[4]:
                    text += "（挂原单）"
                parts.append(text)
            prow = conn.execute(
                "SELECT name, updated_at FROM products ORDER BY rowid DESC LIMIT 1"
            ).fetchone()
            if prow and int(prow[1] or 0) >= start_ms - 2000 and int(prow[1] or 0) <= end_ms + 5000:
                parts.append("新建/改档案：%s" % prow[0])
            return "；".join(parts)
        except sqlite3.Error:
            return ""
        finally:
            try:
                conn.close()
            except sqlite3.Error:
                pass

    def _row_counts(self) -> Dict[str, int]:
        out: Dict[str, int] = {}
        try:
            uri = "file:%s?mode=ro" % self.db_path.replace("\\", "/")
            conn = sqlite3.connect(uri, uri=True, timeout=2.0)
            try:
                for table in ("documents", "stock_ledger", "settlements"):
                    out[table] = int(conn.execute("SELECT COUNT(*) FROM %s" % table).fetchone()[0])
            finally:
                conn.close()
        except sqlite3.Error:
            pass
        return out

    def record_sample(self, row: Dict[str, Any]) -> None:
        with self.lock:
            self.samples.append(row)
            self._sample_writer.writerow(row)
            self._sample_file.flush()

    def record_event(
        self,
        kind: str,
        name: str,
        *,
        duration_s: Optional[float] = None,
        feel: Optional[int] = None,
        note: str = "",
        source: str = "manual",
        peak_cpu: Optional[float] = None,
        read_mb: Optional[float] = None,
        write_mb: Optional[float] = None,
    ) -> None:
        event = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "epoch_ms": int(time.time() * 1000),
            "kind": kind,
            "name": name,
            "duration_s": "" if duration_s is None else round(duration_s, 2),
            "feel": "" if feel is None else feel,
            "note": note,
            # `source` 区分「脚本自己发现的」与「人按的」—— 报告分开展示，
            # 绝不把推断冒充成人工确认（2026-10-27）
            "source": source,
            "peak_cpu": "" if peak_cpu is None else peak_cpu,
            "read_mb": "" if read_mb is None else read_mb,
            "write_mb": "" if write_mb is None else write_mb,
        }
        with self.lock:
            self.events.append(event)
            self._event_writer.writerow(event)
            self._event_file.flush()
        if note:
            self.notes.append("%s %s：%s" % (event["ts"], name, note))

    # -- 人工动作
    def action_start(self, name: str) -> None:
        # 同时记 monotonic（算时长）与 wall（与自动识别的事件对齐）
        self.actions[name] = (time.monotonic(), int(time.time() * 1000))
        self.record_event("action_start", name)
        print("  ▶ 开始计时：%s" % name)

    def action_end(self, feel: Optional[int], note: str) -> None:
        if not self.actions:
            print("（还没有开始计时的动作：先 s <动作名>）")
            return
        name = list(self.actions.keys())[-1]
        started_mono, started_ms = self.actions.pop(name)
        duration = time.monotonic() - started_mono
        self.action_records.append(
            {
                "name": name,
                "duration_s": duration,
                "feel": feel,
                "note": note,
                "start_ms": started_ms,
            }
        )
        self.record_event("action_end", name, duration_s=duration, feel=feel, note=note)
        extra = "" if feel is None else "，观感 %d（%s）" % (feel, FEEL_LABEL.get(feel, "?"))
        print("  ■ %s 用时 %.2f 秒%s%s" % (name, duration, extra, ("；" + note) if note else ""))

    # -- spool（第二个窗口写进来的事件）
    def poll_spool(self) -> None:
        if not self.spool_path or not os.path.isfile(self.spool_path):
            return
        try:
            with open(self.spool_path, "r", encoding="utf-8") as fh:
                fh.seek(self._spool_pos)
                chunk = fh.read()
                self._spool_pos = fh.tell()
        except OSError:
            return
        if not chunk:
            return
        self._spool_buf += chunk
        while "\n" in self._spool_buf:
            line, self._spool_buf = self._spool_buf.split("\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except ValueError:
                continue
            self._apply_spool_item(item)

    def _apply_spool_item(self, item: Dict[str, Any]) -> None:
        action = str(item.get("action") or item.get("name") or "（未命名）")
        phase = str(item.get("phase") or "")
        note = str(item.get("note") or "")
        feel = item.get("feel")
        if phase == "start":
            self.action_start(action)
        elif phase == "end":
            duration = item.get("duration_s")
            if isinstance(duration, (int, float)):
                self.action_records.append(
                    {
                        "name": action,
                        "duration_s": float(duration),
                        "feel": feel if isinstance(feel, int) else None,
                        "note": note,
                        # 另一窗口自报的用时：开始时刻倒推
                        "start_ms": int(time.time() * 1000) - int(float(duration) * 1000),
                    }
                )
                self.record_event(
                    "action_end", action, duration_s=float(duration),
                    feel=feel if isinstance(feel, int) else None, note=note,
                )
                print("  ■ [另一窗口] %s 用时 %.2f 秒" % (action, float(duration)))
            else:
                self.action_end(feel if isinstance(feel, int) else None, note)
        else:
            self.record_event("mark", action, note=note)
            print("  · [另一窗口] %s%s" % (action, ("：" + note) if note else ""))

    def _interval(self) -> float:
        """当前该用多慢的采样间隔。

        空闲用 `--interval`（默认 0.5 秒），**刚忙过**就切到 `--fast-interval`
        （默认 0.2 秒）保持 `--fast-hold` 秒 —— 用户通常连着做几个动作，
        这样 200 ms 级的卡顿也能测出边界，不用人按秒表。
        """
        if self.args.no_adapt:
            return self.args.interval
        if time.monotonic() < self._fast_until:
            return min(self.args.fast_interval, self.args.interval)
        return self.args.interval

    # -- 采样线程
    def sampler_loop(self) -> None:
        while not self.stop.is_set():
            try:
                row = self.sample_once()
                self.record_sample(row)
            except Exception as exc:  # 采样失败不该让整轮测试崩掉
                self.record_event("sample_error", "采样失败", note=str(exc))
            self.poll_spool()
            self.stop.wait(self._interval())

    # -- 收尾
    def close(self) -> None:
        self.stop.set()
        try:
            for event in self.detector.flush():
                self._on_auto_event(event)
        except Exception:
            pass
        time.sleep(min(0.5, self.args.interval))
        try:
            self._sample_file.close()
            self._event_file.close()
        finally:
            if self.proc is not None:
                self.proc.close()


# --------------------------------------------------------------------------- 报告

def num(value: Any) -> Optional[float]:
    if value in ("", None):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def summarize(values: Sequence[float]) -> Dict[str, float]:
    if not values:
        return {}
    return {
        "n": len(values),
        "min": min(values),
        "p50": percentile(values, 0.5),
        "p95": percentile(values, 0.95),
        "max": max(values),
        "mean": statistics.fmean(values),
    }


def build_report(session: Session) -> str:
    args = session.args
    samples = session.samples
    lines: List[str] = []
    add = lines.append
    cpu = [v for v in (num(s.get("cpu_pct")) for s in samples) if v is not None]
    rss = [v for v in (num(s.get("rss_mb")) for s in samples) if v is not None]
    private = [v for v in (num(s.get("private_mb")) for s in samples) if v is not None]
    handles = [v for v in (num(s.get("handles")) for s in samples) if v is not None]
    threads = [v for v in (num(s.get("threads")) for s in samples) if v is not None]
    dbs = [v for v in (num(s.get("db_mb")) for s in samples) if v is not None]
    wals = [v for v in (num(s.get("wal_mb")) for s in samples) if v is not None]
    gaps = [v for v in (num(s.get("gap_ms")) for s in samples) if v is not None and v > 0]
    probes = {
        "库存合计": [v for v in (num(s.get("probe_stock_ms")) for s in samples) if v is not None],
        "单据列表": [v for v in (num(s.get("probe_list_ms")) for s in samples) if v is not None],
        "同步窗口": [v for v in (num(s.get("probe_window_ms")) for s in samples) if v is not None],
    }
    duration = time.time() - session.started
    db_now = mb(session.db_path)

    add("# 长时间使用性能实测 —— %s" % (args.label or "未标注（用 --label 写清楚：哪台机器/第几轮）"))
    add("")
    add("> 由 `tool/perf_monitor.py` 自动生成。**采样数据以 `samples.csv` 为准**，")
    add("> 本报告只做汇总与判读；人工动作的原始记录在 `events.csv`。")
    add("")

    # ---- 先回答「这份数据能不能用」，再看内容（2026-11-02）
    # 第三台机器那轮：CPU 全程 0.0%、工作集 4.9 MB、1 线程，报告照样生成，
    # 测试人员照样交回来 —— 因为没有任何一步说「这不可能」。现在放在**第一屏**。
    problems = sanity_check(samples)
    if problems:
        add("## ⓪ 这份数据可用吗 —— ⛔ 有问题，先看这里")
        add("")
        for p in problems:
            add("- ⛔ %s" % p)
        add("")
        add("> **别把这一轮当性能结论用。** 常见处置：确认软件窗口开着（标题含「%s」）、"
            % args.window_title)
        add("> 用 `--pid` 手动指定（任务管理器 → 详细信息 → 找到 %s 那一行的 PID）。"
            % (args.process or "软件 exe"))
        add("> 报告后面的数字仍然照写，但**进程相关的一切都不作数**。")
    else:
        add("## ⓪ 这份数据可用吗 —— ✅ 挂接与指标自洽")
        add("")
        add("> 线程数、工作集、CPU/读写都落在「真的是那个软件」的范围内（判据见 `sanity_check`）。")
    add("")
    add("## 一、会话")
    add("")
    add("| 项 | 值 |")
    add("|---|---|")
    add("| 开始时间 | %s |" % session.started_iso)
    add("| 持续时长 | %.1f 分钟 |" % (duration / 60.0))
    add(
        "| 采样点 | %d（空闲 %.2f 秒 / 忙时 %.2f 秒，自适应%s） |"
        % (len(samples), args.interval, args.fast_interval, "已关闭" if args.no_adapt else "")
    )
    add("| 数据目录 | `%s` |" % os.path.dirname(session.db_path))
    add("| 库文件 | `%s`（结束时 %.1f MB） |" % (session.db_path, db_now))
    # ⚠️ 用**历史**而不是「此刻的 pid」：测试结束时用户往往先把软件关了，
    # 那一刻 pid 是 0 —— 从前会误报「未挂接」，可整轮明明采到了 CPU/内存
    #（2026-10-28 真机数据里就出现了这一条）。
    history = session.pid_history
    if history:
        label = "PID %d" % history[0] if len(history) == 1 else (
            "PID %s（**重启过 %d 次**）" % (" → ".join(str(p) for p in history), len(history) - 1)
        )
        add("| 挂接进程 | %s（%s） |" % (label, session.attach_reason or "自动发现"))
    else:
        add("| 挂接进程 | **未挂接**（进程指标为 —）—— 见下方「为什么没挂上」 |")
    add("| 软件版本 | %s |" % (args.app_version or "未填写（`--app-version`）"))
    # 机器配置：**多路兜底**采集（注册表 / ctypes / 子进程），受限机器上逐项降级。
    # 2026-10-28 用户实测：从前只报 node/platform/核数，两台机器的数据事后没法对照；
    # 更糟的是受限机器上「人工手段也拿不到配置」—— 所以这里必须自己采。
    # ⚠️ 采一次就够：`cmd_run` 里已经采好挂在 session 上（报告与 session.json 用同一份），
    # 只有单独调 build_report 时才现场采。
    machine = getattr(session, "machine", None) or machine_info.collect()
    add("| 本机 | %s |" % machine_info.summary(machine))
    add("| 采集来源 | %s |" % ("、".join(
        "%s=%s" % (k, v) for k, v in sorted(machine.get("sources", {}).items())
    ) or "—"))
    add("| 备注 | %s |" % (args.session_note or "—"))
    add("")

    # ---- 人工动作
    # ------------------------------------------------ 自动识别的操作事件（2026-10-27）
    add("## 二之一、自动识别的操作事件（脚本自己发现的，**不用按键**）")
    add("")
    auto = session.auto_events
    if not auto:
        add("> 这一轮**没识别到操作**。常见原因（按可能性排）：")
        add("> ① 进程没挂上（看 §一「挂接进程」是不是 `未挂接`）⇒ 没有 CPU/读写信号；")
        add("> ② 阈值太高：默认 CPU ≥ %.0f%%、单次读 ≥ %.0f KB；低配机上跑不动大查询时会偏低，"
            % (args.busy_cpu, args.busy_read_kb))
        add(">    可以加 `--busy-cpu 10 --busy-read-kb 512` 重测；")
        add("> ③ 全程只是看着不动（那本来就没有操作）。")
    else:
        add(
            "> 判据：CPU ≥ %.0f%% 或 单次采样读 ≥ %.0f KB 或 写 ≥ %.0f KB；"
            "连续「忙」算一次操作，空闲 ≥ %.1f 秒才断开。"
            % (args.busy_cpu, args.busy_read_kb, args.busy_write_kb, args.idle_gap)
        )
        add("")
        add("| # | 开始 | 用时 | 脚本查到的动作 | 类型 | 峰值 CPU | 读 | 写 | 采样点 |")
        add("|---|---|---|---|---|---|---|---|---|")
        for e in auto:
            start = time.strftime("%H:%M:%S", time.localtime(e["start_ms"] / 1000.0))
            add(
                "| %d | %s | **%.2f 秒** | %s | %s | %.0f%% | %.2f MB | %.2f MB | %d |"
                % (
                    e["id"],
                    start,
                    e["duration_s"],
                    ("**%s**" % e["label"]) if e.get("label") else "（读操作，库里无痕）",
                    e["kind"],
                    e["peak_cpu"],
                    e["read_mb"],
                    e["write_mb"],
                    e["samples"],
                )
            )
        slow = [e for e in auto if e["duration_s"] >= args.slow_action]
        add("")
        add(
            "**合计 %d 次操作；其中 ≥ %.1f 秒的 %d 次**（明细见 `events.csv` 里 `source=auto` 的行）。"
            % (len(auto), args.slow_action, len(slow))
        )
        if slow:
            worst = max(auto, key=lambda e: e["duration_s"])
            add("")
            add(
                "最慢一次 **%.2f 秒**（%s，峰值 CPU %.0f%%，读 %.2f MB）—— 这一条要对着现场回想："
                "当时在做什么？" % (worst["duration_s"], worst["kind"], worst["peak_cpu"], worst["read_mb"])
            )

    # 与人工记录对齐（有就对齐，没有就跳过）—— 让测试人员能**验证**自动识别准不准
    if auto and session.action_records:
        pairs = []
        for rec in session.action_records:
            start_ms = rec.get("start_ms")
            if not start_ms:
                continue
            nearest = min(auto, key=lambda e: abs(e["start_ms"] - start_ms))
            if abs(nearest["start_ms"] - start_ms) <= 5000:
                pairs.append((rec, nearest))
        if pairs:
            add("")
            add("### 自动识别 vs 人工计时（对得上的那几次）")
            add("")
            add("| 动作 | 人工用时 | 自动识别 | 偏差 |")
            add("|---|---|---|---|")
            for rec, e in pairs:
                delta = rec["duration_s"] - e["duration_s"]
                add(
                    "| %s | %.2f 秒 | %.2f 秒 | %+.2f 秒 |"
                    % (rec["name"], rec["duration_s"], e["duration_s"], delta)
                )
            add("")
            add(
                "> 偏差主要来自**人工按秒表本身**（±0.3–0.5 秒是常态）。"
                "这也是这一版改成自动识别的理由 —— 人按不准。"
            )

    add("")
    add("## 二、人工动作（脚本计时，不用秒表）")
    add("")
    if session.action_records:
        add("| 动作 | 用时(秒) | 观感 | 备注 | 判定 |")
        add("|---|---|---|---|---|")
        for rec in session.action_records:
            flag = "✅" if rec["duration_s"] <= args.slow_action else "⚠️ 超过门槛"
            feel = FEEL_LABEL.get(rec["feel"], "—") if rec["feel"] else "—"
            add("| %s | %.2f | %s | %s | %s |"
                % (rec["name"], rec["duration_s"], feel, rec["note"] or "", flag))
    else:
        add("（没有动作记录。用 `s <动作名>` / `e <观感> <备注>` 现场记录。）")
    add("")

    # ---- 采样摘要
    add("## 三、机器侧采样摘要")
    add("")
    add("| 指标 | 样本 | 最小 | p50 | p95 | 最大 | 首→末 |")
    add("|---|---|---|---|---|---|---|")
    for label, series, unit in (
        ("CPU（单核=100%）", cpu, "%"),
        ("内存工作集", rss, "MB"),
        ("内存私有", private, "MB"),
        ("句柄数", handles, ""),
        ("线程数", threads, ""),
        ("库文件", dbs, "MB"),
        ("WAL", wals, "MB"),
    ):
        st = summarize(series)
        if not st:
            add("| %s | 0 | — | — | — | — | — |" % label)
            continue
        first = series[0] if series else 0
        last = series[-1] if series else 0
        add(
            "| %s | %d | %.1f %s | %.1f %s | %.1f %s | %.1f %s | %.1f → %.1f |"
            % (label, int(st["n"]), st["min"], unit, st["p50"], unit, st["p95"], unit,
               st["max"], unit, first, last)
        )
    add("")
    add("> 首→末 只对「单调量」有意义（内存、库文件、句柄）；CPU 的「首→末」只是两个采样点，不代表趋势。")
    add("")

    # ---- 探针
    add("## 四、库侧探针（可选）")
    add("")
    if any(probes.values()):
        add("| 探针 | 样本 | p50(ms) | p95(ms) | 最大(ms) |")
        add("|---|---|---|---|---|")
        for label, series in probes.items():
            st = summarize(series)
            if not st:
                add("| %s | 0 | — | — | — |" % label)
                continue
            add("| %s | %d | %.2f | %.2f | %.2f |" % (label, int(st["n"]), st["p50"], st["p95"], st["max"]))
        add("")
        add("> ⚠️ **探针 ≠ 页面耗时**，只能看趋势。`单据列表` 那条是**简化形状**"
            "（单段取 id、表达式排序、无 roots 过滤），而单据页首屏跑的是 "
            "`listDocuments(rootsOnly)` 两段 + `business_day` 索引 —— 两者数字不可互换。"
            "要「首屏多少毫秒」请用 `perf_bench.py --only list_roots`；"
            "要「用户那一下卡不卡」请用 `s` / `e` 人工标记。")
    else:
        add("（未开启。加 `--probe-interval 60` 可每 60 秒量一次只读查询耗时。）")
    add("")

    # ---- 自动判读
    add("## 五、自动判读（只是线索，结论仍要看现场）")
    add("")
    findings: List[str] = []
    slow_actions = [r for r in session.action_records if r["duration_s"] > args.slow_action]
    if slow_actions:
        findings.append(
            "**%d 个人工动作超过 %.1f 秒门槛**：%s"
            % (len(slow_actions), args.slow_action,
               "、".join("%s（%.2fs）" % (r["name"], r["duration_s"]) for r in slow_actions[:6]))
        )
    if cpu:
        busy = [v >= args.cpu_busy for v in cpu]
        longest = 0
        cur = 0
        for flag in busy:
            cur = cur + 1 if flag else 0
            longest = max(longest, cur)
        if longest >= 3:
            findings.append(
                "**连续 %d 个采样点 CPU ≥ %.0f%%**（最高 %.0f%%）——"
                " 说明有持续计算，不是「等磁盘」。" % (longest, args.cpu_busy, max(cpu))
            )
    if rss and len(rss) > 4:
        growth = rss[-1] - rss[0]
        ratio = (growth / rss[0] * 100.0) if rss[0] else 0.0
        if growth > 100 and ratio >= args.rss_growth:
            findings.append(
                "**内存从 %.0f MB 涨到 %.0f MB（+%.0f%%）** —— 注意是否单调上涨（疑似泄漏）。"
                % (rss[0], rss[-1], ratio)
            )
    if wals and max(wals) >= 200:
        findings.append(
            "**WAL 最大 %.0f MB** —— 长时间不归并会拖慢读写；对照结束时是否回落。" % max(wals)
        )
    if gaps:
        findings.append(
            "**采样缺口 %d 次，最大 %.1f 秒**（设定间隔 %.1f 秒）——"
            " 脚本自己都晚了，说明那一刻整机被压住。"
            % (len(gaps), max(gaps) / 1000.0, args.interval)
        )
    if not findings:
        findings.append("没有触发任何自动判据 —— 这**不等于**没问题，仍需看第二节的人工观感。")
    for f in findings:
        add("- %s" % f)
    add("")

    # ---- 覆盖
    add("## 六、标准动作覆盖")
    add("")
    done = {r["name"] for r in session.action_records}
    # 自动识别 + 库里查到的动作名也算覆盖（2026-11-02）：测试人员不再按键，
    # 只看「脚本记下的动作名」里有没有这一项 —— 有就算做过，不用他回忆。
    auto_names = " ".join(str(e.get("label") or "") for e in session.auto_events)
    add("| 项 | 状态 |")
    add("|---|---|")
    for name, hint in CHECKLIST:
        if name in done:
            mark = "✅（人工计时）"
        elif name in auto_names:
            mark = "✅（自动识别 + 库里查到）"
        else:
            mark = "—"
        add("| %s | %s %s |" % (name, mark, hint))
    missing = [name for name, _hint in CHECKLIST if name not in done and name not in auto_names]
    add("")
    if missing:
        add("**未记录 %d 项**：%s" % (len(missing), "、".join(missing)))
    else:
        add("**清单全部覆盖。**")
    add("")

    # ---- 事后补填（2026-11-02 裁定：现场只操作，细节事后填）
    # 现场按键会打断操作、还会把「操作」变成「操作+切窗口」，测出来的
    # 已经不是用户真实体验。所以现场什么都不用按，事后对着这张表填。
    add("## 七、事后补填表（**交回前请填这一张**）")
    add("")
    add("> 现场只管用软件，**不用按任何键**。耗时、读写、刚落的单据，脚本都记下了；")
    add("> 只有「当时在做什么」「感觉卡不卡」是机器猜不出来的，请事后补上。")
    add("> 观感：1=顺畅 2=一般 3=卡顿 4=明显卡顿 5=无响应。")
    add("")
    todo_events = [
        e for e in session.auto_events
        if not e.get("label") or e["duration_s"] >= args.slow_action
    ]
    if not todo_events:
        add("（本轮所有操作脚本都认出来了、且都不慢 —— 没有要补的。）")
    else:
        add("| # | 时刻 | 用时 | 脚本已查到 | 当时在做什么（请填） | 观感 1–5（请填） |")
        add("|---|---|---|---|---|---|")
        for e in todo_events:
            start = time.strftime("%H:%M:%S", time.localtime(e["start_ms"] / 1000.0))
            add(
                "| %d | %s | %.2f 秒 | %s |  |  |"
                % (
                    e["id"],
                    start,
                    e["duration_s"],
                    e.get("label") or "（读操作，库里无痕）",
                )
            )
        add("")
        add("> 只填**慢的**和**认不出名字**的即可，其余不必逐条补。")
    add("")

    # ---- 原始备注
    add("## 七、现场备注")
    add("")
    if session.notes:
        for note in session.notes:
            add("- %s" % note)
    else:
        add("（无）")
    add("")
    add("---")
    add("")
    add("## 交回时要带上什么")
    add("")
    add("1. 本文件 `report.md`；")
    add("2. `samples.csv`（逐采样点，Excel 直接开）；")
    add("3. `events.csv`（人工动作与备注）；")
    add("4. 测试前后各一份 `perf_bench.py` 的 CSV；")
    add("5. 一句话：这一轮**最卡的一次是哪个动作、当时在做什么**。")
    return "\n".join(lines)


def build_html(report_md: str, title: str) -> str:
    """极简 HTML：不做 Markdown 渲染，只把原文放进 <pre>，另附库体积走势的 SVG。"""
    return (
        "<!doctype html><meta charset='utf-8'><title>%s</title>"
        "<style>body{font:14px/1.6 system-ui,'Microsoft YaHei UI',sans-serif;margin:24px;"
        "max-width:1100px}pre{white-space:pre-wrap;background:#fafafa;padding:16px;"
        "border:1px solid #ddd;border-radius:6px}</style><h1>%s</h1><pre>%s</pre>"
        % (title, title, report_md.replace("&", "&amp;").replace("<", "&lt;"))
    )


# --------------------------------------------------------------------------- CLI

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="perf_monitor.py",
        description="人工实测期间的实时记录器（只读、不启动/结束软件）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例：\n"
            "  python tool/perf_monitor.py run --data-dir \"D:\\\\神算子数据\" --out D:\\\\perf-run1\n"
            "  python tool/perf_monitor.py run --db .\\\\perf.db --interval 2 --probe-interval 60\n"
            "  python tool/perf_monitor.py mark --spool D:\\\\perf-run1\\\\events.jsonl "
            "--action 保存销售单 --start\n"
            "  python tool/perf_monitor.py checklist\n"
        ),
    )
    sub = parser.add_subparsers(dest="cmd")

    run = sub.add_parser("run", help="开始采样（默认子命令）")
    target = run.add_argument_group("目标（二选一；只用来量文件与探针）")
    target.add_argument("--db", help="库文件路径")
    target.add_argument("--data-dir", help="数据目录（库名固定 %s）" % DATA_FILE_NAME)

    proc = run.add_argument_group("挂接哪个进程（默认**自动发现**，不用手填）")
    proc.add_argument(
        "--window-title",
        default=WINDOW_KEYWORD,
        help="主窗口标题关键词（默认「%(default)s」）—— **优先按它找**，"
        "软件被改名也能找到；找不到才退回 --process",
    )
    proc.add_argument(
        "--process",
        default="shensuanzi.exe",
        help="exe 名（兜底用，默认 %(default)s）。**也接受任务管理器里显示的那个名字**"
        "（神算子显示为「Shensuanzi - Inventory & Bookkeeping」，那是文件说明不是文件名，"
        "照抄进来认）",
    )
    proc.add_argument("--pid", default=None, help="直接指定 PID（优先级最高）")
    proc.add_argument(
        "--no-exe-check", action="store_true",
        help="关掉「exe 名验证」。**默认开**：标题命中但 exe 对不上就不挂 —— "
        "第三台机器按标题挂到了别的进程，711 个采样点全作废（见 discover_app）",
    )

    how = run.add_argument_group("采样")
    how.add_argument(
        "--interval",
        type=float,
        default=0.5,
        help="**空闲时**的采样间隔秒（默认 %(default)s）。0.5 秒是权衡："
        "再慢就跟 200 ms 级卡顿同量级，测不出边界",
    )
    how.add_argument(
        "--fast-interval", type=float, default=0.2,
        help="**刚忙过**的采样间隔秒（默认 %(default)s）—— 自适应，专为测准操作耗时",
    )
    how.add_argument(
        "--fast-hold", type=float, default=6.0,
        help="忙过之后保持快速档的秒数（默认 %(default)s）",
    )
    how.add_argument(
        "--no-adapt", action="store_true", help="关掉自适应（一律用 --interval）"
    )
    how.add_argument(
        "--probe-interval", type=float, default=0.0,
        help="探针间隔秒（默认 0=关闭）；开它会增加 I/O，人工实测时建议 60",
    )
    how.add_argument(
        "--rowcount-every", type=int, default=0,
        help="每 N 个采样点量一次行数（默认 0=关闭，大库上 COUNT(*) 也有成本）",
    )
    how.add_argument("--window-days", type=int, default=7, help="同步窗口天数（探针用，默认 %(default)s）")
    how.add_argument("--duration", type=float, default=0.0, help="跑多少分钟后自动停（默认 0=手动 q 结束）")
    how.add_argument("--no-input", action="store_true", help="不读键盘（只采样；动作靠 --spool）")
    how.add_argument(
        "--keep-open", action="store_true",
        help="软件关掉后**不**自动收尾（默认：关掉软件就自动结束并写报告 —— "
        "测试人员不用记得回来按 q）",
    )

    detect = run.add_argument_group("自动识别操作的阈值（默认值在开发机上验过）")
    detect.add_argument(
        "--busy-cpu", type=float, default=25.0,
        help="CPU 高于多少算「忙」（默认 %(default)s%%，单核=100%%）",
    )
    detect.add_argument(
        "--busy-read-kb", type=float, default=2048.0,
        help="单次采样读多少 KB 算「在加载」（默认 %(default)s）",
    )
    detect.add_argument(
        "--busy-write-kb", type=float, default=256.0,
        help="单次采样写多少 KB 算「在写库」（默认 %(default)s）",
    )
    detect.add_argument(
        "--idle-gap", type=float, default=1.5,
        help="空闲多少秒算两个动作的分界（默认 %(default)s）",
    )

    judge = run.add_argument_group("判读门槛（报告里按它标⚠️）")
    judge.add_argument(
        "--slow-action", type=float, default=2.0,
        help="人工动作超过多少秒算「慢」（默认 %(default)s）",
    )
    judge.add_argument(
        "--cpu-busy", type=float, default=85.0,
        help="CPU 高于多少算「忙」（默认 %(default)s%%，单核=100%%）",
    )
    judge.add_argument(
        "--rss-growth", type=float, default=30.0,
        help="内存首末增长超过多少百分比算「疑似泄漏」（默认 %(default)s%%，且需 >100MB）",
    )

    out = run.add_argument_group("输出与会话信息")
    out.add_argument("--out", default=None, help="结果目录（默认 ./perf-run-YYYYmmdd-HHMMSS）")
    out.add_argument("--label", default="", help="本轮标签，写进报告（如「第1轮/老机器」）")
    out.add_argument("--session-note", default="", help="本轮现场备注（磁盘类型、是否开杀软等）")
    out.add_argument("--app-version", default="", help="软件版本（UI 上能看到就填）")
    out.add_argument("--spool", default=None, help="第二个窗口用 mark 写的事件文件（JSONL）")
    out.add_argument("--html", action="store_true", help="额外生成 report.html")
    out.add_argument("--quiet", action="store_true", help="不打印每个采样点")

    mark = sub.add_parser("mark", help="往 spool 里写一条人工事件（第二个窗口用）")
    mark.add_argument("--spool", required=True, help="与 run --spool 相同的文件")
    mark.add_argument("--action", required=True, help="动作名（与清单里的名字一致最省事）")
    mark.add_argument("--start", action="store_true", help="开始计时")
    mark.add_argument("--end", action="store_true", help="结束计时（此时 --duration 可给秒数）")
    mark.add_argument("--duration", type=float, default=None, help="自报用时（秒）；不给则用 run 侧的计时")
    mark.add_argument("--feel", type=int, default=None, help="观感 1–5")
    mark.add_argument("--note", default="", help="备注")
    mark.add_argument("--mark", action="store_true", help="只记一条观察（不计时）")

    sub.add_parser("checklist", help="打印标准动作清单")
    sub.add_parser("selftest", help="自检：用合成采样序列钉住「动作自动识别」（不需要软件）")
    return parser


def parse_args(argv: Optional[Sequence[str]]) -> argparse.Namespace:
    parser = build_parser()
    argv = list(sys.argv[1:] if argv is None else argv)
    # 无子命令时默认 run（少一次打字）
    if not argv or argv[0] not in ("run", "mark", "checklist", "selftest", "-h", "--help"):
        argv = ["run"] + argv
    args = parser.parse_args(argv)
    if args.cmd is None:
        args.cmd = "run"
    return args


def print_help_commands() -> None:
    print("")
    print("命令（**都不用按也能出数据** —— 脚本自己识别操作，下面这些是可选的补充）：")
    print("  s <动作名>        开始计时（例：s 保存销售单）")
    print("  e [观感] [备注]    结束计时；观感 1=顺畅 2=一般 3=卡顿 4=明显卡顿 5=无响应")
    print("  m <备注>          记一条观察（不计时）")
    print("  p                立即跑一次探针")
    print("  r                打印当前摘要")
    print("  c                打印标准测试清单")
    print("  q                结束并生成报告")
    print("")
    print("  ⭐ 自动识别已开启：你只管用软件，动作耗时自己会记下来；")
    print("     敲 s/e 只是为了给动作**贴名字**、填**观感**（这两样脚本猜不出来）。")
    print("")


def print_checklist() -> None:
    print("")
    print("标准动作清单（按顺序做；耗时脚本自己记，想贴名字再敲 s / e）：")
    for i, (name, hint) in enumerate(CHECKLIST, 1):
        print("  %2d. %-10s %s" % (i, name, hint))
    print("")


def cmd_mark(args: argparse.Namespace) -> int:
    item: Dict[str, Any] = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "action": args.action,
        "note": args.note,
    }
    if args.start:
        item["phase"] = "start"
    elif args.end:
        item["phase"] = "end"
        if args.duration is not None:
            item["duration_s"] = args.duration
    else:
        item["phase"] = "mark"
    if args.feel is not None:
        item["feel"] = args.feel
    try:
        with open(args.spool, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(item, ensure_ascii=False) + "\n")
    except OSError as exc:
        print("⛔ 写不进 %s：%s" % (args.spool, exc), file=sys.stderr)
        return 2
    print("已写入 %s：%s / %s" % (args.spool, args.action, item.get("phase")))
    return 0


def _stdin_reader(q: "queue.Queue[Optional[str]]") -> None:
    """后台线程：把键盘输入塞进队列。

    为什么不能像从前那样在主循环里 `input()`：`input()` 会**阻塞**，
    测试人员一旦去用软件（这才是正事），主循环就停在那儿不动 ——
    想敲 `q` 得先切回窗口，想敲 `s` 得先切回窗口。而「切窗口」这个动作
    本身就会打断被测的操作，测出来的耗时已经不是用户真实体验了。

    现在：输入照收，但**不收也照常跑**。测试人员全程只碰软件。

    ⚠️ **读到 EOF 就安静退出线程，绝不投「结束」信号**（2026-11-04 冒烟测试
    踩到的坑）：stdin 被重定向、或终端没有真实键盘时 `readline()` 会立刻
    返回空串，若据此结束，脚本会**开机即退**，只采到 1 个采样点。
    结束只有三条路：敲 `q`、到 `--duration`、软件被关掉。
    """
    while True:
        try:
            line = sys.stdin.readline()
        except Exception:
            return
        if not line:
            return  # 没有键盘了 —— 停止读取，但**不**结束采样
        q.put(line.rstrip("\r\n"))


def cmd_run(args: argparse.Namespace) -> int:
    if args.db and args.data_dir:
        print("⛔ --db 与 --data-dir 只能指定一个。", file=sys.stderr)
        return 2
    if args.db:
        db_path = os.path.abspath(args.db)
    elif args.data_dir:
        db_path = os.path.join(os.path.abspath(args.data_dir), DATA_FILE_NAME)
    else:
        print(
            "⛔ 需要 --data-dir 或 --db（至少要能定位库文件，才能量库体积）。",
            file=sys.stderr,
        )
        return 2
    if not args.out:
        args.out = os.path.join(os.getcwd(), "perf-run-" + time.strftime("%Y%m%d-%H%M%S"))

    if not os.path.isfile(db_path):
        print(
            "⚠️ 库里还没文件：%s\n   如果软件还没启动过，请先打开一次（让它建库），再跑本脚本。"
            % db_path,
            file=sys.stderr,
        )

    session = Session(args, db_path)
    thread = threading.Thread(target=session.sampler_loop, daemon=True)
    thread.start()

    print("")
    print("性能实测记录开始")
    print("  输出目录  %s" % session.out_dir)
    print("  库文件    %s" % db_path)
    print("  进程      %s" % (("PID %s（已验 exe 名）" % session.pid) if session.pid
                          else ("自动发现中（标题含「%s」，exe %s）"
                                % (args.window_title, args.process))))
    print("  采样      %.1f 秒/次%s"
          % (args.interval, ("；探针每 %.0f 秒" % args.probe_interval) if args.probe_interval else ""))
    if args.spool:
        print("  事件文件  %s" % args.spool)
    print("")
    print("  ⭐ **现在起只管用软件，不用碰这个窗口。**")
    print("     每次操作脚本自己认（写库的动作还会从库里查出是哪张单）；")
    print("     「当时在做什么 / 卡不卡」写在报告末尾的「事后补填表」里。")
    print("  ⚠️ 保持本窗口开着。**关掉软件后脚本会自动结束并写报告**；")
    print("     想提前结束就在这个窗口敲 q（可选，见 h）。")
    if not args.quiet:
        print_help_commands()
    else:
        print("  （--quiet：不打印逐点采样；命令仍可用）")

    deadline = time.time() + args.duration * 60.0 if args.duration > 0 else None
    exit_code = 0
    # 键盘输入走后台线程 ⇒ 主循环**永不阻塞在 input() 上**。
    # 从前 `input()` 卡住时，采样线程照跑，但「软件关了就自动收尾」这类
    # 判断全做不了 —— 而那正是「测试人员忘了按 q」时报告缺失的原因。
    keys: "queue.Queue[Optional[str]]" = queue.Queue()
    if not args.no_input:
        # EOF 无害（见 `_stdin_reader`），所以不必先判 isatty：重定向进来的
        # 命令照样能执行，没有键盘时线程自己安静退出、采样不受影响。
        threading.Thread(target=_stdin_reader, args=(keys,), daemon=True).start()
    # 软件退出后**再采一会儿**就收尾：让最后一次操作的「忙」段闭合完，
    # 也留出时间把 WAL 归并的体积变化采到。
    exit_grace = max(6.0, args.interval * 12)
    saw_app = bool(session.pid)
    gone_since: Optional[float] = None
    try:
        while True:
            if deadline is not None and time.time() >= deadline:
                print("\n到 --duration 设定时间，自动结束。")
                break
            # 自动收尾：见过软件、之后连续一段时间再也找不到 ⇒ 用户测完关掉了
            if session.pid:
                saw_app = True
                gone_since = None
            elif saw_app and not args.keep_open:
                gone_since = gone_since or time.monotonic()
                if time.monotonic() - gone_since >= exit_grace:
                    print("\n软件已关闭（%.0f 秒没再找到窗口），自动结束并写报告。" % exit_grace)
                    break
            try:
                raw = keys.get(timeout=0.5)
            except queue.Empty:
                continue
            if raw is None:
                break
            raw = raw.strip()
            if not raw:
                continue
            cmd, _, rest = raw.partition(" ")
            cmd = cmd.lower()
            if cmd in ("q", "quit", "exit"):
                break
            elif cmd in ("h", "help", "?"):
                print_help_commands()
            elif cmd == "c":
                print_checklist()
            elif cmd == "s":
                if not rest.strip():
                    print("（用法：s <动作名>，例：s 保存销售单）")
                    continue
                session.action_start(rest.strip())
            elif cmd == "e":
                parts = rest.split(None, 2)
                feel = None
                note = ""
                if parts and parts[0].isdigit():
                    feel = int(parts[0])
                    if not 1 <= feel <= 5:
                        print("（观感用 1–5：1=顺畅 … 5=无响应）")
                        continue
                    note = parts[1] if len(parts) > 1 else ""
                elif parts:
                    note = rest
                session.action_end(feel, note)
            elif cmd == "m":
                session.record_event("mark", "观察", note=rest.strip())
                if rest.strip():
                    print("  · 已记录：%s" % rest.strip())
            elif cmd == "p":
                probes = run_probes(db_path, max(1, args.window_days) * 86400000)
                print("  探针：" + "，".join(
                    "%s=%s ms" % (k, "—" if v is None else "%.1f" % v) for k, v in probes.items()))
            elif cmd == "r":
                if session.action_records:
                    print("  已记录动作：")
                    for rec in session.action_records[-10:]:
                        print("    %-12s %.2fs %s" % (rec["name"], rec["duration_s"],
                                                      FEEL_LABEL.get(rec["feel"], "")))
                else:
                    print("  还没有动作记录。")
                print("  采样点：%d；库 %.1f MB；WAL %.1f MB"
                      % (len(session.samples), mb(db_path), mb(db_path + "-wal")))
            else:
                print("（不认识的命令：%s。h 看命令表）" % cmd)
                continue
            if not args.quiet:
                last = session.samples[-1] if session.samples else {}
                cpu = last.get("cpu_pct")
                rss = last.get("rss_mb")
                if cpu not in ("", None) or rss not in ("", None):
                    print("  · CPU %s%% / 内存 %s MB / WAL %s MB"
                          % (cpu if cpu != "" else "—", rss if rss != "" else "—", last.get("wal_mb", "—")))
    finally:
        session.close()

    # 机器配置：**采一次**，报告与 session.json 共用（两处各采一次会不一致）
    session.machine = machine_info.collect()
    report = build_report(session)
    report_path = os.path.join(session.out_dir, "report.md")
    with open(report_path, "w", encoding="utf-8") as fh:
        fh.write(report + "\n")
    if args.html:
        html_path = os.path.join(session.out_dir, "report.html")
        with open(html_path, "w", encoding="utf-8") as fh:
            fh.write(build_html(report, "性能实测报告"))
        print("已写出 %s" % html_path)

    meta = {
        "label": args.label,
        "started": session.started_iso,
        "duration_s": round(time.time() - session.started, 1),
        "samples": len(session.samples),
        "actions": session.action_records,
        "interval_s": args.interval,
        "process": args.process,
        "pid": session.pid,
    "pid_history": list(session.pid_history),
        "app_version": args.app_version,
        "session_note": args.session_note,
        # 完整机器配置（含 blocked / sources）：事后对比两台机器只靠它
        "machine": getattr(session, "machine", None),
        "db": db_path,
        "db_mb": mb(db_path),
        "wal_mb": mb(db_path + "-wal"),
    }
    with open(os.path.join(session.out_dir, "session.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=2)

    print("")
    print("已写出：")
    print("  %s" % report_path)
    print("  %s" % session.samples_path)
    print("  %s" % session.events_path)
    print("  %s" % os.path.join(session.out_dir, "session.json"))
    slow = [r for r in session.action_records if r["duration_s"] > args.slow_action]
    if slow:
        print("")
        print("⚠️ %d 个动作超过 %.1f 秒门槛：" % (len(slow), args.slow_action))
        for rec in slow:
            print("   %s %.2fs" % (rec["name"], rec["duration_s"]))
    return exit_code


def cmd_selftest() -> int:
    """用**合成采样序列**钉住 [ActionDetector]，不需要真开软件。

    为什么必须有它：识别逻辑一旦改坏（阈值写反、间隔判断写错），现场跑一轮
    才发现就白测了。这里用 6 个场景把「该报的」与「不该报的」分开，
    跑一次两秒钟。

    退出码：0 = 全过；1 = 有失败。
    """
    cases: List[Tuple[str, List[Dict[str, Any]], int, List[str]]] = []

    def series(rows: List[Tuple[int, Optional[float], float, float]]) -> List[Dict[str, Any]]:
        """(相对毫秒, CPU%, 读 KB, 写 KB) → 采样 dict 序列。"""
        out: List[Dict[str, Any]] = []
        for offset, cpu, read_kb, write_kb in rows:
            out.append(
                {
                    "epoch_ms": 1_700_000_000_000 + offset,
                    "interval_ms": 200,
                    "cpu_pct": cpu,
                    "read_kb": read_kb,
                    "write_kb": write_kb,
                }
            )
        return out

    cases.append(
        (
            "A 一次读突发 ⇒ 1 个「读库」事件",
            series(
                [
                    (0, 2.0, 0, 0),
                    (200, 2.0, 0, 0),
                    (400, 80.0, 8000, 0),
                    (600, 70.0, 6000, 0),
                    (800, 3.0, 0, 0),
                    (1000, 2.0, 0, 0),
                    (1200, 2.0, 0, 0),
                    (1400, 2.0, 0, 0),
                    (1600, 2.0, 0, 0),
                    (1800, 2.0, 0, 0),
                    (2000, 2.0, 0, 0),
                ]
            ),
            1,
            ["读库"],
        )
    )
    cases.append(
        (
            "B 一次写突发 ⇒ 1 个「写库」事件",
            series(
                [
                    (0, 2.0, 0, 0),
                    (200, 60.0, 0, 900),
                    (400, 2.0, 0, 0),
                    (600, 2.0, 0, 0),
                    (800, 2.0, 0, 0),
                    (1000, 2.0, 0, 0),
                    (1200, 2.0, 0, 0),
                    (1400, 2.0, 0, 0),
                    (1600, 2.0, 0, 0),
                    (1800, 2.0, 0, 0),
                ]
            ),
            1,
            ["写库"],
        )
    )
    cases.append(
        (
            "C 两次突发、中间空闲够久 ⇒ 2 个事件",
            series(
                [
                    (0, 80.0, 5000, 0),
                    (200, 80.0, 5000, 0),
                    (400, 2.0, 0, 0),
                    (600, 2.0, 0, 0),
                    (800, 2.0, 0, 0),
                    (1000, 2.0, 0, 0),
                    (1200, 2.0, 0, 0),
                    (1400, 2.0, 0, 0),
                    (1600, 2.0, 0, 0),
                    (1800, 2.0, 0, 0),
                    (2000, 80.0, 5000, 0),
                    (2200, 80.0, 5000, 0),
                    (2400, 2.0, 0, 0),
                    (2600, 2.0, 0, 0),
                    (2800, 2.0, 0, 0),
                    (3000, 2.0, 0, 0),
                    (3200, 2.0, 0, 0),
                    (3400, 2.0, 0, 0),
                    (3600, 2.0, 0, 0),
                    (3800, 2.0, 0, 0),
                ]
            ),
            2,
            ["读库", "读库"],
        )
    )
    cases.append(
        (
            "D 两次突发、中间只空 0.4 秒 ⇒ 合并成 1 个（用户连点两下 = 一个动作）",
            series(
                [
                    (0, 80.0, 5000, 0),
                    (200, 2.0, 0, 0),
                    (400, 2.0, 0, 0),
                    (600, 80.0, 5000, 0),
                    (800, 2.0, 0, 0),
                    (1000, 2.0, 0, 0),
                    (1200, 2.0, 0, 0),
                    (1400, 2.0, 0, 0),
                    (1600, 2.0, 0, 0),
                    (1800, 2.0, 0, 0),
                    (2000, 2.0, 0, 0),
                ]
            ),
            1,
            ["读库"],
        )
    )
    cases.append(
        (
            "E 全程空闲 ⇒ 0 个事件（不许无中生有）",
            series([(i * 200, 1.0, 0, 0) for i in range(15)]),
            0,
            [],
        )
    )
    cases.append(
        (
            "F 单个 200 ms 尖峰、无读写 ⇒ 丢掉（噪声，不是操作）",
            series(
                [
                    (0, 1.0, 0, 0),
                    (200, 90.0, 0, 0),
                    (400, 1.0, 0, 0),
                    (600, 1.0, 0, 0),
                    (800, 1.0, 0, 0),
                    (1000, 1.0, 0, 0),
                    (1200, 1.0, 0, 0),
                    (1400, 1.0, 0, 0),
                    (1600, 1.0, 0, 0),
                    (1800, 1.0, 0, 0),
                ]
            ),
            0,
            [],
        )
    )

    # ---- 进程自动发现（合成窗口列表，不需要真软件）
    failed_discover = False

    class _FakeWindow:
        def __init__(self, titles):
            self._titles = titles

        def top_windows(self):
            return [(i + 1, 1000 + i, t) for i, t in enumerate(self._titles)]

    class _FakeProc:
        def __init__(self, pid):
            self._pid = pid

        def find_by_name(self, _name):
            return self._pid

    # exe 名验证的假实现：pid 1000 是「标题也含神算子」的浏览器，1001 才是软件
    def _exe(pid: int) -> str:
        return "shensuanzi.exe" if pid == 1001 else "chrome.exe"

    discover_cases = [
        ("窗口标题优先（exe 名不对也能找到）", _FakeWindow(["神算子", "记事本"]), _FakeProc(9), 1000, None),
        ("标题里带后缀也认（「神算子 - 销售开单」）", _FakeWindow(["神算子 - 销售开单"]), _FakeProc(9), 1000, None),
        ("没有窗口 ⇒ 退回 exe 名", _FakeWindow(["记事本"]), _FakeProc(777), 777, None),
        ("都没有 ⇒ 0（不许瞎挂）", _FakeWindow(["记事本"]), _FakeProc(0), 0, None),
        # ⬇️ 2026-11-02 第三台机器的事故：标题命中但不是软件 ⇒ 必须跳过
        ("标题撞车（浏览器标签也叫神算子）⇒ 跳过它、按 exe 名找",
         _FakeWindow(["神算子 - 浏览器", "记事本"]), _FakeProc(777), 777, _exe),
        ("两个候选：先验 exe 名，挂对的那个",
         _FakeWindow(["神算子 - 浏览器", "神算子"]), _FakeProc(9), 1001, _exe),
        ("关掉 exe 验证（--no-exe-check）⇒ 退回旧的标题优先",
         _FakeWindow(["神算子 - 浏览器"]), _FakeProc(9), 1000, "OFF"),
    ]

    # ---- 名字对不上怎么办：任务管理器显示的是 FileDescription，不是 exe 名
    print("— 进程名识别（任务管理器显示名 vs exe 名）—")
    name_cases = [
        ("shensuanzi.exe", "shensuanzi.exe", True, "默认值精确相等"),
        ("shensuanzi.exe", "Shensuanzi - Inventory & Bookkeeping", True, "任务管理器显示名"),
        ("chrome.exe", "shensuanzi.exe", False, "浏览器不是软件"),
        ("notepad.exe", "Shensuanzi - Inventory & Bookkeeping", False, "记事本不是软件"),
        ("", "shensuanzi.exe", False, "取不到 exe 名时不硬认"),
    ]
    for got, want, expect, why in name_cases:
        ok = exe_name_matches(got, want)
        print("  %s %s：%s vs「%s」⇒ %s" % ("✅" if ok == expect else "❌", why, got or "(空)", want, ok))
        if ok != expect:
            failed_discover = True
    print("")

    print("自动识别自检（合成序列，不需要软件）")
    print("")
    print("— 进程自动发现 —")
    for name, window, proc, want, verifier in discover_cases:
        v = None if verifier in (None, "OFF") else verifier
        pid, reason, _title, warn = discover_app(proc, window, WINDOW_KEYWORD, "shensuanzi.exe", v)
        ok = pid == want
        if verifier == "OFF" and ok:
            ok = bool(warn)  # 没验 exe 名时必须**明说**，不许静默
        if not ok:
            failed_discover = True
        print(
            "  %s %s：期望 PID %s，实际 %s%s%s"
            % ("✅" if ok else "❌", name, want or "（找不到）", pid or "（找不到）",
               ("（依据：%s）" % reason) if reason else "",
               ("；警告：%s" % warn) if warn else "")
        )
    print("")
    print("— 挂接体检（这份数据能不能用）—")
    sanity_cases = [
        ("正常一轮 ⇒ 无问题",
         [{"cpu_pct": 12.0, "threads": 14, "rss_mb": 260.0, "read_kb": 100.0, "write_kb": 0.0}] * 20, 0),
        ("第三台机器那种：CPU 全 0、4.9 MB、1 线程 ⇒ 必须报",
         [{"cpu_pct": 0.0, "threads": 1, "rss_mb": 4.9, "read_kb": 0.0, "write_kb": 0.0}] * 711, 3),
        ("全程没挂上进程（指标全空）⇒ 必须说清",
         [{"cpu_pct": "", "threads": "", "rss_mb": "", "read_kb": "", "write_kb": ""}] * 50, 1),
        ("CPU 0 但有读写 ⇒ 不报（进程在动，只是采样窗口短）",
         [{"cpu_pct": 0.0, "threads": 12, "rss_mb": 300.0, "read_kb": 5000.0, "write_kb": 0.0}] * 30, 0),
    ]
    failed_sanity = False
    for name, rows, want_n in sanity_cases:
        got = sanity_check(rows)
        ok = len(got) == want_n
        if not ok:
            failed_sanity = True
        print("  %s %s：期望 %d 条警告，实际 %d 条%s"
              % ("✅" if ok else "❌", name, want_n, len(got),
                 ("\n        " + "\n        ".join(got)) if got else ""))
    print("")
    print("— 动作识别 —")
    failed = 0
    for name, rows, want_count, want_kinds in cases:
        detector = ActionDetector()
        got: List[Dict[str, Any]] = []
        for row in rows:
            got.extend(detector.feed(row))
        got.extend(detector.flush())
        ok = len(got) == want_count and all(
            want in event["kind"] for event, want in zip(got, want_kinds)
        )
        if not ok:
            failed += 1
        print(
            "  %s %s：期望 %d 个%s，实际 %d 个%s"
            % (
                "✅" if ok else "❌",
                name,
                want_count,
                ("（" + " / ".join(want_kinds) + "）") if want_kinds else "",
                len(got),
                ("（" + " / ".join(e["kind"] for e in got) + "）") if got else "",
            )
        )
        for event in got:
            print(
                "        用时 %.2f 秒 · 峰值 CPU %.0f%% · 读 %.2f MB · 写 %.2f MB"
                % (event["duration_s"], event["peak_cpu"], event["read_mb"], event["write_mb"])
            )
    print("")
    if failed or failed_discover:
        print(
            "❌ %d 个场景不通过%s —— 识别逻辑改坏了，别拿去现场测。"
            % (failed, "（另有进程发现用例失败）" if failed_discover else "")
        )
        return 1
    print("✅ 全过：自动识别在这些场景下的行为符合预期。")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except Exception:
            pass
    args = parse_args(argv)
    if args.cmd == "checklist":
        print_checklist()
        return 0
    if args.cmd == "mark":
        return cmd_mark(args)
    if args.cmd == "selftest":
        return cmd_selftest()
    return cmd_run(args)


if __name__ == "__main__":
    raise SystemExit(main())
