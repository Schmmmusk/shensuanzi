# Windows 构建与运行

> 本文只讲**构建这一步**的坑。数据放哪见 [`data_directory.md`](data_directory.md)，
> 测试怎么跑见 [`testing.md` §零](testing.md)。

## 零、换台机器：环境准备清单（2026-09-30）

克隆到**另一台电脑**后、`flutter build windows` 之前，需要下面这些。
**只有第 1 项是「本来就知道的」** —— 其余按顺序补齐，其中**第 4 项是本项目最特有的坑**。

| # | 准备项 | 为什么需要 | 怎么确认 |
|---|---|---|---|
| 1 | **Flutter SDK**（**Dart ≥ 3.11**，对应 Flutter **≥ 3.41**） | 构建 Flutter 应用 | `flutter --version`；`pubspec.yaml` 钉的是 `sdk: ^3.11.0` |
| 2 | **Visual Studio 2022 +「使用 C++ 的桌面开发」工作负载** | Flutter **Windows 桌面**的**硬性依赖**（CMake + MSVC + Windows SDK 都在这个工作负载里）。没有它 `flutter build windows` **一步都跑不起来**，且报错发生在 CMake 阶段、与 Dart 代码无关 | `flutter doctor` 里 `Visual Studio - develop Windows apps` 是 ✅ |
| 3 | **Git** | 克隆与版本管理 | `git --version` |
| 4 | ⚠️ **SQLite 源码预置** `third_party/sqlite3/` | **本项目最特有的坑**：`.gitignore` 排除了 `third_party/` ⇒ **克隆下来没有它** ⇒ 首次构建在 CMake 配置阶段联网下载 `sqlite.org` 的 tarball（国内主站超时 ⇒ 0 字节 ⇒ 配置失败） | 按本文 **§三** 预置（镜像站 + 剥顶层目录）；构建时打印 `[shensuanzi] 使用本地 SQLite 源码` 即成功 |
| 5 | **Python 3**（**仅打包时需要**） | `packaging/make_release.py` 只用标准库；`packaging/make_icon.py` 需要 `Pillow`（**只在要改图标时**） | `python --version`；改图标才 `pip install pillow` |
| 6 | **纯 Dart 测试的原生库**（三个包的 `dart test`） | 纯 Dart 环境**不含** SQLite 原生库，测试时要能加载 | 查找顺序 `SQLITE3_DLL` → `sqlite3.dll` → `C:\Windows\System32\winsqlite3.dll`。**Win10/11 多数靠最后一项兜底即可通过**；真失败再设 `SQLITE3_DLL` |
| 7 | 网络：`flutter pub get` 要通 pub 源 | 拉依赖 + Flutter 首次物料下载 | 国内可设 `PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL` 镜像。⚠️ **两台机器必须设成同一个值** —— 否则 `pubspec.lock` 会整片抖红，见下方 ⚠️ |

**不需要准备的**（省得白装）：

| 项 | 为什么不用 |
|---|---|
| 单独装 Dart SDK | Flutter SDK **自带** Dart |
| 装 SQLite 本体 | 生产由 `sqlite3_flutter_libs` 提供；构建期用 §三 的源码现场编译 |
| Android SDK / JDK | Android 端**尚未开工**（批次 3）；现在做 Windows 不需要 |
| Node.js | 项目里没有任何 JS 构建步骤 |
| VS Code / Android Studio | 命令行即可（`flutter` / `dart` / `python`）；用不用编辑器随你 |

**两台机器之间的一致性**：构建与打包所需的**一切**都已入库 ——
`pubspec.lock`（根 + 三个包共 4 份）、`packaging/用户手册.html`、`packaging/使用说明.txt`、
`test/fixtures/v1_empty.db`（迁移化石）⇒ 克隆后 `flutter pub get` 会装到**同一批依赖版本**，
不需要手动对齐。**唯二例外**已在上面点明：`third_party/sqlite3/`（第 4 项，必须手工预置）
与 `build/`（产物，按需重新构建）。

