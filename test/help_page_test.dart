// 帮助页（`HelpPage`）的 widget 测试。
//
// 内容基本静态 —— 测的是「该有的内容都在」：四步上手（期初录入选第一步，遗漏 4）/
// FAQ 覆盖期初成本 0（AB-2 第三层）/ 反馈真实地址（遗漏 3）/ 版本号（遗漏 6）/
// 备份与恢复（§AE-6 六步 + 遗漏 8 同盘风险）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/help_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

void main() {
  Widget page({String? dataDirectory, String? backupDirectory}) => MaterialApp(
    home: Scaffold(
      body: HelpPage(
        dataDirectory: dataDirectory,
        backupDirectory: backupDirectory,
      ),
    ),
  );

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
    // §AG-1：版本号**从 AppVersion 取**，且带「（第一个可部署版本）」限定词 ——
    // 断言直接用那唯一来源，避免测试再手写一遍版本号
    expect(find.textContaining(AppVersion.display), findsOneWidget);
  });

  testWidgets('FAQ 覆盖「打开时的蓝色警告」（§AG-3）', (WidgetTester tester) async {
    await tester.pumpWidget(page());

    expect(find.textContaining('蓝色警告'), findsOneWidget);
    expect(find.textContaining('仍要运行'), findsOneWidget);
    expect(
      find.textContaining('只需要做一次'),
      findsOneWidget,
      reason: '这句回答的是「我每次打开都要这么麻烦吗」—— 不写用户会以为每次都弹',
    );
  });

  testWidgets('FAQ 覆盖数据位置与换电脑（个体户最关心的两类问题）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());

    expect(find.textContaining('数据存在哪里'), findsOneWidget);
    expect(find.textContaining('换电脑'), findsOneWidget);
  });

  // ---------------------------------------------------------------- §AE-6

  testWidgets('恢复 FAQ 是六步、写在用户能照做的程度（§AE-6）', (WidgetTester tester) async {
    await tester.pumpWidget(
      page(
        dataDirectory: r'D:\神算子数据',
        backupDirectory: r'D:\神算子备份',
      ),
    );

    expect(find.textContaining('1. 先关掉神算子'), findsOneWidget);
    expect(find.textContaining('6. 重新打开神算子'), findsOneWidget);
    expect(
      find.textContaining('shensuanzi.db.bak'),
      findsOneWidget,
      reason: '「先改名成 .bak 再粘贴」是用户的心理安全带，不能省',
    );
    // 真实路径要插进去 —— 只说「去设置页看」用户照做不下去
    expect(find.textContaining(r'D:\神算子备份'), findsOneWidget);
    expect(find.textContaining(r'D:\神算子数据'), findsOneWidget);
  });

  testWidgets('没传路径 → 退回「到设置页看」，不编造路径', (WidgetTester tester) async {
    await tester.pumpWidget(page());

    expect(find.textContaining('「设置」页里「备份位置」显示的那个文件夹'), findsOneWidget);
    expect(find.textContaining('「设置」页里「数据位置」显示的那个文件夹'), findsOneWidget);
  });

  testWidgets('坦白「备份和数据在同一块硬盘」（§AE 遗漏 8）', (WidgetTester tester) async {
    await tester.pumpWidget(page());

    expect(find.textContaining('不是「硬盘坏了」'), findsOneWidget);
    // ⚠️ 用**完整短语**而不是裸「U 盘」——§AF 的「怎么把数据给会计」也提到 U 盘，
    // 裸词会命中 2 个（本文件首轮就栽在「同一段文字出现两次」上）
    expect(find.textContaining('请自己再复制一份到 U 盘'), findsOneWidget);
  });

  // ---------------------------------------------------------------- §AF

  testWidgets('导出 FAQ：导出 ≠ 备份、给会计的四步、Excel 乱码逃生门（§AF 遗漏 5/8）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());

    expect(find.textContaining('「导出」和「备份」'), findsOneWidget);
    expect(find.textContaining('不能用它恢复软件'), findsOneWidget);
    expect(find.textContaining('怎么把数据给会计'), findsOneWidget);
    expect(
      find.textContaining('导出的文件完全属于你'),
      findsOneWidget,
      reason: '§AF 六：这是立场声明，不是技术特性',
    );
    expect(find.textContaining('65001'), findsOneWidget);
  });
}
