#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为**长时间性能实测**造一份体量真实、且内部自洽的账本数据。

    python tool/perf_seed.py --help

## 这个脚本与 `seed_test_data.py` 的分工（别混用）

| | `seed_test_data.py` | 本脚本 |
|---|---|---|
| 写什么 | **只写三张主数据**（商品 / 往来方 / 账户） | 主数据 **+ 单据 + 四张流水** |
| 用途 | 功能验收 / 注入探针 | **只用于性能与容量实测** |
| 写业务数据的方式 | 一律不写（纪律：绕开 RuleEngine 造的账不自洽） | **直写 SQL，但把不自洽的地方补齐**（见下） |
| 能不能用于「账对不对」的验收 | 能 | **绝对不能**（本脚本不是 RuleEngine） |

## 为什么性能测试可以直写 SQL

体量要求是「每张表 10 万条以上」。走 RuleEngine 意味着 20 万次 UI/规则调用，
在没有 Dart SDK 的测试机上不可行；纯人工点更不可能。所以本脚本**复制**了
`RuleEngine` 的落地形态（不是规则实现）：每张单、每条流水、每笔核销都由脚本
按 `docs/rules.md` 的口径生成，并在写完后**用 SQL 反算一遍缓存字段**：

- `documents.paid_amount` ← `SUM(settlements.amount)`（不变量 B4）
- `Σ document_lines.amount` = `documents.total_amount`（不变量 B5）
- `stock_ledger.seq_no` / `money_ledger` / `party_ledger` / `settlements` 各自
  从 1 连续递增（纪律 5），且写完后逐表断言「无空洞、无重复」
- 收付款单**必有** `receipt` / `payment` 行（纪律 11），且 `money_ledger`
  只在收付款单下出现
- 现金方向：`money_ledger.amount` 收款为正、付款为负；`party_ledger` 与单据方向一致

写完会跑 [verify] 逐条核对，任何一条不通过都以退出码 5 结束，并把**违规行数**
打出来。这样测试人员拿到的库，界面上的数字是讲得通的 —— 不然测出来的
「账不对」是造数造的。

⚠️ **它仍然不是 RuleEngine**：不跑规则、不做业务校验、`entry_*` 只是装饰。
所以**不要**拿这份数据去验收业务正确性（那是 `docs/desktop_acceptance.md` 的事）。

## 三步用法

    # ① 先让软件自己建一次数据目录（拿到标记文件 / 配置 / 备份目录），关掉软件
    # ② 造数（默认每张流水表 ≥ 10 万行；库约 200–400 MB，耗时几分钟）
    python tool/perf_seed.py --data-dir "D:\\神算子数据" --min-rows 100000

    # ③ 自检（造数后会自动跑一次；也可以单独跑）
    python tool/perf_seed.py --data-dir "D:\\神算子数据" --verify

    # ④ 基线（不启动软件也能跑；建议在人工实测前后各跑一次）
    python tool/perf_bench.py --data-dir "D:\\神算子数据" --csv baseline-before.csv

    # ⑤ 人工实测（另开一个窗口，边用软件边记录）
    python tool/perf_monitor.py run --data-dir "D:\\神算子数据" --out D:\\perf-run1

## 安全阀

- **必须显式给 `--db` 或 `--data-dir`**，脚本没有默认目标；
- 库里**已有业务数据**时默认拒绝（只警告不改），要覆盖必须同时给
  `--allow-nonempty --confirm-wipe`；
- 目标库的 `PRAGMA user_version` 必须等于脚本读取的 schema 版本，否则停（3）；
- `--dry-run` 只算不写，先看清楚会造多少、多大、多久。

## 依赖

Python 3.8+，**只用标准库**。schema 从 `schema.dart`（开发仓库）或随脚本分发的
`schema_snapshot.json`（测试机）读取 —— 与 `seed_test_data.py` 同一份来源、
同一个指纹校验，所以**两个脚本必须一起分发**（连同 `perf_bench.py`）。

## 退出码

    0  成功（自检全过）
    1  运行期错误（磁盘满 / 库被占用等）
    2  用法错误（没给目标 / 参数冲突 / 拒绝写入）
    3  读不到 schema，或库的版本不匹配
    5  数据已写入，但**自检有违规**（看输出里的 ❌ 行）
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sqlite3
import sys
import time
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import seed_test_data as seed  # 复用 DDL 加载 / 指纹校验 / 工具函数
except Exception as exc:  # pragma: no cover - 分发不全时的明确报错
    print(
        "⛔ 找不到同目录的 seed_test_data.py（本脚本复用它加载 schema，不自己内嵌 DDL）：%s\n"
        "   请把 seed_test_data.py / perf_seed.py / perf_bench.py / schema_snapshot.json "
        "放在同一个目录。" % exc,
        file=sys.stderr,
    )
    raise SystemExit(3)


# --------------------------------------------------------------------------- 常量

#: 业务单据（不含自动生成的收付款单）。顺序即生成顺序，也是「单据类型」的抽样池。
BIZ_TYPES: Tuple[str, ...] = (
    "purchase",
    "sale",
    "delivery",
    "sale_return",
    "purchase_return",
)

DOC_TYPE_LABEL: Dict[str, str] = {
    "purchase": "采购",
    "sale": "销售",
    "delivery": "送货",
    "sale_return": "销售退货",
    "purchase_return": "采购退货",
    "receipt": "收款",
    "payment": "付款",
    "stocktake": "盘点",
}

PREFIX: Dict[str, str] = {
    "purchase": "CG",
    "sale": "XS",
    "delivery": "SH",
    "sale_return": "XT",
    "purchase_return": "CT",
    "receipt": "SK",
    "payment": "FK",
    "stocktake": "PD",
}

#: 每张表都至少要达到的目标行数（由 `--min-rows` 覆盖）。
TARGET_TABLES: Tuple[str, ...] = (
    "document_lines",
    "stock_ledger",
    "money_ledger",
    "party_ledger",
    "settlements",
)

#: 逐表计数，最后打印成「测试卡」。
COUNTED_TABLES: Tuple[str, ...] = (
    "products",
    "parties",
    "accounts",
    "documents",
    "document_lines",
    "stock_ledger",
    "money_ledger",
    "party_ledger",
    "settlements",
)

PRODUCT_NAMES: Tuple[str, ...] = (
    "矿泉水", "可乐", "雪碧", "红茶", "绿茶", "牛奶", "酸奶", "面包", "饼干", "方便面",
    "火腿肠", "鸡蛋", "大米", "面粉", "食用油", "食盐", "白糖", "酱油", "香醋", "料酒",
    "啤酒", "白酒", "洗洁精", "洗衣粉", "牙膏", "牙刷", "纸巾", "洗发水", "香皂", "垃圾袋",
)

SPECS: Tuple[str, ...] = (
    "500ml", "1L", "1.5L", "250ml", "330ml", "整箱", "袋装", "瓶装", "盒装", "散装",
    "大号", "小号", "家庭装", "试用装", "454g", "2.5kg", "10卷", "20包",
)

PARTY_SURNAMES: Tuple[str, ...] = (
    "王", "李", "张", "刘", "陈", "杨", "赵", "黄", "周", "吴", "徐", "孙", "胡", "朱",
    "高", "林", "何", "郭", "马", "罗",
)

PARTY_GIVEN: Tuple[str, ...] = (
    "老板", "记", "小卖部", "超市", "便利店", "副食店", "商行", "批发部", "粮油店", "水果店",
)

ACCOUNT_NAMES: Tuple[str, ...] = ("现金", "微信", "支付宝", "银行卡")

UNITS: Tuple[str, ...] = ("瓶", "袋", "包", "盒", "个", "斤", "件", "箱")

#: `--min-rows` 的默认目标（不传时用于造数；`--verify` 不传则**只查自洽性**，不卡体量）。
DEFAULT_MIN_ROWS = 100000


# --------------------------------------------------------------------------- 工具

def now_ms() -> int:
    return int(time.time() * 1000)


def iso_day(ms: int) -> str:
    return time.strftime("%Y%m%d", time.localtime(ms / 1000.0))


def pct(n: int, d: int) -> str:
    return "%.0f%%" % (100.0 * n / d) if d else "—"


def human_mb(path: str) -> float:
    try:
        return os.path.getsize(path) / (1024.0 * 1024.0)
    except OSError:
        return 0.0


def db_family_mb(db_path: str) -> Tuple[float, float, float]:
    base = human_mb(db_path)
    return (
        base,
        human_mb(db_path + "-wal"),
        human_mb(db_path + "-shm"),
    )


