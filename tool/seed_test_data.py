#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""向神算子数据库写入测试数据（供测试人员在干净环境使用）。

    python tool/seed_test_data.py --help

## 这个脚本做什么

按 `packages/shensuanzi_core/lib/src/db/schema.dart`（schema 的**单一来源**）
或随脚本分发的离线 schema 快照在目标库里写入测试数据，**默认一次 100 条**，可改。

写入范围 = **三张主数据表**（`products` / `parties` / `accounts`）。
单据与四张流水（`documents` / `document_lines` / `stock_ledger` /
`money_ledger` / `party_ledger` / `settlements`）**一律不碰**，理由见下。

## 为什么只写主数据（这不是偷懒，是纪律）

`Agents.md` 把数据分成两类：

| 类别 | 表 | 允许的操作 |
|---|---|---|
| **主数据** | `products` / `parties` / `accounts` | 新增、更新（`sync_version` 乐观锁） |
| **业务数据** | `documents` + `document_lines` + 四张流水 | **只插入，不更新，不删除** |

而且业务数据有两个不能绕过的约束：

1. **纪律 11**：任何资金流动必须挂在一张 `receipt` / `payment` 单下 ——
   直接写 `money_ledger` 而不写收付款单，造出的是**规则上不可能存在**的账；
2. **真相在流水**：库存 = `SUM(stock_ledger.quantity)`、资金 =
   `accounts.initial_balance + SUM(money_ledger.amount)` …… 单据与流水一旦
   不自洽，测出来的「账不对」是**造数造的**，不是软件的缺陷 ——
   这种假缺陷会浪费掉测试人员一整天。

要造**真实可信**的单据，唯一正确的路是走 `RuleEngine`（开机 → 开单 → 保存），
那是功能验收（`docs/desktop_acceptance.md` 第四节）的事，不是本脚本的事。
本脚本负责把**档案**填满：商品、往来方、账户 —— 开单页的选人 / 选货 /
选收款账户、库存页的搜索、导出与备份的体量，都靠这些。

## 干净环境

`--db` 指向不存在的文件、或指向一个 `user_version = 0` 的空库时，脚本会**先建表**
（开发仓库从 `schema.dart` 读取；测试设备使用随脚本分发、由该文件生成的快照 —— 见
[load_ddl_from_schema_source]），建完即为当前 schema 版本，与软件自己启动建的库
**逐字一致**。已有的库则先用 `PRAGMA user_version` 校验，版本不符就停下
（绝不往版本不匹配的库里塞数据）。

## SQL 注入数据

`--inject` 会额外写入**可能触发 SQL 注入**的数据（注入串 + 多语言 / 编码变体），
落在**所有文本列**上（`name` / `remark` / `barcode` / `phone` / `address` /
`roles` / `unit` / `code` …），用来帮测试人员定位数据库层的缺陷。

    --inject          经典 SQL 注入 + XSS + 路径穿越 + 格式串 + 编码混淆 + 宽字符
    --inject sql      只写经典 SQL 注入
    --inject encoded  额外写入「编码形态」的注入串（%27 / 双重编码 / 全角撇号 …）

**所有写入都走参数化查询**，注入串是**当作数据**存进去的字面文本；脚本自己
不会拼 SQL。所以本脚本本身不会因为注入串而损坏库 —— 它的用途是让**软件**去读
这些数据，看软件在哪一步（搜索 / 建档内联提示 / 扫码 / 导出 CSV / 同步 upsert）
失守。

## 看看会写什么，而不真写

    python tool/seed_test_data.py --dry-run --count 5

## 依赖

Python 3.8+，**只用标准库**（`sqlite3` / `argparse` / `json`）。不需要 Dart、
Flutter、pip 包或网络。Windows / macOS / Linux 通用。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import re
import sqlite3
import sys
import time
import uuid
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

# --------------------------------------------------------------------------- 常量

#: 这些表**绝不写入**。写在代码里是为了让「为什么不碰」在审查时一眼可见。
FORBIDDEN_TABLES: Tuple[str, ...] = (
    "documents",
    "document_lines",
    "stock_ledger",
    "money_ledger",
    "party_ledger",
    "settlements",
)

#: 本脚本允许写入的表。
SEEDED_TABLES: Tuple[str, ...] = ("products", "parties", "accounts")

#: schema.dart 里 `Schema.<名字>` → 真实表名。
#: ⚠️ 只包含 DDL 用到的；新增表要同步这里（[check_table_name_consistency] 会拦）。
SCHEMA_TABLE_CONSTANTS: Dict[str, str] = {
    "products": "products",
    "parties": "parties",
    "accounts": "accounts",
    "documents": "documents",
    "documentLines": "document_lines",
    "stockLedger": "stock_ledger",
    "moneyLedger": "money_ledger",
    "partyLedger": "party_ledger",
    "settlements": "settlements",
    "syncQueue": "sync_queue",
    "clockOffset": "clock_offset",
    "syncCursor": "sync_cursor",
}

#: 真实库里的表名 —— 用来校验上面的映射没写错（写错会静默建出错误表名）。
EXPECTED_TABLE_NAMES: Tuple[str, ...] = (
    "products",
    "parties",
    "accounts",
    "documents",
    "document_lines",
    "stock_ledger",
    "money_ledger",
    "party_ledger",
    "settlements",
    "sync_queue",
    "clock_offset",
    "sync_cursor",
)

DATA_FILE_NAME = "shensuanzi.db"
MARKER_FILE_NAME = ".shensuanzi-data"

DEFAULT_COUNT = 100


# ------------------------------------------------------------------- schema 抽取


class SchemaSourceError(RuntimeError):
    """从 `schema.dart` 抽取建表语句失败（文件不在 / 结构被改）。"""


def repo_root() -> str:
    """仓库根 = 本文件所在目录（`tool/`）的上一级。"""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def default_schema_source() -> str:
    return os.path.join(
        repo_root(), "packages", "shensuanzi_core", "lib", "src", "db", "schema.dart"
    )


def bundled_schema_snapshot() -> str:
    """随脚本分发的离线 schema 快照。"""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema_snapshot.json")


def schema_source_label(schema_source: Optional[str]) -> str:
    if schema_source:
        return os.path.abspath(schema_source)
    canonical = default_schema_source()
    return canonical if os.path.isfile(canonical) else bundled_schema_snapshot()


