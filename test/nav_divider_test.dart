// 导航分割线的**对比度**闸门（2026-11-18 用户两次反馈「窄屏下看不出来」）。
//
// ## 为什么要这么一个测试
//
// 这条线坏掉的方式不是「崩了」，而是「**常量对、画出来淡**」：
// 第一次改的时候，代码注释写着 `dividerColor` = #73777F 就照它下结论「颜色够深」，
// 结果真正画出来的是 M3 的 `outlineVariant` = **#C2C7CF**，对背景 **1.63 : 1**
// —— 所以「加粗」当然没用。用户第二次反馈后从截图逐像素取色才看见真相。
//
// ⇒ 闸门不看常量，看**渲染出来的 widget**：拿到 `VerticalDivider.color` 与
// `thickness`，再拿主题背景色算 WCAG 对比度。判据三条：
//
// 1. 仅图标态：对比度 **≥ 3 : 1**（WCAG 1.4.11 对非文字 UI 的下限）；
// 2. 仅图标态必须**明确给出**颜色（`color != null`）—— 靠主题默认就会退回
//    `outlineVariant`，那正是坏掉的那一版；
// 3. 宽屏（常态）不动：1 px + 主题默认色（别顺手把常态也加深加粗）。
//
// 反向灵敏度：把 `NavDivider` 的 `color:` 改回不传 ⇒ ① 与 ② 一起红。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/nav_divider.dart';

void main() {
  /// 只用生产主题里那几个会影响的字段（`app.dart` 的 `_buildTheme`）
  ThemeData theme() => ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FA8)),
    scaffoldBackgroundColor: const Color(0xFFFAFAFA),
    useMaterial3: true,
  );

  /// WCAG 相对亮度
  double luminance(Color color) {
    double channel(double v) => v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(color.r) +
        0.7152 * channel(color.g) +
        0.0722 * channel(color.b);
  }

  /// 对比度（1.0 ~ 21.0）
  double contrast(Color a, Color b) {
    final double la = luminance(a);
    final double lb = luminance(b);
    final double hi = la > lb ? la : lb;
    final double lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  Future<VerticalDivider> render(WidgetTester tester, bool iconOnly) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(),
        home: Scaffold(
          body: Row(
            children: <Widget>[
              const SizedBox(width: 40),
              NavDivider(iconOnly: iconOnly),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    return tester.widget<VerticalDivider>(find.byType(VerticalDivider));
  }

  testWidgets('仅图标态：渲染出来的颜色对背景 ≥ 3:1，且粗细与 width 一致', (
    WidgetTester tester,
  ) async {
    final VerticalDivider divider = await render(tester, true);
    final Color background = theme().scaffoldBackgroundColor;

    expect(
      divider.color,
      isNotNull,
      reason: '必须显式给颜色 —— 主题默认是 outlineVariant（#C2C7CF），1.63:1 看不见',
    );
    expect(
      divider.color,
      theme().colorScheme.outline,
      reason: '加深到 outline（#73777F）：这是「第二次反馈后」定下的那一档',
    );
    expect(
      contrast(divider.color!, background),
      greaterThanOrEqualTo(3.0),
      reason: 'WCAG 1.4.11：非文字 UI 的分界线对相邻颜色至少要 3:1',
    );
    expect(
      divider.thickness,
      3,
      reason: '仅图标态 3 px',
    );
    expect(
      divider.width,
      divider.thickness,
      reason: 'width 不一起给，thickness 会被 SizedBox(width) 夹回去 —— 第一次改就栽在这',
    );
  });

  testWidgets('旧口径确实是「看不见」：outlineVariant 对背景不到 3:1', (
    WidgetTester tester,
  ) async {
    // 这条不是测实现，是**钉住判据**：证明「加粗到 2 却仍看不出」的根因在颜色。
    final Color background = theme().scaffoldBackgroundColor;
    expect(
      contrast(theme().colorScheme.outlineVariant, background),
      lessThan(3.0),
      reason: '如果哪天主题把 outlineVariant 调深了，这条会红 —— 那时可以重新评估要不要 3 px',
    );
  });

  testWidgets('宽屏常态不动：1 px、颜色交给主题', (WidgetTester tester) async {
    final VerticalDivider divider = await render(tester, false);
    expect(divider.thickness, 1);
    expect(divider.width, 1);
    expect(
      divider.color,
      isNull,
      reason: '宽屏 220 px 的导航列有留白说边界，跟着加深会显得笨',
    );
  });
}
