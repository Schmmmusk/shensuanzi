/// 全仓**唯一**的 SnackBar 出口（F12，2026-10-25 复跑；裁定 **D4 甲**）。
///
/// ## 它解决什么
///
/// 复跑实测「提示久不消退」，根因两条叠加：
///
/// 1. **不清理上一条**：Flutter 的 SnackBar 是**串行排队**的 —— 保存后立刻收款，
///    前一条 6 秒没走完，后面还压着两条，用户只能干等。全仓 38 处调用里只有
///    `export_button.dart` 一处先清队。
/// 2. **时长没有规矩**：6 秒 ×13、8 秒 ×7、4 秒 ×4、3 秒 ×3、2 秒 ×2 —— 两条 8 秒的
///    就能把提示压 16 秒。
///
/// ## 两条规矩（用户裁定）
///
/// - **弹之前先清队**（`removeCurrentSnackBar`）⇒ 永远只有一条在屏幕上；
/// - **时长只有两档**：普通 **3 秒**、长文案（含「怎么办」）**6 秒**。
///   调用方写 8 秒/4 秒/2 秒都会被 [showSnack] 归一化到这两档 —— **收在一处**，
///   不靠 38 个调用点各自守纪律。
library;

import 'package:flutter/material.dart';

/// 弹一条提示：**先清掉当前那条**，再弹这条。
void showSnack(BuildContext context, SnackBar bar) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(_twoTier(bar));
}

/// **应用级** messenger —— 挂在 `MaterialApp.scaffoldMessengerKey` 上。
///
/// ## 为什么需要它（2026-11-10，第四次真机实测 P1）
///
/// 现场：**备份进行中切到别的页，备份完成后「成功」通知永远不弹**。
/// 根因是调用点的 `if (!mounted) return;` —— 页面被 `dispose` 后 context 失效，
/// 而 `showSnack` 只能从 context 找最近的 messenger，于是消息没地方播、
/// 也没有任何兜底出口（全仓 grep 无 `scaffoldMessengerKey`）。
///
/// ⚠️ 面向的是**低速设备**用户：一次备份可能十秒，人必然会切走看看别的 ——
/// 「做完了没」这个回答不能因为切页就消失。
///
/// ## 规矩不变
///
/// 仍走 [_twoTier]（先清队 + 时长两档），与 [showSnack] 同一套观感。
/// [fallback] 只用于**没有挂 key 的场合**（页面级 widget 测试、独立预览）。
final GlobalKey<ScaffoldMessengerState> appMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 与 [showSnack] 同规矩，但**不依赖当前页面的 context**。
///
/// 优先走 [appMessengerKey]（页面已 dispose 也能播）；没挂 key 时退回 [fallback]。
/// 两者都没有 ⇒ 静默丢弃（诊断场景，不许因为「没地方弹」而抛异常）。
void showAppSnack(SnackBar bar, {BuildContext? fallback}) {
  final ScaffoldMessengerState? messenger = appMessengerKey.currentState;
  if (messenger != null) {
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(_twoTier(bar));
    return;
  }
  final BuildContext? ctx = fallback;
  if (ctx != null && ctx.mounted) showSnack(ctx, bar);
}

/// 只有一句文案时的简写（时长按 [long] 走两档）。
void showNotice(BuildContext context, String text, {bool long = false}) =>
    showSnack(
      context,
      SnackBar(
        content: Text(text),
        duration: Duration(seconds: long ? 6 : 3),
      ),
    );

/// 时长归一化：≥6 秒 ⇒ 6 秒，其余 ⇒ 3 秒。
///
/// ⚠️ 只重建必要字段：`content` / `action` / 颜色 / 形状等原样搬过去，
/// 免得"统一时长"顺手改了别的观感。
SnackBar _twoTier(SnackBar bar) {
  final int target = bar.duration.inSeconds >= 6 ? 6 : 3;
  if (bar.duration.inSeconds == target) return bar;
  return SnackBar(
    content: bar.content,
    action: bar.action,
    backgroundColor: bar.backgroundColor,
    elevation: bar.elevation,
    margin: bar.margin,
    padding: bar.padding,
    width: bar.width,
    shape: bar.shape,
    behavior: bar.behavior,
    dismissDirection: bar.dismissDirection,
    showCloseIcon: bar.showCloseIcon,
    closeIconColor: bar.closeIconColor,
    duration: Duration(seconds: target),
  );
}