> ⚠️ **`pubspec.lock` 里的 `url:` 会跟着 `PUB_HOSTED_URL` 变**（`docs/reply_review.md` §AS / §BB·七）。
>
> 入库的这几份 `pubspec.lock` 是在**镜像**（`pub.flutter-io.cn`）下生成的。
> 在一台**没设镜像**的机器上跑一次 `flutter pub get`，它会把里面**所有** `url:`
> 改写成 `https://pub.dev` —— 版本一个没变、锁文件却整片翻红
> （2026-10-03 实测：**44 行**被改写，看着像依赖大升级，其实什么都没发生）。
>
> **后果不是坏掉，是噪声**：每次换机器都抖一遍，久了就没人认真看 lock 的 diff，
> 真正的依赖变更反而藏起来了。
>
> **做法**：两台机器都把 `PUB_HOSTED_URL` 设成同一个值（或者都不设），再跑 `pub get`。
> 想按已入库的镜像口径改回来：
>
> ```powershell
> $env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
> flutter pub get
> ```
>
> 想改用 `pub.dev` 也行 —— 那就**单独一个提交**把 5 份 `pubspec.lock`（根 + 三个包 + 将来更多）
> 一起重新生成，别让它混在功能提交里。

> ⚠️ **若这台机器设了代理**：Windows 的环境块允许 `HTTP_PROXY` 与 `http_proxy`
> **同时存在**，而 MSBuild 的 CL.exe 任务用的是**大小写不敏感**的字典 ⇒ 抛
> `MSB6001 … 已添加项。字典中的关键字:"HTTP_PROXY"`，**C/C++ 直接编不了**
> （表现成「找不到编译器」，很容易误判成没装 Visual Studio）。
> 规避：构建前清掉**小写**那一组 ——
> Git Bash：`env -u http_proxy -u https_proxy flutter build windows`。

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

## 七、中文注释与 C4819（改过 `windows/` 下的 C++ 才会遇到）

**症状**：`flutter run` 报

```text
windows\runner\main.cpp(1,1): error C2220: 以下警告被视为错误
windows\runner\main.cpp(1,1): warning C4819: 该文件包含不能在当前代码页(936)中表示的字符
```

**根因**：本项目源码一律 UTF-8（无 BOM），而这个 `.cpp` 里有**中文注释**。
MSVC 默认按**系统代码页**（简体中文机器 = 936 / GBK）解码源文件 ——
UTF-8 的中文在 936 下是非法字节序列 ⇒ 报 C4819；
而 `apply_standard_settings` 里带着 `/WX`（警告即错误）⇒ C4819 变成 C2220 ⇒ **直接编译失败**。

> ⚠️ **只修一半的坑**：把窗口标题写成 `L"\u795e\u7b97\u5b50"` 只解决了
> **字符串字面量**；**注释里的中文照样触发 C4819** —— 2026-09-26 就是这么翻的车。

**处置**：`windows/runner/CMakeLists.txt` 给应用目标加 `/utf-8`：

```cmake
target_compile_options(${BINARY_NAME} PRIVATE "$<$<COMPILE_LANGUAGE:C,CXX>:/utf-8>")
```

`/utf-8` = `/source-charset:utf-8` + `/execution-charset:utf-8`，明确告诉编译器
「源文件是 UTF-8」。

**`$<COMPILE_LANGUAGE:C,CXX>` 不能省** —— 否则这个选项会被一起传给资源编译器
`rc.exe`，而它不认 `/utf-8`。

| 做法 | 结论 |
|---|---|
| **给应用目标加 `/utf-8`** | ✅ 采纳：注释仍可写中文，与仓库其它文件一致 |
| 只把字符串转义成 `\uXXXX` | ❌ 只解决字面量，注释照样报错 |
| 源文件存成 UTF-8 **带 BOM** | 🔸 也能用（MSVC 认 BOM），但给文件加了隐形字节 |
| 中文注释全改英文 | 🔸 可行，但把仓库唯一的语言规范破了 |

**排查手法**：扫一遍 `windows/` 下有没有**非 ASCII** 的源文件 ——
只有「既含非 ASCII、又会被 `cl.exe` 编译」的文件才会报。
注意 `windows/CMakeLists.txt` 里的中文注释**没问题**（CMake 自己按 UTF-8 读脚本），
别照着它一起改。

### 7.1 `Runner.rc` 保持**纯 ASCII**（2026-09-29 裁定：不是做不到中文，是**代价远超收益**）

