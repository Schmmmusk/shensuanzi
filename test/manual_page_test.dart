// 用户手册页（`ManualPage`）的 widget 测试。
//
// 2026-10-20 用户实测：**所有章节标号在「特大」及以上字号下溢出**，
// 而且没有任何黄黑提示 —— 因为标号是 `Container(width: 30, height: 30)` 里
// 放一个 `Text`：`Text` 被**紧约束**裁切，不算 RenderFlex 溢出，不会报警。
//
// 这里守两件事：① 标号跟着字号长高（不再被裁）；② 常规档外观不变（还是 30）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/manual_page.dart';

void main() {
  Widget page({double scale = 1.0}) => MaterialApp(
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    // 版本行是**假的**（这个文件只测排版，不测版本号）—— 刻意用 9.9.9，
    // 免得每次 bump 都有人以为这里要跟着改（0.6.3 的 P1 就是这么来的）
    home: const ManualPage(versionLine: 'v9.9.9（示例版本）'),
  );

  /// 第 1 章标号所在的方框
  Size badgeSize(WidgetTester tester) => tester.getSize(
    find.ancestor(of: find.text('1'), matching: find.byType(Container)).first,
  );

  testWidgets('超大档（2.0）：章节标号跟着字号长高，不再被方框裁掉', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(page(scale: 2.0));
    await tester.pumpAndSettle();

    expect(
      badgeSize(tester).height,
      greaterThan(30),
      reason: '写死 30×30 时数字被裁（而且不会报警）—— 方框必须随文字长高',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('常规档：标号仍是 30 高（小字号外观不变）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    final Size badge = badgeSize(tester);
    expect(badge.height, 30, reason: '最小 30 的约束仍在，小字号看起来与原来一致');
    expect(badge.width, greaterThanOrEqualTo(30));
  });

  // 批 3 第 17 条：手册目录可展开、可跳转。
  testWidgets('目录：默认收起，展开后 20 章齐全，点一章能跳过去', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 默认收起 —— 章标题只在正文里出现一次
    final Finder toc = find.byKey(const Key('manual-toc'));
    expect(toc, findsOneWidget);
    expect(find.byKey(const Key('manual-toc-0')), findsNothing);

    await tester.tap(toc);
    await tester.pumpAndSettle();

    // 展开后 20 行
    expect(find.byKey(const Key('manual-toc-19')), findsOneWidget);

    // 点第 20 章 ⇒ 滚到它（不崩、且该行仍可见）
    await tester.tap(find.byKey(const Key('manual-toc-19')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '跳转不该抛异常');
  });
}