class Progress:
    """每 N 条打印一行 —— 长任务必须让人看见「还在动」。"""

    def __init__(self, label: str, total_hint: int, quiet: bool = False) -> None:
        self.label = label
        self.total_hint = max(total_hint, 1)
        self.quiet = quiet
        self.t0 = time.time()
        self.last = 0

    def tick(self, done: int, extra: str = "") -> None:
        if self.quiet:
            return
        step = max(1, self.total_hint // 20)
        if done - self.last < step and done != self.total_hint:
            return
        self.last = done
        elapsed = time.time() - self.t0
        rate = done / elapsed if elapsed > 0 else 0.0
        eta = (self.total_hint - done) / rate if rate > 0 else 0.0
        sys.stdout.write(
            "\r  %s %d/%d（%s）  %.0f 条/秒  剩余约 %.0fs%s"
            % (
                self.label,
                done,
                self.total_hint,
                pct(done, self.total_hint),
                rate,
                eta,
                ("  " + extra) if extra else "",
            )
        )
        sys.stdout.flush()

    def done(self) -> None:
        if self.quiet:
            return
        sys.stdout.write("\r  %s 完成，用时 %.1fs%s\n" % (self.label, time.time() - self.t0, " " * 40))
        sys.stdout.flush()


# --------------------------------------------------------------------------- 主数据

def load_existing_master(
    conn: sqlite3.Connection, products_wanted: int, parties_wanted: int
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]], List[Dict[str, Any]]]:
    """已有主数据就复用（追加造数时不重复建），不够的由调用方补齐。"""
    products = [
        {
            "id": r[0],
            "name": r[1],
            "unit": r[2],
            "sell_price": r[3],
            "cost_price": r[4],
            "package_unit": r[5],
            "package_size": r[6],
            "barcode": r[7],
        }
        for r in conn.execute(
            "SELECT id, name, unit, sell_price, cost_price, package_unit, package_size, barcode "
            "FROM products ORDER BY created_at, id LIMIT ?",
            (max(products_wanted, 1),),
        )
    ]
    parties = [
        {
            "id": r[0],
            "name": r[1],
            "roles": r[2],
        }
        for r in conn.execute(
            "SELECT id, name, roles FROM parties ORDER BY created_at, id LIMIT ?",
            (max(parties_wanted, 1),),
        )
    ]
    accounts = [
        {"id": r[0], "name": r[1]}
        for r in conn.execute(
            "SELECT id, name FROM accounts WHERE is_active = 1 ORDER BY name LIMIT 20"
        )
    ]
    return products, parties, accounts


