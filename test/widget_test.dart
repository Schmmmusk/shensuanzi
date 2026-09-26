// 根应用的 widget 测试。
//
// ⚠️ **只测不需要磁盘与插件的东西。** 启动流程会读配置、可能弹对话框、
// 还会调文件夹选择器插件 —— 那些在 widget 测试里都会炸（或需要 mock）。
// 启动逻辑本身在 `packages/shensuanzi_app`，由那边的 `dart test` 覆盖。
//
// 这里能测的、也正是最该测的：**左侧导航的入口是否常驻可见**、
// **沉浸模式是否真的不显示面包屑** —— 这两条是 `docs/ui_principles.md`
// 的硬规则，值得用测试钉住而不是靠人眼看截图。
//
// 运行：`flutter test`（本机由用户执行）

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/app_shell.dart';

void main() {
  Widget shell({bool databaseReady = true}) => MaterialApp(
    home: AppShell(
      dataDirectory: r'D:\神算子数据',
      backupDirectory: r'D:\神算子备份',
      schemaVersion: 1,
      databaseReady: databaseReady,
    ),
  );

  Future<void> tapNav(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey<String>('nav-$id')));
    await tester.pumpAndSettle();
  }

  testWidgets('左侧导航把所有入口常驻显示，且每个都带文字标签', (WidgetTester tester) async {
    await tester.pumpWidget(shell());

    // 这条断言就是「所有功能必须有常驻可见的入口 + 文字标签」的可执行版本
    for (final String label in <String>[
      '概览',
      '销售开单',
      '采购入库',
      '商品',
      '库存',
      '单据',
      '往来方',
      '账户',
      '设置',
      '帮助',
    ]) {
      expect(find.text(label), findsWidgets, reason: '入口「$label」必须在界面上可见');
    }
  });

  testWidgets('默认停在概览，并把「数据在哪」说清楚', (WidgetTester tester) async {
    await tester.pumpWidget(shell());

    expect(find.text(r'D:\神算子数据'), findsOneWidget);
    expect(find.textContaining(r'D:\神算子备份'), findsOneWidget);
    expect(find.textContaining('数据文件已就绪'), findsOneWidget);
  });

  testWidgets('点「商品」→ 内容区切过去，概览的内容消失', (WidgetTester tester) async {
    await tester.pumpWidget(shell());
    await tapNav(tester, 'products');

    expect(find.textContaining('数据文件还没就绪'), findsOneWidget);
    expect(find.textContaining('数据文件已就绪'), findsNothing);
    // 概览只剩导航里那一个（内容区已经换掉了）
    expect(find.text('概览'), findsOneWidget);
  });

  testWidgets('商品页：数据库没就绪时给出「怎么办」，不是一片空白', (WidgetTester tester) async {
    await tester.pumpWidget(shell(databaseReady: false));
    await tapNav(tester, 'products');

    expect(find.textContaining('选好存放位置'), findsOneWidget);
  });

  testWidgets('开单页是沉浸模式：只剩导航项，没有面包屑', (WidgetTester tester) async {
    await tester.pumpWidget(shell());

    // 非沉浸时页面名会出现两次：导航项 + 面包屑
    await tapNav(tester, 'products');
    expect(find.text('商品'), findsNWidgets(2), reason: '导航项 + 面包屑');

    await tapNav(tester, 'sale');
    expect(find.text('销售开单：正在开发'), findsOneWidget);
    expect(
      find.text('销售开单'),
      findsOneWidget,
      reason: '沉浸模式不显示面包屑，于是只剩导航里那一个',
    );
  });

  testWidgets('数据库没就绪 → 给出「怎么办」，而不是只说哪里错', (WidgetTester tester) async {
    await tester.pumpWidget(shell(databaseReady: false));

    expect(find.textContaining('换一个位置'), findsOneWidget);
  });
}