**先把事实说准**（本节早先版本有一处不精确，已按裁定纠正）：

> ⚠️ `rc.exe` **是支持 `/utf-8` 的** —— MSVC 2019（16.x）起就有，
> 前提是 Windows SDK **10.0.17763 或更新**。「rc.exe 不认 `/utf-8`」是误传。
>
> 仍然成立的是：Flutter 生成的 CMake 里 `/utf-8` 写成
> `$<$<COMPILE_LANGUAGE:C,CXX>:/utf-8>` —— **语言限定**让它只作用于 C/C++，
> **不会传给资源编译器**。于是现状下 `runner/Runner.rc` 由 `rc.exe`
> **按系统代码页解码**（简体中文机器 = GBK），UTF-8 中文注释**会变乱码**。

**裁定**：`Runner.rc` 保持纯 ASCII（要写说明就写英文，或写进本文件）。
这条由 `test/version_test.dart` 的断言守着（扫该文件的非 ASCII 字节）。

**为什么不是「加 `/utf-8`」或「改 UTF-16」** —— 三条路摆在一起看：

| 方案 | 技术上可行？ | 真实代价 |
|---|---|---|
| A 保持英文 | ✅ | 零成本（属性页与裁定原文有差异） |
| B 整文件 UTF-16 LE with BOM | ✅ | 仓库里**唯一的异类文件**；将来第一个编辑它的合作者会困惑 |
| C 给 rc.exe 传 `/utf-8` | ⚠️ **看工具链** | ① **所有构建者**的 SDK 必须 ≥ 10.0.17763 —— 一个人能建、另一个人建不了，是最难查的那种 bug；② 要在 Flutter 生成的 CMake 配置里找到 rc.exe 的参数入口，不是「改一行」 |

**判断原则**：**构建输入的编码一致性 > 一个几乎没人看的属性页。**

- `Runner.rc` 是仓库里唯一的构建资源文件 —— 它变 UTF-16 就是「唯一需要单独理由的文件」，
  例外会扩散（下一个是 `app.manifest`？），且**单向、难回收**。
- 用户感知路径 **100% 是中文**：窗口标题（`main.cpp` 里 `\u` 转义的「神算子」）、
  任务栏 / Alt+Tab（走窗口标题）、开始菜单（exe 文件名 + 图标）、帮助页（中文）。
  属性页是唯一例外 —— 而它恰好是用户几乎不打开的地方。

**英文属性串的写法（2026-09-29 裁定）**：
`FileDescription` = `Shensuanzi - Inventory & Bookkeeping`（`&` 代替 `and` 更紧凑 ——
属性对话框那一栏约 40 字符；**首字母大写**是 Windows 资源字符串的惯例）。
由 `test/version_test.dart` 钉住。

**⚠️ `shensuanzi.exe` 的文件名也保持英文 —— 与上面是同一条原则的两个落点**，不是独立决定：

| 若改成「神算子.exe」 | 后果 |
|---|---|
| zip 解压 | zip 的 UTF-8 标志位不被所有解压器尊重，**Windows 自带解压器可能按 GBK 解出乱码文件名** |
| 命令行 / `.bat` / 脚本 | 中文路径需要代码页配合，脚本场景易碎 |
| 开始菜单 / 任务管理器 | 显示的是 exe 文件名 —— `shensuanzi` 配上图标反而**稳**，不像半成品 |

**留个口子（记下来但不做）**：将来若做 **MSIX 安装包**，文件属性走 `appxmanifest`
（那是 UTF-8 的 XML），中文属性**会自然出现**，且 MSIX 属性页**覆盖** exe 属性页 ——
与现在的英文 `Runner.rc` 属性**不冲突**，无需回改。

## 八、发布与打包

> 目标：把 `flutter build windows --release` 的产物变成**用户能双击运行**的一包东西。
> 当前分发形式是**便携 zip**（解压即用、不需要管理员权限、不写 `Program Files`）。

### 8.1 产物长什么样（实测，2026-09-29）

`build/windows/x64/runner/Release/` 共 **16 个文件 / 30.4 MB**：