def _strip_comments(text: str) -> str:
    """去掉 Dart 行注释与块注释（块注释按 Dart 规则**支持嵌套**）。

    被去掉的字符换成等长空格、换行保留 —— 于是文本**偏移不变**，
    后面任何必须回原文定位的地方都还对得上（与 `tool/import_guard.dart` 同手法）。
    """
    out: List[str] = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if c == "/" and nxt == "*":
            out.append("  ")
            i += 2
            depth = 1
            while i < n and depth > 0:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    out.append("  ")
                    depth += 1
                    i += 2
                elif text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    out.append("  ")
                    depth -= 1
                    i += 2
                else:
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _strip_sql_comments(sql: str) -> str:
    """去掉 SQL 里的 `--` 行注释与 `/* */` 块注释。

    **为什么必须做**：`schema.dart` 的建表语句里写着大量 `-- v3（§BD）...`
    注释，而 Dart 的 `sqlite3` 包在 `execute()` 时会把注释剥掉再交给 SQLite。
    于是「源码里的字面文本」与「库里 `sqlite_master.sql` 的实际文本」并不相同 ——
    脚本要建出**逐字一致**的库，就必须跟着剥一次
    （不剥的后果：指纹对不上，人开始怀疑 schema 漂移，而其实只是注释）。

    ⚠️ 引号内的 `--` 不是注释，不能剥（用最小的引号状态机，DDL 里够用）。
    """
    out: List[str] = []
    i = 0
    n = len(sql)
    quote: Optional[str] = None
    while i < n:
        c = sql[i]
        if quote is not None:
            out.append(c)
            if c == quote:
                # DDL 里没有 `''` 转义的需求；真出现也只影响一个字符
                quote = None
            i += 1
            continue
        if c in ("'", '"'):
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "-" and i + 1 < n and sql[i + 1] == "-":
            while i < n and sql[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and sql[i + 1] == "*":
            end = sql.find("*/", i + 2)
            i = n if end < 0 else end + 2
            out.append(" ")
            continue
        out.append(c)
        i += 1
    # 收拾注释留下的空行与行尾空白，让指纹稳定
    lines = [" ".join(line.split()) for line in "".join(out).split("\n")]
    return "\n".join(line for line in lines if line)


def _dart_string_literals(text: str) -> List[Tuple[int, int, str, bool]]:
    """取 Dart 源码里的字符串字面量。

    返回 `(起始偏移, 结束偏移, 内容, 是否 raw)` 的列表。支持 `'` / `"` / `'''` / `\"\"\"`，
    跳过 `\\` 转义（raw 串不转义）。注释必须先被 [_strip_comments] 抹掉。

    ⚠️ **结束偏移是必须的**（2026-10-27 补）：Dart 里**相邻字面量是拼接**
    （`'a' 'b'` == `'ab'`），而列表元素之间才有逗号。只拿起始偏移无法区分这两种，
    见 [load_ddl_from_schema_source] 里的 `joins_previous`。
    """
    found: List[Tuple[int, int, str, bool]] = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c not in ("'", '"'):
            i += 1
            continue
        raw = False
        start = i
        if text[max(0, i - 1) : i] == "r" or text[max(0, i - 2) : i] == "r":
            # Dart 的 raw 串前缀：r'...' —— 只认紧邻的那个 r
            if i >= 1 and text[i - 1] == "r":
                raw = True
        triple = text[i : i + 3] == c * 3
        quote = c * 3 if triple else c
        i += len(quote)
        buf: List[str] = []
        while i < n:
            if not raw and text[i] == "\\" and i + 1 < n:
                buf.append(text[i : i + 2])
                i += 2
                continue
            if text.startswith(quote, i):
                i += len(quote)
                break
            buf.append(text[i])
            i += 1
        body = "".join(buf)
        if not raw:
            body = _unescape_dart(body)
        found.append((start, i, body, raw))
    return found


def _unescape_dart(body: str) -> str:
    """还原 Dart 字符串里的转义。

    只处理 DDL 里可能出现的：`\\n` `\\t` `\\r` `\\$` `\\'` `\\"` `\\\\`。
    未知转义原样保留（宁可不还原，也不要造出一个错的字符）。
    """
    out: List[str] = []
    i = 0
    n = len(body)
    simple = {
        "n": "\n",
        "t": "\t",
        "r": "\r",
        "$": "$",
        "'": "'",
        '"': '"',
        "\\": "\\",
    }
    while i < n:
        c = body[i]
        if c == "\\" and i + 1 < n:
            nxt = body[i + 1]
            if nxt in simple:
                out.append(simple[nxt])
                i += 2
                continue
            out.append(c)
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _interpolate_dart(raw_sql: str, table_constants: Dict[str, str]) -> str:
    """把 `$products` / `${Schema.products}` 换成真实表名。

    DDL 里**只应出现表名插值**。遇到别的插值就抛 —— 与其猜，不如让人来看
    （猜错会静默建出错误的表名 / 列名）。
    """
    out: List[str] = []
    i = 0
    n = len(raw_sql)
    while i < n:
        c = raw_sql[i]
        if c != "$":
            out.append(c)
            i += 1
            continue
        if i + 1 < n and raw_sql[i + 1] == "{":
            end = raw_sql.find("}", i + 2)
            if end < 0:
                raise SchemaSourceError("插值 `${` 没有闭合：%r" % raw_sql[i : i + 40])
            expr = raw_sql[i + 2 : end].strip()
            out.append(_resolve_table_constant(expr, table_constants))
            i = end + 1
            continue
        m = re.match(r"\$([A-Za-z_][A-Za-z0-9_]*)", raw_sql[i:])
        if not m:
            raise SchemaSourceError("无法解析的插值：%r" % raw_sql[i : i + 40])
        out.append(_resolve_table_constant(m.group(1), table_constants))
        i += m.end()
    return "".join(out)


def _resolve_table_constant(expr: str, table_constants: Dict[str, str]) -> str:
    name = expr.split(".")[-1].strip()
    if name not in table_constants:
        raise SchemaSourceError(
            "建表语句里出现未知插值 `%s`。本脚本只认表名插值 —— "
            "请同步 SCHEMA_TABLE_CONSTANTS（不要在这里猜表名）。" % expr
        )
    return table_constants[name]


def load_ddl_from_schema_source(schema_source: Optional[str] = None) -> Tuple[List[str], int]:
    """从源码或随脚本分发的快照读取建表语句和 schema 版本。

    开发仓库内优先读取 `schema.dart` 单一来源；在没有源码的测试设备上，
    使用与脚本一起分发的快照。快照必须从 `schema.dart` 生成并在 schema 升版时更新。

    返回 `(语句列表, schema 版本)`。
    """
    if schema_source is None:
        canonical = default_schema_source()
        if os.path.isfile(canonical):
            schema_source = canonical
        else:
            return load_ddl_from_snapshot(bundled_schema_snapshot())
    if not os.path.exists(schema_source):
        raise SchemaSourceError(
            "找不到 schema 单一来源：%s\n"
            "（请确认路径，或省略 --schema-source 使用随脚本附带的 schema 快照）" % schema_source
        )
    with open(schema_source, "r", encoding="utf-8") as fh:
        source = _strip_comments(fh.read())

    # --- Schema.version
    version: Optional[int] = None
    m = re.search(r"static\s+const\s+int\s+version\s*=\s*(\d+)\s*;", source)
    if m:
        version = int(m.group(1))
    if version is None:
        raise SchemaSourceError("在 %s 里找不到 `static const int version = N;`" % schema_source)

    # --- createStatements 的列表体
    m = re.search(
        r"static\s+const\s+List<String>\s+createStatements\s*=\s*<String>\[", source
    )
    if not m:
        m = re.search(r"static\s+const\s+List<String>\s+createStatements\s*=\s*\[", source)
    if not m:
        raise SchemaSourceError("在 %s 里找不到 createStatements 列表" % schema_source)

    open_bracket = source.index("[", m.start())
    depth = 0
    close_bracket = -1
    for i in range(open_bracket, len(source)):
        if source[i] == "[":
            depth += 1
        elif source[i] == "]":
            depth -= 1
            if depth == 0:
                close_bracket = i
                break
    if close_bracket < 0:
        raise SchemaSourceError("createStatements 列表没有闭合的 `]`")

    body = source[open_bracket + 1 : close_bracket]
    # ⚠️ **相邻字面量是拼接，不是两个列表元素**（2026-10-27 修的缺陷）。
    # v5 的覆盖索引就是这么写的：
    #     'CREATE INDEX idx_stock_covering ON $stockLedger('
    #         'product_id, seq_no, quantity, total_cost)',
    # 从前「每个字面量 = 一条语句」⇒ 拆出 `...stock_ledger(;` 与 `product_id, ...);`
    # 两条残句，空库建表直接 `near ";": syntax error`，而且快照里存的也是残句。
    # 判据只看**源码里两个字面量之间的那段文本**：有逗号 = 两个元素；只有空白 = 拼接。
    pieces: List[str] = []
    prev_end: Optional[int] = None
    for start, end, literal, _raw in _dart_string_literals(body):
        text = _interpolate_dart(literal, SCHEMA_TABLE_CONSTANTS)
        text = _strip_sql_comments(text)
        joins_previous = (
            bool(pieces) and prev_end is not None and "," not in body[prev_end:start]
        )
        prev_end = end
        if joins_previous:
            pieces[-1] += text
        elif text:
            pieces.append(text)

    statements: List[str] = []
    for piece in pieces:
        text = piece.strip()
        if not text:
            continue
        if not text.endswith(";"):
            text += ";"
        statements.append(text)
    if not statements:
        raise SchemaSourceError("createStatements 里一条语句都没解析出来")
    check_statement_shape(statements)

    check_table_name_consistency(statements)
    if os.path.abspath(schema_source) == os.path.abspath(default_schema_source()):
        snapshot_path = bundled_schema_snapshot()
        if os.path.isfile(snapshot_path):
            snapshot_statements, snapshot_version = load_ddl_from_snapshot(snapshot_path)
            if (
                snapshot_version != version
                or ddl_fingerprint(snapshot_statements) != ddl_fingerprint(statements)
            ):
                raise SchemaSourceError(
                    "脚本附带的 schema 快照已过期：请从当前 schema.dart 重新生成并分发 "
                    "schema_snapshot.json（源码 v%d，快照 v%d）"
                    % (version, snapshot_version)
                )
    return statements, version


def load_ddl_from_snapshot(snapshot_path: str) -> Tuple[List[str], int]:
    """从随脚本携带的 JSON 快照加载 schema，供无源码的测试设备使用。"""
    if not os.path.isfile(snapshot_path):
        raise SchemaSourceError(
            "找不到 schema.dart，也找不到随脚本分发的 schema 快照：%s\n"
            "（分发时请将 schema_snapshot.json 与 seed_test_data.py 放在同一目录）"
            % snapshot_path
        )
    try:
        with open(snapshot_path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
        version = int(payload["schema_version"])
        statements = payload["statements"]
        expected_fingerprint = str(payload["fingerprint"])
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise SchemaSourceError("schema 快照格式无效：%s（%s）" % (snapshot_path, exc))
    if version <= 0 or not isinstance(statements, list) or not all(
        isinstance(statement, str) and statement.strip() for statement in statements
    ):
        raise SchemaSourceError("schema 快照内容无效：%s" % snapshot_path)
    check_table_name_consistency(statements)
    actual_fingerprint = ddl_fingerprint(statements)
    if actual_fingerprint != expected_fingerprint:
        raise SchemaSourceError(
            "schema 快照指纹不匹配：%s（文件可能损坏或被不完整更新）" % snapshot_path
        )
    return statements, version


def _object_name(statement: str) -> str:
    """从 `CREATE [UNIQUE] TABLE|INDEX <name> ...` 里取对象名。

    ⚠️ 不能固定取第 3 个 token —— `CREATE UNIQUE INDEX idx_stock_seq ON ...`
    的第 3 个 token 是 `INDEX`，第 4 个才是名字（这个坑第一次写就踩了）。
    """
    m = re.match(
        r"CREATE\s+(?:UNIQUE\s+)?(?:TABLE|INDEX|VIEW|TRIGGER)\s+"
        r"(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z_][A-Za-z0-9_]*)",
        statement,
        re.IGNORECASE,
    )
    if not m:
        raise SchemaSourceError("无法从建表语句里取对象名：%r" % statement[:80])
    return m.group(1)


def check_statement_shape(statements: Sequence[str]) -> None:
    """校验每条「语句」真的是一条完整语句，而不是被切碎的残句。

    ## 为什么需要这道检查（2026-10-27 实测）

    Dart 里**相邻字符串字面量是拼接**。`schema.dart` 的 v5 覆盖索引写成

        'CREATE INDEX idx_stock_covering ON $stockLedger('
            'product_id, seq_no, quantity, total_cost)',

    旧解析器「一个字面量 = 一条语句」，于是切出两条：

        CREATE INDEX idx_stock_covering ON stock_ledger(;     ← 残句
        product_id, seq_no, quantity, total_cost);            ← 尾巴

    后果是**空库建表必然失败**（`near ";": syntax error`），而且
    `schema_snapshot.json` 里存的也是这两条残句 —— 测试机同样炸。
    更坏的是 `gen_schema_snapshot.py --check` 会**假绿**：源码侧与快照侧
    用同一个坏解析器，指纹当然一致。

    ⇒ 判据不依赖解析器自己：**每条都必须以 DDL 关键字开头、以 `;` 结尾**。
    切成残句时开头是列名（`product_id`）或结尾缺 `;`，这里立刻停住。
    """
    allowed = (
        "CREATE ",
        "DROP ",
        "ALTER ",
        "INSERT ",
        "PRAGMA ",
        "UPDATE ",
        "DELETE ",
    )
    for index, stmt in enumerate(statements):
        head = stmt.lstrip().upper()
        if not head.startswith(allowed):
            raise SchemaSourceError(
                "从 schema.dart 解析出的第 %d 条不是完整语句（很可能是被切碎的残句）：\n"
                "  %r\n"
                "常见原因：Dart 的**相邻字面量拼接**没被合并"
                "（如 'CREATE INDEX ... (' 换行 'col_a, col_b)'）。"
                % (index + 1, stmt[:120])
            )
        if not stmt.rstrip().endswith(";"):
            raise SchemaSourceError(
                "从 schema.dart 解析出的第 %d 条没有以 `;` 结尾：%r" % (index + 1, stmt[:120])
            )


def check_table_name_consistency(statements: Sequence[str]) -> None:
    """校验 `SCHEMA_TABLE_CONSTANTS` 的映射没写错。

    判据：解析出来的建表语句里的表名，必须与 [EXPECTED_TABLE_NAMES] 一致。
    写错一个（比如把 `documentLines` 映射成 `documentlines`）就会在这里停住，
    而不是等到软件打不开库才发现。
    """
    created: List[str] = []
    for stmt in statements:
        if not re.match(r"\s*CREATE\s+(?:UNIQUE\s+)?TABLE\b", stmt, re.IGNORECASE):
            continue
        created.append(_object_name(stmt))
    missing = [t for t in EXPECTED_TABLE_NAMES if t not in created]
    extra = [t for t in created if t not in EXPECTED_TABLE_NAMES]
    if missing or extra:
        raise SchemaSourceError(
            "从 schema.dart 解析出的表名与预期不符（说明 SCHEMA_TABLE_CONSTANTS 有误）：\n"
            "  少了：%s\n  多了：%s\n  预期：%s"
            % (missing, extra, list(EXPECTED_TABLE_NAMES))
        )


def object_inventory(conn: sqlite3.Connection) -> Dict[str, List[str]]:
    """从库里读出 `{表名: [...], 索引名: [...]}`（排除 SQLite 自建对象）。"""
    tables = [
        r[0]
        for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY rowid"
        )
    ]
    indexes = [
        r[0]
        for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='index' "
            "AND name NOT LIKE 'sqlite_autoindex_%' ORDER BY rowid"
        )
    ]
    return {"tables": tables, "indexes": indexes}


