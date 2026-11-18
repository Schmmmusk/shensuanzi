// 导航列右侧那条竖线（**结构 + 粗细 + 颜色三件事在一起**）。
//
// ## 为什么单独一个 widget
//
// 这条线被用户反馈过两次「窄屏下看不出来」（2026-11-18）。两次都改在
// `app_shell.dart` 里那个 `VerticalDivider(...)` 上，而它有三个容易各自漂的参数：
//
// 1. **`width` 与 `thickness` 必须同时给** —— `VerticalDivider` 的实现是
//    `SizedBox(width) → Center → Container(width: thickness)`，只改 `thickness`
//    会被 `width` 夹回去（第一次改成 2 时踩过：线看着没变粗）；
// 2. **颜色** —— 默认吃 `outlineVariant`（`#C2C7CF`），对 #FAFAFA 只有 **1.63 : 1**，
//    这才是「看不出来」的真正原因（第二次反馈时从截图取像素才发现）；
// 3. **只在仅图标态加强** —— 宽屏 220 px 的导航列本来就有列边界感，跟着变粗会显得笨。
//
// 三个参数写在两个文件里迟早会漂，所以合成一个 widget：调用方只说
// 「是不是仅图标态」，其余由这里决定。
//
// ## 现在的取值
//
// | 状态 | 粗细 | 颜色 | 对 #FAFAFA |
// |---|---|---|---|
// | 仅图标（窄窗） | **3** | `colorScheme.outline`（`#73777F`） | **4.30 : 1** |
// | 常态（宽窗） | 1 | 主题默认（`outlineVariant`） | 1.63 : 1（列边界另有留白可说） |
//
// 闸门在 `test/nav_divider_test.dart`：它把「实际渲染出来的颜色」拿去算对比度，
// 不是只比对常量 —— 因为这条线坏掉的方式正是「常量对、画出来淡」。

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

/// 导航列右侧的分割线。
class NavDivider extends StatelessWidget {
  const NavDivider({super.key, required this.iconOnly});

  /// 仅图标态（窗口窄到放不下文字标签）—— 此时列边界最弱，线要加深加粗。
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double side = AppNavigation.dividerThickness(iconOnly: iconOnly);
    return VerticalDivider(
      width: side,
      thickness: side,
      // `null` = 用主题默认（宽屏不动，避免「顺手把常态也加深」）。
      color: iconOnly ? theme.colorScheme.outline : null,
    );
  }
}
