import 'package:sqlite3/sqlite3.dart';

import '../charts/daily_series.dart';
import '../db/database.dart';
import '../db/read_failures.dart';
import '../db/schema.dart';
import '../models/document.dart';
import '../models/party.dart';
import '../models/product.dart';

/// **RULE-006 库存 / 余额查询**（`docs/rules.md`）。
///
/// 全是聚合读：**不开事务、不改任何数据**（`Agents.md` 纪律 1）。
///
/// 「真相」口径见 `docs/data_model.md` §五 —— 本类不维护任何余额表，
/// 每次都从流水算：
///
/// - 库存 = `SUM(stock_ledger.quantity)`
/// - 资金 = `accounts.initial_balance + SUM(money_ledger.amount)`
/// - 往来 = `SUM(party_ledger.amount)`（**正 = 应收，负 = 应付**）
///
/// 返回**批量映射**而不是逐条查询：列表页一次拿全，
/// 逐条查会退化成 N+1。
class QueryDao {
  QueryDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  /// 每个商品的**账面库存**。
  ///
  /// 只包含有流水的商品 —— 从没进过货的商品不会出现在结果里
  /// （消费端用 `map[id] ?? 0` 取值）。
  Map<String, int> stockByProduct() => _keyedSum(
    'SELECT product_id AS k, COALESCE(SUM(quantity), 0) AS v '
    'FROM ${Schema.stockLedger} GROUP BY product_id',
  );

  /// 每个商品的**库存成本余值**（历史加权平均口径，R-9）。
  ///
  /// ⚠️ 语义：这是「按历史加权平均成本算的剩余存货价值」，
  /// **不是「最近一次进价 × 数量」** —— 进价变过时两者不同，
  /// UI 必须标明口径（§AA 四 / AA-4）。超卖时余值为**负**（R-9）。
  /// 与 [stockByProduct] 同形状：只含有流水的商品，消费端 `?? 0`。
  Map<String, int> costByProduct() => _keyedSum(
    'SELECT product_id AS k, COALESCE(SUM(total_cost), 0) AS v '
    'FROM ${Schema.stockLedger} GROUP BY product_id',
  );

  /// **压货最多的商品**（提案 54 §三「第三优先」，2026-10-30 裁定）。
  ///
  /// ## 为什么按**占用资金**排，不按数量
  ///
  /// 用户举的例子成立：500 个、20 箱、80 千克 —— 数字大小说明不了谁压货多
  /// （单位不同，且单价差异巨大）。按数量排出来的「Top 10」会把
  /// 「一箱牙签」排在「十台电机」前面，**误导经营决策**。
  ///
  /// ## 口径
  ///
  /// `valueCents = SUM(stock_ledger.total_cost)` —— **剩余存货的历史加权平均成本**
  /// （R-9），不是「最近进价 × 数量」。UI 上必须标明这一点（§AA·四 / AA-4）。
  ///
  /// 只取 `quantity > 0` 的：超卖（负数）不该出现在「压货」榜里，
  /// 它属于「要留心」那张卡（负库存 N 种）。
  ///
  /// ## 成本三态（与库存页 §AD 遗漏 1 同一套口径）
  ///
  /// 只有 `cost > 0` 的商品才参与排名。另外两种**不能**当成「占用 ¥0」：
  ///
  /// | 状态 | 判定 | 为什么不能混进榜里 |
  /// |---|---|---|
  /// | 待校准 | `cost == 0`（期初录入没记成本） | 显示 ¥0 会让用户以为「这货不要钱」；库存页早就用「待校准」说清这件事 |
  /// | 负成本 | `cost < 0`（超卖 / 退货把成本摊穿） | 混进来会排到榜尾，横条画成负数没有任何意义 |
  ///
  /// 两种都只报**数量**，由 UI 单独提示 —— 与「未进货 / 待校准」是同一套语言。
  StockTopSummary stockTop({int limit = 10}) {
    if (limit <= 0) {
      return const StockTopSummary(
        rows: <StockValueRow>[],
        uncalibratedCount: 0,
        negativeCostCount: 0,
      );
    }
    const String aggregated =
        'FROM ${Schema.products} p '
        'JOIN (SELECT product_id, '
        '             COALESCE(SUM(quantity), 0) AS qty, '
        '             COALESCE(SUM(total_cost), 0) AS cost '
        '      FROM ${Schema.stockLedger} GROUP BY product_id) s '
        '  ON s.product_id = p.id '
        'WHERE s.qty > 0 ';

    // ⚠️ **一趟扫完**：`ORDER BY cost DESC` 之后「正 / 零 / 负」天然分段 ——
    // 取前 `limit` 个正数进榜，另外两类只数个数。
    //
    // 从前是两条查询（一条取榜、一条数两类），两条都要对整个 `stock_ledger`
    // 做一次 GROUP BY。545 MB / 26 万单实测：合并前 **97 ms**，合并后见台账。
    final List<Map<String, Object?>> all = _raw.select(
      'SELECT p.id AS id, p.name AS name, p.unit AS unit, '
      '       s.qty AS qty, s.cost AS cost '
      '$aggregated '
      'ORDER BY s.cost DESC, p.name ASC',
    );

    final List<StockValueRow> rows = <StockValueRow>[];
    int uncalibrated = 0;
    int negativeCost = 0;
    for (final Map<String, Object?> row in all) {
      final int cost = row['cost']! as int;
      if (cost > 0) {
        if (rows.length < limit) {
          rows.add(
            StockValueRow(
              productId: row['id']! as String,
              name: row['name']! as String,
              unit: row['unit']! as String,
              quantity: row['qty']! as int,
              valueCents: cost,
            ),
          );
        }
      } else if (cost == 0) {
        uncalibrated++;
      } else {
        negativeCost++;
      }
    }
    return StockTopSummary(
      rows: rows,
      uncalibratedCount: uncalibrated,
      negativeCostCount: negativeCost,
    );
  }