def normalize_statement(statement: str) -> str:
    """把一条 DDL 归一成「含义相同 ⇒ 文本相同」的形态。

    SQLite 会**原样保存**你给它的 SQL 文本，而用户机器上的库可能是**迁移**来的，
    于是同一个结构会有多种文本：

    | 差异 | 为什么会出现 | 处理 |
    |---|---|---|
    | **列顺序** | `ALTER TABLE ... ADD COLUMN` 只能**追加**到列尾（v2 的 `package_note`、v3 的五列在真库里都排在 `created_at` 之后），而 `CREATE TABLE` 里它们写在中间 | **按列名排序** |
    | `TEXT NULL` vs `TEXT` | SQLite 把显式的 `NULL` 也存进 `sqlite_master.sql`，而脚本这边是可选的 | 去掉冗余的 `NULL`（保留 `NOT NULL`） |
    | 注释 / 空白 / 大小写 | Dart 的 `sqlite3` 包剥过注释 | 全部抹平 |

    ⚠️ **不归一化会怎样**：指纹对不上 ⇒ 每次自检都报「漂移」⇒ 人开始忽略它。
    归一化之后的判据是「**结构等价**」，这才是我们要盯的东西。

    函数名里的「statement」是单数：它要求**恰好一条**语句（含一条 `;`），
    多条一起传会抛 —— 因为列级处理在 `CREATE TABLE` 里对，在 `CREATE INDEX`
    上没意义，混着处理只会让指纹更难解释。
    """
    if statement.count(";") != 1:
        raise SchemaSourceError(
            "normalize_statement 只接受恰好一条语句（含一个分号），收到 %d 个分号：%r"
            % (statement.count(";"), statement[:80])
        )
    tight = statement.replace(";", "").lower()
    tight = re.sub(r"\s+", " ", tight).strip().lstrip("\ufeff")
    # TEXT NULL / INTEGER NULL → TEXT / INTEGER
    # ⚠️ 用否定后顾断言，别用 `(?!\s*[,)])` —— `not null,` 会让 `\bnull\b` 匹配到
    # `not null` 里那个 null，删完变成 `not`（然后 `not` 又被误当成 `not unique`）。
    tight = re.sub(r"(?<!not )\bnull\b", "", tight)
    tight = re.sub(r"\s+", " ", tight).strip()

    m = re.match(r"^create table ([a-z_][a-z0-9_]*) \((.*)\)$", tight)
    if not m:
        return tight

    table, body = m.group(1), m.group(2)
    parts = _split_top_level(body)
    columns = [p.strip() for p in parts if not p.strip().startswith(("foreign key", "primary key", "unique", "check", "constraint"))]
    constraints = [p.strip() for p in parts if p.strip().startswith(("foreign key", "primary key", "unique", "check", "constraint"))]
    columns.sort()  # ← 列顺序不参与等价判断（列名与列定义都还在）
    return "create table %s (%s%s)" % (
        table,
        ", ".join(columns),
        (", " + ", ".join(sorted(constraints))) if constraints else "",
    )


def _split_top_level(body: str) -> List[str]:
    """按**顶层**逗号切分（括号内的逗号不算，如 `decimal(10,2)` / 复合外键）。"""
    parts: List[str] = []
    depth = 0
    buf: List[str] = []
    for c in body:
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if c == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
            continue
        buf.append(c)
    if buf:
        parts.append("".join(buf))
    return parts


def ddl_fingerprint(statements: Sequence[str]) -> str:
    """建表语句的结构指纹 —— 用来跨机器核对「结构是否同源」。

    同样结构的库（无论是一次性建的还是逐版迁移来的）指纹**相同**；
    指纹不同就是真有结构差异，值得停下来看。见 [normalize_statement]。
    """
    normalized = "\n".join(
        sorted(normalize_statement(s) for s in statements if s.strip())
    )
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:16]


