/// 键盘或候选栏稳定后，将被遮住的焦点移回本页可视区域。
library;

import 'dart:async';

import 'package:flutter/material.dart';

class KeyboardReveal extends StatefulWidget {
  const KeyboardReveal({super.key, required this.child});

  final Widget child;

  @override
  State<KeyboardReveal> createState() => _KeyboardRevealState();
}

class _KeyboardRevealState extends State<KeyboardReveal>
    with WidgetsBindingObserver {
  double _lastInset = -1;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _settle?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 物理像素 —— 只用于「变没变」「键盘是否在屏」判断，不参与布局
    final double inset = View.of(context).viewInsets.bottom;
    if (inset == _lastInset) return;
    _lastInset = inset;
    _settle?.cancel();
    if (inset <= 0) return;
    _settle = Timer(const Duration(milliseconds: 75), _reveal);
  }

  void _reveal() {
    if (!mounted) return;
    final target = FocusManager.instance.primaryFocus?.context;
    if (target == null ||
        target.findAncestorStateOfType<_KeyboardRevealState>() != this) {
      return;
    }
    final scroll = Scrollable.maybeOf(target, axis: Axis.vertical);
    final field = target.findRenderObject();
    final viewport = scroll?.context.findRenderObject();
    if (scroll == null ||
        field is! RenderBox ||
        viewport is! RenderBox ||
        !field.attached ||
        !viewport.attached ||
        !field.hasSize ||
        !viewport.hasSize) {
      return;
    }
    final rect = MatrixUtils.transformRect(
      field.getTransformTo(viewport),
      field.paintBounds,
    );
    final delta = rect.top < 0
        ? rect.top
        : rect.bottom > viewport.size.height
        ? rect.bottom - viewport.size.height
        : 0.0;
    if (delta.abs() < 0.5) return;
    final position = scroll.position;
    final offset = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if (MediaQuery.disableAnimationsOf(context)) {
      position.jumpTo(offset);
    } else {
      position.animateTo(
        offset,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
