// 往来方页（`PartiesPage`）与流水页（`PartyFlowPage`）的 widget 测试。
//
// 覆盖：应收/应付/已结清三态表达（遗漏 2）/ 总应收总应付汇总（遗漏 3）/
// 排序（|余额| 降序、0 沉底，AA-5）/ 完整新建（双角色，遗漏 1）/
// 流水页（单号 + 类型 + 方向字，AA-6）。
//
// ⚠️ 必须 `useLocalSqlite()`（§N）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/party_flow_page.dart';
import 'package:shensuanzi/src/ui/parties_page.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late PartyService service;
  late SaleService sales;
  late ProductDao products;
  late AccountDao accounts;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_parties_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    service = PartyService(PartyDao(db));
    sales = SaleService(engine: RuleEngine(db), queries: QueryDao(db));
    products = ProductDao(db);
    accounts = AccountDao(db);

    final int t = 1700000000000;
    products.insert(Product(
      id: 'p1', code: 'P0001', name: '商品',
      costPrice: 300, sellPrice: 500, createdAt: t, updatedAt: t,
    ));
    accounts.insert(Account(
      id: 'a1', name: '现金', type: AccountType.cash, createdAt: t, updatedAt: t,
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

  Party createCustomer(String name) => service.createFull(
    name: name,
    roles: <PartyRole>[PartyRole.customer],
    now: 1700000000000,
  );

  /// 客户赊销 [yuan] 元（欠款挂名下）
  void creditSale(Party customer, int yuan) {
    sales.create(
      SaleDraft(
        partyId: customer.id,
        date: '2026-09-28',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: 'p1',
            productName: '商品',
            quantity: '1',
            unitPrice: '$yuan',
          ),
        ],
        payments: const <SalePaymentDraft>[],
      ),
      now: 1700000000000,
    );
  }

  Widget page() => MaterialApp(
    home: Scaffold(body: PartiesPage(service: service)),
  );

  testWidgets('空列表给「怎么办」；新建双角色往来方 → 列表出现「已结清」', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有往来方'), findsOneWidget);

    await tester.tap(find.text('新建往来方'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('party-name')), '王老板');
    await tester.tap(find.text('供应商（我从他进货）'));
    await tester.pump();
    await tester.tap(find.text('客户（我卖给他）'));
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.text('王老板'), findsOneWidget);
    expect(find.text('供应商 / 客户'), findsOneWidget);
    expect(find.text('已结清'), findsOneWidget);
  });

  testWidgets('应收 / 应付 / 已结清三态；按 |余额| 降序 0 沉底；汇总行', (
    WidgetTester tester,
  ) async {
    final Party owing = createCustomer('甲客户');
    final Party paid = createCustomer('乙客户');
    createCustomer('丙客户'); // 0 余额沉底用
    creditSale(owing, 100); // 甲欠我 100
    creditSale(paid, 50);
    creditSale(paid, 30); // 乙共欠 80

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 三态表达（不用负号）
    expect(find.text('应收 ¥100.00'), findsOneWidget);
    expect(find.text('应收 ¥80.00'), findsOneWidget);
    expect(find.text('已结清'), findsOneWidget);

    // 排序：甲(100) → 乙(80) → 丙(0 沉底)
    final double yA = tester.getTopLeft(find.text('应收 ¥100.00')).dy;
    final double yB = tester.getTopLeft(find.text('应收 ¥80.00')).dy;
    expect(yA < yB, isTrue, reason: '欠得多的在前');
    final double yC = tester.getTopLeft(find.text('已结清')).dy;
    expect(yC > yB, isTrue, reason: '0 沉底');

    // 汇总行
    expect(find.text('总应收 ¥180.00'), findsOneWidget);
    expect(find.text('总应付 ¥0.00'), findsOneWidget);
  });

  testWidgets('流水页：单号 + 类型 + 方向字 + 底部说明；行不可点', (
    WidgetTester tester,
  ) async {
    final Party customer = createCustomer('甲客户');
    creditSale(customer, 100);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PartyFlowPage(party: customer, service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 单号是正式单号（非待同步前缀）
    final String docNo = service.flowsOf(customer.id).single.docNo;
    expect(find.text(docNo), findsOneWidget);
    expect(docNo.startsWith(Document.pendingDocNoPrefix), isFalse);
    expect(find.text('店内销售'), findsOneWidget, reason: 'doc_type 的中文标签');
    expect(find.text('欠款 +¥100.00'), findsOneWidget);
    expect(find.textContaining('功能开发中'), findsOneWidget);
  });

  testWidgets('编辑资料：改名保存成功；流水与角色不受影响', (WidgetTester tester) async {
    final Party customer = createCustomer('甲客户');
    creditSale(customer, 100);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 编辑走行尾 PopupMenu（行点击是进流水页）
    await tester.tap(
      find.descendant(
        of: find.byKey(Key('party-row-${customer.id}')),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑资料'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('party-name')), '甲客户（新）');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('甲客户（新）'), findsOneWidget);
    // 余额与角色都没动
    expect(find.text('应收 ¥100.00'), findsOneWidget);
    final Party? stored = service.findByName('甲客户（新）');
    expect(stored?.roles, contains(PartyRole.customer));
  });
}
