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
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/overview_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  Widget page({
    String? reminder,
    Future<BackupOutcome> Function()? onBackupNow,
    bool mobileShell = false,
    QueryDao? queries,
    PendingMarks? pendingMarks,
    void Function(String destinationId)? onNavigate,
  }) => MaterialApp(
    home: Scaffold(
      body: OverviewPage(
        dataDirectory: r'D:\神算子数据',
        backupDirectory: r'D:\神算子备份',
        schemaVersion: 1,
        databaseReady: true,
        backupReminder: reminder,
        onBackupNow: onBackupNow,
        mobileShell: mobileShell,
        // #32：经营速览三卡
        queries: queries,
        pendingMarks: pendingMarks,
        onNavigate: onNavigate,
      ),
    ),
  );

  // ===== #32 夹具：临时库 + 真实落库通路 =====
  late Directory box;
  late Db db;

  Future<QueryDao> seedBiz({
    required int todayMs,
    bool withReceivable = false,
    bool oversell = false,
  }) async {
    useLocalSqlite();
    box = Directory.systemTemp.createTempSync('shensuanzi_overview_');
    addTearDown(() {
      db.close();
      box.deleteSync(recursive: true);
    });
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    final QueryDao queries = QueryDao(db);
    final ProductDao products = ProductDao(db);
    final int t0 = todayMs;
    final Product product = Product(
      id: newId(),
      code: 'P001',
      name: '红富士苹果',
      unit: '斤',
      costPrice: 350,
      sellPrice: 1000,
      createdAt: t0,
      updatedAt: t0,
    );
    products.insert(product);

    final RuleEngine engine = RuleEngine(db);
    final PurchaseService purchases = PurchaseService(
      engine: engine,
      queries: queries,
    );
    final SaleService sales = SaleService(engine: engine, queries: queries);
    final DeliveryService deliveries = DeliveryService(
      engine: engine,
      queries: queries,
    );

    final Account cash = Account(
      id: newId(),
      name: '现金',
      type: AccountType.cash,
      createdAt: t0,
      updatedAt: t0,
    );
    AccountDao(db).insert(cash);

    // 客户甲：送货必选客户；赊账销售也走他
    final Party jia = Party(
      id: newId(),
      name: '客户甲',
      roles: const <PartyRole>[PartyRole.customer],
      createdAt: t0 + 1,
      updatedAt: t0 + 1,
    );
    PartyDao(db).insert(jia);

    final int stockIn = oversell ? 2 : 10;
    purchases.create(
      PurchaseDraft(
        date: '2026-10-17',
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: product.id,
            productName: '红富士苹果',
            quantity: '$stockIn',
            unitPrice: '3.50',
          ),
        ],
        payments: <PurchasePaymentDraft>[
          PurchasePaymentDraft(
            accountId: cash.id,
            amount: Money.format(stockIn * 350),
          ),
        ],
      ),
      now: t0,
    );

    if (withReceivable) {
      // 赊账销售给客户甲（应收 12.00）
      sales.create(
        SaleDraft(
          partyId: jia.id,
          partyName: '客户甲',
          date: '2026-10-17',
          lines: <SaleLineDraft>[
            SaleLineDraft(
              productId: product.id,
              productName: '红富士苹果',
              quantity: '2',
              unitPrice: '6.00',
              entryUnit: '斤',
              baseUnit: '斤',
            ),
          ],
        ),
        now: t0 + 1,
      );
    } else {
      // 散客现结（不产生应收）
      sales.create(
        SaleDraft(
          date: '2026-10-17',
          lines: <SaleLineDraft>[
            SaleLineDraft(
              productId: product.id,
              productName: '红富士苹果',
              quantity: oversell ? '5' : '1',
              unitPrice: '10.00',
              entryUnit: '斤',
              baseUnit: '斤',
            ),
          ],
          payments: <SalePaymentDraft>[
            SalePaymentDraft(
              accountId: cash.id,
              amount: oversell ? '50.00' : '10.00',
            ),
          ],
        ),
        now: t0 + 2,
      );
    }

    // 送货（未签收 ⇒ in_transit）
    deliveries.create(
      DeliveryDraft(
        partyId: jia.id,
        partyName: '客户甲',
        date: '2026-10-17',
        lines: <DeliveryLineDraft>[
          DeliveryLineDraft.fromProduct(product, quantity: '3'),
        ],
      ),
      now: t0 + 3,
    );
    return queries;
  }

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

  // M05（2026-10-08）：手机上概览页复用桌面页，但**导航形态不同** ——
  // 桌面是左侧常驻列表，手机是底部导航。同一句话在两套壳里说错地方就是错的。
  testWidgets('M05：桌面壳 ⇒ 指路「左边」，手机壳 ⇒ 指路「底部」', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    expect(find.textContaining('左边的功能列表'), findsOneWidget);
    expect(find.textContaining('底部的按钮'), findsNothing);

    await tester.pumpWidget(page(mobileShell: true));
    expect(find.textContaining('底部的按钮'), findsOneWidget);
    expect(
      find.textContaining('左边的功能列表'),
      findsNothing,
      reason: '手机上写「左边的功能列表」正是 M05 报的错',
    );
  });
  // ===== #32（2026-10-17 裁定甲）：经营速览三卡 =====

  testWidgets('#32：有单 ⇒ 今日经营两行 + 要留心应收 + 快捷入口跳转', (
    WidgetTester tester,
  ) async {
    final int todayMs = DateTime.now().millisecondsSinceEpoch;
    final QueryDao queries = await seedBiz(
      todayMs: todayMs,
      withReceivable: true,
    );
    final List<String> navigated = <String>[];

    await tester.pumpWidget(
      page(queries: queries, onNavigate: navigated.add),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('overview-card-today')), findsOneWidget);
    // 赊销 2×6.00 = 12.00；送货 3×10.00 = 30.00 挂账给客户甲 ⇒ 应收 42.00
    expect(find.text('店内销售 1 笔 · ¥12.00'), findsOneWidget);
    expect(find.text('送货 1 笔 · ¥30.00（未签收 1 张）'), findsOneWidget);
    expect(find.textContaining('应收合计 ¥42.00（1 家未结）'), findsOneWidget);
    expect(find.textContaining('其中 客户甲 ¥42.00'), findsOneWidget);
    // 标题带「按单据日期」（裁定②：补录单不进今日的口径说明）
    expect(find.text('今日销售（按单据日期）'), findsOneWidget);

    // 快捷入口（裁定③：高频动作）→ 回调收到 destinationId
    await tester.tap(find.byKey(const Key('overview-go-sale')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('overview-go-purchase')));
    await tester.pumpAndSettle();
    expect(navigated, <String>['sale', 'purchase']);
  });

  testWidgets('#32：空库（无单据）⇒ 经营块整块不显示（不干扰首次开张）', (
    WidgetTester tester,
  ) async {
    useLocalSqlite();
    final Directory emptyBox = Directory.systemTemp.createTempSync(
      'shensuanzi_overview_empty_',
    );
    addTearDown(() => emptyBox.deleteSync(recursive: true));
    final Db empty = Db.open(p.join(emptyBox.path, 'shensuanzi.db'));
    addTearDown(empty.close);

    await tester.pumpWidget(page(queries: QueryDao(empty)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('overview-card-today')), findsNothing);
    expect(find.byKey(const Key('overview-card-care')), findsNothing);
    expect(find.byKey(const Key('overview-card-entries')), findsNothing);
  });

  testWidgets('#32：手机未同步 ⇒ 「仅已同步 · 有 N 条未同步」；桌面不显示', (
    WidgetTester tester,
  ) async {
    final int todayMs = DateTime.now().millisecondsSinceEpoch;
    final QueryDao queries = await seedBiz(todayMs: todayMs);
    // 队列里 1 条未确认（pending）—— 模拟手机开单还没推
    final SyncQueueDao queue = SyncQueueDao(db);
    queue.enqueue(
      SyncQueueEntry.create(
        SyncOperation(
          entity: Schema.products,
          entityId: 'px',
          operation: SyncOpType.createMasterData,
          payload: <String, Object?>{'id': 'px', 'name': 'x'},
        ),
        now: todayMs,
      ),
    );

    await tester.pumpWidget(
      page(
        queries: queries,
        pendingMarks: PendingMarks(queue),
        mobileShell: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('仅已同步 · 有 1 条未同步'), findsOneWidget);

    // 桌面（无 pendingMarks）不显示该行
    await tester.pumpWidget(page(queries: queries));
    await tester.pumpAndSettle();
    expect(find.textContaining('未同步'), findsNothing);
  });

  testWidgets('#32：负库存 ⇒ 红字提醒（超卖场景）', (
    WidgetTester tester,
  ) async {
    final int todayMs = DateTime.now().millisecondsSinceEpoch;
    final QueryDao queries = await seedBiz(todayMs: todayMs, oversell: true);

    await tester.pumpWidget(page(queries: queries));
    await tester.pumpAndSettle();
    expect(find.textContaining('负库存 1 种'), findsOneWidget);
  });

}
