// F12（2026-10-25 复跑；裁定 D4 甲）：全仓统一的 SnackBar 出口。
//
// 复跑实测「提示久不消退」= ① 不清理上一条（Flutter 是串行排队）+ ② 时长没规矩
// （6 秒 ×13 / 8 秒 ×7 / 4 秒 ×4 / 3 秒 ×3 / 2 秒 ×2）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/notice.dart';

void main() {
  late BuildContext ctx;

  Widget host() => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => ctx = context,
          child: const Text('tap'),
        ),
      ),
    ),
  );

  Future<void> openContext(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('tap'));
    await tester.pump();
  }

  testWidgets('连续两条提示 ⇒ 只留最后一条（先清队，不排队）', (WidgetTester tester) async {
    await openContext(tester);

    showNotice(ctx, '第一条');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('第一条'), findsOneWidget);

    showNotice(ctx, '第二条');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('第二条'),
      findsOneWidget,
      reason: '第二条要立刻顶上来',
    );
    expect(
      find.text('第一条'),
      findsNothing,
      reason: 'F12：前一条必须被 removeCurrentSnackBar 清掉，不能排在后面等',
    );
  });

  testWidgets('时长只有两档：普通 3 秒、长文案 6 秒', (WidgetTester tester) async {
    await openContext(tester);

    showNotice(ctx, '普通一句');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(seconds: 3),
    );

    showNotice(ctx, '这句要说清怎么办', long: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(seconds: 6),
    );
  });

  testWidgets('调用方写 8 秒也会被归一化到 6 秒（规矩收在一处，不靠 38 个调用点守）', (
    WidgetTester tester,
  ) async {
    await openContext(tester);

    showSnack(
      ctx,
      const SnackBar(
        content: Text('老的 8 秒调用'),
        duration: Duration(seconds: 8),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(seconds: 6),
    );
  });
}
