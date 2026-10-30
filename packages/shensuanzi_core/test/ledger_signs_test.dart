// 符号表（`ledger_signs.dart`）与规则层的**对拍**。
//
// ## 为什么要这个文件
//
// `stockSignOf` / `partySignOf` / `moneySignOf` 是抢救器、对账工具查的**唯一口径**，
// 而 `RuleEngine` 各处是**显式**写符号的（`quantity: -line.quantity`）。
// 两份东西只要有一边改了，账就会一半对一半错 —— 而且极难发现。
//
// 所以这里用**真引擎**把每种单据造一遍，再回头核对三本账的符号：
// 规则层改了符号而没改表 ⇒ 这里立刻红。
//
// 用户审查 2026-10-30：「符号不是格式，是业务含义本身。」
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late RuleEngine engine;
  late SaleService sales;
  late PurchaseService purchases;
  late DeliveryService deliveries;
  late ReturnService returns;

  late String productId;
  late String accountId;
  late String customerId;
  late String supplierId;

  setUp(() {
    resetClock();
    db = newMemoryDb();
    engine = RuleEngine(db);
    final QueryDao queries = QueryDao(db);
    sales = SaleService(engine: engine, queries: queries);
    purchases = PurchaseService(engine: engine, queries: queries);
    deliveries = DeliveryService(engine: engine, queries: queries);
    returns = ReturnService(engine: engine, queries: queries);

    final int t = now();
    final Product product = Product(
      id: newId(),
      code: 'P001',
      name: '纯牛奶',
      unit: '瓶',
      costPrice: 600,
      sellPrice: 1000,
      createdAt: t,
      updatedAt: t,
    );
    ProductDao(db).insert(product);
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

    final Party supplier = Party(
      id: newId(),
      name: '供应商乙',
      roles: const <PartyRole>[PartyRole.supplier],
      createdAt: t,
      updatedAt: t,
    );
    PartyDao(db).insert(supplier);
    supplierId = supplier.id;
  });

  tearDown(() => db.close());

  // ------------------------------------------------------------ 工具

  String idOf(String docNo) =>
      db.raw.select('SELECT id FROM documents WHERE doc_no = ?', <Object?>[
            docNo,
          ]).first['id']!
          as String;

  /// 某张单在某一列上的**有符号**合计（没有行 ⇒ 0）。
  int sumOf(String table, String column, String docId) {
    final Object? v = db.raw.select(
      'SELECT COALESCE(SUM($column), 0) AS s FROM $table '
      'WHERE document_id = ?',
      <Object?>[docId],
    ).first['s'];
    return v is int ? v : 0;
  }

  /// 某张单在某张表里的**行数**。
  int rowsOf(String table, String docId) {
    final Object? v = db.raw.select(
      'SELECT COUNT(*) AS c FROM $table WHERE document_id = ?',
      <Object?>[docId],
    ).first['c'];
    return v is int ? v : 0;
  }

  /// 核对一张单的三本账方向是否与符号表一致。
  ///
  /// ⚠️ [LedgerDirection.absent] 的分支查的是 **`COUNT(*)`，不是 `SUM()`**：
  /// 两条 `+100` / `−100` 的流水合计为 0，用 `SUM` 判会放过
  /// （用户审查 2026-10-30）。「不该有」就是一行都不能有。
  void expectSigns(String docId, DocType type, {String? label}) {
    final String what = label ?? type.wire;
    for (final (String table, String column, LedgerDirection dir)
        in <(String, String, LedgerDirection)>[
          ('stock_ledger', 'quantity', stockDirectionOf(type)),
          ('party_ledger', 'amount', partyDirectionOf(type)),
          ('money_ledger', 'amount', moneyDirectionOf(type)),
        ]) {
      final int rows = rowsOf(table, docId);
      if (dir == LedgerDirection.absent) {
        expect(rows, 0, reason: '$what 不该有 $table 流水，实际 $rows 行');
        continue;
      }
      if (dir == LedgerDirection.either) {
        // 方向不固定（盘点）⇒ 不比符号
        continue;
      }
      expect(rows, greaterThan(0), reason: '$what 应该有 $table 流水');
      final int sum = sumOf(table, column, docId);
      expect(
        sum.sign,
        dir.sign,
        reason:
            '$what 的 $table 方向应为 ${dir.sign! > 0 ? '+' : '−'}，'
            '实际合计 $sum —— 符号表与规则层漂了',
      );
    }
  }

  // ------------------------------------------------------------ 各类型

  test('采购 + 立即付款：采购 +库存 −往来，付款单 −资金 +往来', () {
    final PurchaseSaved saved = purchases.create(
      PurchaseDraft(
        partyId: supplierId,
        partyName: '供应商乙',
        date: '2026-10-04',
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '10',
            unitPrice: '10',
          ),
        ],
        payments: <PurchasePaymentDraft>[
          PurchasePaymentDraft(
            accountId: accountId,
            accountName: '现金',
            amount: '100',
          ),
        ],
      ),
    );
    final String purchaseId = idOf(saved.docNo);
    expectSigns(purchaseId, DocType.purchase);

    final String paymentId =
        db.raw.select('SELECT id FROM documents WHERE doc_type = ?', <Object?>[
              'payment',
            ]).first['id']!
            as String;
    expectSigns(paymentId, DocType.payment);
  });

  test('销售 + 立即收款：销售 −库存 +往来，收款单 +资金 −往来', () {
    final SaleSaved saved = sales.create(
      SaleDraft(
        partyId: customerId,
        partyName: '客户甲',
        date: '2026-10-04',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '3',
            unitPrice: '10',
          ),
        ],
        payments: <SalePaymentDraft>[
          SalePaymentDraft(
            accountId: accountId,
            accountName: '现金',
            amount: '30',
          ),
        ],
      ),
    );
    expectSigns(idOf(saved.docNo), DocType.sale);

    final String receiptId =
        db.raw.select('SELECT id FROM documents WHERE doc_type = ?', <Object?>[
              'receipt',
            ]).first['id']!
            as String;
    expectSigns(receiptId, DocType.receipt);
  });

  test('送货：−库存 +往来（未收款，不产生资金流水）', () {
    final DeliverySaved saved = deliveries.create(
      DeliveryDraft(
        partyId: customerId,
        partyName: '客户甲',
        date: '2026-10-04',
        lines: <DeliveryLineDraft>[
          DeliveryLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '5',
            unitPrice: '10',
          ),
        ],
      ),
    );
    expectSigns(idOf(saved.docNo), DocType.delivery);
  });

  test('销售退货：+库存 −往来（货回库、冲销应收）', () {
    final SaleSaved sale = sales.create(
      SaleDraft(
        partyId: customerId,
        partyName: '客户甲',
        date: '2026-10-04',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '3',
            unitPrice: '10',
          ),
        ],
      ),
    );
    final ReturnSaved ret = returns.create(
      ReturnDraft(
        refDocId: idOf(sale.docNo),
        originalDocType: DocType.sale,
        partyId: customerId,
        partyName: '客户甲',
        lines: <ReturnLineDraft>[
          ReturnLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '1',
            amount: '10.00',
            originalQuantity: 3,
            originalAmountCents: 3000,
          ),
        ],
      ),
    );
    expectSigns(idOf(ret.docNo), DocType.saleReturn);
  });

  test('采购退货：−库存 +往来（货出库、冲销应付）', () {
    final PurchaseSaved bought = purchases.create(
      PurchaseDraft(
        partyId: supplierId,
        partyName: '供应商乙',
        date: '2026-10-04',
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '10',
            unitPrice: '10',
          ),
        ],
        payments: <PurchasePaymentDraft>[
          PurchasePaymentDraft(
            accountId: accountId,
            accountName: '现金',
            amount: '100',
          ),
        ],
      ),
    );
    final ReturnSaved ret = returns.create(
      ReturnDraft(
        refDocId: idOf(bought.docNo),
        originalDocType: DocType.purchase,
        partyId: supplierId,
        partyName: '供应商乙',
        lines: <ReturnLineDraft>[
          ReturnLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '2',
            amount: '20.00',
            originalQuantity: 10,
            originalAmountCents: 10000,
          ),
        ],
      ),
    );
    expectSigns(idOf(ret.docNo), DocType.purchaseReturn);
  });

  test('isSupportedDocType：只有 transfer 明确「不支持」', () {
    // 规则层 v1 拒绝调拨。抢救器必须据此把它判成「认得但不支持」，
    // 而不是当成一张普通的、没有流水的空壳单据导进新库。
    for (final DocType type in DocType.values) {
      expect(
        isSupportedDocType(type),
        type != DocType.transfer,
        reason: '${type.wire} 的支持性判断错了',
      );
    }
  });

  test('盘点：不产生往来与资金流水（符号表给 0）', () {
    final Document doc = Document(
      id: newId(),
      docNo: 'PD-SIGN-1',
      docType: DocType.stocktake,
      status: DocStatus.confirmed,
      totalAmount: 0,
      occurredAt: now(),
      createdAt: now(),
      updatedAt: now(),
    );
    final RuleOutcome outcome = engine.dispatch(
      document: doc,
      now: now(),
      stocktakeActual: <String, int>{productId: 7},
    );
    expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
    // 库存那本账方向可正可负（取决于差额），所以只核对往来与资金
    expect(sumOf('party_ledger', 'amount', doc.id), 0);
    expect(sumOf('money_ledger', 'amount', doc.id), 0);
  });
}
