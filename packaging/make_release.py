#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""打包 Windows 发布版（§AG-2 裁定：便携 zip 优先）。

用法（任意目录都可，脚本自己定位仓库根）：

    python packaging/make_release.py             # 产物比源码旧就中止
    python packaging/make_release.py --force     # 跳过新鲜度检查

产物：

    build/dist/神算子-v0.1.0-win64.zip           ← 发给用户的那个
    build/dist/神算子-v0.1.0-win64.zip.sha256    ← 校验用

⚠️ **本脚本不删除任何文件**（重跑会直接覆盖同名 zip；`zipfile` 的 `'w'` 模式会截断）。
   想改包内容就改源码或 `EXTRA` 清单，别指望它替你清理旧目录。

## 为什么要有这个脚本（而不是手敲命令）

1. **防「打包了旧产物」** —— 先比对**产物基准**与**全部构建输入**的时间戳
   （`lib/` `packages/` `windows/runner/` `pubspec.yaml` `pubspec.lock`），有更新的就停下。
   这是发布流程里最贵的错误：发了旧代码，而且从外表完全看不出来。
   ⚠️ 产物基准是 **max(`shensuanzi.exe`, `data/app.so`) 的 mtime**，不是只有 exe：
   Flutter Windows 把全部 Dart 代码编进 `data\app.so`，**只改 Dart 时 exe 根本不重链**
   （2026-09-29 实测：exe 16:02 vs app.so 21:13）—— 只拿 exe 当基准会把
   「刚构建完的新产物」误报成「产物是旧的」。
2. **随包文件不能漏** —— AGPL-3.0 要求分发时**随附许可全文** ⇒ `LICENSE` 必须进包；
   `THIRD_PARTY.md`（第三方组件与字体）与 `使用说明.txt`（用户第一份文档）同理。
   三份缺任一份都会直接中止，不会静默少给。
3. **版本号只有一个来源** —— 从 `pubspec.yaml` 取（`0.1.0+1` → `0.1.0`），
   并**校验 `使用说明.txt` 里印的版本与它一致**。版本号一旦有两处就会漂，
   `test/version_test.dart` 钉的是 Dart 侧那一半，这里钉文档侧那一半。

## 为什么默认是 zip（而不是安装包）

