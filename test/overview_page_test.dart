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
import 'package:shensuanzi/src/ui/revenue_chart.dart';
import 'package:shensuanzi/src/ui/stock_top.dart';
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

    testWidgets('压货榜：金额大的排前面，数量照实写各自单位', (tester) async {
      // 用户举的反例：牙签 500 个 vs 电机 10 台 —— 按数量排牙签会排第一。
      // 这里钉的是**卡片按传入顺序渲染**（排序由 `topStockByValue` 负责，
      // 那边有 DAO 层测试），以及数量/单位**不换算、不求和**。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StockTopCard(
              rows: const <StockValueRow>[
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
          home: Scaffold(body: StockTopCard(rows: <StockValueRow>[])),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('overview-stock-top')), findsNothing);
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
