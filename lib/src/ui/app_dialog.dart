/// **弹窗内边距统一入口**（2026-11-27；批 0 实测结论的落地）。
///
/// ## 病：字号放大时，内边距被框架**反向压缩**
///
/// `AlertDialog` 内部用 `paddingScaleFactor` 乘左右/上内边距，而那个系数是
/// `lerp(1.0, 1/3, clamp(textScale,1,2)-1)` —— 也就是 2.0 档时**只剩 1/3**：
/// 24 px 的默认内边距变成 **8 px**（批 0 实测：1.00 → 24、1.75 → 12、2.00 → 8）。
/// 字放大了两倍、边距缩到三分之一 ⇒ 标题和按钮**贴着边框**（用户原话：
/// 「几乎撑破了对话框」）。这**不是溢出**，框架不会报黄黑条纹。
///
/// ## 治法：把内边距**补偿回去**
///
/// 框架会乘 `factor`，那我们就先除 `factor`：给 `24 / factor`，
/// 乘完正好是 **24** —— 任何缩放下边距都稳定在 24 px，不再随字号缩水。
///
/// 为什么不"2.0 档给 34"：`AlertDialog` 只对**部分**边（左右 / 标题上边）乘系数，
/// 底部与"标题→正文"间距是**原样使用**的。同一个数值既要被除、又要原样用，
/// 混在一处必然算错一边。**稳定 24 px** 是一条简单、可验证、不会算错的规则。
///
/// ## 用法
///
/// 只在 `MaterialApp.builder` 里挂一次（`app.dart`），**25 个 `AlertDialog`
/// 一处生效**，不用逐个改调用点 —— 批 0 的结论就是「改一个共用入口即可」。
library;

import 'package:flutter/material.dart';

/// 复刻框架的 `paddingScaleFactor`（`material/dialog.dart` 的 `_scalePadding`）。
///
/// ⚠️ 这是**框架内部实现细节的镜像**：Flutter 改了 `_scalePadding`，这里必须跟着改。
/// 兜底不炸 —— 最坏情况是边距偏大/偏小几像素，不会溢出（框架仍会自己收窄卡片）。
double dialogPaddingScaleFactor(double textScale) {
  final double clamped = textScale.clamp(1.0, 2.0);
  // lerp(1.0, 1/3, t-1)
  return 1.0 + ((1.0 / 3.0) - 1.0) * (clamped - 1.0);
}

/// 该缩放下，为了让**实际**左右/上内边距等于 [target]，应该传给框架的数值。
double dialogPaddingSupply(double textScale, {double target = 24}) =>
    target / dialogPaddingScaleFactor(textScale);

/// 与 `AlertDialog` 同名同义的弹窗，唯一区别是**内边距不随字号缩水**。
///
/// 为什么不能只改主题：本 Flutter 版本的 `DialogThemeData` **只有**
/// `actionsPadding` / `insetPadding`，**没有** `titlePadding` / `contentPadding`
/// —— 全局主题覆盖不了这两项，所以必须换成一个能自己算边距的组件。
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.actionsPadding,
    this.contentPadding,
    this.titlePadding,
    this.insetPadding,
    this.backgroundColor,
    this.shape,
    this.scrollable = false,
    this.actionsAlignment,
    this.clipBehavior = Clip.none,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? actionsPadding;

  /// 显式给值 ⇒ **原样使用**（尊重既有排版）；`null` ⇒ 统一值。
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? titlePadding;

  final EdgeInsets? insetPadding;
  final Color? backgroundColor;
  final ShapeBorder? shape;
  final bool scrollable;
  final MainAxisAlignment? actionsAlignment;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final double scale = MediaQuery.textScalerOf(context).scale(1.0);
    // 会被框架乘系数的边 ⇒ 预先除回去（见文件头的算术）；
    // 不会被乘的边（标题下 / 正文上 / 各处下边距）⇒ 给原值。
    final double p = dialogPaddingSupply(scale);
    return AlertDialog(
      title: title,
      content: content,
      actions: actions,
      backgroundColor: backgroundColor,
      shape: shape,
      scrollable: scrollable,
      actionsAlignment: actionsAlignment,
      clipBehavior: clipBehavior,
      insetPadding: insetPadding,
      titlePadding:
          titlePadding ?? EdgeInsets.only(left: p, right: p, top: p, bottom: 0),
      contentPadding: contentPadding ?? EdgeInsets.fromLTRB(p, 16, p, 24),
      actionsPadding: actionsPadding ?? EdgeInsets.fromLTRB(p, 0, p, 12),
    );
  }
}
