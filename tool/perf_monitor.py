#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""人工实测期间的实时记录器：边用软件，边把「机器在忙什么」按秒记下来。

    # ① 打开软件，进入主界面（建议全屏，别最小化）
    # ② 另开一个窗口跑：
    python tool/perf_monitor.py run --data-dir "D:\\神算子数据" --out D:\\perf-run1
    # ③ 按提示做动作：开始计时 / 结束计时 / 记一条观察
    # ④ 结束后看 D:\\perf-run1\\report.md

## 它记什么（全部写进 CSV，一行一个采样点）

| 来源 | 指标 | 为什么重要 |
|---|---|---|
| 进程 | CPU（以「单核 100%」为刻度）、内存（工作集/私有）、句柄数、线程数、读写字节 | 区分「机器慢」与「软件慢」：CPU 打满 = 算法/轮询；内存一路涨 = 泄漏；句柄涨 = 资源没释放 |
| 文件 | `shensuanzi.db` / `-wal` / `-shm` 大小 | WAL 长期不归并、备份/导出把文件撑大，都在这里看得见 |
| 探针 | 三条只读查询的耗时（可选，默认关） | 把「界面卡」拆成「库慢」还是「界面重建慢」 |
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
)


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
                if name == target:
                    return int(entry.th32ProcessID)
                ok = self.kernel32.Process32Next(snapshot, ctypes.byref(entry))
            return None
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
            pct = 100.0 * delta_cpu / delta_wall
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

PROBES: Tuple[Tuple[str, str], ...] = (
    (
        "stock",
        "SELECT product_id, COALESCE(SUM(quantity), 0) FROM stock_ledger GROUP BY product_id",
    ),
    (
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
        self.pid = 0
        self._proc_warned = False
        self._attach()

    # -- 进程挂接
    def _attach(self) -> None:
        if self.args.pid:
            if self.proc and self.proc.open(int(self.args.pid)):
                self.pid = int(self.args.pid)
            else:
                print("⚠️ 打不开 PID %s 的进程（权限？）—— 进程指标将为 —" % self.args.pid)
            return
        if self.proc is None:
            return
        pid = self.proc.find_by_name(self.args.process)
        if pid is None:
            print("⚠️ 没找到进程 %s —— 先把软件打开；之后每次采样会再试。" % self.args.process)
            return
        if self.proc.open(pid):
            self.pid = pid
            print("已挂接进程 %s（PID %d）" % (self.args.process, pid))
        else:
            print("⚠️ 找到了 %s（PID %d）但打不开（试试以管理员身份运行本脚本）—— 进程指标将为 —"
                  % (self.args.process, pid))

    # -- 采样
    def sample_once(self) -> Dict[str, Any]:
        wall = time.monotonic()
        interval_ms = 0 if self._last_sample_wall is None else int((wall - self._last_sample_wall) * 1000)
        gap_ms = 0
        expected = int(self.args.interval * 1000)
        if interval_ms and expected and interval_ms > expected * 2.5:
            gap_ms = interval_ms - expected
        self._last_sample_wall = wall

        if self.proc is not None and self.pid == 0 and not self._proc_warned:
            pid = self.proc.find_by_name(self.args.process)
            if pid and self.proc.open(pid):
                self.pid = pid
                self._proc_warned = True
                print("（已自动挂接 PID %d）" % pid)

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

        row["db_mb"] = mb(self.db_path)
        row["wal_mb"] = mb(self.db_path + "-wal")
        row["shm_mb"] = mb(self.db_path + "-shm")

        if self.args.rowcount_every and len(self.samples) % self.args.rowcount_every == 0:
            counts = self._row_counts()
            row["rows_documents"] = counts.get("documents", "")
            row["rows_stock_ledger"] = counts.get("stock_ledger", "")
            row["rows_settlements"] = counts.get("settlements", "")

        if self.args.probe_interval and len(self.samples) % max(1, int(self.args.probe_interval / self.args.interval)) == 0:
            probes = run_probes(self.db_path, max(1, self.args.window_days) * 86400000)
            row["probe_stock_ms"] = "" if probes.get("stock") is None else probes["stock"]
            row["probe_list_ms"] = "" if probes.get("list") is None else probes["list"]
            row["probe_window_ms"] = "" if probes.get("window") is None else probes["window"]
        return row

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
    ) -> None:
        event = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "epoch_ms": int(time.time() * 1000),
            "kind": kind,
            "name": name,
            "duration_s": "" if duration_s is None else round(duration_s, 2),
            "feel": "" if feel is None else feel,
            "note": note,
        }
        with self.lock:
            self.events.append(event)
            self._event_writer.writerow(event)
            self._event_file.flush()
        if note:
            self.notes.append("%s %s：%s" % (event["ts"], name, note))

    # -- 人工动作
    def action_start(self, name: str) -> None:
        self.actions[name] = time.monotonic()
        self.record_event("action_start", name)
        print("  ▶ 开始计时：%s" % name)

    def action_end(self, feel: Optional[int], note: str) -> None:
        if not self.actions:
            print("（还没有开始计时的动作：先 s <动作名>）")
            return
        name = list(self.actions.keys())[-1]
        duration = time.monotonic() - self.actions.pop(name)
        self.action_records.append({"name": name, "duration_s": duration, "feel": feel, "note": note})
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

    # -- 采样线程
    def sampler_loop(self) -> None:
        while not self.stop.is_set():
            try:
                row = self.sample_once()
                self.record_sample(row)
            except Exception as exc:  # 采样失败不该让整轮测试崩掉
                self.record_event("sample_error", "采样失败", note=str(exc))
            self.poll_spool()
            self.stop.wait(self.args.interval)

    # -- 收尾
    def close(self) -> None:
        self.stop.set()
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
    add("## 一、会话")
    add("")
    add("| 项 | 值 |")
    add("|---|---|")
    add("| 开始时间 | %s |" % session.started_iso)
    add("| 持续时长 | %.1f 分钟 |" % (duration / 60.0))
    add("| 采样点 | %d（每 %.1f 秒） |" % (len(samples), args.interval))
    add("| 数据目录 | `%s` |" % os.path.dirname(session.db_path))
    add("| 库文件 | `%s`（结束时 %.1f MB） |" % (session.db_path, db_now))
    add("| 挂接进程 | %s |"
        % (("PID %d" % session.pid) if session.pid else "%s（未挂接，进程指标为 —）" % args.process))
    add("| 软件版本 | %s |" % (args.app_version or "未填写（`--app-version`）"))
    add("| 本机 | %s / %s / %s 核 / Python %s |"
        % (platform.node(), platform.platform(), os.cpu_count(), platform.python_version()))
    add("| 备注 | %s |" % (args.session_note or "—"))
    add("")

    # ---- 人工动作
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
    add("| 项 | 状态 |")
    add("|---|---|")
    for name, hint in CHECKLIST:
        mark = "✅" if name in done else "—"
        add("| %s | %s %s |" % (name, mark, hint))
    missing = [name for name, _hint in CHECKLIST if name not in done]
    add("")
    if missing:
        add("**未记录 %d 项**：%s" % (len(missing), "、".join(missing)))
    else:
        add("**清单全部覆盖。**")
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

    proc = run.add_argument_group("挂接哪个进程")
    proc.add_argument("--process", default="shensuanzi.exe", help="进程名（默认 %(default)s）")
    proc.add_argument("--pid", default=None, help="直接指定 PID（优先级高于 --process）")

    how = run.add_argument_group("采样")
    how.add_argument("--interval", type=float, default=5.0, help="采样间隔秒（默认 %(default)s）")
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
    return parser


