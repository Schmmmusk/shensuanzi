#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""神算子数据库**只读**审计（人工验收时用，不写一个字节）。

用法（软件开着也能跑 —— WAL 支持并发读）：

    python tool/db_audit.py --db "E:\\SSZ-Rerun-065\\data\\shensuanzi.db"
    python tool/db_audit.py --db "..." --verbose      # 把每条的样本行也打出来

输出：每条检查一行 ✅ / ❌ + 实测数字；末尾给「统计摘要」（可直接填进验收记录表）。
有任何 ❌ ⇒ 退出码 1。

## 为什么要有这个脚本

外测报告 §5 用 4 条 SQL 查账务不变量，但**命令散在报告里、每次要手抄**；
而且有几条（退货累计、孤儿行、seq_no 唯一）报告没查。人工验收时最怕两件事：
**查漏了**和**查了但看不懂结果**。这里把「查什么 + 怎么判 + 打印什么」固定下来。

## 判定口径（与 `Agents.md` §二 纪律对齐）

| 编号 | 不变量 | 纪律 |
|---|---|---|
| INV-1 | 单据金额 = 明细行金额合计 | 真相在流水 |
| INV-1b | 行金额 = 数量 × 单价（**舍入容差 ±半件**） | v3 `unit_price` 是派生值 |
| INV-2 | `paid_amount` 缓存 = 核销合计 | 缓存不是真相 |
| INV-3 | 每笔资金流水都挂在一张**收付款单**下 | 纪律 11 |
| INV-4 | 账户余额 = 期初 + 流水（打印，人工比对界面） | 真相在流水 |
| INV-5 | 往来余额 = 流水合计（打印，人工比对界面） | 真相在流水 |
| INV-6 | 四张流水 `seq_no` 无重复 | 纪律 5 |
| INV-7 | 退货累计不超原单金额 | RULE-007 |
| INV-8 | 没有孤儿行（明细 / 流水指向不存在的单） | 外键在客户端是关的 |

