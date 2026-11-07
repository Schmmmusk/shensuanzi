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
- **性能门禁**：`count_roots` / `list_roots` 的 p95 超过阈值 ⇒ **退出码 4**
  （这两条是单据页每帧真正跑的；调参时加 `--no-gate` 跳过）
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
| `doc_search` / `doc_search_count` | 单据页搜索（四路 LIKE，两段 + 「共 N 条」） |
| `lines_of_page` | 单据列表的明细（本页 id 批量取） |
| `settled_counts` | 列表的「已收 N 笔」（批量 `IN + GROUP BY`） |
| `party_balances` / `account_balances` | 往来方页、账户页、概览 |
| `today_summary` | 概览「今日销售」 |
| `recent_products` | 开单页商品选择器的「最近使用」 |
| `pull_*` | 手机同步一次 pull 的分页 + 最近更新窗口 |
| `doc_count` | 概览「有没有单据」（**裸 COUNT，不是页面跑的**） |
| `count_roots` | 单据页「共 N 条」= `countDocuments(rootsOnly)` —— **每帧都跑**（门禁） |
| `list_roots` | 单据页首屏 = `listDocuments(rootsOnly)` 两段 —— **每帧都跑**（门禁） |
| `gross_margin` | 概览「毛利趋势」= `dailyGrossMargin(30 天)`，**6 条 SQL**（N-a 新增） |
| `overview_load` | 概览页**一次 `_load()` 的全部 SQL**（最多 16 条：宽窗口营收 3 + 今日 1 + 应收/应付各一遍 `partyBalances` + 存货榜 1 + 毛利 6） |

⚠️ **改了 DAO 的 SQL 必须同步这里**，否则数字就不代表软件了。2026-11-04 踩过一次：
DAO 换成 `business_day` + 两段式后 bench 没跟上，在**健康库**上门禁照样判红
（bench 529 ms vs 真跑 18 ms）—— 假红会让人去优化一个不存在的瓶颈。
2026-11-06 又踩了**反方向**一次（用户审查 §三·1）：`doc_search` 落后两次改动，
多测了一条生产根本不跑的「条码」LIKE、少测了「子单号 / 子单明细」两条 EXISTS
⇒ 数字**两头都不对**，而且偏快（假绿）。判据同上一次：用 `--explain` 核对形状 ——
`count_roots` 不该有 `MATERIALIZE`；列表第一段该是 `USING INDEX idx_docs_bday_created`
且无 `TEMP B-TREE FOR ORDER BY`。

## 安全

**只读**：`mode=ro` 打开，不建表、不写任何行、不改 `user_version`。
软件开着也能跑（WAL 允许并发读），但**并发跑会互相抢 I/O** ——
要拿「干净基线」时请先关掉软件；要量「软件开着时的互相影响」，就开着跑，并在报告里注明。

## 依赖

