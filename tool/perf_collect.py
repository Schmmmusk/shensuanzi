#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把**散在三处**的实测数据收进一个目录，顺带做「数据可用性体检」。

## 它解决什么

实测时数据天然散在三处，以前每次都要人工去翻、去拷、去改文件名：

| 位置 | 有什么 | 谁写的 |
|---|---|---|
| `<数据目录>\\日志\\` | `startup-trace.jsonl` / `page-cost.jsonl` / `frame-cost.jsonl` | 软件自己（`--dart-define` 埋点） |
| `%APPDATA%\\神算子\\日志\\` | `神算子-日志.txt` / `startup-trace.jsonl`（**partial 那份**） | 软件自己 |
| `--out` 目录 | `samples.csv` / `events.csv` / `report.md` / `session.json` | `perf_monitor.py` |

跑完这一条命令，**只剩一个目录要带走**。

## 用法

    # ① 常规范式：给 run 目录，它自己从 session.json 里找出库在哪
    python tool/perf_collect.py --run D:\\perf-run1

    # ② 只有数据目录（没挂监控，比如只测冷启动）
    python tool/perf_collect.py --data-dir "F:\\神算子数据" --out D:\\collected

    # ③ 事后补收：把已经拷回家的老目录也纳进来
    python tool/perf_collect.py --run tool/testResult/第六次真机测试/0.7.9版补充 \\
        --data-dir "F:\\神算子数据"

    # ④ 只想看看会收什么，不动文件
    python tool/perf_collect.py --run D:\\perf-run1 --dry-run

## 收完长什么样

    <out>/
      logs/
        startup-trace.data.jsonl       ← 数据目录那份（含 T2/T2p/dbprobe）
        startup-trace.appdata.jsonl    ← %APPDATA% 那份（10 秒兜底的 partial 记录）
        page-cost.jsonl
        frame-cost.jsonl
        神算子-日志.data.txt
        神算子-日志.appdata.txt
        collect.json                   ← 每份的来源路径 / 大小 / mtime / 时间
      samples.csv  events.csv  report.md  session.json   ← 原本就在 run 目录里，不动

**带 `.data` / `.appdata` 后缀是故意的**：两处都有 `startup-trace.jsonl`，
同名会互相覆盖；而「哪一份缺 T2」本身就是判断依据（见 `docs/` 里 P2 那几节）。

## 顺带体检（`--verify`，默认开）

收完立刻告诉你这份数据**能不能用**，不用等到分析时才发现：

- 每个 jsonl 有几行、几行**解析失败**（残行 = 埋点并发写的痕迹）
- 有几条 `partial:true`（10 秒兜底的半条记录）
- 有 `startup` 却没有 `dbprobe`（探针没跑或被覆盖）
- 日志里有没有「未捕获异常」

体检结果同时写进 `collect.json`，`perf_report.py` 会重新算一遍并写进报告。

## 一个必须知道的边界

**软件还在跑时**，`startup-trace.jsonl` 等文件正在被追加，这时拷到的是**快照**。
脚本会看 mtime：若某个文件在最近 10 秒内还在变，会提示「可能仍在写入，建议关掉软件后再收一次」。
拷不动（被独占）时**不报错**，只记一条 warning —— 归集失败不该让整轮白跑。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

# 数据目录侧的日志子目录名（与 StartupTrace.traceFileFor 保持一致）
LOG_DIR_NAME = "日志"

# 要收的文件：(文件名, 目标名后缀, 说明)
# 后缀为空表示「只有一侧会产出」，不加重命名
WANTED: Tuple[Tuple[str, str, str], ...] = (
    ("startup-trace.jsonl", ".data", "启动/切页/稳定/库探针"),
    ("page-cost.jsonl", "", "库存页重建次数与聚合耗时"),
    ("frame-cost.jsonl", "", "帧耗时（build / raster / total）"),
    ("神算子-日志.txt", ".data", "软件自己的文本日志"),
)

# %APPDATA% 侧（同样的文件，但记录的是「还没定下数据目录」时的那几行）
WANTED_APPDATA: Tuple[Tuple[str, str, str], ...] = (
    ("startup-trace.jsonl", ".appdata", "10 秒兜底的 partial 启动记录"),
    ("神算子-日志.txt", ".appdata", "软件文本日志（早期那份）"),
)