⚠️ **本脚本不改库**：`mode=ro` + 只 SELECT。
（SQLite 在 WAL 下可能临时读写 `-shm` 共享索引文件 —— 那是它的正常行为，
数据本身一个字节都不动。）发现异常也**不要**在这里修 ——
先截图存证，再按 `docs/desktop_acceptance.md` §十二 回报。
"""

import argparse
import os
import sqlite3
import sys

# 有明细的「业务单」（盘点单 amount 恒 0，也走 INV-1；收付款单没有明细）
DOC_TYPES_WITH_LINES = ('sale', 'purchase', 'delivery',
                        'sale_return', 'purchase_return', 'stocktake')
# `paid_amount` 有意义的三类（退货单的「未退」另算，不在这里比）
DOC_TYPES_WITH_PAID = ('sale', 'purchase', 'delivery')
LEDGER_TABLES = ('stock_ledger', 'money_ledger', 'party_ledger', 'settlements')


class Audit:
    def __init__(self, conn, verbose=False):
        self.conn = conn
        self.verbose = verbose
        self.failed = 0

    def rows(self, sql, args=()):
        return self.conn.execute(sql, args).fetchall()

    def check(self, code, title, sql, args=(), hard=True, note=None):
        """跑一条「违规行」查询：0 行 = 通过。"""
        try:
            bad = self.rows(sql, args)
        except sqlite3.Error as exc:
            print(f'  ⚠️  {code} {title} —— 查询失败：{exc}')
            self.failed += 1
            return []
        if bad:
            mark = '❌' if hard else '⚠️ '
            print(f'  {mark} {code} {title} —— {len(bad)} 条异常')
            for row in bad[:5 if not self.verbose else len(bad)]:
                print('        ' + str(tuple(row)))
            if len(bad) > 5 and not self.verbose:
                print(f'        …还有 {len(bad) - 5} 条（加 --verbose 看全部）')
            if hard:
                self.failed += 1
        else:
            print(f'  ✅ {code} {title}')
            if note:
                print(f'        {note}')
        return bad

    def info(self, code, title, sql, args=()):
        """打印型检查（不判定）：给人拿去和界面比对。"""
        try:
            rows = self.rows(sql, args)
        except sqlite3.Error as exc:
            print(f'  ⚠️  {code} {title} —— 查询失败：{exc}')
            return []
        print(f'  📋 {code} {title}（{len(rows)} 行，人工与界面对比）')
        for row in rows[:30]:
            print('        ' + str(tuple(row)))
        if len(rows) > 30:
            print(f'        …还有 {len(rows) - 30} 行')
        return rows


def main():
    ap = argparse.ArgumentParser(description='神算子数据库只读审计')
    ap.add_argument('--db', required=True, help='shensuanzi.db 的完整路径')
    ap.add_argument('--verbose', action='store_true', help='打印全部异常行')
    args = ap.parse_args()

    path = os.path.abspath(args.db)
    if not os.path.isfile(path):
        raise SystemExit(f'❌ 找不到数据库：{path}')

    # mode=ro：只读；immutable=0 允许读 WAL 里还没 checkpoint 的新数据
    uri = 'file:' + path.replace('\\', '/') + '?mode=ro'
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row

    print(f'数据库：{path}')
    print(f'大小：{os.path.getsize(path) / 1048576:.2f} MB')
    ver = conn.execute('PRAGMA user_version').fetchone()[0]
    print(f'schema user_version：{ver}')
    print()

    a = Audit(conn, verbose=args.verbose)

    print('—— 账务不变量 ————————————————————————————')
    types = ','.join("'%s'" % t for t in DOC_TYPES_WITH_LINES)
    a.check('INV-1', '单据金额 = 明细行金额合计',
            f'''SELECT d.doc_no, d.doc_type, d.total_amount, COALESCE(SUM(l.amount), 0) AS lines_sum
                FROM documents d LEFT JOIN document_lines l ON l.document_id = d.id
                WHERE d.doc_type IN ({types})
                GROUP BY d.id HAVING d.total_amount <> lines_sum''')

    # ⚠️ 必须**减去让价**：v3 起 `amount = quantity × unit_price − discount_amount`
    #（整单议价分摊到行）。不减的话，每一行让过价的单都会被误报成异常。
    a.check('INV-1b', '行金额 = 数量 × 单价 − 让价（容差 ±半件，单价是派生值）',
            '''SELECT d.doc_no, l.quantity, l.unit_price, l.discount_amount, l.amount
               FROM document_lines l JOIN documents d ON d.id = l.document_id
               WHERE ABS(l.amount - (l.quantity * l.unit_price - l.discount_amount)) * 2
                     > l.quantity''')

    a.check('INV-1b*', '行金额 = 数量 × 单价 − 让价（严格相等；不等**可能只是舍入**）',
            '''SELECT d.doc_no, l.quantity, l.unit_price, l.discount_amount, l.amount
               FROM document_lines l JOIN documents d ON d.id = l.document_id
               WHERE l.amount <> l.quantity * l.unit_price - l.discount_amount''',
            hard=False)

    paid_types = ','.join("'%s'" % t for t in DOC_TYPES_WITH_PAID)
    a.check('INV-2', 'paid_amount 缓存 = 核销合计',
            f'''SELECT d.doc_no, d.doc_type, d.paid_amount,
                       COALESCE((SELECT SUM(s.amount) FROM settlements s
                                 WHERE s.target_doc_id = d.id), 0) AS settled
                FROM documents d
                WHERE d.doc_type IN ({paid_types}) AND d.status <> 'cancelled'
                  AND d.paid_amount <> settled''')

    a.check('INV-3', '每笔资金流水都挂在一张收付款单下（纪律 11）',
            '''SELECT m.document_id, d.doc_type
               FROM money_ledger m LEFT JOIN documents d ON d.id = m.document_id
               WHERE d.id IS NULL OR d.doc_type NOT IN ('receipt', 'payment')''')

    a.check('INV-7', '退货累计不超原单金额（RULE-007）',
            '''SELECT o.doc_no, o.total_amount, COALESCE(SUM(r.total_amount), 0) AS returned
               FROM documents o JOIN documents r ON r.ref_doc_id = o.id
               WHERE r.doc_type IN ('sale_return', 'purchase_return')
               GROUP BY o.id HAVING returned > o.total_amount''')

    a.check('INV-8', '没有孤儿行（明细 / 流水指向不存在的单）',
            '''SELECT * FROM (\n               SELECT 'document_lines' AS t, COUNT(*) AS n FROM document_lines l
                 LEFT JOIN documents d ON d.id = l.document_id WHERE d.id IS NULL
               UNION ALL
               SELECT 'stock_ledger', COUNT(*) FROM stock_ledger x
                 LEFT JOIN documents d ON d.id = x.document_id WHERE d.id IS NULL
               UNION ALL
               SELECT 'money_ledger', COUNT(*) FROM money_ledger x
                 LEFT JOIN documents d ON d.id = x.document_id WHERE d.id IS NULL
               UNION ALL
               SELECT 'party_ledger', COUNT(*) FROM party_ledger x
                 LEFT JOIN documents d ON d.id = x.document_id WHERE d.id IS NULL
               UNION ALL
               SELECT 'settlements.receipt', COUNT(*) FROM settlements s
                 LEFT JOIN documents d ON d.id = s.receipt_doc_id WHERE d.id IS NULL
               UNION ALL
               SELECT 'settlements.target', COUNT(*) FROM settlements s
                 LEFT JOIN documents d ON d.id = s.target_doc_id WHERE d.id IS NULL\n               ) WHERE n > 0''')

    print()
    print('—— 流水完整性 ————————————————————————————')
    for table in LEDGER_TABLES:
        a.check(f'INV-6/{table}', f'{table}.seq_no 无重复',
                f'''SELECT seq_no, COUNT(*) AS n FROM {table}
                    GROUP BY seq_no HAVING n > 1''')

    print()
    print('—— 打印型（拿去和界面对）——————————————————')
    a.info('INV-4', '账户余额 = 期初 + 流水',
           '''SELECT a.name, a.initial_balance,
                     a.initial_balance + COALESCE(SUM(m.amount), 0) AS balance_cents
              FROM accounts a LEFT JOIN money_ledger m ON m.account_id = a.id
              GROUP BY a.id ORDER BY a.name''')

    a.info('INV-5', '往来余额 = 流水合计（正 = 对方欠我）',
           '''SELECT p.name, COALESCE(SUM(l.amount), 0) AS balance_cents
              FROM parties p LEFT JOIN party_ledger l ON l.party_id = p.id
              GROUP BY p.id ORDER BY ABS(balance_cents) DESC''')

    print()
    print('—— 统计摘要（填进验收记录表）———————————————')
    def count(sql, *args):
        return conn.execute(sql, args).fetchone()[0]
    print(f'  documents        {count("SELECT COUNT(*) FROM documents")}')
    print(f'  document_lines   {count("SELECT COUNT(*) FROM document_lines")}')
    print(f'  products         {count("SELECT COUNT(*) FROM products")}')
    print(f'  parties          {count("SELECT COUNT(*) FROM parties")}')
    print(f'  accounts         {count("SELECT COUNT(*) FROM accounts")}')
    print(f'  stock_ledger     {count("SELECT COUNT(*) FROM stock_ledger")}')
    print(f'  money_ledger     {count("SELECT COUNT(*) FROM money_ledger")}')
    print(f'  party_ledger     {count("SELECT COUNT(*) FROM party_ledger")}')
    print(f'  settlements      {count("SELECT COUNT(*) FROM settlements")}')
    for row in conn.execute('SELECT doc_type, COUNT(*) AS n FROM documents '
                            'GROUP BY doc_type ORDER BY doc_type'):
        print('    · %-16s %s' % (row[0], row[1]))

    conn.close()
    print()
    if a.failed:
        print(f'❌ {a.failed} 项检查不通过 —— 先截图存证，别急着改数据')
        return 1
    print('✅ 全部硬性检查通过（打印型请自行与界面对一遍）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
