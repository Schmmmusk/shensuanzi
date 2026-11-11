/// 单页「重建次数 / 全表聚合耗时」计数（**临时埋点**，编译期开关）。
///
/// ```bash
/// flutter build windows --release --dart-define=SSZ_PAGE_COST_TRACE=true
/// ```
///
/// `const bool.fromEnvironment(...)` 在**编译期**求值：不传这个 define 时
/// [kPageCostTrace] 恒 `false`，`kPageCostTrace ? … : null` 被常量折叠 ⇒
/// 正式包里连一个字节的机器码都不留（与 `startup_trace.dart` 同一套理由）。
///
/// ## 为什么要有它（2026-11-09，用户裁定「甲」）
///
/// 复测判读 `docs/20261109-新版本虚拟机复测-判读.md` §四 留了一个**没法闭合**的
/// 假设：库存页 `build()` 里跑两条全表聚合（`stock_page.dart` 的
/// `stockAggregates()` / `inTransitByProduct()`），**一次进入若重建 N 次，
/// 就是 2N 次索引全扫**。
///
/// 现场数字：单条聚合缓存热时只要 **39 / 70 ms**，而「一次进入」实测读
/// **212 MB**、耗时 2.02 s —— 差的是**次数**，不是单次成本。
///
/// 所以这条埋点只回答三个问题：
///
/// | 记什么 | 判什么 |
/// |---|---|
/// | `builds` | 一次进入到底重建了几次 |
/// | `aggMs` / `transitMs` | 两条聚合各花了多久（合计，不是单次） |
/// | `perBuild[i][0]` | 第 i 次重建距**进入**多久（对齐 `samples.csv` 用） |
///
/// **判据**：`builds` 只有 1–2 且 `aggMs` 小 ⇒ §四 假设作废，读放大要找别的原因；
/// `builds` 上十位数、`aggMs` 上百毫秒 ⇒ 假设成立，就该把聚合挪出 `build()`。
///
/// ## 与 `SSZ_STARTUP_TRACE` 的分工（两者可同时开）
///
/// | 埋点 | 回答 |
/// |---|---|
/// | `SSZ_STARTUP_TRACE`（`TracedPage`） | 「切页 → 首帧 / 稳定」各多久、期间画了几帧 |
/// | `SSZ_PAGE_COST_TRACE`（本文件） | 「这一页的 build 被调了几次、聚合花在哪」 |
///
/// 前者给**用户体感的上下界**，后者给**成本的来源**。
///
/// ## 落盘时机故意放在**退出页面时**
///
/// 计数期间**不碰磁盘** —— 每次 build 都写一行，会把「被测量的东西」加上
/// I/O 噪声（`startup_trace.dart` 的同一教训：埋点不许拖慢被埋的东西）。
/// 所以：进入 → 全程只在内存里累加 → 离开页面时一次写完一行 JSONL。
///
/// ## 这是**临时**埋点
///
/// 它只为一件事存在：判定读放大是否来自「一次进入的多次重建」。
/// **回答完之后（`docs/reply_review.md` 记下结论那天）连调用点一起删掉** ——
/// 一个常开的诊断层留在生产里，迟早会有人拿它当功能用。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'log.dart' show logFolderName;

/// 埋点总开关。**编译期常量**：不传 `--dart-define=SSZ_PAGE_COST_TRACE=true` 时恒 `false`。
const bool kPageCostTrace = bool.fromEnvironment('SSZ_PAGE_COST_TRACE');

/// 一次「页面进入」的成本账。
///
/// 生命周期：`initState` 里建 → 每次 `build` 记一笔 → `dispose` 里 [finish] 落盘。
class PageCostTrace {
  PageCostTrace({required this.page, this.file});

  /// 页面标识（与 `NavDestination.id` 同口径，如 `stock`）
  final String page;

  /// 落盘目标；`null` = 只算不写（内存库 / 测试）
  final File? file;

  /// 从**进入**开始计时 —— 起点比第一次 `build` 还早（含 `initState` 里那次
  /// `stockTop()`），因为用户体感的起点是「点下导航」。
  final Stopwatch _clock = Stopwatch()..start();

