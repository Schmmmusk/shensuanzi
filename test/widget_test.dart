// 根应用的 widget 测试。
//
// ⚠️ **只测不需要磁盘与插件的东西。** 启动流程会读配置、可能弹对话框、
// 还会调文件夹选择器插件 —— 那些在 widget 测试里都会炸（或需要 mock）。
// 启动逻辑本身在 `packages/shensuanzi_app`，由那边的 `dart test` 覆盖。
//
// 运行：`flutter test`（本机由用户执行）

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/home_page.dart';

void main() {
  testWidgets('主界面把「数据在哪」说清楚，并列出待实现的核心闭环', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HomePage(
          dataDirectory: r'D:\神算子数据',
          backupDirectory: r'D:\神算子备份',
          schemaVersion: 1,
          databaseReady: true,
        ),
      ),
    );

    expect(find.text(r'D:\神算子数据'), findsOneWidget);
    expect(find.textContaining(r'D:\神算子备份'), findsOneWidget);
    expect(find.textContaining('数据文件已就绪'), findsOneWidget);

    // 闭环入口必须**常驻可见 + 带文字**（`docs/ui_principles.md` §1.1）
    expect(find.text('商品建档'), findsOneWidget);
    expect(find.text('销售开单'), findsOneWidget);
    expect(find.text('待实现'), findsWidgets);
  });

  testWidgets('数据库没就绪 → 给出「怎么办」，而不是只说哪里错', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HomePage(
          dataDirectory: r'D:\神算子数据',
          backupDirectory: r'D:\神算子备份',
          schemaVersion: 1,
          databaseReady: false,
        ),
      ),
    );

    expect(find.textContaining('换一个位置'), findsOneWidget);
  });
}