见 §AG-2：解压即用、不需要管理员权限、符合「数据可携带性原则」。
安装包（Inno / MSI）与代码签名都排在首发之后。
"""

import hashlib
import os
import re
import sys
import time
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASE = os.path.join(REPO, 'build', 'windows', 'x64', 'runner', 'Release')
EXE = os.path.join(RELEASE, 'shensuanzi.exe')
# Dart 代码的真正载体（见文件头「防打包旧产物」说明）
APP_SO = os.path.join(RELEASE, 'data', 'app.so')
DIST = os.path.join(REPO, 'build', 'dist')

# 随包文件：(仓库内路径, 包内文件名)。**必须都进包**，缺一即中止。
EXTRA = [
    (os.path.join('packaging', '使用说明.txt'), '使用说明.txt'),
    (os.path.join('packaging', '用户手册.html'), '用户手册.html'),
    ('LICENSE', 'LICENSE'),
    ('THIRD_PARTY.md', 'THIRD_PARTY.md'),
]

# 构建输入：任一比产物基准新 ⇒ 产物是旧的（说明改了代码没重新构建）
INPUT_FILES = ['pubspec.yaml', 'pubspec.lock']
INPUT_DIRS = ['lib', 'packages', os.path.join('windows', 'runner')]
INPUT_EXT = ('.dart', '.yaml', '.rc', '.ico')
# 这些目录不是「我写的输入」：`.dart_tool` 是构建缓存，
# `windows/flutter` 是 flutter 自己生成的（时间戳随构建变，会满屏假报警）
SKIP_DIRS = {'.dart_tool', 'build', '.git', 'flutter'}


def read_version():
    """从 pubspec.yaml 取版本号（去掉 `+构建号`）。"""
    with open(os.path.join(REPO, 'pubspec.yaml'), encoding='utf-8') as fh:
        for line in fh:
            m = re.match(r'^version:\s*(\S+)\s*$', line)
            if m:
                return m.group(1).split('+')[0]
    raise SystemExit('❌ pubspec.yaml 里找不到 version:')


def inputs_newer_than(ts):
    """比 `ts` 新的构建输入（按时间倒序）。"""
    out = []

    def consider(path):
        if os.path.getmtime(path) > ts:
            out.append(path)

    for rel in INPUT_FILES:
        p = os.path.join(REPO, rel)
        if os.path.isfile(p):
            consider(p)
    for rel in INPUT_DIRS:
        for root, dirs, files in os.walk(os.path.join(REPO, rel)):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in files:
                if name.endswith(INPUT_EXT):
                    consider(os.path.join(root, name))
    return sorted(out, key=os.path.getmtime, reverse=True)


def human(n):
    if n >= 1048576:
        return f'{n / 1048576:.1f} MB'
    if n >= 1024:
        return f'{n / 1024:.0f} KB'
    return f'{n} B'


def stamp(p):
    return time.strftime('%m-%d %H:%M:%S', time.localtime(os.path.getmtime(p)))


def artifact_baseline():
    """产物新鲜度基准 = max(exe, data/app.so) 的 mtime。

    只改 Dart 时 app.so 更新而 exe 不重链 —— 只看 exe 会把新产物误判成旧的。
    app.so 缺失（从未构建成功过）时退回 exe，让「找不到产物」的错误先说话。
    """
    ts = os.path.getmtime(EXE)
    if os.path.isfile(APP_SO):
        ts = max(ts, os.path.getmtime(APP_SO))
    return ts


def main():
    force = '--force' in sys.argv

    if not os.path.isfile(EXE):
        raise SystemExit(
            f'❌ 找不到产物：{EXE}\n'
            '   先在仓库根执行：flutter build windows --release'
        )

    version = read_version()
    top = f'神算子-v{version}'

    # ---------------------------------------------------------------- 1 新鲜度
    stale = inputs_newer_than(artifact_baseline())
    if stale:
        print(f'{"⚠️  " if force else "❌ "}产物是旧的 —— 下面这些文件比产物（exe / app.so）新：')
        for p in stale[:8]:
            print(f'     {stamp(p)}  {os.path.relpath(p, REPO).replace(os.sep, "/")}')
        if len(stale) > 8:
            print(f'     …还有 {len(stale) - 8} 个')
        print()
        if not force:
            print('   先在仓库根重新构建：flutter build windows --release')
            print('   （若确认这些改动不影响产物，加 --force 跳过本检查）')
            raise SystemExit(1)
        print('   --force：忽略并继续（请确认过这些改动确实不影响产物）')
        print()

    # ---------------------------------------------------------------- 2 随包文件
    for rel, _ in EXTRA:
        if not os.path.isfile(os.path.join(REPO, rel)):
            raise SystemExit(f'❌ 随包文件缺失：{rel}')
    # 版本号不能有两处（文档侧）
    with open(os.path.join(REPO, EXTRA[0][0]), encoding='utf-8-sig') as fh:
        manual = fh.read()
    m = re.search(r'v(\d+\.\d+\.\d+)', manual)
    if m and m.group(1) != version:
        raise SystemExit(
            f'❌ 版本号不一致：pubspec.yaml = {version}，'
            f'使用说明.txt = v{m.group(1)}'
        )
    # 手册 HTML 同理：改了版本忘重新生成手册，在这里拦下
    manual_html = os.path.join(REPO, 'packaging', '用户手册.html')
    if not os.path.isfile(manual_html):
        raise SystemExit(
            '❌ packaging/用户手册.html 缺失 —— '
            'cd packages/shensuanzi_app && dart run tool/make_manual_html.dart'
        )
    with open(manual_html, encoding='utf-8') as fh:
        html = fh.read()
    if f'v{version}' not in html:
        raise SystemExit(
            f'❌ 用户手册.html 的版本戳不是 v{version} —— 重新生成：'
            'cd packages/shensuanzi_app && dart run tool/make_manual_html.dart'
        )

    # ---------------------------------------------------------------- 3 清单
    # ⚠️ **不建暂存目录、不删任何东西**（打包只需要「源文件 → 包内路径」两张表）：
    #  - 旧写法先 `rmtree` 再 `copytree`，等于把「重跑一次」变成一次批量删除操作 ——
    #    危险且没必要。`zipfile` 以 `'w'` 打开会自动覆盖同名 zip。
    #  - 想要「解压后的目录形状」的，用 `--folder`（已存在就停，由人来决定删不删）。
    entries = []  # (源文件绝对路径, 包内相对路径)
    for root, dirs, files in os.walk(RELEASE):
        dirs.sort()
        for name in sorted(files):
            p = os.path.join(root, name)
            entries.append((p, os.path.relpath(p, RELEASE).replace(os.sep, '/')))
    for rel, name in EXTRA:
        entries.append((os.path.join(REPO, rel), name))
    entries.sort(key=lambda e: e[1])

    print(f'📁 {top}/')
    for src, arc in entries:
        pad = '   ' * arc.count('/')
        print(f'   {pad}{arc.split("/")[-1]:<40} {human(os.path.getsize(src)):>9}')

    total = sum(os.path.getsize(src) for src, _ in entries)
    print(f'\n   未压缩合计 {human(total)}（{len(entries)} 个文件）')

    # ---------------------------------------------------------------- 4 压缩
    os.makedirs(DIST, exist_ok=True)
    zip_path = os.path.join(DIST, f'{top}-win64.zip')
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for src, arc in entries:
            z.write(src, f'{top}/{arc}')

    zipped = os.path.getsize(zip_path)
    digest = hashlib.sha256()
    with open(zip_path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            digest.update(chunk)
    sha = digest.hexdigest()
    # ⚠️ 文件名含中文 ⇒ 不能用 ascii 写（sha256sum 等工具按 UTF-8 读）
    with open(zip_path + '.sha256', 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(f'{sha}  {os.path.basename(zip_path)}\n')

    print(f'\n✅ {zip_path}')
    print(f'   压缩后 {human(zipped)}（{zipped / total:.0%}）')
    print(f'   sha256 {sha}')
    print()
    print('   发给用户前，按 docs/windows_build.md §8.4 的 15 步清单在干净环境验一遍。')


if __name__ == '__main__':
    main()
