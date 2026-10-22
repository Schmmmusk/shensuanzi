/// **界面用色的常量**（2026-10-22，§CV·八十三 批 2 第 11 条）。
///
/// ## 为什么要有这个文件
///
/// 橙色 `0xFFB45309` 在全仓出现 **29 次**：3 处是各页私有的常量定义，
/// 其余是字面量；另有 `0xFF9A5B00`、`0xFF92400E` 两个**近似色**。
/// 想把橙色调深一档时必然漏一片 —— 同一语义出现三种颜色。
///
/// ## 为什么在根层而不在 `shensuanzi_app`
///
/// `shensuanzi_app` 是**纯 Dart 包**（`dart test` 能跑），不能 import flutter ——
/// 所以放不了 `Color`。放在根层 `lib/src/ui/`，与其它摆放组件同层。
///
/// ## 语义分工
///
/// - [AppColors.warningOrange] = **不拦人的告知**
///   （`ui_principles.md`：提示但不阻止用户）
/// - 错误色不在这里 —— 用 `Theme.colorScheme.error`（各页已经在用）
library;

import 'package:flutter/material.dart';

/// 界面用色。**只放「与主题无关、跨页必须一致」的颜色**。
abstract final class AppColors {
  const AppColors._();

  /// 「不拦人的告知」专用橙（条码重复内联提示、包装换算说明、装箱提示…）。
  ///
  /// 历史遗留的近似色 `0xFF9A5B00` / `0xFF92400E` 已一并归一到这个值 ——
  /// 肉眼几乎分不出，维护上却是三个坑。
  static const Color warningOrange = Color(0xFFB45309);
}
