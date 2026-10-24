#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""热路径查询基线：不启动软件，直接量「这些查询在这份数据上要多久」。

    python tool/perf_bench.py --data-dir "D:\\神算子数据"
    python tool/perf_bench.py --data-dir "D:\\神算子数据" --csv before.csv --rounds 30
    python tool/perf_bench.py --db .\\perf.db --explain
    python tool/perf_bench.py --list

## 为什么需要它

人工实测能回答「点下去卡不卡」，但回答不了「是这条 SQL 慢，还是界面在重建」。
这个脚本把**界面背后真正执行的那批查询**单独拎出来计时，于是：

- 换机器 / 换数据量 / 换版本后，能给出**可比较的数字**（CSV 可以直接贴进表格）；
- `--explain` 顺手打印 `EXPLAIN QUERY PLAN` —— 索引有没有被用上，一眼可见
  （例如「单据列表排序用了 `TEMP B-TREE`」就是设计如此，「`pull` 窗口 `SCAN documents`」
  才是真的缺索引）；
- 与 `perf_monitor.py` 的分工：**它测库，monitor 测整机 + 人**。

## 它测哪些查询

见 `--list`。都是**只读**查询，形状照抄自 core 的 DAO（`QueryDao` / `DocumentDao` /
`SyncServer.pull`），所以数字能代表软件里的真实开销：

| 键 | 对应软件里的位置 |
|---|---|
| `stock_group` / `stock_cost` | 库存页的「账面」「成本（均价）」、开单页的库存快照 |
| `in_transit` | 库存页的「在途」、在店可售 |
| `list_documents` | 单据列表首屏（含对方名、已退额、按日分桶排序） |
| `doc_search` | 单据页搜索（四路 LIKE） |
| `lines_of_page` | 单据列表的明细（本页 id 批量取） |
| `settled_counts` | 列表的「已收 N 笔」（批量 `IN + GROUP BY`） |
| `party_balances` / `account_balances` | 往来方页、账户页、概览 |
| `today_summary` | 概览「今日销售」 |
| `recent_products` | 开单页商品选择器的「最近使用」 |
| `pull_*` | 手机同步一次 pull 的分页 + 最近更新窗口 |
| `doc_count` | 概览「有没有单据」、列表计数 |

## 安全

**只读**：`mode=ro` 打开，不建表、不写任何行、不改 `user_version`。
软件开着也能跑（WAL 允许并发读），但**并发跑会互相抢 I/O** ——
要拿「干净基线」时请先关掉软件；要量「软件开着时的互相影响」，就开着跑，并在报告里注明。

## 依赖

Python 3.8+，只用标准库。退出码：0 正常；1 全部查询失败；2 用法/路径错误；3 读不到库。
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import sqlite3
import statistics
import sys
import time
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

DATA_FILE_NAME = "shensuanzi.db"


# --------------------------------------------------------------------------- 查询

