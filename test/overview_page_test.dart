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
import 'package:shensuanzi/src/ui/balance_bars.dart';
import 'package:shensuanzi/src/ui/month_compare.dart';
import 'package:shensuanzi/src/ui/ratio_bar.dart';
import 'package:shensuanzi/src/ui/revenue_chart.dart';
import 'package:shensuanzi/src/ui/stock_top.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

/// 按单号取 id（测试夹具用；`idOf` 在别的文件里是闭包，这里需要独立函数）。
String idOfOn(Db db, String docNo) =>
    db.raw.select('SELECT id FROM documents WHERE doc_no = ?', <Object?>[
          docNo,
        ]).first['id']!
        as String;

void main() {
  Widget page({
    String? reminder,
    Future<BackupOutcome> Function()? onBackupNow,
    bool mobileShell = false,
    QueryDao? queries,
    PendingMarks? pendingMarks,
    void Function(String destinationId)? onNavigate,
    VoidCallback? onPriceLookup,
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
        onPriceLookup: onPriceLookup,
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
    // ⚠️ 草稿的「单据日期」必须**从 `todayMs` 派生**，不能写死 `'2026-10-17'`。
    // 写死的后果（2026-10-18 真实发生）：断言按「今天」算，而单据落在写死的那天
    // ⇒ 跨日零点起这条测试**必红**，而且和真回归混在一起（狼来了）。
    // 用 `todayMs` 派生既保持「同种子同结果」，又不再耦合真实日历。
    final DateTime today = DateTime.fromMillisecondsSinceEpoch(t0);
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final String day =
        '${today.year}-${twoDigits(today.month)}-${twoDigits(today.day)}';
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
        date: day,
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
          date: day,
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
          date: day,
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
        date: day,
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

  testWidgets('有提醒 → 橙卡 + 「立即备份」按钮（AE-3 两层机制的上层）', (WidgetTester tester) async {
    await tester.pumpWidget(
      page(
        reminder: '数据已经 5 天没有备份了。',
        onBackupNow: () async => const BackupOutcome.ok(r'D:\神算子备份\a.db'),
      ),
    );

    expect(find.text('数据已经 5 天没有备份了。'), findsOneWidget);
    expect(card, findsOneWidget);
    expect(find.text('立即备份'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('提醒在但备份不可用（库没就绪）→ 只说事，不给空按钮', (WidgetTester tester) async {
    await tester.pumpWidget(page(reminder: '还没有备份过。'));

    expect(find.text('还没有备份过。'), findsOneWidget);
    expect(card, findsNothing, reason: 'onBackupNow == null → 不摆按钮');
  });

  testWidgets('点「立即备份」→ 回调一次 + SnackBar 带完整路径（遗漏 5）', (
    WidgetTester tester,
  ) async {
    var calls = 0;
    const String path = r'D:\神算子备份\shensuanzi-m-schema1-20260928-1530.db';
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
        onBackupNow: () async =>
            const BackupOutcome.failure('备份文件夹用不了。请检查它是不是被删掉、被设成只读，或者磁盘满了'),
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
  testWidgets('M05：桌面壳 ⇒ 指路「左边」，手机壳 ⇒ 指路「底部」', (WidgetTester tester) async {
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

  // 2026-10-20（用户建议）：三张经营卡**从页首挪到「从这里开始」下方** ——
  // 概览页先回答「数据在哪 / 能不能用 / 从哪开始」，经营数字是第二眼的东西。
  testWidgets('2026-10-20：经营三卡在「从这里开始」**下方**', (WidgetTester tester) async {
    final QueryDao queries = await seedBiz(
      todayMs: DateTime.now().millisecondsSinceEpoch,
      withReceivable: true,
    );
    await tester.pumpWidget(page(queries: queries, onNavigate: (_) {}));
    await tester.pumpAndSettle();

    final double yHint = tester.getTopLeft(find.text('从这里开始')).dy;
    final double yCards = tester
        .getTopLeft(find.byKey(const Key('overview-card-today')))
        .dy;
    expect(
      yCards,
      greaterThan(yHint),
      reason: '三卡必须在「从这里开始」下方（用户 2026-10-20 建议）',
    );
  });

  testWidgets('#32：有单 ⇒ 今日经营两行 + 要留心应收 + 快捷入口跳转', (WidgetTester tester) async {
    final int todayMs = DateTime.now().millisecondsSinceEpoch;
    final QueryDao queries = await seedBiz(
      todayMs: todayMs,
      withReceivable: true,
    );
    final List<String> navigated = <String>[];

    await tester.pumpWidget(page(queries: queries, onNavigate: navigated.add));
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

  testWidgets('#32：空库（无单据）⇒ 经营块整块不显示（不干扰首次开张）', (WidgetTester tester) async {
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

  // 2026-10-22（§CV·八十三 批 2 第 12 条）：**空库也要有入口**。
  // 原来「要开工？」卡长在经营三卡里，被 `hasAnyDocument()` 一起关掉 ——
  // 空库（刚装好、什么都没录）恰恰是最需要指路的时候。
  testWidgets('空库 ⇒ 「要开工？」入口仍然在，且带引导句', (WidgetTester tester) async {
    // queries = null ⇒ 没有任何流水（空库）
    await tester.pumpWidget(page(onNavigate: (_) {}));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('overview-go-sale')), findsOneWidget);
    expect(find.byKey(const Key('overview-go-purchase')), findsOneWidget);
    expect(find.byKey(const Key('overview-go-delivery')), findsOneWidget);
  });

  // 同一批：「打开文件夹」+「不会上传」承诺（报告 §2.4-5）
  testWidgets('数据位置卡：有「打开文件夹」，也有「不会上传」承诺', (WidgetTester tester) async {
    await tester.pumpWidget(page(onNavigate: (_) {}));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('overview-open-folder')), findsOneWidget);
    expect(find.text('数据只在这台电脑上，不会上传到任何地方。'), findsOneWidget);
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

  testWidgets('#32：负库存 ⇒ 红字提醒（超卖场景）', (WidgetTester tester) async {
    final int todayMs = DateTime.now().millisecondsSinceEpoch;
    final QueryDao queries = await seedBiz(todayMs: todayMs, oversell: true);

    await tester.pumpWidget(page(queries: queries));
    await tester.pumpAndSettle();
    expect(find.textContaining('负库存 1 种'), findsOneWidget);
  });

  // Q5 对比度（`docs/proposals/P2两项-对比度与点击区-方案.md`，用户裁定 ①甲）：
  // 负库存告警必须用**主题错误色** —— 实测 colorScheme.error = #BA1A1A
  // 对 #FAFAFA ≈6.19:1；旧值 Colors.red（#F44336）只有 ≈3.53:1，
  // 低于 `ui_principles.md` §二「次要文字 ≥ 4.5:1」。
  testWidgets('负库存告警色 = 主题错误色（Q5 对比度护栏）', (WidgetTester tester) async {
    final int todayMs = DateTime.now().millisecondsSinceEpoch;
    final QueryDao queries = await seedBiz(todayMs: todayMs, oversell: true);

    await tester.pumpWidget(page(queries: queries));
    await tester.pumpAndSettle();

    final Text warning = tester.widget<Text>(find.textContaining('负库存 1 种'));
    final ThemeData theme = Theme.of(tester.element(find.byType(OverviewPage)));
    expect(
      warning.style!.color,
      theme.colorScheme.error,
      reason: '必须用主题错误色（≈6.19:1）；Colors.red 只有 ≈3.53:1，不达标',
    );
    expect(
      warning.style!.color,
      isNot(Colors.red),
      reason: 'Colors.red 是全仓 lib/ 最后一处，不许回来',
    );
  });
  // 附录 B（`docs/ui-review-2026-10-21.md`）：概览页 原先**没有**大字号断言。
  // 批 3 第 18 条：前 17 项「尺寸随缩放派生」改造的机械护栏 —— 先立护栏再动尺寸。
  testWidgets('大字号（2.0）：概览页不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(960, 1000);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: '概览页在 2.0 档下溢出（附录 B 点名的结构：固定宽度 / 固定断点 / 顶部 Row）',
    );
  });

  // ③ 查价入口（真实诉求批 ③，2026-10-24，§CV·一百零四）
  testWidgets('点「查价」回调被调用；不传回调则不显示按钮', (WidgetTester tester) async {
    int opened = 0;
    await tester.pumpWidget(
      page(onNavigate: (_) {}, onPriceLookup: () => opened++),
    );
    expect(find.byKey(const Key('overview-go-price')), findsOneWidget);
    await tester.tap(find.byKey(const Key('overview-go-price')));
    expect(opened, 1);

    // 不传 ⇒ 不显示（既有装配没有这个能力时不该露一个死按钮）
    await tester.pumpWidget(page(onNavigate: (_) {}));
    expect(find.byKey(const Key('overview-go-price')), findsNothing);
  });

  // ============================================================ 经营图表（提案 54 第二批）
  group('经营图表', () {
    testWidgets('有销售 ⇒ 出现柱状图、一句人话总结，且金额写在图上', (tester) async {
      final QueryDao q = await seedBiz(
        todayMs: DateTime.now().millisecondsSinceEpoch,
      );
      await tester.pumpWidget(page(queries: q));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('overview-revenue-chart')), findsOneWidget);
      expect(
        find.byKey(const Key('overview-revenue-summary')),
        findsOneWidget,
        reason: '规则 4：图下面必有一句人话总结，不让人自己比',
      );
      expect(find.textContaining('最近 30 天合计'), findsOneWidget);
      // 柱子是自绘的 —— 断言 painter 在，而不是断言「有个图」
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is CustomPaint && w.painter is RevenueBarPainter,
        ),
        findsOneWidget,
      );
    });

    testWidgets('展开「看每天的数字」⇒ 每天一行，读屏也读得到', (tester) async {
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final QueryDao q = await seedBiz(todayMs: nowMs);
      await tester.pumpWidget(page(queries: q));
      await tester.pumpAndSettle();

      final Finder toggle = find.byKey(
        const Key('overview-revenue-daily-toggle'),
      );
      // 折叠线以下的控件点不动（2026-10-26 踩过）⇒ 先滚到可见
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      expect(find.text('看每天的数字'), findsOneWidget);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(find.text('收起每天的数字'), findsOneWidget);
      // 今天的日期行必须出现（明细是按天列的纯文本 ⇒ 读屏天然可读）
      final DateTime today = DateTime.fromMillisecondsSinceEpoch(nowMs);
      final String label =
          '${today.year}-${today.month.toString().padLeft(2, '0')}'
          '-${today.day.toString().padLeft(2, '0')}';
      expect(find.text(label), findsWidgets);
    });

    testWidgets('只有应收、没有应付 ⇒ 只画一条横条', (tester) async {
      final QueryDao q = await seedBiz(
        todayMs: DateTime.now().millisecondsSinceEpoch,
      );
      await tester.pumpWidget(page(queries: q));
      await tester.pumpAndSettle();

      // 夹具：采购已全额付款（应付 0）、送货未签收（应收 > 0）
      expect(find.byKey(const Key('overview-balance-bars')), findsOneWidget);
      expect(
        find.byKey(const Key('overview-balance-receivable')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('overview-balance-payable')),
        findsNothing,
        reason: '没有应付就不要画一条空条',
      );
    });

    // 提案 54 §三要求「先做原型，在窄窗 / 1280 / 手机三种条件下看挤不挤」。
    // 自动化版：三种尺寸各渲染一次，**不许有溢出**（溢出在测试里是异常）。
    for (final Size size in <Size>[
      const Size(900, 700), // 窄窗
      const Size(1280, 720), // 默认桌面
      const Size(390, 844), // 手机壳
    ]) {
      testWidgets('窗口 ${size.width.toInt()}×${size.height.toInt()} 下不溢出', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final QueryDao q = await seedBiz(
          todayMs: DateTime.now().millisecondsSinceEpoch,
        );
        await tester.pumpWidget(
          page(queries: q, mobileShell: size.width < 500),
        );
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason:
              '${size.width.toInt()} 宽下布局溢出了 —— '
              '要么调聚合粒度，要么调间距，别缩字号',
        );
        expect(find.byKey(const Key('overview-revenue-chart')), findsOneWidget);
      });
    }

    test('柱子上金额的**退让顺序**：先省千分位，最后才省 ¥', () {
      // 2026-10-31 真机：手机（compact）直接从「不带 ¥」起步，标签成了
      // 「534」「0.00」—— 数字失去单位。这里把优先级钉住。
      // 用假的 measure：每个字符 10px，便于精确构造「放得下 / 放不下」。
      double measure(String text) => text.length * 10.0;

      // 放得下 ⇒ 最完整的写法
      expect(chooseBarLabel(1260000, slot: 200, measure: measure), '¥12,600');
      // `¥12,600` 是 **7** 个字符 = 70px；slot-6=64 ⇒ 放不下，退到省千分位
      expect(chooseBarLabel(1260000, slot: 70, measure: measure), '¥12600');
      // ¥12600 是 6 个字符 = 60px；slot-6=54 ⇒ 还放不下，才省 ¥
      expect(chooseBarLabel(1260000, slot: 60, measure: measure), '12600');
    });

    test('柱子上方的金额：负数带负号、整数元、窄窗省 ¥', () {
      // 用户审查 2026-10-30：柱子朝下+变红还不够，金额标签本身要能表达正负。
      expect(barAmountLabel(-50000), '−¥500');
      expect(barAmountLabel(50000), '¥500');
      // ≥¥100 只写整数元（分位是噪音，且 `.00` 会在窄窗口挤掉邻居）
      expect(barAmountLabel(1260000), '¥12,600');
      expect(barAmountLabel(-1260000), '−¥12,600');
      // 窄窗口省掉 ¥（卡片标题与总结句里都有单位）
      expect(barAmountLabel(1260000, withCurrency: false), '12,600');
      // 小于 ¥1 时保留分位，否则会写成「¥0」
      expect(barAmountLabel(50), '¥0.50');
      // 太宽时退到无千分位（还是 15sp，只少两个逗号）
      expect(
        barAmountLabel(1260000, withCurrency: false, withSeparators: false),
        '12600',
      );
    });

    testWidgets('欠款横条：比例照实，小额只保证 4px 可见（不抬到 4%）', (tester) async {
      // 用户审查 2026-10-30：把比例抬到 4% 会让 ¥10 对 ¥10,000 显示成 25:1，
      // 而真实是 1000:1 —— 图会暗示错误的比例。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BalanceBarsCard(
              receivables: const ReceivablesSummary(
                totalCents: 1000, // ¥10
                partyCount: 1,
                topName: '客户甲',
                topCents: 1000,
                topActive: true,
              ),
              payables: const PayablesSummary(
                totalCents: 1000000, // ¥10,000
                partyCount: 1,
                topName: '供应商乙',
                topCents: 1000000,
                topActive: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final double payable = tester
          .getSize(find.byKey(const Key('overview-balance-payable-bar')))
          .width;
      final double receivable = tester
          .getSize(find.byKey(const Key('overview-balance-receivable-bar')))
          .width;

      expect(payable, greaterThan(100), reason: '应付是最大项 ⇒ 铺满');
      expect(
        receivable,
        4.0,
        reason:
            '¥10 对 ¥10,000 真实比例 0.1% ⇒ 按比例只有 0.x 像素，'
            '所以给 4px 可见宽度；**不能**抬到 4%（那是 40 倍失真）',
      );
    });

    testWidgets('净额为零但**有经营活动** ⇒ 不能说「没有销售记录」', (tester) async {
      // 用户审查 2026-10-30：卖 ¥50 又全退 ¥50 ⇒ 净额 0，但那天有生意。
      final Directory box2 = Directory.systemTemp.createTempSync('ssz_zero_');
      final Db db2 = Db.open(p.join(box2.path, 'zero.db'));
      addTearDown(() {
        db2.close();
        box2.deleteSync(recursive: true);
      });

      final int t = DateTime.now().millisecondsSinceEpoch;
      final QueryDao q2 = QueryDao(db2);
      final Product product = Product(
        id: newId(),
        code: 'PZ',
        name: '苹果',
        unit: '斤',
        costPrice: 500,
        sellPrice: 1000,
        createdAt: t,
        updatedAt: t,
      );
      ProductDao(db2).insert(product);
      final Account cash = Account(
        id: newId(),
        name: '现金',
        type: AccountType.cash,
        createdAt: t,
        updatedAt: t,
      );
      AccountDao(db2).insert(cash);
      final RuleEngine engine = RuleEngine(db2);
      final SaleService sales2 = SaleService(engine: engine, queries: q2);
      final ReturnService returns2 = ReturnService(engine: engine, queries: q2);
      final DateTime today = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final String day = '${today.year}-${two(today.month)}-${two(today.day)}';

      // 赊账销售 + 挂账退货（不涉及退款）⇒ 净额正好 0，但那天确实做了生意
      final Party jia = Party(
        id: newId(),
        name: '客户甲',
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      );
      PartyDao(db2).insert(jia);

      final SaleSaved sale = sales2.create(
        SaleDraft(
          partyId: jia.id,
          partyName: '客户甲',
          date: day,
          lines: <SaleLineDraft>[
            SaleLineDraft(
              productId: product.id,
              productName: '苹果',
              quantity: '5',
              unitPrice: '10',
            ),
          ],
        ),
        now: t,
      );
      returns2.create(
        now: t + 1000,
        ReturnDraft(
          refDocId: idOfOn(db2, sale.docNo),
          originalDocType: DocType.sale,
          partyId: jia.id,
          partyName: '客户甲',
          lines: <ReturnLineDraft>[
            ReturnLineDraft(
              productId: product.id,
              productName: '苹果',
              quantity: '5',
              amount: '50.00',
              originalQuantity: 5,
              originalAmountCents: 5000,
            ),
          ],
        ),
      );

      await tester.pumpWidget(page(queries: q2));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('overview-revenue-empty')),
        findsNothing,
        reason: '那天确实有生意 —— 净额 0 不等于「没有销售记录」',
      );
      expect(find.textContaining('正好一样多'), findsOneWidget);
    });

    // ---------------------------------------------------------- 月度对比
    // 这一组**不依赖今天是几号**：直接构造 `MonthCompare` 渲染卡片。
    // 窗口计算本身由 `revenue_series_test` 的纯函数组钉住（含跨年、闰年、
    // 「今天 31 日、上月只有 30 天」）。
    group('月度对比卡', () {
      int dayOf(int y, int m, int d) =>
          businessDayOf(DateTime(y, m, d, 12).millisecondsSinceEpoch);

      MonthCompare build({
        required int current,
        required int prior,
        bool currentActive = true,
        bool priorActive = true,
      }) => MonthCompare(
        window: monthCompareWindow(dayOf(2026, 10, 31)),
        currentCents: current,
        priorCents: prior,
        currentHasActivity: currentActive,
        priorHasActivity: priorActive,
      );

      String summaryOf(WidgetTester tester) => tester
          .widget<Text>(find.byKey(const Key('overview-month-summary')))
          .data!;

      Future<void> pump(WidgetTester tester, MonthCompare c) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: MonthCompareCard(compare: c)),
          ),
        );
        await tester.pumpAndSettle();
      }

      testWidgets('默认用**倍数**：多 ¥X，是上月的 1.3 倍', (tester) async {
        // 2026-10-31 真机：上月 ¥140、本月 ¥973 显示「+595%」——
        // 基期小的时候百分比会爆炸，看着像涨了六倍。默认改成倍数。
        await pump(tester, build(current: 1260000, prior: 980000));
        // `Money.formatGrouped` 保留两位（全应用一致）
        expect(summaryOf(tester), '比上月同期多 ¥2,800.00，是上月的 1.3 倍。');
      });

      testWidgets('设置里切百分数 ⇒ 说「多 ¥X（+N%）」', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MonthCompareCard(
                compare: build(current: 1260000, prior: 980000),
                usePercent: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(summaryOf(tester), '比上月同期多 ¥2,800.00（+29%）。');
      });

      testWidgets('比上月少 ⇒ 说「少」，倍数小于 1', (tester) async {
        await pump(tester, build(current: 500000, prior: 1000000));
        expect(summaryOf(tester), '比上月同期少 ¥5,000.00，是上月的 0.5 倍。');
      });

      testWidgets('一样多 ⇒ 不说「多 0」', (tester) async {
        await pump(tester, build(current: 800000, prior: 800000));
        expect(summaryOf(tester), '和上月同期一样多（¥8,000.00）。');
      });

      testWidgets('上月同期为 0 ⇒ **不编百分比**，说「没法和上月比」', (tester) async {
        // 除以 0 不是 +∞%，也不是 +100% —— 那都是编出来的数。
        await pump(
          tester,
          build(current: 500000, prior: 0, priorActive: false),
        );
        final String text = summaryOf(tester);
        expect(text, contains('上月同期还没有生意'));
        expect(text, isNot(contains('%')), reason: '没有基期就没有百分比');
      });

      testWidgets('本月还没有生意 ⇒ 报上月同期的数，不说「比上月少 100%」', (tester) async {
        await pump(
          tester,
          build(current: 0, prior: 300000, currentActive: false),
        );
        expect(summaryOf(tester), '这个月还没有生意（上月同期 ¥3,000.00）。');
      });

      testWidgets('两段都没有经营活动 ⇒ 整张卡不渲染', (tester) async {
        await pump(
          tester,
          build(current: 0, prior: 0, currentActive: false, priorActive: false),
        );
        expect(find.byKey(const Key('overview-month-compare')), findsNothing);
      });

      testWidgets('两段日期都印出来（用户能自己核对是不是同期）', (tester) async {
        await pump(tester, build(current: 1260000, prior: 980000));
        // 2026-10-31 ⇒ 本月 10/1–10/31，上月同期 9/1–9/30（9 月只有 30 天）
        expect(find.text('10/1–31'), findsOneWidget);
        expect(find.text('9/1–30'), findsOneWidget);
        expect(
          find.byKey(const Key('overview-month-current-bar')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('overview-month-prior-bar')),
          findsOneWidget,
        );
      });
    });

    testWidgets('月度对比：**上月条不能与轨道同色**（真机截图发现的）', (tester) async {
      // 2026-10-31 真机：¥973 对 ¥140，两条看起来一样长 ——
      // 因为上月条用了 `dividerColor`，那正是 `RatioBar` 的轨道色，
      // 填充和轨道同色，条长等于看不见。
      final int d = businessDayOf(
        DateTime(2026, 10, 31, 12).millisecondsSinceEpoch,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => MonthCompareCard(
                compare: MonthCompare(
                  window: monthCompareWindow(d),
                  currentCents: 97300,
                  priorCents: 14000,
                  currentHasActivity: true,
                  priorHasActivity: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final RatioBar current = tester.widget<RatioBar>(
        find.descendant(
          of: find.byKey(const Key('overview-month-current')),
          matching: find.byType(RatioBar),
        ),
      );
      final RatioBar prior = tester.widget<RatioBar>(
        find.descendant(
          of: find.byKey(const Key('overview-month-prior')),
          matching: find.byType(RatioBar),
        ),
      );
      final ThemeData theme = Theme.of(
        tester.element(find.byKey(const Key('overview-month-compare'))),
      );
      expect(
        prior.color,
        isNot(theme.dividerColor),
        reason: '填充色 = 轨道色 ⇒ 条长看不出来（真机上就是这么翻车的）',
      );
      expect(prior.color, isNot(current.color), reason: '两条要能区分');
      expect(prior.color.a, lessThan(1.0), reason: '上月用浅色（弱化），本月用实色');
    });

    testWidgets('三条横条的**深浅层次**：轨道最浅 < 上月 < 本月', (tester) async {
      // 2026-10-31 真机：轨道用了 `dividerColor`（#73777F 中灰），
      // 跟填充色几乎一样深 ⇒ 整条看着都像填满，用户分不出条有多长。
      // 这里把「三层深浅」钉住：谁把轨道改深、或把上月改得跟本月一样，
      // 都会红。
      final int d = businessDayOf(
        DateTime(2026, 10, 31, 12).millisecondsSinceEpoch,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MonthCompareCard(
              compare: MonthCompare(
                window: monthCompareWindow(d),
                currentCents: 97300,
                priorCents: 14000,
                currentHasActivity: true,
                priorHasActivity: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final ThemeData theme = Theme.of(
        tester.element(find.byKey(const Key('overview-month-compare'))),
      );
      final RatioBar current = tester.widget<RatioBar>(
        find.descendant(
          of: find.byKey(const Key('overview-month-current')),
          matching: find.byType(RatioBar),
        ),
      );
      final RatioBar prior = tester.widget<RatioBar>(
        find.descendant(
          of: find.byKey(const Key('overview-month-prior')),
          matching: find.byType(RatioBar),
        ),
      );

      final Color track = RatioBar.trackColorOf(theme);
      // 半透明色要看**叠在轨道上之后**的实际观感，不能只看它自己的 RGB
      double onTrack(Color c) => Color.alphaBlend(c, track).computeLuminance();

      expect(
        track.computeLuminance(),
        greaterThan(0.7),
        reason: '轨道必须是浅色 —— 中灰轨道会让整条看起来都填满了',
      );
      expect(
        onTrack(prior.color),
        lessThan(track.computeLuminance() - 0.08),
        reason: '上月条要能从轨道里看出来',
      );
      expect(
        onTrack(current.color),
        lessThan(onTrack(prior.color) - 0.08),
        reason: '本月要比上月明显更深（三级层次：轨道 < 上月 < 本月）',
      );
    });

    testWidgets('界面缩放 125% 时，每天明细的**日期不折行**', (tester) async {
      // 2026-10-31 真机：`2026-10-20` 被折成「2026-10-2」+「0」——
      // 因为日期装在 `SizedBox(width: 92)` 里，而全局 textScaler 是 1.25。
      // 固定像素宽度 + 文字缩放 = 折行，这类写法一律不许再用。
      final int day = businessDayOf(
        DateTime(2026, 10, 20, 12).millisecondsSinceEpoch,
      );
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(1200, 900),
            textScaler: TextScaler.linear(1.25),
          ),
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: RevenueChartCard(
                  rows: <RevenueDay>[
                    RevenueDay(day: day, saleCents: 6000, documentCount: 1),
                  ],
                  fromDay: day - 6,
                  toDay: day,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('overview-revenue-daily-toggle')));
      await tester.pumpAndSettle();

      final Finder label = find.text('2026-10-20');
      expect(label, findsOneWidget);
      final double oneLine = tester.getSize(label).height;
      expect(
        oneLine,
        lessThan(34),
        reason:
            '日期占了 $oneLine 高 —— 125% 缩放下一行大约 18~20，'
            '超过 34 说明折成了两行',
      );
    });

    testWidgets('营收卡**自己裁窗口**：窗口外的天不算进合计与平均', (tester) async {
      // 概览页为「月度对比」一次查够两个窗口，所以传给营收卡的数据里
      // 可能混着 30 天窗口外的天。卡片必须自己裁 —— 否则「平均每个有生意的
      // 日子」会把上月的天算进分母（用户审查 2026-10-30 同类问题）。
      final int toDay = businessDayOf(DateTime.now().millisecondsSinceEpoch);
      final int fromDay = toDay - 29;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RevenueChartCard(
                rows: <RevenueDay>[
                  RevenueDay(
                    day: fromDay + 1,
                    saleCents: 10000,
                    documentCount: 1,
                  ),
                  // 窗口外（比窗口早 5 天），金额很大 —— 混进去会一眼看出来
                  RevenueDay(
                    day: fromDay - 5,
                    saleCents: 99900,
                    documentCount: 1,
                  ),
                ],
                fromDay: fromDay,
                toDay: toDay,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final String summary = tester
          .widget<Text>(find.byKey(const Key('overview-revenue-summary')))
          .data!;
      expect(summary, contains('合计 ¥100'), reason: '窗口外的 ¥999 不能进合计');
      expect(
        summary,
        contains('平均每个有生意的日子 ¥100'),
        reason: '分母也要裁 —— 否则是 ¥50（2 天）而不是 ¥100（1 天）',
      );
    });

    testWidgets('月度对比卡在页面上：有总结句，且与上下两张卡都留了间距', (tester) async {
      final QueryDao q = await seedBiz(
        todayMs: DateTime.now().millisecondsSinceEpoch,
      );
      await tester.pumpWidget(page(queries: q));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('overview-month-compare')), findsOneWidget);
      expect(find.byKey(const Key('overview-month-summary')), findsOneWidget);

      final Rect chart = tester.getRect(
        find.byKey(const Key('overview-revenue-chart')),
      );
      final Rect month = tester.getRect(
        find.byKey(const Key('overview-month-compare')),
      );
      expect(
        month.top - chart.bottom,
        greaterThanOrEqualTo(8),
        reason: '营收卡与月度对比卡贴在一起了',
      );
    });

    testWidgets('压货榜：金额大的排前面，数量照实写各自单位', (tester) async {
      // 用户举的反例：牙签 500 个 vs 电机 10 台 —— 按数量排牙签会排第一。
      // 这里钉的是**卡片按传入顺序渲染**（排序由 `topStockByValue` 负责，
      // 那边有 DAO 层测试），以及数量/单位**不换算、不求和**。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StockTopCard(
              summary: const StockTopSummary(
                rows: <StockValueRow>[
                  StockValueRow(
                    productId: 'motor',
                    name: '电机',
                    unit: '台',
                    quantity: 10,
                    valueCents: 100000,
                  ),
                  StockValueRow(
                    productId: 'pick',
                    name: '牙签',
                    unit: '个',
                    quantity: 500,
                    valueCents: 500,
                  ),
                ],
                uncalibratedCount: 0,
                negativeCostCount: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('overview-stock-top')), findsOneWidget);
      expect(find.textContaining('按占用资金排'), findsOneWidget);
      expect(find.text('10 台'), findsOneWidget);
      expect(find.text('500 个'), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const Key('overview-stock-top-motor'))).top,
        lessThan(
          tester.getRect(find.byKey(const Key('overview-stock-top-pick'))).top,
        ),
      );

      // 空列表 ⇒ 整张卡不渲染（不留一块空壳）
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StockTopCard(
              summary: StockTopSummary(
                rows: <StockValueRow>[],
                uncalibratedCount: 0,
                negativeCostCount: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('overview-stock-top')), findsNothing);
    });

    testWidgets('重建页面**不重新查库**（点备份不会把全历史聚合再跑一遍）', (tester) async {
      // 用户审查 2026-10-30：从前这些查询写在 `build()` 里 —— 点一下「立即备份」
      // 会 `setState` 改 `_busy`、页面重建、于是 165 ms 的全历史聚合又跑一遍，
      // 备份结束再来一遍。现在数据在 `initState` 算好缓存住。
      //
      // 断言方式：改库之后触发一次纯 UI 重建，界面**仍显示缓存值**。
      // 这不是「显示了旧数据」的 bug，而是「重建不查库」的契约。
      // 窗口调高：橙卡 + 三卡 + 图表在 600px 里放不下，`ListView` 会把
      // 屏幕外的子节点**延迟构建** ⇒ `find.byKey` 直接找不到（不是断言写错）
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final QueryDao q = await seedBiz(todayMs: nowMs);
      await tester.pumpWidget(
        page(
          queries: q,
          // ⚠️ 「立即备份」按钮只在**有提醒**时渲染（橙卡里）——
          // 不传 reminder 的话它根本不存在，`tap` 会直接抛
          reminder: '数据已经 5 天没有备份了。',
          onBackupNow: () async => const BackupOutcome.ok(r'D:/神算子备份/a.db'),
        ),
      );
      await tester.pumpAndSettle();

      final String before = tester
          .widget<Text>(find.byKey(const Key('overview-revenue-summary')))
          .data!;

      // 直接往库里塞一张销售单（绕过 UI）—— 如果重建会重新查，数字就会变
      db.raw.execute(
        'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
        'paid_amount, occurred_at, time_estimated, created_at, updated_at, '
        'business_day) VALUES (?,?,?,?,?,?,?,0,?,?,?)',
        <Object?>[
          'late-sale',
          'XS-LATE-1',
          DocType.sale.wire,
          DocStatus.confirmed.wire,
          99900,
          99900,
          nowMs,
          nowMs,
          nowMs,
          businessDayOf(nowMs),
        ],
      );

      await tester.tap(find.byKey(const Key('overview-backup-now')));
      await tester.pumpAndSettle();

      final String after = tester
          .widget<Text>(find.byKey(const Key('overview-revenue-summary')))
          .data!;
      expect(after, before, reason: '重建复用了缓存 —— 否则每次点备份都会重跑 100+ ms 的全历史聚合');
    });

    testWidgets('压货榜：**待校准 / 负成本**不进榜，但要在卡上说清', (tester) async {
      // 用户审查 2026-10-30：有货但成本 0 的商品显示「¥0.00」会让用户
      // 以为这货不要钱；负成本的横条也没有意义。两种都只报数量。
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StockTopCard(
              summary: StockTopSummary(
                rows: <StockValueRow>[
                  StockValueRow(
                    productId: 'oil',
                    name: '调和油',
                    unit: '桶',
                    quantity: 42,
                    valueCents: 1260000,
                  ),
                ],
                uncalibratedCount: 3,
                negativeCostCount: 1,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('压货最多的 1 个商品'), findsOneWidget);
      expect(
        find.byKey(const Key('overview-stock-top-uncalibrated')),
        findsOneWidget,
      );
      expect(find.textContaining('成本未校准'), findsOneWidget);
      expect(
        find.byKey(const Key('overview-stock-top-negative')),
        findsOneWidget,
      );
      expect(find.textContaining('成本为负'), findsOneWidget);
      // 不能出现「¥0.00」这种把未校准说成零占用的写法
      expect(find.text('¥0.00'), findsNothing);
    });

    testWidgets('压货榜横条：比例照实，小额只保证 4px', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StockTopCard(
              summary: StockTopSummary(
                rows: <StockValueRow>[
                  StockValueRow(
                    productId: 'big',
                    name: '大件',
                    unit: '台',
                    quantity: 1,
                    valueCents: 1260000,
                  ),
                  StockValueRow(
                    productId: 'tiny',
                    name: '小件',
                    unit: '个',
                    quantity: 500,
                    valueCents: 500,
                  ),
                ],
                uncalibratedCount: 0,
                negativeCostCount: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final double big = tester
          .getSize(find.byKey(const Key('overview-stock-top-big-bar')))
          .width;
      final double tiny = tester
          .getSize(find.byKey(const Key('overview-stock-top-tiny-bar')))
          .width;
      expect(big, greaterThan(100));
      expect(
        tiny,
        4.0,
        reason:
            '¥5 对 ¥12,600 真实比例 0.04% ⇒ 按比例不到 1px，'
            '给 4px 可见宽度；**不能**抬到 4%（那是 100 倍失真）',
      );
    });

    testWidgets('压货榜与欠款卡之间也留了间距', (tester) async {
      final QueryDao q = await seedBiz(
        todayMs: DateTime.now().millisecondsSinceEpoch,
      );
      await tester.pumpWidget(page(queries: q));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('overview-stock-top')), findsOneWidget);
      final Rect balance = tester.getRect(
        find.byKey(const Key('overview-balance-bars')),
      );
      final Rect stock = tester.getRect(
        find.byKey(const Key('overview-stock-top')),
      );
      expect(
        stock.top - balance.bottom,
        greaterThanOrEqualTo(8),
        reason: '欠款卡与压货榜贴在一起了',
      );
    });

    testWidgets('**卡片之间必须留间距**（2026-10-20「两张卡叠在一起」的回归钉）', (tester) async {
      final QueryDao q = await seedBiz(
        todayMs: DateTime.now().millisecondsSinceEpoch,
      );
      await tester.pumpWidget(page(queries: q));
      await tester.pumpAndSettle();

      final Rect care = tester.getRect(
        find.byKey(const Key('overview-card-care')),
      );
      final Rect chart = tester.getRect(
        find.byKey(const Key('overview-revenue-chart')),
      );
      final Rect balance = tester.getRect(
        find.byKey(const Key('overview-balance-bars')),
      );

      // 两个 `Card` 都是 `margin: EdgeInsets.zero` —— 间距全靠外层 `SizedBox`。
      // 谁把它删了，这里立刻红。
      expect(
        chart.top - care.bottom,
        greaterThanOrEqualTo(8),
        reason: '经营卡与图表卡贴在一起了',
      );
      expect(
        balance.top - chart.bottom,
        greaterThanOrEqualTo(8),
        reason: '图表卡与欠款卡贴在一起了',
      );
    });
  });
}
