// 根应用的 widget 测试。
//
// ⚠️ **只测不需要插件、不碰真实配置的东西。** 启动流程会真弹系统框、
// 默认配置落在真实 `%APPDATA%` —— 那些在 widget 测试里都会炸（或越红线）。
// 启动流程本身在 `test/startup_test.dart`（注入 `pickDirectory` + 沙箱
// `configStore`），更底层的判断在 `packages/shensuanzi_app`（`dart test`）。
//
// 这里能测的、也正是最该测的：**左侧导航的入口是否常驻可见**、
// **沉浸模式是否真的不显示面包屑**、**设置页是不是真页面** ——
// 这些是 `docs/ui_principles.md` 的硬规则，值得用测试钉住而不是靠人眼看截图。
//
// §AI-1（2026-09-29）：AppShell 的 `configStore` / `onConfigChanged` 改为
// **必传**（生产入口不注入曾是「设置页永远是占位页」的根因），所以本文件的
// shell 也必须给一个沙箱实例（临时目录，纯 dart:io，用完即删）。
//
// 运行：`flutter test`（本机由用户执行）

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/app_shell.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

void main() {
  // 沙箱配置（testing.md §K 红线：绝不指向真实 %APPDATA%）
  final Directory box = Directory.systemTemp.createTempSync(
    'shensuanzi_shell_test_',
  );
  final AppConfigStore store = AppConfigStore(
    File(p.join(box.path, 'config.json')),
  );

  tearDownAll(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉（占用等）不影响结论
    }
  });

  Widget shell({bool databaseReady = true}) => MaterialApp(
    home: AppShell(
      dataDirectory: r'D:\神算子数据',
      backupDirectory: r'D:\神算子备份',
      schemaVersion: 1,
      databaseReady: databaseReady,
      configStore: store,
      onConfigChanged: (AppConfig config) {},
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

  // §AI-1 回归：生产入口不注入任何东西时，设置页曾因 AppShell 拿到 null
  // 而永远显示「正在开发」占位页。configStore 改必传后这条占位分支已删除，
  // 这里钉住「点设置 → 看到的是真页面」。
  testWidgets('点「设置」→ 是真页面（界面大小可调），不是「正在开发」占位', (WidgetTester tester) async {
    await tester.pumpWidget(shell());
    await tapNav(tester, 'settings');

    expect(find.byKey(const Key('setting-scale')), findsOneWidget);
    expect(find.text('设置：正在开发'), findsNothing);
  });
}
