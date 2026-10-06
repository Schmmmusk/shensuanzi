// 核销视图与单据列表过滤（批次 1a / `docs/reply_review.md` §AM·二、§AN·二）。
//
// 覆盖三件事：
//  1. **列表过滤自动生成的收付款单** —— 且**退货单不被误伤**（条件不能只判 `ref_doc_id`）
//  2. `DocumentDao.summaryById`（详情页取一行）
//  3. `settlementsOfReceipt` / `settlementsOfTarget` **对称查询**（同一份数据两个方向）
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；Windows 需要可用的 SQLite 原生库
// （见 `lib/sqlite_local.dart`）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late RuleEngine engine;
  late DocumentDao documents;
  late SettlementDao settlements;

  setUp(() {
    resetClock();
    db = newMemoryDb();
    engine = RuleEngine(db);
    documents = DocumentDao(db);
    settlements = SettlementDao(db);
  });

  tearDown(() => db.close());

  // ---------------------------------------------------------------- 造数夹具

  String createProduct() {
    final Product p = Product(
      id: newId(),
      code: 'P${newId().substring(0, 6)}',
      name: '商品',
      costPrice: 100,
      createdAt: now(),
      updatedAt: now(),
    );
    ProductDao(db).insert(p);
    return p.id;
  }

  String createAccount() {
    final Account a = Account(
      id: newId(),
      name: '现金',
      type: AccountType.cash,
      createdAt: now(),
      updatedAt: now(),
    );
    AccountDao(db).insert(a);
    return a.id;
  }

  String createParty({String name = '客户甲'}) {
    final Party p = Party(
      id: newId(),
      name: name,
      roles: const <PartyRole>[PartyRole.customer],
      createdAt: now(),
      updatedAt: now(),
    );
    PartyDao(db).insert(p);
    return p.id;
  }

  Document doc({
    required DocType type,
    String? partyId,
    String? accountId,
    required int totalAmount,
    String? refDocId,
  }) => Document(
    id: newId(),
    docNo: '${Document.pendingDocNoPrefix}tmp-${newId().substring(0, 6)}',
    docType: type,
    status: DocStatus.confirmed,
    partyId: partyId,
    accountId: accountId,
    totalAmount: totalAmount,
    refDocId: refDocId,
    occurredAt: now(),
    createdAt: now(),
    updatedAt: now(),
  );

  DocumentLine line(Document d, String productId, int quantity, int unitPrice) =>
      DocumentLine.create(
        documentId: d.id,
        productId: productId,
        quantity: quantity,
        unitPrice: unitPrice,
      );

  RuleOutcome run(
    Document d, {
    List<DocumentLine> lines = const <DocumentLine>[],
    List<PaymentEntry> pays = const <PaymentEntry>[],
    List<Allocation> allocs = const <Allocation>[],
  }) => engine.dispatch(
    document: d,
    lines: lines,
    immediatePayments: pays,
    allocations: allocs,
    now: now(),
  );

  // ============================================================ 列表过滤

  group('列表过滤自动生成的收付款单（§AN·二）', () {
    test('自动单默认不显示、退货单不被误伤、手动单要显示', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();

      // ① 销售 + 立即收款 → 主机自动生成 receipt（ref_doc_id 非空）
      final Document sale1 = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 5000,
      );
      run(
        sale1,
        lines: <DocumentLine>[line(sale1, p, 10, 500)],
        pays: <PaymentEntry>[PaymentEntry(accountId: acc, amount: 5000)],
      );

      // ② 赊账销售
      final Document sale2 = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 3000,
      );
      run(sale2, lines: <DocumentLine>[line(sale2, p, 6, 500)]);

      // ③ 手动收款单（核销 sale2 的一部分）—— ref_doc_id = null
      final Document receipt = doc(
        type: DocType.receipt,
        partyId: party,
        accountId: acc,
        totalAmount: 1000,
      );
      run(receipt, allocs: <Allocation>[
        Allocation(targetDocId: sale2.id, amount: 1000),
      ]);

      // ④ 销售退货 —— **ref_doc_id 指向原单，但它是独立交易、必须显示**
      final Document ret = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 500,
        refDocId: sale2.id,
      );
      run(ret, lines: <DocumentLine>[line(ret, p, 1, 500)]);

      final Set<String> shown = documents
          .listDocuments()
          .map((DocumentSummary e) => e.document.id)
          .toSet();
      final Set<String> all = documents
          .listDocuments(includeDerived: true)
          .map((DocumentSummary e) => e.document.id)
          .toSet();

      // 自动生成的收款单（唯一的 ref_doc_id 非空 receipt）
      final String autoReceiptId = db.raw
              .select(
                "SELECT id FROM documents "
                "WHERE doc_type = 'receipt' AND ref_doc_id IS NOT NULL",
              )
              .first['id']!
          as String;
      expect(shown, isNot(contains(autoReceiptId)), reason: '自动单不进列表');
      expect(all, contains(autoReceiptId), reason: '要全量时能看到（参数有效）');

      expect(shown, contains(receipt.id), reason: '手动收款单要显示');
      expect(
        shown,
        contains(ret.id),
        reason: '⚠️ 退货单的 ref_doc_id 也非空 —— 只判 ref_doc_id 会把它误伤',
      );
      expect(shown, contains(sale1.id));
      expect(shown, contains(sale2.id));
      expect(
        all.length,
        greaterThan(shown.length),
        reason: '全量一定不少于默认视图',
      );
    });

    test('导出口径与列表一致（同一个 _summaries）', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 2000,
      );
      run(
        sale,
        lines: <DocumentLine>[line(sale, p, 4, 500)],
        pays: <PaymentEntry>[PaymentEntry(accountId: acc, amount: 2000)],
      );

      expect(
        documents.listDocumentsForExport().length,
        documents.listDocuments().length,
        reason: 'AF-5：导出与列表同一份筛选',
      );
      expect(
        documents.listDocumentsForExport(includeDerived: true).length,
        greaterThan(documents.listDocumentsForExport().length),
      );
    });
  });

  // ============================================================ summaryById

  group('DocumentDao.summaryById（详情页）', () {
    test('命中带对方名；不存在 → null', () {
      final String p = createProduct();
      final String party = createParty(name: '老王批发');
      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 1000,
      );
      run(sale, lines: <DocumentLine>[line(sale, p, 2, 500)]);

      final DocumentSummary? summary = documents.summaryById(sale.id);
      expect(summary, isNotNull);
      expect(summary!.document.id, sale.id);
      expect(summary.partyName, '老王批发', reason: '与列表同一份 JOIN');
      expect(documents.summaryById('不存在'), isNull);
    });
  });

  // ============================================================ 对称查询

  group('核销视图（两个方向对称）', () {
    test('收款单 → 被核销单；被核销单 → 收款单（同一笔数据）', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 5000,
      );
      run(sale, lines: <DocumentLine>[line(sale, p, 10, 500)]);

      // 部分收款 3000
      final Document receipt = doc(
        type: DocType.receipt,
        partyId: party,
        accountId: acc,
        totalAmount: 3000,
      );
      run(receipt, allocs: <Allocation>[
        Allocation(targetDocId: sale.id, amount: 3000),
      ]);

      final List<SettlementView> fromReceipt = settlements.settlementsOfReceipt(
        receipt.id,
      );
      final List<SettlementView> fromTarget = settlements.settlementsOfTarget(
        sale.id,
      );

      expect(fromReceipt, hasLength(1));
      expect(fromTarget, hasLength(1));

      // 从收款单看 → 对端是销售单
      expect(fromReceipt.single.docId, sale.id);
      expect(fromReceipt.single.docNo, documents.findById(sale.id)!.docNo);
      // 从销售单看 → 对端是收款单
      expect(fromTarget.single.docId, receipt.id);
      expect(fromTarget.single.docNo, documents.findById(receipt.id)!.docNo);
      // 对称：同一笔核销
      expect(fromReceipt.single.amount, fromTarget.single.amount);
      expect(fromReceipt.single.amount, 3000);
    });

    test('预收（target_doc_id = NULL）→ docId/docNo 为 null，金额仍要显示', () {
      final String acc = createAccount();
      final String party = createParty();

      final Document prepay = doc(
        type: DocType.receipt,
        partyId: party,
        accountId: acc,
        totalAmount: 800,
      );
      run(prepay, allocs: <Allocation>[
        Allocation(targetDocId: null, amount: 800),
      ]);

      final List<SettlementView> views = settlements.settlementsOfReceipt(
        prepay.id,
      );
      expect(views, hasLength(1));
      expect(views.single.docId, isNull, reason: '预收没有对端单据');
      expect(views.single.docNo, isNull);
      expect(views.single.amount, 800, reason: '预收金额是要显示的信息');

      expect(
        settlements.settlementsOfTarget('任意单'),
        isEmpty,
        reason: '预收不挂在任何 target 上',
      );
    });

    test('没有核销关系 → 两个方向都是空（不报错）', () {
      expect(settlements.settlementsOfReceipt('没有这张单'), isEmpty);
      expect(settlements.settlementsOfTarget('没有这张单'), isEmpty);
    });
  });

  // ============================================================ 拒收折叠 + 退货记录
  //
  // §审查 2026-10-05：客户拒收后，原送货单（已作废）与自动生成的**整单退回**
  // `sale_return` 内容一模一样 —— 列表里并排出现等于「同一笔生意两个入口」。
  // 折叠必须**精确**：只折叠「ref 指向已作废单据」的退货单，正常退货照常显示。

  group('拒收折叠与退货记录（§审查 2026-10-05）', () {
    test('拒收：原送货单已作废 ⇒ 派生退货单不进默认列表；要全量时能看到', () {
      final String p = createProduct();
      final String party = createParty();

      // ① 送货（引擎强制 in_transit）
      final Document delivery = doc(
        type: DocType.delivery,
        partyId: party,
        totalAmount: 5000,
      );
      run(delivery, lines: <DocumentLine>[line(delivery, p, 10, 500)]);
      expect(
        documents.findById(delivery.id)!.status,
        DocStatus.inTransit,
        reason: '送货的状态机起点',
      );

      // ② 拒收 = 全量 sale_return ref 送货单 ⇒ 引擎同事务把原单置 cancelled
      final Document reject = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 5000,
        refDocId: delivery.id,
      );
      run(reject, lines: <DocumentLine>[line(reject, p, 10, 500)]);
      expect(
        documents.findById(delivery.id)!.status,
        DocStatus.cancelled,
        reason: '拒收收口（§BH·七）：原送货单同事务置 cancelled',
      );

      final Set<String> shown = documents
          .listDocuments()
          .map((DocumentSummary e) => e.document.id)
          .toSet();
      expect(shown, contains(delivery.id), reason: '原送货单保留 —— 它是唯一入口');
      expect(
        shown,
        isNot(contains(reject.id)),
        reason: '整单退回的派生退货单不该并排出现',
      );

      // 要全量（按「销售退货」筛选时页面会传 includeDerived）时能看到
      expect(
        documents
            .listDocuments(includeDerived: true)
            .map((DocumentSummary e) => e.document.id),
        contains(reject.id),
      );

      // 原单行带出退货额（列表行显示「已退 ¥50.00」）
      expect(documents.summaryById(delivery.id)!.returnedCents, 5000);
    });

    test('「退货记录」：原单能查到自己被退过什么（详情页区块的数据源）', () {
      final String p = createProduct();
      final String party = createParty();

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 6000,
      );
      run(sale, lines: <DocumentLine>[line(sale, p, 12, 500)]);

      // 先查空
      expect(documents.returnsAgainst(sale.id), isEmpty, reason: '没退过就是空');

      // 退 1500（部分）
      final Document ret = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 1500,
        refDocId: sale.id,
      );
      run(ret, lines: <DocumentLine>[line(ret, p, 3, 500)]);

      final List<DocumentSummary> history = documents.returnsAgainst(sale.id);
      expect(history, hasLength(1));
      expect(history.first.document.id, ret.id);
      expect(history.first.document.totalAmount, 1500);
      expect(history.first.document.docType, DocType.saleReturn);
      // 只认自己的：别的单查不到
      expect(documents.returnsAgainst('别的单'), isEmpty);
    });

    test('正常部分退货：原单未作废 ⇒ 退货单**仍要显示**（独立交易）', () {
      final String p = createProduct();
      final String party = createParty();

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 6000,
      );
      run(sale, lines: <DocumentLine>[line(sale, p, 12, 500)]);

      final Document ret = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 1500,
        refDocId: sale.id,
      );
      run(ret, lines: <DocumentLine>[line(ret, p, 3, 500)]);

      expect(
        documents.findById(sale.id)!.status,
        isNot(DocStatus.cancelled),
        reason: '部分退货不动原单状态',
      );
      final Set<String> shown = documents
          .listDocuments()
          .map((DocumentSummary e) => e.document.id)
          .toSet();
      expect(
        shown,
        contains(ret.id),
        reason: '⚠️ 折叠条件只认「原单已作废」—— 正常退货必须显示',
      );
      expect(shown, contains(sale.id));
      // 行上的退货额也要有（列表显示「已退 ¥15.00」）
      expect(
        documents
            .listDocuments()
            .firstWhere((DocumentSummary e) => e.document.id == sale.id)
            .returnedCents,
        1500,
      );
    });

    test('状态筛选：未结清（扣退货冲减）/ 已作废 / 待签收', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();

      // ① 赊销 6000 → 退 1500 ⇒ 真实未收 4500（「未结清」应命中）
      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 6000,
      );
      run(sale, lines: <DocumentLine>[line(sale, p, 12, 500)]);
      final Document ret = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 1500,
        refDocId: sale.id,
      );
      run(ret, lines: <DocumentLine>[line(ret, p, 3, 500)]);

      // ② 已结清 1000（「未结清」不该命中）
      final Document paid = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 1000,
      );
      run(
        paid,
        lines: <DocumentLine>[line(paid, p, 2, 500)],
        pays: <PaymentEntry>[PaymentEntry(accountId: acc, amount: 1000)],
      );

      // ③ 在途送货（「待签收」应命中）
      final Document delivery = doc(
        type: DocType.delivery,
        partyId: party,
        totalAmount: 2000,
      );
      run(delivery, lines: <DocumentLine>[line(delivery, p, 4, 500)]);

      Set<String> idsFor(Set<DocumentStatusView> views) => documents
          .listDocuments(statusViews: views)
          .map((DocumentSummary e) => e.document.id)
          .toSet();

      final Set<String> unsettled = idsFor(
        const <DocumentStatusView>{DocumentStatusView.unsettled},
      );
      expect(unsettled, contains(sale.id), reason: '60 的单退了 15 ⇒ 仍欠 45');
      expect(
        unsettled,
        isNot(contains(paid.id)),
        reason: '已结清的不算未结清',
      );
      expect(
        unsettled,
        contains(delivery.id),
        reason: '在途送货单也还欠着钱（货送了没收到钱）',
      );
      expect(
        unsettled,
        isNot(contains(ret.id)),
        reason: '退货单本身不产生欠款',
      );

      final Set<String> cancelledIds = idsFor(
        const <DocumentStatusView>{DocumentStatusView.cancelled},
      );
      expect(cancelledIds, isEmpty, reason: '本夹具没有作废单');

      final Set<String> awaiting = idsFor(
        const <DocumentStatusView>{DocumentStatusView.awaitingSignature},
      );
      expect(awaiting, <String>{delivery.id});

      // 多选 = 并集
      expect(
        idsFor(const <DocumentStatusView>{
          DocumentStatusView.awaitingSignature,
          DocumentStatusView.unsettled,
        }),
        containsAll(<String>[sale.id, delivery.id]),
        reason: '多选 = 并集',
      );
      expect(
        idsFor(const <DocumentStatusView>{
          DocumentStatusView.awaitingSignature,
          DocumentStatusView.unsettled,
        }),
        isNot(contains(paid.id)),
        reason: '已结清单既不是「未结清」也不是「待签收」—— 不该混进并集',
      );
    });

    test('untilMillis 上界 + types 多选（自定义时间范围 / 多类型）', () {
      final String p = createProduct();
      final String party = createParty();

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 1000,
      );
      run(sale, lines: <DocumentLine>[line(sale, p, 2, 500)]);
      final int boundary = now();
      final Document after = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 2000,
      );
      run(after, lines: <DocumentLine>[line(after, p, 4, 500)]);

      final List<String> before = documents
          .listDocuments(untilMillis: boundary)
          .map((DocumentSummary e) => e.document.id)
          .toList();
      expect(before, contains(sale.id));
      expect(before, isNot(contains(after.id)), reason: '上界是开区间');

      // types 多选 = 并集；且只含选中类型
      final Set<DocType> picked = <DocType>{DocType.sale, DocType.purchase};
      expect(
        documents
            .listDocuments(types: picked)
            .every((DocumentSummary e) => picked.contains(e.document.docType)),
        isTrue,
      );
    });
  });
}
