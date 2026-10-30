// 退货之后的债务结论（用户裁定 2026-10-30 ⑤）。
//
// ## 为什么这件事值得单独一个测试文件
//
// 用户原话：「退货完成后的欠款提示不够明显，导致用户必须去难以逐行计算的流水中
// 找到自己真正的欠款」。
//
// 退货页从前保存完就直接关窗，用户回到详情页要跨「金额 / 已收 / 已退货 / 未收」
// 四行心算 —— 对熟练用户只是麻烦，对目标用户是算错账的来源。
//
// 这一层的职责只有一个：**把「谁欠谁、欠多少」算准并定死方向**，
// 界面只负责按结果选词。所以用例覆盖四种方向组合，一个都不能少。
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
  late ReturnService returns;
  late SettlementService settle;

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
    returns = ReturnService(engine: engine, queries: queries);
    settle = SettlementService(db: db, engine: engine);

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

  // ------------------------------------------------------------ 夹具

  String idOf(String docNo) =>
      db.raw.select('SELECT id FROM documents WHERE doc_no = ?', <Object?>[
            docNo,
          ]).first['id']!
          as String;

  /// 卖 [qty] 瓶给客户甲（¥10/瓶），当场收 [paidCents] 分（0 = 全赊）。
  String sell({required int qty, required int paidCents}) {
    final SaleSaved saved = sales.create(
      SaleDraft(
        partyId: customerId,
        partyName: '客户甲',
        date: '2026-10-04',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '$qty',
            unitPrice: '10',
          ),
        ],
        payments: paidCents > 0
            ? <SalePaymentDraft>[
                SalePaymentDraft(
                  accountId: accountId,
                  accountName: '现金',
                  amount: (paidCents / 100).toStringAsFixed(2),
                ),
              ]
            : const <SalePaymentDraft>[],
      ),
    );
    return idOf(saved.docNo);
  }

  /// 从供应商乙进 [qty] 瓶（¥10/瓶），当场付 [paidCents] 分。
  String buy({required int qty, required int paidCents}) {
    final PurchaseSaved saved = purchases.create(
      PurchaseDraft(
        partyId: supplierId,
        partyName: '供应商乙',
        date: '2026-10-04',
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '$qty',
            unitPrice: '10',
          ),
        ],
        payments: paidCents > 0
            ? <PurchasePaymentDraft>[
                PurchasePaymentDraft(
                  accountId: accountId,
                  accountName: '现金',
                  amount: (paidCents / 100).toStringAsFixed(2),
                ),
              ]
            : const <PurchasePaymentDraft>[],
      ),
    );
    return idOf(saved.docNo);
  }

  /// 退货 [qty] 瓶、**不立即退钱**（挂账冲减）—— 就是用户说的那个场景。
  void returnWithoutRefund({
    required String refDocId,
    required DocType originalType,
    required int qty,
  }) {
    returns.create(
      ReturnDraft(
        refDocId: refDocId,
        originalDocType: originalType,
        partyId: originalType == DocType.purchase ? supplierId : customerId,
        partyName: originalType == DocType.purchase ? '供应商乙' : '客户甲',
        lines: <ReturnLineDraft>[
          ReturnLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '$qty',
            amount: (qty * 10).toStringAsFixed(2),
            originalQuantity: 100,
            originalAmountCents: 100000,
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 四种方向
  group('outstandingAfterReturn（退货之后的债务结论）', () {
    test('全款收了再退、不退钱 ⇒ 反过来是「我欠客户」', () {
      // 卖 10 瓶 = ¥100，收 ¥100；退 3 瓶 = ¥30 不退钱
      // 未收 = 100 − 100 − 30 = **−30** ⇒ 我们欠客户 ¥30
      final String docId = sell(qty: 10, paidCents: 10000);
      returnWithoutRefund(refDocId: docId, originalType: DocType.sale, qty: 3);

      final OutstandingAfterReturn result = settle.outstandingAfterReturn(
        docId,
      );
      expect(result.inbound, isTrue, reason: '销售单是我方应收方向');
      expect(result.cents, -3000);
      expect(result.settled, isFalse);
      expect(result.weOweCents, 3000, reason: '退得比收得多 ⇒ 钱在我们手里，得退给客户');
      expect(result.theyOweCents, 0);
    });

    test('只收了一部分再退货 ⇒ 客户还欠我（这是最常见的场景）', () {
      // 卖 10 瓶 = ¥100，收 ¥50；退 3 瓶 = ¥30
      // 未收 = 100 − 50 − 30 = **20** ⇒ 客户还欠 ¥20
      final String docId = sell(qty: 10, paidCents: 5000);
      returnWithoutRefund(refDocId: docId, originalType: DocType.sale, qty: 3);

      final OutstandingAfterReturn result = settle.outstandingAfterReturn(
        docId,
      );
      expect(result.cents, 2000);
      expect(result.theyOweCents, 2000, reason: '客户还欠 ¥20');
      expect(result.weOweCents, 0);
    });

    test('收的钱正好等于退货后应收 ⇒ 两清', () {
      // 卖 10 瓶 = ¥100，收 ¥70；退 3 瓶 = ¥30
      // 未收 = 100 − 70 − 30 = **0**
      final String docId = sell(qty: 10, paidCents: 7000);
      returnWithoutRefund(refDocId: docId, originalType: DocType.sale, qty: 3);

      final OutstandingAfterReturn result = settle.outstandingAfterReturn(
        docId,
      );
      expect(result.cents, 0);
      expect(result.settled, isTrue);
      expect(result.theyOweCents, 0);
      expect(result.weOweCents, 0);
    });

    test('采购退货（我方应付方向）⇒ 方向要反过来', () {
      // 进 10 瓶 = ¥100，付 ¥50；退 3 瓶 = ¥30
      // 未付 = 100 − 50 − 30 = **20** ⇒ **我还欠供应商** ¥20
      final String docId = buy(qty: 10, paidCents: 5000);
      returnWithoutRefund(
        refDocId: docId,
        originalType: DocType.purchase,
        qty: 3,
      );

      final OutstandingAfterReturn result = settle.outstandingAfterReturn(
        docId,
      );
      expect(result.inbound, isFalse, reason: '采购单是我方应付方向');
      expect(result.cents, 2000);
      expect(
        result.weOweCents,
        2000,
        reason: '同样的正数 20，在采购单上是「我欠供应商」—— 方向必须由服务层定',
      );
      expect(result.theyOweCents, 0);
    });
  });

  // ------------------------------------------------------------ 纯类型
  group('OutstandingAfterReturn 的方向换算', () {
    OutstandingAfterReturn make(int cents, {required bool inbound}) =>
        OutstandingAfterReturn(
          cents: cents,
          inbound: inbound,
          docType: inbound ? DocType.sale : DocType.purchase,
        );

    test('四个象限都算对（正/负 × 应收/应付）', () {
      expect(make(100, inbound: true).theyOweCents, 100);
      expect(make(100, inbound: true).weOweCents, 0);
      expect(make(-100, inbound: true).weOweCents, 100);
      expect(make(-100, inbound: true).theyOweCents, 0);
      expect(make(100, inbound: false).weOweCents, 100);
      expect(make(100, inbound: false).theyOweCents, 0);
      expect(make(-100, inbound: false).theyOweCents, 100);
      expect(make(-100, inbound: false).weOweCents, 0);
    });

    test('0 是两清，两个方向都是 0', () {
      expect(make(0, inbound: true).settled, isTrue);
      expect(make(0, inbound: true).weOweCents, 0);
      expect(make(0, inbound: true).theyOweCents, 0);
    });
  });
}