  /// 两条聚合的**累计**耗时（微秒）
  int _aggUs = 0;
  int _transitUs = 0;

  /// 每次重建一行：`[距进入毫秒, 该次聚合毫秒, 该次在途毫秒]`
  final List<List<int>> _perBuild = <List<int>>[];

  /// 一次进入重建了几次（= [line] 里的 `builds`）
  int get builds => _perBuild.length;

  /// 记一次 `build()`（**放在 `build()` 第一行**，早于任何聚合调用）
  void build() => _perBuild.add(<int>[_clock.elapsedMilliseconds, 0, 0]);

  /// 记一次 `stockAggregates()` 的耗时（微秒）。须在 [build] 之后调。
  void aggregates(int microseconds) {
    _aggUs += microseconds;
    if (_perBuild.isNotEmpty) _perBuild.last[1] = microseconds ~/ 1000;
  }

  /// 记一次 `inTransitByProduct()` 的耗时（微秒）。须在 [build] 之后调。
  void inTransit(int microseconds) {
    _transitUs += microseconds;
    if (_perBuild.isNotEmpty) _perBuild.last[2] = microseconds ~/ 1000;
  }

  /// 拼一行 JSONL。逻辑在 [pageCostLine]（纯函数，格式可单测）。
  String line(DateTime now) => pageCostLine(
    page: page,
    now: now,
    builds: _perBuild.length,
    spanMs: _clock.elapsedMilliseconds,
    aggMs: _aggUs ~/ 1000,
    transitMs: _transitUs ~/ 1000,
    perBuild: _perBuild,
  );

  /// 离开页面时调一次：**追加**一行。失败不抛（诊断工具，不是功能）。
  Future<void> finish() async {
    final File? target = file;
    if (!kPageCostTrace || target == null) return;
    try {
      await target.parent.create(recursive: true);
      await target.writeAsString(
        '${line(DateTime.now())}\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // 目录只读 / 磁盘满 / 库被挪走都会走到这里：埋点绝不能影响软件运行
    }
  }

  /// 落盘路径：**跟着数据库走** —— `<数据目录>/日志/page-cost.jsonl`。
  ///
  /// 与 `StartupTrace.traceFileFor` 同一个理由（Android 上 `APPDATA` 为空），
  /// 也是同一个位置：两套埋点**放同一个目录**，用户只拷一个文件夹就够。
  /// 内存库（`Db.path == null`）返回 `null` ⇒ 只算不写。
  static File? fileFor(String? databasePath) => databasePath == null
      ? null
      : File(p.join(p.dirname(databasePath), logFolderName, 'page-cost.jsonl'));
}

/// 拼一行「单页成本」的 JSON（**纯函数**，单测直接喂数据）。
///
/// 示例：
/// ```json
/// {"kind":"pagecost","ts":"2026-11-09T22:24:03.120","page":"stock",
///  "builds":3,"spanMs":2010,"aggMs":118,"transitMs":211,
///  "perBuild":[[0,39,70],[812,40,71],[1600,39,70]]}
/// ```
String pageCostLine({
  required String page,
  required DateTime now,
  required int builds,
  required int spanMs,
  required int aggMs,
  required int transitMs,
  required List<List<int>> perBuild,
}) {
  final StringBuffer buffer = StringBuffer()
    ..write('{"kind":"pagecost","ts":"')
    ..write(now.toIso8601String())
    ..write('","page":"')
    ..write(page)
    // 汇总在前、明细在后：现场第一眼要看的是「几次」和「多久」
    ..write('","builds":')
    ..write(builds)
    ..write(',"spanMs":')
    ..write(spanMs)
    ..write(',"aggMs":')
    ..write(aggMs)
    ..write(',"transitMs":')
    ..write(transitMs)
    ..write(',"perBuild":[');
  for (int i = 0; i < perBuild.length; i++) {
    if (i > 0) buffer.write(',');
    buffer.write('[');
    final List<int> one = perBuild[i];
    for (int j = 0; j < one.length; j++) {
      if (j > 0) buffer.write(',');
      buffer.write(one[j]);
    }
    buffer.write(']');
  }
  buffer.write(']}');
  return buffer.toString();
}