Python 3.8+，只用标准库。退出码：0 正常；1 全部查询失败；2 用法/路径错误；3 读不到库。
"""

from __future__ import annotations

import argparse

import machine_info as machine_info_module
import csv
import json
import os
import platform
import sqlite3
import statistics
import sys
import time
from datetime import date, datetime
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


# ---------------------------------------------------------------------------
# 单据列表的 SQL —— 与 `DocumentDao._summaries` / `countDocuments` **逐字同形**。
#
# ⚠️ 2026-11-04 校正：这里曾经落后了**一整次重构**。DAO 在 2026-10-29（`c3946f7`）
# 把排序从表达式 `((occurred_at + 偏移) / 86400000)` 换成**固化列** `business_day`
# 并加了 `INDEXED BY idx_docs_bday_created`，`countDocuments` 也从 `_docFrom`
# （三个 join）换成 `_fromFor`（只带 WHERE 引用的表）。bench 没跟上 ⇒
# 在一份**健康**的库上门禁照样判红（实测 bench 276 / 529 ms，DAO 真跑 62.6 / 18.1 ms）。
# 这正是本文件头立的规矩「改了那边要同步这里，否则又变成测的不是跑的」被违反。
#
# 判据（改 DAO 后怎么确认 bench 没漂）：`--explain` 里
# `count_roots` 必须是 `SCAN documents`（不带任何 `MATERIALIZE`）；
# 列表第一段必须是 `SEARCH documents USING INDEX idx_docs_bday_created`
# 且**没有** `USE TEMP B-TREE FOR ORDER BY`。
# ---------------------------------------------------------------------------

#: 根单据的过滤条件（`rootsOnly: true`）—— 与 `DocumentDao._docFilter` 同源。
_DOC_ROOTS = (
    "WHERE d.ref_doc_id IS NULL AND NOT ("
    "d.doc_type IN ('receipt','payment') AND ("
    "SELECT COUNT(DISTINCT s.target_doc_id) FROM settlements s "
    "WHERE s.receipt_doc_id = d.id AND s.target_doc_id IS NOT NULL) = 1)"
)

#: `_listOrder`：业务日 → 录入时刻 → id 兜底。**不带参数**
#: （`business_day` 是写入时固化的列，不再需要时区偏移实参）。
_DOC_ORDER = "ORDER BY d.business_day DESC, d.created_at DESC, d.id DESC "

#: 列表第二段的整行 + 聚合列（`_summaryColumns`）。
_SUMMARY_COLUMNS = (
    "SELECT d.*, pa.name AS party_name, COALESCE(r.rsum, 0) AS returned_sum, "
    "COALESCE(r.rcnt, 0) AS returned_count, COALESCE(s.psum, 0) AS paid_sum "
)

#: 第一段（取 id）：`_fromFor(filter, ordered: true)`。
#:
#: 两处**不能省**：① `INDEXED BY` 是硬提示，沿索引直接取前 N 行，省掉
#: 全量排序（实测 120 ms → 0.1 ms）；② **不带** `parties` / 两个派生表 ——
#: 默认筛选下 WHERE 只引用 `d`，带上它们第一段会从 124 ms 变 316 ms。
_STAGE1_LIST = (
    "SELECT d.id FROM documents d INDEXED BY idx_docs_bday_created "
    + _DOC_ORDER
    + "LIMIT ?"
)

#: 第一段（rootsOnly）：同上，多一个根过滤。
_STAGE1_ROOTS = (
    "SELECT d.id FROM documents d INDEXED BY idx_docs_bday_created "
    + _DOC_ROOTS
    + " "
    + _DOC_ORDER
    + "LIMIT ?"
)

#: 第二段：只对这 N 个 id 聚合（派生表**必须**加 `IN (...)` 限制，
#: 否则 `s` 仍全量物化，实测只省了排序没省聚合）。
_STAGE2_LIST = (
    _SUMMARY_COLUMNS
    + "FROM documents d "
    "LEFT JOIN parties pa ON pa.id = d.party_id "
    "LEFT JOIN (SELECT ref_doc_id AS ref, SUM(total_amount) AS rsum, COUNT(*) AS rcnt "
    "  FROM documents WHERE ref_doc_id IN (%s) "
    "    AND doc_type IN ('sale_return','purchase_return') GROUP BY ref_doc_id"
    ") r ON r.ref = d.id "
    "LEFT JOIN (SELECT target_doc_id AS tgt, SUM(amount) AS psum FROM settlements "
    "  WHERE target_doc_id IN (%s) GROUP BY target_doc_id) s ON s.tgt = d.id "
    "WHERE d.id IN (%s)"
)


def _two_stage(stage1: str, limit: int):
    """把「先取 id、再按 id 取整行」包成 bench 的 callable（见 `run_one`）。"""

    def measure(conn: sqlite3.Connection) -> int:
        ids = [row[0] for row in conn.execute(stage1, (limit,)).fetchall()]
        if not ids:
            return 0
        marks = ",".join("?" * len(ids))
        sql = _STAGE2_LIST % (marks, marks, marks)
        return len(conn.execute(sql, (*ids, *ids, *ids)).fetchall())

    # 给 --explain 用：callable 本身没法 EXPLAIN，但**第一段**才是索引
    # 有没有用上的关键（第二段是按 id 点查，形状固定）。挂个属性比返回
    # 一句「见下方 *_stage 键」诚实 —— 之前那句是空头承诺，下面并没有那些键。
    measure.explain_sql = stage1  # type: ignore[attr-defined]
    measure.explain_params = (limit,)  # type: ignore[attr-defined]
    return measure, ()


def q_list_documents(limit: int, window_ms: int):
    """单据列表 —— **两段查询**（与 `DocumentDao._summaries` 同形，4c / §CV·九十九）。

    单条 SQL 表示不了「第二段的参数来自第一段的结果」，所以这里用 callable
    逐轮跑两次 —— 硬凑成 `IN (SELECT … LIMIT ?)` 会得到不同的计划，基线就不可信。
    """
    return _two_stage(_STAGE1_LIST, limit)


def _like_escape(term: str) -> str:
    """与生产同构的转义（`DocumentDao` 的 `likeEscape`）：`\\` / `%` / `_` 前置反斜杠。

    压测不转义会**低估**成本（少了转义分支）也**测不出**用户搜「50%」的真实形态 ——
    用户 2026-10-24 审查意见：压测 SQL 必须与生产同构。
    """
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


#: 「按内容找单」的四路 WHERE —— 与 `DocumentDao._docFilter` 的 `query` 分支**逐字同形**。
#:
#: ⚠️ 2026-11-06 对齐（用户审查 §三·1）：这里曾经落后**两次**改动，方向与
#: `list_documents` 那次相反（那次是 bench 比 DAO 慢、假红；这次是 bench 比 DAO 快、**假绿**）：
#:
#: | 项 | bench 旧写法 | 生产（`_docFilter`） |
#: |---|---|---|
#: | 第四路 | `p.barcode LIKE ?` | **没有条码这一路**，第四路是**子单号** `c.doc_no` |
#: | 商品那一路 | 只看 `l.document_id = d.id` | `(cd.id = d.id OR cd.ref_doc_id = d.id)` —— **子单的明细也算** |
#: | 排序 | `((occurred_at + 28800000) / 86400000)` 表达式 | 固化列 `business_day` + `INDEXED BY` |
#: | 结构 | 单段、直接取整行 | 两段（第一段只取 id） |
#:
#: 条码那一路**多出来的成本是假的**（生产不跑），而**少掉的**子单号 EXISTS 与
#: 「子单明细」那半边的成本是**真跑了却没测**—— 两个方向合起来，旧数字两头都不对。
#:
#: ⚠️ `ESCAPE '\'` 必须显式写（SQLite 没有默认转义符），与生产同理。
#:
#: 页面默认 `rootsOnly: true`（`documents_page.dart` 的 `_loadInto`），而
#: `_docFilter` 把 roots 与 query 两个条件 **AND** 在一起 ⇒ 这里也必须两条都带。
_DOC_QUERY_COND = (
    "(d.doc_no LIKE ? ESCAPE '\\' "
    "OR pa.name LIKE ? ESCAPE '\\' "
    "OR EXISTS (SELECT 1 FROM documents c "
    "  WHERE c.ref_doc_id = d.id AND c.doc_no LIKE ? ESCAPE '\\') "
    "OR EXISTS (SELECT 1 FROM document_lines l "
    "  JOIN products p ON p.id = l.product_id "
    "  JOIN documents cd ON cd.id = l.document_id "
    "  WHERE (cd.id = d.id OR cd.ref_doc_id = d.id) AND p.name LIKE ? ESCAPE '\\'))"
)

#: roots + query 的完整 WHERE（`_docFilter` 用 ` AND ` 连接 conditions，顺序同生产）。
_DOC_SEARCH_WHERE = (
    "WHERE " + _DOC_ROOTS[len('WHERE '):] + " AND " + _DOC_QUERY_COND + " "
)

#: 搜索时的 FROM：`_fromFor(filter, ordered: true)` 且 `needsParties = true`
#: （四路里有一路是 `pa.name`）⇒ **带** parties，但**不带**两个派生表
#: （`needsAggregates` 只在「未结清」筛选时为真）。
_STAGE1_SEARCH = (
    "SELECT d.id FROM documents d INDEXED BY idx_docs_bday_created "
    "LEFT JOIN parties pa ON pa.id = d.party_id "
    + _DOC_SEARCH_WHERE
    + _DOC_ORDER
    + "LIMIT ?"
)

#: 搜索时的计数 FROM：同 `_fromFor(filter)` 但**不带** `INDEXED BY`
#: （`countDocuments` 传 `ordered: false`）。
_COUNT_SEARCH = (
    "SELECT COUNT(*) AS c FROM documents d "
    "LEFT JOIN parties pa ON pa.id = d.party_id " + _DOC_SEARCH_WHERE
)


def _search_params() -> Tuple[Any, ...]:
    """搜索词固定用 `1`：单号里几乎必含，能稳定命中四路里的 EXISTS 分支。"""
    pat = f"%{_like_escape('1')}%"
    return (pat, pat, pat, pat)


def q_doc_search(limit: int, window_ms: int):
    """单据页搜索的**列表**（`listDocuments(query:, rootsOnly: true)`）—— **两段**。

    ⚠️ 与页面一致：搜索时页面跑的是 `countDocuments` + `listDocuments` **两条**
    （见 `documents_page.dart` 的 `_loadInto`），所以另有一条 `doc_search_count`。
    """

    def measure(conn: sqlite3.Connection) -> int:
        ids = [
            row[0]
            for row in conn.execute(
                _STAGE1_SEARCH, (*_search_params(), limit)
            ).fetchall()
        ]
        if not ids:
            return 0
        marks = ",".join("?" * len(ids))
        sql = _STAGE2_LIST % (marks, marks, marks)
        return len(conn.execute(sql, (*ids, *ids, *ids)).fetchall())

    measure.explain_sql = _STAGE1_SEARCH  # type: ignore[attr-defined]
    measure.explain_params = (*_search_params(), limit)  # type: ignore[attr-defined]
    return measure, _search_params()


def q_doc_search_count(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    """单据页搜索的「共 N 条」（`countDocuments(query:, rootsOnly: true)`）。"""
    return (_COUNT_SEARCH, _search_params())


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
    """概览页「今日经营」（`QueryDao.todaySummary(dayStart)`）。

    ⚠️ 2026-11-06 对齐（用户审查 §三·1）：旧写法有**两处**与生产不同 ——

    | 项 | bench 旧写法 | 生产 |
    |---|---|---|
    | 零点 | `time.time() % 86400` = **UTC** 零点 | **本地**零点（调用方 `DateTime(y,m,d)`） |
    | 上界 | **没有** | `occurred_at < 明日零点`（3c-5，§3.7 P2 #5） |

    少一个上界 ⇒ 扫的是「今天到数据库最后一张单」，在压测库上等于**全表**，
    数字比生产**大**（保守方向的误差，但仍然是错的）；UTC 零点在东八区
    会把窗口整体挪 8 小时，命中完全不同的行集。
    """
    now = datetime.now()
    day_start = int(datetime(now.year, now.month, now.day).timestamp() * 1000)
    day_end = int(datetime(now.year, now.month, now.day + 1).timestamp() * 1000)
    return (
        "SELECT doc_type AS t, COUNT(*) AS c, COALESCE(SUM(total_amount), 0) AS amt "
        "FROM documents WHERE status != 'cancelled' AND occurred_at >= ? "
        "AND occurred_at < ? "
        "GROUP BY doc_type",
        (day_start, day_end),
    )


def q_recent_products(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    # 4c：倒序走最近 2000 张单、凑满即停（与 `QueryDao.recentProducts` 同形）。
    # `INDEXED BY` 必须写 —— 不写规划器会选 type_status 再排 11.2 万行。
    return (
        "SELECT d.id AS did, dl.product_id AS pid "
        "FROM (SELECT id, occurred_at FROM documents "
        "      INDEXED BY idx_documents_occurred "
        "      WHERE doc_type IN ('sale') "
        "      ORDER BY occurred_at DESC LIMIT 2000) d "
        "JOIN document_lines dl ON dl.document_id = d.id "
        "JOIN products p ON p.id = dl.product_id "
        "WHERE p.is_active = 1 "
        "ORDER BY d.occurred_at DESC",
        (),
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


# ---------------------------------------------------------------------------
# 毛利与概览首屏（2026-11-06 补，用户审查 §三·2）
#
# 为什么必须单独测：概览页 `_load()` **一次点下去跑十几条 SQL**（最多 16 条），
# 而 bench 里原来只有零散的几条（`today_summary` / `party_balances` / `stock_cost`）。
# 「毛利图上线后概览首屏有没有退化」这个问题，用零散数字**回答不了** ——
# 尤其 `receivablesSummary()` 与 `payablesSummary()` 各自**独立**跑一次
# `partyBalances()`（整个 `party_ledger` 的 GROUP BY），**同一次加载里跑了两遍**，
# 单测 `party_balances` 只能看到一半成本。
#
# ⚠️ 这两条**不进 GATES**：门禁阈值要等低配机基线出来再定（N-d 未裁）。
# ---------------------------------------------------------------------------

#: 概览页图表天数（`_OverviewPageState._chartDays`）。
_CHART_DAYS = 30


def _business_day_of(ms: int) -> int:
    """与 core 的 `businessDayOf()` 同式：`((ms + offset) / 86400000).floor()`。

    偏移取**那个时刻**的本地偏移（含夏令时），与 Dart 的
    `DateTime.fromMillisecondsSinceEpoch(ms).timeZoneOffset` 一致。
    """
    offset = datetime.fromtimestamp(ms / 1000.0).astimezone().utcoffset()
    return (ms + int(offset.total_seconds() * 1000)) // 86400000


#: 业务日 0（1970-01-01）对应的 `date.toordinal()`。
_EPOCH_ORDINAL = date(1970, 1, 1).toordinal()


def _day_to_date(day: int) -> date:
    return date.fromordinal(_EPOCH_ORDINAL + day)


def _month_start_day(day: int) -> int:
    """该业务日所在月的 1 号（业务日序号）。走公历日历，不自己算闰年。"""
    return _day_to_date(day).replace(day=1).toordinal() - _EPOCH_ORDINAL


def _month_compare_window(today_day: int) -> Tuple[int, int]:
    """复刻 `monthCompareWindow()`，只取「宽窗口的下界」。

    返回 `(prior_from, prior_to)`。概览页用 `min(prior_from, fromDay)` 当
    `dailyRevenue` 的起点 —— 今天几号决定要不要回到上月初，所以**压测窗口
    会随日期变化**，这是**真实行为**，不是压测脚本的不稳定。
    """
    today = _day_to_date(today_day)
    current_from = today_day - (today.day - 1)
    prior_from = _month_start_day(current_from - 1)
    prior_month_end = _month_start_day(prior_from + 32) - 1
    prior_days = min(today.day, prior_month_end - prior_from + 1)
    return prior_from, prior_from + prior_days - 1


#: `dailyRevenue` 的三条腿（与 `QueryDao.dailyRevenue` 逐字同形）。
_REVENUE_LEGS: Tuple[Tuple[str, Tuple[Any, ...]], ...] = (
    (
        "SELECT business_day AS d, COUNT(*) AS c, COALESCE(SUM(total_amount), 0) AS amt "
        "FROM documents WHERE doc_type = ? AND status != ? AND business_day BETWEEN ? AND ? "
        "GROUP BY business_day",
        ("sale", "cancelled"),
    ),
    (
        "SELECT business_day AS d, COUNT(*) AS c, COALESCE(SUM(total_amount), 0) AS amt, "
        "SUM(CASE WHEN status = ? THEN 1 ELSE 0 END) AS transit, "
        "SUM(CASE WHEN status = ? THEN total_amount ELSE 0 END) AS transit_amt "
        "FROM documents WHERE doc_type = ? AND status != ? AND business_day BETWEEN ? AND ? "
        "GROUP BY business_day",
        ("in_transit", "in_transit", "delivery", "cancelled"),
    ),
    (
        "SELECT r.business_day AS d, COUNT(*) AS c, COALESCE(SUM(r.total_amount), 0) AS amt "
        "FROM documents r LEFT JOIN documents o ON o.id = r.ref_doc_id "
        "WHERE r.doc_type = ? AND r.status != ? AND (o.id IS NULL OR o.status != ?) "
        "AND r.business_day BETWEEN ? AND ? GROUP BY r.business_day",
        ("sale_return", "cancelled", "cancelled"),
    ),
)

#: `dailyGrossMargin` **自己**的三条腿（收入腿复用上面那三条 ⇒ 合计 6 条）。
_MARGIN_LEGS: Tuple[Tuple[str, Tuple[Any, ...]], ...] = (
    (
        "SELECT d.business_day AS day, COALESCE(SUM(s.total_cost), 0) AS cost "
        "FROM stock_ledger s JOIN documents d ON d.id = s.document_id "
        "WHERE d.doc_type IN (?, ?) AND d.status != ? "
        "AND d.business_day BETWEEN ? AND ? GROUP BY d.business_day",
        ("sale", "delivery", "cancelled"),
    ),
    (
        "SELECT d.business_day AS day, COALESCE(SUM(s.total_cost), 0) AS cost "
        "FROM stock_ledger s JOIN documents d ON d.id = s.document_id "
        "WHERE d.doc_type = ? AND d.status != ? AND s.total_cost < 0 "
        "AND d.business_day BETWEEN ? AND ? GROUP BY d.business_day",
        ("stocktake", "cancelled"),
    ),
    (
        "SELECT r.business_day AS day, COALESCE(SUM(s.total_cost), 0) AS cost "
        "FROM stock_ledger s JOIN documents r ON r.id = s.document_id "
        "LEFT JOIN documents o ON o.id = r.ref_doc_id "
        "WHERE r.doc_type = ? AND r.status != ? AND (o.id IS NULL OR o.status != ?) "
        "AND r.business_day BETWEEN ? AND ? GROUP BY r.business_day",
        ("sale_return", "cancelled", "cancelled"),
    ),
)


def _run_legs(
    conn: sqlite3.Connection,
    legs: Sequence[Tuple[str, Tuple[Any, ...]]],
    from_day: int,
    to_day: int,
) -> int:
    rows = 0
    for sql, head in legs:
        rows += len(conn.execute(sql, (*head, from_day, to_day)).fetchall())
    return rows


def _margin_window() -> Tuple[int, int]:
    to_day = _business_day_of(int(time.time() * 1000))
    return to_day - (_CHART_DAYS - 1), to_day


def q_gross_margin(limit: int, window_ms: int):
    """概览「毛利趋势」= `dailyGrossMargin(近 30 天)` —— **6 条 SQL**。

    收入腿 3 条（复用 `dailyRevenue`，口径不分叉）+ 成本腿 3 条。
    N-a（2026-11-06）新上的功能，之前**完全没有基线**。
    """
    from_day, to_day = _margin_window()

    def measure(conn: sqlite3.Connection) -> int:
        return _run_legs(conn, _REVENUE_LEGS + _MARGIN_LEGS, from_day, to_day)

    measure.explain_sql = _MARGIN_LEGS[0][0]  # type: ignore[attr-defined]
    measure.explain_params = (*_MARGIN_LEGS[0][1], from_day, to_day)  # type: ignore[attr-defined]
    return measure, ()


#: 概览首屏里 `stockTop()` 那条（`QueryDao.stockTop` 的聚合子查询）。
_STOCK_TOP = (
    "SELECT p.id AS id, p.name AS name, p.unit AS unit, s.qty AS qty, s.cost AS cost "
    "FROM products p "
    "JOIN (SELECT product_id, COALESCE(SUM(quantity), 0) AS qty, "
    "             COALESCE(SUM(total_cost), 0) AS cost "
    "      FROM stock_ledger GROUP BY product_id) s ON s.product_id = p.id "
    "WHERE s.qty > 0 ORDER BY s.cost DESC, p.name ASC"
)

_PARTY_BALANCES = (
    "SELECT party_id AS k, COALESCE(SUM(amount), 0) AS v FROM party_ledger GROUP BY party_id"
)

_TODAY_SUMMARY_SQL = (
    "SELECT doc_type AS t, COUNT(*) AS c, COALESCE(SUM(total_amount), 0) AS amt "
    "FROM documents WHERE status != 'cancelled' AND occurred_at >= ? AND occurred_at < ? "
    "GROUP BY doc_type"
)


def q_overview_load(limit: int, window_ms: int):
    """概览页**一次 `_load()` 的全部 SQL**（`overview_page.dart` 的 `_load()`）。

    回答的是用户 §七 的问题 ②：「毛利图上线后，概览首屏有没有变慢」。
    逐条对应关系（**顺序照 `_load()`**）：

    | # | `_load()` 里的调用 | SQL |
    |---|---|---|
    | 1 | `hasAnyDocument()` | `SELECT 1 FROM documents LIMIT 1` |
    | 2 | `dailyRevenue(宽窗口)` | 3 条腿，窗口 = `min(priorFrom, fromDay)..toDay` |
    | 3 | `todaySummary(本地零点)` | 1 条（含上界） |
    | 4 | `receivablesSummary()` | `partyBalances()` **全表 GROUP BY** + 1 条点查 |
    | 5 | `payablesSummary()` | **又一遍** `partyBalances()` + 1 条点查 |
    | 6 | `stockTop()` | 1 条（`stock_ledger` 全表 GROUP BY + 排序） |
    | 7 | `dailyGrossMargin(30 天)` | 6 条腿 |

    ⚠️ 第 4/5 步的**两遍** `partyBalances()` 是现状，不是压测脚本写错了 ——
    要不要合并是**性能优化提案**，本轮（纯测试工具）不动生产代码。
    """
    to_day = _business_day_of(int(time.time() * 1000))
    from_day = to_day - (_CHART_DAYS - 1)
    prior_from, _prior_to = _month_compare_window(to_day)
    wide_from = min(prior_from, from_day)
    now = datetime.now()
    day_start = int(datetime(now.year, now.month, now.day).timestamp() * 1000)
    day_end = int(datetime(now.year, now.month, now.day + 1).timestamp() * 1000)

    def measure(conn: sqlite3.Connection) -> int:
        rows = 0
        rows += len(conn.execute("SELECT 1 FROM documents LIMIT 1").fetchall())
        rows += _run_legs(conn, _REVENUE_LEGS, wide_from, to_day)
        rows += len(conn.execute(_TODAY_SUMMARY_SQL, (day_start, day_end)).fetchall())
        # 应收 / 应付：**各自独立**跑一遍 partyBalances（生产现状 —— 同一次加载里
        # 整个 party_ledger 被 GROUP BY 了两遍）。top 的取法也照 `_duesSummary`：
        # 应收取「正得最多」，应付取「负得最多」。
        for positive in (True, False):
            balances = conn.execute(_PARTY_BALANCES).fetchall()
            rows += len(balances)
            if positive:
                dues = [r for r in balances if (r[1] or 0) > 0]
            else:
                dues = [r for r in balances if (r[1] or 0) < 0]
            if dues:
                top = max(dues, key=lambda r: abs(r[1] or 0))
                rows += len(
                    conn.execute(
                        "SELECT name, is_active FROM parties WHERE id = ?", (top[0],)
                    ).fetchall()
                )
        rows += len(conn.execute(_STOCK_TOP).fetchall())
        rows += _run_legs(conn, _REVENUE_LEGS + _MARGIN_LEGS, from_day, to_day)
        return rows

    measure.explain_sql = _STOCK_TOP  # type: ignore[attr-defined]
    measure.explain_params = ()  # type: ignore[attr-defined]
    return measure, ()



# ---------------------------------------------------------------------------
# 下面两条是**单据页每帧真正跑的东西**（2026-10-28 补，2026-11-04 对齐重构）。
#
# 为什么必须单独列出来：`doc_count` 是裸 `COUNT(*)`（3.5 ms），可单据页跑的是
# `countDocuments(rootsOnly: true)`。真机实测 **267 ms**，而 bench 报 3.5 ms
# ⇒ 报告里一片绿，页面上 2 秒。这个盲区让我们在上一轮把「页面卡」
# 误判成「界面重建慢」。
#
# ⚠️ 反方向的同一个坑（2026-11-04）：DAO 在 2026-10-29 换成
# `_fromFor`（不带无用 join）+ 两段式 + `business_day` 索引后，这两条**没跟上**，
# 于是在健康库上门禁照样判红（bench 276 / 529 ms vs DAO 真跑 62.6 / 18.1 ms）。
# 「测的不是跑的」两个方向都会骗人 —— 假红和假绿一样有害，假红会让人去优化
# 一个根本不存在的瓶颈。SQL 现在与 `countDocuments` / `_summaries` 逐字同形。
# ---------------------------------------------------------------------------


def q_count_roots(limit: int, window_ms: int) -> Tuple[str, Sequence[Any]]:
    """单据页的「共 N 条」（`countDocuments(rootsOnly: true)`）。

    ⚠️ 用 `_fromFor` 的形状（**只有 `documents`**），不是 `_docFrom` 的三个 join：
    `COUNT(*)` 用不到「退货汇总 / 核销汇总」两个派生表，带上它们会被整表物化
    （实测 300 ms vs 61 ms，2026-10-28，26 万单库）。
    """
    return ("SELECT COUNT(*) AS c FROM documents d " + _DOC_ROOTS, ())


def q_list_roots(limit: int, window_ms: int):
    """单据页首屏（`listDocuments(rootsOnly: true, limit: 200)`）—— **两段**。

    与 `list_documents` 同一形状，只差第一段的 roots 过滤（DAO 里也是同一份
    `_summaries`，靠 `_docFilter(rootsOnly:)` 分派）。
    """
    return _two_stage(_STAGE1_ROOTS, limit)


#: **性能门禁**：这些查询的 p95 超过阈值即判红（退出码 4）。
#:
#: 为什么只给这两条：它们是**页面每帧真正跑的**（`countDocuments(rootsOnly)` /
#: `listDocuments(rootsOnly, 200)`）。
#:
#: ## 阈值怎么来的（2026-11-04 重定，裁定「甲」）
#:
#: 旧阈值（120 / 200 ms）是照**重构前**的单段 SQL 定的，重构后照样判红 ⇒
#: 门禁拦的是不存在的性能问题。新阈值取「当前实测 p95 的 3 倍」，
#: 在 498.7 MB / 262,693 单 / schema v8 的库上（`perf_seed.py --min-rows 100000`）：
#:
#: | 查询 | 实测 p50 | 实测 p95 | 阈值 | 倍数 |
#: |---|---|---|---|---|
#: | `count_roots` | 62.6 | 64.1 | 200 | 3.1× |
#: | `list_roots`（两段合计） | 18.1 | 24.3 | 80 | 3.3× |
#:
#: ⚠️ 阈值不是性能目标，是**防退化护栏**：谁把 `_fromFor` 的派生表又加回来
#: （实测 62 → 300 ms）、或把 `INDEXED BY` / `business_day` 排序弄丢
#: （实测第一段 0.1 → 120 ms），这条立刻红。要放宽就改这里并写明理由。
#:
#: ## 判据只有一个：**p95**（三处描述以本表为准）
#:
#: 文件头、`--list` 的输出、下面的判定代码，说的都是同一件事 ——
#: `--list` 的阈值是**从本表现取**的，不再抄一遍，所以不会漂移。
#:
#: **为什么是 p95 不是 p50**：门禁要拦的是「偶发的卡顿」——p50 是「平时多快」，
#: 一次全表扫描混在 30 轮里几乎不动 p50，却会把 p95 抬起来。用户记住的正是那几次。
#:
#: ⏳ **N-d 未裁**：是否给 `doc_search` / `today_summary` 也加门禁（建议按同一
#: 「实测 p95 × 3」的定法）。裁了就往本表加行，**别在别处另写一套判据**。
GATES: Dict[str, float] = {
    "count_roots": 200.0,
    "list_roots": 80.0,
}

QUERIES: Tuple[Tuple[str, str, Callable[[int, int], Tuple[str, Sequence[Any]]]], ...] = (
    ("stock_group", "库存合计（每商品）", q_stock_group),
    ("stock_cost", "成本余值（每商品）", q_stock_cost),
    ("in_transit", "在途数量（送货未签收）", q_in_transit),
    ("list_documents", "单据列表首屏", q_list_documents),
    ("doc_search", "单据页搜索（四路，两段）", q_doc_search),
    ("doc_search_count", "单据页搜索「共 N 条」", q_doc_search_count),
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
    ("count_roots", "单据页「共 N 条」（rootsOnly，每帧都跑）", q_count_roots),
    ("list_roots", "单据页首屏（rootsOnly 两段，每帧都跑）", q_list_roots),
    ("gross_margin", "概览毛利趋势（近 30 天，6 条腿）", q_gross_margin),
    ("overview_load", "概览首屏一次 _load()（全部 SQL，最多 16 条）", q_overview_load),
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
    # 4c（2026-10-24）：**多步查询**（两段查询：先取 id、再按 id 取整行）用 callable
    # 表达 —— 单条 SQL 无法表示「第二段的参数来自第一段的结果」，硬凑成子查询
    # 会得到不同的执行计划，基线就不可信了。
    if callable(sql):
        fn = sql
        for _ in range(max(0, warmup)):
            try:
                fn(conn)
            except sqlite3.Error as exc:
                return [], 0, str(exc)
        for _ in range(max(1, rounds)):
            t0 = time.perf_counter()
            try:
                rows = fn(conn)
            except sqlite3.Error as exc:
                error = str(exc)
                break
            samples.append((time.perf_counter() - t0) * 1000.0)
        return samples, rows, error
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
    if callable(sql):
        # 多步查询：EXPLAIN **第一段**（索引是否生效只看第一段；第二段是
        # 按 id 点查，形状固定）。没有可 EXPLAIN 的第一段就明说，不编。
        #
        # ⚠️ 参数不能一律硬塞 `(200,)` —— 那是「第一段只有 LIMIT」的列表查询
        # 才成立；搜索的第一段带 4 个 LIKE 参数，毛利腿带 5 个 ⇒ 直接报
        # 「Incorrect number of bindings」。所以第一段要自带参数（`explain_params`）。
        first = getattr(sql, "explain_sql", None)
        if not first:
            return ["（多步查询，无法 EXPLAIN）"]
        sql, params = first, getattr(sql, "explain_params", (200,))
        rows = conn.execute("EXPLAIN QUERY PLAN " + sql, params).fetchall()
        return ["第一段：" + str(r[-1]) for r in rows]
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
    out.add_argument(
        "--no-gate", action="store_true", help="不做性能门禁判定（只量不判，调参时用）"
    )
    return parser


def machine_info() -> Dict[str, Any]:
    """机器配置 —— **委托给 `tool/machine_info.py`**（单一来源）。

    2026-10-28：从前这里与 `perf_monitor.py` 各写一份，两份必然漂移，而且都太薄
    （这台机器是什么 CPU / 什么盘 / 什么缩放，事后没法对照）。现在统一走共享模块：
    注册表 → ctypes → 子进程多路兜底，受限机器上逐项降级并记录「哪项被挡了」。
    """
    info: Dict[str, Any] = dict(machine_info_module.collect())
    # 兼容既有 CSV 列名（`machine` / `cpu_count`）
    info["machine"] = info.get("arch")
    info["cpu_count"] = info.get("cores_logical")
    info["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    return info


def main(argv: Optional[Sequence[str]] = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except Exception:
            pass
    args = build_parser().parse_args(argv)

    if args.list:
        # 门禁信息**从 GATES 现取**，不在这里重述一遍 —— 三处各写一遍是
        # 「描述与实现漂移」的温床（纪律 17）。判据统一是 **p95**，见 GATES 注释。
        for key, label, _fn in QUERIES:
            gate = GATES.get(key)
            mark = "  【门禁 p95 > %.0f ms】" % gate if gate is not None else ""
            print("%-16s %s%s" % (key, label, mark))
        print("")
        print("门禁判据：只有标了【门禁】的键参与判定，比较的是 **p95**（不是 p50、不是 max）。")
        print("          阈值 = 定阈值那台机器实测 p95 的约 3 倍，是防退化护栏不是性能目标；")
        print("          单一来源是脚本里的 GATES 表，要改阈值改那里并写明理由。")
        print("          调参 / 换机器时先加 --no-gate 只量不判。")
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

        # ---- 性能门禁（2026-10-28，用户裁定 A-2）----
        breaches: List[Tuple[str, float, float]] = []
        if not args.no_gate:
            for r in results:
                limit = GATES.get(r["key"])
                if limit is not None and "p95_ms" in r and r["p95_ms"] > limit:
                    breaches.append((r["key"], r["p95_ms"], limit))
            if breaches:
                print("")
                print("⛔ 性能门禁未通过（p95 超过阈值）：")
                for key, value, limit in breaches:
                    print("   %-16s %8.1f ms > %.0f ms" % (key, value, limit))
                print("   判据见 GATES 表；确属预期就加 --no-gate，并把理由写进提交消息。")

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

        if breaches:
            return 4
        if failures and failures == len(selected):
            return 1
        if failures and args.strict:
            return 2
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
