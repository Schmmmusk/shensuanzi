# 值得做，但只注入一个东西

## 缺口的性质

你说得对，但值得把缺口说精确一点：**纯 Dart 那层已经测透了**（`DataDirectoryDialogModel` 有 20 个用例、`DataDirectoryPolicy` 有几十个），漏的是**「什么时候弹、拿到结果之后干什么」**这段接线。它住在 `lib/src/app.dart`，是 Flutter 层。

这段接线恰恰是**最容易悄悄坏掉**的地方——因为它没有任何断言，改一次 `existing()` 的返回语义、改一次对话框的 `pop` 类型，程序就会**静默地跳过对话框**，而所有单元测试都是绿的。

## 我的建议：只注入 `pickDirectory`

`DataDirectoryService` **不要注入**。理由：

| 依赖 | 会不会阻塞测试 | 要不要注入 |
|---|---|---|
| `pickDirectory`（系统选择器） | **会** —— 真弹系统框，测试卡死 | **必须** |
| `DataDirectoryService`（创建目录、写标记） | 不会 —— 指到临时目录就行 | 不需要 |
| `AppBootstrap`（开 SQLite） | 不会 —— 同上 | 不需要 |

**一个注入点就能解锁全部场景**，其他都走真实路径。这比注入三个依赖更值——你测的是**真实的集成路径**，不是拼装出来的假象。

## 构造函数的改动量

```dart
class ShensuanziApp extends StatelessWidget {
  final Future<String?> Function() pickDirectory;

  const ShensuanziApp({
    super.key,
    Future<String?> Function()? pickDirectory,
  }) : pickDirectory = pickDirectory ?? pickFolderFromSystem;
  ...
}
```

**默认值指向真实实现**——现有调用点 `runApp(const ShensuanziApp())` 一个字都不用改。测试里传个桩。这就是「可选命名参数 + 默认值」的标准用法，代价是一行。

**一个必须点出的隐患**：默认值不能写成 `null` 再在 `build` 里兜底，否则「忘了传」会变成「运行时才炸」。**默认值必须在构造函数参数里就地给出**，让类型系统保证它非空。

## 测试能抓到什么

这才是关键——注入不是目的，**断言才是**：

| 场景 | 断言 |
|---|---|
| 没有配置过数据目录 | `find.byType(DataDirectoryDialog)` **不空** |
| 配置过且目录可用 | 对话框**不出现**，`find.byType(AppShell)` 不空 |
| 用户在对话框里选了目录 | 对话框消失，`AppShell` 出现 |
| 用户取消（选择器返回 `null`） | 对话框**仍在**，没崩 |
| 数据库打不开 | **错误页**出现，不是 `AppShell` |

**第二条尤其重要**——「配置过就不再弹」是这条流程的主路径，但它恰恰是最容易在重构里被破坏的（比如某人把 `existing()` 的语义从「可用」改成「存在」，磁盘被拔了也直接进主界面）。今天没有断言，坏了没人知道。

## 顺带一个附带收益

一旦 `ShensuanziApp` 接受了 `pickDirectory`，`folder_picker.dart` 就从「全项目唯一调用 Flutter 插件的地方」升级成「全项目唯一**注入** Flutter 插件的地方」。这个文件会更小、更专一——**它不再是一个实现，而是一个注入点**。将来如果 Android 端要做「选择文件夹」的替代方案，改这里就够了。

## 别做的事

**不要现在就抽 `AppStartupModel`。** 启动流程现在只有三个分支（有配置 / 没配置 / 开库失败），抽成状态机会引入一个只有三个状态的类、一堆转发方法和一个更复杂的 `build`。**等第四个分支出现时再抽**——那时你会知道它需要什么字段。

这跟「数据目录对话框」不一样：那个抽出来是因为它有**六种互斥结果**和**实时校验**，值得独立测试；启动流程没有这个复杂度。

## 一句话

**注入 `pickDirectory`，一个参数，默认值指向真实实现。** 用五个场景把「对话框弹不弹、开库失不失败」钉住。`DataDirectoryService` 不用注入——把它指向临时目录，走真实路径，测出来的才是真的。

---
