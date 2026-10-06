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

  testWidgets('对话框：预填未收额；超收 → 内联告知、不弹第二个窗、按未收额落库', (
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

    // §AX·一：超收**不再报错**，改为橙色内联**告知**「记多少 / 找多少」
    expect(
      find.textContaining('实收 ¥200.00，其中 ¥10.00 入账、找零 ¥190.00'),
      findsOneWidget,
    );
    expect(
      find.byType(AlertDialog),
      findsOneWidget,
      reason: '内联 —— 只该有一个对话框（不弹第二个窗）',
    );
    // **按钮文字**跟着变（裁定：按钮文字是用户动作的最终确认）
    expect(find.textContaining('记 ¥10.00 并找零 ¥190.00'), findsOneWidget);

    // 点确认 → **按未收额封顶落库**（旧行为是拦住不落库）
    await tester.tap(find.textContaining('记 ¥10.00 并找零 ¥190.00'));
    await tester.pumpAndSettle();
    expect(
      settlements.unsettledCentsOf(doc.id),
      0,
      reason: '封顶到未收额 ¥10.00 ⇒ 正好结清',
    );
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

  /// 直接走引擎造一张**赊销**：2 × ¥5.00 = ¥10.00（不收钱 ⇒ 未收 = 全额）。
  /// 再对它退 1 × ¥4.00（部分退货）——**原单不作废**（作废只发生在拒收）。
  ({String saleId, String retId}) partialReturn() {
    final RuleEngine engine = RuleEngine(db);
    Document mk(String id, DocType type, int total, {String? ref}) => Document(
      id: id,
      docNo: '${Document.pendingDocNoPrefix}$id',
      docType: type,
      status: DocStatus.confirmed,
      partyId: 'pt1',
      totalAmount: total,
      refDocId: ref,
      occurredAt: 1700000000000,
      createdAt: 1700000000000,
      updatedAt: 1700000000000,
    );

    final Document sale = mk('xs-1', DocType.sale, 1000);
    engine.dispatch(
      document: sale,
      lines: <DocumentLine>[
        DocumentLine.create(
          documentId: sale.id,
          productId: 'p1',
          quantity: 2,
          unitPrice: 500,
        ),
      ],
      now: 1700000000000,
    );

    final Document ret = mk('th-1', DocType.saleReturn, 400, ref: sale.id);
    engine.dispatch(
      document: ret,
      lines: <DocumentLine>[
        DocumentLine.create(
          documentId: ret.id,
          productId: 'p1',
          quantity: 1,
          unitPrice: 400,
        ),
      ],
      now: 1700000000000,
    );
    return (saleId: sale.id, retId: ret.id);
  }

  /// 送货（在途）→ **客户拒收**（整单退回）⇒ 引擎把原送货单置 `cancelled`。
  String rejectedDelivery() {
    final RuleEngine engine = RuleEngine(db);
    Document mk(String id, DocType type, int total, {String? ref}) => Document(
      id: id,
      docNo: '${Document.pendingDocNoPrefix}$id',
      docType: type,
      status: DocStatus.confirmed,
      partyId: 'pt1',
      totalAmount: total,
      refDocId: ref,
      occurredAt: 1700000000000,
      createdAt: 1700000000000,
      updatedAt: 1700000000000,
    );

    final Document delivery = mk('sh-1', DocType.delivery, 1000);
    engine.dispatch(
      document: delivery,
      lines: <DocumentLine>[
        DocumentLine.create(
          documentId: delivery.id,
          productId: 'p1',
          quantity: 2,
          unitPrice: 500,
        ),
      ],
      now: 1700000000000,
    );
    final Document reject = mk('sr-1', DocType.saleReturn, 1000, ref: delivery.id);
    engine.dispatch(
      document: reject,
      lines: <DocumentLine>[
        DocumentLine.create(
          documentId: reject.id,
          productId: 'p1',
          quantity: 2,
          unitPrice: 500,
        ),
      ],
      now: 1700000000000,
    );
    return delivery.id;
  }

  testWidgets('退货记录：部分退货后详情页能看到那笔退货（§审查 2026-10-05）', (
    WidgetTester tester,
  ) async {
    final ({String saleId, String retId}) fixture = partialReturn();
    await tester.pumpWidget(page(fixture.saleId));
    await tester.pumpAndSettle();

    // 金额卡把冲减额摆出来 —— 直接回答「60 的单怎么收 40 就结清了」
    expect(find.text('已退货'), findsOneWidget);
    expect(find.textContaining('¥4.00'), findsWidgets);

    // 退货记录区块：说清退过几次、共多少，并列出单号
    expect(find.text('退货记录'), findsOneWidget);
    expect(find.textContaining('退过 1 次'), findsOneWidget);
    expect(
      find.byKey(Key('return-row-${fixture.retId}')),
      findsOneWidget,
      reason: '那笔退货单要能点开',
    );

    // 原单本身**不作废**（部分退货 ≠ 拒收）
    expect(find.textContaining('客户拒收'), findsNothing);
  });

  testWidgets('没退过货的单不显示「退货记录」区块', (WidgetTester tester) async {
    final Document doc = sellOnCredit();
    await tester.pumpWidget(page(doc.id));
    await tester.pumpAndSettle();

    expect(find.text('退货记录'), findsNothing, reason: '没退过就别多一块空白');
    expect(find.text('已退货'), findsNothing);
  });

  testWidgets('拒收的送货单：只说「已作废」，**不再**冒出「已签收」', (
    WidgetTester tester,
  ) async {
    // 真机截图 bug：同一屏上同时出现「已作废（客户拒收）」+「已签收」。
    // 根因是 `_actionRow` 的 else 分支把 cancelled 也当成「已签收」。
    await tester.pumpWidget(page(rejectedDelivery()));
    await tester.pumpAndSettle();

    expect(find.textContaining('已作废'), findsWidgets);
    expect(
      find.textContaining('已签收'),
      findsNothing,
      reason: '作废的单不可能同时是「已签收」',
    );
    expect(
      find.textContaining('不用收付款'),
      findsNothing,
      reason: '作废原因说一次就够，不再补第二句',
    );
    // 作废单不给收款 / 拒收 / 退货入口
    expect(find.byKey(const Key('settle-button')), findsNothing);
    expect(find.byKey(const Key('reject-button')), findsNothing);
    expect(find.byKey(const Key('return-button')), findsNothing);
  });

  testWidgets('单据不存在 → 说清「可能已经被删掉」', (WidgetTester tester) async {
    await tester.pumpWidget(page('没有这张单'));
    await tester.pumpAndSettle();

    expect(find.textContaining('找不到这张单'), findsOneWidget);
  });
}
