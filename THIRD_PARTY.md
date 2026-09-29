# 第三方组件与许可声明

神算子（Shensuanzi）以 **AGPL-3.0** 发布（见 [`LICENSE`](LICENSE)）。
本文件列出**随程序一起分发**的第三方组件及其许可，以及**明确未内嵌**的东西。

> 为什么需要这份文件：AGPL-3.0 允许把不同许可的第三方组件一起分发，
> 但**必须保留它们的声明**。打包时（见 [`docs/windows_build.md`](docs/windows_build.md) §八）
> 本文件会随产物一起放进 zip。

---

## 一、随程序分发的组件

| 组件 | 版本（本轮） | 许可 | 用途 / 出现位置 |
|---|---|---|---|
| [Flutter](https://flutter.dev) | SDK 自带 | **BSD-3-Clause** | UI 框架。产物里的 `flutter_windows.dll`、`data/app.so` |
| [Dart](https://dart.dev) | SDK 自带 | **BSD-3-Clause** | 语言与运行时 |
| [SQLite](https://sqlite.org) | 随 `sqlite3_flutter_libs` 内置 | **Public Domain** | 数据库引擎。产物里的 `sqlite3.dll` |
| [`sqlite3`](https://pub.dev/packages/sqlite3)（Dart 绑定） | 2.9.4 | **MIT** | Dart 侧调用 SQLite |
| [`sqlite3_flutter_libs`](https://pub.dev/packages/sqlite3_flutter_libs) | 0.5.42 | **MIT** | 把 SQLite 原生库随应用打包 |
| [`file_selector`](https://pub.dev/packages/file_selector) | 1.1.0 | **BSD-3-Clause** | 「选择数据文件夹」对话框 |
| [`file_selector_windows`](https://pub.dev/packages/file_selector_windows) | 0.9.3+6 | **BSD-3-Clause** | 同上（Windows 实现） |
| [`path`](https://pub.dev/packages/path) | 1.9.1 | **BSD-3-Clause** | 路径拼接 |
| [`cupertino_icons`](https://pub.dev/packages/cupertino_icons) | 1.0.9 | **MIT** | 图标字体 `CupertinoIcons.ttf`（随产物打包） |
| Material Icons（`MaterialIcons-Regular.otf`） | 随 Flutter 打包 | **Apache-2.0** | 界面图标字体 |
| [`shelf`](https://pub.dev/packages/shelf) 及 `shensuanzi_host` 的依赖 | 见 `pubspec.lock` | **BSD-3-Clause** | 未来「多设备同步」的 HTTP 服务（当前**尚未接入桌面应用**） |

> ⚠️ 版本号是**本轮构建时** `pubspec.lock` 的实际取值。升级依赖后请同步本表 ——
> 表里的版本是「事实上随产物出去的东西」，不是「pubspec 里允许的范围」。

---

## 二、**没有**内嵌的东西（要说清楚）

### 字体：本软件**不内嵌任何中文字体**

Windows 上使用的是**系统已安装**的字体，按下列顺序取第一个可用的：

```
Microsoft YaHei UI → Microsoft YaHei → SimHei → Segoe UI
```

- 这些字体由**操作系统提供**，神算子**不打包、不再分发、不主张任何权利**
- Android 端**不指定字体**（系统默认字体本身就是中文可用的 Noto / 思源）
- 因此本软件**不需要**任何字体授权

> 这一点必须写明：否则审查者会问「你的中文字体授权在哪」。
> 答案不是「有授权」，而是「**没有内嵌**」。

### 其他未包含项

| 项 | 说明 |
|---|---|
| 数字签名证书 | 未购买（见 `docs/reply_review.md` §AG-3）—— 首次运行会有 SmartScreen 提示 |
| 用户数据 | 产物里**不含任何用户数据**；数据在用户自己选的目录里（见 README「数据在哪」） |

---

## 三、自行构建时的第三方源码

Windows 构建需要在**配置阶段**拿到 SQLite 源码。本仓库**不存**这份源码
（`third_party/` 在 `.gitignore` 里），需要按
[`docs/windows_build.md`](docs/windows_build.md) §三 预置 —— 那是**构建期的输入**，
不随产物分发，因此**不出现在本表的「随程序分发」中**。

---

Copyright (C) 2026 神算子贡献者（Shensuanzi contributors）
