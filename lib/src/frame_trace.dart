/// **全时段**帧耗时采集（编译期开关，正式包零开销）。
///
/// ```bash
/// flutter build windows --release --dart-define=SSZ_FRAME_TRACE=true
/// ```
///
/// ## 为什么需要它（2026-11-10，第四次真机实测 P3）
///
/// 真机上「假死」和机器侧对不上：19:35:36–19:36:44 **连续 68 秒 CPU 0.0%**，
/// RSS 不动、读不增，而测试人员记录「界面明显假死，约 1 秒后才绘制完整页面」。
/// 现有两套埋点都答不了这个问题：
///
/// | 现有 | 给的是什么 | 缺什么 |
/// |---|---|---|
/// | `TracedPage`（`SSZ_STARTUP_TRACE`） | 首帧 / 稳定 / **画了几帧** | 每帧**多久**、花在 build 还是 raster |
/// | `SyncFrameTrace`（`SSZ_SYNC_FRAME_TRACE`） | 同步窗口内的**总时长**分位 | 只覆盖同步、且不分 build / raster |
///
/// 所以这里补的正是那一列：**build 与 raster 分开**。
/// 判据很直接 ——
///
/// - `build` 高 ⇒ 主 isolate 在算（我们的 Widget / SQL），该动我们的代码；
/// - `build` 低而 `raster` 高 ⇒ 画得慢（GPU / 合成器 / 杀软拦文件），不是算不过来；
/// - 两者都低但用户仍觉卡 ⇒ **连帧都没排上**（输入/呈现链路），继续查环境。
///
/// ## 与既有两套的分工（三者可同时开，互不重叠）
///
/// 本文件**不记页面名**：时间戳足够与 `startup-trace.jsonl` 的 `page` 行对齐，
/// 而记录当前页名需要每个页面往这里注册一次 —— 多一处必漏的耦合。
///
/// ## 落盘
///
/// 每 [window]（默认 5 秒）追加一行到 `<数据目录>/日志/frame-cost.jsonl`。
/// **只在内存里累加**、到点一次写 —— 与 `page_cost_trace.dart` 同一条教训：
/// 埋点不许拖慢被埋的东西。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;

import 'sync_frame_trace.dart' show FrameTraceSummary, summarizeFrames;

/// 埋点总开关。**编译期常量**：不传 `--dart-define=SSZ_FRAME_TRACE=true` 时恒 `false`。
const bool kFrameTrace = bool.fromEnvironment('SSZ_FRAME_TRACE');

/// 日志目录名（与 `AppLog` / 另两套埋点同一个目录）
const String _logFolder = '日志';

/// 采集器：`attach()` 之后每 [window] 落一行；进程退出即止（无常驻线程）。
class FrameTrace {
  FrameTrace._(this._file);

  /// 落盘目标；`null` = 只算不写（内存库 / 测试）
  final File? _file;

  /// 三列分开存 —— 判据就是「哪一列高」
  final List<double> _build = <double>[];
  final List<double> _raster = <double>[];
  final List<double> _total = <double>[];

  int _windowStart = DateTime.now().millisecondsSinceEpoch;

  static FrameTrace? _active;

  /// 幂等：重复调用不会装两个回调（迁移后重开库会再走一次装配）。
  static void attach(
    String? databasePath, {
    Duration window = const Duration(seconds: 5),
  }) {
    if (!kFrameTrace) return;
    if (_active != null) return;
    final FrameTrace trace = FrameTrace._(_fileFor(databasePath));
    _active = trace;
    trace._windowStart = DateTime.now().millisecondsSinceEpoch;
    SchedulerBinding.instance.addTimingsCallback(trace._onTimings);
    trace._window = window;
  }

  Duration _window = const Duration(seconds: 5);

  /// 只给测试用：摘掉回调并清空。
  static void detachForTest() {
    final FrameTrace? trace = _active;
    if (trace != null) {
      SchedulerBinding.instance.removeTimingsCallback(trace._onTimings);
    }
    _active = null;
  }

  /// 落盘路径：**跟着数据库走** —— `<数据目录>/日志/frame-cost.jsonl`
  /// （与 `startup-trace.jsonl` / `page-cost.jsonl` 同目录，用户只拷一个文件夹）。
  static File? _fileFor(String? databasePath) => databasePath == null
      ? null
      : File(p.join(p.dirname(databasePath), _logFolder, 'frame-cost.jsonl'));

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      _build.add(t.buildDuration.inMicroseconds / 1000);
      _raster.add(t.rasterDuration.inMicroseconds / 1000);
      _total.add(t.totalSpan.inMicroseconds / 1000);
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _windowStart >= _window.inMilliseconds) _flush(now);
  }

  void _flush(int now) {
    final int span = now - _windowStart;
    // 这 5 秒一帧都没画（界面空闲或被完全阻塞）：不写行 —— 空闲期刷屏没有信息量
    if (_total.isEmpty) {
      _windowStart = now;
      return;
    }
    final String line = frameCostLine(
      now: DateTime.fromMillisecondsSinceEpoch(now),
      winMs: span,
      total: summarizeFrames(_total, spanMs: span),
      build: summarizeFrames(_build, spanMs: span),
      raster: summarizeFrames(_raster, spanMs: span),
    );
    _build.clear();
    _raster.clear();
    _total.clear();
    _windowStart = now;

    final File? target = _file;
    if (target == null) return;
    // ⚠️ **异步追加**：这是帧回调里，任何同步 I/O 都会亲手制造我们想测的那种卡顿。
    unawaited(_append(target, '$line\n'));
  }
}

/// 追加一行（异步、失败吞掉）。诊断工具：写不进去绝不影响软件。
Future<void> _append(File target, String text) async {
  try {
    await target.parent.create(recursive: true);
    await target.writeAsString(text, mode: FileMode.append, flush: false);
  } catch (_) {
    // 目录只读 / 磁盘满 / 库被挪走：埋点不许抛
  }
}

/// 拼一行「帧耗时」JSON（**纯函数**，单测直接喂数据）。
///
/// 三列各带 `n` / `p50` / `p90` / `p99` / `slow`（>16.7 ms 的帧数）。
String frameCostLine({
  required DateTime now,
  required int winMs,
  required FrameTraceSummary total,
  required FrameTraceSummary build,
  required FrameTraceSummary raster,
}) {
  String one(FrameTraceSummary s) =>
      '{"n":${s.frames},"p50":${s.p50Ms.toStringAsFixed(1)},'
      '"p90":${s.p90Ms.toStringAsFixed(1)},'
      '"p99":${s.p99Ms.toStringAsFixed(1)},"slow":${s.slowFrames}}';
  return '{"kind":"frames","ts":"${now.toIso8601String()}",'
      '"winMs":$winMs,'
      '"total":${one(total)},'
      '"build":${one(build)},'
      '"raster":${one(raster)}}';
}
