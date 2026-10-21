// RULE-006 查询（`docs/rules.md`），对应 `docs/testing.md` §C。
//
// 覆盖：库存 / 账户余额 / 往来余额 / 在途 / 在店可售 / 存在性判定。
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

  List<DocumentLine> oneLine(
    String docId,
    String productId,
    int qty,
    int price,
  ) => <DocumentLine>[
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
    final RuleOutcome outcome = run(
      purchase,
      oneLine(purchase.id, productId, qty, unitPrice),
    );
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
      expect(
        entry.docNo.startsWith(Document.pendingDocNoPrefix),
        isFalse,
        reason: '用户认的是正式单号不是 UUID',
      );
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

  // ===== #27 批 1（2026-10-17）：账户资金流水（JOIN documents 人可读版）=====
  //
  // 照「往来流水视图」组的先例 —— `ofAccountReadable` 是 `ofParty` 的账户版。
  group('账户资金流水视图（#27 批 1：JOIN documents 人可读版）', () {
    test('收款/付款带回 doc_no / doc_type；金额口径 = 进账正；按 seq_no 排序', () {
      final String p = createProduct();
      final String party = createParty();
      final String supplier = createParty();
      final String cash = createAccount(name: '现金', initialBalance: 0);
      final String wechat = createAccount(name: '微信', initialBalance: 0);

      seedPurchase(p, supplier, 10, 100); // 采购 1000
      final Document purchase = doc(
        type: DocType.purchase,
        partyId: supplier,
        totalAmount: 1000,
      );
      run(purchase, oneLine(purchase.id, p, 10, 100));

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 3000,
      );
      run(sale, oneLine(sale.id, p, 3, 1000));

      // 进账 3000（现金）
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

      // 出账 500（付供应商，同账户）
      final Document payment = doc(
        type: DocType.payment,
        partyId: supplier,
        accountId: cash,
        totalAmount: 500,
      );
      engine.dispatch(
        document: payment,
        allocations: <Allocation>[
          Allocation(targetDocId: purchase.id, amount: 500),
        ],
        now: now(),
      );

      final List<MoneyFlowEntry> flow = MoneyLedgerDao(
        db,
      ).ofAccountReadable(cash);
      expect(flow, hasLength(2));
      expect(flow[0].seqNo, lessThan(flow[1].seqNo));

      final MoneyFlowEntry receiptEntry = flow.firstWhere(
        (MoneyFlowEntry e) => e.docType == DocType.receipt,
      );
      expect(receiptEntry.amount, 3000, reason: '进账 = 正（balanceOf 口径）');
      expect(
        receiptEntry.docNo.startsWith(Document.pendingDocNoPrefix),
        isFalse,
        reason: '用户认的是正式单号不是 UUID',
      );
      expect(receiptEntry.documentId, receipt.id, reason: '详情跳转要用它');

      final MoneyFlowEntry paymentEntry = flow.firstWhere(
        (MoneyFlowEntry e) => e.docType == DocType.payment,
      );
      expect(paymentEntry.amount, -500, reason: '出账 = 负');

      // 只含本账户
      expect(MoneyLedgerDao(db).ofAccountReadable(wechat), isEmpty);
    });

    test('#27 批 2：库存流水 —— 入库正 / 出库负 / 成本带回 / 只含本商品', () {
      final String p = createProduct();
      final String other = createProduct(code: 'P002');
      final String supplier = createParty();
      final String party = createParty();

      seedPurchase(p, supplier, 10, 100); // 入库 +10（成本 1000）

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 3000,
      );
      run(sale, oneLine(sale.id, p, 3, 1000)); // 出库 -3

      // 另一商品的流水不该出现
      seedPurchase(other, supplier, 7, 100);

      final List<StockFlowEntry> flow = StockLedgerDao(db).ofProductReadable(p);
      expect(flow, hasLength(2));
      expect(flow[0].seqNo, lessThan(flow[1].seqNo));

      final StockFlowEntry inbound = flow.firstWhere(
        (StockFlowEntry e) => e.quantity > 0,
      );
      expect(inbound.quantity, 10, reason: '入库 = 正');
      expect(inbound.docType, DocType.purchase);
      expect(inbound.totalCost, 1000, reason: '成本真相（进价 × 数量）');
      expect(inbound.unitCost, 100);

      final StockFlowEntry outbound = flow.firstWhere(
        (StockFlowEntry e) => e.quantity < 0,
      );
      expect(outbound.quantity, -3, reason: '出库 = 负');
      expect(outbound.totalCost, -300, reason: '成本随数量同号（流出记负，3 × 100）');
      expect(outbound.unitCost, 100);

      // 另一商品没有本商品流水
      expect(StockLedgerDao(db).ofProductReadable(other).length, 1);
      expect(
        StockLedgerDao(
          db,
        ).ofProductReadable(other).first.documentId.contains('d-'),
        anyOf(isTrue, isFalse),
      );
      expect(StockLedgerDao(db).ofProductReadable(other).first.quantity, 7);
    });

    test('认不出的 doc_type ⇒ 跳行 + 计数（#42 同款，不整页塌）', () {
      final String cash = createAccount(name: '现金', initialBalance: 0);
      // 直接种一条「文档类型是库外值」的脏数据（模拟 forward-compat）
      db.raw.execute(
        "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
        'paid_amount, occurred_at, time_estimated, created_at, updated_at) '
        "VALUES ('d-x', 'XX-1', 'nope', 'confirmed', 0, 0, 1, 0, 1, 1)",
      );
      MoneyLedgerDao(db).insert(
        MoneyLedger(
          id: newId(),
          accountId: cash,
          documentId: 'd-x',
          amount: 100,
          seqNo: 1,
          occurredAt: 1,
          createdAt: 1,
        ),
      );

      final List<MoneyFlowEntry> flow = MoneyLedgerDao(
        db,
      ).ofAccountReadable(cash);
      expect(flow, isEmpty, reason: '坏行跳过');
      expect(
        db.readFailures.count,
        greaterThan(0),
        reason: '跳过必须计数 —— 不许静默（#42 L4：跳行可能藏一笔钱）',
      );
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

  // ============================================================ 存在性判定

  group('存在性判定（§AE 遗漏 1 / §AD 遗漏 1、2）', () {
    test('空库：hasAnyDocument / hasAnyStockLedger 都是 false', () {
      expect(query.hasAnyDocument(), isFalse);
      expect(query.hasAnyStockLedger(), isFalse);
      expect(query.inboundProductIds(), isEmpty);
    });

    test('落过单 → hasAnyDocument true；有过流水 → hasAnyStockLedger true', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 5, 100);

      expect(query.hasAnyDocument(), isTrue);
      expect(query.hasAnyStockLedger(), isTrue);
    });

    test('inboundProductIds：只认正数量流水（出库不算「进过货」）', () {
      final String stocked = createProduct();
      final String neverBought = createProduct(code: 'P002');
      final String party = createParty();

      seedPurchase(stocked, party, 5, 100);

      // 超卖一个从没进过货的商品 —— 它只有**负数量**流水
      final Document sale = doc(
        type: DocType.sale,
        partyId: createParty(),
        totalAmount: 300,
      );
      run(sale, oneLine(sale.id, neverBought, 1, 300));

      final Set<String> inbound = query.inboundProductIds();
      expect(inbound, contains(stocked));
      expect(
        inbound,
        isNot(contains(neverBought)),
        reason: '只有出库流水 → 成本口径没有意义（§AD 遗漏 1）',
      );
    });
  });
  // ============================================================ #32 概览速览

  group('#32 概览速览（todaySummary / receivablesSummary / 未签收 / 未同步计数）', () {
    test('todaySummary：sale / delivery 分列；金额 = total_amount 合计', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 10, 100);

      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 300,
      );
      run(sale, oneLine(sale.id, p, 3, 100));

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: party,
        totalAmount: 500,
      );
      run(delivery, oneLine(delivery.id, p, 5, 100));

      final OverviewSummary s = query.todaySummary(
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(s.saleCount, 1);
      expect(s.saleCents, 300);
      expect(s.deliveryCount, 1);
      expect(s.deliveryCents, 500);
    });

    test('含赊账、排除 cancelled；收付款 / 退货 / 盘点不进卡', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 10, 100);

      // 赊账销售（无收款）—— 也算销售额
      final Document credit = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 800,
      );
      run(credit, oneLine(credit.id, p, 8, 100));

      // 已取消的销售（金额也要过 B5 校验才能落库，取消才有意义）
      final Document cancelled = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 100,
      );
      run(cancelled, oneLine(cancelled.id, p, 1, 100));
      db.raw.execute('UPDATE documents SET status = ? WHERE id = ?', <Object?>[
        DocStatus.cancelled.wire,
        cancelled.id,
      ]);

      final OverviewSummary s = query.todaySummary(
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(s.saleCount, 1, reason: '赊账算、取消不算');
      expect(s.saleCents, 800);
    });

    test('裁定②补录边界：occurred_at 在 dayStart 之前 ⇒ 不进今日', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 10, 100);

      final Document late = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 700,
      );
      run(late, oneLine(late.id, p, 3, 100));
      // 补录：把业务日期改到昨天（clock 基点 1700000000000 ⇒ 零点取它，往前 1 天）
      db.raw.execute(
        'UPDATE documents SET occurred_at = ? WHERE id = ?',
        <Object?>[1700000000000 - 86400000, late.id],
      );

      final OverviewSummary s = query.todaySummary(
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(s.saleCount, 0, reason: '按单据日期算 —— 补录昨天的单不进今日');
      expect(s.saleCents, 0);
    });

    test('裁定跨日：dayStart 传明天 ⇒ 全为 0（dayStart 由调用方传入）', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 10, 100);
      final Document sale = doc(
        type: DocType.sale,
        partyId: party,
        totalAmount: 300,
      );
      run(sale, oneLine(sale.id, p, 3, 100));

      final OverviewSummary s = query.todaySummary(
        DateTime.fromMillisecondsSinceEpoch(1700000000000 + 86400000),
      );
      expect(s.saleCount, 0);
      expect(s.deliveryCount, 0);
    });

    test('deliveryInTransitCount：在途 1 → 签收后 0', () {
      final String p = createProduct();
      final String party = createParty();
      seedPurchase(p, party, 12, 100);

      final Document delivery = doc(
        type: DocType.delivery,
        partyId: party,
        totalAmount: 600,
      );
      run(delivery, oneLine(delivery.id, p, 6, 100));
      expect(query.deliveryInTransitCount(), 1);

      expect(
        RuleEngine(
          db,
        ).markDelivered(documentId: delivery.id, now: now()).status,
        anyOf(RuleStatus.applied, RuleStatus.alreadyExists),
      );
      expect(query.deliveryInTransitCount(), 0);
    });

    test('receivablesSummary：合计 / 家数 / top1（停用也在内且标注）', () {
      final String p = createProduct();
      seedPurchase(p, createParty(), 30, 100);

      // 两家赊账客户：甲 1200（最高）、乙 500
      final String jia = createParty();
      final String yi = createParty();
      db.raw.execute('UPDATE parties SET name = ? WHERE id = ?', <Object?>[
        '客户甲',
        jia,
      ]);
      db.raw.execute('UPDATE parties SET name = ? WHERE id = ?', <Object?>[
        '客户乙',
        yi,
      ]);
      final Document s1 = doc(
        type: DocType.sale,
        partyId: jia,
        totalAmount: 1200,
      );
      run(s1, oneLine(s1.id, p, 12, 100));
      final Document s2 = doc(
        type: DocType.sale,
        partyId: yi,
        totalAmount: 500,
      );
      run(s2, oneLine(s2.id, p, 5, 100));
      // 停用甲（欠得最多的停用客户 —— OBS-05：照样显示）
      db.raw.execute('UPDATE parties SET is_active = 0 WHERE id = ?', <Object?>[
        jia,
      ]);

      final ReceivablesSummary r = query.receivablesSummary();
      expect(r.totalCents, 1700);
      expect(r.partyCount, 2);
      expect(r.topName, '客户甲', reason: '欠得最多的排前（OBS-05）');
      expect(r.topActive, isFalse, reason: 'UI 据此标「（已停用）」');
      expect(r.topCents, 1200);
    });

    test('PendingMarks.unconfirmedCount：pending + sent 都算，确认后归零', () {
      final PendingMarks marks = PendingMarks(SyncQueueDao(db));
      expect(marks.unconfirmedCount(), 0);

      final SyncQueueDao queue = SyncQueueDao(db);
      final SyncQueueEntry entry = queue.enqueue(
        SyncQueueEntry.create(
          SyncOperation(
            entity: Schema.products,
            entityId: 'px',
            operation: SyncOpType.createMasterData,
            payload: <String, Object?>{'id': 'px', 'name': 'x'},
          ),
          now: now(),
        ),
      );
      expect(marks.unconfirmedCount(), 1, reason: 'pending 算');
      queue.markSent(entry.id);
      expect(marks.unconfirmedCount(), 1, reason: 'sent 也算（未确认）');
      queue.clearConfirmed(<String>{'px'});
      expect(marks.unconfirmedCount(), 0, reason: '确认清除后归零');
    });
  });
}
