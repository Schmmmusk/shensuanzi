// 退货页（`ReturnPage`）的 widget 测试 —— §BI R2。
//
// 与 `purchase_page_test.dart` 同款：临时库走真实路径（真实建库、真实开原单、
// 真实退货落库）。覆盖两条主路径：
// ① 挂账退货 e2e（数量自动带出累计比例法金额 → 确认对话框 → 落库）；
// ② 拒收（fullReturn 预填全部可退量 → 保存 → 原送货单 cancelled，裁定 2）。
//
// 运行：`flutter test`（本机由用户执行）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/return_page.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late RuleEngine engine;
  late QueryDao queries;
  late ProductDao productDao;
  late StockLedgerDao stock;
  late PartyLedgerDao partyLedger;
  late DocumentDao documents;
  late ReturnService returns;
  late String productId;
  late String accountId;
  late String customerId;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_return_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    engine = RuleEngine(db);
    queries = QueryDao(db);
    productDao = ProductDao(db);
    stock = StockLedgerDao(db);
    partyLedger = PartyLedgerDao(db);
    documents = DocumentDao(db);
    returns = ReturnService(engine: engine, queries: queries);

    final int t = DateTime.now().millisecondsSinceEpoch;
    final Product product = Product(
      id: newId(),
      code: 'P001',
      name: '蒙牛纯牛奶',
      unit: '瓶',
      packageUnit: '箱',
      packageSize: 12,
      sellPrice: 250,
      createdAt: t,
      updatedAt: t,
    );
    productDao.insert(product);
    productId = product.id;

    final Account cash = Account(
      id: newId(),
      name: '现金',
      type: AccountType.cash,
      createdAt: t,
      updatedAt: t,
    );
    AccountDao(db).insert(cash);
    accountId = cash.id;

    final Party customer = Party(
      id: newId(),
      name: '客户甲',
      roles: const <PartyRole>[PartyRole.customer],
      createdAt: t,
      updatedAt: t,
    );
    PartyDao(db).insert(customer);
    customerId = customer.id;
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  String idOf(String docNo) => db.raw
      .select('SELECT id FROM documents WHERE doc_no = ?', <Object?>[docNo])
      .first['id']! as String;

  /// 夹具：卖 3 箱（36 瓶 × 派生价，合计 ¥750）给客户甲，全款。
  Document sell3Boxes() {
    final SaleService sales = SaleService(engine: engine, queries: queries);
    final SaleSaved saved = sales.create(
      SaleDraft(
        partyId: customerId,
        partyName: '客户甲',
        date: '2026-10-04',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: productId,
            productName: '蒙牛纯牛奶',
            quantity: '3',
            unitPrice: '250',
            entryUnit: '箱',
            baseUnit: '瓶',
            packageUnit: '箱',
            packageSize: 12,
          ),
        ],
        payments: <SalePaymentDraft>[
          SalePaymentDraft(accountId: accountId, accountName: '现金', amount: '750'),
        ],
      ),
    );
    return documents.findById(idOf(saved.docNo))!;
  }

  int bookQuantity() => stock
      .ofProduct(productId)
      .fold(0, (int sum, StockLedger e) => sum + e.quantity);

  Widget page(Document original, {bool fullReturn = false}) => MaterialApp(
    // ⚠️ 不能拿 ReturnPage 当 home（唯一路由）：保存成功后会 pop 回上一页，
    // pop 完没有底层 Scaffold ⇒ SnackBar 无处安放、找不到「退货单」（§BI·二·补 6）。
    // 垫一个「单据页」占位，与真实 App 的「详情页 → 退货页」结构一致。
    routes: <String, WidgetBuilder>{
      '/': (_) => const Scaffold(body: SizedBox.shrink()),
      '/return': (_) => ReturnPage(
        original: original,
        service: returns,
        fullReturn: fullReturn,
      ),
    },
    initialRoute: '/return',
  );

  testWidgets('挂账退货 e2e：数量一填金额自动带出 → 确认对话框 → 落库', (
    WidgetTester tester,
  ) async {
    final Document original = sell3Boxes();

    await tester.pumpWidget(page(original));

    // 配额显示按**最小单位**（瓶），箱换算单独一行说清 ——
    // §BI·二·补 3 回归：曾把瓶数缀「箱」（原量 120 箱），用户被误导填 120
    expect(
      find.textContaining('原量 36 瓶 / 已退 0 瓶 / 可退 36 瓶'),
      findsOneWidget,
      reason: '三个数统一缀最小单位（瓶）',
    );
    expect(
      find.textContaining('退货数量按「箱」填写：1 箱 = 12 瓶，最多可退 3 箱'),
      findsOneWidget,
    );

    // 填数量 ⇒ 金额自动带出（累计比例法：75000 × 12/36 = 25000）
    await tester.enterText(find.byKey(Key('return-qty-$productId')), '1');
    await tester.pumpAndSettle();
    expect(
      (tester.widget<TextField>(
        find.byKey(Key('return-amount-$productId')),
      ).controller!.text),
      '250.00',
      reason: '金额默认 = 累计比例法（裁定 1：不用派生单价）',
    );
    // 实时换算亮出来：填 1 箱 = 12 瓶（金额与库存口径都以瓶为准）
    expect(find.textContaining('填 1 箱 = 12 瓶'), findsOneWidget);
    // 退款金额自动合计（§BI·二·补 4）：未手改时跟随行金额合计
    expect(
      (tester.widget<TextField>(
        find.byKey(const Key('return-refund-amount')),
      ).controller!.text),
      '250.00',
      reason: '退款金额 = 行金额合计（只在没手改时自动填）',
    );

    // 保存 → 确认对话框（裁定 4：重大操作必须确认）
    await tester.scrollUntilVisible(
      find.byKey(const Key('return-save')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('return-save')));
    await tester.pumpAndSettle();
    expect(find.text('确认退货？'), findsOneWidget);
    expect(find.textContaining('¥250.00'), findsWidgets);

    await tester.tap(find.byKey(const Key('return-confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('退货单'), findsOneWidget, reason: 'SnackBar 报单号');
    // 落库：销售出库 −36、退货入库 +12 ⇒ 账面 −24
    expect(bookQuantity(), -(36 - 12));
    // 往来：销售**已全款收清**（+750 应收 − 750 收款 = 0），
    // 退货挂账冲减 −250.00 ⇒ 余额 −250.00（负 = 我欠客户）
    expect(partyLedger.balanceOf(customerId), -25000);
  });

  testWidgets('拒收（fullReturn）：预填全部可退量，保存后原送货单 cancelled', (
    WidgetTester tester,
  ) async {
    final DeliveryService deliveries = DeliveryService(
      engine: engine,
      queries: queries,
    );
    final DeliverySaved signed = deliveries.create(
      DeliveryDraft(
        partyId: customerId,
        partyName: '客户甲',
        date: '2026-10-04',
        lines: <DeliveryLineDraft>[
          DeliveryLineDraft.fromProduct(
            productDao.findById(productId)!,
            quantity: '12',
          ),
        ],
      ),
    );
    final Document deliveryDoc = documents.findById(idOf(signed.docNo))!;
    expect(deliveryDoc.status, DocStatus.inTransit);

    await tester.pumpWidget(page(deliveryDoc, fullReturn: true));

    // 预填全部可退量：数量 12、金额 30.00（¥2.50/瓶 × 12）
    expect(
      (tester.widget<TextField>(
        find.byKey(Key('return-qty-$productId')),
      ).controller!.text),
      '12',
    );
    expect(
      (tester.widget<TextField>(
        find.byKey(Key('return-amount-$productId')),
      ).controller!.text),
      '30.00',
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('return-save')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('return-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('return-confirm')));
    await tester.pumpAndSettle();

    // 裁定 2：拒收收口 —— 原送货单 cancelled（否则在途视图永远算它）
    expect(documents.findById(deliveryDoc.id)!.status, DocStatus.cancelled);
    // 库存：送货 −12、拒收退回 +12 ⇒ 回到发货前的 0
    expect(bookQuantity(), 0);
  });

  testWidgets('选退款账户：下拉选择后页面不炸（回归：build 内查库 ⇒ value/items 不同源）', (
    WidgetTester tester,
  ) async {
    final Document original = sell3Boxes();
    await tester.pumpWidget(page(original));

    // 退款区在保存按钮附近；滚到退款金额框可见
    await tester.scrollUntilVisible(
      find.byKey(const Key('return-refund-amount')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // 展开下拉 → 选「现金」（菜单在 overlay 顶层 ⇒ .last）
    await tester.tap(find.byType(DropdownButton<Account>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('现金').last);
    await tester.pumpAndSettle();

    // 回归断言（真机踩过 2026-10-04）：旧代码在 build 里调 activeAccounts()，
    // 每次重建查库产出新 Account 实例 ⇒ 选中的旧实例在 items 里匹配不上 ⇒
    // DropdownButton 断言炸、整页卡死。修复后账户列表在 initState 查一次，
    // value 与 items 永远同源。
    final DropdownButton<Account> dropdown = tester
        .widget<DropdownButton<Account>>(find.byType(DropdownButton<Account>));
    expect(dropdown.value, isNotNull, reason: '已选中「现金」');
    expect(
      dropdown.items!
          .where((DropdownMenuItem<Account> item) => item.value == dropdown.value),
      hasLength(1),
      reason: 'value 必须能在 items 里恰好匹配一次（对象同一性）',
    );
    expect(tester.takeException(), isNull);
  });
}
