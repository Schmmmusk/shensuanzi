import 'dart:math' as math;

import 'daily_series.dart';

/// 毛利趋势的**单日分项**与**分桶纯函数**（N-a 裁定甲，2026-11-06）。
///
/// ## 为什么分项要全部留着，而不是只给一个毛利数
///
/// 用户裁定（`docs/reply.md` §P2·3）：
///
/// > 销售收入、出库成本、退货退款和盘点损失不能混成一条没有区分的流水。
/// > 否则图表虽然能算出一个数字，却无法解释这个数字是怎样形成的。
///
/// 所以 [GrossMarginDay] 把四个组成部分**各自成字段**，界面点某一天时能拆开讲。
/// 恒等式（有测试钉住）：
///
/// ```
/// 毛利 = 收入 − 销售成本 − 盘点损失 − 退货成本调整
/// ```
class GrossMarginDay {
  const GrossMarginDay({
    required this.day,
    this.revenueCents = 0,
    this.saleCostCents = 0,
    this.stocktakeLossCents = 0,
    this.returnCostAdjustCents = 0,
    this.documentCount = 0,
    this.inTransitCount = 0,
    this.returnCount = 0,
  });

  /// 业务日序号（`businessDayOf`），**不是** `occurred_at` —— 裁定 ①甲。
  final int day;

  /// **收入**（分）：销售 + 送货 − 原单仍有效的销售退货。**退货已含在内为负数**。
  ///
  /// 与 `QueryDao.dailyRevenue` 的 `netCents` **同一份实现**（不分叉口径），
  /// 所以拒收不双冲、原单读不到仍冲减这些边界自动继承。
  final int revenueCents;

  /// **销售成本**（分，正数）：`sale` / `delivery` 出库结转的成本。
  ///
  /// ⚠️ 不含进货（那是成本的形成）、不含采购退货（那是采购的逆操作）。
  final int saleCostCents;

  /// **盘点损失**（分，正数）：盘亏结转的成本。
  ///
  /// ⚠️ **盘盈不在这里** —— `data_model.md` §3.3「盘盈同入库」，它是成本的形成，
  /// 不是结转。把它当负成本会凭空造出毛利。
  final int stocktakeLossCents;

  /// **退货的成本调整**（分，**负数**）：销售退货回吐的成本。
  ///
  /// 符号与 [revenueCents] 里的退货腿一致（都是负的），所以恒等式里是**减掉一个负数**。
  /// 单独成字段而不是并进 [saleCostCents]，是为了让「今天退了货 ⇒ 成本少了」
  /// 这件事在界面上说得出来。
  final int returnCostAdjustCents;

  /// 这一天的经营单据数（销售 + 送货），沿用营收图口径
  final int documentCount;

  /// 其中未签收的送货单数（图上要标注「含未签收 N 张」）
  final int inTransitCount;

  /// 这一天的退货单数（判断「这天有没有做过生意」用）
  final int returnCount;

  /// 毛利（分）= 收入 − 销售成本 − 盘点损失 − 退货成本调整
  int get grossMarginCents =>
      revenueCents - saleCostCents - stocktakeLossCents - returnCostAdjustCents;

  /// 这一天有没有经营活动（同 `RevenueDay`：净额 0 不代表没做生意）
  bool get isEmpty => documentCount == 0 && returnCount == 0;
}
/// 毛利图上一个桶（一天 / 一周 / 一月）—— 分量与 [GrossMarginDay] 一一对应。
class GrossMarginPoint {
  const GrossMarginPoint({
    required this.startDay,
    required this.endDay,
    required this.revenueCents,
    required this.saleCostCents,
    required this.stocktakeLossCents,
    required this.returnCostAdjustCents,
    required this.documentCount,
    required this.inTransitCount,
    required this.returnCount,
  });

  /// 桶的第一天（业务日序号，已夹到查询窗口内）
  final int startDay;

  /// 桶的最后一天（含）
  final int endDay;

  final int revenueCents;
  final int saleCostCents;
  final int stocktakeLossCents;
  final int returnCostAdjustCents;
  final int documentCount;
  final int inTransitCount;
  final int returnCount;

  /// 毛利（分）—— 与 [GrossMarginDay.grossMarginCents] 同一个恒等式
  int get grossMarginCents =>
      revenueCents -
      saleCostCents -
      stocktakeLossCents -
      returnCostAdjustCents;

  /// 这个桶里有没有经营活动（同 `RevenuePoint`）
  bool get isEmpty => documentCount == 0 && returnCount == 0;
}

/// 把稀疏的 [GrossMarginDay] 补零、按桶汇总成连续序列（纯函数，边界好测）。
///
/// 与 `buildRevenueSeries()` 同构 —— 分桶规则（周起点、月起点、窗口首日
/// 可能不是整周）必须一致，否则两张图的柱子对不齐，用户会以为数据有问题。
/// 所以这里**复用** `RevenueBucket` / `weekStartDay` / `monthStartDay`。
List<GrossMarginPoint> buildGrossMarginSeries({
  required List<GrossMarginDay> rows,
  required int fromDay,
  required int toDay,
  RevenueBucket bucket = RevenueBucket.day,
}) {
  if (fromDay > toDay) return const <GrossMarginPoint>[];

  final Map<int, _MutableMarginBucket> buckets = <int, _MutableMarginBucket>{};
  for (int day = fromDay; day <= toDay; day++) {
    final int start = switch (bucket) {
      RevenueBucket.day => day,
      RevenueBucket.week => weekStartDay(day),
      RevenueBucket.month => monthStartDay(day),
    };
    final _MutableMarginBucket acc = buckets.putIfAbsent(
      start,
      () => _MutableMarginBucket(start),
    );
    acc.endDay = math.max(acc.endDay, day);
  }

  // 窗口外的天直接丢掉（父级可能传宽数据）
  for (final GrossMarginDay row in rows) {
    if (row.day < fromDay || row.day > toDay) continue;
    final int start = switch (bucket) {
      RevenueBucket.day => row.day,
      RevenueBucket.week => weekStartDay(row.day),
      RevenueBucket.month => monthStartDay(row.day),
    };
    buckets[start]?.add(row);
  }

  final List<int> starts = buckets.keys.toList()..sort();
  return <GrossMarginPoint>[
    for (final int s in starts) buckets[s]!.freeze(fromDay),
  ];
}

class _MutableMarginBucket {
  _MutableMarginBucket(this.startDay) : endDay = startDay;

  final int startDay;
  int endDay;

  int revenue = 0;
  int saleCost = 0;
  int stocktakeLoss = 0;
  int returnAdjust = 0;
  int docs = 0;
  int transit = 0;
  int returns = 0;

  void add(GrossMarginDay d) {
    revenue += d.revenueCents;
    saleCost += d.saleCostCents;
    stocktakeLoss += d.stocktakeLossCents;
    returnAdjust += d.returnCostAdjustCents;
    docs += d.documentCount;
    transit += d.inTransitCount;
    returns += d.returnCount;
  }

  /// [fromDay] 把桶起点**夹进窗口**（与 `_MutableBucket.freeze` 同理）：
  /// 窗口的第一周可能不是从周一开始，标一个没统计的日期会骗人。
  GrossMarginPoint freeze(int fromDay) => GrossMarginPoint(
    startDay: math.max(startDay, fromDay),
    endDay: endDay,
    revenueCents: revenue,
    saleCostCents: saleCost,
    stocktakeLossCents: stocktakeLoss,
    returnCostAdjustCents: returnAdjust,
    documentCount: docs,
    inTransitCount: transit,
    returnCount: returns,
  );
}