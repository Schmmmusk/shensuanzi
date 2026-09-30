// 单据详情页（`DocumentDetailPage`）的 widget 测试（批次 1a，§AO）。
//
// 覆盖：显示字段 / [收款] 按钮的出现条件 / 核销对话框（预填、超收内联提示）/
// 收款成功后的 SnackBar 与状态刷新 / 部分收款 / 收付款单的「核销去向」/
// 单据不存在。
//
// ⚠️ 必须 `useLocalSqlite()`（§N）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/document_detail_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late DocumentDao dao;
  late SettlementService settlements;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_doc_detail_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    dao = DocumentDao(db);
    settlements = SettlementService(db: db, engine: RuleEngine(db));

    final int t = 1700000000000;
    ProductDao(db).insert(Product(
      id: 'p1',
      code: 'P0001',
      name: '矿泉水',
      costPrice: 300,
      sellPrice: 500,
      createdAt: t,
      updatedAt: t,
    ));
    AccountDao(db).insert(Account(
      id: 'a1',
      name: '现金',
      type: AccountType.cash,
      createdAt: t,
      updatedAt: t,
    ));
    PartyDao(db).insert(Party(
      id: 'pt1',
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

  /// 赊账销售一张：**2 × ¥5.00 = ¥10.00**（不收钱 ⇒ 未收 = 全额）
  ///
  /// ⚠️ 算式当场验算：quantity '2' × unitPrice '5.00' ⇒ 2 × 500 分 = **1000 分**。
  /// （首版把断言写成 ¥100.00 —— 记录在案：夹具金额必须当场算一遍。）
  Document sellOnCredit() {
    SaleService(engine: RuleEngine(db), queries: QueryDao(db)).create(
      SaleDraft(
        partyId: 'pt1',
        date: '2026-09-28',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: 'p1',
            productName: '矿泉水',
            quantity: '2',
            unitPrice: '5.00',
          ),
        ],
      ),
      now: 1700000000000,
    );
    // 赊账销售单是列表里唯一一张（自动收付款单被列表过滤）
    return dao.listDocuments().single.document;
  }

  Widget page(String documentId) => MaterialApp(
    home: DocumentDetailPage(
      documentId: documentId,
      settlements: settlements,
      products: ProductService(db),
    ),
  );

  testWidgets('显示单号 / 对方 / 金额 / 状态 / 明细；赊账单给 [收款] 按钮', (
    WidgetTester tester,
  ) async {
    final Document doc = sellOnCredit();
    await tester.pumpWidget(page(doc.id));
    await tester.pumpAndSettle();

    expect(find.text(doc.docNo), findsOneWidget);
    expect(find.textContaining('李姐'), findsWidgets);
    expect(find.textContaining('¥10.00'), findsWidgets, reason: '金额带千分位格式');
    expect(find.text(docStatusLabel(DocStatus.confirmed)), findsWidgets);
    expect(find.text('矿泉水'), findsOneWidget, reason: '明细行显示商品名');

    expect(find.byKey(const Key('settle-button')), findsOneWidget);
    expect(find.textContaining('收款 ¥10.00'), findsOneWidget);
    expect(find.byKey(const Key('copy-doc-no')), findsOneWidget, reason: '复制单号挪到本页');
  });

  testWidgets('对话框：预填未收额；超收 → 内联提示且不弹第二个窗', (
    WidgetTester tester,
  ) async {
    final Document doc = sellOnCredit();
    await tester.pumpWidget(page(doc.id));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settle-button')));
    await tester.pumpAndSettle();

    final TextField amount = tester.widget<TextField>(
      find.byKey(const Key('settle-amount')),
    );
    expect(amount.controller!.text, '10.00', reason: '预填未收额（可改小）');
    expect(find.textContaining('就结清了'), findsOneWidget, reason: '结论句');

    await tester.enterText(find.byKey(const Key('settle-amount')), '200');
    await tester.pumpAndSettle();

    expect(find.textContaining('超过未收金额 ¥10.00，请改小'), findsOneWidget);
    expect(
      find.byType(AlertDialog),
      findsOneWidget,
      reason: '内联提示 —— 只该有一个对话框（不弹第二个窗）',
    );

    // 确认按钮点了也不该记账（提示还在）
    await tester.tap(find.text('确认收款'));
    await tester.pumpAndSettle();
    expect(settlements.unsettledCentsOf(doc.id), 1000, reason: '被拦住，没落库');
  });

  testWidgets('全额收款 → SnackBar + 状态变已结清 + 按钮消失', (
    WidgetTester tester,
  ) async {
    final Document doc = sellOnCredit();
    await tester.pumpWidget(page(doc.id));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settle-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认收款'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已收'), findsWidgets, reason: 'SnackBar');
    expect(find.text(docStatusLabel(DocStatus.settled)), findsWidgets);
    expect(
      find.byKey(const Key('settle-button')),
      findsNothing,
      reason: '结清后按钮消失',
    );
    expect(find.textContaining('这张单已经结清了'), findsOneWidget);
    expect(settlements.unsettledCentsOf(doc.id), 0);
  });

  testWidgets('部分收款 → 按钮变剩余额 + 说「还欠」', (WidgetTester tester) async {
    final Document doc = sellOnCredit();
    await tester.pumpWidget(page(doc.id));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settle-button')));
    await tester.pumpAndSettle();
    // 收 3 元（< 未收 10 元）⇒ 还欠 7 元
    await tester.enterText(find.byKey(const Key('settle-amount')), '3');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认收款'));
    await tester.pumpAndSettle();

    expect(find.textContaining('还欠'), findsWidgets);
    expect(find.textContaining('收款 ¥7.00'), findsOneWidget, reason: '按钮金额变成剩余');
  });

  testWidgets('收款单显示「这笔钱核销到了」+ 对端单号；不能再核销', (
    WidgetTester tester,
  ) async {
    final Document sale = sellOnCredit();
    final SettlementSaved saved = settlements.settle(
      targetDocId: sale.id,
      accountId: 'a1',
      amountCents: 1000, // 全额 = 2 × ¥5.00
      now: 1700000000001,
    );

    await tester.pumpWidget(page(saved.docId));
    await tester.pumpAndSettle();

    expect(find.text('这笔钱核销到了'), findsOneWidget);
    expect(find.text(sale.docNo), findsOneWidget, reason: '核销去向显示对端单号');
    expect(
      find.byKey(const Key('settle-button')),
      findsNothing,
      reason: '收付款单自身不能再核销',
    );
    expect(find.textContaining('这类单据不需要收付款'), findsOneWidget);
  });

  testWidgets('单据不存在 → 说清「可能已经被删掉」', (WidgetTester tester) async {
    await tester.pumpWidget(page('没有这张单'));
    await tester.pumpAndSettle();

    expect(find.textContaining('找不到这张单'), findsOneWidget);
  });
}
