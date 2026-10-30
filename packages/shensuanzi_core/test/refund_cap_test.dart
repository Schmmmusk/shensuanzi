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

  // ------------------------------------------------------------ 主机权威
  group('主机规则层才是权威边界（绕过 ReturnService）', () {
    test('直接调 RuleEngine.dispatch 造退货单 ⇒ 同样拒绝', () {
      // 用户审查 2026-10-30：`SyncServer._createDocument` 收到客户端请求后
      // **直接调 `_engine.dispatch`**，完全绕过 `ReturnService`。
      // 如果闸只在服务层，同步入口就能造出超额退款 —— 而 Android 客户端
      // 暂时不开这条路，不等于永远不会。
      final String deliveryId = signedDelivery(qty: 10);
      final int stamp = now();

      final Document returnDoc = Document(
        id: newId(),
        docNo: 'TEST-RET-001',
        docType: DocType.saleReturn,
        status: DocStatus.confirmed,
        partyId: customerId,
        refDocId: deliveryId,
        totalAmount: 3000,
        occurredAt: stamp,
        createdAt: stamp,
        updatedAt: stamp,
      );
      final List<DocumentLine> lines = <DocumentLine>[
        DocumentLine.create(
          documentId: returnDoc.id,
          productId: productId,
          quantity: 3,
          amount: 3000,
          entryQuantity: 3,
          entryUnit: '瓶',
        ),
      ];

      final RuleOutcome outcome = engine.dispatch(
        document: returnDoc,
        lines: lines,
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: accountId, amount: 3000),
        ],
        now: stamp,
      );

      expect(
        outcome.status,
        isNot(RuleStatus.applied),
        reason: '一分钱没收的送货单，直接走同步入口也不许退款',
      );
      expect(outcome.reason, contains('还没收到'));
      // 而且什么都没写进去
      final int count =
          db.raw
                  .select(
                    'SELECT COUNT(*) FROM documents WHERE id = ?',
                    <Object?>[returnDoc.id],
                  )
                  .first
                  .values
                  .first!
              as int;
      expect(count, 0, reason: '拒绝时不该留下半张单');
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

  // ------------------------------------------------------------ 延迟退款
  group('事后用付款单核销退货单（延迟退款）也受同一上限约束', () {
    /// 建一张付款单核销退货单 [returnId]，金额 [cents]。
    int paySeq = 0;
    RuleOutcome payReturn(String returnId, int cents) {
      final int stamp = now();
      return engine.dispatch(
        document: Document(
          id: newId(),
          // ⚠️ 不能用 `newId().substring(...)` 造号：`newId()` 前几位是时间前缀，
          // 同一毫秒内建两张会撞 `documents.doc_no` 的唯一约束（踩过）。
          docNo: 'TEST-PAY-${++paySeq}',
          docType: DocType.payment,
          status: DocStatus.confirmed,
          partyId: customerId,
          accountId: accountId,
          totalAmount: cents,
          occurredAt: stamp,
          createdAt: stamp,
          updatedAt: stamp,
        ),
        allocations: <Allocation>[
          Allocation(targetDocId: returnId, amount: cents),
        ],
        now: stamp,
      );
    }

    test('两笔退货都挂账、各用付款单退一次 ⇒ 第二次超真实收款，拒绝', () {
      // 用户审查 2026-10-30（P0）：「后续独立核销退货单的退款路径没有纳入
      // 原单累计退款额度校验」。
      //
      // 退货时选「不立即退钱」是常见操作，钱以后再退 —— 那条路走的是
      // **独立的付款单核销退货单**，根本不经过 `_return()` 里的
      // `_requireRefundWithinCap`。而 `_settle` 只校验
      // `已核销 + 本次 ≤ 本单金额`，于是两张各 ¥750 的退货单各自核销一次，
      // 每次都「没超过本单金额」，累计却退出去 ¥1500，而原单只收到过 ¥1000
      // —— 多出的 ¥500 是凭空付出去的钱。
      final String saleId = sell(qty: 250, paidCents: 100000); // ¥2500，只收 ¥1000
      final String a = idOf(
        doReturn(
          refDocId: saleId,
          originalType: DocType.sale,
          qty: 75,
          refundCents: 0,
        ).docNo,
      );
      final String b = idOf(
        doReturn(
          refDocId: saleId,
          originalType: DocType.sale,
          qty: 75,
          refundCents: 0,
        ).docNo,
      );

      expect(
        payReturn(a, 75000).status,
        RuleStatus.applied,
        reason: '退 ¥750 ≤ 收到 ¥1000，这一笔是合法的',
      );

      final RuleOutcome second = payReturn(b, 75000);
      expect(
        second.status,
        isNot(RuleStatus.applied),
        reason: '再退 ¥750 就累计退出去 ¥1500，而只收到过 ¥1000',
      );
      expect(second.reason, contains('只收到'));

      final int rows =
          db.raw.select(
                'SELECT COUNT(*) AS c FROM settlements WHERE target_doc_id = ?',
                <Object?>[b],
              ).first['c']!
              as int;
      expect(rows, 0, reason: '拒绝时不该留下核销记录');
    });

    /// 建一张**收款单**核销退货单（采购退货的延迟收款方向）。
    RuleOutcome collectReturn(String returnId, int cents) {
      final int stamp = now();
      return engine.dispatch(
        document: Document(
          id: newId(),
          docNo: 'TEST-REC-${++paySeq}',
          docType: DocType.receipt,
          status: DocStatus.confirmed,
          partyId: supplierId,
          accountId: accountId,
          totalAmount: cents,
          occurredAt: stamp,
          createdAt: stamp,
          updatedAt: stamp,
        ),
        allocations: <Allocation>[
          Allocation(targetDocId: returnId, amount: cents),
        ],
        now: stamp,
      );
    }

    /// 一张收付款单核销多个目标。
    RuleOutcome payMany(List<(String, int)> targets) {
      final int stamp = now();
      int total = 0;
      for (final (String, int) t in targets) {
        total += t.$2;
      }
      return engine.dispatch(
        document: Document(
          id: newId(),
          docNo: 'TEST-PAY-${++paySeq}',
          docType: DocType.payment,
          status: DocStatus.confirmed,
          partyId: customerId,
          accountId: accountId,
          totalAmount: total,
          occurredAt: stamp,
          createdAt: stamp,
          updatedAt: stamp,
        ),
        allocations: <Allocation>[
          for (final (String, int) t in targets)
            Allocation(targetDocId: t.$1, amount: t.$2),
        ],
        now: stamp,
      );
    }

    test('**采购退货**用收款单延迟退款，也受累计上限约束（用户审查 P0）', () {
      // 销售退货走 `payment`（钱流出），采购退货走 `receipt`（钱流入）——
      // 方向相反。从前上限检查写成 `if (moneyOut && …)`，于是**采购退货整类漏检**：
      // 每张退货单单独看都不超本单金额，累计却超过实际付出去的钱。
      final String purchaseId = buy(
        qty: 100,
        paidCents: 50000,
      ); // ¥1000，实付 ¥500
      final String a = idOf(
        doReturn(
          refDocId: purchaseId,
          originalType: DocType.purchase,
          qty: 40,
          refundCents: 0,
        ).docNo,
      );
      final String b = idOf(
        doReturn(
          refDocId: purchaseId,
          originalType: DocType.purchase,
          qty: 40,
          refundCents: 0,
        ).docNo,
      );

      expect(
        collectReturn(a, 40000).status,
        RuleStatus.applied,
        reason: '收回 ¥400 ≤ 实付 ¥500，这一笔合法',
      );

      final RuleOutcome second = collectReturn(b, 40000);
      expect(
        second.status,
        isNot(RuleStatus.applied),
        reason: '再收回 ¥400 就累计 ¥800，而只付出去过 ¥500',
      );
      expect(
        second.reason,
        contains('只付出去过'),
        reason: '采购退货的措辞要跟方向走 —— 说「没收到过钱」会让用户莫名其妙',
      );
    });

    test('一张付款单同时核销**同一原单的两张**退货单 ⇒ 合计超额拒绝', () {
      // 逐目标检查读到的都是同一份历史累计（本次核销还没落库）：
      // A 看 0+600 ≤ 600 通过，B 看 0+600 ≤ 600 也通过 —— 合计 ¥1200 却超了 ¥1000。
      final String saleId = sell(qty: 250, paidCents: 100000); // ¥2500，实收 ¥1000
      final String a = idOf(
        doReturn(
          refDocId: saleId,
          originalType: DocType.sale,
          qty: 60,
          refundCents: 0,
        ).docNo,
      );
      final String b = idOf(
        doReturn(
          refDocId: saleId,
          originalType: DocType.sale,
          qty: 60,
          refundCents: 0,
        ).docNo,
      );

      final RuleOutcome outcome = payMany(<(String, int)>[
        (a, 60000),
        (b, 60000),
      ]);
      expect(
        outcome.status,
        isNot(RuleStatus.applied),
        reason: '两张各 ¥600 合计 ¥1200 > 实收 ¥1000，不能因为逐张都不超就放过',
      );
      expect(outcome.reason, contains('只收到'));
    });

    test('两张退货单属于**不同原单** ⇒ 各自算额度，不合并（不误杀）', () {
      final String s1 = sell(qty: 250, paidCents: 100000);
      final String s2 = sell(qty: 250, paidCents: 100000);
      final String a = idOf(
        doReturn(
          refDocId: s1,
          originalType: DocType.sale,
          qty: 60,
          refundCents: 0,
        ).docNo,
      );
      final String b = idOf(
        doReturn(
          refDocId: s2,
          originalType: DocType.sale,
          qty: 60,
          refundCents: 0,
        ).docNo,
      );

      final RuleOutcome outcome = payMany(<(String, int)>[
        (a, 60000),
        (b, 60000),
      ]);
      expect(
        outcome.status,
        RuleStatus.applied,
        reason:
            '两张退货单各自的原单都收过 ¥1000，各退 ¥600 都合法 —— '
            '按原单分组，不能把两笔额度并成一张 ¥1000 的额度',
      );
    });

    test('只收到 ¥1000、退 ¥1000 ⇒ 正好用光，通过（不误杀）', () {
      final String saleId = sell(qty: 250, paidCents: 100000);
      final String a = idOf(
        doReturn(
          refDocId: saleId,
          originalType: DocType.sale,
          qty: 100,
          refundCents: 0,
        ).docNo,
      );
      expect(payReturn(a, 100000).status, RuleStatus.applied);
      expect(returns.refundableCentsOf(saleId), 0, reason: '额度已用光');
    });
  });
}