  /// **在途数量**：送货单里 `status = in_transit` 的未签收数量
  /// （`docs/rules.md` RULE-003 的在途视图）。
  Map<String, int> inTransitByProduct() => _keyedSum(
    'SELECT dl.product_id AS k, COALESCE(SUM(dl.quantity), 0) AS v '
    'FROM ${Schema.documentLines} dl '
    'JOIN ${Schema.documents} d ON d.id = dl.document_id '
    "WHERE d.doc_type = '${DocType.delivery.wire}' "
    "  AND d.status = '${DocStatus.inTransit.wire}' "
    'GROUP BY dl.product_id',
  );

  /// **在店可售** = 账面库存 − 在途数量。
  ///
  /// 送货单创建时货已离店（账面已扣），所以在店可售要再减掉在途。
  /// **低库存告警必须用这个，不能用账面库存。**
  Map<String, int> availableInStore() {
    final Map<String, int> book = stockByProduct();
    for (final MapEntry<String, int> entry in inTransitByProduct().entries) {
      book[entry.key] = (book[entry.key] ?? 0) - entry.value;
    }
    return book;
  }

  /// 账户余额 = `initial_balance + SUM(money_ledger.amount)`。
  ///
  /// **含所有账户**（包括一条流水都没有的），所以是 LEFT JOIN。
  Map<String, int> accountBalances() => _keyedSum(
    'SELECT a.id AS k, a.initial_balance + COALESCE(SUM(m.amount), 0) AS v '
    'FROM ${Schema.accounts} a '
    'LEFT JOIN ${Schema.moneyLedger} m ON m.account_id = a.id '
    'GROUP BY a.id',
  );