def q_stock_group(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    return (
        "SELECT product_id, COALESCE(SUM(quantity), 0) AS v "
        "FROM stock_ledger GROUP BY product_id",
        (),
    )


def q_stock_cost(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    return (
        "SELECT product_id, COALESCE(SUM(total_cost), 0) AS v "
        "FROM stock_ledger GROUP BY product_id",
        (),
    )


def q_in_transit(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    return (
        "SELECT dl.product_id AS k, COALESCE(SUM(dl.quantity), 0) AS v "
        "FROM document_lines dl JOIN documents d ON d.id = dl.document_id "
        "WHERE d.doc_type = 'delivery' AND d.status = 'in_transit' "
        "GROUP BY dl.product_id",
        (),
    )


def q_list_documents(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    # 与 DocumentDao.listDocuments 同形：LEFT JOIN 对方名 + 派生表算「已退额」+ 按日分桶排序
    return (
        "SELECT d.*, pa.name AS party_name, COALESCE(r.rsum, 0) AS returned_sum, "
        "COALESCE(r.rcnt, 0) AS returned_count "
        "FROM documents d "
        "LEFT JOIN parties pa ON pa.id = d.party_id "
        "LEFT JOIN ("
        "  SELECT ref_doc_id AS ref, SUM(total_amount) AS rsum, COUNT(*) AS rcnt "
        "  FROM documents WHERE ref_doc_id IS NOT NULL "
        "    AND doc_type IN ('sale_return','purchase_return') GROUP BY ref_doc_id"
        ") r ON r.ref = d.id "
        "WHERE NOT (d.ref_doc_id IS NOT NULL AND d.doc_type IN ('receipt','payment')) "
        "ORDER BY ((d.occurred_at + 28800000) / 86400000) DESC, d.created_at DESC "
        "LIMIT ?",
        (limit,),
    )


def q_doc_search(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    # 四路：单号 / 对方名 / 商品名 / 条码（形状同 documents_page 的搜索）
    return (
        "SELECT d.*, pa.name AS party_name "
        "FROM documents d LEFT JOIN parties pa ON pa.id = d.party_id "
        "WHERE d.doc_no LIKE ? OR IFNULL(pa.name, '') LIKE ? "
        "   OR EXISTS (SELECT 1 FROM document_lines l JOIN products p ON p.id = l.product_id "
        "              WHERE l.document_id = d.id AND (p.name LIKE ? OR IFNULL(p.barcode,'') LIKE ?)) "
        "ORDER BY ((d.occurred_at + 28800000) / 86400000) DESC, d.created_at DESC "
        "LIMIT ?",
        ("%1%", "%1%", "%1%", "%1%", limit),
    )


def q_lines_of_page(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    return (
        "SELECT l.* FROM document_lines l WHERE l.document_id IN ("
        "  SELECT id FROM documents ORDER BY created_at DESC LIMIT ?) "
        "ORDER BY l.rowid",
        (limit,),
    )


def q_settled_counts(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    return (
        "SELECT target_doc_id AS t, COUNT(*) AS n FROM settlements "
        "WHERE target_doc_id IN (SELECT id FROM documents ORDER BY created_at DESC LIMIT ?) "
        "GROUP BY target_doc_id",
        (limit,),
    )


def q_party_balances(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    return (
        "SELECT party_id AS k, COALESCE(SUM(amount), 0) AS v "
        "FROM party_ledger GROUP BY party_id",
        (),
    )


def q_account_balances(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    return (
        "SELECT a.id AS k, a.initial_balance + COALESCE(SUM(m.amount), 0) AS v "
        "FROM accounts a LEFT JOIN money_ledger m ON m.account_id = a.id "
        "GROUP BY a.id",
        (),
    )


def q_today_summary(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    day_start = int((time.time() - (time.time() % 86400)) * 1000)
    return (
        "SELECT doc_type AS t, COUNT(*) AS c, COALESCE(SUM(total_amount), 0) AS amt "
        "FROM documents WHERE status != 'cancelled' AND occurred_at >= ? "
        "GROUP BY doc_type",
        (day_start,),
    )


def q_recent_products(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    return (
        "SELECT dl.product_id AS pid FROM document_lines dl "
        "JOIN documents d ON d.id = dl.document_id "
        "JOIN products p ON p.id = dl.product_id "
        "WHERE d.doc_type IN ('sale') AND p.is_active = 1 "
        "GROUP BY dl.product_id ORDER BY MAX(d.occurred_at) DESC LIMIT ?",
        (20,),
    )


def q_pull_stock(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    return (
        "SELECT * FROM stock_ledger WHERE seq_no > ? ORDER BY seq_no LIMIT ?",
        (0, 500),
    )


def q_pull_documents(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    return (
        "SELECT * FROM documents WHERE created_at > ? "
        "OR (created_at = ? AND id > ?) ORDER BY created_at, id LIMIT ?",
        (0, 0, "", 500),
    )


def q_pull_window(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    since = int(time.time() * 1000) - window_ms
    return (
        "SELECT * FROM documents WHERE updated_at > ? ORDER BY updated_at, id LIMIT ?",
        (since, 500),
    )


def q_doc_count(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    return ("SELECT COUNT(*) FROM documents", ())


QUERIES: Tuple[Tuple[str, str, Callable[[int, int], Tuple[str, Sequence[Any]]]], ...] = (
    ("stock_group", "库存合计（每商品）", q_stock_group),
    ("stock_cost", "成本余值（每商品）", q_stock_cost),
    ("in_transit", "在途数量（送货未签收）", q_in_transit),
    ("list_documents", "单据列表首屏", q_list_documents),
    ("doc_search", "单据页搜索（四路）", q_doc_search),
    ("lines_of_page", "本页明细批量取", q_lines_of_page),
    ("settled_counts", "本页核销笔数（批量）", q_settled_counts),
    ("party_balances", "往来余额（每方）", q_party_balances),
    ("account_balances", "账户余额（每户）", q_account_balances),
    ("today_summary", "概览今日速览", q_today_summary),
    ("recent_products", "选择器最近使用商品", q_recent_products),
    ("pull_stock", "同步 pull：库存流水一页", q_pull_stock),
    ("pull_documents", "同步 pull：单据一页", q_pull_documents),
    ("pull_window", "同步 pull：最近更新窗口", q_pull_window),
    ("doc_count", "单据总数", q_doc_count),
)


# --------------------------------------------------------------------------- 计时

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


def open_readonly(db_path: str) -> sqlite3.Connection:
    uri = "file:%s?mode=ro" % db_path.replace("\\", "/")
    conn = sqlite3.connect(uri, uri=True, timeout=10.0)
    conn.execute("PRAGMA busy_timeout = 5000")
    return conn


def table_counts(conn: sqlite3.Connection) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for table in (
        "products",
        "parties",
        "accounts",
        "documents",
        "document_lines",
        "stock_ledger",
        "money_ledger",
        "party_ledger",
        "settlements",
    ):
        try:
            out[table] = int(conn.execute("SELECT COUNT(*) FROM %s" % table).fetchone()[0])
        except sqlite3.Error:
            out[table] = -1
    return out


def file_mb(path: str) -> float:
    try:
        return os.path.getsize(path) / (1024.0 * 1024.0)
    except OSError:
        return 0.0


def run_one(
    conn: sqlite3.Connection,
    sql: str,
    params: Sequence[Any],
    rounds: int,
    warmup: int,
) -> Tuple[List[float], int, Optional[str]]:
    samples: List[float] = []
    rows = 0
    error: Optional[str] = None
    for _ in range(max(0, warmup)):
        try:
            conn.execute(sql, params).fetchall()
        except sqlite3.Error as exc:
            return [], 0, str(exc)
    for _ in range(max(1, rounds)):
        t0 = time.perf_counter()
        try:
            data = conn.execute(sql, params).fetchall()
        except sqlite3.Error as exc:
            error = str(exc)
            break
        samples.append((time.perf_counter() - t0) * 1000.0)
        rows = len(data)
    return samples, rows, error


def explain(conn: sqlite3.Connection, sql: str, params: Sequence[Any]) -> List[str]:
    try:
        rows = conn.execute("EXPLAIN QUERY PLAN " + sql, params).fetchall()
    except sqlite3.Error as exc:
        return ["（EXPLAIN 失败：%s）" % exc]
    out: List[str] = []
    for row in rows:
        # sqlite3 的列顺序：id, parent, notused, detail
        out.append(str(row[-1]))
    return out


# --------------------------------------------------------------------------- 输出

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="perf_bench.py",
        description="量神算子热路径查询的耗时（只读，不启动软件）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例：\n"
            "  python tool/perf_bench.py --data-dir \"D:\\\\神算子数据\"\n"
            "  python tool/perf_bench.py --data-dir \"D:\\\\神算子数据\" --csv before.csv --rounds 30\n"
            "  python tool/perf_bench.py --db .\\\\perf.db --explain --only list_documents,pull_window\n"
        ),
    )
    where = parser.add_argument_group("目标库（二选一）")
    where.add_argument("--db", help="库文件路径")
    where.add_argument("--data-dir", help="数据目录（库名固定 %s）" % DATA_FILE_NAME)

    how = parser.add_argument_group("怎么测")
    how.add_argument("--rounds", type=int, default=20, help="每个查询跑几轮（默认 %(default)s）")
    how.add_argument("--warmup", type=int, default=3, help="预热几轮（不计入统计，默认 %(default)s）")
    how.add_argument("--limit", type=int, default=200, help="列表类查询的 LIMIT（默认 %(default)s）")
    how.add_argument(
        "--window-days", type=int, default=7, help="pull 窗口天数（默认 %(default)s）"
    )
    how.add_argument("--only", default=None, help="只跑这些（逗号分隔的键，见 --list）")
    how.add_argument("--list", action="store_true", help="列出所有查询键后退出")
    how.add_argument("--explain", action="store_true", help="额外打印 EXPLAIN QUERY PLAN")
    how.add_argument(
        "--strict", action="store_true", help="任何查询报错就以退出码 2 结束（默认跳过并继续）"
    )

    out = parser.add_argument_group("输出")
    out.add_argument("--csv", default=None, help="结果写成 CSV（一行一个查询）")
    out.add_argument("--csv-detail", default=None, help="逐次采样写成 CSV（一行一次）")
    out.add_argument("--json-out", default=None, help="结果写成 JSON（含环境信息与执行计划）")
    out.add_argument("--quiet", action="store_true", help="只打印表格，不打印说明")
    return parser


def machine_info() -> Dict[str, Any]:
    info: Dict[str, Any] = {
        "host": platform.node(),
        "os": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    try:  # Windows 上取物理内存（标准库 + ctypes，零依赖）
        import ctypes

        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        stat = MEMORYSTATUSEX()
        stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
            info["ram_gb"] = round(stat.ullTotalPhys / (1024.0 ** 3), 1)
    except Exception:
        pass
    return info


def main(argv: Optional[Sequence[str]] = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except Exception:
            pass
    args = build_parser().parse_args(argv)

    if args.list:
        for key, label, _fn in QUERIES:
            print("%-16s %s" % (key, label))
        return 0

    if args.db and args.data_dir:
        print("⛔ --db 与 --data-dir 只能指定一个。", file=sys.stderr)
        return 2
    if not args.db and not args.data_dir:
        print(
            "⛔ 必须指定 --db 或 --data-dir（脚本没有默认目标，避免误读正式数据）。",
            file=sys.stderr,
        )
        return 2

    db_path = os.path.abspath(args.db) if args.db else os.path.join(
        os.path.abspath(args.data_dir), DATA_FILE_NAME
    )
    if not os.path.isfile(db_path):
        print("⛔ 找不到库文件：%s" % db_path, file=sys.stderr)
        return 3

    only = {s.strip() for s in args.only.split(",") if s.strip()} if args.only else None
    selected = [q for q in QUERIES if only is None or q[0] in only]
    if not selected:
        print("⛔ --only 里没有可识别的查询键（用 --list 看）。", file=sys.stderr)
        return 2

    window_ms = max(1, args.window_days) * 86400000
    conn = open_readonly(db_path)
    try:
        version = int(conn.execute("PRAGMA user_version").fetchone()[0])
        counts = table_counts(conn)
        meta = machine_info()
        meta.update(
            {
                "db": db_path,
                "schema_version": version,
                "db_mb": round(file_mb(db_path), 1),
                "wal_mb": round(file_mb(db_path + "-wal"), 1),
                "counts": counts,
                "rounds": args.rounds,
                "warmup": args.warmup,
                "limit": args.limit,
            }
        )

        if not args.quiet:
            print("查询基线 —— 只读，不启动软件")
            print("  库        %s" % db_path)
            print("  schema    v%d；%.1f MB（WAL %.1f MB）"
                  % (version, meta["db_mb"], meta["wal_mb"]))
            print("  数据量    " + "  ".join(
                "%s=%s" % (k, v) for k, v in counts.items() if v >= 0))
            print("  每项      %d 轮（预热 %d）" % (args.rounds, args.warmup))
            print("")

        header = "%-16s %10s %10s %10s %8s %8s" % ("查询", "p50(ms)", "p95(ms)", "max(ms)", "行数", "说明")
        print(header)
        print("-" * len(header))

        results: List[Dict[str, Any]] = []
        detail_rows: List[Tuple[str, int, float]] = []
        failures = 0
        for key, label, factory in selected:
            sql, params = factory(args.limit, window_ms)
            samples, rows, error = run_one(conn, sql, params, args.rounds, args.warmup)
            plans = explain(conn, sql, params) if args.explain else []
            if error:
                failures += 1
                print("%-16s %10s %10s %10s %8s %8s" % (key, "—", "—", "—", "—", "报错"))
                print("    ⚠️ %s" % error)
                results.append(
                    {
                        "key": key,
                        "label": label,
                        "error": error,
                        "samples_ms": [],
                        "plan": plans,
                    }
                )
                continue
            p50 = percentile(samples, 0.5)
            p95 = percentile(samples, 0.95)
            print(
                "%-16s %10.2f %10.2f %10.2f %8d %8s"
                % (key, p50, p95, max(samples), rows, "ok")
            )
            for i, value in enumerate(samples):
                detail_rows.append((key, i + 1, value))
            results.append(
                {
                    "key": key,
                    "label": label,
                    "rows": rows,
                    "rounds": len(samples),
                    "min_ms": round(min(samples), 3),
                    "mean_ms": round(statistics.fmean(samples), 3),
                    "p50_ms": round(p50, 3),
                    "p95_ms": round(p95, 3),
                    "max_ms": round(max(samples), 3),
                    "samples_ms": [round(v, 3) for v in samples],
                    "plan": plans,
                }
            )
            if args.explain and plans:
                for line in plans:
                    print("    · %s" % line)

        print("")
        slowest = sorted(
            [r for r in results if "p95_ms" in r], key=lambda r: r["p95_ms"], reverse=True
        )[:3]
        if slowest:
            print("最慢三条（p95）：" + "，".join(
                "%s %.1f ms" % (r["key"], r["p95_ms"]) for r in slowest))
        if failures:
            print("⚠️ 有 %d 条查询报错（schema 与本脚本不同源？看上面的说明）。" % failures)

        if args.csv:
            with open(args.csv, "w", encoding="utf-8-sig", newline="") as fh:
                writer = csv.writer(fh)
                writer.writerow(
                    [
                        "key", "label", "rows", "rounds", "min_ms", "mean_ms",
                        "p50_ms", "p95_ms", "max_ms", "schema_version", "db_mb",
                        "wal_mb", "documents", "stock_ledger", "settlements", "host", "os",
                        "timestamp",
                    ]
                )
                for r in results:
                    writer.writerow(
                        [
                            r["key"], r["label"], r.get("rows", ""), r.get("rounds", ""),
                            r.get("min_ms", ""), r.get("mean_ms", ""), r.get("p50_ms", ""),
                            r.get("p95_ms", ""), r.get("max_ms", ""),
                            meta["schema_version"], meta["db_mb"], meta["wal_mb"],
                            counts.get("documents", ""), counts.get("stock_ledger", ""),
                            counts.get("settlements", ""), meta["host"], meta["os"],
                            meta["timestamp"],
                        ]
                    )
            print("已写出 %s" % args.csv)

        if args.csv_detail:
            with open(args.csv_detail, "w", encoding="utf-8-sig", newline="") as fh:
                writer = csv.writer(fh)
                writer.writerow(["key", "round", "ms"])
                writer.writerows(detail_rows)
            print("已写出 %s（逐次采样）" % args.csv_detail)

        if args.json_out:
            payload = {"meta": meta, "queries": results}
            with open(args.json_out, "w", encoding="utf-8") as fh:
                json.dump(payload, fh, ensure_ascii=False, indent=2)
            print("已写出 %s" % args.json_out)

        if failures and failures == len(selected):
            return 1
        if failures and args.strict:
            return 2
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
