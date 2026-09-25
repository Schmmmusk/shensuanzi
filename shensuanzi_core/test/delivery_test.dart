// RULE-003 送货（`docs/rules.md`），对应 `docs/testing.md` §C。
//
// 覆盖：创建路径（状态机起点、库存出库、往来）、R-10 的 `status` 例外、
// 「在店可售」在途视图、不变量。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`（`test` 是 dev_dependency），
// 且 Windows 需要可用的 SQLite 原生库，见 `tool/sqlite_local.dart`。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../tool/sqlite_local.dart';
import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late RuleEngine engine;
  late ProductDao products;
  late AccountDao accounts;
  late DocumentDao documents;
  late StockLedgerDao stock;
  late PartyLedgerDao partyLedger;
  late SettlementDao settlements;

  setUp(() {
    resetClock();
    db = newMemoryDb();
    engine = RuleEngine(db);
    products = ProductDao(db);
    accounts = AccountDao(db);
    documents = DocumentDao(db);
    stock = StockLedgerDao(db);
    partyLedger = PartyLedgerDao(db);
    settlements = SettlementDao(db);
  });

  tearDown(() => db.close());

  // ------------------------------------------------------------ 夹具

  String createProduct({String code = 'P001'}) {
    final int t = now();
    final Product p = Product(
      id: newId(),
      code: code,
      name: '商品-$code',
      createdAt: t,
      updatedAt: t,
    );
    products.insert(p);
    return p.id;
  }

  String createAccount({String name = '现金'}) {
    final int t = now();
    final Account a = Account(
      id: newId(),
      name: name,
      type: AccountType.cash,
      createdAt: t,
      updatedAt: t,
    );
    accounts.insert(a);
    return a.id;
  }

  String createParty({String name = '往来方甲'}) {
    final int t = now();
    final Party p = Party(
      id: newId(),
      name: name,
      roles: const <PartyRole>[PartyRole.customer, PartyRole.supplier],
      createdAt: t,
      updatedAt: t,
    );
    PartyDao(db).insert(p);
    return p.id;
  }

  Document doc({
    required DocType type,
    String? partyId,
    String? accountId,
    int totalAmount = 0,
    String? refDocId,
    DocStatus status = DocStatus.confirmed,
  }) => Document(
    id: newId(),
    docNo: '${Document.pendingDocNoPrefix}abc123',
    docType: type,
    status: status,
    partyId: partyId,
    accountId: accountId,
    totalAmount: totalAmount,
    refDocId: refDocId,
    occurredAt: now(),
    createdAt: now(),
    updatedAt: now(),
  );

  List<DocumentLine> oneLine(
    String documentId,
    String productId,
    int qty,
    int price,
  ) => <DocumentLine>[
    DocumentLine.create(
      documentId: documentId,
      productId: productId,
      quantity: qty,
      unitPrice: price,
    ),
  ];

  /// 入库备货（货离店出库的成本来源）。**必须有供应商**，否则欠款无处记录。
  Document seedStock(
    String productId, {
    required String supplier,
    int qty = 20,
    int unitPrice = 100,
  }) {
    final Document purchase = doc(
      type: DocType.purchase,
      partyId: supplier,
      totalAmount: qty * unitPrice,
    );
    final RuleOutcome outcome = engine.dispatch(
      document: purchase,
      lines: oneLine(purchase.id, productId, qty, unitPrice),
      now: now(),
    );
    expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
    return purchase;
  }

  // ============================================================ 创建路径

  group('RULE-003 送货 · 创建', () {
    test('库存 −qty、成本按出库口径、往来 +total', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      seedStock(p, supplier: supplier, qty: 20, unitPrice: 100); // 库存 20 / 成本 2000

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 1000,
      );
      final RuleOutcome outcome = engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 10, 100),
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
      expect(stock.stockOf(p), 10, reason: '货离店即扣库存');

      final StockLedger row = stock.ofProduct(p).last;
      expect(row.quantity, -10);
      expect(row.totalCost, -1000, reason: '出库成本 = 2000 × 10 / 20');

      expect(partyLedger.balanceOf(customer), 1000, reason: '客户欠我 1000');
      expect(partyLedger.balanceOf(supplier), -2000, reason: '我欠供应商 2000');
      expect(
        documents.findById(delivery.id)!.docNo,
        isNot(contains(Document.pendingDocNoPrefix)),
        reason: '主机分配了正式单号',
      );
    });

    test('主机强制 status = in_transit（调用方传什么都覆盖）', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      seedStock(p, supplier: supplier);

      // 调用方故意传 confirmed —— 送货的状态机起点必须是 in_transit
      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 100,
        status: DocStatus.confirmed,
      );
      final RuleOutcome outcome = engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 1, 100),
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
      expect(outcome.document!.status, DocStatus.inTransit);
      expect(documents.findById(delivery.id)!.status, DocStatus.inTransit);
    });

    test('数量非正 → 拒绝，且整单无残留（单据未落库、库存未扣）', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      seedStock(p, supplier: supplier);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 0,
      );
      final RuleOutcome outcome = engine.dispatch(
        document: delivery,
        lines: <DocumentLine>[
          DocumentLine(
            id: newId(),
            documentId: delivery.id,
            productId: p,
            quantity: 0,
            unitPrice: 0,
            amount: 0,
          ),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(documents.findById(delivery.id), isNull);
      expect(stock.stockOf(p), 20, reason: '库存未被扣减');
    });

    test('有欠款但无 party_id → 拒绝（否则欠款凭空消失）', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      seedStock(p, supplier: supplier);

      final Document delivery = doc(
        type: DocType.delivery,
        totalAmount: 100,
      );
      final RuleOutcome outcome = engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 1, 100),
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.reason, contains('party_id'));
      expect(documents.findById(delivery.id), isNull);
    });
  });

  // ============================================================ R-10 例外

  group('R-10：delivery 的 status 不由 paid_amount 推导', () {
    test('全款立即收款 → paid_amount 刷新，但 status 仍为 in_transit', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      final String account = createAccount();
      seedStock(p, supplier: supplier);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 1000,
      );
      final RuleOutcome outcome = engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 10, 100),
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: account, amount: 1000),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: outcome.reason);

      final Document saved = documents.findById(delivery.id)!;
      expect(saved.paidAmount, 1000, reason: '不变量 B4 对 delivery 无例外');
      expect(
        saved.status,
        DocStatus.inTransit,
        reason: '状态机优先：钱到了但货未签收（R-10）',
      );
      expect(settlements.settledAmountOf(delivery.id), 1000);

      // 资金流仍挂在自动生成的 receipt 单下（纪律 11）
      final Row moneyOnMain = db.raw
          .select(
            'SELECT COUNT(*) AS c FROM money_ledger m '
            'JOIN documents d ON d.id = m.document_id WHERE d.ref_doc_id = ?',
            <Object?>[delivery.id],
          )
          .first;
      expect(moneyOnMain['c'], 1);
      expect(
        db.raw
            .select(
              'SELECT d.doc_type FROM money_ledger m '
              'JOIN documents d ON d.id = m.document_id WHERE d.ref_doc_id = ?',
              <Object?>[delivery.id],
            )
            .first['doc_type'],
        'receipt',
      );
    });
  });

  // ============================================================ 签收

  group('RULE-003 签收（v1 主机本地路径，docs/reply.md）', () {
    test('in_transit → delivered', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      seedStock(p, supplier: supplier);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 1000,
      );
      engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 10, 100),
        now: now(),
      );
      expect(documents.findById(delivery.id)!.status, DocStatus.inTransit);

      final RuleOutcome outcome = engine.markDelivered(
        documentId: delivery.id,
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
      final Document saved = documents.findById(delivery.id)!;
      expect(saved.status, DocStatus.delivered);
      expect(saved.paidAmount, 0);
    });

    test('已收满款时签收 → 同一事务内直接落到 settled', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      final String account = createAccount();
      seedStock(p, supplier: supplier);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 1000,
      );
      engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 10, 100),
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: account, amount: 1000),
        ],
        now: now(),
      );
      // 钱到了但未签收 → 状态机停在 in_transit
      expect(documents.findById(delivery.id)!.status, DocStatus.inTransit);
      expect(documents.findById(delivery.id)!.paidAmount, 1000);

      final RuleOutcome outcome = engine.markDelivered(
        documentId: delivery.id,
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
      expect(documents.findById(delivery.id)!.status, DocStatus.settled);
    });

    test('未收满款签收 → 停在 delivered', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      final String account = createAccount();
      seedStock(p, supplier: supplier);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 1000,
      );
      engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 10, 100),
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: account, amount: 400),
        ],
        now: now(),
      );

      engine.markDelivered(documentId: delivery.id, now: now());

      final Document saved = documents.findById(delivery.id)!;
      expect(saved.status, DocStatus.delivered);
      expect(saved.paidAmount, 400);
    });

    test('签收后收到余款 → delivered → settled（状态机补完）', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      final String account = createAccount();
      seedStock(p, supplier: supplier);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 1000,
      );
      engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 10, 100),
        now: now(),
      );
      engine.markDelivered(documentId: delivery.id, now: now());
      expect(documents.findById(delivery.id)!.status, DocStatus.delivered);

      // 客户回店付清余款 → RULE-004 核销
      final Document receipt = doc(
        type: DocType.receipt,
        partyId: customer,
        accountId: account,
        totalAmount: 1000,
      );
      final RuleOutcome settle = engine.dispatch(
        document: receipt,
        allocations: <Allocation>[
          Allocation(targetDocId: delivery.id, amount: 1000),
        ],
        now: now(),
      );

      expect(settle.status, RuleStatus.applied, reason: settle.reason);
      final Document saved = documents.findById(delivery.id)!;
      expect(saved.status, DocStatus.settled, reason: '签收后收满款 → settled');
      expect(saved.paidAmount, 1000);
    });

    test('重复签收是 no-op → alreadyExists，且不产生任何副作用', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      seedStock(p, supplier: supplier);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 1000,
      );
      engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 10, 100),
        now: now(),
      );

      expect(
        engine.markDelivered(documentId: delivery.id, now: now()).status,
        RuleStatus.applied,
      );

      final int stockRows = stock.ofProduct(p).length;
      final int partyRows = partyLedger.ofParty(customer).length;
      final int updatedAt = documents.findById(delivery.id)!.updatedAt;

      final RuleOutcome second = engine.markDelivered(
        documentId: delivery.id,
        now: now(),
      );

      expect(second.status, RuleStatus.alreadyExists);
      expect(second.document!.status, DocStatus.delivered);
      expect(stock.ofProduct(p).length, stockRows, reason: '不产生库存流水');
      expect(partyLedger.ofParty(customer).length, partyRows, reason: '不产生往来流水');
      expect(
        documents.findById(delivery.id)!.updatedAt,
        updatedAt,
        reason: '幂等命中时不写 updated_at',
      );
    });

    test('签收只改 status，不动库存与流水', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      seedStock(p, supplier: supplier, qty: 20, unitPrice: 100);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 1000,
      );
      engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 10, 100),
        now: now(),
      );

      final int stockBefore = stock.stockOf(p);
      final int stockCostBefore = stock.costSnapshotOf(p).totalCost;
      final int partyBefore = partyLedger.balanceOf(customer);
      final int stockRowsBefore = db.raw
          .select('SELECT COUNT(*) AS c FROM stock_ledger')
          .first['c']! as int;

      engine.markDelivered(documentId: delivery.id, now: now());

      expect(stock.stockOf(p), stockBefore);
      expect(stock.costSnapshotOf(p).totalCost, stockCostBefore);
      expect(partyLedger.balanceOf(customer), partyBefore);
      expect(
        db.raw.select('SELECT COUNT(*) AS c FROM stock_ledger').first['c'],
        stockRowsBefore,
      );
    });

    test('已取消的送货单不能签收 → rejected', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      seedStock(p, supplier: supplier);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 1000,
      );
      engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 10, 100),
        now: now(),
      );
      // 主机本地取消（白名单 UPDATE）
      documents.updateStatusAndPaid(
        id: delivery.id,
        status: DocStatus.cancelled,
        updatedAt: now(),
      );

      final RuleOutcome outcome = engine.markDelivered(
        documentId: delivery.id,
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.reason, contains('cancelled'));
      expect(documents.findById(delivery.id)!.status, DocStatus.cancelled);
    });

    test('非 delivery 单据不能签收 → rejected', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final Document purchase = seedStock(p, supplier: supplier);

      final RuleOutcome outcome = engine.markDelivered(
        documentId: purchase.id,
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.reason, contains('不适用'));
    });

    test('单据不存在 → rejected', () {
      final RuleOutcome outcome = engine.markDelivered(
        documentId: 'no-such-document',
        now: now(),
      );
      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.reason, contains('不存在'));
    });
  });

  // ============================================================ 在途视图

  group('在途视图（docs/rules.md RULE-003）', () {
    test('在店可售 = 账面库存 − 在途数量', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      seedStock(p, supplier: supplier, qty: 20, unitPrice: 100);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 500,
      );
      engine.dispatch(
        document: delivery,
        lines: oneLine(delivery.id, p, 5, 100),
        now: now(),
      );

      final int inTransit =
          db.raw
                  .select(
                    '''
                    SELECT COALESCE(SUM(dl.quantity), 0) AS n
                    FROM document_lines dl
                    JOIN documents d ON d.id = dl.document_id
                    WHERE d.doc_type = 'delivery' AND d.status = 'in_transit'
                      AND dl.product_id = ?
                    ''',
                    <Object?>[p],
                  )
                  .first['n']!
              as int;

      expect(stock.stockOf(p), 15, reason: '账面库存已扣（货离店即扣）');
      expect(inTransit, 5);
      expect(stock.stockOf(p) - inTransit, 10, reason: '在店可售');
    });
  });

  // ============================================================ 不变量

  group('不变量（docs/data_model.md §五）', () {
    test('库存 = SUM(stock_ledger.quantity)', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      seedStock(p, supplier: supplier, qty: 20, unitPrice: 100);

      for (final int qty in <int>[2, 3, 4]) {
        final Document delivery = doc(
          type: DocType.delivery,
          partyId: customer,
          totalAmount: qty * 100,
        );
        engine.dispatch(
          document: delivery,
          lines: oneLine(delivery.id, p, qty, 100),
          now: now(),
        );
      }

      final int sum =
          db.raw
                  .select(
                    'SELECT COALESCE(SUM(quantity), 0) AS s FROM stock_ledger '
                    'WHERE product_id = ?',
                    <Object?>[p],
                  )
                  .first['s']!
              as int;
      expect(stock.stockOf(p), sum);
      expect(stock.stockOf(p), 11, reason: '20 − 2 − 3 − 4');
    });
  });
}
