#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一轮实测的 trace **一次性读成一张表**，省掉逐文件翻找。

## 它解决什么

以前每轮测试结束，要分别打开 5 个文件、按不同的形状读：

| 文件 | 形状 | 以前怎么读 |
|---|---|---|
| `startup-trace.data.jsonl` | 一行一个 `startup` / `page` / `settled` / `dbprobe` | 逐行挑 |
| `startup-trace.appdata.jsonl` | 同上，但只有 10 秒兜底的 partial 记录 | 用来反证「那份缺 T2」 |
| `page-cost.jsonl` | 一行一次「进入库存页」 | 看 builds / aggMs |
| `frame-cost.jsonl` | 一行一个 5 秒窗口 | 看 build / raster 的 p99 |
| `神算子-日志.txt` | 文本 | 找异常 |

这个脚本把它们**汇成一份 md**：启动几次、每次卡在哪一步；哪些页面首帧慢；
帧耗时的尖刺在 build 还是 raster；库存页重建了几次。

## 用法

    # ① 常规：给归集后的目录（perf_collect.py 的输出，或任意轮次目录）
    python tool/perf_report.py --dir tool/testResult/第六次真机测试/0.7.9版补充

    # ② 给整个 run 目录（会自动找 logs/ 里那份）
    python tool/perf_report.py --dir D:\\perf-run1

    # ③ 只要屏幕输出，不写文件
    python tool/perf_report.py --dir <dir> --stdout

    # ④ 换阈值（默认：开库 1000 ms / 首帧 500 ms / build p99 100 ms）
    python tool/perf_report.py --dir <dir> --slow-open 500 --slow-page 300

## 它不做什么

- **不判读**。它只把数排列出来、按阈值标颜色（`⚠️`）。「这算不算问题」仍然要人判断。
- **不跨轮对比**。两轮之间的比较要人挑（因为机器、缓存、库大小都可能不同）。
- 缺文件不报错：没有 `frame-cost.jsonl` 就少一节，并说明「这一项测不了」。

## 目录结构兼容

递归查找下面这些名字（不论在哪一层子目录里）：

- `*.jsonl` —— 按 `kind` 分流（`startup` / `page` / `settled` / `dbprobe` / `pagecost` / `frames`）
- `神算子-日志*.txt` —— 数异常

所以历史上那些手工拷的目录（`日志/抓取自数据目录/...`）也能直接吃。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

# 阈值（可在命令行改）
SLOW_OPEN_MS = 1000.0
SLOW_PAGE_MS = 500.0
SLOW_BUILD_P99_MS = 100.0

# SQLite 文件头魔数："SQLite format 3\0"
SQLITE_MAGIC = [83, 81, 76, 105, 116, 101, 32, 102, 111, 114, 109, 97, 116, 32, 51, 0]