def make_products(
    rnd: random.Random, start_index: int, count: int, stamp: int
) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for i in range(count):
        n = start_index + i
        name = "%s%s %s" % (
            PRODUCT_NAMES[n % len(PRODUCT_NAMES)],
            "" if n < len(PRODUCT_NAMES) else "（%d）" % (n // len(PRODUCT_NAMES) + 1),
            SPECS[n % len(SPECS)],
        )
        unit = UNITS[n % len(UNITS)]
        cost = rnd.randint(30, 8000)  # 分
        # 三成商品带包装换算（成对才有意义）：1 箱 = N 瓶
        package_size = rnd.choice((6, 12, 24, 48)) if n % 10 < 3 else None
        rows.append(
            {
                "id": seed.uuid7(stamp),
                "code": "P%04d" % (n + 1),
                "name": name,
                "barcode": "69%011d" % (n + 1000000),
                "unit": unit,
                "cost_price": cost,
                "sell_price": int(cost * rnd.uniform(1.15, 1.9)),
                "safety_stock": rnd.choice((0, 5, 10, 20, 50)),
                "category": None,
                "is_active": 1,
                "remark": None,
                "package_note": ("1箱=%d%s" % (package_size, unit)) if package_size else None,
                "package_unit": ("箱" if package_size else None),
                "package_size": package_size,
                "created_at": stamp + i,
                "updated_at": stamp + i,
                "sync_version": 0,
            }
        )
    return rows


def make_parties(rnd: random.Random, start_index: int, count: int, stamp: int) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for i in range(count):
        n = start_index + i
        name = "%s%s%s" % (
            PARTY_SURNAMES[n % len(PARTY_SURNAMES)],
            rnd.choice(("", "记", "家")),
            PARTY_GIVEN[n % len(PARTY_GIVEN)],
        )
        if n >= 10:
            name = "%s%d号店" % (name, n // 10)
        roles = rnd.choice(
            (
                '["customer"]',
                '["supplier"]',
                '["customer","supplier"]',
                '["customer","carrier"]',
            )
        )
        rows.append(
            {
                "id": seed.uuid7(stamp + i),
                "name": name,
                "phone": "1%010d" % rnd.randint(0, 9999999999),
                "address": None,
                "roles": roles,
                "credit_limit": 0,
                "is_active": 1,
                "remark": None,
                "created_at": stamp + i,
                "updated_at": stamp + i,
                "sync_version": 0,
            }
        )
    return rows


def make_accounts(count: int, stamp: int) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    kinds = ("cash", "wechat", "alipay", "bank")
    for i in range(count):
        rows.append(
            {
                "id": seed.uuid7(stamp + i),
                "name": ACCOUNT_NAMES[i % len(ACCOUNT_NAMES)],
                "type": kinds[i % len(kinds)],
                "initial_balance": 500000 if i == 0 else 0,  # 现金账户带点期初
                "is_active": 1,
                "created_at": stamp + i,
                "updated_at": stamp + i,
                "sync_version": 0,
            }
        )
    return rows


# --------------------------------------------------------------------------- 造单

class Ledger:
    """造数期的内存状态：库存、成本、单号序列、各表 seq_no。

    这些状态**只用于生成期算数**；落库后一切以流水为准（脚本不维护余额）。
    """

    def __init__(self) -> None:
        self.stock: Dict[str, int] = {}
        self.cost: Dict[str, int] = {}
        self.last_unit: Dict[str, int] = {}
        self.doc_seq: Dict[Tuple[str, str], int] = {}
        self.seq = {
            "stock_ledger": 0,
            "money_ledger": 0,
            "party_ledger": 0,
            "settlements": 0,
        }

    # -- 单号
    def next_doc_no(self, doc_type: str, occurred_ms: int) -> str:
        prefix = PREFIX[doc_type]
        day = iso_day(occurred_ms)
        key = (prefix, day)
        self.doc_seq[key] = self.doc_seq.get(key, 0) + 1
        return "%s%s-%03d" % (prefix, day, self.doc_seq[key])

    # -- 成本
    def inbound_unit_cost(self, product: Dict[str, Any], total_cost: int, qty: int) -> int:
        if qty <= 0:
            return 0
        unit = int(round(total_cost / float(qty)))
        self.last_unit[product["id"]] = unit
        return unit

    def outbound_cost(self, product_id: str, qty: int) -> int:
        """出库成本：账面 > 0 用加权均价；≤ 0 用最近一次进价（与 CostPolicy 同口径）。"""
        have = self.stock.get(product_id, 0)
        cost = self.cost.get(product_id, 0)
        if qty <= 0:
            return 0
        if have > 0:
            return -int(round(cost * qty / float(have)))
        unit = self.last_unit.get(product_id, 0)
        return -(unit * qty)

    def apply_stock(self, product_id: str, quantity: int, total_cost: int) -> None:
        self.stock[product_id] = self.stock.get(product_id, 0) + quantity
        self.cost[product_id] = self.cost.get(product_id, 0) + total_cost


def choose_lines(
    rnd: random.Random,
    products: Sequence[Dict[str, Any]],
    line_count: int,
) -> List[Dict[str, Any]]:
    picked: List[Dict[str, Any]] = []
    seen: set = set()
    for _ in range(line_count):
        for _try in range(6):
            p = products[rnd.randrange(len(products))]
            if p["id"] not in seen:
                seen.add(p["id"])
                picked.append(p)
                break
    if not picked:
        picked.append(products[rnd.randrange(len(products))])
    return picked


class Emitter:
    """把生成的行攒成批，按 chunk 一次性 INSERT（省时间，但保留事务粒度）。"""

    def __init__(self, conn: sqlite3.Connection, chunk_docs: int, quiet: bool) -> None:
        self.conn = conn
        self.chunk_docs = max(1, chunk_docs)
        self.quiet = quiet
        self.rows: Dict[str, List[Any]] = {t: [] for t in COUNTED_TABLES}
        self.docs_since_commit = 0
        self.counts: Dict[str, int] = {t: 0 for t in COUNTED_TABLES}
        self.commits = 0

    def add(self, table: str, row: Dict[str, Any]) -> None:
        self.rows[table].append(row)
        self.counts[table] += 1

    def note_doc(self) -> None:
        self.docs_since_commit += 1
        if self.docs_since_commit >= self.chunk_docs:
            self.flush()

    def flush(self) -> None:
        pending = {t: v for t, v in self.rows.items() if v}
        if not pending:
            return
        # 依赖顺序：单据 → 明细 → 流水（外键要求；FK 在主机是开的）
        order = (
            "documents",
            "document_lines",
            "stock_ledger",
            "money_ledger",
            "party_ledger",
            "settlements",
        )
        self.conn.execute("BEGIN")
        try:
            for table in order:
                rows = pending.get(table)
                if not rows:
                    continue
                cols = list(rows[0].keys())
                sql = "INSERT INTO %s (%s) VALUES (%s)" % (
                    seed.quote_ident(table),
                    ", ".join(seed.quote_ident(c) for c in cols),
                    ", ".join("?" for _ in cols),
                )
                self.conn.executemany(sql, ([r.get(c) for c in cols] for r in rows))
            self.conn.execute("COMMIT")
        except Exception:
            self.conn.execute("ROLLBACK")
            raise
        self.commits += 1
        for t in self.rows:
            self.rows[t] = []
        self.docs_since_commit = 0


def build_doc(
    *,
    rnd: random.Random,
    ledger: Ledger,
    doc_type: str,
    occurred_ms: int,
    created_ms: int,
    party_id: Optional[str],
    lines: Sequence[Dict[str, Any]],
    ref_doc_id: Optional[str] = None,
    account_id: Optional[str] = None,
    status: str = "confirmed",
) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    """生成一张业务单（不含立即收付款）。返回 (单据行, 明细行)。"""
    doc_id = seed.uuid7(created_ms)
    doc_no = ledger.next_doc_no(doc_type, occurred_ms)
    out_lines: List[Dict[str, Any]] = []
    total = 0
    for p in lines:
        qty = rnd.choice((1, 1, 2, 2, 3, 5, 10, 12, 24))
        unit_price = p["sell_price"] if doc_type in ("sale", "delivery") else p["cost_price"]
        unit_price = max(1, int(unit_price * rnd.uniform(0.92, 1.06)))
        amount = qty * unit_price
        # 8% 的行带让价（不超过金额的一半）
        discount = 0
        if rnd.random() < 0.08 and amount >= 4:
            discount = rnd.randint(1, max(1, amount // 2))
            amount -= discount
        entry_unit = None
        entry_qty = None
        if p.get("package_size") and rnd.random() < 0.25:
            entry_unit = p["package_unit"]
            entry_qty = max(1, qty // int(p["package_size"]))
        out_lines.append(
            {
                "id": seed.uuid7(created_ms),
                "document_id": doc_id,
                "product_id": p["id"],
                "quantity": qty,
                "unit_price": unit_price,
                "amount": amount,
                "discount_amount": discount,
                "entry_quantity": entry_qty,
                "entry_unit": entry_unit,
                "remark": None,
            }
        )
        total += amount
    doc = {
        "id": doc_id,
        "doc_no": doc_no,
        "doc_type": doc_type,
        "status": status,
        "party_id": party_id,
        "account_id": account_id,
        "total_amount": total,
        "paid_amount": 0,
        "ref_doc_id": ref_doc_id,
        "occurred_at": occurred_ms,
        "time_estimated": 1 if rnd.random() < 0.02 else 0,
        "created_at": created_ms,
        "updated_at": created_ms,
        "remark": None,
    }
    return doc, out_lines


def build_payment_doc(
    *,
    rnd: random.Random,
    ledger: Ledger,
    money_out: bool,
    amount: int,
    occurred_ms: int,
    party_id: str,
    account_id: str,
    ref_doc_id: Optional[str],
    main_doc_id: str,
) -> Tuple[Dict[str, Any], Dict[str, Any], Dict[str, Any], Dict[str, Any], str]:
    """生成一张收付款单 + 它的 money/party/settlement 行。

    返回 (单据行, money 行, party 行, settlement 行, 新单 id)。
    `ref_doc_id` 为 `None` = 用户事后手记的收付款（会出现在单据列表里）；
    非空 = 开单时自动生成（进 `documents`，但列表默认折叠）。
    """
    doc_type = "payment" if money_out else "receipt"
    doc_id = seed.uuid7(occurred_ms)
    doc_no = ledger.next_doc_no(doc_type, occurred_ms)
    doc = {
        "id": doc_id,
        "doc_no": doc_no,
        "doc_type": doc_type,
        "status": "settled",
        "party_id": party_id,
        "account_id": account_id,
        "total_amount": amount,
        "paid_amount": 0,
        "ref_doc_id": ref_doc_id,
        "occurred_at": occurred_ms,
        "time_estimated": 0,
        "created_at": occurred_ms,
        "updated_at": occurred_ms,
        "remark": "由 %s 自动生成" % DOC_TYPE_LABEL.get(doc_type, doc_type) if ref_doc_id else None,
    }
    ledger.seq["money_ledger"] += 1
    money = {
        "id": seed.uuid7(occurred_ms + 1),
        "account_id": account_id,
        "document_id": doc_id,
        "amount": -amount if money_out else amount,
        "seq_no": ledger.seq["money_ledger"],
        "occurred_at": occurred_ms,
        "time_estimated": 0,
        "external_ref": None,
        "created_at": occurred_ms,
    }
    ledger.seq["party_ledger"] += 1
    party = {
        "id": seed.uuid7(occurred_ms + 2),
        "party_id": party_id,
        "document_id": doc_id,
        "amount": amount if money_out else -amount,
        "seq_no": ledger.seq["party_ledger"],
        "occurred_at": occurred_ms,
        "time_estimated": 0,
        "created_at": occurred_ms,
    }
    ledger.seq["settlements"] += 1
    settle = {
        "id": seed.uuid7(occurred_ms + 3),
        "receipt_doc_id": doc_id,
        "target_doc_id": main_doc_id,
        "amount": amount,
        "seq_no": ledger.seq["settlements"],
        "time_estimated": 0,
        "created_at": occurred_ms,
    }
    return doc, money, party, settle, doc_id


# --------------------------------------------------------------------------- 主流程

def generate(
    conn: sqlite3.Connection,
    *,
    rnd: random.Random,
    args: argparse.Namespace,
    products: List[Dict[str, Any]],
    parties: List[Dict[str, Any]],
    accounts: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """按天造单，直到每张流水表的行数都达到 `--min-rows`。"""
    emitter = Emitter(conn, args.chunk_docs, args.quiet)
    ledger = Ledger()

    # seq_no 接着库里已有的最大值（追加造数时不撞号）
    for table in ("stock_ledger", "money_ledger", "party_ledger", "settlements"):
        row = conn.execute(
            "SELECT COALESCE(MAX(seq_no), 0) FROM %s" % seed.quote_ident(table)
        ).fetchone()
        ledger.seq[table] = int(row[0] or 0)

    # 已有库存/成本先读进内存，避免新单把老商品的成本算飞
    for pid, qty, cost in conn.execute(
        "SELECT product_id, COALESCE(SUM(quantity), 0), COALESCE(SUM(total_cost), 0) "
        "FROM stock_ledger GROUP BY product_id"
    ):
        ledger.stock[pid] = int(qty)
        ledger.cost[pid] = int(cost)

    account_ids = [a["id"] for a in accounts] or [seed.uuid7(now_ms())]
    if not accounts:
        # 极端情况：库里一个账户都没有 —— 造一个现金账户，否则收付款单没有 account_id
        acc = make_accounts(1, now_ms())[0]
        conn.execute("BEGIN")
        conn.execute(
            "INSERT INTO accounts (%s) VALUES (%s)"
            % (
                ", ".join(seed.quote_ident(c) for c in acc),
                ", ".join("?" for _ in acc),
            ),
            list(acc.values()),
        )
        conn.execute("COMMIT")
        accounts = [{"id": acc["id"], "name": acc["name"]}]
        account_ids = [acc["id"]]

    customer_ids = [p["id"] for p in parties]
    if not customer_ids:
        raise SystemExit("库里没有任何往来方 —— 请先用 seed_test_data.py 造主数据")

    end_ms = now_ms()
    days = max(1, int(args.days))
    day_ms = 86400000
    # 「最近 N 天」占 `--recent-share`：手机同步窗口 / 默认 30 天筛选都靠它才测得出
    recent_start = end_ms - max(1, args.recent_days) * day_ms

    # 每张「业务单」平均产出多少行 —— 用它反推需要多少张单，才不会跑到一半才发现
    # 核销/资金表还差一半（这两张表只由「收付款」产生，是体量的真正瓶颈）。
    per_doc_output = {
        "document_lines": 2.2,
        "stock_ledger": 2.2,
        "party_ledger": 1.0 + args.pay_ratio * 1.15,
        "money_ledger": args.pay_ratio * 1.15,
        "settlements": args.pay_ratio * 1.15,
    }
    docs_needed = 1
    for table in TARGET_TABLES:
        rate = per_doc_output.get(table, 0.0)
        if rate > 0:
            docs_needed = max(docs_needed, int(args.min_rows / rate) + 1)
    docs_needed = min(int(docs_needed * 1.08), args.max_docs)  # 8% 余量抵消抽样波动
    # 时间轴固定 `--days` 天，靠提高「每天的单据量」达到体量（现实里就是生意更好）
    per_day = max(int(args.docs_per_day), int(docs_needed / float(days)) + 1)

    # 造数期的两份缓存（**不受分批提交影响** —— flush 会清空 emitter.rows）
    originals: List[Dict[str, Any]] = []  # 可退货/可拒收的原单快照
    unpaid: List[Dict[str, Any]] = []  # 还没收满的主单（供第二阶段补收款）

    progress = Progress("造单", days * per_day, args.quiet)

    def target_met() -> bool:
        return all(emitter.counts[t] >= args.min_rows for t in TARGET_TABLES)

    day_index = 0
    docs_total = 0
    started = time.time()
    stop_reason = "达标"
    while day_index < days:
        # 时间轴：从最早一天走到今天；最近一段单独加密
        frac = day_index / float(max(1, days - 1))
        day_start = end_ms - int((1.0 - frac) * (days - 1) * day_ms)
        day_start = day_start - (day_start % day_ms) + 9 * 3600 * 1000  # 当天 09:00
        is_recent = day_start >= recent_start
        count_today = per_day * (3 if is_recent and args.recent_share > 0 else 1)
        if args.stress_docno and day_index == days - 1:
            count_today = max(count_today, 1100)  # 复现「单日 >999」的坑

        for _ in range(count_today):
            r = rnd.random()
            if r < args.purchase_ratio:
                doc_type = "purchase"
            elif r < args.purchase_ratio + args.delivery_ratio:
                doc_type = "delivery"
            elif r < args.purchase_ratio + args.delivery_ratio + args.return_ratio:
                doc_type = "sale_return" if rnd.random() < 0.7 else "purchase_return"
            else:
                doc_type = "sale"

            occurred = day_start + rnd.randint(0, 8 * 3600) * 1000
            created = occurred + rnd.randint(1, 120) * 1000
            line_count = rnd.choice((1, 1, 2, 2, 2, 3, 3, 5))

            original_id = None
            original = None
            if doc_type in ("sale_return", "purchase_return"):
                # 退货必须有原单：从「可退原单」缓存里挑一张；一单都没造过就退化成销售
                if not originals:
                    doc_type = "sale"
                else:
                    original = originals[rnd.randrange(len(originals))]
                    original_id = original["id"]
                    # 退货按原单的商品与售价（不是当前档案价）—— 与 RULE-007 的成本口径同向
                    lines = [
                        {
                            "id": pid,
                            "sell_price": price,
                            "cost_price": price,
                            "package_size": None,
                            "package_unit": None,
                        }
                        for (pid, _qty, price) in original["lines"][:2]
                    ]
            if doc_type not in ("sale_return", "purchase_return"):
                lines = choose_lines(rnd, products, line_count)
            else:
                lines = choose_lines(rnd, products, line_count)

            party_id = customer_ids[rnd.randrange(len(customer_ids))]
            status = "in_transit" if doc_type == "delivery" else "confirmed"

            doc, doc_lines = build_doc(
                rnd=rnd,
                ledger=ledger,
                doc_type=doc_type,
                occurred_ms=occurred,
                created_ms=created,
                party_id=party_id,
                lines=lines,
                ref_doc_id=original_id,
                status=status,
            )

            # 退货总额不得超过原单（否则往来账会被「退出一笔更大的钱」）
            if original is not None and doc["total_amount"] > original["total_amount"]:
                if doc_lines:
                    diff = doc["total_amount"] - original["total_amount"]
                    doc_lines[-1]["amount"] -= diff
                    doc["total_amount"] = original["total_amount"]

            emitter.add("documents", doc)
            for line in doc_lines:
                emitter.add("document_lines", line)

            # 记「可退原单」与「可事后收款」的候选（不受 flush 影响）
            if doc_type in ("sale", "purchase", "delivery") and doc_lines:
                originals.append(
                    {
                        "id": doc["id"],
                        "doc_type": doc_type,
                        "party_id": party_id,
                        "total_amount": doc["total_amount"],
                        "lines": [
                            (l["product_id"], l["quantity"], l["unit_price"]) for l in doc_lines
                        ],
                    }
                )
                if len(originals) > 400:
                    originals.pop(0)
            if doc_type in ("sale", "delivery"):
                unpaid.append(
                    {
                        "id": doc["id"],
                        "doc_type": doc_type,
                        "party_id": party_id,
                        "total_amount": doc["total_amount"],
                        "paid": 0,
                        "occurred_at": occurred,
                        "status": doc["status"],
                    }
                )

            # ---- 库存流水（与 RULE-001/002/003/007/008 的符号一致）
            for line in doc_lines:
                p = next((x for x in products if x["id"] == line["product_id"]), None)
                if p is None:
                    continue
                qty = line["quantity"]
                if doc_type in ("purchase", "sale_return"):
                    ledger.seq["stock_ledger"] += 1
                    total_cost = line["amount"]
                    ledger.inbound_unit_cost(p, total_cost, qty)
                    emitter.add(
                        "stock_ledger",
                        {
                            "id": seed.uuid7(created + 1),
                            "product_id": p["id"],
                            "document_id": doc["id"],
                            "quantity": qty,
                            "unit_cost": int(round(total_cost / float(qty))),
                            "total_cost": total_cost,
                            "seq_no": ledger.seq["stock_ledger"],
                            "occurred_at": occurred,
                            "time_estimated": doc["time_estimated"],
                            "created_at": created,
                        },
                    )
                    ledger.apply_stock(p["id"], qty, total_cost)
                else:
                    # ---- 出库前先补货：真实店铺是「先进货再卖」。
                    # 不补货的话所有商品都会变成负库存（界面满屏红色告警），
                    # 那不像一家正常营业的店，也会把「低库存告警」测成噪音。
                    if ledger.stock.get(p["id"], 0) < qty:
                        restock_qty = max(qty, qty * rnd.randint(4, 12))
                        restock_ms = occurred - rnd.randint(60, 600) * 1000
                        rdoc, rlines = build_doc(
                            rnd=rnd,
                            ledger=ledger,
                            doc_type="purchase",
                            occurred_ms=restock_ms,
                            created_ms=created - rnd.randint(1, 60) * 1000,
                            party_id=party_id,
                            lines=[p],
                            status="confirmed",
                        )
                        if rlines:
                            first = rlines[0]
                            unit = max(1, first["unit_price"])
                            first["quantity"] = restock_qty
                            first["amount"] = restock_qty * unit
                            first["discount_amount"] = 0
                            first["entry_quantity"] = None
                            first["entry_unit"] = None
                            rdoc["total_amount"] = first["amount"]
                            emitter.add("documents", rdoc)
                            for rl in rlines:
                                emitter.add("document_lines", rl)
                            ledger.seq["stock_ledger"] += 1
                            emitter.add(
                                "stock_ledger",
                                {
                                    "id": seed.uuid7(restock_ms + 1),
                                    "product_id": p["id"],
                                    "document_id": rdoc["id"],
                                    "quantity": restock_qty,
                                    "unit_cost": unit,
                                    "total_cost": first["amount"],
                                    "seq_no": ledger.seq["stock_ledger"],
                                    "occurred_at": restock_ms,
                                    "time_estimated": 0,
                                    "created_at": rdoc["created_at"],
                                },
                            )
                            ledger.apply_stock(p["id"], restock_qty, first["amount"])
                            ledger.inbound_unit_cost(p, first["amount"], restock_qty)
                            ledger.seq["party_ledger"] += 1
                            emitter.add(
                                "party_ledger",
                                {
                                    "id": seed.uuid7(restock_ms + 2),
                                    "party_id": party_id,
                                    "document_id": rdoc["id"],
                                    "amount": -rdoc["total_amount"],
                                    "seq_no": ledger.seq["party_ledger"],
                                    "occurred_at": restock_ms,
                                    "time_estimated": 0,
                                    "created_at": rdoc["created_at"],
                                },
                            )
                            emitter.note_doc()

                    ledger.seq["stock_ledger"] += 1
                    total_cost = ledger.outbound_cost(p["id"], qty)
                    emitter.add(
                        "stock_ledger",
                        {
                            "id": seed.uuid7(created + 1),
                            "product_id": p["id"],
                            "document_id": doc["id"],
                            "quantity": -qty,
                            "unit_cost": int(round(total_cost / float(-qty))) if qty else 0,
                            "total_cost": total_cost,
                            "seq_no": ledger.seq["stock_ledger"],
                            "occurred_at": occurred,
                            "time_estimated": doc["time_estimated"],
                            "created_at": created,
                        },
                    )
                    ledger.apply_stock(p["id"], -qty, total_cost)

            # ---- 往来流水（主单方向）
            ledger.seq["party_ledger"] += 1
            if doc_type in ("sale", "delivery"):
                amount = doc["total_amount"]
            elif doc_type in ("purchase", "sale_return"):
                amount = -doc["total_amount"]
            else:
                amount = doc["total_amount"]
            emitter.add(
                "party_ledger",
                {
                    "id": seed.uuid7(created + 2),
                    "party_id": party_id,
                    "document_id": doc["id"],
                    "amount": amount,
                    "seq_no": ledger.seq["party_ledger"],
                    "occurred_at": occurred,
                    "time_estimated": doc["time_estimated"],
                    "created_at": created,
                },
            )

            # ---- 立即收付（自动生成收付款单 + money/party/settlement）
            if rnd.random() < args.pay_ratio and doc["total_amount"] > 0:
                money_out = doc_type in ("purchase", "sale_return")
                if rnd.random() < 0.25:
                    pay_amount = max(1, int(doc["total_amount"] * rnd.uniform(0.2, 0.8)))
                else:
                    pay_amount = doc["total_amount"]
                pay_ms = created + rnd.randint(5, 300) * 1000
                pay_doc, money, party, settle, pay_id = build_payment_doc(
                    rnd=rnd,
                    ledger=ledger,
                    money_out=money_out,
                    amount=pay_amount,
                    occurred_ms=pay_ms,
                    party_id=party_id,
                    account_id=account_ids[rnd.randrange(len(account_ids))],
                    ref_doc_id=doc["id"],
                    main_doc_id=doc["id"],
                )
                emitter.add("documents", pay_doc)
                emitter.add("money_ledger", money)
                emitter.add("party_ledger", party)
                emitter.add("settlements", settle)
                doc["paid_amount"] += pay_amount
                # 同步第二阶段的候选（同一份 dict 引用 ⇒ 直接改 paid 计数）
                if unpaid and unpaid[-1]["id"] == doc["id"]:
                    unpaid[-1]["paid"] += pay_amount

            # ---- 拒收：送货单 + 全量 sale_return，并把送货单置作废
            if doc_type == "delivery" and rnd.random() < args.refuse_ratio:
                ret_doc, ret_lines = build_doc(
                    rnd=rnd,
                    ledger=ledger,
                    doc_type="sale_return",
                    occurred_ms=occurred + 3600 * 1000,
                    created_ms=created + 3600 * 1000,
                    party_id=party_id,
                    lines=lines,
                    ref_doc_id=doc["id"],
                    status="confirmed",
                )
                ret_doc["total_amount"] = doc["total_amount"]
                if ret_lines:
                    diff = doc["total_amount"] - sum(l["amount"] for l in ret_lines)
                    ret_lines[-1]["amount"] += diff
                emitter.add("documents", ret_doc)
                for line in ret_lines:
                    emitter.add("document_lines", line)
                for line in ret_lines:
                    p = next((x for x in products if x["id"] == line["product_id"]), None)
                    if p is None:
                        continue
                    ledger.seq["stock_ledger"] += 1
                    total_cost = line["amount"]
                    emitter.add(
                        "stock_ledger",
                        {
                            "id": seed.uuid7(created + 3601),
                            "product_id": p["id"],
                            "document_id": ret_doc["id"],
                            "quantity": line["quantity"],
                            "unit_cost": int(round(total_cost / float(line["quantity"]))),
                            "total_cost": total_cost,
                            "seq_no": ledger.seq["stock_ledger"],
                            "occurred_at": occurred + 3600 * 1000,
                            "time_estimated": 0,
                            "created_at": created + 3600 * 1000,
                        },
                    )
                    ledger.apply_stock(p["id"], line["quantity"], total_cost)
                ledger.seq["party_ledger"] += 1
                emitter.add(
                    "party_ledger",
                    {
                        "id": seed.uuid7(created + 3602),
                        "party_id": party_id,
                        "document_id": ret_doc["id"],
                        "amount": -ret_doc["total_amount"],
                        "seq_no": ledger.seq["party_ledger"],
                        "occurred_at": occurred + 3600 * 1000,
                        "time_estimated": 0,
                        "created_at": created + 3600 * 1000,
                    },
                )
                doc["status"] = "cancelled"
                if unpaid and unpaid[-1]["id"] == doc["id"]:
                    unpaid[-1]["status"] = "cancelled"

            docs_total += 1
            emitter.note_doc()
            progress.tick(docs_total)

        day_index += 1
        if target_met():
            stop_reason = "流水达标"
            break
        if emitter.counts["documents"] >= args.max_docs:
            stop_reason = "达到 --max-docs 上限"
            break

    progress.done()

    # ---- 第二阶段：事后收款（只为把 money_ledger、settlements 顶上去）
    # 现实里对应「老板隔几天统一收账」，也顺带覆盖「手记收付款单（ref 为空）」
    if not target_met():
        candidates = [u for u in unpaid if u["status"] != "cancelled" and u["paid"] < u["total_amount"]]
        progress2 = Progress("补收付款", len(candidates), args.quiet)
        for i, target in enumerate(candidates):
            if target_met():
                break
            outstanding = target["total_amount"] - target["paid"]
            if outstanding <= 0:
                continue
            amount = outstanding if rnd.random() < 0.7 else max(1, int(outstanding * 0.5))
            pay_ms = target["occurred_at"] + rnd.randint(1, 20) * 86400000
            if pay_ms > end_ms:
                pay_ms = end_ms - rnd.randint(1, 3600) * 1000
            doc, money, party, settle, _ = build_payment_doc(
                rnd=rnd,
                ledger=ledger,
                money_out=False,
                amount=amount,
                occurred_ms=pay_ms,
                party_id=target["party_id"],
                account_id=account_ids[rnd.randrange(len(account_ids))],
                ref_doc_id=None,  # 手记收付款：ref 为空，会出现在列表里
                main_doc_id=target["id"],
            )
            emitter.add("documents", doc)
            emitter.add("money_ledger", money)
            emitter.add("party_ledger", party)
            emitter.add("settlements", settle)
            target["paid"] += amount
            progress2.tick(i)
            emitter.note_doc()
        progress2.done()

    emitter.flush()
    return {
        "counts": emitter.counts,
        "stop_reason": stop_reason,
        "docs_generated": docs_total,
        "seconds": time.time() - started,
        "commits": emitter.commits,
        "targets_met": target_met(),
    }


# --------------------------------------------------------------------------- 写后规整

def refresh_cache_columns(conn: sqlite3.Connection) -> None:
    """用 SQL 反算缓存字段 —— 这一步保证界面上的数字讲得通。

    - `documents.paid_amount` ← `SUM(settlements.amount)`（不变量 B4）
    - `documents.status`：收付款单恒 `settled`；送货单尊重其状态机；
      其余按「收满即结清」派生；作废的单**不回退**
    """
    conn.execute("BEGIN")
    try:
        conn.execute(
            "UPDATE documents SET paid_amount = COALESCE(("
            "  SELECT SUM(amount) FROM settlements s WHERE s.target_doc_id = documents.id"
            "), 0)"
        )
        conn.execute(
            "UPDATE documents SET status = CASE"
            "  WHEN doc_type IN ('receipt','payment') THEN 'settled'"
            "  WHEN status = 'cancelled' THEN 'cancelled'"
            "  WHEN doc_type = 'delivery' AND status = 'in_transit' THEN 'in_transit'"
            "  WHEN total_amount > 0 AND paid_amount >= total_amount THEN"
            "    CASE WHEN doc_type = 'delivery' THEN 'settled' ELSE 'settled' END"
            "  WHEN doc_type = 'delivery' THEN 'delivered'"
            "  ELSE 'confirmed' END"
        )
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise


# --------------------------------------------------------------------------- 自检

HARD_CHECKS: Tuple[Tuple[str, str], ...] = (
    (
        "B4 paid_amount = SUM(settlements)",
        "SELECT COUNT(*) FROM documents d WHERE d.paid_amount <> COALESCE(("
        "  SELECT SUM(s.amount) FROM settlements s WHERE s.target_doc_id = d.id), 0)",
    ),
    (
        "B5 Σ明细金额 = 单据金额",
        "SELECT COUNT(*) FROM ("
        "  SELECT d.id, d.total_amount, COALESCE(SUM(l.amount), 0) AS s"
        "  FROM documents d LEFT JOIN document_lines l ON l.document_id = d.id"
        "  WHERE d.doc_type IN ('purchase','sale','delivery','sale_return','purchase_return')"
        "  GROUP BY d.id HAVING d.total_amount <> s)",
    ),
    (
        "核销额未超单据总额（同目标求和）",
        "SELECT COUNT(*) FROM ("
        "  SELECT s.target_doc_id, SUM(s.amount) AS a, d.total_amount AS t"
        "  FROM settlements s JOIN documents d ON d.id = s.target_doc_id"
        "  GROUP BY s.target_doc_id HAVING a > t)",
    ),
    (
        "单号唯一",
        "SELECT COUNT(*) - COUNT(DISTINCT doc_no) FROM documents",
    ),
    (
        "seq_no 无重复（四张流水）",
        "SELECT SUM(n) FROM (" + " UNION ALL ".join(
            "SELECT COUNT(*) - COUNT(DISTINCT seq_no) AS n FROM %s" % t
            for t in ("stock_ledger", "money_ledger", "party_ledger", "settlements")
        ) + ")",
    ),
    (
        "seq_no 无空洞（四张流水）",
        "SELECT SUM(CASE WHEN c <> m THEN 1 ELSE 0 END) FROM (" + " UNION ALL ".join(
            "SELECT COUNT(*) AS c, COALESCE(MAX(seq_no), 0) AS m FROM %s" % t
            for t in ("stock_ledger", "money_ledger", "party_ledger", "settlements")
        ) + ")",
    ),
    (
        "money_ledger 只挂在收付款单下",
        "SELECT COUNT(*) FROM money_ledger m JOIN documents d ON d.id = m.document_id"
        " WHERE d.doc_type NOT IN ('receipt','payment')",
    ),
    (
        "收付款单都有 account_id / party_id",
        "SELECT COUNT(*) FROM documents WHERE doc_type IN ('receipt','payment')"
        " AND (account_id IS NULL OR party_id IS NULL)",
    ),
    (
        "entry_quantity / entry_unit 成对",
        "SELECT COUNT(*) FROM document_lines"
        " WHERE (entry_unit IS NULL) <> (entry_quantity IS NULL)",
    ),
)

INFO_QUERIES: Tuple[Tuple[str, str], ...] = (
    ("负库存商品数", "SELECT COUNT(*) FROM ("
        "  SELECT product_id FROM stock_ledger GROUP BY product_id HAVING SUM(quantity) < 0)"),
    ("有库存的商品数", "SELECT COUNT(*) FROM ("
        "  SELECT product_id FROM stock_ledger GROUP BY product_id HAVING SUM(quantity) > 0)"),
    ("单据类型分布", "SELECT COUNT(*) FROM documents"),
    ("作废单数", "SELECT COUNT(*) FROM documents WHERE status = 'cancelled'"),
    ("在途送货单数", "SELECT COUNT(*) FROM documents"
        " WHERE doc_type = 'delivery' AND status = 'in_transit'"),
    ("未结清单据数", "SELECT COUNT(*) FROM documents"
        " WHERE doc_type IN ('sale','purchase','delivery') AND status <> 'cancelled'"
        " AND total_amount - paid_amount > 0"),
)


def table_counts(conn: sqlite3.Connection) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for table in COUNTED_TABLES:
        try:
            out[table] = int(
                conn.execute("SELECT COUNT(*) FROM %s" % seed.quote_ident(table)).fetchone()[0]
            )
        except sqlite3.Error:
            out[table] = -1
    return out


def verify(
    conn: sqlite3.Connection,
    db_path: str,
    min_rows: int,
    enforce_size: bool,
) -> List[str]:
    """造数后的硬自检。返回问题清单（空 = 全过）。

    [enforce_size] = `false` 时**不把「行数不足」算违规** —— 用于 `--verify` 单独
    复检一份已有数据（那时用户可能没传 `--min-rows`，默认 10 万会误报）。
    自洽性（B4/B5/seq_no/单号…）永远都是硬违规。
    """
    problems: List[str] = []

    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        problems.append("integrity_check 不通过：%s" % integrity)
    fk = conn.execute("PRAGMA foreign_key_check").fetchall()
    if fk:
        problems.append("外键校验不通过，%d 处（示例 %s）" % (len(fk), fk[:3]))

    print("")
    print("自检（硬性）")
    for label, sql in HARD_CHECKS:
        try:
            n = int(conn.execute(sql).fetchone()[0] or 0)
        except sqlite3.Error as exc:
            problems.append("%s：查询失败（%s）" % (label, exc))
            print("  ❌ %-38s 查询失败：%s" % (label, exc))
            continue
        ok = n == 0
        print("  %s %-38s %s" % ("✅" if ok else "❌", label, "通过" if ok else "%d 处违规" % n))
        if not ok:
            problems.append("%s：%d 处违规" % (label, n))

    counts = table_counts(conn)
    print("")
    print("行数（每张流水表目标 ≥ %d）" % min_rows if enforce_size else "行数（本次只查自洽性，不卡体量）")
    for table in COUNTED_TABLES:
        n = counts.get(table, -1)
        flag = ""
        if table in TARGET_TABLES and enforce_size:
            flag = " ✅" if n >= min_rows else " ⚠️ 不足"
        print("  %-16s %10d%s" % (table, n, flag))
        if enforce_size and table in TARGET_TABLES and n < min_rows:
            problems.append("表 %s 只有 %d 行，低于目标 %d" % (table, n, min_rows))

    base, wal, shm = db_family_mb(db_path)
    print("")
    print("文件：%s = %.1f MB（WAL %.1f MB / SHM %.1f MB）" % (db_path, base, wal, shm))

    print("")
    print("参考信息（不算违规）")
    for label, sql in INFO_QUERIES:
        try:
            n = conn.execute(sql).fetchone()[0]
        except sqlite3.Error:
            n = "—"
        print("  %-16s %s" % (label, n))
    return problems


# --------------------------------------------------------------------------- 清理

BUSINESS_TABLES_DELETE_ORDER: Tuple[str, ...] = (
    "settlements",
    "money_ledger",
    "party_ledger",
    "stock_ledger",
    "document_lines",
    "documents",
)


def wipe_business_data(conn: sqlite3.Connection, quiet: bool = False) -> None:
    """清空业务数据（**只在 `--confirm-wipe` 之后调用**）。

    顺序按外键依赖倒序；主数据保留（商品/往来方/账户不删）。
    """
    conn.execute("BEGIN")
    try:
        for table in BUSINESS_TABLES_DELETE_ORDER:
            n = conn.execute("SELECT COUNT(*) FROM %s" % seed.quote_ident(table)).fetchone()[0]
            conn.execute("DELETE FROM %s" % seed.quote_ident(table))
            if not quiet:
                print("  已清空 %-16s %d 行" % (table, n))
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise


def has_business_data(conn: sqlite3.Connection) -> Tuple[bool, int]:
    total = 0
    for table in ("documents", "document_lines", "stock_ledger", "money_ledger", "party_ledger", "settlements"):
        try:
            total += int(
                conn.execute("SELECT COUNT(*) FROM %s" % seed.quote_ident(table)).fetchone()[0]
            )
        except sqlite3.Error:
            pass
    return total > 0, total


# --------------------------------------------------------------------------- CLI

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="perf_seed.py",
        description="为长时间性能实测造一份体量真实、且内部自洽的账本数据（每张流水表 ≥ 10 万行）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例：\n"
            "  python tool/perf_seed.py --data-dir \"D:\\\\神算子数据\" --dry-run\n"
            "  python tool/perf_seed.py --data-dir \"D:\\\\神算子数据\" --min-rows 100000\n"
            "  python tool/perf_seed.py --data-dir \"D:\\\\神算子数据\" --verify\n"
            "  python tool/perf_seed.py --db .\\\\perf.db --min-rows 20000 --days 180\n"
            "\n"
            "⚠️ 这份数据只用于**性能与容量**实测，不能用于业务正确性验收（它不是 RuleEngine）。\n"
        ),
    )

    where = parser.add_argument_group("目标库（二选一；写入时必须明确指定）")
    where.add_argument("--db", help="直接指定库文件路径（不存在则按 schema 新建）")
    where.add_argument(
        "--data-dir", help="数据目录（库名固定 %s，与软件一致）" % seed.DATA_FILE_NAME
    )
    where.add_argument(
        "--schema-source", default=None, help="可选：显式指定 schema.dart；默认仓库源码 → 快照"
    )

    size = parser.add_argument_group("体量与形态")
    size.add_argument(
        "--min-rows",
        type=int,
        default=None,
        help="每张流水表至少达到的行数（造数默认 %d；--verify 不传则只查自洽性、不卡体量）"
        % DEFAULT_MIN_ROWS,
    )
    size.add_argument("--days", type=int, default=730, help="时间轴长度，天（默认 %(default)s）")
    size.add_argument(
        "--docs-per-day", type=int, default=60, help="普通日每天的单据数（默认 %(default)s）"
    )
    size.add_argument(
        "--recent-days", type=int, default=7, help="「最近」区间长度，天（默认 %(default)s）"
    )
    size.add_argument(
        "--recent-share",
        type=float,
        default=0.15,
        help="落在最近区间的比例；>0 时最近几天每天按 3 倍量造（默认 %(default)s）",
    )
    size.add_argument("--products", type=int, default=300, help="商品数（默认 %(default)s）")
    size.add_argument("--parties", type=int, default=200, help="往来方数（默认 %(default)s）")
    size.add_argument("--accounts", type=int, default=4, help="账户数（默认 %(default)s）")
    size.add_argument(
        "--pay-ratio", type=float, default=0.65, help="开单时立即收付的比例（默认 %(default)s）"
    )
    size.add_argument(
        "--purchase-ratio", type=float, default=0.12, help="采购占比（默认 %(default)s）"
    )
    size.add_argument(
        "--delivery-ratio", type=float, default=0.10, help="送货占比（默认 %(default)s）"
    )
    size.add_argument(
        "--return-ratio", type=float, default=0.03, help="退货占比（默认 %(default)s）"
    )
    size.add_argument(
        "--refuse-ratio", type=float, default=0.03, help="送货被拒收（整单退回）的比例（默认 %(default)s）"
    )
    size.add_argument("--seed", default="perf", help="随机种子（默认 %(default)s）")
    size.add_argument(
        "--max-docs", type=int, default=400000, help="单据数上限（安全阀，默认 %(default)s）"
    )
    size.add_argument(
        "--chunk-docs", type=int, default=500, help="每多少张单提交一个事务（默认 %(default)s）"
    )
    size.add_argument(
        "--stress-docno",
        action="store_true",
        help="最后一天故意造 >999 张同类型单（复现「单号第 1000 单撞号」的已知缺陷）",
    )

    safety = parser.add_argument_group("安全阀")
    safety.add_argument("--dry-run", action="store_true", help="只算不写：打印预计规模与耗时")
    safety.add_argument("--verify", action="store_true", help="只自检，不造数")
    safety.add_argument(
        "--allow-nonempty",
        action="store_true",
        help="允许在已有业务数据的库上追加（默认拒绝）",
    )
    safety.add_argument(
        "--confirm-wipe",
        action="store_true",
        help="配合 --allow-nonempty：先清空六张业务表再重造（主数据保留）",
    )
    safety.add_argument(
        "--vacuum", action="store_true", help="清空后执行 VACUUM（重建文件、回收空间，较慢）"
    )
    safety.add_argument("--quiet", action="store_true", help="只打印结论")
    safety.add_argument("--json-out", default=None, help="把本次结果写成 JSON（便于汇总）")
    return parser


def resolve_db_path(args: argparse.Namespace) -> Optional[str]:
    if args.db:
        return os.path.abspath(args.db)
    if args.data_dir:
        return os.path.abspath(args.data_dir)
    return None


def load_ddl(conn_hint: "Optional[str]") -> Tuple[Optional[List[str]], int, Optional[str]]:
    """加载建表语句。

    返回 `(statements, version, note)`；`statements is None` = 只拿到了版本号
    （库已存在，本轮不需要建表）。

    三级回退，每一级都写清楚为什么：

    1. **正常路径**：`schema.dart`（开发仓库）或随脚本分发的 `schema_snapshot.json`；
    2. **源码回退**：仓库在、但分发快照过期 —— 把源码复制到临时路径再解析
       （`seed.load_ddl_from_schema_source` 只在「路径 == 默认来源」时校验快照，
       复制后就不再触发），并**明确提示快照需要重新生成**；
    3. **库已存在**：连版本都读不到时，只要目标库已有 `documents` 表就继续 ——
       本脚本这时不需要 DDL（不建表），版本号从 `PRAGMA user_version` 取。
    """
    try:
        statements, version = seed.load_ddl_from_schema_source(None)
        return statements, version, None
    except seed.SchemaSourceError as first:
        source = seed.default_schema_source()
        if os.path.isfile(source):
            import shutil
            import tempfile

            tmp = os.path.join(tempfile.gettempdir(), "perf_seed_schema_copy.dart")
            shutil.copyfile(source, tmp)
            try:
                statements, version = seed.load_ddl_from_schema_source(tmp)
            finally:
                try:
                    os.remove(tmp)
                except OSError:
                    pass
            return (
                statements,
                version,
                "⚠️ 随脚本分发的 schema 快照已过期（开发机上正常，**测试机上会直接拒跑**）。\n"
                "   本轮已改用 schema.dart 解析，能继续；分发前请跑：python tool/gen_schema_snapshot.py\n"
                "   原因：%s" % str(first).splitlines()[0],
            )
        # 没有源码：只能靠库里已有的结构
        if conn_hint and os.path.exists(conn_hint):
            try:
                probe = sqlite3.connect(conn_hint, timeout=5.0)
                try:
                    if seed.table_exists(probe, "documents"):
                        return None, seed.user_version(probe), (
                            "⚠️ 读不到 schema（没有源码、也没有可用快照），"
                            "但目标库已存在（v%d）—— 本轮不建表，直接往里写。" % seed.user_version(probe)
                        )
                finally:
                    probe.close()
            except sqlite3.Error:
                pass
        raise


def target_db_path(args: argparse.Namespace) -> Optional[str]:
    """`--data-dir` 时拼上固定库名；`--db` 直接用。写库与 dry-run 共用这一处。"""
    path = resolve_db_path(args)
    if path and args.data_dir:
        return os.path.join(path, seed.DATA_FILE_NAME)
    return path


def estimate(args: argparse.Namespace) -> Dict[str, Any]:
    """不写库，按比例估一下规模、文件大小与耗时。"""
    # 每张业务单平均产出：1 单 + 2 明细 + 2 库存 + 2.3 往来 + 0.65 核销 + 0.65 收付款单
    per_doc_lines = 2.2
    per_doc_stock = 2.2
    per_doc_party = 1.0 + (0.65 if args.pay_ratio > 0 else 0.0)
    paid = args.pay_ratio
    docs_for_settle = args.min_rows / max(paid, 0.01)
    docs_for_lines = args.min_rows / per_doc_lines
    docs_for_stock = args.min_rows / per_doc_stock
    docs_for_party = args.min_rows / per_doc_party
    docs_needed = int(max(docs_for_settle, docs_for_lines, docs_for_stock, docs_for_party))
    docs_needed = min(docs_needed, args.max_docs)
    rows_total = int(
        docs_needed * (1 + per_doc_lines + per_doc_stock + per_doc_party + paid * 2)
        + args.products
        + args.parties
        + args.accounts
    )
    # 经验值（本脚本实测）：含索引约 0.33 KB/行；单表 10 万行的库量级在 300–500 MB。
    size_mb = rows_total * 0.00035
    # 造数速度：批量 executemany + 500 单一事务，实测约 3000–8000 行/秒
    seconds = rows_total / 5000.0
    return {
        "docs_needed": docs_needed,
        "rows_total": rows_total,
        "size_mb": size_mb,
        "seconds": seconds,
    }


def print_plan(args: argparse.Namespace, db_path: Optional[str], version: int) -> None:
    est = estimate(args)
    print("性能数据造数 —— 计划（--dry-run，未写任何数据）")
    print("  目标库      %s" % (db_path or "（未指定 —— 真正写入时必须指定）"))
    print("  schema 版本 %d" % version)
    print("  目标行数    每张流水表 ≥ %d" % args.min_rows)
    print("  主数据      商品 %d / 往来方 %d / 账户 %d"
          % (args.products, args.parties, args.accounts))
    print("  时间轴      %d 天（最近 %d 天加密）" % (args.days, args.recent_days))
    print("  抽样比例    立即收付 %.0f%% / 采购 %.0f%% / 送货 %.0f%% / 退货 %.0f%% / 拒收 %.0f%%"
          % (args.pay_ratio * 100, args.purchase_ratio * 100, args.delivery_ratio * 100,
             args.return_ratio * 100, args.refuse_ratio * 100))
    print("")
    print("  预计需要单据约 %d 张，全部行约 %d 条，库约 %.0f MB，造数约 %.0f 秒"
          % (est["docs_needed"], est["rows_total"], est["size_mb"], est["seconds"]))
    print("  （估算只用于心里有数；真实值以跑完的汇总为准）")
    if args.stress_docno:
        print("")
        print("  ⚠️ 已启用 --stress-docno：最后一天会造 >999 张同类型单，用于复现已知缺陷。")
        print("     这批数据**不适合**做「长时间使用」的干净基线 —— 请单独跑一轮。")


def main(argv: Optional[Sequence[str]] = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except Exception:
            pass
    args = build_parser().parse_args(argv)

    if args.db and args.data_dir:
        print("⛔ --db 与 --data-dir 只能指定一个。", file=sys.stderr)
        return 2
    if not args.dry_run and not args.verify and not args.db and not args.data_dir:
        print(
            "⛔ 写入前必须显式指定 --db 或 --data-dir；脚本没有默认目标。\n"
            "   建议先用 --dry-run 看一眼规模。",
            file=sys.stderr,
        )
        return 2
    if args.confirm_wipe and not args.allow_nonempty:
        print("⛔ --confirm-wipe 必须与 --allow-nonempty 一起用（确认这是隔离的测试库）。", file=sys.stderr)
        return 2

    t0 = time.time()
    rnd = random.Random(args.seed)

    # `--min-rows` 不传：造数按默认目标；`--verify` 只查自洽性（不卡体量）
    enforce_size = args.min_rows is not None
    args.min_rows = int(args.min_rows) if args.min_rows is not None else DEFAULT_MIN_ROWS

    db_path = target_db_path(args)

    # ---- schema（建表才需要；库已存在时连不上源码也能继续）
    try:
        statements, version, schema_note = load_ddl(db_path)
    except seed.SchemaSourceError as exc:
        print("无法加载数据库结构：\n%s" % exc, file=sys.stderr)
        return 3
    if schema_note:
        print(schema_note, file=sys.stderr if "过期" in schema_note else sys.stdout)

    if args.dry_run:
        print_plan(args, db_path, version)
        return 0

    assert db_path is not None
    is_new = not os.path.exists(db_path)
    os.makedirs(os.path.dirname(db_path) or ".", exist_ok=True)

    conn = sqlite3.connect(db_path, isolation_level=None, timeout=30.0)
    try:
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA synchronous = NORMAL")
        conn.execute("PRAGMA foreign_keys = ON")

        # ---- 只自检：库必须已经存在且建过表
        if args.verify and (is_new or not seed.table_exists(conn, "documents")):
            print(
                "⛔ 这个位置没有可自检的库（%s）。\n"
                "   请先造数，或用 --db 指向已有库。" % db_path,
                file=sys.stderr,
            )
            return 3
        if is_new or not seed.table_exists(conn, "documents"):
            if statements is None:
                print(
                    "⛔ 这个位置还没有库，而脚本读不到建表语句（既没有 schema.dart，"
                    "也没有可用的 schema_snapshot.json）。\n"
                    "   两种做法任选：\n"
                    "     a) 先启动一次神算子，让它自己建好数据目录与库，关掉后再跑本脚本；\n"
                    "     b) 在开发仓库里先跑 python tool/gen_schema_snapshot.py，"
                    "把 schema_snapshot.json 与脚本一起分发。",
                    file=sys.stderr,
                )
                return 3
            print("空库：按 schema v%d 建表（与软件自己建的库逐字一致）" % version)
            seed.create_schema(conn, statements, version)
        else:
            actual = seed.user_version(conn)
            if actual != version:
                print(
                    "⛔ 库的 schema 版本是 %d，脚本支持 %d。\n"
                    "   请用与软件同版本的脚本，或另建一个空库。" % (actual, version),
                    file=sys.stderr,
                )
                return 3

        # ---- 已有数据的处置
        nonempty, n = has_business_data(conn)
        if nonempty and not args.verify:
            if not args.allow_nonempty:
                print(
                    "⛔ 这个库里已经有 %d 行业务数据。造数会**追加**（不是重造），"
                    "多轮混在一起会让基线不可比。\n"
                    "   确认这是隔离的测试库时加：--allow-nonempty（重造再加 --confirm-wipe）"
                    % n,
                    file=sys.stderr,
                )
                return 2
            if args.confirm_wipe:
                print("清空六张业务表（主数据保留）……")
                wipe_business_data(conn, args.quiet)
                if args.vacuum:
                    print("  VACUUM（回收空间，可能要几十秒）……")
                    conn.execute("VACUUM")

        if args.verify:
            problems = verify(conn, db_path, args.min_rows, enforce_size)
            print("")
            if problems:
                print("结论：❌ 有 %d 条违规，这批数据不能用作性能基线。" % len(problems))
                for p in problems:
                    print("  - %s" % p)
                return 5
            print("结论：✅ 自检全过，可以用作性能基线。")
            return 0

        # ---- 主数据
        products, parties, accounts = load_existing_master(conn, args.products, args.parties)
        stamp = now_ms()
        if len(products) < args.products:
            rows = make_products(rnd, len(products), args.products - len(products), stamp)
            conn.execute("BEGIN")
            for row in rows:
                cols = list(row.keys())
                conn.execute(
                    "INSERT INTO products (%s) VALUES (%s)"
                    % (", ".join(seed.quote_ident(c) for c in cols), ", ".join("?" for _ in cols)),
                    [row[c] for c in cols],
                )
            conn.execute("COMMIT")
            products.extend(
                {
                    "id": r["id"],
                    "name": r["name"],
                    "unit": r["unit"],
                    "sell_price": r["sell_price"],
                    "cost_price": r["cost_price"],
                    "package_unit": r["package_unit"],
                    "package_size": r["package_size"],
                    "barcode": r["barcode"],
                }
                for r in rows
            )
        if len(parties) < args.parties:
            rows = make_parties(rnd, len(parties), args.parties - len(parties), stamp + 1)
            conn.execute("BEGIN")
            for row in rows:
                cols = list(row.keys())
                conn.execute(
                    "INSERT INTO parties (%s) VALUES (%s)"
                    % (", ".join(seed.quote_ident(c) for c in cols), ", ".join("?" for _ in cols)),
                    [row[c] for c in cols],
                )
            conn.execute("COMMIT")
            parties.extend({"id": r["id"], "name": r["name"], "roles": r["roles"]} for r in rows)
        if not accounts:
            rows = make_accounts(args.accounts, stamp + 2)
            conn.execute("BEGIN")
            for row in rows:
                cols = list(row.keys())
                conn.execute(
                    "INSERT INTO accounts (%s) VALUES (%s)"
                    % (", ".join(seed.quote_ident(c) for c in cols), ", ".join("?" for _ in cols)),
                    [row[c] for c in cols],
                )
            conn.execute("COMMIT")
            accounts = [{"id": r["id"], "name": r["name"]} for r in rows]

        if not args.quiet:
            print("主数据：商品 %d / 往来方 %d / 账户 %d"
                  % (len(products), len(parties), len(accounts)))
            print("开始造单（每张流水表目标 ≥ %d 行）……" % args.min_rows)

        result = generate(
            conn,
            rnd=rnd,
            args=args,
            products=products,
            parties=parties,
            accounts=accounts,
        )

        print("规整缓存字段（paid_amount / status 由流水反算）……")
        refresh_cache_columns(conn)
        print("checkpoint（把 WAL 归并回主库，便于量文件大小）……")
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")

        problems = verify(conn, db_path, args.min_rows, enforce_size)  # 造数后：体量必须达标
        counts = table_counts(conn)
        base, wal, shm = db_family_mb(db_path)
        summary = {
            "db": db_path,
            "schema_version": version,
            "min_rows": args.min_rows,
            "seed": args.seed,
            "seconds": round(time.time() - t0, 1),
            "counts": counts,
            "file_mb": round(base, 1),
            "wal_mb": round(wal, 1),
            "stop_reason": result["stop_reason"],
            "docs_generated": result["docs_generated"],
            "targets_met": result["targets_met"],
            "problems": problems,
        }
        if args.json_out:
            with open(args.json_out, "w", encoding="utf-8") as fh:
                json.dump(summary, fh, ensure_ascii=False, indent=2)
            if not args.quiet:
                print("")
                print("已写出 %s" % args.json_out)

        print("")
        print("性能数据 —— 造数完成（用时 %.0f 秒）" % summary["seconds"])
        print("  停止原因：%s；生成单据 %d 张" % (result["stop_reason"], result["docs_generated"]))
        print("  库文件：%.1f MB（WAL 已归并）" % base)
        print("")
        print("下一步：")
        print("  1) 基线（软件不要开）：python tool/perf_bench.py --db \"%s\" --csv baseline-before.csv" % db_path)
        print("  2) 人工实测：        python tool/perf_monitor.py run --db \"%s\" --out D:\\perf-run1" % db_path)
        if problems:
            print("")
            print("结论：❌ 有 %d 条违规，这份数据不能当基线（见上）。" % len(problems))
            return 5
        print("")
        print("结论：✅ 自检全过，可以用作性能基线。")
        return 0
    except sqlite3.OperationalError as exc:
        print("⛔ 数据库操作失败（可能是库被软件占用 / 磁盘满）：%s" % exc, file=sys.stderr)
        print("   请先关掉神算子再跑。", file=sys.stderr)
        return 1
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
