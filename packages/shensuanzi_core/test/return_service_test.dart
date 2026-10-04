// ReturnService —— RULE-007/008 的表单门槛（§BH·七 R1，reply.md 2026-10-04）。
//
// 覆盖：可退额度（quotasFor）· 累计比例法默认金额（裁定 3：派生单价乘数量有
// 舍入差）· 端到端落库（库存回退 / 往来冲减 / 立即退款）· 超额前置拦截 ·
// 退款封顶（裁定 5）· **拒收收口**（delivery 未签收 ⇒ cancelled，裁定 2）。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；Windows 需要可用的 SQLite 原生库。
import 'package:shensuanzi_core/shensuanzi_core.dart';
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
  late QueryDao queries;

  late ReturnService returns;
  late SaleService sales;
  late PurchaseService purchases;
  late DeliveryService deliveries;

  late String productId;
  late String accountId;
  late String customerId;
  late String supplierId;

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
    queries = QueryDao(db);

    returns = ReturnService(engine: engine, queries: queries);
    sales = SaleService(engine: engine, queries: queries);
    purchases = PurchaseService(engine: engine, queries: queries);
    deliveries = DeliveryService(engine: engine, queries: queries);

    final int t = now();
    final Product product = Product(
      id: newId(),
      code: 'P001',
      name: '蒙牛纯牛奶',
      unit: '瓶',
      packageUnit: '箱',
      packageSize: 12,
      costPrice: 200,
      sellPrice: 250,
      createdAt: t,
      updatedAt: t,
    );
    products.insert(product);
    productId = product.id;

    final Account cash = Account(
      id: newId(),
      name: '现金',
      type: AccountType.cash,
      createdAt: t,
      updatedAt: t,
    );
    accounts.insert(cash);
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

  /// 单据 id（按单号反查 —— 各 `*Saved` 只带单号不带 id）
  String idOf(String docNo) => db.raw
      .select('SELECT id FROM documents WHERE doc_no = ?', <Object?>[docNo])
      .first['id']! as String;

  /// 卖 36 瓶（3 箱 × ¥250/箱 = ¥750）给客户甲，全款。
  ///
  /// 对应裁定 3 的舍入例证：派生单价 round(75000/36) = 2083 分 ——
  /// 「派生单价 × 瓶数」会有舍入差，累计比例法没有（见下）。
  String sell3Boxes() {
    final SaleSaved saved = sales.create(
      SaleDraft(
        partyId: customerId,
        partyName: '客户甲',
        date: '2026-10-04',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: productId,
            productName: '蒙牛纯牛奶',
            quantity: '3',
            unitPrice: '250',
            entryUnit: '箱',
            baseUnit: '瓶',
            packageUnit: '箱',
            packageSize: 12,
          ),
        ],
        payments: <SalePaymentDraft>[
          SalePaymentDraft(accountId: accountId, accountName: '现金', amount: '750'),
        ],
      ),
    );
    return idOf(saved.docNo);
  }

  /// 退货行（**箱录单**：原量 36 瓶、金额 75000 分、entry_unit = 箱）。
  /// 按裁定 3「沿用原单 entry_unit」⇒ 本次数量按箱填（'1' = 12 瓶）。
  ReturnLineDraft boxLine({
    String? qty,
    String? amount,
    int priorReturnedQuantity = 0,
    int priorReturnedAmountCents = 0,
  }) => ReturnLineDraft(
    productId: productId,
    productName: '蒙牛纯牛奶',
    quantity: qty ?? '1',
    amount: amount ?? '250.00',
    entryUnit: '箱',
    baseUnit: '瓶',
    packageUnit: '箱',
    packageSize: 12,
    originalQuantity: 36,
    originalAmountCents: 75000,
    priorReturnedQuantity: priorReturnedQuantity,
    priorReturnedAmountCents: priorReturnedAmountCents,
  );

  /// 退货行（**瓶录单**：原量 36 瓶、entry_unit = 瓶）—— 按瓶退。
  ReturnLineDraft bottleLine({
    String? qty,
    String? amount,
    int priorReturnedQuantity = 0,
    int priorReturnedAmountCents = 0,
  }) => ReturnLineDraft(
    productId: productId,
    productName: '蒙牛纯牛奶',
    quantity: qty ?? '3',
    amount: amount ?? '62.50',
    entryUnit: '瓶',
    baseUnit: '瓶',
    originalQuantity: 36,
    originalAmountCents: 75000,
    priorReturnedQuantity: priorReturnedQuantity,
    priorReturnedAmountCents: priorReturnedAmountCents,
  );

  int bookQuantity() => stock
      .ofProduct(productId)
      .fold(0, (int sum, StockLedger e) => sum + e.quantity);

  // ------------------------------------------------------------ quotasFor

  group('quotasFor（可退额度 —— 表单预填与超额前置拦截的依据）', () {
    test('原量 / 已退 / 可退 三段齐', () {
      final String refDocId = sell3Boxes();

      final Map<String, ReturnQuota> quotas = returns.quotasFor(
        refDocId: refDocId,
        returnType: DocType.saleReturn,
      );
      final ReturnQuota quota = quotas[productId]!;
      expect(quota.originalQuantity, 36);
      expect(quota.originalAmountCents, 75000);
      expect(quota.returnedQuantity, 0);
      expect(quota.returnedAmountCents, 0);
      expect(quota.remainingQuantity, 36);
      expect(quota.productName, '蒙牛纯牛奶');
    });

    test('原单不存在 ⇒ 空 map（UI 显示「原单不存在」而不是崩）', () {
      expect(
        returns.quotasFor(
          refDocId: 'no-such-doc',
          returnType: DocType.saleReturn,
        ),
        isEmpty,
      );
    });

    test('超额报错按**最小单位**缀单位（不能缀录入单位 —— 真机踩过「原量 120 箱」）', () {
      // 箱录单：原量 36 瓶、按箱填。填 4 箱 = 48 瓶 > 36 ⇒ 超额。
      // 数字必须缀「瓶」；36 整除 12 ⇒ 附「= 3 箱」换算。
      final Map<ReturnLineField, String> errors = boxLine(qty: '4').validate();
      expect(
        errors[ReturnLineField.quantity],
        '超过可退数量：原量 36 瓶、已退 0，最多可退 36 瓶（= 3 箱）',
      );

      // 瓶录单：录入单位 = 基本单位 ⇒ 不附换算。
      final Map<ReturnLineField, String> errors2 = bottleLine(
        qty: '40',
      ).validate();
      expect(
        errors2[ReturnLineField.quantity],
        '超过可退数量：原量 36 瓶、已退 0，最多可退 36 瓶',
      );
    });
  });

  // ------------------------------------------------------------ 累计比例法

  group('累计比例法默认金额（裁定 3 —— 派生单价乘数量有舍入差）', () {
    test('瓶录单退 3 瓶 ⇒ ¥62.50（派生单价法会算出 62.49）', () {
      // 派生单价 round(75000/36) = 2083 分；3 × 2083 = 6249 ❌
      // 累计比例法 round(75000 × 3 / 36) = 6250 ✅
      final ReturnLineDraft draft = bottleLine(qty: '3');
      expect(draft.defaultAmountCents, 6250);
    });

    test('箱录单退 1 箱 ⇒ ¥250.00', () {
      expect(boxLine(qty: '1').defaultAmountCents, 25000);
    });

    test('分多次退，之和精确等于应退总额', () {
      // 36 瓶全退，每次退 3 瓶：12 次默认金额之和 = 75000 分（差 1 分都不行）
      int priorQty = 0;
      int priorAmount = 0;
      int total = 0;
      for (int i = 0; i < 12; i++) {
        final ReturnLineDraft draft = bottleLine(
          qty: '3',
          priorReturnedQuantity: priorQty,
          priorReturnedAmountCents: priorAmount,
        );
        final int amount = draft.defaultAmountCents!;
        expect(amount, greaterThan(0), reason: '第 ${i + 1} 次');
        total += amount;
        priorQty += 3;
        priorAmount += amount;
      }
      expect(total, 75000, reason: '多次退货之和精确等于应退总额');
      expect(priorQty, 36);
    });
  });

  // ------------------------------------------------------------ 端到端

  group('create（sale_return —— 端到端）', () {
    test('退 1 箱、挂账冲减 ⇒ 库存回退 / 往来减少 / 无资金流水', () {
      final String refDocId = sell3Boxes();

      final ReturnSaved saved = returns.create(
        ReturnDraft(
          refDocId: refDocId,
          originalDocType: DocType.sale,
          partyId: customerId,
          partyName: '客户甲',
          lines: <ReturnLineDraft>[boxLine(qty: '1', amount: '250.00')],
          remark: '客户反馈口味不对',
        ),
      );

      expect(saved.returnType, DocType.saleReturn);
      expect(saved.totalCents, 25000);
      expect(saved.refundedCents, 0, reason: '挂账冲减 ⇒ 没有立即退款');
      expect(saved.originalDocNo, isNotEmpty);

      // 库存方向：销售是**出库**（−36），退货是**入库**（+12）⇒ 账面 −24
      //（成本按 R-11 比例回退，引擎已测，这里只验方向）
      expect(bookQuantity(), -(36 - 12));
      // 往来冲减：客户欠款减少 250.00（正 = 对方欠我）
      expect(partyLedger.ofParty(customerId).last.amount, -25000);
      // 挂账冲减 ⇒ 没有新的资金流水（余额停在收款时的 75000）
      expect(money.balanceOf(accountId), 75000);
    });

    test('立即退款 ⇒ 生成 payment 单（资金流出）', () {
      final String refDocId = sell3Boxes();

      final ReturnSaved saved = returns.create(
        ReturnDraft(
          refDocId: refDocId,
          originalDocType: DocType.sale,
          partyId: customerId,
          partyName: '客户甲',
          lines: <ReturnLineDraft>[boxLine(qty: '1', amount: '250.00')],
          refunds: <ReturnRefundDraft>[
            ReturnRefundDraft(accountId: accountId, accountName: '现金', amount: '250.00'),
          ],
        ),
      );

      expect(saved.refundedCents, 25000);
      // 余额 = 收款 750.00 − 退款 250.00
      expect(money.balanceOf(accountId), 75000 - 25000);
    });

    test('退款超合计 ⇒ 封顶（找零口径，裁定 5）', () {
      final String refDocId = sell3Boxes();

      final ReturnSaved saved = returns.create(
        ReturnDraft(
          refDocId: refDocId,
          originalDocType: DocType.sale,
          partyId: customerId,
          partyName: '客户甲',
          lines: <ReturnLineDraft>[boxLine(qty: '1', amount: '250.00')],
          refunds: <ReturnRefundDraft>[
            ReturnRefundDraft(accountId: accountId, accountName: '现金', amount: '300'),
          ],
        ),
      );

      expect(saved.totalCents, 25000);
      expect(saved.refundedCents, 25000, reason: '填了 300，落库封顶到 250.00');
    });
  });

  group('create（purchase_return / 拒收）', () {
    test('采购退货 ⇒ 库存出库、应付减少、立即收款生成 receipt', () {
      // 进 10 瓶 × ¥2.00（全款）
      final PurchaseSaved bought = purchases.create(
        PurchaseDraft(
          partyId: supplierId,
          partyName: '供应商乙',
          date: '2026-10-04',
          lines: <PurchaseLineDraft>[
            PurchaseLineDraft.fromProduct(
              products.findById(productId)!,
              quantity: '10',
            ),
          ],
          payments: <PurchasePaymentDraft>[
            PurchasePaymentDraft(accountId: accountId, accountName: '现金', amount: '20'),
          ],
        ),
      );

      // 采购行没有 entry_unit（按最小单位录的）⇒ 退货行 entryUnit = null
      final ReturnSaved saved = returns.create(
        ReturnDraft(
          refDocId: idOf(bought.docNo),
          originalDocType: DocType.purchase,
          partyId: supplierId,
          partyName: '供应商乙',
          lines: <ReturnLineDraft>[
            ReturnLineDraft(
              productId: productId,
              productName: '蒙牛纯牛奶',
              quantity: '4',
              amount: '8.00',
              baseUnit: '瓶',
              originalQuantity: 10,
              originalAmountCents: 2000,
            ),
          ],
          refunds: <ReturnRefundDraft>[
            ReturnRefundDraft(accountId: accountId, accountName: '现金', amount: '8.00'),
          ],
        ),
      );

      expect(saved.returnType, DocType.purchaseReturn);
      expect(bookQuantity(), 10 - 4, reason: '退 4 ⇒ 库存出库');
      // 往来口径（采购侧）：负 = 我欠对方。进货 −20.00（欠增加），
      // 退货单 −8.00（欠**减少** —— 绝对值从 20 变 8），引擎 RULE-008 同款符号
      expect(partyLedger.ofParty(supplierId).last.amount, -800);
      // 资金：进货付款 −20.00、供应商退款 +8.00 ⇒ 余额 −12.00
      expect(money.balanceOf(accountId), -(2000 - 800));
    });

    test('拒收收口（裁定 2）：送货未签收 ⇒ sale_return 后原单变 cancelled', () {
      // 送 12 瓶给客户甲（RULE-003 ⇒ 待签收，库存 −12）
      final DeliverySaved signed = deliveries.create(
        DeliveryDraft(
          partyId: customerId,
          partyName: '客户甲',
          date: '2026-10-04',
          lines: <DeliveryLineDraft>[
            DeliveryLineDraft.fromProduct(
              products.findById(productId)!,
              quantity: '12',
            ),
          ],
        ),
      );
      final String deliveryId = idOf(signed.docNo);
      expect(documents.findById(deliveryId)!.status, DocStatus.inTransit);

      returns.create(
        ReturnDraft(
          refDocId: deliveryId,
          originalDocType: DocType.delivery,
          partyId: customerId,
          partyName: '客户甲',
          lines: <ReturnLineDraft>[
            ReturnLineDraft(
              productId: productId,
              productName: '蒙牛纯牛奶',
              quantity: '12',
              amount: '30.00',
              baseUnit: '瓶',
              originalQuantity: 12,
              originalAmountCents: 3000,
            ),
          ],
        ),
      );

      // 拒收收口：原送货单 → cancelled（否则在途视图永远算它）
      expect(documents.findById(deliveryId)!.status, DocStatus.cancelled);
      // 库存：送货出库 −12，拒收退回 +12 ⇒ 回到发货前的 0
      //（此前断言「回到送货后的 −12」是符号搞反 —— 拒收的货是**回来**了）
      expect(bookQuantity(), 0);
    });
  });

  group('create（校验失败 ⇒ ReturnDraftInvalid）', () {
    test('超额数量：校验层就拦（文案带可退上限），不落库不炸引擎', () {
      final String refDocId = sell3Boxes();

      expect(
        () => returns.create(
          ReturnDraft(
            refDocId: refDocId,
            originalDocType: DocType.sale,
            partyId: customerId,
            partyName: '客户甲',
            lines: <ReturnLineDraft>[boxLine(qty: '4', amount: '1000.00')],
          ),
        ),
        throwsA(
          isA<ReturnDraftInvalid>().having(
            (ReturnDraftInvalid e) => e.lineErrors.first[ReturnLineField.quantity],
            'quantity 错误文案',
            contains('最多可退 36'),
          ),
        ),
      );
    });

    test('金额超余量：拦', () {
      expect(
        () => returns.create(
          ReturnDraft(
            refDocId: sell3Boxes(),
            originalDocType: DocType.sale,
            partyId: customerId,
            partyName: '客户甲',
            lines: <ReturnLineDraft>[boxLine(qty: '1', amount: '999.00')],
          ),
        ),
        throwsA(isA<ReturnDraftInvalid>()),
      );
    });
  });
}
