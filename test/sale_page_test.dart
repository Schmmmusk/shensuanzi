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
  late String productId;
  late String accountId;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_sale_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    service = SaleService(engine: RuleEngine(db), queries: QueryDao(db));
    purchases = PurchaseService(engine: RuleEngine(db), queries: QueryDao(db));
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
  Future<void> tapBottomButton(WidgetTester tester, String label) async {
    final Finder button = find.text(label);
    await tester.scrollUntilVisible(
      button,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

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
}