| 文件 | 大小 | 说明 |
|---|---|---|
| `shensuanzi.exe` | **409 KB** | 启动器。**其中 361 KB 是应用图标**（内嵌 ICO，见 `packaging/make_icon.py`） |
| `flutter_windows.dll` | 20.8 MB | Flutter 引擎（**体积主要在这里**） |
| `data/app.so` | 6.2 MB | 应用的 AOT 快照（Dart 代码编译结果） |
| `data/icudtl.dat` | 842 KB | 国际化数据 |
| `data/flutter_assets/` | ~2.1 MB | 字体（Material / Cupertino 图标）、着色器、`NOTICES.Z` |
| `sqlite3.dll` | 1.4 MB | SQLite 引擎 |
| `sqlite3_flutter_libs_plugin.dll` | 9.7 KB | 插件外壳 |
| `file_selector_windows_plugin.dll` | 108 KB | 「选择文件夹」对话框 |
| `native_assets.json` | 45 B | 原生资源清单 |

打包后共 **19 个条目**（上面的 16 个 + `使用说明.txt` / `LICENSE` / `THIRD_PARTY.md`），
未压缩 **30.8 MB** → 压缩后 **12.8 MB**（deflate）—— 这就是用户下载的大小。

### 8.2 打包步骤

**两条命令**（在仓库根）：

```bat
cd /d D:\shensuanzi\shensuanzi
flutter build windows --release
python packaging\make_release.py
```

> ⚠️ **报 `LNK1104: 无法打开文件 ...shensuanzi.exe` = 旧 exe 被占用**，不是构建坏了：
> ① 软件本体还开着（先退出神算子）；② **「文件属性」对话框开着也会锁** ——
> 资源管理器在属性页打开期间持有文件句柄（2026-09-29 真实踩过：
> 核对新 FileDescription 后忘了关属性框，下一次构建直接挂）。
> 关掉再重跑即可，无需清理任何目录。

`packaging/make_release.py` 做四件事（**每一条都对应一次真实踩坑**）：

1. **拦「拿旧产物打包」** —— 比对 `Release/shensuanzi.exe` 与全部构建输入
   （`lib/` `packages/` `windows/runner/` `pubspec.yaml` `pubspec.lock`）的时间戳，
   有比 exe 新的就**直接停**并列出是哪几个文件。
   > 这是发布流程里最贵的错误：发了旧代码，从外表完全看不出来，用户报问题也查不出原因。
   > 确认那些改动不影响产物时才用 `--force` 跳过。
2. **拦「随包文件漏了」** —— `EXTRA` 清单里任一文件缺失即中止（`LICENSE` 漏了就是违反自己的许可）。
3. **拦「版本号有两处」** —— 从 `pubspec.yaml` 取版本（`0.1.0+1` → `0.1.0`），
   与 `packaging/使用说明.txt` 里印的版本比对。`test/version_test.dart` 钉的是 Dart 侧那一半，
   这里钉文档侧那一半。
4. 压成 zip + 写 `.sha256`。

产物：

```
build/dist/神算子-v0.1.0-win64.zip
build/dist/神算子-v0.1.0-win64.zip.sha256
```

> ⚠️ **这个脚本不删除任何文件**。重跑会直接覆盖同名 zip（`zipfile` 的 `'w'` 模式），
> 不需要先清理什么 —— 以前那版先 `rmtree` 再 `copytree` 的写法是没必要的危险动作。
> 中文目录名在 zip 里带 **UTF-8 标志位**（打包时已断言），Windows 资源管理器解压不会乱码。

### 8.3 随包必须带的文件（少了要回来补）

| 文件 | 为什么必须带 |
|---|---|
| `LICENSE` | **AGPL-3.0 的分发要求** —— 不给许可文本属于违反自己的许可 |
| `THIRD_PARTY.md` | 第三方组件与字体的声明（含「**未内嵌中文字体**」这一条，见文件内说明） |
| `使用说明.txt` | 目标用户不会打开 `.md` 文件 —— 必须是 `.txt`，且**UTF-8 带 BOM** |
| `用户手册.html` | 完整用户手册（**自包含网页**，双击浏览器打开、可打印）。内容与软件内「帮助 → 查看完整手册」**同源**（都出自 `manual_content.dart`）；**改了手册内容或版本号后要重新生成**：`cd packages/shensuanzi_app && dart run tool/make_manual_html.dart`。`make_release.py` 会校验它的版本戳 |

