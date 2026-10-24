#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 `schema.dart` 重新生成 `schema_snapshot.json`（分发用的离线快照）。

    python tool/gen_schema_snapshot.py            # 生成 / 覆盖
    python tool/gen_schema_snapshot.py --check    # 只校验快照是否过期（CI 可跑）

## 为什么需要它

`schema.dart` 是 schema 的**单一来源**，但测试机通常没有源码，只有随脚本分发的
`schema_snapshot.json`。两者一旦不同步，`seed_test_data.py` / `perf_seed.py`
会在启动时直接拒绝（并由 `tool/README.md` 记为「快照过期」）—— 这是**故意的**：
宁可停下，也不要往结构不对的库里灌数据。

2026-10-24 实例：schema 升到 v4（`documents` 加 `idx_documents_updated`），
快照仍是 v3 ⇒ 两个造数脚本在开发机上也直接报「快照已过期」。所以这个生成器
本身就是发布前的一步：**改 schema ⇒ 重生成快照 ⇒ 两套脚本自检一次**。

## 判据（--check）

    schema.dart 的 version 与 statements 指纹  ==  快照里的 version 与指纹

不一致时退出码 4，并打印「源码 vN / 快照 vM」——与 `seed_test_data.py` 的报错同源。

## 依赖

Python 3.8+，只用标准库；复用 `seed_test_data.py` 的解析器（不另写一份 DDL 解析）。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import seed_test_data as seed
except Exception as exc:  # pragma: no cover
    print("⛔ 找不到 seed_test_data.py：%s" % exc, file=sys.stderr)
    raise SystemExit(3)


def load_source_ddl() -> "tuple[list, int]":
    """从源码解析 DDL。

    ⚠️ 走「临时副本」而不是直接传源码路径：`load_ddl_from_schema_source()` 在
    路径等于默认来源时**会校验现有快照**，快照过期就抛 —— 而本脚本的职责正是
    修好过期快照，所以必须绕过那道校验（副本路径 != 默认来源路径）。
    """
    src = seed.default_schema_source()
    if not os.path.isfile(src):
        raise seed.SchemaSourceError(
            "找不到 %s —— 本脚本要在**开发仓库**里跑（测试机不需要生成快照，只需分发它）。" % src
        )
    tmp = os.path.join(tempfile.gettempdir(), "shensuanzi_schema_for_snapshot.dart")
    shutil.copyfile(src, tmp)
    try:
        return seed.load_ddl_from_schema_source(tmp)
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


def snapshot_state(path: str) -> "tuple[int, str]":
    with open(path, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
    return int(payload["schema_version"]), str(payload["fingerprint"])


def main(argv=None) -> int:
    # 中文 Windows 控制台默认 GBK，打印 ✅/❌ 会 UnicodeEncodeError（真机上踩到过）
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
        except Exception:
            pass
    parser = argparse.ArgumentParser(
        prog="gen_schema_snapshot.py",
        description="从 schema.dart 重新生成分发用的 schema_snapshot.json",
    )
    parser.add_argument("--out", default=None, help="输出路径（默认 tool/schema_snapshot.json）")
    parser.add_argument("--check", action="store_true", help="只校验，不写文件")
    args = parser.parse_args(argv)

    out = args.out or seed.bundled_schema_snapshot()
    try:
        statements, version = load_source_ddl()
    except seed.SchemaSourceError as exc:
        print("⛔ %s" % exc, file=sys.stderr)
        return 3

    fingerprint = seed.ddl_fingerprint(statements)
    label = "源码 v%d / %d 条语句 / 指纹 %s" % (version, len(statements), fingerprint)

    if args.check:
        if not os.path.isfile(out):
            print("❌ 快照不存在：%s（%s）" % (out, label), file=sys.stderr)
            return 4
        snap_version, snap_fingerprint = snapshot_state(out)
        if snap_version != version or snap_fingerprint != fingerprint:
            print(
                "❌ 快照已过期：源码 v%d / 快照 v%d（指纹 %s vs %s）\n"
                "   请运行：python tool/gen_schema_snapshot.py"
                % (version, snap_version, fingerprint, snap_fingerprint),
                file=sys.stderr,
            )
            return 4
        print("✅ 快照与源码一致：%s" % label)
        return 0

    with open(out, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "schema_version": version,
                "statements": statements,
                "fingerprint": fingerprint,
            },
            fh,
            ensure_ascii=False,
            indent=2,
        )
        fh.write("\n")
    print("已写出 %s" % out)
    print("  %s" % label)
    # 立刻用读取路径回读一次 —— 生成器的输出必须能被消费者接受
    reloaded, reloaded_version = seed.load_ddl_from_snapshot(out)
    if reloaded_version != version or seed.ddl_fingerprint(reloaded) != fingerprint:
        print("❌ 回读校验失败（生成的文件不可用）", file=sys.stderr)
        return 5
    print("  回读校验：✅ 指纹一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