def fingerprint_of_db(conn: sqlite3.Connection) -> str:
    """从**已存在的库**算出同一口径的指纹。

    用它来回答一个对测试人员很实用的问题：「这个库的结构与脚本的 schema
    是同一份吗？」—— 是，就可以放心写入；不是，先别写。
    """
    rows = [
        r[0]
        for r in conn.execute(
            "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL "
            "AND type IN ('table','index') AND name NOT LIKE 'sqlite_%' "
            "ORDER BY rowid"
        )
    ]
    if not rows:
        return ""
    statements = [r if r.rstrip().endswith(";") else r.rstrip() + ";" for r in rows]
    return ddl_fingerprint(statements)


# --------------------------------------------------------------------- 注入载荷
#
# 每条 = (标签, 原文)。标签用于在报告里指认「哪一条被吞了 / 被改写了」。
# ⚠️ 这些串**只当数据**存进库。脚本自己一律用参数化查询。

SQL_INJECTION_PAYLOADS: Tuple[Tuple[str, str], ...] = (
    ("sql.quote", "' OR '1'='1"),
    ("sql.comment", "'; --"),
    ("sql.union", "' UNION SELECT 1,2,3--"),
    ("sql.stacked", "'; DROP TABLE products; --"),
    ("sql.tautology", "' OR 1=1 /*"),
    ("sql.paren", "') OR ('1'='1"),
    ("sql.sleep", "'; SELECT sqlite_version(); --"),
    ("sql.attach", "'; ATTACH DATABASE 'x' AS y; --"),
    ("sql.pragma", "'; PRAGMA user_version = 999; --"),
    ("sql.delete", "'; DELETE FROM products WHERE 1=1; --"),
    ("sql.update", "'; UPDATE products SET sell_price = 1; --"),
    ("sql.insert", "'; INSERT INTO accounts VALUES('x'); --"),
    ("sql.quote.double", '" OR "1"="1'),
    ("sql.backtick", "` OR `1`=`1"),
    ("sql.hex", "0x27 OR 0x31=0x31"),
    ("sql.char", "CHAR(39)||'OR 1=1'"),
    ("sql.like", "%' OR name LIKE '%"),
    ("sql.nullbyte", "a\x00b"),
)

XSS_PAYLOADS: Tuple[Tuple[str, str], ...] = (
    ("xss.script", "<script>alert('x')</script>"),
    ("xss.img", "<img src=x onerror=alert('x')>"),
    ("xss.svg", "<svg/onload=alert('x')>"),
    ("xss.js", "javascript:alert('x')"),
)

PATH_PAYLOADS: Tuple[Tuple[str, str], ...] = (
    ("path.traversal", "../../../etc/passwd"),
    ("path.windows", r"..\..\..\Windows\System32\drivers\etc\hosts"),
    ("path.unc", r"\\?\C:\Windows\System32"),
    ("path.drive", "C:/Windows/System32/config/SAM"),
    ("path.abs", "/etc/shadow"),
)

FORMAT_PAYLOADS: Tuple[Tuple[str, str], ...] = (
    ("fmt.percent", "%s%n%d%x"),
    ("fmt.braces", "{0}{1}{name}"),
    ("fmt.dart", r"${name} ${1+1}"),
    ("fmt.shell", "$(whoami) `id`"),
)

MISC_PAYLOADS: Tuple[Tuple[str, str], ...] = (
    ("misc.newline", "第一行\n第二行\r\n第三行"),
    ("misc.tab", "甲\t乙\t丙"),
    ("misc.zero_width", "商\u200b品\u200c名\u200d称"),
    ("misc.bidi", "\u202eabc\u202c"),
    ("misc.fullwidth", "＇ＯＲ　１＝１"),
    ("misc.emoji", "牛奶🥛🍎"),
    ("misc.gb18030", "镕焘喆\u9fa5"),
    ("misc.surrogate.escape", "\\ud800\\udc00"),
    ("misc.long", "长" * 300),
    ("misc.spaces", "  　\t  "),
    ("misc.emptyish", "'\"`%_\\"),
)

#: 编码形态 —— 同一个注入串的「变形」。软件的解码链只要少走一步，
#: 变形就会在某一层还原成可执行的原文。
ENCODED_PAYLOADS: Tuple[Tuple[str, str], ...] = (
    ("enc.percent", "%27%20OR%20%271%27%3D%271"),
    ("enc.double", "%2527%2520OR%25201%253D1"),
    ("enc.unicode", "\\u0027 OR \\u0027x\\u0027=\\u0027x"),
    ("enc.html", "&#39; OR &#39;1&#39;=&#39;1"),
    ("enc.htmlhex", "&#x27;&#x4F;&#x52;&#x20;1=1"),
    ("enc.base64", "JyBPUiAnMSc9JzE="),
    ("enc.utf7", "+ACcAIABPAFIAIAAnADEAJwA9ACcAMQ"),
    ("enc.overlong", "%c0%a7%20OR%201=1"),
    ("enc.fullwidth.quote", "＇ OR １＝１"),
    ("enc.cjk.compat", "＇　ＯＲ　１＝１"),
    ("enc.nul.truncate", "safe%00'; DROP TABLE products; --"),
)

INJECT_SETS: Dict[str, Tuple[Tuple[str, str], ...]] = {
    "sql": SQL_INJECTION_PAYLOADS,
    "xss": XSS_PAYLOADS,
    "path": PATH_PAYLOADS,
    "fmt": FORMAT_PAYLOADS,
    "misc": MISC_PAYLOADS,
    "encoded": ENCODED_PAYLOADS,
}

ALL_PAYLOAD_SETS: Tuple[str, ...] = ("sql", "xss", "path", "fmt", "misc", "encoded")


def select_payloads(mode: str) -> List[Tuple[str, str]]:
    """按 `--inject` 的取值挑载荷。`all` = 全部（默认）。"""
    mode = mode.strip().lower()
    if mode in ("all", "yes", "true", "1"):
        groups = ALL_PAYLOAD_SETS
    elif mode == "full":
        groups = ALL_PAYLOAD_SETS
    elif mode in INJECT_SETS:
        groups = (mode,)
    else:
        raise SystemExit(
            "无法识别的 --inject 取值：%s\n可选：all / %s"
            % (mode, " / ".join(ALL_PAYLOAD_SETS))
        )
    out: List[Tuple[str, str]] = []
    for g in groups:
        out.extend(INJECT_SETS[g])
    return out


# ------------------------------------------------------------------ 样本词库

PRODUCT_WORDS: Tuple[str, ...] = (
    "牛奶", "大米", "面粉", "酱油", "陈醋", "食盐", "白糖", "花生油",
    "鸡蛋", "挂面", "火腿肠", "方便面", "矿泉水", "可乐", "啤酒", "纸巾",
    "洗衣粉", "洗洁精", "牙膏", "香皂", "螺丝", "螺母", "电线", "灯泡",
    "插座", "开关", "水管", "胶带", "砂纸", "油漆",
)
PRODUCT_SPECS: Tuple[str, ...] = ("", "500ml", "1L", "5kg", "10kg", "大包", "小包", "加厚", "特级")
PRODUCT_UNITS: Tuple[str, ...] = ("件", "个", "瓶", "袋", "包", "箱", "盒", "桶", "kg", "米")
PACKAGE_UNITS: Tuple[str, ...] = ("箱", "包", "提", "扎", "板")
CATEGORIES: Tuple[str, ...] = ("食品", "日杂", "五金", "饮料", "粮油", "清洁")
PACKAGE_NOTES: Tuple[str, ...] = ("整箱进货", "破损包退", "按箱结算", "")

SURNAMES: Tuple[str, ...] = ("张", "王", "李", "赵", "刘", "陈", "杨", "黄", "周", "吴", "徐", "孙")
GIVEN: Tuple[str, ...] = ("伟", "芳", "娜", "强", "磊", "洋", "静", "敏", "军", "丽", "杰", "涛")
SHOP_KINDS: Tuple[str, ...] = ("五金店", "便利店", "副食店", "建材店", "粮油店", "小卖部", "超市")
TOWNS: Tuple[str, ...] = ("城关镇", "双桥镇", "红光村", "开发区", "老城区", "新街", "河东")
STREETS: Tuple[str, ...] = ("解放路", "人民路", "建设街", "文化路", "前进巷", "环城北路")
ACCOUNT_NAMES: Tuple[str, ...] = ("现金", "微信", "支付宝", "农行卡", "工行卡", "邮政卡", "备用金")
ACCOUNT_TYPES: Tuple[str, ...] = ("cash", "wechat", "alipay", "bank", "other")
UNITS_WITH_ALIASES: Tuple[str, ...] = ("件", "个", "瓶", "袋", "箱", "盒", "斤", "箱 ")

MONEY_CEIL = 5_000_00  # 单品价格上界（分）= 5000 元