# --------------------------------------------------------------------------
# 读
# --------------------------------------------------------------------------
def find_files(root: str) -> Tuple[List[str], List[str]]:
    """递归找 jsonl 与日志。返回 (jsonl 列表, txt 列表)。"""
    jsonls: List[str] = []
    logs: List[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        # 跳过明显无关的大目录
        dirnames[:] = [d for d in dirnames if d not in (".git", "build", "node_modules")]
        for name in filenames:
            full = os.path.join(dirpath, name)
            low = name.lower()
            if low.endswith(".jsonl"):
                jsonls.append(full)
            elif name.startswith("神算子-日志") and low.endswith(".txt"):
                logs.append(full)
    return sorted(jsonls), sorted(logs)


def load_jsonl(path: str) -> Tuple[List[Dict[str, Any]], List[str]]:
    """返回 (解析成功的对象列表, 解析失败的原始片段)。"""
    rows: List[Dict[str, Any]] = []
    bad: List[str] = []
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        return rows, bad
    for line in raw.split(b"\n"):
        s = line.strip(b"\r").strip()
        if not s:
            continue
        try:
            obj = json.loads(s.decode("utf-8"))
        except Exception:
            bad.append(s[:80].decode("utf-8", "replace"))
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows, bad


def load_log_errors(path: str) -> Tuple[int, int, List[str]]:
    """返回 (总行数, 异常行数, 异常样例)。"""
    total = errors = 0
    samples: List[str] = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                total += 1
                if ("未捕获异常" in line) or ("[错误]" in line) or ("[严重]" in line):
                    errors += 1
                    if len(samples) < 3:
                        samples.append(line.strip()[:140])
    except OSError:
        pass
    return total, errors, samples


# --------------------------------------------------------------------------
# 算
# --------------------------------------------------------------------------
def pct(values: List[float], p: float) -> float:
    """最近秩百分位（样本少时也不会插值出看不见的数）。"""
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = max(0, min(len(ordered) - 1, int(round((p / 100.0) * (len(ordered) - 1)))))
    return ordered[idx]


def marks_of(row: Dict[str, Any]) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for m in row.get("marks") or []:
        if isinstance(m, dict) and "name" in m:
            try:
                out[str(m["name"])] = int(m["ms"])
            except (TypeError, ValueError):
                continue
    return out


def fmt(value: Any, digits: int = 1, dash: str = "—") -> str:
    if value is None:
        return dash
    if isinstance(value, float):
        return ("%%.%df" % digits) % value
    return str(value)


# --------------------------------------------------------------------------
# 报告
# --------------------------------------------------------------------------
def build_md(root: str, opts: argparse.Namespace) -> str:
    jsonls, logfiles = find_files(root)

    startups: List[Dict[str, Any]] = []
    pages: List[Dict[str, Any]] = []
    settled: List[Dict[str, Any]] = []
    probes: List[Dict[str, Any]] = []
    pagecosts: List[Dict[str, Any]] = []
    frames: List[Dict[str, Any]] = []
    sources: List[Dict[str, Any]] = []

    for path in jsonls:
        rows, bad = load_jsonl(path)
        counts: Dict[str, int] = {}
        for r in rows:
            kind = r.get("kind")
            if kind == "startup":
                startups.append({**r, "_src": os.path.basename(path)})
            elif kind == "page":
                pages.append({**r, "_src": os.path.basename(path)})
            elif kind == "settled":
                settled.append({**r, "_src": os.path.basename(path)})
            elif kind == "dbprobe":
                probes.append({**r, "_src": os.path.basename(path)})
            elif kind == "pagecost":
                pagecosts.append({**r, "_src": os.path.basename(path)})
            elif kind == "frames":
                frames.append({**r, "_src": os.path.basename(path)})
            counts[str(kind)] = counts.get(str(kind), 0) + 1
        sources.append(
            {
                "name": os.path.basename(path),
                "lines": len(rows) + len(bad),
                "bad": len(bad),
                "kinds": counts,
            }
        )

    log_stats: List[Dict[str, Any]] = []
    for path in logfiles:
        total, errors, samples = load_log_errors(path)
        log_stats.append(
            {
                "name": os.path.basename(path),
                "lines": total,
                "errors": errors,
                "samples": samples,
            }
        )

    L: List[str] = []
    add = L.append

    add("# 实测数据自动分析")
    add("")
    add("> 由 `tool/perf_report.py` 生成（%s）。**只排列数字、按阈值标 `⚠️`，不代替判读。**"
        % time.strftime("%Y-%m-%d %H:%M"))
    add("> 目录：`%s`" % root)
    add("")

    # ---- ⓪ 数据源
    add("## ⓪ 数据源")
    add("")
    if not sources and not log_stats:
        add("**没找到任何 jsonl 或 神算子-日志*.txt。** 先跑 `perf_collect.py`。")
        add("")
        return "\n".join(L)
    add("| 文件 | 行数 | 问题行 | 内容 |")
    add("|---|---|---|---|")
    for s in sources:
        kinds = " · ".join("%s %d" % (k, v) for k, v in sorted(s["kinds"].items())) or "（空）"
        flag = "**%d**" % s["bad"] if s["bad"] else "0"
        add("| `%s` | %d | %s | %s |" % (s["name"], s["lines"], flag, kinds))
    for s in log_stats:
        flag = "**%d**" % s["errors"] if s["errors"] else "0"
        add("| `%s` | %d | %s | 文本日志（错误/异常 %d 条） |"
            % (s["name"], s["lines"], flag, s["errors"]))
    add("")
    add("> 「问题行」对 jsonl 是**解析失败的行数**（残行），对文本日志是错误/异常条数。")
    bad_total = sum(s["bad"] for s in sources)
    if bad_total:
        add("")
        add("⚠️ **共 %d 行解析失败（残行）** —— 埋点并发写的痕迹。"
            "2026-11-11 串行化修复后的构建应为 0，非 0 说明跑的不是那版，或又退化了。" % bad_total)
        add("")

    # ---- ① 启动
    add("## ① 启动（每次一行）")
    add("")
    if not startups:
        add("（本轮没有 startup 记录 —— 埋点 `SSZ_STARTUP_TRACE` 没开？）")
        add("")
    else:
        add("| 时刻 | 来源 | partial | 库 MB | T1 | T4 首帧 | **T2p_open** | T2 开库 | T3 服务 |")
        add("|---|---|---|---|---|---|---|---|---|")
        for r in sorted(startups, key=lambda x: str(x.get("ts", ""))):
            m = marks_of(r)
            open_ms = m.get("T2p_sqlite_open")
            t2 = m.get("T2_db_open")
            slow = (t2 is not None and t2 > opts.slow_open) or (
                open_ms is not None and open_ms > opts.slow_open
            )
            add("| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                str(r.get("ts", ""))[11:19],
                r.get("_src", ""),
                "**是**" if r.get("partial") else "",
                fmt(r.get("dbMb")),
                fmt(m.get("T1_run_app")),
                fmt(m.get("T4_first_frame")),
                ("**%d** ⚠️" % open_ms) if (open_ms is not None and open_ms > opts.slow_open) else fmt(open_ms),
                ("**%d** ⚠️" % t2) if (t2 is not None and t2 > opts.slow_open) else fmt(t2),
                fmt(m.get("T3_services")),
            ))
            if slow and not (r.get("partial")):
                pass  # 表格里已经标了，不再逐行加注释
        add("")
        slow_starts = [
            r for r in startups
            if not r.get("partial")
            and (marks_of(r).get("T2_db_open") or 0) > opts.slow_open
        ]
        if slow_starts:
            add("⚠️ **%d 次启动的开库超过 %.0f ms** —— 看 `T2p_sqlite_open` 那一格："
                "它若占绝大部分，说明慢在 `sqlite3.open()` 本身（不是 WAL / pragma / 迁移）。"
                % (len(slow_starts), opts.slow_open))
            add("")
        partials = [r for r in startups if r.get("partial")]
        if partials:
            add("· %d 条 `partial:true`：10 秒兜底先落盘的**半条**记录，缺 `T2_db_open`。"
                "**不能读成「开库快到没打点」**（正好相反）。" % len(partials))
            add("")

    # ---- ② dbprobe
    add("## ② 库探针 `dbprobe`")
    add("")
    if not probes:
        add("（没有 dbprobe —— 探针没落盘。本次所有「库大小」都不可信。）")
        add("")
    else:
        add("| 时刻 | lengthSync | statBytes | 一致 | 文件头 | 同目录文件 |")
        add("|---|---|---|---|---|---|")
        for r in sorted(probes, key=lambda x: str(x.get("ts", ""))):
            a, b = r.get("lengthSync"), r.get("statBytes")
            same = "✓" if (a is not None and a == b) else "**✗**"
            head = r.get("head") or []
            if not head:
                magic = "—（无 head 字段，无法判定）"
            elif list(head[:16]) == SQLITE_MAGIC:
                magic = "✓ SQLite"
            else:
                magic = "**✗ 不是库**"
            sib = r.get("siblings") or []
            add("| %s | %s | %s | %s | %s | %s |" % (
                str(r.get("ts", ""))[11:19],
                fmt(a),
                fmt(b),
                same,
                magic,
                "<br>".join(str(x) for x in sib) if sib else "—",
            ))
        add("")
        add("**两条独立途径读同一个大小**（`lengthSync` 与 `statSync().size`）：一致才可信。"
            "文件头不是 `SQLite format 3` ⇒ 打开的不是库（可能是刚被创建的空文件）。")
        add("")

    # ---- ③ 页面首帧
    add("## ③ 页面首帧")
    add("")
    if not pages:
        add("（没有 page 记录）")
        add("")
    else:
        by_page: Dict[str, List[float]] = {}
        for r in pages:
            name = str(r.get("page") or "?")
            try:
                by_page.setdefault(name, []).append(float(r.get("ms")))
            except (TypeError, ValueError):
                continue
        add("| 页面 | 次数 | p50 | max | 超过 %.0f ms |" % opts.slow_page)
        add("|---|---|---|---|---|")
        for name in sorted(by_page, key=lambda k: -max(by_page[k] or [0])):
            vals = by_page[name]
            over = sum(1 for v in vals if v > opts.slow_page)
            flag = ("**%d** ⚠️" % over) if over else "0"
            add("| %s | %d | %s | %s | %s |" % (
                name, len(vals), fmt(pct(vals, 50)), fmt(max(vals)), flag))
        add("")
        add("> 首帧 = 「点下导航到第一帧画完」。**不含**窗口创建、DWM 合成、显卡呈现，"
            "所以它比人眼看到的快（历史记载过「应用 3 秒就绪、用户 17 秒才看到窗口」）。")
        add("")

    # ---- ④ 帧耗时
    add("## ④ 帧耗时窗口（每 5 秒一行）")
    add("")
    if not frames:
        add("（没有 frame-cost —— 埋点 `SSZ_FRAME_TRACE` 没开？）")
        add("")
    else:
        add("| 窗口起始 | 帧数 | build p50 | build p99 | raster p50 | raster p99 | total p99 | slow |")
        add("|---|---|---|---|---|---|---|---|")
        worst: Optional[Dict[str, Any]] = None
        worst_key = -1.0
        for r in sorted(frames, key=lambda x: str(x.get("ts", ""))):
            b = r.get("build") or {}
            ra = r.get("raster") or {}
            t = r.get("total") or {}
            b99 = float(b.get("p99") or 0.0)
            if b99 > worst_key:
                worst_key = b99
                worst = r
            mark = "**%s** ⚠️" % fmt(b99) if b99 > opts.slow_build else fmt(b99)
            add("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
                str(r.get("ts", ""))[11:19],
                fmt(t.get("n"), dash="—"),
                fmt(b.get("p50"), 2),
                mark,
                fmt(ra.get("p50"), 2),
                fmt(ra.get("p99"), 2),
                fmt(t.get("p99"), 2),
                fmt(t.get("slow")),
            ))
        add("")
        if worst is not None:
            b = worst.get("build") or {}
            ra = worst.get("raster") or {}
            b99 = float(b.get("p99") or 0.0)
            r99 = float(ra.get("p99") or 0.0)
            verdict = "**build**（我们的 Widget 重建）" if b99 > r99 else "**raster**（绘制/合成）"
            add("最差窗口 `%s`：build p99 **%s ms** vs raster p99 **%s ms** ⇒ 卡在 %s。"
                % (str(worst.get("ts", ""))[11:19], fmt(b99), fmt(r99), verdict))
            add("")

    # ---- ⑤ 库存页成本
    add("## ⑤ 库存页成本（`page-cost`）")
    add("")
    if not pagecosts:
        add("（没有 page-cost —— 埋点 `SSZ_PAGE_COST_TRACE` 没开？）")
        add("")
    else:
        add("| 时刻 | 重建次数 | 停留 | 聚合累计 | 在途累计 | 每次重建（距进入 ms / 聚合 / 在途） |")
        add("|---|---|---|---|---|---|")
        for r in sorted(pagecosts, key=lambda x: str(x.get("ts", ""))):
            pb = r.get("perBuild") or []
            pb_txt = " ".join(
                "[%s,%s,%s]" % (fmt(x[0], dash="?"), fmt(x[1], dash="?"), fmt(x[2], dash="?"))
                if isinstance(x, list) and len(x) >= 3 else str(x)
                for x in pb
            ) or "—"
            builds = r.get("builds")
            flag = "**%s** ⚠️" % builds if (isinstance(builds, int) and builds > 3) else fmt(builds)
            add("| %s | %s | %s ms | %s ms | %s ms | %s |" % (
                str(r.get("ts", ""))[11:19],
                flag,
                fmt(r.get("spanMs")),
                fmt(r.get("aggMs")),
                fmt(r.get("transitMs")),
                pb_txt,
            ))
        add("")
        add("> `builds > 1` 说明这次进入期间被重建了多次。"
            "⚠️ 2026-11-11 的乙方案（聚合移出 `build`）之后，"
            "`aggMs/transitMs` 记的是**最近一次 `_loadAggregates`**，不再是「本次 build 内」——"
            "所以判断单帧变慢要看 ④ 的 build p99，不要只看这两列。")
        add("")

    # ---- ⑥ 需要看的
    add("## ⑥ 需要看的")
    add("")
    notes: List[str] = []
    if bad_total:
        notes.append("**%d 行残行** —— 埋点写入没串行化，或跑的构建早于 2026-11-11 的修复。" % bad_total)
    for s in log_stats:
        if s["errors"]:
            notes.append("`%s` 有 **%d 条错误/异常**：%s"
                         % (s["name"], s["errors"], " / ".join(s["samples"])))
    if startups and not probes:
        notes.append("有 startup 却**没有 dbprobe** —— 探针没落盘，库大小与「空库/满库」判断不可信。")
    if probes:
        for r in probes:
            a, b = r.get("lengthSync"), r.get("statBytes")
            if a is not None and b is not None and a != b:
                notes.append("dbprobe 两途径读数不一致（%s vs %s）—— 是读法/过滤驱动的问题。" % (a, b))
            head = r.get("head") or []
            if head and list(head[:16]) != SQLITE_MAGIC:
                notes.append("dbprobe 文件头不是 SQLite 魔数 —— 打开的不是库。")
    if frames and worst is not None:
        b99 = float((worst.get("build") or {}).get("p99") or 0.0)
        if b99 > opts.slow_build:
            notes.append("build p99 最差 **%s ms**（窗口 %s）—— 主 isolate 被占住了。"
                         % (fmt(b99), str(worst.get("ts", ""))[11:19]))
    if pages:
        slow_pages = [(n, max(v)) for n, v in by_page.items() if v and max(v) > opts.slow_page]
        if slow_pages:
            notes.append("首帧超 %.0f ms 的页面：%s"
                         % (opts.slow_page,
                            " · ".join("%s %s ms" % (n, fmt(m)) for n, m in sorted(slow_pages, key=lambda x: -x[1]))))
    if not notes:
        add("本轮**没有触发任何阈值**。（阈值可用 `--slow-open / --slow-page / --slow-build` 调。）")
    else:
        for n in notes:
            add("- " + n)
    add("")
    return "\n".join(L)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="perf_report.py",
        description="把一轮实测的 trace 读成一张表（启动 / 库探针 / 页面 / 帧 / 库存页成本）。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "例：\n"
            "  python tool/perf_report.py --dir tool/testResult/第六次真机测试/0.7.9版补充\n"
            "  python tool/perf_report.py --dir D:\\perf-run1 --stdout\n"
        ),
    )
    p.add_argument("--dir", required=True, help="要分析的目录（递归找 *.jsonl 与 神算子-日志*.txt）")
    p.add_argument("--out", default=None, help="输出 md 路径（默认 <dir>/analysis.md）")
    p.add_argument("--stdout", action="store_true", help="只打印，不写文件")
    p.add_argument("--slow-open", type=float, default=SLOW_OPEN_MS, help="开库慢的阈值 ms（默认 %(default)s）")
    p.add_argument("--slow-page", type=float, default=SLOW_PAGE_MS, help="页面首帧慢的阈值 ms（默认 %(default)s）")
    p.add_argument("--slow-build", type=float, default=SLOW_BUILD_P99_MS, help="build p99 阈值 ms（默认 %(default)s）")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    root = os.path.abspath(args.dir)
    if not os.path.isdir(root):
        print("✗ 目录不存在：%s" % root)
        return 2
    md = build_md(root, args)
    if args.stdout:
        print(md)
        return 0
    out = os.path.abspath(args.out) if args.out else os.path.join(root, "analysis.md")
    try:
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(md + "\n")
    except OSError as exc:
        print("✗ 写不出 %s：%s" % (out, exc))
        return 2
    print("已写出 %s" % out)
    print("")
    print(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
