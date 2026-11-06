// 毛利趋势的**口径**（N-a 裁定甲 ①甲 ②甲，2026-11-06；用户 `docs/reply.md` §P2·3）。
//
// 裁定原文的四条：
//   · 按 `business_day` 聚合；
//   · 退货发生当天把**销售额和对应成本都记负数**；
//   · 按**实际出库成本**计算毛利；
//   · **盘亏成本也纳入成本口径**。
// 外加一条硬要求：**收入 / 销售成本 / 盘点损失 / 退货调整必须是可解释的分项**，
// 不能混成一条没有区分的流水 —— 否则图能算出一个数，却说不清怎么来的。
//
// ## 本文件守的三个坑（每一个都会静默算错账）
//
// 1. **整表求和 `SUM(total_cost)` 是错的** —— 进货分录也有 `total_cost`（成本的形成），
//    整表求和会把进货成本算进销售成本，毛利变成大负数。
// 2. **`quantity < 0` 也不够** —— `purchase_return` 的流水同样是负数（货离店），
//    但它是**采购的逆操作**，不是销售成本。必须**按 `doc_type` 分派**。
// 3. **盘盈不是成本** —— `docs/data_model.md` §3.3「盘盈同入库」，它是成本的**形成**；
//    只有**盘亏**进成本（`docs/rules.md` L533）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  group('QueryDao.dailyGrossMargin（N-a 口径）', () {
    late Db db;
    late QueryDao queries;
    late PurchaseService purchases;
    late SaleService sales;
    late DeliveryService deliveries;
    late ReturnService returns;
    late StocktakeService stocktakes;

    late String productId;
    late String accountId;
    late String supplierId;
    late String customerId;

    setUp(() {
      resetClock();
      db = newMemoryDb();
      final RuleEngine engine = RuleEngine(db);
      queries = QueryDao(db);
      purchases = PurchaseService(engine: engine, queries: queries);
      sales = SaleService(engine: engine, queries: queries);
      deliveries = DeliveryService(engine: engine, queries: queries);
      returns = ReturnService(engine: engine, queries: queries);
      stocktakes = StocktakeService(engine: engine, queries: queries);

      final int t = now();
      // 进价 6 元 / 售价 10 元 —— 单件毛利 4 元，好口算。
      ProductDao(db).insert(
        Product(
          id: newId(),
          code: 'P001',
          name: '纯牛奶',
          unit: '瓶',
          costPrice: 600,
          sellPrice: 1000,
          createdAt: t,
          updatedAt: t,
        ),
      );
      productId = db.raw
          .select("SELECT id FROM products WHERE code = 'P001'")
          .first['id']! as String;

      AccountDao(db).insert(
        Account(
          id: newId(),
          name: '现金',
          type: AccountType.cash,
          createdAt: t,
          updatedAt: t,
        ),
      );
      accountId = db.raw
          .select("SELECT id FROM accounts WHERE name = '现金'")
          .first['id']! as String;

      PartyDao(db).insert(
        Party(
          id: newId(),
          name: '王老板',
          roles: const <PartyRole>[PartyRole.supplier],
          createdAt: t,
          updatedAt: t,
        ),
      );
      supplierId = db.raw
          .select("SELECT id FROM parties WHERE name = '王老板'")
          .first['id']! as String;

      PartyDao(db).insert(
        Party(
          id: newId(),
          name: '客户甲',
          roles: const <PartyRole>[PartyRole.customer],
          createdAt: t,
          updatedAt: t,
        ),
      );
      customerId = db.raw
          .select("SELECT id FROM parties WHERE name = '客户甲'")
          .first['id']! as String;
    });

    tearDown(() => db.close());

    int dayOf(String date) =>
        businessDayOf(DateTime.parse('$date 12:00:00').millisecondsSinceEpoch);

    String idOf(String docNo) =>
        db.raw
            .select('SELECT id FROM documents WHERE doc_no = ?', <Object?>[docNo])
            .first['id']! as String;

    /// 进货 [qty] 件，单价 6 元，全款现结。
    String stockIn(String date, int qty) => idOf(
      purchases.create(
        PurchaseDraft(
          partyId: supplierId,
          partyName: '王老板',
          date: date,
          lines: <PurchaseLineDraft>[
            PurchaseLineDraft(
              productId: productId,
              productName: '纯牛奶',
              quantity: '$qty',
              unitPrice: '6',
            ),
          ],
          payments: <PurchasePaymentDraft>[
            PurchasePaymentDraft(accountId: accountId, amount: '${qty * 6}'),
          ],
        ),
      ).docNo,
    );

    /// 卖 [qty] 件，单价 10 元，全款现结。
    String sell(String date, int qty) => idOf(
      sales.create(
        SaleDraft(
          partyId: customerId,
          partyName: '客户甲',
          date: date,
          lines: <SaleLineDraft>[
            SaleLineDraft(
              productId: productId,
              productName: '纯牛奶',
              quantity: '$qty',
              unitPrice: '10',
            ),
          ],
          payments: <SalePaymentDraft>[
            SalePaymentDraft(accountId: accountId, amount: '${qty * 10}'),
          ],
        ),
      ).docNo,
    );

    String deliver(String date, int qty) => idOf(
      deliveries.create(
        DeliveryDraft(
          partyId: customerId,
          partyName: '客户甲',
          date: date,
          lines: <DeliveryLineDraft>[
            DeliveryLineDraft(
              productId: productId,
              productName: '纯牛奶',
              quantity: '$qty',
              unitPrice: '10',
            ),
          ],
        ),
      ).docNo,
    );

    /// 退货的 `business_day` 由 `now` 决定（草稿没有 date 字段）⇒ 要落某天必须显式传。
    ReturnSaved refund(
      String refDocId,
      DocType type,
      String date,
      int qty,
    ) => returns.create(
      now: DateTime.parse('$date 12:00:00').millisecondsSinceEpoch,
      ReturnDraft(
        refDocId: refDocId,
        originalDocType: type,
        partyId: type == DocType.purchase ? supplierId : customerId,
        partyName: type == DocType.purchase ? '王老板' : '客户甲',
        lines: <ReturnLineDraft>[
          ReturnLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '$qty',
            amount: '${qty * 10}.00',
            originalQuantity: 100,
            originalAmountCents: 100000,
          ),
        ],
      ),
    );

    /// 盘点：填的是**盘点后实际数量**。
    void count(String date, int actualQty) => stocktakes.create(
      StocktakeDraft(
        lines: <StocktakeLineDraft>[
          StocktakeLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '$actualQty',
          ),
        ],
      ),
      now: DateTime.parse('$date 12:00:00').millisecondsSinceEpoch,
    );

    List<GrossMarginDay> margin(String from, String to) =>
        queries.dailyGrossMargin(
          fromDay: dayOf(from),
          toDay: dayOf(to),
        );

    // ---------------------------------------------------------- 基本口径

    test('进货的成本**不进**毛利：卖 4 件 ⇒ 成本只有出库那 4 件', () {
      stockIn('2026-11-01', 10); // 进货成本 ¥60（10 × 6）
      sell('2026-11-02', 4); // 卖 4 件 ¥40

      final List<GrossMarginDay> rows = margin('2026-11-01', '2026-11-02');

      // 进货那天**不该出现在结果里** —— 它没有任何毛利相关的分量。
      expect(
        rows.map((GrossMarginDay r) => r.day),
        isNot(contains(dayOf('2026-11-01'))),
        reason: '进货是成本的**形成**，不是结转 ⇒ 稀疏结果里没有这一天',
      );
      expect(
        rows.fold(0, (int s, GrossMarginDay r) => s + r.saleCostCents),
        2400,
        reason:
            '整个窗口的销售成本**只有出库那 4 件**。进货分录也有 total_cost，'
            '整表 SUM(total_cost) 会把 ¥60 进货成本也算进来 ⇒ 全窗口成本 8400、'
            '毛利 −4400。这条断言就是挡这个的。',
      );

      // 卖货那天：收入 4000，成本 = 时点加权均价 600 × 4 = 2400。
      final GrossMarginDay d2 = rows.firstWhere(
        (GrossMarginDay r) => r.day == dayOf('2026-11-02'),
      );
      expect(d2.revenueCents, 4000);
      expect(d2.saleCostCents, 2400);
      expect(d2.stocktakeLossCents, 0);
      expect(d2.returnCostAdjustCents, 0);
      expect(d2.grossMarginCents, 1600, reason: '4 件 × 单件毛利 4 元');
    });

    test('`quantity < 0` 的口径**不够**：采购退货不进销售成本', () {
      stockIn('2026-11-01', 10);
      // 采购退 2 件 —— 它的 stock_ledger.quantity 与 total_cost **都是负数**
      // （货离店），和卖货出库**同号**。按符号分口径会把它当成销售成本。
      refund(idOf(
        purchases.create(
          PurchaseDraft(
            partyId: supplierId,
            partyName: '王老板',
            date: '2026-11-01',
            lines: <PurchaseLineDraft>[
              PurchaseLineDraft(
                productId: productId,
                productName: '纯牛奶',
                quantity: '10',
                unitPrice: '6',
              ),
            ],
            payments: <PurchasePaymentDraft>[
              PurchasePaymentDraft(accountId: accountId, amount: '60'),
            ],
          ),
        ).docNo,
      ), DocType.purchase, '2026-11-03', 2);
      // 同一天再卖 1 件，让这一天出现在结果里。采购退 2 件后库存 8、
      // 成本余值 4800 ⇒ 卖 1 件结转 600。若把采购退货也算成销售成本 ⇒ 1800。
      sell('2026-11-03', 1);

      final List<GrossMarginDay> rows = margin('2026-11-03', '2026-11-03');
      final GrossMarginDay d = rows.firstWhere(
        (GrossMarginDay r) => r.day == dayOf('2026-11-03'),
      );
      expect(
        d.saleCostCents,
        600,
        reason: '只有卖出去那 1 件结转成本（余值 10800 / 库存 18 = 600）。'
            '采购退货是**采购的逆操作**、不是销售成本；算进来 ⇒ 成本 1800、'
            '毛利凭空少 ¥12，且用户完全无法解释。',
      );
      expect(d.revenueCents, 1000);
      expect(d.grossMarginCents, 400);
    });

    // ---------------------------------------------------------- 盘点

    test('盘亏**进成本**（裁定：盘亏成本纳入成本口径）', () {
      stockIn('2026-11-01', 10);
      sell('2026-11-02', 4); // 库存 6，成本余值 3600
      count('2026-11-03', 3); // 盘亏 3 ⇒ round(3600 × −3 / 6) = −1800

      final GrossMarginDay d = margin('2026-11-03', '2026-11-03').firstWhere(
        (GrossMarginDay r) => r.day == dayOf('2026-11-03'),
      );
      expect(d.revenueCents, 0, reason: '盘点单 total_amount = 0，不是收入');
      expect(d.saleCostCents, 0, reason: '盘亏走**盘点损失**分项，不混进销售成本');
      expect(d.stocktakeLossCents, 1800);
      expect(d.grossMarginCents, -1800, reason: '丢了 3 件货 = 亏了 3 件的成本');
    });

    test('盘盈**不是成本**（`data_model.md` §3.3「盘盈同入库」）', () {
      stockIn('2026-11-01', 10);
      sell('2026-11-02', 4); // 库存 6
      count('2026-11-03', 9); // 盘盈 3 ⇒ total_cost = +1800（成本的形成）

      final List<GrossMarginDay> rows = margin('2026-11-03', '2026-11-03');
      expect(
        rows,
        isEmpty,
        reason: '盘盈是成本的**形成**（同入库），不是结转 ⇒ 这一天没有任何毛利分量。'
            '把它当负成本 ⇒ 白捡 ¥18 毛利，而货是凭空多出来的。',
      );
    });

    // ---------------------------------------------------------- 退货（裁定 ②甲）

    test('退货当天：销售额记负、成本也记负（回吐）', () {
      stockIn('2026-11-01', 10);
      final String saleId = sell('2026-11-02', 4); // ¥40 / 成本 2400
      refund(saleId, DocType.sale, '2026-11-05', 1); // 退 1 件 ¥10

      final List<GrossMarginDay> rows = margin('2026-11-02', '2026-11-05');

      // 原单那天**不被改写**（裁定乙「冲减原单那天」已否决）
      final GrossMarginDay d2 = rows.firstWhere(
        (GrossMarginDay r) => r.day == dayOf('2026-11-02'),
      );
      expect(d2.revenueCents, 4000, reason: '历史不能被改写');
      expect(d2.saleCostCents, 2400);

      // 退货落在**退货那天**
      final GrossMarginDay d5 = rows.firstWhere(
        (GrossMarginDay r) => r.day == dayOf('2026-11-05'),
      );
      expect(d5.revenueCents, -1000, reason: '销售额记负');
      expect(
        d5.returnCostAdjustCents,
        -600,
        reason: '成本记负（回吐）：按原单比例 2400 × 1/4 = 600，取负',
      );
      expect(d5.grossMarginCents, -400, reason: '少卖一件 = 少赚 4 元');

      // 恒等式：净卖 3 件 ⇒ 收入 3000 / 成本 1800 / 毛利 1200
      final int total = rows.fold(
        0,
        (int s, GrossMarginDay r) => s + r.grossMarginCents,
      );
      expect(total, 1200, reason: '3 件 × 4 元 —— 与「按原单比例精确回退」逐字同口径');
    });

    test('拒收：原送货单已作废 ⇒ 收入与成本**都不冲减**（不分叉口径）', () {
      stockIn('2026-11-01', 10);
      final String deliveryId = deliver('2026-11-02', 4);
      refund(deliveryId, DocType.delivery, '2026-11-03', 4); // 整单拒收

      final List<GrossMarginDay> rows = margin('2026-11-02', '2026-11-03');
      final int total = rows.fold(
        0,
        (int s, GrossMarginDay r) => s + r.grossMarginCents,
      );
      expect(
        total,
        0,
        reason: '拒收 = 这单生意没做成。收入腿已因原单 cancelled 不冲减'
            '（`dailyRevenue` 的既有裁定），成本腿**必须同判据** —— '
            '否则收入没减却回吐了成本，白赚 24 元。',
      );
      for (final GrossMarginDay r in rows) {
        expect(r.returnCostAdjustCents, 0, reason: '拒收的退货不记成本调整');
      }
    });

    test('作废的销售单：收入与成本都不计', () {
      stockIn('2026-11-01', 10);
      final String saleId = sell('2026-11-02', 4);
      db.raw.execute(
        "UPDATE documents SET status = 'cancelled' WHERE id = ?",
        <Object?>[saleId],
      );

      final List<GrossMarginDay> rows = margin('2026-11-02', '2026-11-02');
      expect(
        rows,
        isEmpty,
        reason: '作废单的流水也要排除 —— 否则只剩成本没有收入。'
            '排除后这一天没有任何分量 ⇒ 稀疏结果里没有它。',
      );
    });

    // ---------------------------------------------------------- 可解释性

    test('恒等式：毛利 = 收入 − 销售成本 − 盘点损失 − 退货调整', () {
      stockIn('2026-11-01', 20);
      sell('2026-11-02', 10);
      final String saleId = sell('2026-11-03', 6);
      refund(saleId, DocType.sale, '2026-11-04', 2);
      count('2026-11-05', 8); // 盘亏

      for (final GrossMarginDay r in margin('2026-11-01', '2026-11-05')) {
        expect(
          r.grossMarginCents,
          r.revenueCents -
              r.saleCostCents -
              r.stocktakeLossCents -
              r.returnCostAdjustCents,
          reason: '用户点某一天时要能解释这个数字怎么来的'
              '（用户 `reply.md` §P2·3：不能混成一条没有区分的流水）',
        );
      }
    });

    test('稀疏 + 窗口：只返回有数据的天，窗口外忽略', () {
      stockIn('2026-11-01', 10);
      sell('2026-11-05', 1);

      final List<GrossMarginDay> rows = margin('2026-11-01', '2026-11-10');
      expect(rows.map((GrossMarginDay r) => r.day).toList(), <int>[
        dayOf('2026-11-05'),
      ], reason: '补零交给纯函数，查询层给稀疏（与 dailyRevenue 一致）。'
          '进货那天没有任何毛利分量 ⇒ 也不出现（与「进货不进成本」同源）。');

      expect(margin('2026-11-06', '2026-11-10'), isEmpty);
      expect(
        queries.dailyGrossMargin(fromDay: 10, toDay: 1),
        isEmpty,
        reason: 'from > to ⇒ 空列表，不抛',
      );
    });

    test('送货（在途未签收）算收入、也结转成本', () {
      stockIn('2026-11-01', 10);
      deliver('2026-11-02', 3); // 不签收

      final GrossMarginDay d = margin('2026-11-02', '2026-11-02').firstWhere(
        (GrossMarginDay r) => r.day == dayOf('2026-11-02'),
      );
      expect(d.revenueCents, 3000, reason: '在途计入营收（2026-10-30 裁定甲）');
      expect(d.saleCostCents, 1800, reason: '货已离店，成本同时结转');
      expect(d.grossMarginCents, 1200);
    });

    test('负库存出库：成本按最近入库均价，毛利仍自洽', () {
      // 不进货直接卖 ⇒ 负库存（纪律：允许，UI 红字告警）
      sell('2026-11-02', 2);
      final GrossMarginDay d = margin('2026-11-02', '2026-11-02').firstWhere(
        (GrossMarginDay r) => r.day == dayOf('2026-11-02'),
      );
      expect(d.revenueCents, 2000);
      expect(
        d.saleCostCents,
        0,
        reason: '无入库历史 ⇒ `outboundCost` 记 0（`CostPolicy` 已裁）。'
            '毛利会虚高，但**这是成本口径的既有裁定，不是毛利的锅**。',
      );
      expect(d.grossMarginCents, 2000);
    });
  });
}