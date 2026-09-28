// 帮助页（`HelpPage`）的 widget 测试。
//
// 纯静态页 —— 测的是「该有的内容都在」：四步上手（期初录入选第一步，遗漏 4）/
// FAQ 覆盖期初成本 0（AB-2 第三层）/ 反馈真实地址（遗漏 3）/ 版本号（遗漏 6）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/help_page.dart';

void main() {
  Widget page() => MaterialApp(home: Scaffold(body: HelpPage()));

  testWidgets('四步上手：期初录入选第一步（遗漏 4）', (WidgetTester tester) async {
    await tester.pumpWidget(page());

    expect(find.text('1️⃣'), findsOneWidget);
    expect(find.text('录入现有货物'), findsOneWidget);
    expect(find.textContaining('第一次需要做'), findsOneWidget);
    expect(find.text('采购入库 / 销售开单'), findsOneWidget);
  });

  testWidgets('FAQ 覆盖「期初成本为什么是 0」（AB-2 第三层）', (WidgetTester tester) async {
    await tester.pumpWidget(page());

    expect(find.textContaining('期初录入后'), findsOneWidget);
    expect(find.textContaining('待校准'), findsOneWidget);
  });

  testWidgets('反馈入口给真实地址；版本号在底部（遗漏 3/6）', (WidgetTester tester) async {
    await tester.pumpWidget(page());

    expect(find.textContaining('github.com'), findsOneWidget);
    expect(find.textContaining('@163.com'), findsOneWidget);
    expect(find.textContaining('v0.1.0'), findsOneWidget);
  });

  testWidgets('FAQ 覆盖数据位置与换电脑（个体户最关心的两类问题）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());

    expect(find.textContaining('数据存在哪里'), findsOneWidget);
    expect(find.textContaining('换电脑'), findsOneWidget);
  });
}