# ------------------------------------------------------------------- ID / 工具


def uuid7(now_ms: Optional[int] = None) -> str:
    """生成 UUIDv7（毫秒时间戳 + 随机尾巴），与 `Ids.newId()` 同构。

    Dart 端用 `uuid` 包的 v7；这里用标准库手搓 —— 目的是让造出来的 id
    在**形态上**与软件自己生成的一致（同长度、同连字符、字典序近似有序），
    这样测试人员拿 id 排序 / 去重时看到的行为与真实数据一样。
    """
    if now_ms is None:
        now_ms = int(time.time() * 1000)
    rand_a = random.getrandbits(12)
    rand_b = random.getrandbits(62)
    value = (now_ms & ((1 << 48) - 1)) << 80
    value |= 0x7 << 76
    value |= rand_a << 64
    value |= 0b10 << 62
    value |= rand_b
    return str(uuid.UUID(int=value))


def now_ms() -> int:
    return int(time.time() * 1000)


def yuan(cents: int) -> str:
    return "%.2f" % (cents / 100.0)


def barcode_like(rnd: random.Random, seq: int, dup_pool: Sequence[str]) -> str:
    """条码。重复条码是**允许**的（同箱拆卖 / 同款不同批次）—— 刻意制造重复。"""
    if dup_pool and rnd.random() < 0.25:
        return rnd.choice(list(dup_pool))
    return "69%011d" % (seq % 10**11)


def phone_like(rnd: random.Random) -> str:
    head = rnd.choice(("138", "139", "150", "151", "176", "188", "199", "0571", "0"))
    return head + "".join(str(rnd.randrange(10)) for _ in range(rnd.choice((7, 8))))


def pick_name(rnd: random.Random, seq: int) -> str:
    """商品名。**刻意包含重复名** —— 建档允许同名，去重逻辑要能分开。"""
    if rnd.random() < 0.2:
        return rnd.choice(PRODUCT_WORDS)
    return "%s%s%s" % (
        rnd.choice(PRODUCT_WORDS),
        rnd.choice(PRODUCT_SPECS),
        "" if rnd.random() < 0.5 else "%d号" % (seq % 50),
    )


def pick_party_name(rnd: random.Random) -> str:
    if rnd.random() < 0.45:
        return "%s%s%s" % (rnd.choice(SURNAMES), rnd.choice(GIVEN), rnd.choice(("", "老板", "师傅")))
    return "%s%s%s" % (rnd.choice(TOWNS), rnd.choice(SURNAMES), rnd.choice(SHOP_KINDS))


# ------------------------------------------------------------------- 行构造器


def make_product(index: int, code: str, rnd: random.Random, dup_barcodes: Sequence[str]) -> Dict[str, Any]:
    """造一行 `products`。

    刻意覆盖的边界（都**不是**脚本的 bug，是给测试人员的探针）：

    | 状态 | 为什么造它 |
    |---|---|
    | `package_unit` 与 `package_size` 成对 / 只填一半 / 都不填 | v3 包装换算是「成对启用」，半配置必须能被拦（验收 3.3） |
    | `package_size = 0` / 负数 | 纯函数 [toBaseQuantity] 有 `packageSizeInvalid` 兜底，档案校验本应挡住 |
    | `is_active = 0` | 停用商品：开单选不到、库存页仍能对账（验收 3.4 / 5.4） |
    | `cost_price = 0` / `sell_price = 0` | 零价商品：导出与金额求和要能扛住 |
    | `barcode` 重复 / 为空 | 条码重复**允许**，扫码多条时要有选择器（裁定 R-15） |
    | `unit` 带空白 / 全角 | 单位是文本列，前后空白会污染库存口径 |
    """
    ts = now_ms()
    unit = rnd.choice(PRODUCT_UNITS)
    if rnd.random() < 0.05:
        unit = rnd.choice(UNITS_WITH_ALIASES)

    # 包装换算三态
    roll = rnd.random()
    if roll < 0.55:
        package_unit: Optional[str] = None
        package_size: Optional[int] = None
    elif roll < 0.72:
        package_unit = rnd.choice(PACKAGE_UNITS)
        package_size = rnd.choice((6, 8, 10, 12, 20, 24, 30, 48))
    elif roll < 0.80:
        package_unit = rnd.choice(PACKAGE_UNITS)  # 半配置：只有单位
        package_size = None
    elif roll < 0.88:
        package_unit = None
        package_size = rnd.choice((6, 12))  # 半配置：只有数量
    elif roll < 0.94:
        package_unit = rnd.choice(PACKAGE_UNITS)
        package_size = 0  # 非法：0
    else:
        package_unit = rnd.choice(PACKAGE_UNITS)
        package_size = -2  # 非法：负数

    cost = rnd.randrange(50, MONEY_CEIL)
    if rnd.random() < 0.05:
        cost = 0
    sell = cost + rnd.randrange(-200, 1200)
    if sell < 0:
        sell = 0

    barcode: Optional[str] = barcode_like(rnd, index, dup_barcodes)
    if rnd.random() < 0.06:
        barcode = None

    remark: Optional[str] = None
    if rnd.random() < 0.4:
        remark = rnd.choice(
            ("老客户常拿", "供货商换过一批", "临期处理中", "促销价", "退货返修过", "")
        )

    return {
        "id": uuid7(ts),
        "code": code,
        "name": pick_name(rnd, index),
        "barcode": barcode,
        "unit": unit,
        "cost_price": cost,
        "sell_price": sell,
        "safety_stock": rnd.choice((0, 0, 5, 10, 20, 50, 100)),
        "category": rnd.choice(CATEGORIES) if rnd.random() < 0.7 else None,
        "is_active": 0 if rnd.random() < 0.12 else 1,
        "remark": remark,
        "package_note": rnd.choice(PACKAGE_NOTES) or None,
        "package_unit": package_unit,
        "package_size": package_size,
        "created_at": ts,
        "updated_at": ts,
        "sync_version": 0,
    }


def make_party(index: int, rnd: random.Random) -> Dict[str, Any]:
    """造一行 `parties`。`roles` 是 **JSON 数组文本**（`Party.encodeRoles` 的形态）。"""
    ts = now_ms()
    roles: List[str] = []
    if rnd.random() < 0.4:
        roles.append("customer")
    if rnd.random() < 0.4:
        roles.append("supplier")
    if rnd.random() < 0.15:
        roles.append("carrier")
    if not roles:
        roles = ["customer"]

    phone = phone_like(rnd)
    if rnd.random() < 0.06:
        phone = None

    address: Optional[str] = None
    if rnd.random() < 0.7:
        address = "%s%s%d号" % (rnd.choice(TOWNS), rnd.choice(STREETS), rnd.randrange(1, 300))

    return {
        "id": uuid7(ts),
        "name": pick_party_name(rnd),
        "phone": phone,
        "address": address,
        "roles": json.dumps(roles, ensure_ascii=False, separators=(",", ":")),
        "credit_limit": rnd.choice((0, 0, 10_000_00, 50_000_00, 100_000_00)) if rnd.random() < 0.35 else 0,
        "is_active": 0 if rnd.random() < 0.12 else 1,
        "remark": rnd.choice(("月结", "现金结算", "老客户", "只收整箱", "")) or None,
        "created_at": ts,
        "updated_at": ts,
        "sync_version": 0,
    }


def make_account(index: int, rnd: random.Random) -> Dict[str, Any]:
    """造一行 `accounts`。`type` 必须在 `AccountType` 的五个 wire 值里。

    刻意包含 `initial_balance < 0`（信用卡式欠款）与 `is_active = 0`（停用账户：
    开单收款区不该再出现它 —— 验收 3.7）。
    """
    ts = now_ms()
    balance = rnd.randrange(0, 2_000_000_00)
    if rnd.random() < 0.12:
        balance = -rnd.randrange(0, 500_000_00)
    if rnd.random() < 0.1:
        balance = 0
    return {
        "id": uuid7(ts),
        "name": "%s%d" % (rnd.choice(ACCOUNT_NAMES), index + 1),
        "type": rnd.choice(ACCOUNT_TYPES),
        "initial_balance": balance,
        "is_active": 0 if rnd.random() < 0.12 else 1,
        "created_at": ts,
        "updated_at": ts,
        "sync_version": 0,
    }