# 判断「文件可能还在写」的窗口（秒）
RECENT_WRITE_S = 10.0

# 「软件可能还在跑」的提示：这些扩展名正在被写
LIVE_SUFFIXES = (".jsonl", ".txt")


# --------------------------------------------------------------------------
# 路径发现
# --------------------------------------------------------------------------
def _read_session(run_dir: str) -> Optional[Dict[str, Any]]:
    path = os.path.join(run_dir, "session.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def resolve_data_dir(run_dir: Optional[str], data_dir: Optional[str]) -> Tuple[Optional[str], str]:
    """定出数据目录。返回 (路径, 来源说明)。"""
    if data_dir:
        return os.path.abspath(data_dir), "--data-dir"
    if not run_dir:
        return None, "未提供"
    meta = _read_session(run_dir)
    if not meta:
        return None, "run 目录没有可读的 session.json"
    db = meta.get("db") or ""
    if not db:
        return None, "session.json 里没有 db 字段"
    # session.json 的 db 是库文件全路径 ⇒ 数据目录是它的父目录
    guess = os.path.dirname(os.path.abspath(db))
    if os.path.isdir(guess):
        return guess, "session.json 的 db 字段"
    if os.path.isdir(db):  # 万一有人把 db 传成了目录
        return os.path.abspath(db), "session.json 的 db 字段（本就是目录）"
    return None, "session.json 里的 db 路径不存在：%s" % db


def resolve_appdata(appdata: Optional[str]) -> Optional[str]:
    if appdata:
        return os.path.abspath(appdata)
    root = os.environ.get("APPDATA")
    if not root:
        return None
    cand = os.path.join(root, "神算子", LOG_DIR_NAME)
    return cand if os.path.isdir(cand) else None


# --------------------------------------------------------------------------
# 拷贝
# --------------------------------------------------------------------------
def _stat_note(path: str) -> Dict[str, Any]:
    st = os.stat(path)
    return {
        "bytes": st.st_size,
        "mtime": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(st.st_mtime)),
        "age_s": round(time.time() - st.st_mtime, 1),
    }


def collect_one(src: str, dst: str, dry_run: bool) -> Dict[str, Any]:
    """拷一份。**失败只记下来，不抛。**"""
    rec: Dict[str, Any] = {"src": src, "dst": dst}
    try:
        rec.update(_stat_note(src))
    except OSError as exc:
        rec["error"] = "读不到：%s" % exc
        return rec

    if dry_run:
        rec["copied"] = False
        rec["dry_run"] = True
        return rec

    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        rec["copied"] = True
    except OSError as exc:
        rec["copied"] = False
        rec["error"] = "拷不动（可能被独占）：%s" % exc
    return rec


def next_paths(logs_dir: str, name: str, suffix: str) -> str:
    base, ext = os.path.splitext(name)
    return os.path.join(logs_dir, base + suffix + ext)


# --------------------------------------------------------------------------
# 体检
# --------------------------------------------------------------------------
def verify_jsonl(path: str) -> Dict[str, Any]:
    """数「几行 / 几行坏 / 几条 partial / 有没有 dbprobe」。坏行就是残行。"""
    out: Dict[str, Any] = {"lines": 0, "bad": 0, "kinds": {}, "partial": 0, "bad_samples": []}
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        out["error"] = str(exc)
        return out

    for line in raw.split(b"\n"):
        s = line.strip(b"\r").strip()
        if not s:
            continue
        out["lines"] += 1
        try:
            obj = json.loads(s.decode("utf-8"))
        except Exception:
            out["bad"] += 1
            if len(out["bad_samples"]) < 3:
                out["bad_samples"].append(s[:60].decode("utf-8", "replace"))
            continue
        kind = obj.get("kind") or "?"
        out["kinds"][kind] = out["kinds"].get(kind, 0) + 1
        if obj.get("partial") is True:
            out["partial"] += 1
    return out


