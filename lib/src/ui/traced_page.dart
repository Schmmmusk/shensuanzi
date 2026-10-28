/// 给「切页」计时的一层薄包装（Flutter 侧；纯 Dart 的收集器在
/// `package:shensuanzi_app/src/startup_trace.dart`）。
///
/// ## 为什么它在根层而不在 `shensuanzi_app` 包里
///
/// `packages/shensuanzi_app` 是**纯 Dart 包**（没有 Flutter 依赖）——
/// 它的测试用 `dart test` 跑。往里塞 `StatefulWidget` 会直接编译不过
/// （2026-10-28 实测：`Target of URI doesn't exist: package:flutter/widgets.dart`）。
/// 所以：**收集器（只碰 `dart:io`）留在包里，widget 放根层**。
///
/// ## 为什么正式包里它不存在
///
/// 调用点写的是 `kStartupTrace ? TracedPage(...) : page`，而 `kStartupTrace`
/// 是 `const bool.fromEnvironment(...)`（编译期 false）⇒ 整个分支被折叠掉，
/// 正式包的 widget 树与从前**逐字相同**（多一层 `StatefulWidget` 会改变
/// rebuild 行为，不能悄悄留在生产里）。
///
/// ## 两个终点，不是一个（2026-10-28 第五轮）
///
/// 前四轮只记了「**第一帧画完**」（`firstMs`）。可用户体感的终点是
/// 「**页面稳定、可以操作**」—— 两者之间可能还有若干次重绘。
/// 所以这里再跟一段：首帧之后**每来一帧就重置一个 500 ms 静默计时器**，
/// 计时器真的响了才算「稳定」，记 `settledMs` 与这期间又画了几帧。
///
/// | 情况 | 判据 |
/// |---|---|
/// | 正常 | 首帧后 500 ms 内没有新帧 ⇒ 记 `settledMs` |
/// | 一直在动（转圈/动画） | **硬上限 10 秒**，到点强制记一次并标 `timedOut: true` |
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

class TracedPage extends StatefulWidget {
  const TracedPage({super.key, required this.name, required this.child});

  /// 页面标识（`NavDestination.id`，如 `documents`）
  final String name;
  final Widget child;

  @override
  State<TracedPage> createState() => _TracedPageState();
}

class _TracedPageState extends State<TracedPage> {
  /// 静默多久算「稳定」。
  static const Duration _quiet = Duration(milliseconds: 500);

  /// 硬上限：一直在重绘（转圈）也不能永远等下去。
  static const Duration _cap = Duration(seconds: 10);

  final Stopwatch _clock = Stopwatch()..start();

  int? _firstFrameMs;
  int _lastFrameMs = 0;
  int _frames = 0;
  bool _settled = false;
  Timer? _quietTimer;
  Timer? _capTimer;

  @override
  void initState() {
    super.initState();
    _capTimer = Timer(_cap, () => _settle(timedOut: true));
    // 首帧：`initState` 返回时还没画，必须等 post-frame
    WidgetsBinding.instance.addPostFrameCallback(
      (Duration _) => _onFrame(first: true),
    );
  }

  void _onFrame({bool first = false}) {
    if (!mounted || _settled) return;
    _frames++;
    _lastFrameMs = _clock.elapsedMilliseconds;
    if (first) {
      _firstFrameMs = _lastFrameMs;
      unawaited(StartupTrace.appendSwitch(widget.name, _firstFrameMs!));
    }
    // 每来一帧就重置静默计时；没有新帧时它会真的响
    _quietTimer?.cancel();
    _quietTimer = Timer(_quiet, () => _settle(timedOut: false));
    // 继续等下一帧（没有下一帧时这条链自然停住，由上面的计时器收尾）
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _onFrame());
  }

  void _settle({required bool timedOut}) {
    if (_settled || !mounted) return;
    _settled = true;
    _quietTimer?.cancel();
    _capTimer?.cancel();
    unawaited(
      StartupTrace.appendSettled(
        page: widget.name,
        firstMs: _firstFrameMs ?? _lastFrameMs,
        settledMs: _lastFrameMs,
        frames: _frames,
        timedOut: timedOut,
      ),
    );
  }

  @override
  void dispose() {
    _quietTimer?.cancel();
    _capTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
