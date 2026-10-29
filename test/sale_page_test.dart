// 店内销售开单页（`SalePage`）的 widget 测试。
//
// 与 `purchase_page_test.dart` 同构；销售特有：售价预填 / 散客结清 /
// 负库存快照告警 / 客户选择器（最近往来 + 同名追加 role）。
//
// ⚠️ 必须 `useLocalSqlite()`（§N）；商品选择器**空查询显示「最近销售」**（先搜索再点选）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/sale_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late SaleService service;
  late PurchaseService purchases;
  late ProductService products;
  late PartyService partyService;
  // B3b：页面提交改吃 Sink —— 桌面语义 = ServiceSink（与直连逐字同行为）
  late DocumentSink sink;
  late String productId;
  late String accountId;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_sale_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    service = SaleService(engine: RuleEngine(db), queries: QueryDao(db));
    purchases = PurchaseService(engine: RuleEngine(db), queries: QueryDao(db));
    sink = ServiceSink(
      sales: service,
      purchases: purchases,
      deliveries: DeliveryService(
        engine: RuleEngine(db),
        queries: QueryDao(db),
      ),
    );
    products = ProductService(db);
    partyService = PartyService(PartyDao(db));

    final int t = 1700000000000;
    final Product product = Product(
      id: newId(),
      code: 'P0001',
      name: '红富士苹果',
      costPrice: 350,
      sellPrice: 500,
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

  Widget page({
    StockDelta? stockDelta,
    MasterDataPolicy? policy,
    bool mobileShell = false,
    DraftsStore? drafts,

    /// F18：传 1.8 = 复现「界面大小 = 超大」（`MediaQuery.textScaler`）。
    double textScale = 1.0,
  }) => MaterialApp(
    // 缩放走 `textScaler`（`uiScaleOf` 就是从这里取的，见 `scaled.dart`）
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: SalePage(
        service: service,
        productService: products,
        partyService: partyService,
        sink: sink,
        stockDelta: stockDelta,
        // 缺省桌面 ⇒ 既有用例**零变化**；mobile() 组显式传入
        masterDataPolicy: policy ?? const MasterDataPolicy.desktop(),
        masterDataSink: ServiceMasterSink(products),
        mobileShell: mobileShell,
        // ① 草稿：不传 = 不启用（既有用例逐字不变）
        drafts: drafts,
      ),
    ),
  );

  /// #51 夹具：把 [SalePage] **推成第二屏路由**（手机上的真实形态）——
  /// 底下垫一页占位，才能断言「确认放弃后整屏被退出」。
  Future<void> pushSalePage(
    WidgetTester tester, {
    required bool mobileShell,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(body: Center(child: Text(' beneath '))),
      ),
    );
    final NavigatorState nav = tester.state(find.byType(Navigator));
    nav.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => Scaffold(
          body: SalePage(
            service: service,
            productService: products,
            partyService: partyService,
            sink: sink,
            masterDataPolicy: const MasterDataPolicy.desktop(),
            masterDataSink: ServiceMasterSink(products),
            mobileShell: mobileShell,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 一条「卖出 1 件」的入队条目（M08 用；payload = createDocument wire 形状）
  void enqueueSale(String id, String productId) {
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
              'quantity': 1,
              'unit_price': 500,
              'amount': 500,
            },
          ],
        },
        createdAt: 1700000000000,
      ),
    );
  }

  /// 选中第一行的商品（先搜索再点选 —— 空查询是「最近销售」，首跑为空）
  //
  // ⚠️ 声明必须排在**首个使用点之前**：Dart 的局部函数按局部变量处理，
  //    声明点之前不可见（2026-10-08 真实踩到：M08 用例在它之前调用 ⇒ 编译不过）。
  /// 打开商品选择器。
  ///
  /// ② 之后行卡的商品格分两种形态（`allowTypedName`）：
  /// - 主机出口（`ServiceSink`）⇒ 可手打的输入框 + 右边小图标；
  /// - 队列出口（`QueueSink`）⇒ 仍是「点此选商品」单元格（它不能建主数据）。
  Future<void> openPicker(WidgetTester tester) async {
    final Finder byKey = find.byKey(const Key('sale-pick-product'));
    await tester.tap(byKey.evaluate().isNotEmpty ? byKey : find.text('点此选商品'));
    await tester.pumpAndSettle();
  }

  Future<void> pickFirstProduct(WidgetTester tester) async {
    await openPicker(tester);

    // ⚠️ 搜索框必须用 Key：`byType(TextField).first` 会命中弹层底下页面的输入框
    await tester.enterText(find.byKey(const Key('picker-search')), '红富士');
    await tester.pumpAndSettle();
    await tester.tap(find.text('红富士苹果').first);
    await tester.pumpAndSettle();
  }

  testWidgets('M08：开单页的库存提示**含本地未同步影响**（不只是权威值）', (WidgetTester tester) async {
    enqueueSale('q-m08', productId);

    await tester.pumpWidget(
      page(
        stockDelta: StockDelta(db: db, queue: SyncQueueDao(db)),
      ),
    );
    await tester.pumpAndSettle();
    await pickFirstProduct(tester);

    // M08（2026-10-08）：手机上刚开的单还没推给电脑 —— 只说权威值会让老板
    // 误判缺货（「还有 7 件」而实际只剩 6 件）。提示必须说明本地影响。
    expect(
      find.textContaining('本地未同步'),
      findsOneWidget,
      reason: '库存提示要说清「权威值 + 本地未同步多少」',
    );
  });

  /// 先采购 10 件建立正库存（页外直接走服务层）
  void stockUp() {
    purchases.create(
      PurchaseDraft(
        date: '2026-09-27',
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: productId,
            productName: '红富士苹果',
            quantity: '10',
            unitPrice: '3.50',
          ),
        ],
        payments: <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: accountId, amount: '35'),
        ],
      ),
      now: 1700000000000,
    );
  }

  Future<void> fillRow(WidgetTester tester, {String qty = '10'}) async {
    await pickFirstProduct(tester);
    // 单价已预填售价 5.00 —— 不动它
    await tester.enterText(find.byKey(const Key('sale-qty')), qty);
    await tester.pumpAndSettle();
  }

  /// 底部按钮先滚到可见再点（800×600 视口装不下整页）
  Future<void> tapFinder(WidgetTester tester, Finder button) async {
    await tester.scrollUntilVisible(
      button,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  /// 按**文案**点底部按钮。⚠️ 保存按钮的文案会随「有没有找零」变（§AX·一）
  /// ⇒ 涉及找零的用例请用 [tapFinder] + `Key('sale-save')`（按 Key 找，不按文案）。
  Future<void> tapBottomButton(WidgetTester tester, String label) =>
      tapFinder(tester, find.text(label));

  /// 点底部「保存」—— **按 Key 找**，与文案解耦。
  Future<void> tapSave(WidgetTester tester) =>
      tapFinder(tester, find.byKey(const Key('sale-save')));

  // 2026-10-22（§CV·八十一 批 2 第 7 条 / 报告 §2.5 性能项）：
  // 原来 `build()` 里直接 `stockSnapshot()`，而页内任何输入都 `setState`
  // ⇒ **每敲一个键一次全表 GROUP BY**。现在一次会话只查一次（提交后失效）。
  testWidgets('打字不再每键查一次全库（快照按需失效）', (WidgetTester tester) async {
    int calls = 0;
    final SaleService counting = _CountingSaleService(
      engine: RuleEngine(db),
      queries: QueryDao(db),
      onSnapshot: () => calls++,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SalePage(
            service: counting,
            productService: products,
            partyService: partyService,
            sink: sink,
            masterDataPolicy: const MasterDataPolicy.desktop(),
            masterDataSink: ServiceMasterSink(products),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 选一个商品（走页面已有的 helper：弹层里要先搜索才列商品）
    await pickFirstProduct(tester);

    // 数量框：按 Key 找（`byType.first` 会命中别的输入框）
    final Finder qty = find.byKey(const Key('sale-qty'));
    await tester.enterText(qty, '1');
    await tester.pump();
    await tester.enterText(qty, '12');
    await tester.pump();
    await tester.enterText(qty, '123');
    await tester.pump();
    await tester.enterText(qty, '1234');
    await tester.pump();
    await tester.enterText(qty, '12345');
    await tester.pump();

    expect(
      calls,
      lessThanOrEqualTo(2),
      reason: '快照应缓存（首次 + 可能一次重算），不能每键一次；实测 \$calls 次',
    );
  });

  testWidgets('空表单点保存 → 行级报「请选一个商品」', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tapBottomButton(tester, '保存 (Ctrl+S)');

    // 2026-10-21：现在会**出现两次** —— 就地标红 + 页顶摘要（§CV·八十 批 1 ③）
    expect(find.textContaining('请选一个商品'), findsWidgets);
    expect(find.byKey(const Key('submit-error-summary')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  // 2026-10-21（§CV·八十 批 1 ③）：保存失败要**在页顶说清楚哪几处要填**。
  // 原来只在各字段就地标红 —— 用户视线在页底保存按钮，等于「点了没反应」。
  testWidgets('保存失败 ⇒ 页顶出现错误摘要（含条数）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tapBottomButton(tester, '保存 (Ctrl+S)');

    expect(find.byKey(const Key('submit-error-summary')), findsOneWidget);
    expect(find.textContaining('还有'), findsWidgets, reason: '要报条数');
    // 摘要里也要有具体那一条（不只一个数字）
    expect(find.textContaining('请选一个商品'), findsWidgets);
  });

  testWidgets('散客全款 → 保存成功，库存 -10，SnackBar 已结清', (WidgetTester tester) async {
    stockUp();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester);
    await tester.tap(find.text('全款'));
    await tester.pumpAndSettle();
    await tapBottomButton(tester, '保存 (Ctrl+S)');

    expect(find.textContaining('已保存'), findsOneWidget);
    expect(find.textContaining('已结清'), findsOneWidget);
    expect(StockLedgerDao(db).stockOf(productId), 0, reason: '买 10 卖 10');
  });

  testWidgets('手机端（QueueSink）保存 → 「已记入待同步」SnackBar，本地不落库（§CA）', (
    WidgetTester tester,
  ) async {
    // 队列库按真机形态：镜像库 FK 是关的（SyncClient 毒丸守卫的前提）
    final Db queueDb = Db.openInMemory(foreignKeys: false);
    final DocumentSink queueSink = QueueSink(queue: SyncQueueDao(queueDb));
    stockUp(); // 选择器/快照仍查本地服务（B3c 再切镜像视图 —— 台账已列开放项）
    addTearDown(queueDb.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SalePage(
            service: service,
            productService: products,
            partyService: partyService,
            sink: queueSink,
            masterDataPolicy: const MasterDataPolicy.desktop(),
            masterDataSink: ServiceMasterSink(products),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await fillRow(tester);
    await tester.tap(find.text('全款'));
    await tester.pumpAndSettle();
    await tapBottomButton(tester, '保存 (Ctrl+S)');

    // 裁定 ② 的文案（core `queuedNotice` 给，UI 不造句）
    expect(find.textContaining('已记入待同步'), findsOneWidget);
    // #53 二稿（2026-10-16 裁定）：「保存后会自动尝试」—— 开单路径准确；
    // 旧「主机下次联网时会收到」承诺了不存在的触发
    expect(find.textContaining('保存后会自动尝试传给电脑'), findsOneWidget);
    expect(StockLedgerDao(db).stockOf(productId), 10, reason: '客户端不落库 —— 库存不动');
    expect(SyncQueueDao(queueDb).count(), 1, reason: '入队 1 条');
  });

  testWidgets('散客欠款 → 报「散客要当场结清」', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester); // 不点全款 → 全赊
    await tapBottomButton(tester, '保存 (Ctrl+S)');

    expect(
      find.textContaining('散客要当场结清'),
      findsWidgets,
      reason: '就地 + 页顶摘要各一次（§CV·八十 批 1 ③）',
    );
  });

  testWidgets('负库存：行内红色提示（打开本页时），保存照常放行', (WidgetTester tester) async {
    // 库存快照在页面 initState 取 —— 先开页面再改库存也行，但这里直接不进货
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester, qty: '10'); // 无采购 → 快照 0，卖 10 → 负
    await tester.tap(find.text('全款'));
    await tester.pumpAndSettle();

    // 红色提示出现，且**标明是快照**
    expect(find.textContaining('打开本页时'), findsOneWidget);
    expect(find.textContaining('负库存记账'), findsOneWidget);

    await tapBottomButton(tester, '保存 (Ctrl+S)');
    expect(find.textContaining('已保存'), findsOneWidget);
    expect(StockLedgerDao(db).stockOf(productId), -10);
  });

  testWidgets('选客户 + 部分收款 → SnackBar 带累计欠款；售出单价可改', (
    WidgetTester tester,
  ) async {
    stockUp();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 选客户
    await tester.tap(find.text('散客（当场结清）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('李姐').first);
    await tester.pumpAndSettle();

    await fillRow(tester);
    // 议价：单价从预填 5.00 改成 4.00（改后的单价是这一行的真相）
    await tester.enterText(find.byKey(const Key('sale-price')), '4.00');
    await tester.pumpAndSettle();
    // 部分收款 10 元
    await tester.enterText(find.byKey(const Key('sale-pay-amount')), '10');
    await tapBottomButton(tester, '保存 (Ctrl+S)');

    expect(find.textContaining('已保存'), findsOneWidget);
    // 10 × 4.00 = 40 元，收 10 元 → 欠 30 元
    expect(find.textContaining('欠款 ¥30.00'), findsOneWidget);
    expect(find.textContaining('李姐 累计欠款 ¥30.00'), findsOneWidget);
  });

  testWidgets('客户选择器：空查询显示「最近往来」；新建同名 → 追加 role 不建第二条', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.text('散客（当场结清）'));
    await tester.pumpAndSettle();

    // 已有客户「李姐」在列表里（空查询列出全部启用客户）
    expect(find.text('李姐'), findsOneWidget);

    // 新建同名 → ensureParty 追加 role，不建第二条
    await tester.enterText(find.byKey(const Key('picker-search')), '老王');
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建客户（用上面的名称）'));
    await tester.pumpAndSettle();

    // 弹层关闭，页头显示客户名
    expect(find.text('老王'), findsWidgets);
    final int count =
        db.raw
                .select("SELECT COUNT(*) AS n FROM parties WHERE name = '老王'")
                .first['n']!
            as int;
    expect(count, 1);
    // 他同时也是供应商（若之前作为供应商存在）时 roles 会追加 —— 这里验证 customer role 在
    final Party? party = partyService.findByName('老王');
    expect(party?.roles, contains(PartyRole.customer));
  });

  testWidgets('取消：有内容 → 先确认，确认后表单清空', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester);
    await tapBottomButton(tester, '取消 (Esc)');

    expect(find.text('放弃这次开单？'), findsOneWidget);
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();

    // ② 之后商品格是输入框：清空 = 名字为空（不再是「点此选商品」文案）
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sale-product-name')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text('放弃这次开单？'), findsNothing);
  });

  testWidgets('#51：手机（推入路由）确认放弃 ⇒ 整屏退出，不只清草稿', (WidgetTester tester) async {
    await pushSalePage(tester, mobileShell: true);
    await fillRow(tester); // 有内容 ⇒ canPop = false ⇒ 返回被拦

    // Android 系统返回（返回键 / 手势 / AppBar 返回）= 一次 maybePop
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('放弃这次开单？'), findsOneWidget);
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();

    // 旧实现只清草稿、人还留在开单页（外测 M09 的失败点）；
    // 现在「放弃」= 退出整屏 —— 底下垫的那一页露出来
    expect(find.text(' beneath '), findsOneWidget, reason: '确认放弃 ⇒ 路由退出');
    expect(find.text('放弃这次开单？'), findsNothing);
  });

  testWidgets('#51/Alt+←：桌面系统返回被吞 —— 不弹确认、不退出、草稿保留', (
    WidgetTester tester,
  ) async {
    await pushSalePage(tester, mobileShell: false);
    await fillRow(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      find.text('放弃这次开单？'),
      findsNothing,
      reason:
          '2026-10-15 裁定：Alt+← / 鼠标侧键不启用 —— '
          '中老年用户不认识它，误触到「放弃确认」有丢草稿风险',
    );
    expect(find.text(' beneath '), findsNothing, reason: '不退出');
    // 草稿原样保留：数量框还是填过的 10（没有被清空重置成空行）
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sale-qty')))
          .controller!
          .text,
      '10',
      reason: '草稿原样保留',
    );
  });

  // ---------------------------------------------------------------- §AJ·AI-4 现金找零

  testWidgets('现金找零辅助行：默认现金账户可见；给了 100 买 50 的货 → 找零 ¥50.00', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 辅助行常驻（第一条收款行默认是现金账户）
    expect(find.text('顾客给了'), findsOneWidget);

    await fillRow(tester); // 10 × 5.00 = 50
    await tester.enterText(find.byKey(const Key('sale-given')), '100');
    await tester.pumpAndSettle();

    expect(find.text('找零 ¥50.00'), findsOneWidget);
  });

  testWidgets('「顾客给了」小于应收 → 显示「不够」（内联橙），仍允许提交', (WidgetTester tester) async {
    stockUp();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester); // 合计 50
    await tester.tap(find.text('全款'));
    await tester.enterText(find.byKey(const Key('sale-given')), '30');
    await tester.pumpAndSettle();

    expect(find.text('不够'), findsOneWidget);

    // 「不够」只是提醒 —— 提交照常放行（用户可能只是拿它算个数）
    await tapBottomButton(tester, '保存 (Ctrl+S)');
    expect(find.textContaining('已保存'), findsOneWidget);
  });

  // #40④（2026-10-18 裁定甲）：「顾客给了」**不记账**，但用户会当它是收款框
  testWidgets('#40④ 填了「顾客给了」却没填收款框 ⇒ 提交前说清会整单赊账', (WidgetTester tester) async {
    stockUp();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester); // 合计 50
    await tester.enterText(find.byKey(const Key('sale-given')), '100');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('sale-cash-given-notice')),
      findsOneWidget,
      reason: '不记账这件事必须在**提交前**说，不能只靠保存后的 SnackBar',
    );
    expect(find.textContaining('不会记账'), findsOneWidget);
    expect(find.textContaining('整单赊账 ¥50.00'), findsOneWidget);
  });

  testWidgets('「顾客给了」不记账：给 100 收 50 → money_ledger 只进 50', (
    WidgetTester tester,
  ) async {
    stockUp();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester);
    await tester.tap(find.text('全款')); // 收款框 = 50.00（应收）
    await tester.enterText(find.byKey(const Key('sale-given')), '100');
    await tester.pumpAndSettle();

    // 这条路是**「顾客给了」超收**：那个数**不进草稿** ⇒
    // ① 找零辅助行照旧写「找零 ¥50.00」 ② **按钮文字**说清「记多少 / 找多少」。
    // ⚠️ **不**出现「实收/入账」橙色告知 —— 那是**收款框自己填超**时才有的
    //（那时系统要替用户折算，必须说清；这里收款框本来就是应收，什么都没改）。
    expect(find.text('找零 ¥50.00'), findsOneWidget);
    expect(find.textContaining('记 ¥50.00 并找零 ¥50.00'), findsOneWidget);
    expect(
      find.textContaining('实收 ¥100.00'),
      findsNothing,
      reason: '收款框没填超 ⇒ 不该有折算告知',
    );

    await tapSave(tester); // 按 Key 找 —— 不依赖会变的文案

    expect(find.textContaining('已保存'), findsOneWidget);
    // 落库永远是应收：现金箱净流入 50 元。⚠️ 只 sum 收入方向 ——
    // stockUp 的采购付款（-3500）也在 money_ledger 里，全表 SUM 会混入
    final int cashIn =
        db.raw
                .select(
                  'SELECT COALESCE(SUM(amount), 0) AS s FROM money_ledger '
                  'WHERE amount > 0',
                )
                .first['s']!
            as int;
    expect(cashIn, 5000, reason: '落库 50 元，不是顾客给的 100 元（§AJ·AI-4）');
    // 保存后「顾客给了」即清（不持久化）
    expect(find.text('100'), findsNothing);
  });

  testWidgets('收款框直接填超（100 > 应收 50）→ 橙色告知 + 按钮 + SnackBar 说清记账额', (
    WidgetTester tester,
  ) async {
    stockUp();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester);
    // 直接在**收款框**里填 100（不点「全款」）—— 旧行为是报错「不能超过应收」并拦住
    await tester.enterText(find.byKey(const Key('sale-pay-amount')), '100');
    await tester.pumpAndSettle();

    // ① 橙色内联告知（系统替他折算 ⇒ **必须**说清记多少 / 找多少）
    expect(
      find.textContaining('实收 ¥100.00，其中 ¥50.00 入账、找零 ¥50.00'),
      findsOneWidget,
    );
    expect(find.textContaining('不能超过应收'), findsNothing, reason: '§AX·一 旧文案已废止');
    // ② 按钮文字
    expect(find.textContaining('记 ¥50.00 并找零 ¥50.00'), findsOneWidget);

    await tapSave(tester);

    // ③ 保存后再说一次（第二处告知）
    expect(find.textContaining('已保存'), findsOneWidget);
    expect(
      find.textContaining('记账 ¥50.00（找零 ¥50.00）'),
      findsOneWidget,
      reason: '第二处告知：保存后再说一次记了多少',
    );
    final int cashIn =
        db.raw
                .select(
                  'SELECT COALESCE(SUM(amount), 0) AS s FROM money_ledger '
                  'WHERE amount > 0',
                )
                .first['s']!
            as int;
    expect(cashIn, 5000, reason: '⚡ 关键：找零的 50 元没进账');
  });

  testWidgets('快捷键 [收 100]：收款框填应收全额，「顾客给了」填整额', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester); // 合计 50
    // ⚠️ v3 加了「整单让价」框，页面又高了一截 ——「收 100」在视口外，
    // 直接 tap 会 miss（offset 越界）且收款框没被填。先滚到可见再点。
    await tapFinder(tester, find.text('收 100'));

    final TextField payField = tester.widget<TextField>(
      find.byKey(const Key('sale-pay-amount')),
    );
    final TextField givenField = tester.widget<TextField>(
      find.byKey(const Key('sale-given')),
    );
    expect(payField.controller!.text, '50.00', reason: '收款框填的是应收');
    expect(givenField.controller!.text, '100.00');
    expect(find.text('找零 ¥50.00'), findsOneWidget);
  });

  testWidgets('非现金账户不显示找零辅助行（找零是现金的物理属性）', (WidgetTester tester) async {
    // ⚠️ v3 加了「整单让价」框，账户 Dropdown 的按钮位置更低 ——
    // 800×600 视口里弹出菜单放不下（框架断言 menuLimits）。
    // 该用例临时加高视口；addTearDown 恢复，不影响别的用例。
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final int t = 1700000000000;
    AccountDao(db).insert(
      Account(
        id: newId(),
        name: '微信收款',
        type: AccountType.wechat,
        createdAt: t,
        updatedAt: t,
      ),
    );

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // ⚠️ 账户下拉按 name 排序（`ORDER BY name`）——「微信收款」按码点排在
    // 「现金」前面，页面默认选中的是微信收款。先切到现金，再断言辅助行在。
    await tester.tap(find.text('微信收款').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('现金').last);
    await tester.pumpAndSettle();

    // 现金账户时辅助行在
    expect(find.text('顾客给了'), findsOneWidget);

    // 切到微信 → 辅助行消失
    await tester.tap(find.text('现金').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('微信收款').last);
    await tester.pumpAndSettle();

    expect(find.text('顾客给了'), findsNothing);
  });

  // ---- §BG 方案 A：切单位 ⇒ 未被手改的预填价跟着换算（三页同构，各钉各的 Key）----

  testWidgets('§BG 方案A：切到「箱」⇒ 预填价 ×12、单价标注单位、显示换算说明', (
    WidgetTester tester,
  ) async {
    final Product milk = Product(
      id: newId(),
      code: 'P0002',
      name: '蒙牛纯牛奶',
      unit: '瓶',
      sellPrice: 250,
      packageUnit: '箱',
      packageSize: 12,
      createdAt: 2,
      updatedAt: 2,
    );
    ProductDao(db).insert(milk);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 选牛奶（⚠️ 结果行按 ListTile 找 —— 搜索框里的字也会被 find.text 命中）
    await tester.tap(find.byKey(const Key('sale-pick-product')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('picker-search')), '蒙牛');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '蒙牛纯牛奶'));
    await tester.pumpAndSettle();

    TextField priceField() =>
        tester.widget<TextField>(find.byKey(const Key('sale-price')));
    // 预填 = 瓶价 2.50，label 标注最小单位
    expect(priceField().controller!.text, '2.50');
    expect(find.text('单价（元/瓶）*'), findsOneWidget);

    // 切到「箱」⇒ 预填价 ×12 = 30.00（§BG 方案 A 的核心断言）
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, '箱'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '箱'));
    await tester.pumpAndSettle();
    expect(priceField().controller!.text, '30.00');
    expect(find.text('单价（元/箱）*'), findsOneWidget);
    expect(find.text('1 箱 = 12 瓶，入库按 12 瓶记。'), findsOneWidget);

    // 切回「瓶」⇒ ÷12 还原；换算说明消失（只在切到包装时显示，裁定 ③）
    await tester.tap(find.widgetWithText(ChoiceChip, '瓶'));
    await tester.pumpAndSettle();
    expect(priceField().controller!.text, '2.50');
    expect(find.text('单价（元/瓶）*'), findsOneWidget);
    expect(find.text('1 箱 = 12 瓶，入库按 12 瓶记。'), findsNothing);
  });

  // ============================================ M12：改数量后让价重算（2026-10-08）

  testWidgets('M12：改数量后整单让价**重新分摊**（预览与提交一致）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await pickFirstProduct(tester);

    // 1 × ¥5.00，让价 ¥1.00 ⇒ 合计 ¥4.00
    await tester.enterText(find.byKey(const Key('sale-qty')), '1');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sale-discount')), '1');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('¥ 4.00'),
      findsWidgets,
      reason: '1 × 5.00 减让价 1.00',
    );

    // 数量改成 2 ⇒ 折前 ¥10.00，让价 ¥1.00 ⇒ **¥9.00**。
    // 不重算的话各行小计还按 1 件算 ⇒ 合计仍是 ¥4.00（报告实测的 M12：
    // 界面显示的和保存时算出来的不一样）。
    await tester.enterText(find.byKey(const Key('sale-qty')), '2');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('¥ 9.00'),
      findsWidgets,
      reason: 'M12：改数量后让价必须重新分摊',
    );
  });

  // M10（2026-10-08）：明细行原先是**固定横向比例** —— 窄屏 + 超大字号时
  // 单价框放不下「单价（元/箱）」这个 label，被系统截成省略号。
  // 现在宽屏并排（桌面零变化）、窄屏 + 大字号改成上下堆叠。
  testWidgets('M10：窄屏 + 2 倍字号 ⇒ 数量/单价**上下堆叠**', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 不用选商品：行卡的数量 / 单价框一开始就在
    final Finder qty = find.byKey(const Key('sale-qty'));
    final Finder price = find.byKey(const Key('sale-price'));
    expect(qty, findsOneWidget);
    expect(price, findsOneWidget);

    expect(
      tester.getBottomLeft(qty).dy <= tester.getTopLeft(price).dy,
      isTrue,
      reason: 'M10：窄屏 + 大字号必须堆叠（数量在上、单价在下）',
    );
  });

  testWidgets('M10：宽屏 + 标准字号 ⇒ 仍**并排**（桌面零变化）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    final Finder qty = find.byKey(const Key('sale-qty'));
    final Finder price = find.byKey(const Key('sale-price'));

    // 并排 ⇒ 两个框在**同一水平带**（中心 y 基本相同）
    expect(
      (tester.getCenter(qty).dy - tester.getCenter(price).dy).abs() < 1,
      isTrue,
      reason: '宽屏必须还是并排，不能把桌面布局改坏',
    );
  });

  // ============================================================ §CV·七 ① 乙
  // `MasterDataPolicy.mobile()`（v1 只开商品）下**页面消费值对象**的分支。
  // 值对象本身由 `master_data_policy_test` / `selfcheck_app` 钉；这里钉的是
  // 「三个能力各走对路」—— 三处 `if` 位置错一个，值对象测试全绿也发现不了。
  group('手机端 MasterDataPolicy.mobile()（§CV·七）', () {
    testWidgets('＋新建商品 ⇒ 出**建档表单**（商品本机可建）', (WidgetTester tester) async {
      await tester.pumpWidget(page(policy: const MasterDataPolicy.mobile()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sale-pick-product')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建商品'));
      await tester.pumpAndSettle();

      expect(
        find.text('这一步在电脑上做'),
        findsNothing,
        reason: '商品在手机 v1 是**可建**的 —— 不能弹引导（条件写反会在这里暴露）',
      );
      expect(find.text('新增商品'), findsOneWidget, reason: '出的是建档表单');
    });

    testWidgets('＋新建客户 ⇒ 出**引导**（手机没装队列出口 ⇒ 不给写不通的路）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(page(policy: const MasterDataPolicy.mobile()));
      await tester.pumpAndSettle();

      // 页头「散客（当场结清）」= 未选客户时的展示 ⇒ 点它开客户选择器
      await tester.tap(find.text('散客（当场结清）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建客户（用上面的名称）'));
      await tester.pumpAndSettle();

      expect(
        find.text('这一步在电脑上做'),
        findsOneWidget,
        reason: '往来 v1 禁建 ⇒ 保留入口 + 引导到电脑（与商品分属不同分支）',
      );
    });
  });

  // ---- #25（§CV·二五 裁定「甲」）：同一行内换商品 ⇒ 单价必须**重新预填** ----
  //
  // ⚠️ 三页是**三份独立实现** ⇒ 三页各钉一遍（不假设同款，见 §CV·二五 裁定 §四）。
  // ⚠️ 第 ② 步在修复前**必红** —— 这就是本用例的反向灵敏度。
  testWidgets('#25 换商品 ⇒ 单价重填（含重选）；手改不阻挡覆盖；取消不覆盖', (WidgetTester tester) async {
    // 第二个商品：售价必须与红富士（5.00）不同，否则断言分辨不出来
    ProductDao(db).insert(
      Product(
        id: newId(),
        code: 'P0009',
        name: '黄金梨',
        costPrice: 700,
        sellPrice: 1250,
        createdAt: 9,
        updatedAt: 9,
      ),
    );

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    TextField priceField() =>
        tester.widget<TextField>(find.byKey(const Key('sale-price')));
    TextField qtyField() =>
        tester.widget<TextField>(find.byKey(const Key('sale-qty')));

    /// 打开选择器并选中 [name]。
    ///
    /// ② 之后行卡的商品格是**输入框**（可手打），选商品统一点右边的小图标
    /// —— 不再需要「当前显示的是哪个名字」来决定点哪里。
    Future<void> pick(String keyword, String name) async {
      await openPicker(tester);
      await tester.enterText(find.byKey(const Key('picker-search')), keyword);
      await tester.pumpAndSettle();
      // ⚠️ 结果行一律用 `widgetWithText(ListTile, …)`：`find.text` 连搜索框的
      //    `EditableText` 一起匹配
      await tester.tap(find.widgetWithText(ListTile, name));
      await tester.pumpAndSettle();
    }

    // ① 选 A（红富士苹果 售价 5.00）⇒ 预填
    await pick('红富士', '红富士苹果');
    expect(priceField().controller!.text, '5.00');

    // ② 同一行改选 B（黄金梨 售价 12.50）⇒ 【修复前必红】
    await pick('黄金梨', '黄金梨');
    expect(
      priceField().controller!.text,
      '12.50',
      reason: '换商品必须重填新商品的价 —— 旧价对新商品没有意义（#25）',
    );

    // ③ 再选回 A ⇒ 「重选同一商品」也要回到该商品的初始态
    await pick('红富士', '红富士苹果');
    expect(priceField().controller!.text, '5.00');

    // ④ **手改过**也不阻挡覆盖
    await tester.enterText(find.byKey(const Key('sale-price')), '9.99');
    await tester.pumpAndSettle();
    expect(priceField().controller!.text, '9.99');
    await pick('黄金梨', '黄金梨');
    expect(priceField().controller!.text, '12.50', reason: '手改不阻挡覆盖');

    // ⑤ 换商品**不碰数量**
    await tester.enterText(find.byKey(const Key('sale-qty')), '7');
    await tester.pumpAndSettle();
    await pick('红富士', '红富士苹果');
    expect(qtyField().controller!.text, '7', reason: '换商品只重置价与单位；数量是用户的输入');

    // ⑥ 打开选择器后**取消** ⇒ 不覆盖（`picked == null` 的对称边界）
    final String before = priceField().controller!.text;
    await openPicker(tester);
    Navigator.of(tester.element(find.byKey(const Key('picker-search')))).pop();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('picker-search')),
      findsNothing,
      reason: '前提断言：选择器真的关掉了（否则下面那条会空过）',
    );
    expect(priceField().controller!.text, before, reason: '取消选择 ⇒ 不覆盖');
  });

  // #28①（2026-10-14）：负库存提示**必须比「最小单位」** —— 库存快照是「瓶」，
  // 而录入框里的数字是**录入单位**的原始数（3 箱）。原来直接拿 3 去比 20 瓶
  // ⇒ 按箱录入**必然漏报**（实际 36 > 20 已经超卖）。
  testWidgets('#28 按「箱」录入超库存 ⇒ 必须报负库存（原来拿 3 比 20 瓶，漏报）', (
    WidgetTester tester,
  ) async {
    final Product milk = Product(
      id: newId(),
      code: 'P0002',
      name: '蒙牛纯牛奶',
      unit: '瓶',
      sellPrice: 250,
      packageUnit: '箱',
      packageSize: 12,
      createdAt: 2,
      updatedAt: 2,
    );
    ProductDao(db).insert(milk);
    // 先建立 20 瓶的正库存（页外直接走服务层）
    purchases.create(
      PurchaseDraft(
        date: '2026-09-27',
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: milk.id,
            productName: '蒙牛纯牛奶',
            quantity: '20',
            unitPrice: '1.00',
          ),
        ],
        payments: <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: accountId, amount: '20'),
        ],
      ),
      now: 1700000000000,
    );

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 选牛奶（⚠️ 结果行按 ListTile 找 —— 搜索框里的字也会被 `find.text` 命中）
    await tester.tap(find.byKey(const Key('sale-pick-product')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('picker-search')), '蒙牛');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '蒙牛纯牛奶'));
    await tester.pumpAndSettle();

    // 切到「箱」
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, '箱'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '箱'));
    await tester.pumpAndSettle();

    // 反向对照：1 箱 = 12 瓶 ≤ 20 ⇒ **不该**报（不然就是「一律报」）
    await tester.enterText(find.byKey(const Key('sale-qty')), '1');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('负库存记账'),
      findsNothing,
      reason: '1 箱（=12 瓶）没超过 20 瓶的库存 ⇒ 不该报',
    );

    // ⭐ 回归点：3 箱 = 36 瓶 > 20 ⇒ 必须报（改前拿「3」比「20」⇒ 漏报）
    await tester.enterText(find.byKey(const Key('sale-qty')), '3');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('负库存记账'),
      findsOneWidget,
      reason: '#28①：录入单位是「箱」，库存是「瓶」—— 必须换算到最小单位再比',
    );
  });

  // #44（甲裁定 2026-10-14）：**数量框还空着时不该报负库存**。
  // `#28①` 把 `qty` 由 `row.quantityValue`（空 / ≤0 / 非法 ⇒ `null`）换成
  // `row.baseQuantityValue`，而后者内部是 `quantityValue ?? 0` + `toBaseQuantity`
  // （`entryUnit == null` ⇒ 原样返回 `entryQuantity`）⇒ **空框被 0 兜底**
  // ⇒ 判定式退化成 `0 > estimated` ⇒ `estimated < 0`（本地快照为负 + 有未同步销售）
  // 时**假告警**，还把 M08 的「本地未同步」说明挤掉（负库存分支在三元里优先）。
  // ⚠️ 本用例第 ① 条在修复前**必红** —— 这就是它的反向灵敏度（裁定 §三）。
  testWidgets('#44 数量框还空着 + 本地快照为负 + 有未同步销售 ⇒ 不报负库存，M08 说明不被挤掉', (
    WidgetTester tester,
  ) async {
    enqueueSale('q-44', productId); // 未同步卖 1 ⇒ estimated = 0 + (-1) = -1

    await tester.pumpWidget(
      page(
        stockDelta: StockDelta(db: db, queue: SyncQueueDao(db)),
      ),
    );
    await tester.pumpAndSettle();
    await pickFirstProduct(tester); // ⚠️ 只选商品，**不填数量**

    // ① 回归点：没填数量 ⇒ 不该出红字「本单会按负库存记账」
    expect(
      find.textContaining('负库存记账'),
      findsNothing,
      reason: '#44：数量空 ⇒ qty 必须是 null（不是 0）—— 0 > -1 会让空框也报负库存',
    );
    // ② 双重要求：假告警走负库存分支 ⇒ 会挤掉 `local != 0` 分支的 M08 说明
    expect(
      find.textContaining('本地未同步'),
      findsOneWidget,
      reason: '#44：数量空着时 M08 的「权威 + 本地未同步」说明要正常显示',
    );
  });

  // #37甲（2026-10-14）：**点过页内空白之后 `Ctrl+S` 仍必须能保存**。
  // 机理：`EditableText.onTapOutside`（**桌面专属**）的默认动作就是 `unfocus()`，
  // 默认 `UnfocusDisposition.scope` ⇒ 焦点升到**最近的外层 scope**。页级原来用
  // `Focus`（不是 scope）⇒ 焦点会升到**路由的** `FocusScope`，而 `CallbackShortcuts`
  // 在它**下面** ⇒ 按键上溯不再经过它 ⇒ 静默失效（用户实测：填好单子按 Ctrl+S 没反应）。
  testWidgets('#37 点页内空白（unfocus 到 scope）之后 Ctrl+S 仍然能保存', (
    WidgetTester tester,
  ) async {
    stockUp();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await fillRow(tester, qty: '1');
    await tester.tap(find.text('全款'));
    await tester.pumpAndSettle();

    // 复现「点页内空白」：把焦点升到最近的外层 scope
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    // 真发按键（不是调回调）—— 必须真的**经过** `CallbackShortcuts`
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('已保存'),
      findsOneWidget,
      reason:
          '#37：页级是 `Focus` 时 `unfocus()` 会把焦点升到**路由的** scope ⇒ '
          'Ctrl+S 静默失效；改成 `FocusScope` 后焦点留在页内 ⇒ 恒生效',
    );
  });

  // ============================================================ 草稿自动保存（①）
  //
  // 真实诉求批 ①（2026-10-24，§CV·一百零二）。用户裁定：1.5 s 防抖、
  // **不自动填**（挂橙条）、保存成功/放弃/取消即删。
  //
  // ⚠️ 这几条用例是**防止数据丢失**功能的护栏 —— 它们红了就是「用户填的东西
  // 没被救回来」，比任何性能问题都严重。
  group('草稿自动保存（①）', () {
    late DraftsStore store;

    setUp(() {
      store = DraftsStore(dataDirectory: box.path);
    });

    /// 往盘里塞一份「上次的草稿」（3 瓶 × ¥5.00）
    void seedDraft({String quantity = '3'}) {
      store.writeSync(
        DraftKind.sale,
        saleDraftToJson(
          SaleDraft(
            date: '2026-10-24',
            remark: '上次填的',
            lines: <SaleLineDraft>[
              SaleLineDraft(
                productId: productId,
                productName: '红富士',
                quantity: quantity,
                unitPrice: '5.00',
              ),
            ],
          ),
        ),
      );
    }

    testWidgets('进页发现草稿 ⇒ 橙条出现，但**表单不自动填**', (WidgetTester tester) async {
      seedDraft(quantity: '3');
      await tester.pumpWidget(page(drafts: store));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('sale-draft-banner')),
        findsOneWidget,
        reason: '① 有草稿就要说出来（不自动填，先问）',
      );
      final TextField qty = tester.widget<TextField>(
        find.byKey(const Key('sale-qty')),
      );
      expect(
        qty.controller!.text,
        isEmpty,
        reason: '① 用户可能想开新单 —— **绝不自动填**（裁定甲）',
      );
    });

    // F1（2026-10-25 复跑）：待恢复的草稿不许被 dispose 删掉。
    testWidgets('有未恢复的草稿 ⇒ 离开页面不得删掉它（F1）', (WidgetTester tester) async {
      seedDraft();
      await tester.pumpWidget(page(drafts: store));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sale-draft-banner')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(
        store.exists(DraftKind.sale),
        isTrue,
        reason: '待恢复 ≠ 用户清空：这份草稿不许被 dispose 删掉',
      );

      await tester.pumpWidget(page(drafts: store));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sale-draft-banner')), findsOneWidget);
    });

    testWidgets('点「恢复」⇒ 数量/备注被填回来，橙条收起', (WidgetTester tester) async {
      seedDraft(quantity: '3');
      await tester.pumpWidget(page(drafts: store));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sale-draft-restore')));
      await tester.pumpAndSettle();

      final TextField qty = tester.widget<TextField>(
        find.byKey(const Key('sale-qty')),
      );
      expect(qty.controller!.text, '3', reason: '① 恢复后数量要一字不差');
      expect(find.text('上次填的'), findsOneWidget, reason: '备注也要回来');
      expect(
        find.byKey(const Key('sale-draft-banner')),
        findsNothing,
        reason: '恢复完橙条该收起',
      );
    });

    testWidgets('点「放弃」⇒ 草稿文件被删，表单仍是空的', (WidgetTester tester) async {
      seedDraft();
      await tester.pumpWidget(page(drafts: store));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sale-draft-discard')));
      await tester.pumpAndSettle();

      expect(store.exists(DraftKind.sale), isFalse, reason: '① 放弃了就别再问');
      expect(find.byKey(const Key('sale-draft-banner')), findsNothing);
      final TextField qty = tester.widget<TextField>(
        find.byKey(const Key('sale-qty')),
      );
      expect(qty.controller!.text, isEmpty, reason: '放弃 ≠ 恢复');
    });

    testWidgets('输入后 1.5 s 落盘（防抖）', (WidgetTester tester) async {
      await tester.pumpWidget(page(drafts: store));
      await tester.pumpAndSettle();
      expect(store.exists(DraftKind.sale), isFalse, reason: '前置：还没有草稿');

      await tester.enterText(find.byKey(const Key('sale-qty')), '7');
      await tester.pump(); // 让 onChanged 生效
      expect(
        store.exists(DraftKind.sale),
        isFalse,
        reason: '① 防抖期内不该落盘（否则每敲一键一次写盘）',
      );

      await tester.pump(const Duration(milliseconds: 1600));
      expect(store.exists(DraftKind.sale), isTrue, reason: '① 停手 1.5 s 后落盘');

      final SaleDraft? back = saleDraftFromJson(store.read(DraftKind.sale));
      expect(back, isNotNull);
      expect(back!.lines.first.quantity, '7', reason: '① 存的是用户输入原文');
    });

    testWidgets('空表单不写草稿（否则下次进页挂个空橙条）', (WidgetTester tester) async {
      await tester.pumpWidget(page(drafts: store));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 2000));
      expect(store.exists(DraftKind.sale), isFalse);
    });

    testWidgets('读不懂的草稿 ⇒ 进页不挂橙条，且坏文件被删掉', (WidgetTester tester) async {
      final String path = store.pathOf(DraftKind.sale);
      Directory(p.dirname(path)).createSync(recursive: true);
      File(path).writeAsStringSync('{ 坏 JSON');
      await tester.pumpWidget(page(drafts: store));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sale-draft-banner')), findsNothing);
      expect(File(path).existsSync(), isFalse, reason: '读不了就删，别再打扰');
    });
  });
  // ========================================================== 无缝建档（②）
  //
  // 真实诉求批 ②（2026-10-25，§CV·一百零五）。家人拿着进货单直接录，
  // 不知道要先建商品档案 ⇒ 允许在明细行**手打名字**，保存时确认一次。
  //
  // 这三条是「不能错」的护栏：静默建档会把错别字固化成商品；
  // 每次都弹窗会让手打这件事变得比建档还烦。
  group('无缝建档（②）', () {
    Finder nameField([int at = 0]) =>
        find.byKey(const Key('sale-product-name')).at(at);

    Future<void> typeName(
      WidgetTester tester,
      String name, {
      int at = 0,
    }) async {
      await tester.enterText(nameField(at), name);
      await tester.pumpAndSettle();
    }

    testWidgets('手打名字 ⇒ 保存时弹确认；点「先建档再保存」⇒ 建档 + 落单', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      await typeName(tester, '蒙牛纯牛奶');
      await tester.enterText(find.byKey(const Key('sale-qty')), '3');
      await tester.enterText(find.byKey(const Key('sale-price')), '5.00');
      await tester.pumpAndSettle();
      await tester.tap(find.text('全款'));
      await tester.pumpAndSettle();

      await tapSave(tester);
      expect(
        find.byKey(const Key('missing-product-dialog')),
        findsOneWidget,
        reason: '② 没建档的名字必须先问一句（错别字不能被静默固化）',
      );
      expect(
        find.textContaining('蒙牛纯牛奶'),
        findsWidgets,
        reason: '② 对话框要把名字**原样**摆出来',
      );

      await tester.tap(find.byKey(const Key('missing-product-create')));
      await tester.pumpAndSettle();

      final List<Map<String, Object?>> made = db.raw.select(
        "SELECT * FROM products WHERE TRIM(name) = '蒙牛纯牛奶'",
      );
      expect(made, hasLength(1), reason: '② 建档了');
      expect(made.single['sell_price'], 500, reason: '② 销售单价 = 售价');
      expect(
        db.raw.select(
          "SELECT COUNT(*) AS c FROM documents WHERE doc_type = 'sale'",
        ),
        hasLength(1),
        reason: '② 单也落了',
      );
      expect(
        find.byKey(const Key('missing-product-dialog')),
        findsNothing,
        reason: '② 关掉了',
      );
    });

    testWidgets('点「取消」⇒ 不建档、不保存，输入一个都不丢', (WidgetTester tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      await typeName(tester, '打错字的货');
      await tester.enterText(find.byKey(const Key('sale-qty')), '2');
      await tester.enterText(find.byKey(const Key('sale-price')), '1.00');
      await tester.pumpAndSettle();
      await tester.tap(find.text('全款'));
      await tester.pumpAndSettle();

      await tapSave(tester);
      await tester.tap(find.byKey(const Key('missing-product-cancel')));
      await tester.pumpAndSettle();

      expect(
        db.raw.select(
          "SELECT COUNT(*) AS c FROM products WHERE name = '打错字的货'",
        ),
        hasLength(1),
        reason: '② 取消 ⇒ 不建档',
      );
      expect(
        db.raw.select(
          "SELECT COUNT(*) AS c FROM documents WHERE doc_type = 'sale'",
        ),
        hasLength(1),
        reason: '② 取消 ⇒ 不落单',
      );
      expect(
        tester.widget<TextField>(nameField()).controller!.text,
        '打错字的货',
        reason: '② **不丢输入**（取消 ≠ 清空）',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('sale-qty')))
            .controller!
            .text,
        '2',
      );
    });

    testWidgets('两个缺档行 ⇒ **一个**对话框列全（不弹三次）', (WidgetTester tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.tap(find.text('加一行'));
      await tester.pumpAndSettle();

      await typeName(tester, '甲货', at: 0);
      await typeName(tester, '乙货', at: 1);
      await tester.enterText(find.byKey(const Key('sale-qty')).at(0), '1');
      await tester.enterText(find.byKey(const Key('sale-price')).at(0), '1.00');
      await tester.enterText(find.byKey(const Key('sale-qty')).at(1), '1');
      await tester.enterText(find.byKey(const Key('sale-price')).at(1), '2.00');
      await tester.pumpAndSettle();
      // 两行时「全款」滚出了 800×600 视口 ⇒ 必须先滚到可见再点
      await tapFinder(tester, find.text('全款'));

      await tapSave(tester);
      expect(find.byKey(const Key('missing-product-dialog')), findsOneWidget);
      expect(find.text('· 甲货'), findsOneWidget, reason: '② 一次列全');
      expect(find.text('· 乙货'), findsOneWidget);

      await tester.tap(find.byKey(const Key('missing-product-create')));
      await tester.pumpAndSettle();
      expect(
        db.raw.select("SELECT name FROM products WHERE name IN ('甲货','乙货')"),
        hasLength(2),
        reason: '② 两个都建出来了',
      );
    });

    testWidgets('名字与已有商品一字不差 ⇒ **不弹框**，直接绑定（④甲）', (WidgetTester tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      // 「红富士苹果」是 setUp 里建好的商品（售价 5.00）
      await typeName(tester, '红富士苹果');
      await tester.enterText(find.byKey(const Key('sale-qty')), '4');
      // 手打名字**不会**预填单价（没经过商品选择器）⇒ 用户自己填
      await tester.enterText(find.byKey(const Key('sale-price')), '5.00');
      await tester.pumpAndSettle();
      await tapFinder(tester, find.text('全款'));

      await tapSave(tester);
      expect(
        find.byKey(const Key('missing-product-dialog')),
        findsNothing,
        reason: '④甲：同名自动匹配 —— 拿弹窗打扰用户是错的',
      );
      expect(
        db.raw.select(
          "SELECT COUNT(*) AS c FROM products WHERE name = '红富士苹果'",
        ),
        hasLength(1),
        reason: '④甲：不许出现两个同名商品（库存会被拆成两半）',
      );
      final List<Map<String, Object?>> lines = db.raw.select(
        'SELECT product_id FROM document_lines',
      );
      expect(lines.single['product_id'], productId, reason: '绑到了已有商品');
    });

    testWidgets('手机队列出口（QueueSink）⇒ **没有**手打输入框（不给假承诺）', (
      WidgetTester tester,
    ) async {
      final Db queueDb = Db.openInMemory(foreignKeys: false);
      addTearDown(queueDb.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SalePage(
              service: service,
              productService: products,
              partyService: partyService,
              sink: QueueSink(queue: SyncQueueDao(queueDb)),
              masterDataPolicy: const MasterDataPolicy.desktop(),
              masterDataSink: ServiceMasterSink(products),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('sale-product-name')),
        findsNothing,
        reason: '② 队列出口建不了主数据 —— 放开手打只会「填了名字存不进去」',
      );
      expect(find.text('点此选商品'), findsOneWidget, reason: '② 手机端保持原样');
    });
  });

  // F2（2026-10-25 复跑）：保存成功后表单只留**客户**，而
  // `saleDraftHasContent` 把 `partyId != null` 算作"有内容" ⇒
  // 离开页面时旧实现把这堆残留写成草稿，下次进页面弹「恢复草稿」，
  // 恢复出来是空表单。⚠️ 散客（不选客户）**测不到**这条。
  testWidgets('F2：选了客户 + 保存 ⇒ 离开页面不留「只有客户」的假草稿', (WidgetTester tester) async {
    final DraftsStore draftsStore = DraftsStore(dataDirectory: box.path);
    await tester.pumpWidget(page(drafts: draftsStore));
    await tester.pumpAndSettle();

    // ① 先选客户 —— F2 的复现前提
    await tester.tap(find.text('散客（当场结清）'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '李姐'));
    await tester.pumpAndSettle();

    await fillRow(tester);
    await tapFinder(tester, find.text('全款'));
    await tapSave(tester);

    expect(draftsStore.exists(DraftKind.sale), isFalse, reason: '保存成功即删');
    expect(find.text('李姐'), findsOneWidget, reason: '保存后保留客户 —— 这正是假草稿的来源');

    // ② 离开页面（dispose → _writeDraftNow）
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(
      draftsStore.exists(DraftKind.sale),
      isFalse,
      reason: 'F2：保存后的残留不是草稿，不许写',
    );
  });

  // ============================================ F18 适老化（2026-10-26 裁定甲）
  //
  // 现场（界面大小 = 超大，真机截图 `big-2.png` / `big-3.png`）：
  // 1. 日期折行断在**数字中间**（`2026-1` / `0-26`）；
  // 2. 收款「金额」输入框被挤成一条缝（**必填**项，几乎看不见）；
  // 3. 「全款」按钮只剩 43 px 高、文字被裁（`ui_principles.md` §二 要求 ≥44）。
  //
  // 根因都是同一类：**固定比例分栏**（`Row` + `Expanded(flex: 3/2)`）在字放大后
  // 没跟着放大 —— 格子还是那个格子，字变成两倍。⇒ 放不下就**上下两行**。

  /// 手机逻辑尺寸（1220×2712 物理 / dpr 3.1 ≈ 393×872）+ 超大字号。
  ///
  /// ⚠️ **必须缩画布**：默认测试画布 800 宽，比手机宽一倍 ——
  /// F18-2 在 800 宽下"够放"，测不出真机那条缝（第一版就是这么假绿的）。
  Future<void> pumpPhoneLarge(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(393, 872));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(page(textScale: 1.8));
  }

  testWidgets('F18-1：超大字号下「日期」不能挤在同一行被折断', (WidgetTester tester) async {
    await pumpPhoneLarge(tester);
    await tester.pumpAndSettle();

    final Rect party = tester.getRect(find.text('客户'));
    final Rect date = tester.getRect(find.text('日期'));
    expect(
      date.top,
      greaterThan(party.top),
      reason: 'F18-1：放不下就上下两行 —— 从前 5:3 分栏把 2026-10-26 断成 2026-1 / 0-26',
    );
  });

  testWidgets('F18-2：超大字号下「金额」输入框不能被挤成一条缝', (WidgetTester tester) async {
    await pumpPhoneLarge(tester);
    await tester.pumpAndSettle();

    final Rect amount = tester.getRect(
      find.byKey(const Key('sale-pay-amount')),
    );
    expect(
      amount.width,
      greaterThan(200),
      reason: 'F18-2：它是**必填**项（留空 = 全部赊账），不能被账户下拉挤没',
    );
  });

  // ⚠️ **F18-3 的更正（2026-10-26 22:5x）**：原来报的是「全款按钮只有 43 px、
  // 文字被裁」。实测**按钮本身 68.2 × 48.0** —— 高度 48，本来就达标。
  //
  // 那个 43 是 `uiautomator` 报的**物理像素**、而且被**滚动视口裁掉了大半**
  // （43 / dpr 3.1 ≈ 14 逻辑像素，就是"只露出一点"）。⇒ **误判，不是布局缺陷**。
  //
  // 这条留作**护栏**（当前 48，绿）：将来谁把 `TextButton` 换成 `isDense`
  // 或塞进受限高度的 Row，这里会红。
  testWidgets('F18-3（护栏）：「全款」按钮的点击高度必须 ≥ 44', (WidgetTester tester) async {
    await pumpPhoneLarge(tester);
    await tester.pumpAndSettle();

    final Rect full = tester.getRect(
      find.byKey(const Key('sale-full-payment')),
    );
    expect(
      full.height,
      greaterThanOrEqualTo(44),
      reason: 'ui_principles.md §二 要求 44×44（实测 48，达标）',
    );
  });

  // ------------------------------------------------------------ 商品名自动补全（2026-10-29）
  //
  // 落地依据：`docs/proposals/商品名称自动补全-方案.md`（裁定 D1′乙 前缀豁免 / D2′甲 只做桌面）。
  // 这里钉三件最容易被改坏的事：候选出得来、前缀豁免不问、真要换才问。
  group('商品名自动补全', () {
    /// 再放两个商品，让候选有得选（夹具里原本只有「红富士苹果」）
    void seedMore() {
      final int t = 1700000000000;
      for (final (String code, String name) in <(String, String)>[
        ('P0002', '大米'),
        ('P0003', '可口可乐'),
      ]) {
        ProductDao(db).insert(
          Product(
            id: newId(),
            code: code,
            name: name,
            sellPrice: 1500,
            createdAt: t,
            updatedAt: t,
          ),
        );
      }
    }

    testWidgets('输入部分名称 ⇒ 弹出候选（副标题带售价）', (WidgetTester tester) async {
      seedMore();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('sale-product-name')), '大');
      await tester.pumpAndSettle();

      expect(find.text('大米'), findsWidgets, reason: '「大」应命中「大米」');
      expect(
        find.textContaining('售价 ¥15.00'),
        findsWidgets,
        reason: '销售页副标题显示售价（采购页显示进价）',
      );
    });

    testWidgets('前缀豁免：输入「大」选「大米」**不问**覆盖', (WidgetTester tester) async {
      seedMore();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('sale-product-name')), '大');
      await tester.pumpAndSettle();
      await tester.tap(find.text('大米').last);
      await tester.pumpAndSettle();

      expect(
        find.text('换掉这一行的商品？'),
        findsNothing,
        reason: '用户正在搜索（输入是候选的前缀）⇒ 直接填，别烦他（裁定 D1′乙）',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('sale-product-name')))
            .controller!
            .text,
        '大米',
      );
    });

    testWidgets('真要换（输入的不是候选前缀）⇒ 弹确认；取消后原值不变', (WidgetTester tester) async {
      seedMore();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      // 「米」是「大米」的**包含**匹配、不是前缀 ⇒ 按裁定 D1′乙 这时要问。
      // （别用「大」来测：它本来就是「大米」的前缀，按裁定**不该**问。）
      await tester.enterText(find.byKey(const Key('sale-product-name')), '米');
      await tester.pumpAndSettle();
      await tester.tap(find.text('大米').last);
      await tester.pumpAndSettle();

      expect(find.text('换掉这一行的商品？'), findsOneWidget);
      await tester.tap(find.byKey(const Key('replace-product-cancel')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const Key('sale-product-name')))
            .controller!
            .text,
        '米',
        reason: '取消 ⇒ 不换，框里还是用户刚打的字',
      );
    });

    testWidgets('选中候选 ⇒ 单价按售价预填', (WidgetTester tester) async {
      seedMore();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('sale-product-name')), '大米');
      await tester.pumpAndSettle();
      await tester.tap(find.text('大米').last);
      await tester.pumpAndSettle();

      expect(find.text('15.00'), findsWidgets, reason: '选中后单价预填该商品售价（¥15.00）');
    });
  });

  // ------------------------------------------------------------ 回车 ⇒ 立刻建档（2026-10-29）
  //
  // 提案 §四·B / 诉求 6：「输入的内容没有匹配项，则询问是否立刻创建新商品」。
  // 只认**回车**（用户明确表示「名字打完了」）；失焦不触发 —— 失焦时机太多
  // （点保存、点合计、切窗口），每次都弹比原来的问题更烦。
  group('回车 ⇒ 立刻建档', () {
    testWidgets('名字不在库里 ⇒ 回车弹「没找到这个商品」；先不建 ⇒ 不建档', (WidgetTester tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      final int before = products.count();

      await tester.enterText(
        find.byKey(const Key('sale-product-name')),
        '还没建过的商品',
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();

      expect(find.text('没找到这个商品'), findsOneWidget);
      expect(find.textContaining('还没建过的商品'), findsWidgets);

      await tester.tap(find.byKey(const Key('missing-product-later')));
      await tester.pumpAndSettle();

      expect(products.count(), before, reason: '选了「先不建」就不该多出商品');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('sale-product-name')))
            .controller!
            .text,
        '还没建过的商品',
        reason: '名字留着 —— 保存时仍由「缺商品」对话框兜底',
      );
    });

    testWidgets('名字**已经在库里** ⇒ 回车不弹建档（照旧跳下一格）', (WidgetTester tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('sale-product-name')),
        '红富士苹果',
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();

      expect(
        find.text('没找到这个商品'),
        findsNothing,
        reason: '库里有这个名字 ⇒ 回车就是「往下走」，别打扰',
      );
    });

    testWidgets('选「建档」⇒ 打开建档对话框，名字已预填', (WidgetTester tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('sale-product-name')),
        '新的可乐',
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('missing-product-create')));
      await tester.pumpAndSettle();

      // 建档对话框里名称已预填（复用无缝建档，不是另起一套）
      expect(
        find.widgetWithText(TextField, '新的可乐'),
        findsWidgets,
        reason: '`showProductFormDialog(initialName:)` 要把名字带过去',
      );
    });
  });
}

/// 只用来数 `stockSnapshot()` 被调了几次（性能回归的机械判据）
class _CountingSaleService extends SaleService {
  _CountingSaleService({
    required super.engine,
    required super.queries,
    required this.onSnapshot,
  });

  final void Function() onSnapshot;

  @override
  Map<String, int> stockSnapshot() {
    onSnapshot();
    return super.stockSnapshot();
  }
}