def parse_args(argv: Optional[Sequence[str]]) -> argparse.Namespace:
    parser = build_parser()
    argv = list(sys.argv[1:] if argv is None else argv)
    # 无子命令时默认 run（少一次打字）
    if not argv or argv[0] not in ("run", "mark", "checklist", "-h", "--help"):
        argv = ["run"] + argv
    args = parser.parse_args(argv)
    if args.cmd is None:
        args.cmd = "run"
    return args


def print_help_commands() -> None:
    print("")
    print("命令：")
    print("  s <动作名>        开始计时（例：s 保存销售单）")
    print("  e [观感] [备注]    结束计时；观感 1=顺畅 2=一般 3=卡顿 4=明显卡顿 5=无响应")
    print("  m <备注>          记一条观察（不计时）")
    print("  p                立即跑一次探针")
    print("  r                打印当前摘要")
    print("  c                打印标准测试清单")
    print("  q                结束并生成报告")
    print("")


def print_checklist() -> None:
    print("")
    print("标准动作清单（按顺序做；每项用 s / e 记一次）：")
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
    print("  进程      %s" % (("PID %s" % args.pid) if args.pid else args.process))
    print("  采样      %.1f 秒/次%s"
          % (args.interval, ("；探针每 %.0f 秒" % args.probe_interval) if args.probe_interval else ""))
    if args.spool:
        print("  事件文件  %s" % args.spool)
    print("  ⚠️ 请保持本窗口开着；结束时按 q（会自动写报告）")
    if not args.quiet:
        print_help_commands()
    else:
        print("  （--quiet：不打印逐点采样；命令仍可用）")

    deadline = time.time() + args.duration * 60.0 if args.duration > 0 else None
    exit_code = 0
    try:
        while True:
            if deadline is not None and time.time() >= deadline:
                print("\n到 --duration 设定时间，自动结束。")
                break
            if args.no_input:
                time.sleep(1.0)
                continue
            try:
                raw = input("perf> ").strip()
            except (EOFError, KeyboardInterrupt):
                print("")
                break
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
        "app_version": args.app_version,
        "session_note": args.session_note,
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
    return cmd_run(args)


if __name__ == "__main__":
    raise SystemExit(main())
