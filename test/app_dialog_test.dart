// 弹窗内边距（2026-11-27，批 0 结论落地）。
//
// 真问题不是溢出：`AlertDialog` 会把左右/上内边距乘一个**随字号反向收缩**的系数
// （2.0 档只剩 1/3），24 px → 8 px，于是标题与按钮贴着边框。
// 这里把「1.0 / 2.0 档的实际内边距」都钉住，并保留一条**对照**（裸 `AlertDialog`）
// 证明 8 px 的坑是真的存在。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/app_dialog.dart';

void main() {
  Widget host(Widget dialog, {double scale = 1.0}) => MaterialApp(
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: Builder(
          builder: (BuildContext context) => ElevatedButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (BuildContext _) => dialog,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  /// 卡片左边 → 标题左边的像素距（= 实际左内边距）
  Future<double> leftPaddingOf(WidgetTester tester) async {
    // ⚠️ 不能用 `AlertDialog` / `Dialog` 的 rect —— 它们的渲染盒是**整屏**
    //（内部是 AnimatedPadding + Align）。卡片本体是包住标题的那个 `Material`。
    final Rect card = tester.getRect(
      find
          .ancestor(of: find.text('确认退货？'), matching: find.byType(Material))
          .first,
    );
    final Rect title = tester.getRect(find.text('确认退货？'));
    return title.left - card.left;
  }

  testWidgets('AppDialog：1.0 档实际左内边距仍是 24', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      host(const AppDialog(title: Text('确认退货？'), content: Text('退掉之后不能撤销。'))),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(await leftPaddingOf(tester), closeTo(24, 1));
  });

  testWidgets('AppDialog：2.0 档**不再缩成 8 px**（仍是 24）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      host(
        const AppDialog(title: Text('确认退货？'), content: Text('退掉之后不能撤销。')),
        scale: 2.0,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      await leftPaddingOf(tester),
      closeTo(24, 1),
      reason: '批 0 实测：裸 AlertDialog 在 2.0 档只剩 8 px（字贴着边框）',
    );
  });

  testWidgets('对照：裸 AlertDialog 在 2.0 档确实只剩 1/3 内边距', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      host(
        // 刻意用裸 AlertDialog —— 这条是**反证**，说明为什么必须换成 AppDialog
        const AlertDialog(title: Text('确认退货？'), content: Text('退掉之后不能撤销。')),
        scale: 2.0,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      await leftPaddingOf(tester),
      lessThan(12),
      reason: '框架把 24 px 压到约 8 px —— 这就是"几乎撑破对话框"的来源',
    );
  });
}
