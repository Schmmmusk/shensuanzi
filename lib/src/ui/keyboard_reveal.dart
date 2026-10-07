/// 键盘弹出 / 高度变化时，把**当前焦点字段**滚回可视区
/// （C3 真机反馈 ④：IME 输入时输入界面自行跳到输入法下方，看不到输入内容）。
///
/// ## 机制
///
/// [WidgetsBindingObserver.didChangeMetrics] 在窗口尺寸变化（键盘弹出 /
/// 收起 / **输入法候选栏伸缩**）时触发。用 `View.of(context).viewInsets`
/// 读**原始窗口** insets —— 不受页面 `Scaffold` 的 MediaQuery 裁剪影响，
/// 嵌套在多深的壳里都能拿到真值。
///
/// - insets 变大（键盘在屏）⇒ 下一帧把 `FocusManager.primaryFocus` 的字段
///   `Scrollable.ensureVisible` 到视口上沿 1/4 处（`alignment: 0.25` ——
///   给输入法候选栏留出上方余量）；
/// - insets 归零（键盘收起）⇒ **不动作** —— 不抢用户自己的滚动位置。
///
/// 焦点在页面级 `Focus`（非输入框）时，`ensureVisible` 找不到祖先滚动视图
/// 是无害 no-op。
///
/// ## 用法
///
/// 包在含表单的 `Scaffold` 外层：
/// `Focus(autofocus: true, child: KeyboardReveal(child: Scaffold(...)))`。
library;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 物理像素 —— 只用于「变没变」「键盘是否在屏」判断，不参与布局
    final double inset = View.of(context).viewInsets.bottom;
    if (inset == _lastInset) return;
    _lastInset = inset;
    if (inset <= 0) return; // 键盘收起：不抢用户的滚动位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final BuildContext? focusContext =
          FocusManager.instance.primaryFocus?.context;
      if (focusContext == null) return;
      Scrollable.ensureVisible(
        focusContext,
        duration: const Duration(milliseconds: 150),
        alignment: 0.25,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
