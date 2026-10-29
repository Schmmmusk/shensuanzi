# -*- coding: utf-8 -*-
"""把一个 **v6** 库降级回 **v5 形状**，用来验证「老库升级」这条迁移路径。

## 为什么需要它

测试机房的机器**离开后会被还原**，而 schema 变更必须在「老库」上验。
传统做法是先装一个旧预览版建出 v5 库 —— 但那样还要解决「怎么给 v5 库造数」
（造数脚本只认当前版本的快照）。

本脚本走另一条路：**先把 v6 库造好（造数脚本原生支持），再降级成 v5**，
然后用新包打开它 ⇒ 触发真实的 v5→v6 迁移。走的还是同一条迁移代码路径，
且不需要分发任何旧版本安装包。

## 降级做了三件事（与 v6 迁移严格互逆）

1. `DROP INDEX idx_docs_bday_created`
2. `ALTER TABLE documents DROP COLUMN business_day`
3. `PRAGMA user_version = 5`

⚠️ 列是**最后**加上的（`business_day` 在 `documents` 的末列），所以 `DROP COLUMN`
之后列顺序与真 v5 逐字一致 —— 这不是巧合，是 v6 建表时刻意把它放在最后。

⚠️ 本脚本**只给测试库用**。它会让「业务数据只插入不更新」看起来被违反 ——
实际上没有：`DROP COLUMN` 是结构操作，不写任何业务值，且只发生在测试库上。
**绝不要对用户的正式库跑它**（脚本会先检查：库里有数据也可以，但会要求 `--yes`）。
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import sys
from typing import Any, List

TARGET_VERSION = 5
SOURCE_VERSION = 6

#: v6 才有的东西（降级时移除）
V6_COLUMN = 'business_day'
V6_INDEX = 'idx_docs_bday_created'


def _columns(conn: sqlite3.Connection, table: str) -> List[str]:
    return [r[1] for r in conn.execute('PRAGMA table_info(%s)' % table)]


def _indexes(conn: sqlite3.Connection, table: str) -> List[str]:
    return [r[1] for r in conn.execute('PRAGMA index_list(%s)' % table)]


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog='downgrade_to_v5.py',
        description='把 v6 库降级成 v5 形状（仅用于验证「老库升级」的迁移路径）',
    )
    parser.add_argument('--db', required=True, help='库文件路径（测试库，不是用户正式库）')
    parser.add_argument(
        '--yes',
        action='store_true',
        help='库里有业务数据时也照做（脚本默认拒绝，防止误用到正式库）',
    )
    parser.add_argument(
        '--dry-run', action='store_true', help='只检查并打印将做什么，不改文件'
    )
    args = parser.parse_args(argv)

    path = os.path.abspath(args.db)
    if not os.path.isfile(path):
        print('⛔ 找不到库文件：%s' % path, file=sys.stderr)
        return 3

    conn = sqlite3.connect(path)
    try:
        version = int(conn.execute('PRAGMA user_version').fetchone()[0])
        if version == TARGET_VERSION:
            print('这个库已经是 v%d，不需要降级。' % TARGET_VERSION)
            return 0
        if version != SOURCE_VERSION:
            print(
                '⛔ 只支持 v%d → v%d，当前是 v%d。' % (SOURCE_VERSION, TARGET_VERSION, version),
                file=sys.stderr,
            )
            return 3

        columns = _columns(conn, 'documents')
        indexes = _indexes(conn, 'documents')
        if V6_COLUMN not in columns:
            print('⛔ documents 里没有 %s —— 这个库不像 v6。' % V6_COLUMN, file=sys.stderr)
            return 3

        docs = int(conn.execute('SELECT COUNT(*) FROM documents').fetchone()[0])
        print('库        %s' % path)
        print('当前版本  v%d；documents %d 行；%s 列在；%s 索引在'
              % (version, docs, V6_COLUMN, V6_INDEX if V6_INDEX in indexes else '（缺）'))

        plan = [
            'DROP INDEX IF EXISTS %s' % V6_INDEX,
            'ALTER TABLE documents DROP COLUMN %s' % V6_COLUMN,
            'PRAGMA user_version = %d' % TARGET_VERSION,
        ]
        # `--dry-run` **不改文件**，所以它应当绕过下面那道「库里有数据」的保护 ——
        # 那道保护的目的是防误改正式库，而只看不动没有风险。
        if args.dry_run:
            print('\n将执行（--dry-run，未改文件）：')
            for sql in plan:
                print('  · %s' % sql)
            return 0

        if docs > 0 and not args.yes:
            print(
                '\n⛔ 这个库里有 %d 张单据。降级会让「business_day」这一列消失，\n'
                '   只在**测试库**上才有意义。确认是测试库就加 --yes。' % docs,
                file=sys.stderr,
            )
            return 2

        conn.execute('BEGIN')
        try:
            for sql in plan:
                conn.execute(sql)
            conn.execute('COMMIT')
        except Exception:
            conn.execute('ROLLBACK')
            raise

        # 复核：形状真的回到 v5 了吗
        after_columns = _columns(conn, 'documents')
        after_indexes = _indexes(conn, 'documents')
        after_version = int(conn.execute('PRAGMA user_version').fetchone()[0])
        ok = (
            after_version == TARGET_VERSION
            and V6_COLUMN not in after_columns
            and V6_INDEX not in after_indexes
        )
        print('\n降级完成：v%d；%s %s；%s %s'
              % (
                  after_version,
                  V6_COLUMN,
                  '已移除' if V6_COLUMN not in after_columns else '**仍在**',
                  V6_INDEX,
                  '已移除' if V6_INDEX not in after_indexes else '**仍在**',
              ))
        if not ok:
            print('⛔ 复核没通过，形状不对 —— 别用这个库做迁移测试。', file=sys.stderr)
            return 4
        print('   单据仍有 %d 张（数据没动）。现在用新包打开它，就会跑 v5→v6 迁移。'
              % int(conn.execute('SELECT COUNT(*) FROM documents').fetchone()[0]))
        return 0
    finally:
        conn.close()


if __name__ == '__main__':
    raise SystemExit(main())
