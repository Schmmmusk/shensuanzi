#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把某个数据目录里的**压测数据**挪到一边，让软件下次启动自己建一个空库。

用法（在仓库根执行，或任意目录 —— 脚本自己找仓库）：

    python tool/purge_perf_data.py --dir "C:\\Users\\yzx\\神算子数据"            # 只看，不动
    python tool/purge_perf_data.py --dir "C:\\Users\\yzx\\神算子数据" --confirm  # 真的挪
    python tool/purge_perf_data.py --dir ... --confirm --with-mirror            # 连镜像一起挪

## 为什么是「挪」不是「删」

这是开发/验收用的工具，但**它碰的目录形状跟用户真实数据目录一模一样**。
一次手滑就是别人半年的账。所以：

1. **从不删除**：把 `shensuanzi.db`（含 `-wal` / `-shm`）`os.replace` 进
   `<数据目录>/_压测数据-<时间>/`。想恢复，把文件挪回去即可（脚本会打印命令）。
2. **默认只看不做**（dry run）；要真动必须显式 `--confirm`。
3. **先验证它确实是压测库**：只读打开数一遍 `documents`。少于
   `--min-docs`（默认 50000）就**拒绝**，除非再显式加 `--allow-small`。
   真实的夫妻店单据量很难到 5 万；压测库是 26 万。
4. 只碰这个目录里的库文件，**不递归、不触及其它任何路径**。

## 为什么需要它（2026-11-17）

验收 VM 里那份 500 MB 压测库会一直碍事：概览页数字是假的（应付 2552 万 / 199 家未结）、
启动要读完整个库、自动备份会拷 500 MB。想验「干净首启」就得先把它挪开 ——
但`删除`这个动作不该由脚本来做。
"""

import argparse
import os
import sqlite3
import sys
import time

DB = 'shensuanzi.db'
MIRROR = os.path.join('mirror', 'shensuanzi_mirror.db')
# 库文件周边：WAL 模式下 `-wal` / `-shm` 与主库是一套，必须一起挪，否则下次打开会「库损坏」
SIDECARS = ['-wal', '-shm']


def human(n):
    if n >= 1048576:
        return f'{n / 1048576:.1f} MB'
    if n >= 1024:
        return f'{n / 1024:.0f} KB'
    return f'{n} B'


def probe(db_path):
    """只读打开，返回 (单据数, 版本号)。读不出来抛 RuntimeError。"""
    uri = 'file:' + db_path.replace('\\', '/') + '?mode=ro'
    try:
        con = sqlite3.connect(uri, uri=True, timeout=5)
    except sqlite3.Error as e:
        raise RuntimeError(f'打不开（{e}）') from e
    try:
        docs = con.execute('SELECT COUNT(*) FROM documents').fetchone()[0]
        try:
            ver = con.execute('PRAGMA user_version').fetchone()[0]
        except sqlite3.Error:
            ver = None
        return docs, ver
    except sqlite3.Error as e:
        raise RuntimeError(f'读不出单据数（{e}）') from e
    finally:
        con.close()


def main():
    ap = argparse.ArgumentParser(description='把压测数据挪到一边（不删除）')
    ap.add_argument('--dir', required=True, help='数据目录（里面应有 shensuanzi.db）')
    ap.add_argument('--confirm', action='store_true', help='真的执行（不加就只看）')
    ap.add_argument('--min-docs', type=int, default=50000,
                    help='判定为「压测库」的最少单据数（默认 50000）')
    ap.add_argument('--allow-small', action='store_true',
                    help='单据数不到 --min-docs 也照样挪（**危险**，先想清楚）')
    ap.add_argument('--with-mirror', action='store_true',
                    help='连镜像库 mirror/shensuanzi_mirror.db 一起挪')
    args = ap.parse_args()

    data_dir = os.path.abspath(args.dir)
    db_path = os.path.join(data_dir, DB)
    if not os.path.isdir(data_dir):
        raise SystemExit(f'❌ 目录不存在：{data_dir}')
    if not os.path.isfile(db_path):
        raise SystemExit(
            f'❌ 这个目录里没有 {DB}：{data_dir}\n'
            '   如果软件还没启动过，它会在首次启动时自己建一个空库 —— 不需要本工具。')

    print(f'📁 数据目录：{data_dir}')
    print(f'   库文件　：{DB}　{human(os.path.getsize(db_path))}')

    try:
        docs, ver = probe(db_path)
    except RuntimeError as e:
        raise SystemExit(
            f'❌ 这个库读不出来：{e}\n'
            '   **不处理**（读不出来就更分不清是压测库还是用户的真库）。')

    print(f'   单据数　：{docs:,}　schema 版本：{ver if ver is not None else "?"}')

    if docs < args.min_docs and not args.allow_small:
        raise SystemExit(
            f'\n⛔ 不处理：单据数 {docs:,} < {args.min_docs:,}，**不像压测库**。\n'
            '   这多半是真实数据 —— 挪走它等于让用户「打开软件发现账全没了」。\n'
            '   确认要动（例如你在测小数据量的边界）请加 --allow-small。')

    targets = [db_path] + [db_path + s for s in SIDECARS if os.path.isfile(db_path + s)]
    if args.with_mirror:
        mp = os.path.join(data_dir, MIRROR)
        if os.path.isfile(mp):
            targets.append(mp)
        else:
            print('   （没有镜像库，--with-mirror 忽略）')

    stamp = time.strftime('%Y%m%d-%H%M%S')
    box = os.path.join(data_dir, f'_压测数据-{stamp}')

    print('\n计划（**只挪不删**）：')
    for t in targets:
        print(f'   {os.path.relpath(t, data_dir):<32} → {os.path.basename(box)}/')

    if not args.confirm:
        print('\n（dry run：什么都没动。确认无误后加 --confirm 再跑一次）')
        return 0

    os.makedirs(box, exist_ok=True)
    moved = []
    for src in targets:
        dst = os.path.join(box, os.path.basename(src))
        os.replace(src, dst)          # 同一卷内是原子改名，不复制、不丢数据
        moved.append((src, dst))
        print(f'   ✅ 挪走 {os.path.basename(src)}')

    print(f'\n✅ 完成。压测数据都在：{box}')
    print('   下次启动软件会用同一个数据目录，**自己建一个空库**（新版 schema）。')
    print('   想恢复这批数据（先把软件关掉）：')
    for src, dst in moved:
        print(f'     move "{dst}" "{src}"')
    return 0


if __name__ == '__main__':
    sys.exit(main())
