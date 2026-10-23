// 库存查询页（`StockPage`）的 widget 测试。
//
// 覆盖：三档颜色语义（负红 / 低橙 / 正常无色，§AA AA-3）/ 在店可售主列 /
// 排序（在店可售降序，遗漏 4）/ 零流水隐藏与「显示全部」开关（遗漏 5）/
// 成本（均价）列的 tooltip（AA-4）/ 导出按钮（§AF：含停用、在途、单位）。
//
// ⚠️ 必须 `useLocalSqlite()`（§N）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/document_detail_page.dart';
import 'package:shensuanzi/src/ui/opening_stock_page.dart';
import 'package:shensuanzi/src/ui/stock_flow_page.dart';
import 'package:shensuanzi/src/ui/stock_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

import 'support/fake_export.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late ProductService products;
  late QueryDao queries;
  late PurchaseService purchases;
  late SaleService sales;
  late String productId;
  late String accountId;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_stock_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    products = ProductService(db);
    queries = QueryDao(db);
    purchases = PurchaseService(engine: RuleEngine(db), queries: queries);
    sales = SaleService(engine: RuleEngine(db), queries: queries);

    final int t = 1700000000000;
    final Product product = Product(
      id: newId(),
      code: 'P0001',
      name: '红富士苹果',
      safetyStock: 5,
      createdAt: t,
      updatedAt: t,
    );
    ProductDao(db).insert(product);
    productId = product.id;

    final Account account = Account(
      id: newId(),
      name: '现金',
      type: AccountType.cash,
      createdAt: t,
      updatedAt: t,
    );
    AccountDao(db).insert(account);
    accountId = account.id;

    PartyDao(db).insert(
      Party(
        id: newId(),
        name: '王老板',
        roles: const <PartyRole>[PartyRole.supplier],
        createdAt: t,
        updatedAt: t,
      ),
    );
    PartyDao(db).insert(
      Party(
        id: newId(),
        name: '李姐',
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      ),
    );
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  /// 采购 [qty] 件（3.50 进），立即付款
  void buy(int qty) {
    purchases.create(
      PurchaseDraft(
        date: '2026-09-28',
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: productId,
            productName: '红富士苹果',
            quantity: '$qty',
            unitPrice: '3.50',
          ),
        ],
        payments: <PurchasePaymentDraft>[
          PurchasePaymentDraft(
            accountId: accountId,
            amount: Money.format(qty * 350),
          ),
        ],
      ),
      now: 1700000000000,
    );
  }

  /// 卖给「李姐」（散客也要结清，统一走客户）
  /// 卖出 [qty] 件（4.00 出），立即收款
  void sell(int qty) {
    final String customerId = PartyDao(
      db,
    ).findAll(role: PartyRole.customer).first.id;
    sales.create(
      SaleDraft(
        partyId: customerId,
        date: '2026-09-28',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: productId,
            productName: '红富士苹果',
            quantity: '$qty',
            unitPrice: '4.00',
          ),
        ],
        payments: <SalePaymentDraft>[
          SalePaymentDraft(
            accountId: accountId,
            amount: Money.format(qty * 400),
          ),
        ],
      ),
      now: 1700000000000,
    );
  }

  Widget page({
    ExportSink? exports,
    StockDelta? stockDelta,
    StockLedgerDao? stockFlow,
    SettlementService? settlements,
    MasterDataSink? masterDataSink,
    DocumentSink? documentSink,
    bool canCreateProducts = false,
    bool mobileShell = false,
  }) => MaterialApp(
    home: Scaffold(
      body: StockPage(
        engine: RuleEngine(db),
        products: products,
        queries: queries,
        exports: exports,
        stockDelta: stockDelta,
        // #27 批 2：商品流水 + 新建商品补充入口（手机壳 = 镜像实例化，
        // 测试里主库/镜像同库模拟「同源接线」）
        stockFlow: stockFlow,
        settlements: settlements,
        masterDataSink: masterDataSink,
        documentSink: documentSink,
        canCreateProducts: canCreateProducts,
        mobileShell: mobileShell,
      ),
    ),
  );

  /// 一条「卖出 [quantity] 件」的入队条目（payload = createDocument wire 形状）
  void enqueueSale(String id, String productId, int quantity) {
    SyncQueueDao(db).enqueue(
      SyncQueueEntry(
        id: id,
        entity: Schema.documents,
        entityId: 'd-$id',
        operation: SyncOpType.createDocument,
        payload: <String, Object?>{
          'document': <String, Object?>{
            'id': 'd-$id',
            'doc_no': '${Document.pendingDocNoPrefix}$id',
            'doc_type': 'sale',
            'status': 'confirmed',
            'occurred_at': 1700000000000,
          },
          'lines': <Object?>[
            <String, Object?>{
              'id': 'l-$id',
              'document_id': 'd-$id',
              'product_id': productId,
              'quantity': quantity,
              'unit_price': 500,
              'amount': quantity * 500,
            },
          ],
        },
        createdAt: 1700000000000,
      ),
    );
  }

  testWidgets('M14：**只有本地未同步影响**的商品，默认列表里也要看得到', (WidgetTester tester) async {
    // 手机端场景：刚在手机上卖了 1 件，权威账面仍是 0（还没推给电脑）
    final Product onlyLocal = Product(
      id: 'p-only-local',
      code: 'P9999',
      name: '只在手机上卖过的货',
      costPrice: 300,
      sellPrice: 500,
      createdAt: 1700000000000,
      updatedAt: 1700000000000,
    );
    ProductDao(db).insert(onlyLocal);
    enqueueSale('q-m14', onlyLocal.id, 1);

    await tester.pumpWidget(
      page(
        stockDelta: StockDelta(db: db, queue: SyncQueueDao(db)),
      ),
    );
    await tester.pumpAndSettle();

    // M14（2026-10-08）：本地那一笔也是流水 —— 只按权威过滤会把它**藏起来**，
    // 负库存风险反而看不见（报告实测：勾「显示全部」才看得到「估算 −1」）
    expect(
      find.text('只在手机上卖过的货'),
      findsOneWidget,
      reason: '默认列表必须含「只有本地未同步影响」的商品',
    );
  });

  testWidgets('空库给「怎么办」：两段式空态（§AD-6）+ 首次入口文案（遗漏 2）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('还没有库存记录'), findsOneWidget);
    expect(find.textContaining('店里已经有货'), findsOneWidget);
    expect(find.textContaining('以后新进的货'), findsOneWidget);
    // 首次（无任何流水）→「录入现有货物」；有流水后同位置变「重新清点」
    expect(find.text('录入现有货物'), findsOneWidget);
    expect(find.text('重新清点'), findsNothing);
  });

  testWidgets('入口文案切换：有流水后变「重新清点」（§AD 遗漏 2）', (WidgetTester tester) async {
    buy(3);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('重新清点'), findsOneWidget);
    expect(find.text('录入现有货物'), findsNothing, reason: '用户录过之后看到同一文案会以为没录上');
  });

  testWidgets('期初录入过 → 成本列「待校准」而不是 ¥0.00（§AD 遗漏 1）', (
    WidgetTester tester,
  ) async {
    StocktakeService(engine: RuleEngine(db), queries: queries).create(
      StocktakeDraft(
        lines: <StocktakeLineDraft>[
          StocktakeLineDraft(
            productId: productId,
            productName: '红富士苹果',
            quantity: '8',
          ),
        ],
      ),
      now: 1700000000000,
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('待校准'), findsOneWidget);
    expect(find.text('¥ 0.00'), findsNothing, reason: '成本 0 ≠ 没有成本口径');

    // 之后采购 3 件（3.50）→ 成本校准为 10.50，恢复正常金额显示
    buy(3);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('待校准'), findsNothing);
    expect(find.text('¥ 10.50'), findsOneWidget);
  });

  testWidgets('采购 10 件 → 在店可售 10（主列）；账面 10；成本（均价）出现', (
    WidgetTester tester,
  ) async {
    buy(10);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('10'), findsOneWidget, reason: '在店可售主列');
    expect(find.text('账面 10 · 在途 0'), findsOneWidget);
    expect(find.textContaining('成本（均价）'), findsOneWidget);
    // 成本 = 10 × 3.50 = ¥35.00
    expect(find.text('¥ 35.00'), findsOneWidget);
  });

  testWidgets('三档颜色：卖到低于安全库存 → 橙提示；超卖 → 红提示', (WidgetTester tester) async {
    buy(10); // 安全库存 5
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 卖 6 件 → 在店可售 4 ≤ 安全库存 5 → 橙「低于安全库存 5」
    sell(6);
    // ⚠️ 页面只在 build 时读库 —— 测试里改了数据要**重新挂载**才会看到
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.textContaining('低于安全库存 5'), findsOneWidget);

    // 再卖 5 件 → 在店可售 -1 → 红「已超卖」（橙色提示消失）
    sell(5);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.textContaining('已超卖'), findsOneWidget);
    expect(find.textContaining('低于安全库存'), findsNothing);
  });

  testWidgets('零流水商品默认隐藏，「显示全部」后出现（遗漏 5）', (WidgetTester tester) async {
    // 再建一个没流水的商品
    final int t = 1700000000000;
    ProductDao(db).insert(
      Product(
        id: newId(),
        code: 'P0002',
        name: '没进过货的商品',
        createdAt: t,
        updatedAt: t,
      ),
    );

    buy(3);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('红富士苹果'), findsOneWidget);
    expect(find.text('没进过货的商品'), findsNothing);
    expect(find.textContaining('已隐藏 1 个'), findsOneWidget);

    await tester.tap(find.text('显示全部（含没进过货的商品）'));
    await tester.pumpAndSettle();
    expect(find.text('没进过货的商品'), findsOneWidget);
  });

  // ---------------------------------------------------------------- 导出（§AF）

  testWidgets('导出按钮：列含单位与在途、**含停用**、行口径与页面一致（AF-9 / AF-12）', (
    WidgetTester tester,
  ) async {
    buy(10);
    // 再造一件**停用但有库存**的商品：页面上看不到，但导出的账里不能少。
    // ⚠️ 走真实路径（建档 → 采购入库 → 停用），不手插流水 ——
    // 手插会绕开外键与不变量，测出来的东西不算数
    final int t = 1700000000000;
    ProductDao(db).insert(
      Product(
        id: 'p-stopped',
        code: 'P0002',
        name: '停用但有货',
        unit: '箱',
        createdAt: t,
        updatedAt: t,
      ),
    );
    purchases.create(
      PurchaseDraft(
        date: '2026-09-28',
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: 'p-stopped',
            productName: '停用但有货',
            quantity: '4',
            unitPrice: '1.00',
          ),
        ],
        payments: <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: accountId, amount: '4.00'),
        ],
      ),
      now: 1700000000000,
    );
    products.setActive('p-stopped', false, now: 1700000000000);

    final FakeExport fake = FakeExport();
    await tester.pumpWidget(page(exports: fake));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('export-stock')), findsOneWidget);
    expect(find.text('导出库存'), findsOneWidget);

    await tester.tap(find.byKey(const Key('export-stock')));
    await tester.pumpAndSettle();

    expect(fake.calls, 1);
    final ExportTable table = fake.last;
    expect(table.label, '库存');
    expect(table.header, <String>[
      '编码',
      '商品',
      '条码',
      '单位',
      '库存数量',
      '在途',
      '在店可售',
      '库存成本',
      '状态',
    ]);
    expect(
      table.rows.map((List<String> row) => row[1]).toList(),
      containsAll(<String>['红富士苹果', '停用但有货']),
      reason: 'AF-12：停用但有库存的行也要在导出里（会计对得上账）',
    );
    expect(table.rows.every((List<String> row) => row.length == 9), isTrue);
    expect(
      table.rows.any((List<String> row) => row.contains('停用')),
      isTrue,
      reason: '含停用的行要能一眼看出来',
    );
  });

  // ===== #27 批 2（2026-10-17 裁定）：商品流水页 + 行入口 + 新建商品补充入口 =====

  testWidgets('#27：桌面点商品行打开流水页（±数量 + 成本列 + 行跳详情 + 导出）', (
    WidgetTester tester,
  ) async {
    buy(10);
    sell(3);
    await tester.pumpWidget(
      page(
        stockFlow: StockLedgerDao(db), // 桌面 = 主库实例化
        settlements: SettlementService(db: db, engine: RuleEngine(db)),
        exports: FakeExport(),
      ),
    );
    await tester.pumpAndSettle();

    // 行 tap = 打开本商品的流水页
    await tester.tap(find.text('红富士苹果'));
    await tester.pumpAndSettle();

    expect(find.byType(StockFlowPage), findsOneWidget);
    expect(find.text('红富士苹果 的流水'), findsOneWidget);
    expect(find.text('10'), findsOneWidget, reason: '入库 = 正');
    expect(find.text('-3'), findsOneWidget, reason: '出库 = 负');
    expect(find.text('¥35.00'), findsOneWidget, reason: '桌面显示成本（10 × 3.50）');
    expect(find.byKey(const Key('export-stock-flow')), findsOneWidget);

    // 流水行 tap ⇒ 跳单据详情
    final String docId = StockLedgerDao(
      db,
    ).ofProductReadable(productId).first.documentId;
    await tester.tap(find.byKey(Key('stock-flow-row-$docId')));
    await tester.pumpAndSettle();
    expect(find.byType(DocumentDetailPage), findsOneWidget);
  });

  testWidgets('#27：手机壳流水页 —— 镜像可读（非空）、无成本列、行不可点', (WidgetTester tester) async {
    buy(6);
    await tester.pumpWidget(
      page(
        mobileShell: true,
        // 手机壳 = 镜像实例化（测试同库模拟同源接线）—— 裁定②的「非空」断言：
        // 打开即至少一条流水，防「误接主库查不到数据」的坑
        stockFlow: StockLedgerDao(db),
        masterDataSink: QueueMasterSink(mirror: db, queue: SyncQueueDao(db)),
        canCreateProducts: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('红富士苹果'));
    await tester.pumpAndSettle();

    expect(find.byType(StockFlowPage), findsOneWidget);
    expect(find.text('6'), findsOneWidget, reason: '「至少能读到一条」—— 裁定②的点');
    expect(find.textContaining('成本只在电脑上显示'), findsOneWidget);
    expect(find.textContaining('每件'), findsNothing, reason: '手机不显示成本');
    // 行不可点：点了仍在流水页（无详情页可跳）
    final String docId = StockLedgerDao(
      db,
    ).ofProductReadable(productId).first.documentId;
    await tester.tap(find.byKey(Key('stock-flow-row-$docId')));
    await tester.pumpAndSettle();
    expect(find.byType(StockFlowPage), findsOneWidget);
    expect(find.byType(DocumentDetailPage), findsNothing);
  });

  // 2026-10-20（§CV·七十八，用户要求）：手机上「重新清点 / 录入现有货物」
  // 以前是引导（裁定说客户端算不出盘点 delta）—— 现在**清点单走单据队列**，
  // 差额由主机算 ⇒ 直接开页面，不再引导。
  testWidgets('#78：手机「重新清点」⇒ 进期初页（不再弹「这一步在电脑上做」）', (WidgetTester tester) async {
    buy(6); // 有流水 ⇒ 按钮文案是「重新清点」
    final QueueSink sink = QueueSink(
      queue: SyncQueueDao(db),
      clock: () => 1700000000000,
    );

    await tester.pumpWidget(
      page(
        mobileShell: true,
        documentSink: sink,
        masterDataSink: QueueMasterSink(mirror: db, queue: SyncQueueDao(db)),
        canCreateProducts: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('重新清点'));
    await tester.pumpAndSettle();

    expect(find.text('这一步在电脑上做'), findsNothing, reason: '不再引导');
    expect(
      find.text('录入现有货物'),
      findsNothing,
      reason: '二次进来是「重新清点」语义 —— 页面标题不打首次文案',
    );
    expect(find.byType(OpeningStockPage), findsOneWidget);
  });

  // 2026-10-21（§CV·八十 Q1）：与往来流水同一组判据 —— 字号真的生效 + 2.0 不溢出。
  testWidgets('#64③ 商品流水页不许把 2.0 夹到 1.15；2.0 下不溢出', (
    WidgetTester tester,
  ) async {
    buy(6);
    Future<double> quantityHeight(double scale) async {
      // 每次从**空树**重建（否则 Navigator 留着上一次 push 的流水页）
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: StockPage(
              engine: RuleEngine(db),
              products: products,
              queries: queries,
              stockFlow: StockLedgerDao(db),
              mobileShell: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('红富士').first);
      await tester.pumpAndSettle();
      expect(find.byType(StockFlowPage), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$scale× 下流水页溢出');
      // 量流水页里「单号 · 日期」那一行的字号效果
      return tester
          .getSize(find.textContaining(' · 2026').first)
          .height;
    }

    final double h1 = await quantityHeight(1.0);
    final double h2 = await quantityHeight(2.0);
    expect(
      h2 / h1,
      greaterThan(1.6),
      reason: '字号被夹到 1.15（比值≈1.15）—— 用户选的 2.0 必须真的生效',
    );
  });

  testWidgets('#27：新建商品补充入口 —— 手机壳在场、桌面缺省不在', (WidgetTester tester) async {
    await tester.pumpWidget(
      page(
        mobileShell: true,
        masterDataSink: QueueMasterSink(mirror: db, queue: SyncQueueDao(db)),
        canCreateProducts: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stock-create-product')), findsOneWidget);

    // 桌面缺省（无 sink / 非手机壳）⇒ 不在场（桌面建档在「商品」页）
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stock-create-product')), findsNothing);
  });

  // ===== #31（2026-10-16 裁定②）：「期初 N 件待同步」提示 =====
  //
  // 手机建档带期初 = 一条 createMasterData 条目（payload 带 opening_quantity），
  // stocktake 的 delta 客户端算不出 ⇒ 数字上不出现 —— 用提示行补。
  testWidgets('#31：待同步期初 ⇒ 行显示「期初 N（单位）待同步」，零流水也可见', (
    WidgetTester tester,
  ) async {
    // 手机形态：页面读**镜像**，PendingMarks 也挂在镜像队列上
    final Db mirror = Db.openInMemory(foreignKeys: false);
    addTearDown(mirror.close);
    final ProductService mirrorProducts = ProductService(mirror);
    final QueryDao mirrorQueries = QueryDao(mirror);

    int tick = 1700000000000;
    final QueueMasterSink sink = QueueMasterSink(
      mirror: mirror,
      queue: SyncQueueDao(mirror),
      clock: () => ++tick, // 单调（§CV·十六 的 UUIDv7 教训）
    );
    // 真实通路：建档 + 期初（一条条目）
    sink.createProduct(
      const ProductDraft(name: '新建档商品', unit: '瓶', sellPrice: '2.00'),
      openingQuantity: 10,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StockPage(
            engine: RuleEngine(mirror),
            products: mirrorProducts,
            queries: mirrorQueries,
            mobileShell: true,
            pendingMarks: PendingMarks(SyncQueueDao(mirror)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('期初 10（瓶）待同步'),
      findsOneWidget,
      reason: '裁定②：技术诚实（delta=0）之外要 UI 补偿',
    );
  });

  testWidgets('#31：期初同步确认后（条目转 sent 且被确认清除）提示消失', (WidgetTester tester) async {
    final Db mirror = Db.openInMemory(foreignKeys: false);
    addTearDown(mirror.close);
    final ProductService mirrorProducts = ProductService(mirror);
    final QueryDao mirrorQueries = QueryDao(mirror);

    int tick = 1700000002000;
    final QueueMasterSink sink = QueueMasterSink(
      mirror: mirror,
      queue: SyncQueueDao(mirror),
      clock: () => ++tick,
    );
    sink.createProduct(
      const ProductDraft(name: '已同步商品', unit: '瓶', sellPrice: '2.00'),
      openingQuantity: 6,
    );
    final SyncQueueDao queue = SyncQueueDao(mirror);
    // 主机收下 + pull 确认（条目删除 ⇒ 提示随之消失）
    for (final SyncQueueEntry entry in queue.all()) {
      queue.markSent(entry.id);
      queue.clearConfirmed(<String>{entry.entityId});
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StockPage(
            engine: RuleEngine(mirror),
            products: mirrorProducts,
            queries: mirrorQueries,
            mobileShell: true,
            pendingMarks: PendingMarks(queue),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('期初'), findsNothing);
  });
  // 附录 B（`docs/ui-review-2026-10-21.md`）：库存页 原先**没有**大字号断言。
  // 批 3 第 18 条：前 17 项「尺寸随缩放派生」改造的机械护栏 —— 先立护栏再动尺寸。
  testWidgets('大字号（2.0）：库存页不溢出', (WidgetTester tester) async {
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
      reason: '库存页在 2.0 档下溢出（附录 B 点名的结构：固定宽度 / 固定断点 / 顶部 Row）',
    );
  });

  // 附录 B（`docs/ui-review-2026-10-21.md`）：**商品流水页**原先没有大字号断言。
  testWidgets('大字号（2.0）：商品流水页不溢出', (WidgetTester tester) async {
    final Product product = products.list().first;

    tester.view.physicalSize = const Size(960, 1000);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StockFlowPage(
            product: product,
            flowDao: StockLedgerDao(db),
            mobileShell: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: '商品流水页在 2.0 档下溢出（附录 B 点名：固定宽度 / 顶部 Row）',
    );
  });


  // 批 3 第 16 条：库存页原先有搜索，但**没有 × 清空、没有真实总数**。
  testWidgets('搜索：有真实总数、× 能清空', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.textContaining('共 1 个商品'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('stock-search')), '不存在的商品');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    // **真实总数**：不是「找到 0 个」，而是「找到 0 个 / 共 1 个」
    expect(find.textContaining('找到 0 个 / 共 1 个'), findsOneWidget);

    await tester.tap(find.byKey(const Key('list-search-clear')));
    await tester.pumpAndSettle();
    expect(find.textContaining('共 1 个商品'), findsOneWidget);
  });

}
