// RULE-006 查询（`docs/rules.md`），对应 `docs/testing.md` §C。
//
// 覆盖：库存 / 账户余额 / 往来余额 / 在途 / 在店可售。
// 核心主张：**没有余额表，每次都从流水算**（`docs/data_model.md` §五）。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`（`test` 是 dev_dependency），
// 且 Windows 需要可用的 SQLite 原生库，见 `lib/sqlite_local.dart`。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

import 'package:shensuanzi_core/sqlite_local.dart';
import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late RuleEngine engine;
  late QueryDao query;
  late ProductDao products;
  late AccountDao accounts;

  setUp(() {
    resetClock();
    db = newMemoryDb();
    engine = RuleEngine(db);
    query = QueryDao(db);
    products = ProductDao(db);
    accounts = AccountDao(db);
  });

  tearDown(() => db.close());

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

  String createAccount({String name = '现金', int initialBalance = 0}) {
    final int t = now();
    final Account a = Account(
      id: newId(),
      name: name,
      type: AccountType.cash,
      initialBalance: initialBalance,
      createdAt: t,
      updatedAt: t,
    );
    accounts.insert(a);
    return a.id;
  }

  String createParty() {
    final int t = now();
    final Party p = Party(
      id: newId(),
      name: '往来方',
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
  }) => Document(
    id: newId(),
    docNo: '${Document.pendingDocNoPrefix}abc123',
    docType: type,
    status: DocStatus.confirmed,
    partyId: partyId,
    accountId: accountId,
    totalAmount: totalAmount,
    occurredAt: now(),
    createdAt: now(),
    updatedAt: now(),
  );

  List<DocumentLine> oneLine(String docId, String productId, int qty, int price) =>
      <DocumentLine>[
        DocumentLine.create(
          documentId: docId,
          productId: productId,
          quantity: qty,
          unitPrice: price,
        ),
      ];

  RuleOutcome run(Document d, List<DocumentLine> ls) =>
      engine.dispatch(document: d, lines: ls, now: now());

  void seedPurchase(String productId, String partyId, int qty, int unitPrice) {
    final Document purchase = doc(
      type: DocType.purchase,
      partyId: partyId,
      totalAmount: qty * unitPrice,
    );
    final RuleOutcome outcome = run(purchase, oneLine(purchase.id, productId, qty, unitPrice));
    expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
  }

  // ============================================================ 库存

  group('库存（RULE-006）', () {
    test('stockByProduct 从流水算，等于 SUM(quantity)', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 10, 100);

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 300,
      );
      run(sale, oneLine(sale.id, p, 3, 100));

      expect(query.stockByProduct()[p], 7);
    });

    test('只包含有流水的商品：进过货的在，没进过货的不在', () {
      final String p = createProduct();
      final String untouched = createProduct(code: 'P002');
      final String party = createParty();
      seedPurchase(p, party, 10, 100);

      final Map<String, int> stock = query.stockByProduct();
      expect(stock, contains(p));
      expect(stock[p], 10);
      expect(
        stock,
        isNot(contains(untouched)),
        reason: '从没进过货的商品不出现（GROUP BY 只覆盖有流水的行）',
      );
      expect(stock[untouched] ?? 0, 0, reason: '消费端用 ?? 0 兜底');
    });

    test('负库存如实反映（超卖允许）', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 2, 100);

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 500,
      );
      run(sale, oneLine(sale.id, p, 5, 100));

      expect(query.stockByProduct()[p], -3);
    });

    test('costByProduct = SUM(total_cost)：正常为正、超卖转负（R-9）', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 10, 100); // 成本余值 1000

      expect(query.costByProduct()[p], 1000);

      // ⚠️ totalAmount 必须等于明细和（12 × 100）：B5 不变量，不符会被拒
      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 1200,
      );
      run(sale, oneLine(sale.id, p, 12, 100)); // 卖 12 件 > 库存 10 → 超卖

      // 12 × 100 出库成本 > 1000 入库 → 余值 -200（UI 必须红色，§AA AA-4）
      expect(query.costByProduct()[p], -200);
    });
  });

  // ============================================================ 余额

  group('账户余额（RULE-006）', () {
    test('= initial_balance + SUM(money_ledger.amount)', () {
      final String p = createProduct();
      final String party = createParty();
      final String cash = createAccount(initialBalance: 10000);

      seedPurchase(p, party, 10, 100);

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 3000,
      );
      run(sale, oneLine(sale.id, p, 3, 1000));

      // 收 3000
      final Document receipt = doc(
        type: DocType.receipt,
        partyId: party,
        accountId: cash,
        totalAmount: 3000,
      );
      engine.dispatch(
        document: receipt,
        allocations: <Allocation>[
          Allocation(targetDocId: sale.id, amount: 3000),
        ],
        now: now(),
      );

      expect(query.accountBalances()[cash], 13000, reason: '10000 + 3000');
    });

    test('没有任何流水的账户也在结果里（LEFT JOIN）', () {
      final String idle = createAccount(name: '闲置账户', initialBalance: 500);

      expect(query.accountBalances(), contains(idle));
      expect(query.accountBalances()[idle], 500);
    });
  });

  group('往来余额（RULE-006）', () {
    test('正 = 应收，负 = 应付', () {
      final String p = createProduct();
      final String supplier = createParty();
      final String customer = createParty();

      seedPurchase(p, supplier, 10, 100); // 我欠供应商 1000

      final Document sale = doc(
        type: DocType.sale,
        partyId: customer,
        totalAmount: 2000,
      );
      run(sale, oneLine(sale.id, p, 2, 1000)); // 客户欠我 2000

      final Map<String, int> balances = query.partyBalances();
      expect(balances[supplier], -1000, reason: '应付为负');
      expect(balances[customer], 2000, reason: '应收为正');
    });
  });

  group('往来流水视图（§AA 六 / AA-6：JOIN documents 人可读版）', () {
    test('带回 doc_no / doc_type；金额口径不变；按 seq_no 排序', () {
      final String p = createProduct();
      final String customer = createParty();
      final Document sale = doc(
        type: DocType.sale,
        partyId: customer,
        totalAmount: 2000,
      );
      run(sale, oneLine(sale.id, p, 2, 1000)); // 客户欠我 2000

      final List<PartyFlowEntry> flow = PartyLedgerDao(db).ofParty(customer);

      expect(flow, hasLength(1));
      final PartyFlowEntry entry = flow.single;
      // ⚠️ dispatch 会把占位单号换成正式单号 —— 断言「非待同步前缀」
      expect(entry.docNo.startsWith(Document.pendingDocNoPrefix), isFalse,
          reason: '用户认的是正式单号不是 UUID');
      expect(entry.docType, DocType.sale, reason: '要能区分采购/收款');
      expect(entry.amount, 2000, reason: '正 = 对方欠我增加（口径不变）');
      expect(entry.documentId, sale.id);
      // 裸流水时代的 .length / .single.seqNo 调用保持兼容
      expect(entry.seqNo, greaterThan(0));
    });

    test('多笔按 seq_no 排序；散客单（party_id null）不出现', () {
      final String p = createProduct();
      final String supplier = createParty();
      seedPurchase(p, supplier, 5, 100); // 第一笔

      final Document purchase2 = doc(
        type: DocType.purchase,
        partyId: supplier,
        totalAmount: 500,
      );
      run(purchase2, oneLine(purchase2.id, p, 5, 100)); // 第二笔

      final List<PartyFlowEntry> flow = PartyLedgerDao(db).ofParty(supplier);
      expect(flow, hasLength(2));
      expect(flow[0].seqNo, lessThan(flow[1].seqNo));
      for (final PartyFlowEntry entry in flow) {
        expect(entry.docType, DocType.purchase);
      }

      // 散客销售（无 party）不产生流水，也不影响本列表
      final int before = flow.length;
      final Document sale = doc(type: DocType.sale, totalAmount: 300);
      run(sale, oneLine(sale.id, p, 1, 300));
      expect(PartyLedgerDao(db).ofParty(supplier), hasLength(before));
    });
  });

  // ============================================================ 在途

  group('在途与在店可售（RULE-006 / RULE-003）', () {
    test('送货未签收 → 在途数量 = 送货数量', () {
      final String p = createProduct();
      final String supplier = createParty();
      final String customer = createParty();
      seedPurchase(p, supplier, 20, 100);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 500,
      );
      run(delivery, oneLine(delivery.id, p, 5, 100));

      expect(query.stockByProduct()[p], 15, reason: '账面已扣');
      expect(query.inTransitByProduct()[p], 5);
      expect(query.availableInStore()[p], 10, reason: '在店可售 = 15 − 5');
    });

    test('签收后在途归零，在店可售回到账面库存', () {
      final String p = createProduct();
      final String supplier = createParty();
      final String customer = createParty();
      seedPurchase(p, supplier, 20, 100);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: customer,
        totalAmount: 500,
      );
      run(delivery, oneLine(delivery.id, p, 5, 100));
      expect(query.availableInStore()[p], 10);

      final RuleOutcome signed = engine.markDelivered(
        documentId: delivery.id,
        now: now(),
      );
      expect(signed.status, RuleStatus.applied, reason: signed.reason);

      expect(query.inTransitByProduct()[p] ?? 0, 0, reason: '已签收，不在途');
      expect(query.availableInStore()[p], 15, reason: '等于账面库存');
    });

    test('没有送货单时在店可售 = 账面库存', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 8, 100);

      expect(query.inTransitByProduct(), isEmpty);
      expect(query.availableInStore()[p], 8);
    });
  });
}