def make_injected_rows(
    payloads: Sequence[Tuple[str, str]], rnd: random.Random
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]], List[Dict[str, Any]], List[Dict[str, str]]]:
    """把每条载荷写进**所有文本列**（分布到三张表上）。

    数值列给的是**正常值** —— 注入点只在文本列，把金额也写成垃圾只会制造
    「金额算不对」的假缺陷（那种缺陷测的是脚本，不是软件）。

    返回 `(products, parties, accounts, 载荷索引)`。
    """
    products: List[Dict[str, Any]] = []
    parties: List[Dict[str, Any]] = []
    accounts: List[Dict[str, Any]] = []
    index: List[Dict[str, str]] = []
    ts = now_ms()

    for i, (tag, payload) in enumerate(payloads):
        # 载荷轮转落点：保证「同一个串在三种档案上都出现过」
        where = i % 3
        index.append({"tag": tag, "payload": payload, "table": SEEDED_TABLES[where]})
        if where == 0:
            products.append(
                {
                    "id": uuid7(ts),
                    "code": payload,          # products.code（UNIQUE）—— 编码列也过一遍
                    "name": payload,
                    "barcode": payload,
                    "unit": payload,
                    "cost_price": 100,
                    "sell_price": 200,
                    "safety_stock": 0,
                    "category": payload,
                    "is_active": 1,
                    "remark": payload,
                    "package_note": payload,
                    "package_unit": payload,  # 半配置：只填单位，专测「成对启用」的拦截
                    "package_size": None,
                    "created_at": ts,
                    "updated_at": ts,
                    "sync_version": 0,
                }
            )
        elif where == 1:
            parties.append(
                {
                    "id": uuid7(ts),
                    "name": payload,
                    "phone": payload,
                    "address": payload,
                    # roles 必须是 JSON 数组文本，否则列表页直接解析失败 ——
                    # 「解析失败」本身也是一个值得被看见的结果
                    "roles": json.dumps([payload], ensure_ascii=False),
                    "credit_limit": 0,
                    "is_active": 1,
                    "remark": payload,
                    "created_at": ts,
                    "updated_at": ts,
                    "sync_version": 0,
                }
            )
        else:
            accounts.append(
                {
                    "id": uuid7(ts),
                    "name": payload,
                    "type": rnd.choice(ACCOUNT_TYPES),
                    "initial_balance": 0,
                    "is_active": 1,
                    "created_at": ts,
                    "updated_at": ts,
                    "sync_version": 0,
                }
            )
    return products, parties, accounts, index


# ------------------------------------------------------------------ 库的读写


def resolve_db_path(args: argparse.Namespace) -> Optional[str]:
    if args.db:
        return os.path.abspath(args.db)
    if args.data_dir:
        return os.path.abspath(os.path.join(args.data_dir, DATA_FILE_NAME))
    return None


def marker_path_for(db_path: str) -> str:
    return os.path.join(os.path.dirname(db_path), MARKER_FILE_NAME)


def table_columns(conn: sqlite3.Connection, table: str) -> List[str]:
    return [r[1] for r in conn.execute("PRAGMA table_info(%s)" % quote_ident(table))]


def quote_ident(name: str) -> str:
    """SQLite 标识符引用。表名来自本脚本的常量 / `sqlite_master`，
    仍然走一次引用 —— 少一处「假定输入可信」的地方。"""
    return '"%s"' % name.replace('"', '""')


def table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (table,)
    ).fetchone()
    return row is not None


def user_version(conn: sqlite3.Connection) -> int:
    return int(conn.execute("PRAGMA user_version").fetchone()[0])


def create_schema(conn: sqlite3.Connection, statements: Sequence[str], version: int) -> None:
    """空库建表。**顺序即执行顺序**（被引用的表必须先建），与 `Db._migrate` 的
    v0 分支逐句一致 —— 包括「一个事务、最后写 `user_version`」。"""
    conn.execute("BEGIN")
    try:
        for stmt in statements:
            conn.execute(stmt)
        conn.execute("PRAGMA user_version = %d" % version)
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise


def next_product_code(conn: sqlite3.Connection) -> int:
    """下一个可用序号 —— 与 `ProductDao.latestCode()` 同一口径：

        SELECT code FROM products WHERE code LIKE 'P%'
        ORDER BY LENGTH(code) DESC, code DESC LIMIT 1

    ⚠️ **不能用 `MAX(code)`**：`P10000` 的字典序小于 `P9999`（裁定见
    `Agents.md` §4.1「商品编码与排序」），取最大编码会取错。
    """
    row = conn.execute(
        "SELECT code FROM products WHERE code LIKE 'P%' "
        "ORDER BY LENGTH(code) DESC, code DESC LIMIT 1"
    ).fetchone()
    if row is None:
        return 1
    m = re.match(r"^P(\d+)$", row[0] or "")
    if not m:
        # 已有编码不符合格式（可能是注入数据 / 用户改过）⇒ 退到「数量 + 1」，
        # 保证不撞号；不抛，因为这不是致命问题。
        count = conn.execute("SELECT COUNT(*) FROM products").fetchone()[0]
        return int(count) + 1
    return int(m.group(1)) + 1


def existing_values(conn: sqlite3.Connection, table: str, column: str, limit: int = 200) -> List[str]:
    if not table_exists(conn, table):
        return []
    try:
        rows = conn.execute(
            "SELECT %s FROM %s WHERE %s IS NOT NULL LIMIT ?"
            % (quote_ident(column), quote_ident(table), quote_ident(column)),
            (limit,),
        ).fetchall()
    except sqlite3.Error:
        return []
    return [r[0] for r in rows]


def insert_rows(
    conn: sqlite3.Connection, table: str, rows: Sequence[Dict[str, Any]], on_conflict: str
) -> Tuple[int, List[str]]:
    """逐行插入。返回 `(成功条数, 失败说明)`。

    `on_conflict`：`fail` = 冲突即报错；`skip` = 冲突跳过（幂等重跑用）。

    ⚠️ **一行一条语句**而不是 `executemany` 批量：一次写入量默认只有 100 条，
    省下的那点时间不值得让「第 37 条撞了 UNIQUE」变成一句没有行号的
    `IntegrityError`（测试人员要的是「哪条不行」，不是「有一批不行」）。
    """
    if not rows:
        return 0, []
    cols = table_columns(conn, table)
    if not cols:
        return 0, ["表 %s 不存在，跳过" % table]
    unknown = sorted({k for row in rows for k in row} - set(cols))
    if unknown:
        return 0, [
            "表 %s 上不存在这些列：%s（schema 与脚本不同源？）" % (table, unknown)
        ]
    verb = "INSERT OR IGNORE INTO" if on_conflict == "skip" else "INSERT INTO"
    sql = "%s %s (%s) VALUES (%s)" % (
        verb,
        quote_ident(table),
        ", ".join(quote_ident(c) for c in cols),
        ", ".join("?" for _ in cols),
    )
    ok = 0
    problems: List[str] = []
    for n, row in enumerate(rows, 1):
        try:
            conn.execute(sql, [row.get(c) for c in cols])
            ok += 1
        except sqlite3.Error as exc:
            problems.append("第 %d 行：%s" % (n, exc))
            if on_conflict == "fail" and len(problems) >= 5:
                problems.append("（失败已多于 5 条，后面的不再逐条报告）")
                break
    return ok, problems


# ------------------------------------------------------------------- 校验


def verify(
    conn: sqlite3.Connection,
    seeded: Dict[str, int],
    injected: Sequence[Dict[str, str]],
) -> List[str]:
    """写完之后自己验一遍，把「能不能用」的结论直接给测试人员。

    验的是**四件事**，每件都对应一个真实的翻车方式：

    1. **结构自洽** —— `foreign_key_check` / `integrity_check` 通过
    2. **行数对得上** —— 写进去多少就是多少
    3. **注入载荷逐字节还原** —— 参数化查询没丢字符（丢了就说明绑定层动了手脚）
    4. **软件能读回来** —— 用 `Party.decodeRoles` / `AccountType.fromWire` 的
       口径把行读一遍；读不出来的行是**真缺陷**，要在报告里点名
    """
    problems: List[str] = []

    fk = conn.execute("PRAGMA foreign_key_check").fetchall()
    if fk:
        problems.append("外键校验不通过，%d 处（示例：%s）" % (len(fk), fk[:3]))
    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        problems.append("integrity_check 不通过：%s" % integrity)

    for table in SEEDED_TABLES:
        n = conn.execute("SELECT COUNT(*) FROM %s" % quote_ident(table)).fetchone()[0]
        if n < seeded.get(table, 0):
            problems.append(
                "表 %s 里只有 %d 行，少于本次写入的 %d 行" % (table, n, seeded.get(table, 0))
            )

    # 注入载荷逐字节还原
    for item in injected:
        tag, payload, table = item["tag"], item["payload"], item["table"]
        col = "name" if table != "products" else "name"
        row = conn.execute(
            "SELECT %s FROM %s WHERE %s = ? LIMIT 1"
            % (quote_ident(col), quote_ident(table), quote_ident(col)),
            (payload,),
        ).fetchone()
        if row is None:
            problems.append("注入载荷 %s 查不回来（表 %s 列 %s）" % (tag, table, col))
        elif row[0] != payload:
            problems.append("注入载荷 %s 落库后被改写：%r → %r" % (tag, payload, row[0]))

    # 软件能不能读回来（只读、不改）
    bad_roles: List[str] = []
    for (raw,) in conn.execute("SELECT roles FROM parties"):
        if raw is None:
            bad_roles.append("NULL")
            continue
        try:
            parsed = json.loads(raw)
        except Exception:
            bad_roles.append(raw)
            continue
        if not isinstance(parsed, list):
            bad_roles.append(raw)
    if bad_roles:
        # ⚠️ 这不是脚本的失败，而是**注入数据的预期效果**之一：
        # 它就是来测「roles 被污染时软件怎么表现」的。
        pass

    bad_account_types = [
        t
        for (t,) in conn.execute("SELECT type FROM accounts")
        if t not in ACCOUNT_TYPES
    ]
    if bad_account_types:
        problems.append(
            "accounts.type 有 %d 个不在 AccountType 白名单里（示例 %s）"
            % (len(bad_account_types), bad_account_types[:3])
        )

    if not conn.execute("SELECT 1 FROM products LIMIT 1").fetchone():
        problems.append("products 是空的 —— 开单页会选不到货")

    return problems


