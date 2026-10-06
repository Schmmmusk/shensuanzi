// 店内销售开单页（`SalePage`）的 widget 测试。
//
// 与 `purchase_page_test.dart` 同构；销售特有：售价预填 / 散客结清 /
// 负库存快照告警 / 客户选择器（最近往来 + 同名追加 role）。
//
// ⚠️ 必须 `useLocalSqlite()`（§N）；商品选择器**空查询显示「最近销售」**（先搜索再点选）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/sale_page.dart';
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
      deliveries: DeliveryService(engine: RuleEngine(db), queries: QueryDao(db)),
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

    PartyDao(db).insert(Party(
      id: newId(),
      name: '李姐',
      roles: const <PartyRole>[PartyRole.customer],
      createdAt: t,
      updatedAt: t,
    ));
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  Widget page() => MaterialApp(
    home: Scaffold(
      body: SalePage(
        service: service,
        productService: products,
        partyService: partyService,
        sink: sink,
      ),
    ),
  );

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

  /// 选中第一行的商品（先搜索再点选 —— 空查询是「最近销售」，首跑为空）
  Future<void> pickFirstProduct(WidgetTester tester) async {
    await tester.tap(find.text('点此选商品'));
    await tester.pumpAndSettle();

    // ⚠️ 搜索框必须用 Key：`byType(TextField).first` 会命中弹层底下页面的输入框
    await tester.enterText(find.byKey(const Key('picker-search')), '红富士');
    await tester.pumpAndSettle();
    await tester.tap(find.text('红富士苹果').first);
    await tester.pumpAndSettle();
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

  testWidgets('空表单点保存 → 行级报「请选一个商品」', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tapBottomButton(tester, '保存 (Ctrl+S)');

    expect(find.textContaining('请选一个商品'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
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
    expect(find.textContaining('主机下次联网时会收到'), findsOneWidget);
    expect(StockLedgerDao(db).stockOf(productId), 10, reason: '客户端不落库 —— 库存不动');
    expect(SyncQueueDao(queueDb).count(), 1, reason: '入队 1 条');
  });

  testWidgets('散客欠款 → 报「散客要当场结清」', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester); // 不点全款 → 全赊
    await tapBottomButton(tester, '保存 (Ctrl+S)');

    expect(find.textContaining('散客要当场结清'), findsOneWidget);
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

  testWidgets('选客户 + 部分收款 → SnackBar 带累计欠款；售出单价可改', (WidgetTester tester) async {
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

  testWidgets('客户选择器：空查询显示「最近往来」；新建同名 → 追加 role 不建第二条', (WidgetTester tester) async {
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
        db.raw.select("SELECT COUNT(*) AS n FROM parties WHERE name = '老王'")
            .first['n']! as int;
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

    expect(find.text('点此选商品'), findsOneWidget);
    expect(find.text('放弃这次开单？'), findsNothing);
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

  testWidgets('「顾客给了」小于应收 → 显示「不够」（内联橙），仍允许提交', (
    WidgetTester tester,
  ) async {
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
    final int cashIn = db.raw
        .select('SELECT COALESCE(SUM(amount), 0) AS s FROM money_ledger '
            'WHERE amount > 0')
        .first['s']! as int;
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
    final int cashIn = db.raw
        .select('SELECT COALESCE(SUM(amount), 0) AS s FROM money_ledger '
            'WHERE amount > 0')
        .first['s']! as int;
    expect(cashIn, 5000, reason: '⚡ 关键：找零的 50 元没进账');
  });

  testWidgets('快捷键 [收 100]：收款框填应收全额，「顾客给了」填整额', (
    WidgetTester tester,
  ) async {
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

  testWidgets('非现金账户不显示找零辅助行（找零是现金的物理属性）', (
    WidgetTester tester,
  ) async {
    // ⚠️ v3 加了「整单让价」框，账户 Dropdown 的按钮位置更低 ——
    // 800×600 视口里弹出菜单放不下（框架断言 menuLimits）。
    // 该用例临时加高视口；addTearDown 恢复，不影响别的用例。
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final int t = 1700000000000;
    AccountDao(db).insert(Account(
      id: newId(),
      name: '微信收款',
      type: AccountType.wechat,
      createdAt: t,
      updatedAt: t,
    ));

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

  testWidgets('§BG 方案A：切到「箱」⇒ 预填价 ×12、单价标注单位、显示换算说明', (WidgetTester tester) async {
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
    await tester.tap(find.text('点此选商品'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('picker-search')), '蒙牛');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '蒙牛纯牛奶'));
    await tester.pumpAndSettle();

    TextField priceField() => tester.widget<TextField>(
      find.byKey(const Key('sale-price')),
    );
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
}