  /// **单个往来方的余额**（正 = 对方欠我，负 = 我欠对方）。
  ///
  /// 与 [partyBalances] **同一口径**（`SUM(amount)`，不含 `initial_balance`），
  /// 只是不再为了一句提示扫全表。
  ///
  /// 5b（2026-10-24，§CV·一百）：三个 service 在**每单保存末尾**为了 SnackBar 里
  /// 那句「对方现在欠多少」调 [partyBalances] —— 那是**每单固定成本**（26 万行
  /// `party_ledger` 全表聚合），随经营年限线性增长，与这单毫无关系。
  /// 改点查后走 `idx_party_covering` 前缀，**结果完全一样**。
  int partyBalanceOf(String partyId) {
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT COALESCE(SUM(amount), 0) AS v FROM ${Schema.partyLedger} '
      'WHERE party_id = ?',
      <Object?>[partyId],
    );
    return rows.isEmpty ? 0 : rows.first['v']! as int;
  }

  /// 往来余额。正 = 对方欠我（应收），负 = 我欠对方（应付）。
  Map<String, int> partyBalances() => _keyedSum(
    'SELECT party_id AS k, COALESCE(SUM(amount), 0) AS v '
    'FROM ${Schema.partyLedger} GROUP BY party_id',
  );

  /// **#32（2026-10-17 裁定甲）**：今日经营速览（概览页「今日经营」卡）。
  ///
  /// 口径（裁定①，`docs/reply.md` 2026-10-17）：
  /// - 按 **`occurred_at`（单据日期）** 算「今日」—— 用户补录昨天的单
  ///   **不进**今日（UI 文案标「按单据日期」，裁定②）；
  /// - **含赊账** —— 销售额是业务发生额，不是实收款；
  /// - `sale` 与 `delivery` **分列**（送货模式多的用户不能看到 0 笔）；
  ///   其它类型（收付款 / 退货 / 盘点）不进这张卡。
  /// - 已取消（`cancelled`）不算。
  ///
  /// 「今日」的零点由**调用方**传入（[dayStart]，本地时间零点）——
  /// core 不做时间判断（测试传固定值可复现；多时区是登记在案的将来待办）。
  OverviewSummary todaySummary(DateTime dayStart) {
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT doc_type AS t, COUNT(*) AS c, '
      'COALESCE(SUM(total_amount), 0) AS amt '
      'FROM ${Schema.documents} '
      "WHERE status != '${DocStatus.cancelled.wire}' "
      '  AND occurred_at >= ? '
      // 3c-5（2026-10-24，§3.7 P2 #5）：**必须有上界** —— 手滑填了明天 /
      // 下月的单会被算进「今日销售」，数字虚高且用户无法解释。
      '  AND occurred_at < ? '
      'GROUP BY doc_type',
      <Object?>[
        dayStart.millisecondsSinceEpoch,
        // 明日零点（本地时区；与 `dayStart` 同一套口径 —— 由调用方给的零点推）
        DateTime(
          dayStart.year,
          dayStart.month,
          dayStart.day + 1,
        ).millisecondsSinceEpoch,
      ],
    );
    int saleCount = 0, saleCents = 0, deliveryCount = 0, deliveryCents = 0;
    for (final Map<String, Object?> row in rows) {
      final int count = row['c']! as int;
      final int cents = row['amt']! as int;
      // switch 的 case 要常量，`DocType.sale.wire` 不是 const 表达式 ⇒ if/else
      final String type = row['t']! as String;
      if (type == DocType.sale.wire) {
        saleCount = count;
        saleCents = cents;
      } else if (type == DocType.delivery.wire) {
        deliveryCount = count;
        deliveryCents = cents;
      }
    }
    return OverviewSummary(
      saleCount: saleCount,
      saleCents: saleCents,
      deliveryCount: deliveryCount,
      deliveryCents: deliveryCents,
    );
  }

  /// **经营图表**：按业务日聚合的营收（提案 54 §二，2026-10-30 裁定）。
  ///
  /// ## 口径
  ///
  /// ```
  /// 营收 = 销售 + 送货 − 原单仍然有效的销售退货
  /// ```
  ///
  /// - **在途送货算营收**（裁定甲）—— 另给 `inTransitCount`，图上必须标注
  ///   「含未签收 N 张」；
  /// - 退货只减「**原单仍有效**」的：拒收时原送货单被置 `cancelled`、
  ///   本来就不计营收，再减一次就是**双重冲减**（实测 458 张、虚减 3.9%）；
  /// - 用 `business_day`（整数、有索引、不随时区漂移），**不用** `occurred_at`
  ///   —— 后者依赖查询时区，换台电脑历史图会整体平移；
  /// - 作废单据一律排除。
  ///
  /// ## 为什么是三条 SQL 而不是一条
  ///
  /// 一条 `GROUP BY business_day, doc_type` 会让规划器放弃
  /// `(doc_type, business_day)` 索引 —— 实测 **143.8 ms vs 6.1 ms**（24 倍）。
  ///
  /// 返回**稀疏**结果（只含有数据的天）；补零与分桶交给
  /// `buildRevenueSeries()` —— 那是纯函数，边界好测。
  List<RevenueDay> dailyRevenue({required int fromDay, required int toDay}) {
    if (fromDay > toDay) return const <RevenueDay>[];

    final Map<int, int> sale = <int, int>{};
    final Map<int, int> delivery = <int, int>{};
    final Map<int, int> refund = <int, int>{};
    final Map<int, int> count = <int, int>{};
    final Map<int, int> transit = <int, int>{};
    final Map<int, int> transitCents = <int, int>{};
    final Map<int, int> refundCount = <int, int>{};

    // ① 店内销售
    for (final Map<String, Object?> row in _raw.select(
      'SELECT business_day AS d, COUNT(*) AS c, '
      'COALESCE(SUM(total_amount), 0) AS amt '
      'FROM ${Schema.documents} '
      'WHERE doc_type = ? AND status != ? AND business_day BETWEEN ? AND ? '
      'GROUP BY business_day',
      <Object?>[DocType.sale.wire, DocStatus.cancelled.wire, fromDay, toDay],
    )) {
      final int day = row['d']! as int;
      sale[day] = row['amt']! as int;
      count[day] = (count[day] ?? 0) + (row['c']! as int);
    }

    // ② 送货（含在途；另数出在途张数给界面标注用）
    for (final Map<String, Object?> row in _raw.select(
      'SELECT business_day AS d, COUNT(*) AS c, '
      'COALESCE(SUM(total_amount), 0) AS amt, '
      'SUM(CASE WHEN status = ? THEN 1 ELSE 0 END) AS transit, '
      'SUM(CASE WHEN status = ? THEN total_amount ELSE 0 END) AS transit_amt '
      'FROM ${Schema.documents} '
      'WHERE doc_type = ? AND status != ? AND business_day BETWEEN ? AND ? '
      'GROUP BY business_day',
      <Object?>[
        DocStatus.inTransit.wire,
        DocStatus.inTransit.wire,
        DocType.delivery.wire,
        DocStatus.cancelled.wire,
        fromDay,
        toDay,
      ],
    )) {
      final int day = row['d']! as int;
      delivery[day] = row['amt']! as int;
      count[day] = (count[day] ?? 0) + (row['c']! as int);
      transit[day] = row['transit']! as int;
      transitCents[day] = row['transit_amt']! as int;
    }

    // ③ 销售退货
    //
    // **三条边界**（用户审查 2026-10-30 第 3 条）：
    //   · 原单存在且**未作废** ⇒ 冲减（正常退货）
    //   · 原单存在但**已作废** ⇒ **不冲减**：拒收时原送货单被置 `cancelled`、
    //     本来就没进上面两条的营收，再减一次就是双重冲减
    //     （用户实测 458 张、虚减 ¥45.8 万 / 3.9%）
    //   · 原单**读不到**（数据缺失）⇒ **仍然冲减**：提案 54 §五的边界约定是
    //     「不知道就别擅自加回来」。从前这里是内连接，直接把这种退货**过滤掉了**
    //     ⇒ 营收虚高 —— 与方案不一致。
    for (final Map<String, Object?> row in _raw.select(
      'SELECT r.business_day AS d, COUNT(*) AS c, '
      'COALESCE(SUM(r.total_amount), 0) AS amt '
      'FROM ${Schema.documents} r '
      'LEFT JOIN ${Schema.documents} o ON o.id = r.ref_doc_id '
      'WHERE r.doc_type = ? AND r.status != ? '
      '  AND (o.id IS NULL OR o.status != ?) '
      '  AND r.business_day BETWEEN ? AND ? '
      'GROUP BY r.business_day',
      <Object?>[
        DocType.saleReturn.wire,
        DocStatus.cancelled.wire,
        DocStatus.cancelled.wire,
        fromDay,
        toDay,
      ],
    )) {
      final int day = row['d']! as int;
      refund[day] = row['amt']! as int;
      refundCount[day] = row['c']! as int;
    }

    final Set<int> days = <int>{...sale.keys, ...delivery.keys, ...refund.keys};
    final List<int> sorted = days.toList()..sort();
    return <RevenueDay>[
      for (final int day in sorted)
        RevenueDay(
          day: day,
          saleCents: sale[day] ?? 0,
          deliveryCents: delivery[day] ?? 0,
          returnCents: refund[day] ?? 0,
          documentCount: count[day] ?? 0,
          inTransitCount: transit[day] ?? 0,
          inTransitCents: transitCents[day] ?? 0,
          returnCount: refundCount[day] ?? 0,
        ),
    ];
  }

  /// **#32**：未签收送货单张数（`in_transit`；「送货 M 笔 · ¥Y」行的小注）。
  int deliveryInTransitCount() =>
      _raw
              .select(
                'SELECT COUNT(*) AS c FROM ${Schema.documents} '
                "WHERE doc_type = '${DocType.delivery.wire}' "
                "  AND status = '${DocStatus.inTransit.wire}'",
              )
              .first['c']!
          as int;

  /// **#32**：应收速览（概览页「要留心」卡）—— 正余额 = 对方欠我（应收）。
  ///
  /// top1 = 欠得最多的那家（**停用的也显示**，OBS-05「账未结清要能查到」；
  /// UI 标「（已停用）」）。没有应收 ⇒ 全零 + `topName == null`。
  ReceivablesSummary receivablesSummary() => _duesSummary(positive: true);

  /// **应付汇总**（F13，2026-10-25 裁定）：谁我欠着钱、一共欠多少。
  ///
  /// 金额一律取**正数** —— 「我欠李哥 ¥72」对用户就是 72，不该显示成 −72。
  PayablesSummary payablesSummary() => _duesSummary(positive: false);

  /// 应收 / 应付**同一份实现**（纪律 18：不许两处并行，早晚漂移）。
  ///
  /// [positive] = true 取正余额（人欠我）；false 取负余额（我欠人，金额取绝对值）。
  DuesSummary _duesSummary({required bool positive}) {
    final Map<String, int> balances = partyBalances();
    final List<MapEntry<String, int>> dues =
        balances.entries
            .where(
              (MapEntry<String, int> e) => positive ? e.value > 0 : e.value < 0,
            )
            .toList()
          ..sort(
            (MapEntry<String, int> a, MapEntry<String, int> b) => positive
                ? b.value.compareTo(a.value)
                : a.value.compareTo(b.value), // 负得越多 = 欠得越多，排前面
          );
    if (dues.isEmpty) {
      return const DuesSummary(
        totalCents: 0,
        partyCount: 0,
        topName: null,
        topActive: true,
        topCents: 0,
      );
    }
    final MapEntry<String, int> top = dues.first;
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT name, is_active FROM ${Schema.parties} WHERE id = ?',
      <Object?>[top.key],
    );
    return DuesSummary(
      totalCents: dues.fold(
        0,
        (int s, MapEntry<String, int> e) => s + e.value.abs(),
      ),
      partyCount: dues.length,
      topName: rows.isEmpty ? null : rows.first['name']! as String,
      topActive: rows.isEmpty || (rows.first['is_active']! as int) == 1,
      topCents: top.value.abs(),
    );
  }

  /// 是否存在任何单据（§AE 遗漏 1：空库跳过**自动**备份的判定 ——
  /// 刚建好数据目录还没录东西时，不该生成一份份相同的空库备份；
  /// 「手动立即备份」不受此限制，那是用户的主动意图）。
  bool hasAnyDocument() =>
      _raw.select('SELECT 1 FROM ${Schema.documents} LIMIT 1').isNotEmpty;

  /// 是否存在**任何**库存流水（§AD 遗漏 2）。
  ///
  /// 库存页据此区分入口文案：`false` = 首次 →「录入现有货物」；
  /// `true` = 再次 →「重新清点」。一次 EXISTS 查询，O(1) 级别。
  bool hasAnyStockLedger() =>
      _raw.select('SELECT 1 FROM ${Schema.stockLedger} LIMIT 1').isNotEmpty;

  /// **库存页一次取全**（4c-2，2026-10-24，业务审查 §5.2 #3）：
  /// 账面 + 成本余值 + 是否进过货 —— **一条 SQL 扫一次 `stock_ledger`**。
  ///
  /// 从前库存页每次 rebuild 跑三次全表聚合（`stockByProduct` /
  /// `costByProduct` / `inboundProductIds`），30 万行 × 3。三者同表同分组键，
  /// 合成一次即可（`MAX(CASE WHEN quantity > 0 ...)` 顺手算出「进过货」）。
  ///
  /// ⚠️ 三个单查方法**保留**（别处仍在用：开单页只用账面、成本页只用成本）；
  /// 页面级合并只在需要多项时用这个。
  Map<String, StockAgg> stockAggregates() => <String, StockAgg>{
    for (final Map<String, Object?> row in _raw.select(
      'SELECT product_id AS k, '
      'COALESCE(SUM(quantity), 0) AS q, '
      'COALESCE(SUM(total_cost), 0) AS c, '
      'MAX(CASE WHEN quantity > 0 THEN 1 ELSE 0 END) AS inb '
      'FROM ${Schema.stockLedger} GROUP BY product_id',
    ))
      row['k']! as String: StockAgg(
        quantity: row['q']! as int,
        cost: row['c']! as int,
        hasInbound: (row['inb']! as int) != 0,
      ),
  };

  /// 发生过**正数量入库**（数量 > 0 的流水）的商品集合（§AD 遗漏 1）。
  ///
  /// 库存页成本列的三态判断：
  /// - 商品不在集合里 → **从未入库** →「未进货」
  /// - 在集合里且 [costByProduct] 余值为 0 → 期初录入过、成本未校准 →「待校准」
  /// - 在集合里且余值 ≠ 0 → 正常显示金额
  ///
  /// 「数量 > 0」涵盖采购入库与盘盈（RULE-009 的 diff > 0）——
  /// 两者都意味着「这个商品真实进过货」，成本口径有意义。
  Set<String> inboundProductIds() => <String>{
    for (final Row row in _raw.select(
      'SELECT DISTINCT product_id AS k '
      'FROM ${Schema.stockLedger} WHERE quantity > 0',
    ))
      row['k']! as String,
  };

  Map<String, int> _keyedSum(String sql) => <String, int>{
    for (final Row row in _raw.select(sql))
      row['k']! as String: row['v']! as int,
  };

  /// 最近**交易过**的商品（选择器空查询时显示的「最近使用」）。
  ///
  /// [docTypes] 决定哪些单据算「交易过」：采购页传 `[purchase]`、
  /// 销售页传 `[sale]` —— **一处 SQL 两处共用**（`docs/reply_review.md` §Z 五），
  /// 不为采购/销售各写一个平行方法。
  ///
  /// 只含**启用中**的商品，按最近一次交易时间倒序；没有任何历史时返回空列表
  /// （界面退化为纯搜索）。个体工商户大部分单据是重复进货/出货 ——
  /// 打开选择器就能点到常买的货，不用每次敲搜索词。
  /// 「最近使用」的扫描窗口（张单据）。见 [recentProducts] 的保底说明。
  static const int _recentScanWindow = 2000;

  /// 从「按最新单据倒序」的行里收集前 [limit] 个不同 key。
  ///
  /// 返回 `truncated = true` 表示**窗口被用完**（子查询撞到了 `LIMIT`），
  /// 也就是「更早的单里可能还有别的 key」；`false` 表示已经扫到底、结果完整。
  ///
  /// ⚠️ 判据必须是「窗口是否被用完」，**不是**「key 数够不够」——
  /// 商品 / 往来方总数本来就少时（只卖 3 种货）窗口永远凑不满 limit，
  /// 那种情况退回全量只会更慢，而且结果一模一样。
  static ({List<String> ids, bool truncated}) _collectRecent(
    List<Map<String, Object?>> rows,
    int limit,
    int window,
  ) {
    final List<String> ids = <String>[];
    final Set<String> seen = <String>{};
    final Set<String> docs = <String>{};
    for (final Map<String, Object?> row in rows) {
      docs.add(row['did']! as String);
      final String key = row['pid']! as String;
      if (seen.add(key)) {
        ids.add(key);
        // 凑够了就停 —— 快路径的收益全在这个 break 上
        if (ids.length >= limit) return (ids: ids, truncated: true);
      }
    }
    return (ids: ids, truncated: docs.length >= window);
  }

  /// 最近使用过的商品（开单页商品选择器的默认列表）。
  ///
  /// ## 等价改写（4c，2026-10-24，§CV·九十九）
  ///
  /// 旧写法 `GROUP BY product_id ORDER BY MAX(occurred_at) DESC` 要**扫全部销售单**
  /// 再分组 —— 26.4 万单实测 **429 ms**。
  ///
  /// 新写法：从**最新单据倒序**走，凑满 [limit] 个不同商品就停。这在数学上**等价**：
  /// 一个商品的「最后一次卖出」必然就是它出现的**最新那张单**，所以「倒序遇到的
  /// 前 N 个不同商品」= 按 `MAX(occurred_at)` 倒序的前 N 个。
  /// 实测 429 ms → **7 ms**（同语义、逐项比对一致）。
  ///
  /// ## 两条不能省的细节
  ///
  /// 1. **必须 `INDEXED BY idx_documents_occurred`** —— 不写的话规划器会选
  ///    `idx_documents_type_status` 再排 11.2 万行（实测 122 ms，白瞎了索引）。
  /// 2. **保底**：窗口被用完仍不足 [limit] 个 ⇒ 退回全量查询（见 [_collectRecent]）。
  List<Product> recentProducts({
    required List<DocType> docTypes,
    int limit = 20,
  }) {
    if (docTypes.isEmpty) return const <Product>[];
    final String marks = List<String>.filled(docTypes.length, '?').join(',');
    final List<Object?> types = <Object?>[
      for (final DocType t in docTypes) t.wire,
    ];

    final ({List<String> ids, bool truncated}) picked = _collectRecent(
      _raw.select(
        'SELECT d.id AS did, dl.product_id AS pid '
        'FROM (SELECT id, occurred_at FROM ${Schema.documents} '
        '      INDEXED BY idx_documents_occurred '
        '      WHERE doc_type IN ($marks) '
        '      ORDER BY occurred_at DESC LIMIT ?) d '
        'JOIN ${Schema.documentLines} dl ON dl.document_id = d.id '
        'JOIN ${Schema.products} p ON p.id = dl.product_id '
        'WHERE p.is_active = 1 '
        'ORDER BY d.occurred_at DESC',
        <Object?>[...types, _recentScanWindow],
      ),
      limit,
      _recentScanWindow,
    );
    List<String> ids = picked.ids;
    if (ids.length < limit && picked.truncated) {
      // 保底：窗口被用完 ⇒ 用**全量语义**再算一次（慢就慢点，但数据必须对）
      ids = <String>[
        for (final Map<String, Object?> row in _raw.select(
          'SELECT dl.product_id AS pid '
          'FROM ${Schema.documentLines} dl '
          'JOIN ${Schema.documents} d ON d.id = dl.document_id '
          'JOIN ${Schema.products} p ON p.id = dl.product_id '
          'WHERE d.doc_type IN ($marks) AND p.is_active = 1 '
          'GROUP BY dl.product_id '
          'ORDER BY MAX(d.occurred_at) DESC '
          'LIMIT ?',
          <Object?>[...types, limit],
        ))
          row['pid']! as String,
      ];
    }
    if (ids.isEmpty) return const <Product>[];
    // 4c-4（2026-10-24，业务审查 §5.2 #6）：**一次 `IN` 取回全部行** ——
    // 从前逐条 `findById`（20 次主键查询的 N+1）。
    final String idMarks = List<String>.filled(ids.length, '?').join(',');
    final List<Product> found = decodeRows(
      _raw.select(
        'SELECT * FROM ${Schema.products} WHERE id IN ($idMarks)',
        ids,
      ),
      (Map<String, Object?> row) => Product.fromRow(row),
      table: Schema.products,
      failures: db.readFailures,
    );
    final Map<String, Product> byId = <String, Product>{
      for (final Product product in found) product.id: product,
    };
    return <Product>[
      for (final String id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// 最近**交易过**的往来方（客户/供应商选择器空查询时显示的「最近往来」，
  /// §Z 遗漏 3 —— 客户群稳定，一开店就能点到常客）。
  ///
  /// 语义与 [recentProducts] 完全对称：[docTypes] 决定哪些单据算「交易过」，
  /// 只含**启用中**的往来方，按最近一次交易时间倒序；没有历史返回空列表。
  /// 无往来的单据（散客/散采）`party_id` 为空，天然被排除。
  ///
  /// 实现也对称（4c）：倒序走最近 [_recentScanWindow] 张单取前 [limit] 个不同往来方
  /// —— 159 ms → **2.3 ms**。顺带修掉从前的 **N+1**（逐条 `parties.findById`）。
  List<Party> recentParties({required List<DocType> docTypes, int limit = 20}) {
    if (docTypes.isEmpty) return const <Party>[];
    final String marks = List<String>.filled(docTypes.length, '?').join(',');
    final List<Object?> types = <Object?>[
      for (final DocType t in docTypes) t.wire,
    ];

    final ({List<String> ids, bool truncated}) picked = _collectRecent(
      _raw.select(
        'SELECT d.id AS did, d.party_id AS pid '
        'FROM (SELECT id, party_id, occurred_at FROM ${Schema.documents} '
        '      INDEXED BY idx_documents_occurred '
        '      WHERE doc_type IN ($marks) AND party_id IS NOT NULL '
        '      ORDER BY occurred_at DESC LIMIT ?) d '
        'JOIN ${Schema.parties} pa ON pa.id = d.party_id '
        'WHERE pa.is_active = 1 '
        'ORDER BY d.occurred_at DESC',
        <Object?>[...types, _recentScanWindow],
      ),
      limit,
      _recentScanWindow,
    );
    List<String> ids = picked.ids;
    if (ids.length < limit && picked.truncated) {
      ids = <String>[
        for (final Map<String, Object?> row in _raw.select(
          'SELECT d.party_id AS pid '
          'FROM ${Schema.documents} d '
          'JOIN ${Schema.parties} pa ON pa.id = d.party_id '
          'WHERE d.doc_type IN ($marks) AND d.party_id IS NOT NULL '
          '  AND pa.is_active = 1 '
          'GROUP BY d.party_id '
          'ORDER BY MAX(d.occurred_at) DESC '
          'LIMIT ?',
          <Object?>[...types, limit],
        ))
          row['pid']! as String,
      ];
    }
    if (ids.isEmpty) return const <Party>[];
    // 一次 `IN` 取回（从前逐条 `findById` = N+1）
    final String idMarks = List<String>.filled(ids.length, '?').join(',');
    final List<Party> found = decodeRows(
      _raw.select(
        'SELECT * FROM ${Schema.parties} WHERE id IN ($idMarks)',
        ids,
      ),
      (Map<String, Object?> row) => Party.fromRow(row),
      table: Schema.parties,
      failures: db.readFailures,
    );
    final Map<String, Party> byId = <String, Party>{
      for (final Party party in found) party.id: party,
    };
    return <Party>[
      for (final String id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }
}

/// [QueryDao.stockTop] 的结果：能排名的 + 两种「不能假装有金额」的计数。
class StockTopSummary {
  const StockTopSummary({
    required this.rows,
    required this.uncalibratedCount,
    required this.negativeCostCount,
  });

  /// 占用资金 > 0 的商品，按金额降序（最多 `limit` 条）
  final List<StockValueRow> rows;

  /// 有库存但**成本为 0**（期初录入没记成本）的商品数 —— 显示成「待校准」
  final int uncalibratedCount;

  /// 有库存但**成本为负**（超卖 / 退货把成本摊穿）的商品数
  final int negativeCostCount;

  /// 三样都没有 ⇒ 整张卡不显示
  bool get isEmpty =>
      rows.isEmpty && uncalibratedCount == 0 && negativeCostCount == 0;
}

/// [QueryDao.stockTop] 的一行：一个商品的压货情况。
class StockValueRow {
  const StockValueRow({
    required this.productId,
    required this.name,
    required this.unit,
    required this.quantity,
    required this.valueCents,
  });

  final String productId;
  final String name;

  /// 商品自己的单位（**不做单位换算、不跨商品求和**）
  final String unit;

  /// 当前库存数量（最小单位）
  final int quantity;

  /// 占用资金（分）= `SUM(stock_ledger.total_cost)`，历史加权平均成本口径
  final int valueCents;
}

/// [QueryDao.todaySummary] 的一行结果（#32：概览页「今日经营」卡）。
class OverviewSummary {
  const OverviewSummary({
    required this.saleCount,
    required this.saleCents,
    required this.deliveryCount,
    required this.deliveryCents,
  });

  /// 今日**店内销售**（`sale`）笔数 / 金额（分）。含赊账；已取消不算。
  final int saleCount;
  final int saleCents;

  /// 今日**送货**（`delivery`）笔数 / 金额（分）。
  final int deliveryCount;
  final int deliveryCents;
}

/// [QueryDao.receivablesSummary] 的结果（#32：概览页「要留心」卡）。
class DuesSummary {
  const DuesSummary({
    required this.totalCents,
    required this.partyCount,
    required this.topName,
    required this.topActive,
    required this.topCents,
  });

  /// 应收合计（分）—— 所有正余额之和。
  final int totalCents;

  /// 欠款方家数（正余额的往来方数）。
  final int partyCount;

  /// 欠得最多的一家（`null` = 没有应收）。**停用的也在内**（OBS-05）。
  final String? topName;
  final bool topActive;
  final int topCents;
}

/// 应收（人欠我）—— 旧名保留，形状与 [DuesSummary] 一致。
typedef ReceivablesSummary = DuesSummary;

/// 应付（我欠人）—— F13（2026-10-25）：概览页「要留心」从前只看应收，
/// 欠着供应商的钱一个字都不说，边界上还会显示「目前没有要留心的事」。
typedef PayablesSummary = DuesSummary;

/// 一个商品的库存聚合（[QueryDao.stockAggregates] 的返回元素）。
class StockAgg {
  const StockAgg({
    required this.quantity,
    required this.cost,
    required this.hasInbound,
  });

  /// 账面库存（`SUM(quantity)`）
  final int quantity;

  /// 成本余值（`SUM(total_cost)`，可为负 —— 超卖）
  final int cost;

  /// 是否发生过正数量入库（成本列的「未进货 / 待校准」三态判断用）
  final bool hasInbound;
}