def verify_text(path: str) -> Dict[str, Any]:
    """数日志里的告警行。只认「未捕获异常 / 错误」这两类，避免误报。"""
    out: Dict[str, Any] = {"lines": 0, "errors": 0, "error_samples": []}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                out["lines"] += 1
                if ("未捕获异常" in line) or ("[错误]" in line) or ("[严重]" in line):
                    out["errors"] += 1
                    if len(out["error_samples"]) < 3:
                        out["error_samples"].append(line.strip()[:120])
    except OSError as exc:
        out["error"] = str(exc)
    return out


def run_verify(logs_dir: str) -> Dict[str, Any]:
    report: Dict[str, Any] = {}
    for name in sorted(os.listdir(logs_dir)):
        if name == "collect.json":
            continue
        path = os.path.join(logs_dir, name)
        if not os.path.isfile(path):
            continue
        if name.endswith(".jsonl"):
            report[name] = verify_jsonl(path)
        elif name.endswith(".txt"):
            report[name] = verify_text(path)
    return report


def health_notes(verify: Dict[str, Any]) -> List[str]:
    """把体检结果翻译成「这份数据能不能用」的几句话。"""
    notes: List[str] = []
    for name, info in verify.items():
        if info.get("bad"):
            notes.append(
                "⚠️ %s 有 %d 行**解析失败**（残行 = 埋点并发写的痕迹，2026-11-11 已串行化修复后的构建应为 0）"
                % (name, info["bad"])
            )
        kinds = info.get("kinds") or {}
        if kinds.get("startup", 0) and not kinds.get("dbprobe", 0):
            notes.append(
                "⚠️ %s 有 %d 条 startup 但**没有 dbprobe** —— 探针没落盘，库大小不可信"
                % (name, kinds["startup"])
            )
        if info.get("partial"):
            notes.append(
                "· %s 有 %d 条 `partial:true`（10 秒兜底的半条记录，缺 T2，不能当「开库快」用）"
                % (name, info["partial"])
            )
        if info.get("errors"):
            notes.append("⚠️ %s 有 %d 条错误/异常日志（样例见 collect.json）" % (name, info["errors"]))
    return notes


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------
def collect(args: argparse.Namespace) -> int:
    run_dir = os.path.abspath(args.run) if args.run else None
    if run_dir and not os.path.isdir(run_dir):
        print("✗ --run 目录不存在：%s" % run_dir)
        return 2

    data_dir, data_src = resolve_data_dir(run_dir, args.data_dir)
    appdata_dir = resolve_appdata(args.appdata)

    logs_dir = os.path.abspath(args.out) if args.out else (
        os.path.join(run_dir, "logs") if run_dir else os.path.abspath("logs")
    )

    # --quiet 只压「过程」，体检结论与退出码照旧（给脚本串起来用）
    def say(msg: str = "") -> None:
        if not args.quiet:
            print(msg)

    say("归集目标  %s" % logs_dir)
    say("数据目录  %s  （来源：%s）" % (data_dir or "（未找到）", data_src))
    say("APPDATA   %s" % (appdata_dir or "（未找到，跳过）"))
    if args.dry_run:
        say("** dry-run：只看会收什么，不动文件 **")
    say("")

    records: List[Dict[str, Any]] = []
    warnings: List[str] = []
    # 最近还在被写的文件（秒）；非空说明软件可能还在跑
    freshest: List[float] = []

    def do(src_dir: Optional[str], wanted: Tuple[Tuple[str, str, str], ...], side: str) -> None:
        if not src_dir:
            warnings.append("没有 %s 侧目录，跳过" % side)
            return
        log_dir = src_dir
        # 数据目录侧的文件在 `日志` 子目录里
        if side == "data":
            cand = os.path.join(src_dir, LOG_DIR_NAME)
            if os.path.isdir(cand):
                log_dir = cand
        for name, suffix, why in wanted:
            src = os.path.join(log_dir, name)
            if not os.path.isfile(src):
                continue
            dst = next_paths(logs_dir, name, suffix)
            rec = collect_one(src, dst, args.dry_run)
            rec["side"] = side
            rec["what"] = why
            records.append(rec)
            flag = "✓" if rec.get("copied") else ("·" if args.dry_run else "✗")
            size = rec.get("bytes")
            say("  %s %-26s %10s B  ← %s" % (
                flag,
                os.path.basename(dst),
                size if size is not None else "?",
                src,
            ))
            if rec.get("age_s") is not None and rec["age_s"] < RECENT_WRITE_S:
                # 只累计**最新**的那个 age，最后合成一条提示（逐文件说 6 遍纯属噪音）
                freshest.append(rec["age_s"])

    if not args.dry_run:
        os.makedirs(logs_dir, exist_ok=True)
    do(data_dir, WANTED, "data")
    do(appdata_dir, WANTED_APPDATA, "appdata")

    if freshest:
        warnings.append(
            "有文件在最近 %.0f 秒内还在变 —— 软件可能仍在运行，"
            "此时收到的是**快照**；要完整数据就关掉软件再收一次" % min(freshest)
        )

    if not records:
        print("  （一份都没找到）")
        print("")
        print("排查顺序：")
        print("  1. 数据目录对不对？—— 软件「帮助」页最下方有完整路径")
        print("  2. 埋点有没有开？—— 没传 --dart-define 的正式包不产出任何 trace")
        print("  3. 数据目录里有没有「日志」子目录？")
        return 1

    verify = {} if args.dry_run else run_verify(logs_dir)
    notes = health_notes(verify) if verify else []

    print("")
    if notes:
        print("体检：")
        for line in notes:
            print("  " + line)
        print("")
    if warnings:
        print("提醒：")
        for line in warnings:
            print("  · " + line)
        print("")

    if not args.dry_run:
        payload = {
            "collected_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "run_dir": run_dir,
            "data_dir": data_dir,
            "data_dir_source": data_src,
            "appdata_dir": appdata_dir,
            "files": records,
            "warnings": warnings,
            "verify": verify,
        }
        meta_path = os.path.join(logs_dir, "collect.json")
        # 追加历史，但每次都是整份重写（保留上一轮的历史数组）
        history: List[Dict[str, Any]] = []
        if os.path.isfile(meta_path):
            try:
                with open(meta_path, "r", encoding="utf-8") as fh:
                    history = json.load(fh).get("history") or []
            except Exception:
                history = []
        history.append(
            {
                "collected_at": payload["collected_at"],
                "data_dir": data_dir,
                "files": len(records),
                "bad_lines": sum(v.get("bad", 0) for v in verify.values()),
            }
        )
        payload["history"] = history[-10:]  # 只留最近 10 次，别把文件撑大
        with open(meta_path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
        print("已写出：")
        print("  %s（%d 份）" % (logs_dir, len(records)))
        print("  %s" % meta_path)

    # 有残行 / 有错误就返回非 0，方便脚本串起来时能拦住
    bad_total = sum(v.get("bad", 0) for v in verify.values())
    err_total = sum(v.get("errors", 0) for v in verify.values())
    if bad_total or err_total:
        print("")
        print("✗ 体检不通过：残行 %d 行 / 错误日志 %d 条（数据可用，但判读时要标出来）" % (bad_total, err_total))
        return 3
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="perf_collect.py",
        description="把实测数据从三个散落位置收进一个目录，并做可用性体检。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "例：\n"
            "  python tool/perf_collect.py --run D:\\perf-run1\n"
            "  python tool/perf_collect.py --data-dir \"F:\\神算子数据\" --out D:\\collected\n"
            "  python tool/perf_collect.py --run D:\\perf-run1 --dry-run\n"
        ),
    )
    p.add_argument("--run", default=None, help="perf_monitor 的 --out 目录（读 session.json 找库路径）")
    p.add_argument("--data-dir", default=None, help="数据目录（覆盖 session.json 的推断）")
    p.add_argument("--appdata", default=None, help="%%APPDATA%%\\神算子\\日志（默认自动探测）")
    p.add_argument("--out", default=None, help="收进哪个目录（默认 <run>/logs）")
    p.add_argument("--dry-run", action="store_true", help="只看会收什么，不动文件")
    p.add_argument("--quiet", action="store_true", help="只输出结论（给脚本串起来用）")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    return collect(args)


if __name__ == "__main__":
    sys.exit(main())
