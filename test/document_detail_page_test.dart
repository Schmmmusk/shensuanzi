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
    ProductDao(db).insert(
      Product(
        id: 'p1',
        code: 'P0001',
        name: '矿泉水',
        costPrice: 300,
        sellPrice: 500,
        createdAt: t,
        updatedAt: t,
      ),
    );
    AccountDao(db).insert(
      Account(
        id: 'a1',
        name: '现金',
        type: AccountType.cash,
        createdAt: t,
        updatedAt: t,
      ),
    );
    PartyDao(db).insert(
      Party(
        id: 'pt1',
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
    expect(
      find.byKey(const Key('copy-doc-no')),
      findsOneWidget,
      reason: '复制单号挪到本页',
    );
  });

  // 3a（2026-10-24，业务审查 §3.4 / 用户裁定）：负未收是真实信号 ——
  // 「退得比收得多」时我们欠客户钱，要显示「多收 ¥X」，不许夹成 0。
  testWidgets('3a：退得比收得多 ⇒ 显示「多收 ¥3.00」（不是「未收 ¥0.00」）', (
    WidgetTester tester,
  ) async {
    final Document doc = sellOnCredit(); // 10.00
    // 已收满 10.00
    db.raw.execute(
      'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
      'occurred_at, created_at, updated_at) '
      "VALUES ('rc1', 'SK1', 'receipt', 'settled', 1000, 0, 0, 0)",
    );
    db.raw.execute(
      'INSERT INTO settlements (id, receipt_doc_id, target_doc_id, amount, '
      'seq_no, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      <Object?>['st1', 'rc1', doc.id, 1000, 1, 0],
    );
    // 之后退了 3.00
    db.raw.execute(
      'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
      'ref_doc_id, occurred_at, created_at, updated_at) '
      "VALUES ('rt1', 'XT1', 'sale_return', 'confirmed', 300, ?, 0, 0, 0)",
      <Object?>[doc.id],
    );

    await tester.pumpWidget(page(doc.id));
    await tester.pumpAndSettle();

    expect(find.text('多收'), findsOneWidget, reason: '3a：负数要读作「多收」');
    expect(find.text('¥3.00'), findsWidgets, reason: '3a：金额显示为正数');
  });

  testWidgets('对话框：预填未收额；超收 → 内联告知、不弹第二个窗、按未收额落库', (WidgetTester tester) async {
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

  testWidgets('全额收款 → SnackBar + 状态变已结清 + 按钮消失', (WidgetTester tester) async {
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

  testWidgets('收款单显示「这笔钱核销到了」+ 对端单号；不能再核销', (WidgetTester tester) async {
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
    final Document reject = mk(
      'sr-1',
      DocType.saleReturn,
      1000,
      ref: delivery.id,
    );
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
    // ⚠️ 2026-10-18（#26 批 3）：标题带次数与金额（列表折叠后这是唯一入口，
    // 所以标题要**醒目**）⇒ 用 `textContaining` 而不是精确匹配
    expect(find.textContaining('退货记录 · 1 次'), findsOneWidget);
    expect(find.textContaining('点下面任意一行'), findsOneWidget);
    expect(
      find.byKey(Key('return-row-${fixture.retId}')),
      findsOneWidget,
      reason: '那笔退货单要能点开',
    );

    // 原单本身**不作废**（部分退货 ≠ 拒收）
    expect(find.textContaining('客户拒收'), findsNothing);
  });

  testWidgets('退货单：显示「未退款」+ [退款给客户] 入口（2026-10-07，reply.md §2）', (
    WidgetTester tester,
  ) async {
    // 挂账退货（`partialReturn` 造的 `th-1` 没有立即退款）⇒ 该退 ¥4.00 还没退。
    // 从前这里只有一句「退货单不用收付款」，客户的钱没有出口。
    final ({String saleId, String retId}) fixture = partialReturn();
    await tester.pumpWidget(page(fixture.retId));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('refund-button')), findsOneWidget);
    expect(find.textContaining('退款给客户 ¥4.00'), findsOneWidget);
    expect(find.text('未退款'), findsOneWidget);
    expect(find.text('应退金额'), findsOneWidget);
    expect(
      find.byKey(const Key('settle-button')),
      findsNothing,
      reason: '退货单走退款入口，不是普通收款 / 付款按钮',
    );

    // 点开对话框：文案也是退款口径（不是「付款 / 未付」）
    await tester.tap(find.byKey(const Key('refund-button')));
    await tester.pumpAndSettle();
    expect(find.text('退款给客户'), findsWidgets);
    expect(find.textContaining('未退款：'), findsOneWidget);
    expect(find.textContaining('客户：李姐'), findsOneWidget);
  });

  testWidgets('没退过货的单不显示「退货记录」区块', (WidgetTester tester) async {
    final Document doc = sellOnCredit();
    await tester.pumpWidget(page(doc.id));
    await tester.pumpAndSettle();

    expect(find.textContaining('退货记录'), findsNothing, reason: '没退过就别多一块空白');
    expect(find.text('已退货'), findsNothing);
  });

  testWidgets('拒收的送货单：只说「已作废」，**不再**冒出「已签收」', (WidgetTester tester) async {
    // 真机截图 bug：同一屏上同时出现「已作废（客户拒收）」+「已签收」。
    // 根因是 `_actionRow` 的 else 分支把 cancelled 也当成「已签收」。
    await tester.pumpWidget(page(rejectedDelivery()));
    await tester.pumpAndSettle();

    expect(find.textContaining('已作废'), findsWidgets);
    expect(find.textContaining('已签收'), findsNothing, reason: '作废的单不可能同时是「已签收」');
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

  // #39（2026-10-14）：**全部退回之后不该再有「退货」入口** —— 否则可以再点一次、
  // 误导用户继续退款。⚠️ 「客户拒收」会 `cancel` 原单（入口自然消失），
  // 「退货」**不会**（原单不作废，只是被冲减）⇒ 必须显式判 `returnedCents >= 总额`。
  // F4（2026-10-25 裁定 D3 乙）：详情页之间可以一路下钻（原单 → 退货单 → 核销 → 收付款单），
  // 复跑实测「用户被困在单据里很难出来」。裁定 = 保留跳转 + 面包屑：
  // 关联单顶部给「回到原单 XS…」，一次弹回。
  testWidgets('F4（D3 乙）：从退货单进来 ⇒ 顶部有「回到原单」，一次弹回', (WidgetTester tester) async {
    final RuleEngine engine = RuleEngine(db);
    final Document sale = sellOnCredit(); // 2 × ¥5.00 = ¥10.00
    final Document ret = Document(
      id: 'th-f4',
      docNo: 'XT20261025-F4',
      docType: DocType.saleReturn,
      status: DocStatus.confirmed,
      partyId: 'pt1',
      totalAmount: 500,
      refDocId: sale.id,
      occurredAt: 1700000000000,
      createdAt: 1700000000000,
      updatedAt: 1700000000000,
    );
    engine.dispatch(
      document: ret,
      lines: <DocumentLine>[
        DocumentLine.create(
          documentId: ret.id,
          productId: 'p1',
          quantity: 1,
          unitPrice: 500,
        ),
      ],
      now: 1700000000000,
    );

    await tester.pumpWidget(page(sale.id));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('detail-back-to-origin')),
      findsNothing,
      reason: '原单本身不该有面包屑',
    );

    await tester.tap(find.byKey(const Key('return-row-th-f4')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('detail-back-to-origin')),
      findsOneWidget,
      reason: 'F4：关联单顶部要给「回到原单」',
    );
    expect(find.textContaining(sale.docNo), findsWidgets);

    await tester.tap(find.byKey(const Key('detail-back-to-origin')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('detail-back-to-origin')),
      findsNothing,
      reason: '一次就回到原单了',
    );
  });

  testWidgets('#39 全部退回之后：退货入口消失 + 给一句说明', (WidgetTester tester) async {
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

    final Document sale = mk('xs-9', DocType.sale, 1000);
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
    // **整单退**：2 × ¥5.00 = ¥10.00（= 原单全额）
    final Document ret = mk('th-9', DocType.saleReturn, 1000, ref: sale.id);
    engine.dispatch(
      document: ret,
      lines: <DocumentLine>[
        DocumentLine.create(
          documentId: ret.id,
          productId: 'p1',
          quantity: 2,
          unitPrice: 500,
        ),
      ],
      now: 1700000000000,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DocumentDetailPage(
          documentId: sale.id,
          settlements: settlements,
          products: ProductService(db),
          returnService: ReturnService(engine: engine, queries: QueryDao(db)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('return-button')),
      findsNothing,
      reason: '#39：已全退 ⇒ 不能再退（否则用户可反复点、继续退款）',
    );
    expect(
      find.text('这张单已经全部退过了，不能再退。'),
      findsOneWidget,
      reason: '#39：按钮凭空消失比点不动更让人困惑 ⇒ 要给一句说明',
    );
  });

  // #38 甲（2026-10-14，用户裁定）：**全退之后不再显示「还要收多少 / 欠多少」**。
  // 报告里那张单（全收 ¥120 + 全退 ¥120）原本显示「未收 ¥-120.00」——
  // 现在只留一句「已全部退清」；**算术不动**（第二步口径的裁定对象）。
  testWidgets('#38 甲 + F3（D1 甲）：全收 + 全退但**没退钱** ⇒ 说「还欠客户退款」', (
    WidgetTester tester,
  ) async {
    final RuleEngine engine = RuleEngine(db);
    final Document sale = sellOnCredit(); // 夹具 = 2 × ¥5.00 = ¥10.00
    // 先**收满** ¥10.00（顺序不能反：先全退的话未收已是 0，`settle()` 会拒绝）
    settlements.settle(
      targetDocId: sale.id,
      accountId: 'a1',
      amountCents: 1000,
      now: 1700000000000,
    );
    // 再**整单退** ¥10.00（= 原单全额，走 `ref_doc_id` 挂到原单上）
    final Document ret = Document(
      id: 'th-38',
      docNo: '${Document.pendingDocNoPrefix}th-38',
      docType: DocType.saleReturn,
      status: DocStatus.confirmed,
      partyId: 'pt1',
      totalAmount: 1000,
      refDocId: sale.id,
      occurredAt: 1700000000000,
      createdAt: 1700000000000,
      updatedAt: 1700000000000,
    );
    engine.dispatch(
      document: ret,
      lines: <DocumentLine>[
        DocumentLine.create(
          documentId: ret.id,
          productId: 'p1',
          quantity: 2,
          unitPrice: 500,
        ),
      ],
      now: 1700000000000,
    );

    // ⛔ 算术照旧可为负 —— 本测试**故意**钉住它不被动过（第二步才裁口径）
    expect(settlements.unsettledCentsOf(sale.id), -1000, reason: '算术不动');

    await tester.pumpWidget(page(sale.id));
    await tester.pumpAndSettle();

    // F3（D1 甲，2026-10-25 用户裁定）：「商品全退了，但钱没退，
    // 状态写『已结清』是自欺欺人。必须显示『还欠客户退款 ¥X』。」
    expect(find.text('还欠客户退款'), findsOneWidget, reason: '全退但没退款 ⇒ 必须明说还欠多少');
    expect(find.text('¥10.00'), findsWidgets, reason: '待退款 = 退货总额 − 已退款');
    expect(find.text('已全部退清'), findsNothing, reason: '钱没退完就不许说「已全部退清」');
    expect(find.text('已全退'), findsOneWidget, reason: '状态不再写「已结清」');
    expect(
      find.textContaining('未收'),
      findsNothing,
      reason: '「未收」这一行不再出现（标签本身就是「还要收多少」）',
    );

    // 把退款补上（给退货单做一笔核销）⇒ 回到「已全部退清」
    settlements.settle(
      targetDocId: ret.id,
      accountId: 'a1',
      amountCents: 1000,
      now: 1700000000000,
    );
    await tester.pumpWidget(page(sale.id));
    await tester.pumpAndSettle();

    expect(find.text('已全部退清'), findsOneWidget, reason: '钱退完了才算「退清」');
    expect(find.text('还欠客户退款'), findsNothing);
    expect(find.textContaining('¥-'), findsNothing, reason: '界面不再出现负数金额');
  });

  // 附录 B（`docs/ui-review-2026-10-21.md`）：单据详情页 原先**没有**大字号断言。
  // 批 3 第 18 条：尺寸改造的机械护栏 —— 先立护栏再动尺寸。
  testWidgets('大字号（2.0）：单据详情页不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(960, 1000);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final Document doc = sellOnCredit();
    await tester.pumpWidget(page(doc.id));
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: '单据详情页在 2.0 档下溢出（附录 B 点名的结构：固定宽度 / 固定断点 / 顶部 Row）',
    );
  });

  // 附录 B（`docs/ui-review-2026-10-21.md`）：**核销弹窗**原先没有大字号断言。
  // 走真实入口：详情页点「收款」→ 弹窗（不直接构造私有 _SettlementDialog）。
  testWidgets('大字号（2.0）：核销弹窗不溢出', (WidgetTester tester) async {
    final Document doc = sellOnCredit();

    tester.view.physicalSize = const Size(960, 1000);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(page(doc.id));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settle-button')));
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: '核销弹窗在 2.0 档下溢出（附录 B 点名：顶部 Row / 固定宽度）',
    );
  });
}