> **`README.md` 刻意不进包**（与本节早先版本不同）：它是**面向仓库**的 ——
> 顶部就有「怎么构建 / 换台机器克隆下来构建不了」，用户解压后读到会以为要装开发环境。
> 用户那份文档是 `使用说明.txt`，一页讲完「怎么开始 / 蓝屏提示 / 怎么删」。

> ⚠️ `packaging\使用说明.txt` 是**版本化文件**（在仓库里），不是每次现写的 ——
> 改文案要改仓库里那份，否则发的包和仓库对不上。
> 它存成 **UTF-8 with BOM + CRLF**：老版本记事本与第三方编辑器都能正确识别。
> 上面三项由 `make_release.py` 的 `EXTRA` 清单强制校验，漏一个就打不出包。

### 8.4 首发验证清单（**必须在干净环境走一遍**）

用一台**没装过 Flutter 的电脑**（或新建一个 Windows 虚拟机 / 沙箱账户）：

| # | 步骤 | 预期 |
|---|---|---|
| 1 | 解压 zip 到 `D:\神算子\` | 目录里有 `shensuanzi.exe` 与 `data\` |
| 2 | 双击 `shensuanzi.exe` | 出现蓝色 SmartScreen 提示（**未签名，预期行为**） |
| 3 | 「更多信息」→「仍要运行」 | 数据目录对话框**出现在最前面**（⚠️ 见下） |
| 4 | 对话框顶部 | 有「欢迎使用神算子 / 这是第一次启动 …… 不会上传」 |
| 5 | 选 `D:\神算子数据\` → 「开始使用」 | 进入主界面；`D:\神算子数据\` 里出现数据库与标记文件 |
| 6 | 文件属性 | **文件版本 `0.1.0.1`**、**产品版本 `0.1.0`**、产品名 `Shensuanzi`、版权 `Shensuanzi contributors` |
| 7 | 任务栏 / Alt+Tab 图标 | **是神算子自己的图标**，不是 Flutter 默认蓝标 |
| 8 | 建商品 → 采购 → 销售 → 看库存 | 数字正确（采购 10 件、卖 2 件 → 剩 8 件） |
| 9 | 单据页 → 导出 | 弹出「已导出 N 条到 …」；CSV 用 Excel 打开中文正常 |
| 10 | 设置页 → 立即备份 | 提示带完整路径；`D:\神算子备份\` 里出现一个 `.db` |
| 11 | 关掉软件，重新打开 | **不再弹数据目录对话框**，直接进主界面，数据还在 |
| 12 | 看 `%APPDATA%\神算子\日志\神算子-日志.txt` | 有启动行（版本 / schema / 系统） |
| 13 | 文件菜单「删除」流程 | 按 README「怎么删除」能干净删掉（程序 + 数据） |
| 14 | 双击 `用户手册.html` | 浏览器打开：目录可点、15 章齐全、底部版本号与软件一致 |
| 15 | **从老版本数据升级**（先拿**上一个版本**的 zip 走完 1–5 步生成一份旧数据，再用当前版本覆盖 `exe` + `data\` 后打开） | 能正常打开、数据都在；数据目录里**多出 `shensuanzi.db.before-v{N}`**（升级前自动备份，N = 旧库版本）；`%APPDATA%\神算子\日志` 里有一条「版本号不一致…刷新标记文件」；再次打开**不再**出现该日志 |

> ⚠️ **第 3 步是唯一有风险的项**：SmartScreen 关掉后主窗口是否在前台、
> 对话框是否被挡住，**只有真机能回答**。如果被挡住，下一步是引入窗口置前能力
> （`window_manager`，会成为本项目第一个「为了体验」而加的依赖）。
> 这条已记录在 `docs/reply_review.md` §AG 遗漏 2。

### 8.5 每次发布前的一次性检查

```bat
cd /d D:\shensuanzi\shensuanzi
flutter analyze
flutter test
dart run tool\import_guard.dart
cd packages\shensuanzi_app && dart test && cd ..\..
```

四项全绿再打包（`make_release.py` 还会额外拦一次「产物比源码旧」）。
`flutter analyze` 必须是 **0 issues**（`Agents.md` 的门禁）。
