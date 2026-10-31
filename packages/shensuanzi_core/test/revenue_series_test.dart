// 经营图表的**序列构建**与**聚合口径**（提案 54 §二 / 55 §三）。
//
// 这一层最容易出的错不是「算错」，而是**画错**：
//   · 不补零 ⇒ 三天没卖被画成连续趋势；
//   · 用 `day ~/ 7` 当周 ⇒ 边界既不是周一也不是周日，用户对不上日历；
//   · 拒收的退货再减一次 ⇒ 双重冲减（实测虚减 3.9%）。
//
// 所以纯函数和口径各测一组。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  // ============================================================ 纯函数

  group('buildRevenueSeries（纯函数）', () {
    /// 2026-10-26 是**周一**（用来验「自然周从周一起」）。
    int dayOf(int y, int m, int d) =>
        businessDayOf(DateTime(y, m, d, 12).millisecondsSinceEpoch);

    test('补零：没有数据的那天也要出现在序列里', () {
      final int d1 = dayOf(2026, 10, 1);
      final int d4 = dayOf(2026, 10, 4);
      final List<RevenuePoint> points = buildRevenueSeries(
        rows: <RevenueDay>[
          RevenueDay(day: d1, saleCents: 1000),
          RevenueDay(day: d4, saleCents: 2000),
        ],
        fromDay: d1,
        toDay: d4,
      );

      expect(points.length, 4, reason: '10-01 到 10-04 是 4 天，一天都不能少');
      expect(
        points.map((RevenuePoint p) => p.netCents).toList(),
        <int>[1000, 0, 0, 2000],
        reason: '中间两天必须是 0 —— 不补零会画成「连续卖了四天」',
      );
    });

    test('自然周：周一为一周的第一天（不是每 7 天切一刀）', () {
      final int monday = dayOf(2026, 10, 26);
      final int sunday = dayOf(2026, 11, 1);
      expect(dayToDate(monday).weekday, DateTime.monday, reason: '夹具前提');

      expect(weekStartDay(monday), monday);
      expect(
        weekStartDay(sunday),
        monday,
        reason: '周日属于**上一周**（周一起算），不能跟下周一归到一起',
      );
      expect(
        weekStartDay(dayOf(2026, 10, 25)),
        monday - 7,
        reason: '10-25 是周日，属于 10-19 那一周',
      );

      final List<RevenuePoint> weeks = buildRevenueSeries(
        rows: <RevenueDay>[
          RevenueDay(day: monday, saleCents: 1000),
          RevenueDay(day: monday + 6, saleCents: 2000), // 周日
          RevenueDay(day: monday + 7, saleCents: 4000), // 下周一
        ],
        fromDay: monday,
        toDay: monday + 7,
        bucket: RevenueBucket.week,
      );
      expect(weeks.length, 2);
      expect(weeks[0].startDay, monday);
      expect(weeks[0].netCents, 3000, reason: '周一到周日要合成一个桶');
      expect(weeks[1].netCents, 4000);
    });

    test('自然月：跨月切成两个桶', () {
      final int end = dayOf(2026, 10, 31);
      final int start = dayOf(2026, 11, 1);
      expect(
        monthStartDay(end),
        isNot(monthStartDay(start)),
        reason: '10-31 和 11-01 必须是两个月',
      );

      final List<RevenuePoint> months = buildRevenueSeries(
        rows: <RevenueDay>[
          RevenueDay(day: end, saleCents: 1000),
          RevenueDay(day: start, saleCents: 2000),
        ],
        fromDay: end,
        toDay: start,
        bucket: RevenueBucket.month,
      );
      expect(months.length, 2);
      expect(
        months.first.startDay,
        end,
        reason:
            '窗口从 10-31 开始 ⇒ 第一个桶的起点要**夹到窗口内**，'
            '否则标签会写「10 月」而实际只统计了一天',
      );
      expect(months.first.endDay, end);
      expect(months.last.startDay, start);
    });

    test('窗口不从周一开始时，第一个周桶的起点夹到窗口内', () {
      final int wednesday = dayOf(2026, 10, 28); // 周三
      expect(dayToDate(wednesday).weekday, DateTime.wednesday);

      final List<RevenuePoint> weeks = buildRevenueSeries(
        rows: <RevenueDay>[RevenueDay(day: wednesday, saleCents: 500)],
        fromDay: wednesday,
        toDay: wednesday + 2,
        bucket: RevenueBucket.week,
      );
      expect(
        weeks.single.startDay,
        wednesday,
        reason: '标 10/26（周一）会让用户以为这周从周一开始统计 —— 其实只有周三起',
      );
      expect(weeks.single.endDay, wednesday + 2);
    });

    test('窗口外的数据被忽略；from > to ⇒ 空列表', () {
      final int d = dayOf(2026, 10, 10);
      final List<RevenuePoint> points = buildRevenueSeries(
        rows: <RevenueDay>[
          RevenueDay(day: d - 1, saleCents: 999),
          RevenueDay(day: d, saleCents: 100),
          RevenueDay(day: d + 1, saleCents: 999),
        ],
        fromDay: d,
        toDay: d,
      );
      expect(points.length, 1);
      expect(points.single.netCents, 100);

      expect(
        buildRevenueSeries(rows: const [], fromDay: d, toDay: d - 1),
        isEmpty,
      );
    });

    test('同一天出现多次 ⇒ 累加（查询层不该给重复，但别指望）', () {
      final int d = dayOf(2026, 10, 12);
      final List<RevenuePoint> points = buildRevenueSeries(
        rows: <RevenueDay>[
          RevenueDay(day: d, saleCents: 100, documentCount: 1),
          RevenueDay(day: d, deliveryCents: 200, documentCount: 1),
        ],
        fromDay: d,
        toDay: d,
      );
      expect(points.single.netCents, 300);
      expect(points.single.documentCount, 2);
    });
  });

  // ============================================================ 聚合口径

  group('QueryDao.dailyRevenue（口径）', () {
    late Db db;
    late SaleService sales;
    late DeliveryService deliveries;
    late ReturnService returns;
    late QueryDao queries;

    late String productId;
    late String accountId;
    late String customerId;

    setUp(() {
      resetClock();
      db = newMemoryDb();
      final RuleEngine engine = RuleEngine(db);
      queries = QueryDao(db);
      sales = SaleService(engine: engine, queries: queries);
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
    });

    tearDown(() => db.close());

    String idOf(String docNo) =>
        db.raw.select('SELECT id FROM documents WHERE doc_no = ?', <Object?>[
              docNo,
            ]).first['id']!
            as String;

    int dayOf(String date) =>
        businessDayOf(DateTime.parse('$date 12:00:00').millisecondsSinceEpoch);

    String sell(String date, int qty) {
      final SaleSaved saved = sales.create(
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
            SalePaymentDraft(
              accountId: accountId,
              accountName: '现金',
              amount: '${qty * 10}',
            ),
          ],
        ),
      );
      return idOf(saved.docNo);
    }

    String deliver(String date, int qty) {
      final DeliverySaved saved = deliveries.create(
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
      );
      return idOf(saved.docNo);
    }

    /// 退货单的 `occurred_at` 由 `now` 决定（草稿里没有 date 字段）——
    /// 要把它落在指定那天，必须显式传 `now`。
    ReturnSaved refund(String refDocId, DocType type, String date, int qty) =>
        returns.create(
          now: DateTime.parse('$date 12:00:00').millisecondsSinceEpoch,
          ReturnDraft(
            refDocId: refDocId,
            originalDocType: type,
            partyId: customerId,
            partyName: '客户甲',
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

    test('销售 + 送货 − 有效退货：三天各算各的', () {
      sell('2026-10-04', 3); // ¥30
      deliver('2026-10-05', 2); // ¥20
      final String saleId = sell('2026-10-04', 1); // 再卖 ¥10
      refund(saleId, DocType.sale, '2026-10-06', 1); // 退 ¥10

      final List<RevenueDay> rows = queries.dailyRevenue(
        fromDay: dayOf('2026-10-04'),
        toDay: dayOf('2026-10-06'),
      );
      expect(rows.length, 3);

      expect(rows[0].saleCents, 4000, reason: '同一天两笔销售要合并');
      expect(rows[0].deliveryCents, 0);
      expect(rows[1].deliveryCents, 2000);
      expect(rows[2].returnCents, 1000);
      expect(rows[2].netCents, -1000, reason: '净额可以为负 —— 只退货的那天');
    });

    test('**拒收**的退货不冲减营收（原单已作废，减两次就是双重冲减）', () {
      // 拒收 = 送货单还在途 + 全量退货 ⇒ 原送货单被置 cancelled。
      // 它本来就不计营收，退货再减一次就是凭空少一笔。
      final String deliveryId = deliver('2026-10-07', 5);
      final ReturnSaved ret = refund(
        deliveryId,
        DocType.delivery,
        '2026-10-07',
        5,
      );
      expect(
        db.raw.select('SELECT status FROM documents WHERE id = ?', <Object?>[
          deliveryId,
        ]).first['status'],
        DocStatus.cancelled.wire,
        reason: '夹具前提：全量拒收会把原送货单置 cancelled',
      );
      expect(ret.docNo, isNotEmpty);

      final List<RevenueDay> rows = queries.dailyRevenue(
        fromDay: dayOf('2026-10-07'),
        toDay: dayOf('2026-10-07'),
      );
      expect(rows, isEmpty, reason: '拒收当天既不该有营收，也不该有冲减 —— 两边都是 0');
    });

    test('在途送货**计入**营收，并单独给出张数（图上要标注）', () {
      deliver('2026-10-08', 3); // 不签收，保持 in_transit

      final List<RevenueDay> rows = queries.dailyRevenue(
        fromDay: dayOf('2026-10-08'),
        toDay: dayOf('2026-10-08'),
      );
      expect(rows.single.deliveryCents, 3000, reason: '裁定甲：在途也算营收');
      expect(rows.single.inTransitCount, 1, reason: '界面必须能说「含未签收 1 张」');
      expect(
        rows.single.inTransitCents,
        3000,
        reason: '只报张数不够：¥100 和 ¥100,000 的在途，那句话一模一样',
      );
    });

    test('**原单读不到的退货仍然冲减**（提案 54 §五：不知道就别加回来）', () {
      // 从前这里是内连接 ⇒ 原单缺失的退货被**整条过滤掉** ⇒ 营收虚高。
      // `documents` 表对 `ref_doc_id` 没有外键约束，所以这种「指着空气」的行
      // 是真实可能存在的（坏页 / 手工清理）。
      sell('2026-10-11', 5); // ¥50

      final int at = DateTime.parse(
        '2026-10-11 12:00:00',
      ).millisecondsSinceEpoch;
      db.raw.execute(
        'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
        'paid_amount, ref_doc_id, occurred_at, time_estimated, created_at, '
        'updated_at, business_day) VALUES (?,?,?,?,?,?,?,?,0,?,?,?)',
        <Object?>[
          'ghost-return',
          'TH-GHOST-1',
          DocType.saleReturn.wire,
          DocStatus.confirmed.wire,
          2000,
          0,
          'no-such-document',
          at,
          at,
          at,
          businessDayOf(at),
        ],
      );

      final List<RevenueDay> rows = queries.dailyRevenue(
        fromDay: dayOf('2026-10-11'),
        toDay: dayOf('2026-10-11'),
      );
      expect(rows.single.saleCents, 5000);
      expect(
        rows.single.returnCents,
        2000,
        reason: '原单读不到 ⇒ 仍然冲减（保守），不能当成「没发生」',
      );
      expect(rows.single.returnCount, 1);
    });

    test('作废单据不计', () {
      final String saleId = sell('2026-10-09', 4);
      db.raw.execute('UPDATE documents SET status = ? WHERE id = ?', <Object?>[
        DocStatus.cancelled.wire,
        saleId,
      ]);

      final List<RevenueDay> rows = queries.dailyRevenue(
        fromDay: dayOf('2026-10-09'),
        toDay: dayOf('2026-10-09'),
      );
      expect(rows, isEmpty);
    });
  });

  // ============================================================ 库存 Top 10
  group('QueryDao.topStockByValue（压货榜）', () {
    late Db db;
    late PurchaseService purchases;
    late SaleService sales;
    late QueryDao queries;
    late Account cash;

    setUp(() {
      resetClock();
      db = newMemoryDb();
      final RuleEngine engine = RuleEngine(db);
      queries = QueryDao(db);
      purchases = PurchaseService(engine: engine, queries: queries);
      sales = SaleService(engine: engine, queries: queries);

      final int t = now();
      cash = Account(
        id: newId(),
        name: '现金',
        type: AccountType.cash,
        createdAt: t,
        updatedAt: t,
      );
      AccountDao(db).insert(cash);
    });

    tearDown(() => db.close());

    /// 进 [qty] 件，单价 [yuan]（元）。
    String buy(String name, String unit, int qty, String yuan) {
      final int t = now();
      final Product product = Product(
        id: newId(),
        code: 'P${name.hashCode.abs()}',
        name: name,
        unit: unit,
        costPrice: 0,
        sellPrice: 0,
        createdAt: t,
        updatedAt: t,
      );
      ProductDao(db).insert(product);
      purchases.create(
        PurchaseDraft(
          date: '2026-10-04',
          lines: <PurchaseLineDraft>[
            PurchaseLineDraft(
              productId: product.id,
              productName: name,
              quantity: '$qty',
              unitPrice: yuan,
            ),
          ],
          payments: <PurchasePaymentDraft>[
            PurchasePaymentDraft(
              accountId: cash.id,
              amount: Money.format((double.parse(yuan) * qty * 100).round()),
            ),
          ],
        ),
      );
      return product.id;
    }

    test('**按占用资金排，不按数量**（用户举的反例）', () {
      // 牙签 500 个 × ¥0.01 = ¥5；电机 10 台 × ¥100 = ¥1000。
      // 按数量排「牙签」会排第一 —— 那正是要避免的误导。
      buy('牙签', '个', 500, '0.01');
      buy('电机', '台', 10, '100');

      final List<StockValueRow> top = queries.stockTop().rows;
      expect(top.length, 2);
      expect(top.first.name, '电机', reason: '占用 ¥1000 > ¥5');
      expect(top.first.valueCents, 100000);
      expect(top.first.quantity, 10);
      expect(top.first.unit, '台');
      expect(top.last.name, '牙签');
      expect(top.last.valueCents, 500);
      expect(top.last.quantity, 500, reason: '数量照实给，但**不参与排序**');
    });

    test('limit 生效，且按价值降序', () {
      buy('A', '个', 10, '1'); // ¥10
      buy('B', '个', 10, '5'); // ¥50
      buy('C', '个', 10, '3'); // ¥30

      final List<StockValueRow> top = queries.stockTop(limit: 2).rows;
      expect(top.map((StockValueRow r) => r.name).toList(), <String>['B', 'C']);
    });

    test('超卖（数量为负）不进压货榜 —— 它属于「要留心」那张卡', () {
      final String id = buy('亏货款', '个', 5, '10');
      // 卖掉 8 个 ⇒ 库存 −3
      sales.create(
        SaleDraft(
          date: '2026-10-05',
          lines: <SaleLineDraft>[
            SaleLineDraft(
              productId: id,
              productName: '亏货款',
              quantity: '8',
              unitPrice: '20',
            ),
          ],
          payments: <SalePaymentDraft>[
            SalePaymentDraft(accountId: cash.id, amount: '160'),
          ],
        ),
      );

      expect(
        queries.stockTop().rows,
        isEmpty,
        reason: '负库存不是「压货」，混进来会让榜首变成一个负数',
      );
    });

    test('没有任何库存流水 ⇒ 空列表（不是一堆 0）', () {
      expect(queries.stockTop().isEmpty, isTrue);
    });

    test('**成本未校准**（有货、成本 0）⇒ 不进榜，只报数量', () {
      // 用户审查 2026-10-30：`WHERE qty > 0` 会把「期初录入没记进价」的商品
      // 选进来，然后显示「¥0.00」—— 用户以为这货不要钱。库存页早就有
      // 「待校准」这个词，榜单必须用同一套语言。
      final String id = buy('待校准货', '个', 10, '0.01'); // 先正常进一次
      // 把成本流水抹成 0（模拟「期初录入没记成本」：有正数量、成本余值 0）
      db.raw.execute(
        'UPDATE stock_ledger SET total_cost = 0 WHERE product_id = ?',
        <Object?>[id],
      );

      final StockTopSummary summary = queries.stockTop();
      expect(summary.rows, isEmpty, reason: '不能假装它占用 ¥0');
      expect(summary.uncalibratedCount, 1);
      expect(summary.negativeCostCount, 0);
      expect(summary.isEmpty, isFalse, reason: '有东西要提示 ⇒ 卡还是要显示');
    });

    test('**负成本**（超卖把成本摊穿）⇒ 不进榜，单独计数', () {
      final String id = buy('亏本货', '个', 2, '10'); // 2 个 × ¥10 = ¥20
      // 卖掉 1 个后成本余值还是正的；再人为把它压成负数，模拟「退货摊穿」
      db.raw.execute(
        'UPDATE stock_ledger SET total_cost = -500 WHERE product_id = ?',
        <Object?>[id],
      );

      final StockTopSummary summary = queries.stockTop();
      expect(summary.rows, isEmpty, reason: '负成本的横条没有意义');
      expect(summary.negativeCostCount, 1);
      expect(summary.uncalibratedCount, 0);
    });
  });
}
