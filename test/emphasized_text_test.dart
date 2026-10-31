// `EmphasizedText` 的渲染 —— 2026-10-31 真机。
//
// ## 这条测试钉的是**屏幕上那一层**
//
// 解析（`emphasisSegments`）在 `packages/shensuanzi_app` 里单独测；这里只回答
// 一件事：**用户看到的那段文字里还有没有 `**`**。真机反馈原话：
// 「现在的『怎么办』对话框里就有 md 语法」。
//
// 所以断言分两步：
// 1. `RichText` 的 `toPlainText()` 里**不含 `**`**（这是用户能看见的全文）；
// 2. 确实有一段是粗体（不是把星号删了了事 —— 那会丢掉「这句最要紧」的意图）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/emphasized_text.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  /// 取出渲染后的纯文本（`Text.rich` 走 `RichText`；普通 `Text` 也能找到）
  String plainText(WidgetTester tester) {
    final RichText rich = tester.widget<RichText>(find.byType(RichText).last);
    return rich.text.toPlainText();
  }

  /// 递归收集所有叶子 TextSpan（`Text.rich` 外面还套着一层，别假设层级）
  List<TextSpan> leaves(InlineSpan span) {
    if (span is! TextSpan) return <TextSpan>[];
    final List<TextSpan> out = <TextSpan>[];
    if (span.text != null) out.add(span);
    for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
      out.addAll(leaves(child));
    }
    return out;
  }

  testWidgets('带 ** 的文案：屏幕上不出现星号，且有粗体片段', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(const EmphasizedText('先说清楚：**你的账没有丢**。手机上的单据都在。')),
    );

    expect(plainText(tester), '先说清楚：你的账没有丢。手机上的单据都在。');
    expect(plainText(tester).contains('**'), isFalse, reason: '星号漏到屏幕上了');

    final TextSpan root =
        tester.widget<RichText>(find.byType(RichText).last).text as TextSpan;
    final TextSpan strong = leaves(
      root,
    ).firstWhere((TextSpan s) => s.text == '你的账没有丢');
    expect(strong.style?.fontWeight, FontWeight.w700, reason: '最要紧那句要真的加粗');
  });

  testWidgets('没有 ** 的文案 ⇒ 退化成普通 Text（`find.text` 仍能命中）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(wrap(const EmphasizedText('你的账没有丢。')));
    expect(find.text('你的账没有丢。'), findsOneWidget);
    expect(plainText(tester), '你的账没有丢。');
  });

  testWidgets('大字号下不溢出（200% 是仓内硬纪律）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      wrap(
        const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: Padding(
            padding: EdgeInsets.all(12),
            child: EmphasizedText('先说清楚：**你的账没有丢**。手机上的单据、库存都是从电脑同步过来的。'),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull, reason: '200% 字号下不许溢出');
  });
}
