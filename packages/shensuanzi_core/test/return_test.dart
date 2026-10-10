// RULE-007 销售退货 / RULE-008 采购退货（`docs/rules.md`），对应 `docs/testing.md` §E / §F。
//
// 成本口径来自 **R-11 裁定 · 方案 A（原单比例精确回退）**，
// 算法见 `docs/data_model.md` §3.3「退货的成本分摊」。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`（`test` 是 dev_dependency），
// 且 Windows 需要可用的 SQLite 原生库，见 `lib/sqlite_local.dart`。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'package:shensuanzi_core/sqlite_local.dart';
import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late RuleEngine engine;
  late ProductDao products;
  late AccountDao accounts;
  late DocumentDao documents;
  late StockLedgerDao stock;
  late MoneyLedgerDao money;
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
    money = MoneyLedgerDao(db);
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
  }) => Document(
    id: newId(),
    docNo: '${Document.pendingDocNoPrefix}abc123',
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

  RuleOutcome run(Document d, List<DocumentLine> ls) =>
      engine.dispatch(document: d, lines: ls, now: now());

  /// 某单据写入的库存成本（该单只有一条 line 时无歧义）
  int stockCostOf(String documentId) =>
      db.raw
              .select(
                'SELECT total_cost FROM stock_ledger WHERE document_id = ?',
                <Object?>[documentId],
              )
              .first['total_cost']!
          as int;

  /// 入库备货，返回原采购单
  Document seedPurchase(
    String productId,
    String partyId,
    int qty,
    int unitPrice,
  ) {
    final Document purchase = doc(
      type: DocType.purchase,
      partyId: partyId,
      totalAmount: qty * unitPrice,
    );
    final RuleOutcome outcome = run(
      purchase,
      oneLine(purchase.id, productId, qty, unitPrice),
    );
    expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
    return purchase;
  }

  // ============================================================ R-11 成本分摊

  group('RULE-008 采购退货 · 成本分摊（R-11 方案 A）', () {
    test('单次部分退 → round_half_up(原单 total_cost × 退货量 / 原单数量)', () {
      final String p = createProduct();
      final String party = createParty();
      final Document purchase = seedPurchase(p, party, 10, 100);

      final Document ret = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 300,
        refDocId: purchase.id,
      );
      final RuleOutcome outcome = run(ret, oneLine(ret.id, p, 3, 100));

      expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
      expect(stock.stockOf(p), 7);

      final StockLedger row = stock.ofProduct(p).last;
      expect(row.quantity, -3, reason: '采购退货是货出库');
      expect(row.totalCost, -300, reason: '1000 × 3 / 10，符号为负');
    });

    test('单次全额退 → total_cost = 原单 total_cost，库存成本精确归零', () {
      final String p = createProduct();
      final String party = createParty();
      final Document purchase = seedPurchase(p, party, 10, 100);

      final Document ret = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 1000,
        refDocId: purchase.id,
      );
      run(ret, oneLine(ret.id, p, 10, 100));

      expect(stockCostOf(ret.id), -1000);
      expect(stock.stockOf(p), 0);
      expect(stock.costSnapshotOf(p).totalCost, 0);
    });

    test('多次部分退 3 + 3 + 4，原 total_cost = 1001 → 300 / 301 / 400', () {
      final String p = createProduct();
      final String party = createParty();

      // 原单同一商品两条明细：1×101 + 9×100 = 1001，数量合计 10
      final Document purchase = doc(
        type: DocType.purchase,
        partyId: party,
        totalAmount: 1001,
      );
      final RuleOutcome seeded = engine.dispatch(
        document: purchase,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: purchase.id,
            productId: p,
            quantity: 1,
            unitPrice: 101,
          ),
          DocumentLine.create(
            documentId: purchase.id,
            productId: p,
            quantity: 9,
            unitPrice: 100,
          ),
        ],
        now: now(),
      );
      expect(seeded.status, RuleStatus.applied, reason: seeded.reason);
      expect(stock.costSnapshotOf(p).totalCost, 1001);

      final List<int> costs = <int>[];
      for (final int qty in <int>[3, 3, 4]) {
        final Document ret = doc(
          type: DocType.purchaseReturn,
          partyId: party,
          totalAmount: qty * 100,
          refDocId: purchase.id,
        );
        final RuleOutcome outcome = run(ret, oneLine(ret.id, p, qty, 100));
        expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
        costs.add(stockCostOf(ret.id));
      }

      expect(costs, <int>[-300, -301, -400], reason: '余数由最后一次吸收');
      expect(
        costs.reduce((int a, int b) => a + b),
        -1001,
        reason: '三次之和精确等于应分摊总额',
      );
      expect(stock.stockOf(p), 0);
      expect(stock.costSnapshotOf(p).totalCost, 0);
    });

    test('累计退货量超额 → 拒绝（return_exceeds_original），整单回滚', () {
      final String p = createProduct();
      final String party = createParty();
      final Document purchase = seedPurchase(p, party, 10, 100);

      final Document ok = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 800,
        refDocId: purchase.id,
      );
      expect(run(ok, oneLine(ok.id, p, 8, 100)).status, RuleStatus.applied);

      final Document over = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 300,
        refDocId: purchase.id,
      );
      final RuleOutcome outcome = run(over, oneLine(over.id, p, 3, 100));

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.code, RejectCode.returnExceedsOriginal, reason: outcome.reason);
      expect(documents.findById(over.id), isNull, reason: '整单回滚');
      expect(stock.stockOf(p), 2, reason: '第二次退货未落地任何流水');
    });

    test('多商品独立约束：A 超退不影响 B 的合法退货', () {
      final String a = createProduct(code: 'A');
      final String b = createProduct(code: 'B');
      final String party = createParty();

      final Document purchase = doc(
        type: DocType.purchase,
        partyId: party,
        totalAmount: 2000,
      );
      final RuleOutcome seeded = engine.dispatch(
        document: purchase,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: purchase.id,
            productId: a,
            quantity: 10,
            unitPrice: 100,
          ),
          DocumentLine.create(
            documentId: purchase.id,
            productId: b,
            quantity: 5,
            unitPrice: 200,
          ),
        ],
        now: now(),
      );
      expect(seeded.status, RuleStatus.applied, reason: seeded.reason);

      // A 退 8 → ok
      final Document a8 = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 800,
        refDocId: purchase.id,
      );
      expect(run(a8, oneLine(a8.id, a, 8, 100)).status, RuleStatus.applied);
      expect(stockCostOf(a8.id), -800);

      // A 再退 3 → 累计 11 > 10 → 拒绝
      final Document a3 = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 300,
        refDocId: purchase.id,
      );
      final RuleOutcome rejected = run(a3, oneLine(a3.id, a, 3, 100));
      expect(rejected.status, RuleStatus.rejected);
      expect(rejected.code, RejectCode.returnExceedsOriginal, reason: rejected.reason);

      // B 全额退 5 → 不受 A 影响
      final Document b5 = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 1000,
        refDocId: purchase.id,
      );
      expect(run(b5, oneLine(b5.id, b, 5, 200)).status, RuleStatus.applied);
      expect(stockCostOf(b5.id), -1000);
      expect(stock.stockOf(b), 0);
    });

    test('原单没有该商品的流水 → 拒绝', () {
      final String a = createProduct(code: 'A');
      final String b = createProduct(code: 'B');
      final String party = createParty();
      final Document purchase = seedPurchase(a, party, 10, 100);

      final Document ret = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 100,
        refDocId: purchase.id, // 原单里没有商品 B
      );
      final RuleOutcome outcome = run(ret, oneLine(ret.id, b, 1, 100));

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.code, RejectCode.ruleInternalError, reason: outcome.reason);
      expect(documents.findById(ret.id), isNull);
    });
  });

  // ============================================================ RULE-007

  group('RULE-007 销售退货', () {
    test('全额退 → 库存回、成本精确回流、往来冲销', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 10, 100); // 库存 10 / 成本 1000

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 2000,
      );
      run(sale, oneLine(sale.id, p, 10, 200));
      expect(stock.stockOf(p), 0);
      expect(stock.costSnapshotOf(p).totalCost, 0);
      // 采购未付 → -1000；销售 +2000 ⇒ 退货前 +1000
      expect(partyLedger.balanceOf(party), 1000);

      final Document ret = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 2000,
        refDocId: sale.id,
      );
      final RuleOutcome outcome = run(ret, oneLine(ret.id, p, 10, 200));

      expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
      expect(stock.stockOf(p), 10);

      final StockLedger row = stock.ofProduct(p).last;
      expect(row.quantity, 10, reason: '销售退货是货回库');
      expect(row.totalCost, 1000, reason: '原销售单出库成本 1000 精确回流');
      expect(stock.costSnapshotOf(p).totalCost, 1000);

      // 退货把销售的应收全额冲销（+1000 → −1000，只剩未付的采购款）
      expect(partyLedger.balanceOf(party), -1000);
    });

    test('部分退用 round-half-up：原单成本 302 / 数量 3 → 退 1 得 101（截断会得 100）', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 1, 2); // 1 件 2 分
      seedPurchase(p, party, 2, 150); // 2 件 300 分 ⇒ 库存 3 / 成本 302

      expect(stock.costSnapshotOf(p).totalCost, 302);

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 600,
      );
      run(sale, oneLine(sale.id, p, 3, 200));
      final StockLedger saleRow = stock.ofProduct(p).last;
      expect(saleRow.totalCost, -302, reason: '出库成本 = round(302 × 3 / 3)');
      expect(stock.stockOf(p), 0);

      final Document r1 = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 200,
        refDocId: sale.id,
      );
      expect(run(r1, oneLine(r1.id, p, 1, 200)).status, RuleStatus.applied);
      expect(stockCostOf(r1.id), 101, reason: 'round_half_up(302 × 1 / 3)');
      expect(302 ~/ 3, 100, reason: '若用 ~/ 截断会得到 100');

      final Document r2 = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 400,
        refDocId: sale.id,
      );
      expect(run(r2, oneLine(r2.id, p, 2, 200)).status, RuleStatus.applied);
      expect(
        stockCostOf(r2.id),
        201,
        reason: '累计分摊 302 − 已分摊 101，余数被吸收',
      );
      expect(stockCostOf(r1.id) + stockCostOf(r2.id), 302);
      expect(stock.costSnapshotOf(p).totalCost, 302);
    });

    test('负库存出库后退货 → 原样回退原单的估算成本', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 3, 100); // 库存 3 / 成本 300

      // 超卖 5 件（允许负库存）→ 出库成本 = round(300 × −5 / 3) = −500
      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 500,
      );
      run(sale, oneLine(sale.id, p, 5, 100));
      expect(stock.stockOf(p), -2);
      expect(stock.costSnapshotOf(p).totalCost, -200);
      expect(stock.ofProduct(p).last.totalCost, -500);

      final Document ret = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 200,
        refDocId: sale.id,
      );
      expect(run(ret, oneLine(ret.id, p, 2, 100)).status, RuleStatus.applied);

      expect(stockCostOf(ret.id), 200, reason: '回退 500 × 2 / 5');
      expect(stock.stockOf(p), 0);
      expect(stock.costSnapshotOf(p).totalCost, 0, reason: '回到「从未卖出」的状态');
    });

    test('立即退款 → 自动生成 payment 单，退货单 status = settled', () {
      final String p = createProduct();
      final String party = createParty();
      final String account = createAccount();
      seedPurchase(p, party, 10, 100);

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 5000,
      );
      run(sale, oneLine(sale.id, p, 10, 500));

      final Document ret = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 1000,
        refDocId: sale.id,
      );
      final RuleOutcome outcome = engine.dispatch(
        document: ret,
        lines: oneLine(ret.id, p, 2, 500),
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: account, amount: 1000),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: outcome.reason);

      final Document saved = documents.findById(ret.id)!;
      expect(saved.paidAmount, 1000);
      expect(saved.status, DocStatus.settled);
      expect(settlements.settledAmountOf(ret.id), 1000);

      // 退款走自动生成的 payment 单（纪律 11：主单不直接写 money_ledger）
      final Row refund = db.raw
          .select(
            'SELECT m.amount, d.doc_type FROM money_ledger m '
            'JOIN documents d ON d.id = m.document_id WHERE d.ref_doc_id = ?',
            <Object?>[ret.id],
          )
          .first;
      expect(refund['doc_type'], 'payment');
      expect(refund['amount'], -1000, reason: '退给客户 → 资金流出');
      expect(money.balanceOf(account), -1000);
    });

    test('未立即退款 → 未结清部分留在 party_ledger（我方应付）', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 10, 100);

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 5000,
      );
      run(sale, oneLine(sale.id, p, 10, 500));

      final Document ret = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 1000,
        refDocId: sale.id,
      );
      run(ret, oneLine(ret.id, p, 2, 500));

      expect(documents.findById(ret.id)!.status, DocStatus.confirmed);
      expect(documents.findById(ret.id)!.paidAmount, 0);
      // −1000（采购）+ 5000（销售）− 1000（退货）= 3000
      expect(partyLedger.balanceOf(party), 3000);
    });

    test('退货不修改原单 paid_amount', () {
      final String p = createProduct();
      final String party = createParty();
      final String account = createAccount();
      seedPurchase(p, party, 10, 100);

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 5000,
      );
      engine.dispatch(
        document: sale,
        lines: oneLine(sale.id, p, 10, 500),
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: account, amount: 3000),
        ],
        now: now(),
      );
      expect(documents.findById(sale.id)!.paidAmount, 3000);

      final Document ret = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 1000,
        refDocId: sale.id,
      );
      run(ret, oneLine(ret.id, p, 2, 500));

      expect(
        documents.findById(sale.id)!.paidAmount,
        3000,
        reason: '原单是已完成的历史交易，退货是独立的新交易',
      );
      expect(documents.findById(sale.id)!.status, DocStatus.confirmed);
    });

    test('拒收：ref_doc_id 指向 delivery 也被接受，成本按原送货单回退', () {
      final String p = createProduct();
      final String supplier = createParty(name: '供应商甲');
      final String customer = createParty(name: '客户乙');
      seedPurchase(p, supplier, 20, 100); // 库存 20 / 成本 2000

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 1000,
      );
      run(delivery, oneLine(delivery.id, p, 10, 100));
      expect(stock.stockOf(p), 10);
      expect(
        stock.ofProduct(p).last.totalCost,
        -1000,
        reason: '送货出库成本 = 2000 × 10 / 20',
      );
      expect(partyLedger.balanceOf(customer), 1000);

      // 客户拒收 4 件 —— 原单是 delivery，不是 sale
      final Document refused = doc(
        type: DocType.saleReturn,
        partyId: customer,
        totalAmount: 400,
        refDocId: delivery.id,
      );
      final RuleOutcome outcome = run(refused, oneLine(refused.id, p, 4, 100));

      expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
      expect(stock.stockOf(p), 14, reason: '4 件回库');

      final StockLedger row = stock.ofProduct(p).last;
      expect(row.quantity, 4);
      expect(row.totalCost, 400, reason: '原送货单出库成本 1000 × 4 / 10');
      expect(partyLedger.balanceOf(customer), 600, reason: '拒收冲销应收 400');
    });
  });

  // ============================================================ RULE-008 结算与校验

  group('RULE-008 采购退货 · 结算与校验', () {
    test('立即收退款 → 自动生成 receipt 单，退货单 status = settled', () {
      final String p = createProduct();
      final String party = createParty();
      final String account = createAccount();
      final Document purchase = seedPurchase(p, party, 10, 100);

      final Document ret = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 300,
        refDocId: purchase.id,
      );
      final RuleOutcome outcome = engine.dispatch(
        document: ret,
        lines: oneLine(ret.id, p, 3, 100),
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: account, amount: 300),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: outcome.reason);

      final Document saved = documents.findById(ret.id)!;
      expect(saved.paidAmount, 300);
      expect(saved.status, DocStatus.settled);

      final Row refund = db.raw
          .select(
            'SELECT m.amount, d.doc_type FROM money_ledger m '
            'JOIN documents d ON d.id = m.document_id WHERE d.ref_doc_id = ?',
            <Object?>[ret.id],
          )
          .first;
      expect(refund['doc_type'], 'receipt');
      expect(refund['amount'], 300, reason: '供应商退我们钱 → 资金流入');
      expect(money.balanceOf(account), 300);
      // −1000（采购）+ 300（退货）+（receipt 记 −300）⇒ 仍欠 1000
      expect(partyLedger.balanceOf(party), -1000);
    });

    test('ref_doc_id 缺失 → 拒绝', () {
      final String p = createProduct();
      final String party = createParty();

      final Document ret = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 100,
      );
      final RuleOutcome outcome = run(ret, oneLine(ret.id, p, 1, 100));

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.code, RejectCode.ruleInternalError, reason: outcome.reason);
      expect(documents.findById(ret.id), isNull);
    });

    test('ref_doc_id 指向错误类型 → 拒绝', () {
      final String p = createProduct();
      final String party = createParty();
      final Document purchase = seedPurchase(p, party, 10, 100);

      // sale_return 的原单必须是 sale，却给了 purchase
      final Document ret = doc(
        type: DocType.saleReturn,
        partyId: party,
        totalAmount: 100,
        refDocId: purchase.id,
      );
      final RuleOutcome outcome = run(ret, oneLine(ret.id, p, 1, 100));

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.code, RejectCode.ruleInternalError, reason: outcome.reason);
      expect(documents.findById(ret.id), isNull);
    });

    test('原单不存在 → 拒绝', () {
      final String p = createProduct();
      final String party = createParty();

      final Document ret = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 100,
        refDocId: 'no-such-document',
      );
      final RuleOutcome outcome = run(ret, oneLine(ret.id, p, 1, 100));

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.code, RejectCode.targetMissing, reason: outcome.reason);
    });
  });

  // ============================================================ 不变量

  group('不变量（docs/data_model.md §五）', () {
    test('库存 = SUM(stock_ledger.quantity)', () {
      final String p = createProduct();
      final String party = createParty();
      final Document purchase = seedPurchase(p, party, 10, 100);

      final Document r1 = doc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: 300,
        refDocId: purchase.id,
      );
      run(r1, oneLine(r1.id, p, 3, 100));

      final int sum = db.raw
          .select(
            'SELECT COALESCE(SUM(quantity), 0) AS s FROM stock_ledger '
            'WHERE product_id = ?',
            <Object?>[p],
          )
          .first['s']!
          as int;
      expect(stock.stockOf(p), sum);
      expect(stock.stockOf(p), 7);
      expect(stock.costSnapshotOf(p).totalCost, 700, reason: '1000 − 300');
    });
  });
}
