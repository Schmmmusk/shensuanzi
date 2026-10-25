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
