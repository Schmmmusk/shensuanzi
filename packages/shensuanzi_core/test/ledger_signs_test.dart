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

  /// 核对一张单的三本账符号是否与符号表一致。
  ///
  /// `sign == 0` 表示「这类单据不该有这张表的流水」⇒ 要求一行都没有。
  void expectSigns(String docId, DocType type, {String? label}) {
    final String what = label ?? type.wire;
    for (final (String table, String column, int sign)
        in <(String, String, int)>[
          ('stock_ledger', 'quantity', stockSignOf(type)),
          ('party_ledger', 'amount', partySignOf(type)),
          ('money_ledger', 'amount', moneySignOf(type)),
        ]) {
      final int sum = sumOf(table, column, docId);
      if (sign == 0) {
        expect(sum, 0, reason: '$what 不该有 $table 流水，实际合计 $sum');
        continue;
      }
      expect(
        sum.sign,
        sign,
        reason:
            '$what 的 $table 方向应为 ${sign > 0 ? '+' : '−'}，'
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
