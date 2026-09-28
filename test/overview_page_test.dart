// 概览页（`OverviewPage`）的 widget 测试。
//
// 覆盖 §AE-3（数据安全橙卡的**两层机制**：自动失败静默、但要被用户看见）+
// 遗漏 5（SnackBar 带完整路径）+ 遗漏 11（按钮防抖）。
//
// ⚠️ 这里**不复制文案逻辑**：`backupReminder` 由纯 Dart 的
// `backupReminderText` 给出（那边有 `dart test` 覆盖），本文件只钉
// 「摆得对不对」—— 断言用**精确文本**或 Key，避免与提醒文案里的
// 「立即备份」四个字撞车。
//
// 运行：`flutter test`（本机由用户执行）
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/overview_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

void main() {
  Widget page({
    String? reminder,
    Future<BackupOutcome> Function()? onBackupNow,
  }) => MaterialApp(
    home: Scaffold(
      body: OverviewPage(
        dataDirectory: r'D:\神算子数据',
        backupDirectory: r'D:\神算子备份',
        schemaVersion: 1,
        databaseReady: true,
        backupReminder: reminder,
        onBackupNow: onBackupNow,
      ),
    ),
  );

  final Finder card = find.byKey(const Key('overview-backup-now'));

  testWidgets('没有提醒 → 不出现橙卡（不该打扰有备份的人）', (WidgetTester tester) async {
    await tester.pumpWidget(page());

    expect(card, findsNothing);
    expect(find.text('立即备份'), findsNothing);
    // 原有的「数据在哪」照旧
    expect(find.text(r'D:\神算子数据'), findsOneWidget);
    expect(find.textContaining(r'D:\神算子备份'), findsOneWidget);
    expect(find.textContaining('数据文件已就绪'), findsOneWidget);
  });

  testWidgets('有提醒 → 橙卡 + 「立即备份」按钮（AE-3 两层机制的上层）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      page(
        reminder: '数据已经 5 天没有备份了。',
        onBackupNow: () async =>
            const BackupOutcome.ok(r'D:\神算子备份\a.db'),
      ),
    );

    expect(find.text('数据已经 5 天没有备份了。'), findsOneWidget);
    expect(card, findsOneWidget);
    expect(find.text('立即备份'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('提醒在但备份不可用（库没就绪）→ 只说事，不给空按钮', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page(reminder: '还没有备份过。'));

    expect(find.text('还没有备份过。'), findsOneWidget);
    expect(card, findsNothing, reason: 'onBackupNow == null → 不摆按钮');
  });

  testWidgets('点「立即备份」→ 回调一次 + SnackBar 带完整路径（遗漏 5）', (
    WidgetTester tester,
  ) async {
    var calls = 0;
    const String path =
        r'D:\神算子备份\shensuanzi-m-schema1-20260928-1530.db';
    await tester.pumpWidget(
      page(
        reminder: '还没有备份过。',
        onBackupNow: () async {
          calls++;
          return const BackupOutcome.ok(path);
        },
      ),
    );

    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(
      find.textContaining(path),
      findsOneWidget,
      reason: 'SnackBar 必须带完整路径（用户可复制到文件管理器）',
    );
  });

  testWidgets('备份失败 → SnackBar 直接说「怎么办」（领域层文案）', (WidgetTester tester) async {
    await tester.pumpWidget(
      page(
        reminder: '还没有备份过。',
        onBackupNow: () async => const BackupOutcome.failure(
          '备份文件夹用不了。请检查它是不是被删掉、被设成只读，或者磁盘满了',
        ),
      ),
    );

    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(find.textContaining('备份文件夹用不了'), findsOneWidget);
  });

  testWidgets('点下去立刻禁用 +「备份中…」（遗漏 11，防连点）', (WidgetTester tester) async {
    final Completer<BackupOutcome> gate = Completer<BackupOutcome>();
    var calls = 0;
    await tester.pumpWidget(
      page(
        reminder: '还没有备份过。',
        onBackupNow: () {
          calls++;
          return gate.future;
        },
      ),
    );

    await tester.tap(card);
    await tester.pump();

    expect(find.text('备份中…'), findsOneWidget);
    expect(find.text('立即备份'), findsNothing, reason: '进行中就不能再点');

    // 进行中再点一次：页面自己拦住（不能靠服务侧的单飞兜）
    await tester.tap(find.byKey(const Key('overview-backup-now')));
    await tester.pump();
    expect(calls, 1);

    gate.complete(const BackupOutcome.ok(r'D:\神算子备份\a.db'));
    await tester.pump();
    await tester.pump();
    expect(find.text('立即备份'), findsOneWidget, reason: '完成后按钮恢复可用');
  });
}
