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

## 运行库随包（N-l 裁定「甲」，2026-11-17）

`msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll` **随包放在 exe 同目录**
（微软文档里的 app-local 装法），三个加起来 0.83 MiB。这样「解压即用」才真的成立：
裸 Windows / LTSC 不必先装 VC++ 运行库，也不需要管理员权限。

- 来源：本机 Visual Studio 的 `VC/Redist/MSVC/<ver>/x64/Microsoft.VC*.CRT/`
  —— 那就是微软为「再分发」准备的目录，**绝不从 `C://Windows//System32` 拷**；
- 找不到、或拿到的不是 x64 ⇒ **直接中止**，不会静默出一个跑不起来的包；
- 许可说明随包（`运行库说明.txt`，模板在 `packaging/`），条款依据见
  `docs/windows_build.md` §8.4.1；
- 代价（写清，别当成推荐）：微软对 app-local 的原话是「For servicing reasons,
  we don't recommend that you use this application-local installation location.」
  —— 运行库有更新时得我们重新发包。对本项目可接受，属已知取舍。
"""

import glob
import hashlib
import os
import re
import subprocess
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

# ---------------------------------------------------------------- VC++ 运行库（随包）
#
# 2026-11-17 用户裁定「甲」：放 exe 同目录，不做「启动前检测 + 自动下载」。
# 只带这三个，因为发布产物里**只有它们被导入**（`dumpbin /dependents` 实测：
# shensuanzi.exe 与 4 个插件要 MSVCP140 / VCRUNTIME140 / VCRUNTIME140_1；
# flutter_windows.dll 自带、不依赖；sqlite3.dll 只要 VCRUNTIME140，已被覆盖）。
CRT_FILES = ['msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll']
CRT_NOTE = os.path.join('packaging', '运行库说明.txt')  # 带 {{CRT_VERSION}} 等占位符的模板
PE_X64 = 0x8664

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


def pe_machine(path):
    """PE 头的 machine 字段（0x8664 = x64）；不是 PE ⇒ None。

    为什么值得查：`VC/Redist/MSVC/<ver>/x64` 与 `<ver>/x86` 里的文件名一模一样。
    拿错架构放进包，exe 照样起不来，而且报错完全不同（「不是有效的 Win32 应用程序」）——
    这种错误在用户的店里排查起来比缺 dll 更贵。
    """
    try:
        with open(path, 'rb') as fh:
            head = fh.read(0x40)
            if len(head) < 0x40 or head[:2] != b'MZ':
                return None
            fh.seek(int.from_bytes(head[0x3C:0x40], 'little'))
            sig = fh.read(6)
            if len(sig) < 6 or sig[:4] != b'PE\x00\x00':
                return None
            return int.from_bytes(sig[4:6], 'little')
    except OSError:
        return None


def _ver_key(name):
    try:
        return tuple(int(x) for x in name.split('.'))
    except ValueError:
        return (-1,)


def _version_of(path):
    """从路径里认出 `14.51.36231` 这种版本段（找不到就 '(unknown)'）。"""
    d = path
    while True:
        name = os.path.basename(d)
        if re.match(r'^\d+(\.\d+)+$', name):
            return name
        parent = os.path.dirname(d)
        if parent == d:
            return '(unknown)'
        d = parent


def crt_roots():
    """可能藏着 `VC/Redist/MSVC` 的地方（按可信度排、去重保序）。

    顺序：`SHENSUANZI_VC_REDIST` 显式指定 → `VCINSTALLDIR` → vswhere
    （VS 自己登记的安装路径，装在 D://// 这种自定义盘符也能找对）→ 两个 Program Files 通配。
    """
    out = []
    env = os.environ.get('SHENSUANZI_VC_REDIST')
    if env:
        out.append(env)
    vc = os.environ.get('VCINSTALLDIR')
    if vc:
        out.append(os.path.join(vc, 'Redist', 'MSVC'))
    pf86 = os.environ.get('ProgramFiles(x86)', r'C://Program Files (x86)')
    vswhere = os.path.join(pf86, 'Microsoft Visual Studio', 'Installer', 'vswhere.exe')
    if os.path.isfile(vswhere):
        try:
            res = subprocess.run(
                [vswhere, '-latest', '-products', '*', '-property',
                 'installationPath'],
                capture_output=True, text=True, timeout=20)
            for line in res.stdout.splitlines():
                p = line.strip()
                if p:
                    out.append(os.path.join(p, 'VC', 'Redist', 'MSVC'))
        except (OSError, subprocess.SubprocessError):
            pass  # 拿不到就靠下面的通配兜底
    for pf in (os.environ.get('ProgramFiles', r'C://Program Files'), pf86):
        out.extend(glob.glob(os.path.join(
            pf, 'Microsoft Visual Studio', '*', 'VC', 'Redist', 'MSVC')))
    seen, uniq = set(), []
    for p in out:
        key = os.path.normcase(os.path.normpath(p))
        if key not in seen:
            seen.add(key)
            uniq.append(p)
    return uniq


def find_crt():
    """定位 x64 的 `Microsoft.VC*.CRT` 目录 ⇒ (目录, 版本串)。

    **找不到就中止**：N-l 裁的「运行库随包」，静默出一个缺 dll 的包，
    等于把「双击起不来」那个 bug 又发一遍。
    """
    env = os.environ.get('SHENSUANZI_VC_REDIST')
    if env and all(os.path.isfile(os.path.join(env, f)) for f in CRT_FILES):
        d = os.path.abspath(env)
        return d, _version_of(d)

    tried = []
    for root in crt_roots():
        if not os.path.isdir(root):
            continue
        tried.append(root)
        # 根可能已指到 <ver> 或 <ver>/x64（环境变量写法各异），三种层级都试
        levels = [root] + [
            os.path.join(root, v)
            for v in sorted(os.listdir(root), key=_ver_key, reverse=True)
            if os.path.isdir(os.path.join(root, v))
        ]
        for base in levels:
            x64 = os.path.join(base, 'x64')
            if not os.path.isdir(x64):
                continue
            for folder in sorted(os.listdir(x64)):
                d = os.path.join(x64, folder)
                if not (folder.startswith('Microsoft.VC') and
                        folder.endswith('.CRT')):
                    continue
                if all(os.path.isfile(os.path.join(d, f)) for f in CRT_FILES):
                    return d, _version_of(d)
    raise SystemExit(
        '❌ 找不到 VC++ x64 运行库（' + ' / '.join(CRT_FILES) + '）。\n'
        '   N-l 的裁定是「运行库随包」—— 找不到就不出包，\n'
        '   免得发出去的软件在没装运行库的机器上打不开。\n'
        '   装好「Visual Studio 生成工具 + 桌面 C++ 生成工具」，或设环境变量\n'
        '   SHENSUANZI_VC_REDIST 指向 ...\\VC\\Redist\\MSVC\\<ver>\\x64\\Microsoft.VC143.CRT。\n'
        '   找过：' + ('、'.join(tried) if tried else '（没有任何候选根）'))


def crt_note_text(crt_dir, crt_ver):
    """把 `运行库说明.txt` 模板填成随包的那一页（版本/来源写实，避免手抄漂移）。"""
    path = os.path.join(REPO, CRT_NOTE)
    if not os.path.isfile(path):
        raise SystemExit(f'❌ 运行库说明模板缺失：{CRT_NOTE}')
    with open(path, encoding='utf-8-sig') as fh:
        text = fh.read().replace('\r\n', '\n')
    return (text
            .replace('{{FILES}}', '、'.join(CRT_FILES))
            .replace('{{CRT_VERSION}}', crt_ver)
            .replace('{{CRT_DIR}}', crt_dir.replace(os.sep, '/')))


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

    # ---------------------------------------------------------------- 2b 运行库
    # N-l 裁定「随包」：找不到 / 架构不对就中止，**绝不静默出一个缺 dll 的包**。
    crt_dir, crt_ver = find_crt()
    for name in CRT_FILES:
        m = pe_machine(os.path.join(crt_dir, name))
        if m is None:
            raise SystemExit(f'❌ {name} 不是有效的 PE 文件：{crt_dir}')
        if m != PE_X64:
            raise SystemExit(
                f'❌ {name} 的 machine=0x{m:X}，不是 x64（0x{PE_X64:X}）：{crt_dir}\n'
                '   多半是拿到了 x86 目录 —— 用户那边会报「不是有效的 Win32 应用程序」。')
    print(f'🔧 VC++ 运行库：{crt_ver}（{crt_dir}）')
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
    # 运行库放**包根**（= exe 同目录）：app-local 只认 exe 所在目录，放子目录等于没放
    for name in CRT_FILES:
        entries.append((os.path.join(crt_dir, name), name))
    entries.sort(key=lambda e: e[1])
    # 许可/来源说明：模板填实后**直接写进 zip**（不落盘 —— 本脚本不留中间文件）
    note_arc = '运行库说明.txt'
    note_text = crt_note_text(crt_dir, crt_ver)
    note_size = len(note_text.encode('utf-8'))

    print(f'📁 {top}/')
    for src, arc in entries:
        pad = '   ' * arc.count('/')
        print(f'   {pad}{arc.split("/")[-1]:<40} {human(os.path.getsize(src)):>9}')

    pad = '   '
    print(f'   {note_arc:<40} {human(note_size):>9}  （随包生成）')

    total = sum(os.path.getsize(src) for src, _ in entries) + note_size
    print(f'\n   未压缩合计 {human(total)}（{len(entries) + 1} 个文件）')

    # ---------------------------------------------------------------- 4 压缩
    os.makedirs(DIST, exist_ok=True)
    zip_path = os.path.join(DIST, f'{top}-win64.zip')
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for src, arc in entries:
            z.write(src, f'{top}/{arc}')
        z.writestr(f'{top}/{note_arc}', note_text)

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
    # N-l（2026-11-17 裁定甲）：运行库已随包，用户**不需要**再装任何东西。
    # 每次打包都把「带了哪一版」打出来 —— 将来排查 dll 版本时这是第一手信息。
    print(f'   ✅ 已随包带 VC++ 运行库 {crt_ver}（{len(CRT_FILES)} 个 dll，放 exe 同目录）'
          ' —— 裸 Windows 上不需要另装；')
    print('      随包依据与代价见 docs/windows_build.md §8.4.1。')


if __name__ == '__main__':
    main()