# ------------------------------------------------------------------- 报告


def render_plan(
    args: argparse.Namespace,
    db_path: Optional[str],
    statements: Sequence[str],
    version: int,
    counts: Dict[str, int],
    inject_counts: Dict[str, int],
    payloads: Sequence[Tuple[str, str]],
) -> str:
    lines = [
        "神算子测试数据 —— 预演（--dry-run，一个字节都不会写）",
        "=" * 64,
        "目标库        ：%s" % (db_path or "未指定（仅预演，不访问本机数据目录）"),
        "库存在        ：%s" % (
            "未检查（未指定目标）"
            if not db_path
            else ("是" if os.path.exists(db_path) else "否（将按 schema 新建）")
        ),
        "schema 来源   ：%s" % schema_source_label(args.schema_source),
        "schema 版本   ：v%d" % version,
        "建表语句指纹  ：%s（%d 条）" % (ddl_fingerprint(statements), len(statements)),
        "写入范围      ：%s" % " / ".join(SEEDED_TABLES),
        "明确不写      ：%s" % " / ".join(FORBIDDEN_TABLES),
        "随机种子      ：%s" % args.seed,
        "一次写入量    ：%d 条" % args.count,
        "计划写入      ：products %(products)d · parties %(parties)d · accounts %(accounts)d"
        % counts,
    ]
    if payloads:
        lines.append(
            "注入数据      ：%d 条（--inject %s）" % (len(payloads), args.inject)
        )
        lines.append(
            "               ：products %(products)d · parties %(parties)d · accounts %(accounts)d"
            % inject_counts
        )
    else:
        lines.append("注入数据      ：无（加 --inject 可生成）")
    lines.append("")
    lines.append("— 前 3 条样本 —")
    return "\n".join(lines)


def render_summary(
    db_path: str,
    version: int,
    seeded: Dict[str, int],
    totals: Dict[str, int],
    payload_count: int,
    problems: Sequence[str],
    elapsed_ms: int,
) -> str:
    lines = [
        "",
        "=" * 64,
        "写入位置：%s" % db_path,
        "schema  ：v%d" % version,
        "本次写入：products %(products)d · parties %(parties)d · accounts %(accounts)d"
        % seeded,
        "现有总量：products %(products)d · parties %(parties)d · accounts %(accounts)d"
        % totals,
        "注入数据：%d 条" % payload_count,
        "耗时    ：%d ms" % elapsed_ms,
    ]
    if problems:
        lines.append("")
        lines.append("⚠️ 有 %d 处需要看一眼：" % len(problems))
        lines.extend("   · %s" % p for p in problems)
    else:
        lines.append("校验    ：通过（外键 / 完整性 / 行数 / 载荷逐字节还原）")
    lines.append("")
    lines.append("下一步（测试人员）：")
    n = 0
    n += 1
    lines.append("  %d) 启动神算子，数据目录选到：%s" % (n, os.path.dirname(db_path)))
    n += 1
    lines.append("  %d) 商品页 / 往来方页 / 账户页应能看到刚写的数据（重启后仍在）" % n)
    if payload_count:
        n += 1
        lines.append("  %d) 注入数据已混在里面 —— 逐条核对见下方的载荷清单" % n)
    n += 1
    lines.append(
        "  %d) 想让软件认下这个位置：先启动一次软件，由它自己写标记文件 %s"
        "（脚本不代写）" % (n, MARKER_FILE_NAME)
    )
    n += 1
    lines.append("  %d) 想清库重来：删掉 shensuanzi.db* 三个文件即可（脚本只新增，不改不删）" % n)
    return "\n".join(lines)


def render_payload_index(injected: Sequence[Dict[str, str]]) -> str:
    if not injected:
        return ""
    lines = [
        "",
        "— 注入载荷清单（这一串就是库里存着的字面值）—",
        "%-22s %-10s %s" % ("标签", "落点表", "载荷（repr）"),
    ]
    for item in injected:
        lines.append("%-22s %-10s %s" % (item["tag"], item["table"], repr(item["payload"])))
    lines.append("")
    lines.append("怎么用这串数据（每一步都在测一个具体的拼串点）：")
    lines.append("  · 商品页按名称 / 编码 / 条码搜索这些串 → 看是否报错、是否漏搜、是否搜出全表")
    lines.append("  · 往来方页按手机号搜索 → 同上")
    lines.append("  · 打开含这些串的商品详情并编辑保存 → 看回显是否被截断 / 转义")
    lines.append("  · 导出商品 / 往来方 CSV → 用 Excel 打开，看引号、换行、emoji 是否把表撑坏")
    lines.append("  · 开主机（设置 → 主机）后用手机端拉取 → 看同步 upsert 通道是否吞掉这些串")
    lines.append("  · 备份一次 → 用 sqlite3 打开备份，确认串仍是原文（备份不该改写数据）")
    lines.append("  · ⚠️ 任何一处出现 SQL 语法错误 / 报错文案里带出 SQL 片段，都是**缺陷**，请记录")
    return "\n".join(lines)


# ------------------------------------------------------------------- 主流程


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="seed_test_data.py",
        description="向神算子数据库写入测试数据（只写商品 / 往来方 / 账户三张主数据表）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例：\n"
            "  python tool/seed_test_data.py --dry-run\n"
            "  python tool/seed_test_data.py --db D:\\神算子数据\\shensuanzi.db --count 500\n"
            "  python tool/seed_test_data.py --data-dir D:\\测试数据 --count 100 --inject\n"
            "  python tool/seed_test_data.py --db ./干净库.db --inject sql --seed 7\n"
        ),
    )
    where = parser.add_argument_group("写入位置（二选一；写入时必须明确指定）")
    where.add_argument(
        "--db",
        help="直接指定库文件路径（不存在则按 schema 新建）",
    )
    where.add_argument(
        "--data-dir",
        help="数据目录（库名固定为 %s，与软件一致）" % DATA_FILE_NAME,
    )
    amount = parser.add_argument_group("一次写入量")
    amount.add_argument(
        "--count",
        type=int,
        default=DEFAULT_COUNT,
        help="一次写入的**记录条数**（默认 %(default)s）；三张表按 3:3:2 分配",
    )
    amount.add_argument(
        "--seed",
        default="shensuanzi",
        help="随机种子（默认 %(default)s）—— 同种子同结果，便于复现",
    )

    inject = parser.add_argument_group("注入数据")
    inject.add_argument(
        "--inject",
        nargs="?",
        const="all",
        default=None,
        metavar="KIND",
        help="额外写入可能触发 SQL 注入的数据。不带值 = all；"
        "可选 all / %s" % " / ".join(ALL_PAYLOAD_SETS),
    )

    safety = parser.add_argument_group("安全阀")
    safety.add_argument(
        "--dry-run", action="store_true", help="只打印计划与样本，不写库"
    )
    safety.add_argument(
        "--allow-nonempty",
        action="store_true",
        help="明确允许向已有数据的库追加（默认拒绝；仅用于隔离的测试库）",
    )
    safety.add_argument(
        "--on-conflict",
        choices=("fail", "skip"),
        default="fail",
        help="撞 UNIQUE 时怎么办：fail = 报出来（默认）；skip = 跳过（幂等重跑）",
    )
    safety.add_argument(
        "--schema-source",
        default=None,
        help="可选：显式指定 schema.dart；默认仓库内读源码，无源码时使用脚本附带快照",
    )
    safety.add_argument(
        "--quiet", action="store_true", help="只打印结论，不打印样本与载荷清单"
    )
    return parser


