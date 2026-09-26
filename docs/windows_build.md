# Windows 构建与运行

> 本文只讲**构建这一步**的坑。数据放哪见 [`data_directory.md`](data_directory.md)，
> 测试怎么跑见 [`testing.md` §零](testing.md)。

## 一、症状：应用**一直起不来**，但代码全绿

`flutter run -d windows` / `flutter build windows` 失败。特征很固定：

- 失败发生在 **CMake 配置阶段**（还没轮到 Dart 代码）
- 报错里出现 `sqlite3-populate` / `_deps/sqlite3-subbuild` / `Failed to download`
- 磁盘上留下这样的痕迹：

```text
build/windows/x64/_deps/sqlite3-subbuild/.../src/
  sqlite-autoconf-3520000.tar.gz     ← 0 字节
build/windows/x64/_deps/sqlite3-src/ ← 空目录
```

**这与 Dart 代码无关**：`flutter analyze` 全绿、`flutter test` 全绿，照样起不来。
排查时别在 `lib/` 里找问题。

## 二、根因

`sqlite3_flutter_libs`（给 Windows / Android 提供 SQLite 原生库的插件）
在**配置阶段**用 CMake 的 `FetchContent` 现场下载 SQLite 源码：

```text
https://sqlite.org/2026/sqlite-autoconf-3520000.tar.gz
```

国内直连 `sqlite.org` **主站**会超时或被中途掐断（实测 `curl` 报
`(56) schannel: server closed abruptly`，`https://sqlite.org` 连 25 秒超时），
于是下载到 **0 字节** → 解压失败 → 目录是空的 → 配置失败。
它的镜像站在国内是通的（见下）。

## 三、一次性准备：把源码放到本地，跳过下载

`windows/CMakeLists.txt` 里有一段守卫：只要下面这个目录里同时有
`sqlite3.c` 和 `sqlite3.h`，就用它，**不再联网**；没有就照旧联网下载
（**行为与改动前完全一致**，所以这个守卫本身不会引入新风险）。

```text
third_party/sqlite3/
├── sqlite3.c        ← 必须有（≈ 9.4 MB）
├── sqlite3.h        ← 必须有（≈ 680 KB）
└── sqlite3ext.h
```

### 1. 下载（目标 3,258,980 字节）

主站不通就用它的镜像 —— `www2` / `www3` 是**同一个文件**：

```bash
cd /d/shensuanzi/shensuanzi
curl -L --retry 3 -o third_party/sqlite-autoconf-3520000.tar.gz \
  https://www2.sqlite.org/2026/sqlite-autoconf-3520000.tar.gz
```

下完先看大小：**3,258,980 字节**。差得远（尤其 0 字节）就是没下成，重来。

### 2. 解压（**必须剥掉顶层目录**）

压缩包里的顶层是 `sqlite-autoconf-3520000/`，要剥一层，
让 `sqlite3.c` 直接落在 `third_party/sqlite3/` 下：

```bash
mkdir -p third_party/sqlite3
tar xzf third_party/sqlite-autoconf-3520000.tar.gz \
  -C third_party/sqlite3 --strip-components=1
```

> 守卫其实也认「保留顶层目录」的形状（`third_party/sqlite3/sqlite-autoconf-*/`），
> 但剥掉更清爽，也不会在插件升版后和新目录混在一起。

### 3. 校验

```bash
ls -l third_party/sqlite3/sqlite3.c third_party/sqlite3/sqlite3.h
```

期望两个文件都在、都远大于 0 字节。**一个 0 字节文件就是没下成。**

`third_party/` 已在 `.gitignore` 里 —— 它是**一次性构建前提**，不入库。
想改成「克隆下来就能离线构建」，把 `.gitignore` 里那一行去掉并把目录提交即可
（代价是仓库多 ~12 MB 第三方源码，且 SQLite 升级要跟着提一次）。

## 四、构建

```powershell
cd D:\shensuanzi\shensuanzi
flutter clean
flutter pub get
flutter run -d windows
```

配置阶段应当打印一行确认它用上了本地源码：

```text
[shensuanzi] 使用本地 SQLite 源码：D:/shensuanzi/shensuanzi/third_party/sqlite3
```

- 看到这行 ⇒ 这一轮**不会再下载**，跑到 `build/windows/x64/runner/Debug/shensuanzi.exe` 就算成功
- 看到「未发现本地 SQLite 源码，将联网下载」⇒ §三 的目录形状不对（多半是没剥顶层目录）

## 五、为什么不用别的办法

| 备选 | 不采用的原因 |
|---|---|
| 每次构建挂代理 | 代理是**环境的偶然条件**，换台机器 / 换个人就复现同样的问题；而且实测走代理下这个包也会被中途掐断 |
| 把 tarball 塞进 `build/_deps/...` | 插件的 `FetchContent_Declare` **没配 `URL_HASH`**，CMake 发现本地已存在这个文件会**先删掉再重下** |
| 换成预编译的 `sqlite3.dll` | 要改插件自己的 CMake，且升级 Flutter / 插件时会丢 |
| 直接提交 `sqlite3.c` | 9.4 MB 的第三方 blob；真需要时再改（见 §三 末） |

## 六、升级 SQLite

版本号钉在插件里（当前 `sqlite3_flutter_libs 0.5.42` → `sqlite-autoconf-3520000`）。
插件升版后：按新版本号重新下载、重新解压到**同一个目录**即可，
守卫只看「文件在不在」，不认版本号。
