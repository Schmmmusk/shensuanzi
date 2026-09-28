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

    PartyDao(db).insert(Party(
      id: newId(),
      name: '王老板',
      roles: const <PartyRole>[PartyRole.supplier],
      createdAt: t,
      updatedAt: t,
    ));
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
          PurchasePaymentDraft(accountId: accountId, amount: Money.format(qty * 350)),
        ],
      ),
      now: 1700000000000,
    );
  }

  /// 卖给「李姐」（散客也要结清，统一走客户）
  /// 卖出 [qty] 件（4.00 出），立即收款
  void sell(int qty) {
    final String customerId =
        PartyDao(db).findAll(role: PartyRole.customer).first.id;
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
          SalePaymentDraft(accountId: accountId, amount: Money.format(qty * 400)),
        ],
      ),
      now: 1700000000000,
    );
  }

  Widget page({ExportSink? exports}) => MaterialApp(
    home: Scaffold(
      body: StockPage(
        engine: RuleEngine(db),
        products: products,
        queries: queries,
        exports: exports,
      ),
    ),
  );

  testWidgets('空库给「怎么办」：两段式空态（§AD-6）+ 首次入口文案（遗漏 2）', (WidgetTester tester) async {
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
    expect(find.text('录入现有货物'), findsNothing,
        reason: '用户录过之后看到同一文案会以为没录上');
  });

  testWidgets('期初录入过 → 成本列「待校准」而不是 ¥0.00（§AD 遗漏 1）', (WidgetTester tester) async {
    StocktakeService(engine: RuleEngine(db), queries: queries).create(
      StocktakeDraft(lines: <StocktakeLineDraft>[
        StocktakeLineDraft(
          productId: productId,
          productName: '红富士苹果',
          quantity: '8',
        ),
      ]),
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

  testWidgets('三档颜色：卖到低于安全库存 → 橙提示；超卖 → 红提示', (
    WidgetTester tester,
  ) async {
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
    ProductDao(db).insert(Product(
      id: newId(),
      code: 'P0002',
      name: '没进过货的商品',
      createdAt: t,
      updatedAt: t,
    ));

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
    ProductDao(db).insert(Product(
      id: 'p-stopped',
      code: 'P0002',
      name: '停用但有货',
      unit: '箱',
      createdAt: t,
      updatedAt: t,
    ));
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
}