def plan_counts(count: int) -> Dict[str, int]:
    """把 N 条记录分给三张表（3:3:2，余数给商品）。

    ⚠️ 这里决定的是「**记录**条数」而不是「库里的总行数」—— 脚本只新增，
    反复跑会累积，报告里两个数都打出来（`--count 100` 跑两次 = 库里有 200 条）。
    """
    if count < 0:
        raise SystemExit("--count 不能是负数")
    products = count * 3 // 8
    parties = count * 3 // 8
    accounts = count - products - parties
    return {"products": products, "parties": parties, "accounts": accounts}


def main(argv: Optional[Sequence[str]] = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except Exception:
            pass
    args = build_parser().parse_args(argv)

    # 在读取 schema 或解析任何目标文件之前拒绝隐式写入目标。
    if args.db and args.data_dir:
        print("⛔ --db 与 --data-dir 只能指定一个。", file=sys.stderr)
        return 2
    if not args.dry_run and not args.db and not args.data_dir:
        print(
            "⛔ 写入前必须显式指定 --db 或 --data-dir；脚本不会回退到开发设备或用户目录。\n"
            "   请使用干净的测试目录；已有数据的库还需要显式加 --allow-nonempty。",
            file=sys.stderr,
        )
        return 2

    t0 = time.time()
    rnd = random.Random(args.seed)

    # ---- 1. schema 单一来源
    try:
        statements, version = load_ddl_from_schema_source(args.schema_source)
    except SchemaSourceError as exc:
        print("无法加载数据库结构：\n%s" % exc, file=sys.stderr)
        return 3

    db_path = resolve_db_path(args)

    # ---- 2. 计划
    counts = plan_counts(args.count)
    payloads: List[Tuple[str, str]] = []
    if args.inject is not None:
        payloads = select_payloads(args.inject)

    # 样本（只在 dry-run / 非 quiet 时造，避免无谓开销）
    sample_lines: List[str] = []
    if args.dry_run or not args.quiet:
        sample_rnd = random.Random(args.seed)
        for i in range(min(3, counts["products"])):
            sample_lines.append(
                "  products[%d] = %s"
                % (i, json.dumps(make_product(i, "P%04d" % (i + 1), sample_rnd, ()), ensure_ascii=False))
            )
        for i in range(min(1, counts["parties"])):
            sample_lines.append(
                "  parties[%d]  = %s" % (i, json.dumps(make_party(i, sample_rnd), ensure_ascii=False))
            )
        for i in range(min(1, counts["accounts"])):
            sample_lines.append(
                "  accounts[%d] = %s" % (i, json.dumps(make_account(i, sample_rnd), ensure_ascii=False))
            )

    if args.dry_run:
        print(
            render_plan(
                args,
                db_path,
                statements,
                version,
                counts,
                {
                    "products": len(payloads) // 3 + (1 if len(payloads) % 3 > 0 else 0),
                    "parties": len(payloads) // 3 + (1 if len(payloads) % 3 > 1 else 0),
                    "accounts": len(payloads) // 3,
                },
                payloads,
            )
        )
        print("\n".join(sample_lines))
        if payloads:
            print(render_payload_index([
                {"tag": t, "payload": p, "table": SEEDED_TABLES[i % 3]}
                for i, (t, p) in enumerate(payloads)
            ]))
        print("\n")
        print("（--dry-run：没有写任何东西）")
        return 0

    assert db_path is not None  # 写入目标已在解析参数后强制指定

    # ---- 3. 打开库（不存在则新建）
    existed = os.path.exists(db_path)
    parent = os.path.dirname(db_path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)

    conn = sqlite3.connect(db_path)
    try:
        conn.execute("PRAGMA foreign_keys = ON")

        current = user_version(conn)
        created = False
        if current == 0 and not table_exists(conn, "products"):
            create_schema(conn, statements, version)
            created = True
            current = user_version(conn)
        elif current != version:
            print(
                "⛔ 这个库的 schema 版本是 v%d，而 %s 是 v%d。\n"
                "   版本不符时写入可能造出软件读不动的数据，所以脚本停在这里。\n"
                "   怎么办：① 换一个干净位置（--db 指定新文件）；"
                "② 或让软件先打开一次这个库（软件会跑迁移链，迁移后会自带备份）；"
                "③ 或用 --schema-source 指向与该库匹配的 schema.dart。"
                % (current, schema_source_label(args.schema_source), version),
                file=sys.stderr,
            )
            return 4

        # 默认只允许干净库。检查数据库所有用户表而非仅三张种子表，避免
        # 把已有业务库误当测试库；显式覆盖也必须由操作者承担风险。
        existing_rows: List[Tuple[str, int]] = []
        if existed:
            user_tables = [
                row[0]
                for row in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table' "
                    "AND name NOT LIKE 'sqlite_%' ORDER BY name"
                )
            ]
            for table in user_tables:
                n = int(conn.execute("SELECT COUNT(*) FROM %s" % quote_ident(table)).fetchone()[0])
                if n:
                    existing_rows.append((table, n))
        if existing_rows and not args.allow_nonempty:
            preview = ", ".join("%s=%d" % item for item in existing_rows[:8])
            print(
                "⛔ 目标库不是空库，默认拒绝写入（%s）。\n"
                "   请换一个干净测试位置；确认这是隔离测试库后才可加 --allow-nonempty。"
                % preview,
                file=sys.stderr,
            )
            return 5

        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA synchronous = NORMAL")

        notes: List[str] = []
        # 结构同源核对：这个库的结构和脚本手里的 schema 是同一份吗？
        # ⚠️ 只**报告**，不拦 —— 库可能是软件迁移来的（列序不同是正常的，
        # [fingerprint_of_db] 已归一化），也可能被人改过（那才值得看一眼）。
        db_fp = fingerprint_of_db(conn)
        script_fp = ddl_fingerprint(statements)
        if db_fp and db_fp != script_fp:
            notes.append(
                "⚠️ 这个库的结构指纹（%s）与脚本的 schema（%s）不同。"
                "若软件是逐版升级来的，通常仍属正常；若你刚手工改过结构，"
                "请先确认后再用这份数据。" % (db_fp, script_fp)
            )

        # 库存在但标记文件缺失 / 版本旧 ⇒ 提醒（**不代写**：marker 是软件的身份证）
        marker = marker_path_for(db_path)
        if created:
            notes.append(
                "按 schema v%d 建了新库（%s）" % (version, os.path.basename(db_path))
            )
        if not os.path.exists(marker):
            notes.append(
                "⚠️ 目录里没有标记文件 %s —— 请让**软件**先打开一次这个位置，"
                "由软件自己写标记；脚本不代写（标记是软件的身份证，见 docs/data_directory.md）"
                % MARKER_FILE_NAME
            )

        # ---- 4. 造数据
        seq = next_product_code(conn)
        dup_barcodes = existing_values(conn, "products", "barcode", 20)

        product_rows: List[Dict[str, Any]] = []
        for i in range(counts["products"]):
            product_rows.append(
                make_product(i, "P%04d" % seq, rnd, dup_barcodes)
            )
            seq += 1
        party_rows = [make_party(i, rnd) for i in range(counts["parties"])]
        account_rows = [make_account(i, rnd) for i in range(counts["accounts"])]

        inject_products: List[Dict[str, Any]] = []
        inject_parties: List[Dict[str, Any]] = []
        inject_accounts: List[Dict[str, Any]] = []
        injected_index: List[Dict[str, str]] = []
        if payloads:
            inject_products, inject_parties, inject_accounts, injected_index = make_injected_rows(
                payloads, rnd
            )

        # ---- 5. 写入（一个事务：要么全进，要么全不进）
        seeded: Dict[str, int] = {}
        problems: List[str] = []
        conn.execute("BEGIN")
        try:
            for table, rows in (
                ("products", product_rows + inject_products),
                ("parties", party_rows + inject_parties),
                ("accounts", account_rows + inject_accounts),
            ):
                ok, issues = insert_rows(conn, table, rows, args.on_conflict)
                seeded[table] = ok
                problems.extend(issues)
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise

        totals = {
            t: conn.execute("SELECT COUNT(*) FROM %s" % quote_ident(t)).fetchone()[0]
            for t in SEEDED_TABLES
        }

        # ---- 6. 自验
        problems.extend(verify(conn, seeded, injected_index))

        # ---- 7. 报告
        print("神算子测试数据 —— 写入完成")
        for note in notes:
            print("· %s" % note)
        print(
            render_summary(
                db_path,
                current,
                seeded,
                totals,
                len(payloads),
                problems,
                int((time.time() - t0) * 1000),
            )
        )
        if payloads and not args.quiet:
            print(render_payload_index(injected_index))
        if not args.quiet:
            print("")
            print("本次为「记录条数 = %d」；因为脚本只新增，库里的总量见上面的「现有总量」。"
                  % args.count)
        return 0 if not problems else 5
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
