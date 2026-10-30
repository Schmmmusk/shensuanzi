// 退款上限（用户裁定 2026-10-30 ⑥）。
//
// ## 为什么这是 P0
//
// 一张「已签收、一分钱没收到」的送货单，退货时从前照样显示退款卡片 ——
// 用户填了金额、提交，系统生成一张 payment 单。**账上凭空多出一笔支出**，
// 而货其实根本没付过钱。
//
// 用户原话：「这种问题发生了后果更难收拾」—— 对，它不是显示问题，是造错账的入口。
//
// ## 判据（用户裁定）
//
//   ① 本次退款 ≤ 本次退货应退金额        —— 由 `recordedRefundCents` 的钳制保证
//   ② 累计实际退款（含本次） ≤ 原单真实收款
//   ③ 原单真实收款 == 0 ⇒ 任何退款请求都拒绝
//
// ⚠️「真实收款」走 `settlements`，**不是** `documents.paid_amount`（那是缓存）。
// 用例里故意用「只收一部分」的场景把两者区分开。
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

  // ------------------------------------------------------------ 夹具

  String idOf(String docNo) =>
      db.raw.select('SELECT id FROM documents WHERE doc_no = ?', <Object?>[
            docNo,
          ]).first['id']!
          as String;

  /// 卖 [qty] 瓶（¥10/瓶），当场收 [paidCents] 分（0 = 全赊）。
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

  /// 开一张送货单并**签收**（未收款 —— 用户举的那个场景）。
  String signedDelivery({required int qty}) {
    final DeliverySaved saved = deliveries.create(
      DeliveryDraft(
        partyId: customerId,
        partyName: '客户甲',
        date: '2026-10-04',
        lines: <DeliveryLineDraft>[
          DeliveryLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '$qty',
            unitPrice: '10',
          ),
        ],
      ),
    );
    final String id = idOf(saved.docNo);
    deliveries.markDelivered(id);
    return id;
  }

  /// 进 [qty] 瓶，当场付 [paidCents] 分。
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

  /// 退货 [qty] 瓶，并**立即退 [refundYuan] 元**（0 = 挂账不退钱）。
  ReturnSaved doReturn({
    required String refDocId,
    required DocType originalType,
    required int qty,
    required int refundCents,
  }) {
    final bool purchase = originalType == DocType.purchase;
    return returns.create(
      ReturnDraft(
        refDocId: refDocId,
        originalDocType: originalType,
        partyId: purchase ? supplierId : customerId,
        partyName: purchase ? '供应商乙' : '客户甲',
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
        refunds: refundCents > 0
            ? <ReturnRefundDraft>[
                ReturnRefundDraft(
                  accountId: accountId,
                  accountName: '现金',
                  amount: (refundCents / 100).toStringAsFixed(2),
                ),
              ]
            : const <ReturnRefundDraft>[],
      ),
    );
  }

  Matcher rejectedWith(String fragment) => throwsA(
    isA<RuleRejected>().having(
      (RuleRejected e) => e.reason,
      'reason',
      contains(fragment),
    ),
  );

  // ------------------------------------------------------------ 收款为 0
  group('原单没收到过钱 ⇒ 一律不许退款', () {
    test('送货已签收、一分未收 ⇒ 拒绝（用户举的那个场景）', () {
      final String deliveryId = signedDelivery(qty: 10);
      expect(
        () => doReturn(
          refDocId: deliveryId,
          originalType: DocType.delivery,
          qty: 3,
          refundCents: 3000,
        ),
        rejectedWith('还没收到'),
        reason: '货送到了、钱没收到，退什么款 —— 真退出去就是凭空多一笔支出',
      );
    });

    test('销售全赊 ⇒ 同样拒绝（不只送货）', () {
      final String saleId = sell(qty: 10, paidCents: 0);
      expect(
        () => doReturn(
          refDocId: saleId,
          originalType: DocType.sale,
          qty: 3,
          refundCents: 3000,
        ),
        rejectedWith('还没收到'),
      );
    });

    test('采购全赊 ⇒ 同样拒绝（我方应付方向也一样）', () {
      final String purchaseId = buy(qty: 10, paidCents: 0);
      expect(
        () => doReturn(
          refDocId: purchaseId,
          originalType: DocType.purchase,
          qty: 3,
          refundCents: 3000,
        ),
        rejectedWith('还没'),
      );
    });

    test('**不退钱**的退货不受影响（挂账冲减是正常操作）', () {
      final String deliveryId = signedDelivery(qty: 10);
      final ReturnSaved saved = doReturn(
        refDocId: deliveryId,
        originalType: DocType.delivery,
        qty: 3,
        refundCents: 0,
      );
      expect(saved.totalCents, 3000);
      expect(saved.refundedCents, 0, reason: '挂账冲减不涉及钱');
    });
  });

  // ------------------------------------------------------------ 累计上限
  group('累计退款 ≤ 原单真实收款', () {
    test('只收了 50，却要退 60 ⇒ 拒绝', () {
      final String saleId = sell(qty: 10, paidCents: 5000);
      expect(
        () => doReturn(
          refDocId: saleId,
          originalType: DocType.sale,
          qty: 6,
          refundCents: 6000,
        ),
        rejectedWith('只收到'),
        reason: '本次退款（60）没超退货额（60），但超了真实收款（50）',
      );
    });

    test('分两次退，累计超收款 ⇒ 第二次拒绝', () {
      // 收 40；第一次退 30 退 30（累计 30 ≤ 40，通过）
      // 第二次退 20 想退 20（累计 50 > 40）⇒ 拒绝
      final String saleId = sell(qty: 10, paidCents: 4000);
      doReturn(
        refDocId: saleId,
        originalType: DocType.sale,
        qty: 3,
        refundCents: 3000,
      );
      expect(
        () => doReturn(
          refDocId: saleId,
          originalType: DocType.sale,
          qty: 2,
          refundCents: 2000,
        ),
        rejectedWith('只收到'),
        reason: '已经退过 30，这次再退 20 就超过收到过的 40 了',
      );
    });

    test('refundableCentsOf：界面用它决定显示不显示输入框（与拦截同源）', () {
      final String saleId = sell(qty: 10, paidCents: 5000);
      expect(
        returns.refundableCentsOf(saleId),
        5000,
        reason: '收了 50、还没退过 ⇒ 最多能退 50',
      );
      doReturn(
        refDocId: saleId,
        originalType: DocType.sale,
        qty: 3,
        refundCents: 3000,
      );
      expect(
        returns.refundableCentsOf(saleId),
        2000,
        reason: '退过 30 ⇒ 只剩 20 可退',
      );
    });

    test('收了 100、退 30 退 30 ⇒ 正常通过（不误杀）', () {
      final String saleId = sell(qty: 10, paidCents: 10000);
      final ReturnSaved saved = doReturn(
        refDocId: saleId,
        originalType: DocType.sale,
        qty: 3,
        refundCents: 3000,
      );
      expect(saved.refundedCents, 3000);
    });
  });
}
