/// **同步期间的 UI 帧耗时**采集（2026-11-01，用户裁定 A5 的额外要求）。
///
/// ## 为什么需要它
///
/// 真机实测：26.4 万单的全量同步期间**进度条明显掉帧**（用户原话）。
/// 但「掉帧」是个体感词，没有数字就没法判断：
///
/// - 是**偶发**（几百帧里几个长帧，用户可能只是看到转圈动画卡了一下）？
/// - 还是**持续**（同步全程每帧都超 16.7 ms，说明主 isolate 被 JSON 解析 +
///   SQLite 落库占满了）？
///
/// 两者的处置完全不同：前者不用管，后者才值得考虑把数据处理挪到独立 isolate。
///
/// ## 为什么默认关闭
///
/// `addTimingsCallback` 每帧都会回调，虽然开销很小，但**没有任何理由让生产包
/// 常开**。用 `--dart-define=SSZ_SYNC_FRAME_TRACE` 显式打开：
///
/// ```bash
/// flutter build apk --profile --dart-define=SSZ_SYNC_FRAME_TRACE=true
/// ```
///
/// ## 只记「同步期间」
///
/// 从点「立即同步」到遮罩收起，中间那些帧才是用户体感的来源。
/// 平时页面的帧耗时由 `traced_page.dart` 那套（首帧 / settled）负责，两者不重叠。
///
/// ## ⚠️ 别用 `dumpsys gfxinfo` 量 Flutter
///
/// 2026-11-01 实测：它对 Flutter 应用读出 `Total frames rendered: 0` +
/// `50th percentile: 4950ms` —— 那是**假数**（它统计 Android View 层，
/// 而 Flutter 走自己的渲染线程）。所以必须从 Flutter 侧拿 `FrameTiming`。
library;

import 'package:flutter/scheduler.dart';

/// 一帧的耗时统计结果（**纯数据**，摘要文案见 [describe]）。
class FrameTraceSummary {
  const FrameTraceSummary({
    required this.frames,
    required this.p50Ms,
    required this.p90Ms,
    required this.p99Ms,
    required this.slowFrames,
    required this.totalMs,
  });

  /// 采集到的帧数（0 = 这段时间一帧都没画，通常意味着界面被完全阻塞）
  final int frames;

  final double p50Ms;
  final double p90Ms;
  final double p99Ms;

  /// 超过 [jankThresholdMs] 的帧数
  final int slowFrames;

  /// 采集窗口的总时长
  final int totalMs;

  /// 掉帧率（0..1）
  double get slowRatio => frames == 0 ? 0 : slowFrames / frames;

  /// 一行日志（**给日志看，不给用户看**）
  ///
  /// 格式固定，方便事后 grep：
  /// `同步帧耗时 frames=812 p50=12.3 p90=28.4 p99=61.0 slow=143/812(17.6%) span=9123ms`
  String describe() =>
      '同步帧耗时 frames=$frames '
      'p50=${p50Ms.toStringAsFixed(1)} '
      'p90=${p90Ms.toStringAsFixed(1)} '
      'p99=${p99Ms.toStringAsFixed(1)} '
      'slow=$slowFrames/$frames(${(slowRatio * 100).toStringAsFixed(1)}%) '
      'span=${totalMs}ms';
}

/// 超过这个值算「掉帧」（60 Hz 的 16.7 ms；120 Hz 屏上更严，但用同一把尺子便于比较）
const double jankThresholdMs = 16.7;

/// 把一串帧耗时（毫秒）算成摘要。**纯函数** —— 测试直接喂数字。
///
/// [spanMs] = 采集窗口的真实时长（从开始到结束的墙钟），用来算「这段时间本该画多少帧」。
FrameTraceSummary summarizeFrames(
  List<double> frameMs, {
  required int spanMs,
}) {
  if (frameMs.isEmpty) {
    return FrameTraceSummary(
      frames: 0,
      p50Ms: 0,
      p90Ms: 0,
      p99Ms: 0,
      slowFrames: 0,
      totalMs: spanMs,
    );
  }
  final List<double> sorted = List<double>.of(frameMs)..sort();
  double at(double q) {
    final int index = ((sorted.length - 1) * q).round().clamp(
      0,
      sorted.length - 1,
    );
    return sorted[index];
  }

  return FrameTraceSummary(
    frames: sorted.length,
    p50Ms: at(0.5),
    p90Ms: at(0.9),
    p99Ms: at(0.99),
    slowFrames: sorted.where((double ms) => ms > jankThresholdMs).length,
    totalMs: spanMs,
  );
}

/// 采集器：`start()` → 跑同步 → `stop()` 拿摘要。
///
/// 关闭时（默认）[start] 返回 `null`，调用方据此完全不介入 —— **零副作用**。
class SyncFrameTrace {
  SyncFrameTrace._();

  /// 编译期开关（`--dart-define=SSZ_SYNC_FRAME_TRACE=true`）
  static const bool enabled = bool.fromEnvironment('SSZ_SYNC_FRAME_TRACE');

  final List<double> _frames = <double>[];
  int _startedAt = 0;

  /// 开启时返回采集器，否则 `null`
  static SyncFrameTrace? start() {
    if (!enabled) return null;
    final SyncFrameTrace trace = SyncFrameTrace._();
    trace._startedAt = DateTime.now().millisecondsSinceEpoch;
    SchedulerBinding.instance.addTimingsCallback(trace._onTimings);
    return trace;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming timing in timings) {
      // `totalSpan` = 这一帧从 build 到 raster 完成的总时长（微秒）
      _frames.add(timing.totalSpan.inMicroseconds / 1000);
    }
  }

  /// 停止采集并返回摘要（`null` = 这段时间一帧都没有 —— 本身就是要报的信号）
  FrameTraceSummary stop() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    final int span = DateTime.now().millisecondsSinceEpoch - _startedAt;
    return summarizeFrames(_frames, spanMs: span);
  }
}
