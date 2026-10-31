import 'dart:math' as math;

/// 经营图表的**序列构建**（提案 54 §二 / 55 §三）。
///
/// ## 这一层为什么是纯函数
///
/// 「补零」「自然周从周一起」「按月分桶」都是**算日期**，跟数据库无关。
/// 把它们做成纯函数，就能在测试里把边界（跨月、跨年、空白日、闰年）
/// 全部钉住 —— 而不是等图画出来才发现「三天没卖」被画成了连续趋势。
///
/// 查询层只负责「哪几天有钱」，这里负责「图上有几根柱子、每根多高」。

/// 一个业务日的营收拆解。
///
/// [day] = **业务日序号**（本地日，自 1970-01-01 起，见 `businessDayOf`）。
class RevenueDay {
  const RevenueDay({
    required this.day,
    this.saleCents = 0,
    this.deliveryCents = 0,
    this.returnCents = 0,
    this.documentCount = 0,
    this.inTransitCount = 0,
    this.inTransitCents = 0,
    this.returnCount = 0,
  });

  final int day;

  /// 店内销售
  final int saleCents;

  /// 送货（**含在途未签收** —— 2026-10-30 裁定甲）
  final int deliveryCents;

  /// 退货冲减。**正数**，表示「要从营收里减掉多少」。
  ///
  /// ⚠️ 只含**原单仍然有效**的退货：拒收时原送货单已被置 `cancelled`、
  /// 本来就不计营收，再减一次就是双重冲减（实测 458 张、虚减 3.9%）。
  final int returnCents;

  /// 这一天的单据数（销售 + 送货）
  final int documentCount;

  /// 其中**还没签收**的送货单数（图上要标注「含未签收 N 张」）
  final int inTransitCount;

  /// 其中未签收送货的**金额**（「N 张 · ¥X」—— 只报张数，用户看不出这事有多大）
  final int inTransitCents;

  /// 这一天的**退货单数**（不是金额）。
  ///
  /// 用来判断「这天有没有做过生意」：一天卖了 ¥500、又退了 ¥500，净额是 0，
  /// 但那天**确实有经营活动**。只按 `netCents != 0` 判断会漏掉这种日子，
  /// 于是「平均每个有生意的日子」被算高（用户审查 2026-10-30）。
  final int returnCount;

  /// 净营收 = 销售 + 送货 − 退货
  int get netCents => saleCents + deliveryCents - returnCents;

  /// 这一天**有没有经营活动**（不是「净额是不是 0」）。
  ///
  /// 卖了 ¥500 又退了 ¥500 ⇒ 净额 0，但那天是有生意的。
  bool get isEmpty => documentCount == 0 && returnCount == 0;
}

/// 图上一个桶（一天 / 一周 / 一月）。
class RevenuePoint {
  const RevenuePoint({
    required this.startDay,
    required this.endDay,
    required this.saleCents,
    required this.deliveryCents,
    required this.returnCents,
    required this.documentCount,
    required this.inTransitCount,
    required this.inTransitCents,
    required this.returnCount,
  });

  /// 桶的第一天（业务日序号）
  final int startDay;

  /// 桶的最后一天（含）
  final int endDay;

  final int saleCents;
  final int deliveryCents;
  final int returnCents;
  final int documentCount;
  final int inTransitCount;
  final int inTransitCents;
  final int returnCount;

  int get netCents => saleCents + deliveryCents - returnCents;

  /// 这个桶里**有没有经营活动**（见 `RevenueDay.isEmpty` 的说明）
  bool get isEmpty => documentCount == 0 && returnCount == 0;
}

/// 分桶粒度。
enum RevenueBucket {
  /// 一天一根柱子（近 30 天用这个）
  day,

  /// **自然周**，周一为一周的第一天（不是「每 7 天切一刀」）
  week,

  /// 自然月
  month,
}

/// 把「有数据的那些天」铺成**连续**的序列，并按 [bucket] 分桶。
///
/// ## 为什么必须补零（用户裁定）
///
/// 不补的话，`2026-10-01` 和 `2026-10-04` 两根柱子会**挨在一起**，
/// 图上看起来像「连续卖了四天」。三天没卖这件事必须**看得见**。
///
/// ## 边界口径
///
/// - `fromDay > toDay` ⇒ 空列表（不抛）
/// - 桶的 `startDay` 可能**早于** `fromDay`（第一周/第一月不完整），
///   这是对的：柱子的位置由日历决定，不由查询窗口决定。
///   调用方要标注的话用 `startDay < fromDay` 判断。
/// - 同一 `day` 出现多次时**累加**（查询层理论上不会给重复，但别指望）
List<RevenuePoint> buildRevenueSeries({
  required List<RevenueDay> rows,
  required int fromDay,
  required int toDay,
  RevenueBucket bucket = RevenueBucket.day,
}) {
  if (fromDay > toDay) return const <RevenuePoint>[];

  // ① 铺平：先把查询结果按天摊进数组，缺的天留空（后面补 0）
  final Map<int, RevenueDay> byDay = <int, RevenueDay>{};
  for (final RevenueDay row in rows) {
    if (row.day < fromDay || row.day > toDay) continue; // 窗口外的忽略
    final RevenueDay? prev = byDay[row.day];
    byDay[row.day] = prev == null
        ? row
        : RevenueDay(
            day: row.day,
            saleCents: prev.saleCents + row.saleCents,
            deliveryCents: prev.deliveryCents + row.deliveryCents,
            returnCents: prev.returnCents + row.returnCents,
            documentCount: prev.documentCount + row.documentCount,
            inTransitCount: prev.inTransitCount + row.inTransitCount,
            inTransitCents: prev.inTransitCents + row.inTransitCents,
            returnCount: prev.returnCount + row.returnCount,
          );
  }

  // ② 分桶：每天先归到它所属的桶起点，再按桶累加
  final Map<int, _MutableBucket> buckets = <int, _MutableBucket>{};
  for (int day = fromDay; day <= toDay; day++) {
    final int start = switch (bucket) {
      RevenueBucket.day => day,
      RevenueBucket.week => weekStartDay(day),
      RevenueBucket.month => monthStartDay(day),
    };
    final RevenueDay data = byDay[day] ?? RevenueDay(day: day); // 没有数据 ⇒ 全 0
    final _MutableBucket acc = buckets.putIfAbsent(
      start,
      () => _MutableBucket(start),
    );
    acc.add(data);
    acc.endDay = math.max(acc.endDay, day);
  }

  // ③ 按桶起点排序 —— 图从左到右就是这个顺序
  final List<int> starts = buckets.keys.toList()..sort();
  return <RevenuePoint>[
    for (final int start in starts) buckets[start]!.freeze(fromDay),
  ];
}

/// 月度对比的两个窗口：**本月至今** vs **上月同期**。
///
/// ## 为什么必须比「同期」，不能比「上月整月」
///
/// 今天是 10 月 8 日时，「本月 1–8 日」对「上月 1–30 日」必然显得惨淡 ——
/// 那不是生意变差，是**窗口不等长**。这种图会直接骗人（提案 54 §五
/// 「口径必须先定，否则图会撒谎」）。
///
/// 所以上月窗口取**同样的天数**，并且：
///
/// - 上月不足那么多天时（今天 31 日、上月只有 30 天）**截到月末**，
///   不跨到上上月去凑；
/// - 卡片上把两段日期都写出来，用户能自己核对。
class MonthCompareWindow {
  const MonthCompareWindow({
    required this.currentFrom,
    required this.currentTo,
    required this.priorFrom,
    required this.priorTo,
  });

  final int currentFrom;
  final int currentTo;
  final int priorFrom;
  final int priorTo;

  int get currentDays => currentTo - currentFrom + 1;
  int get priorDays => priorTo - priorFrom + 1;
}

/// 算出「本月至今」与「上月同期」两段窗口。
///
/// [todayDay] = 今天（业务日序号）。
MonthCompareWindow monthCompareWindow(int todayDay) {
  final int currentFrom = monthStartDay(todayDay);
  final DateTime today = dayToDate(todayDay);
  final int priorFrom = monthStartDay(currentFrom - 1);
  // 上月有几天：从 1 日往后跳 32 天**一定**落到下个月（1 日 + 32 天 ≥ 33 日，
  // 而任何月份都不超过 31 天），再取那之前一天。
  final int priorMonthEnd = monthStartDay(priorFrom + 32) - 1;
  final int priorDays = math.min(today.day, priorMonthEnd - priorFrom + 1);
  return MonthCompareWindow(
    currentFrom: currentFrom,
    currentTo: todayDay,
    priorFrom: priorFrom,
    priorTo: priorFrom + priorDays - 1,
  );
}

/// 月度对比的结果。
class MonthCompare {
  const MonthCompare({
    required this.window,
    required this.currentCents,
    required this.priorCents,
    required this.currentHasActivity,
    required this.priorHasActivity,
  });

  final MonthCompareWindow window;

  /// 本月至今的净营收（销售 + 送货 − 有效退货）
  final int currentCents;

  /// 上月同期的净营收
  final int priorCents;

  /// 两段窗口里**有没有经营活动**（不是「净额是不是 0」）。
  ///
  /// 卖了 ¥500 又退了 ¥500 的那天净额是 0，但它确实做了生意 ——
  /// 用净额判断会说「这个月没生意」（与 `RevenueDay.isEmpty` 同一个教训）。
  final bool currentHasActivity;
  final bool priorHasActivity;

  int get deltaCents => currentCents - priorCents;

  /// 相对上月同期的变化百分比。
  ///
  /// 上月同期为 0 时**没有百分比**（除以 0 不是无穷大，是「没法比」）——
  /// 界面要说「上月同期还没有生意」，不能写「+∞%」。
  int? get percent {
    if (priorCents == 0) return null;
    return (deltaCents * 100 / priorCents).round();
  }

  /// 两段都没有经营活动 ⇒ 整张卡不显示
  bool get isEmpty => !currentHasActivity && !priorHasActivity;
}

/// 从按日数据里汇总出月度对比。
///
/// [rows] 可以是比窗口更宽的区间（调用方通常一次查够两个窗口），
/// 窗口外的天在这里被忽略。
MonthCompare buildMonthCompare({
  required List<RevenueDay> rows,
  required MonthCompareWindow window,
}) {
  int current = 0;
  int prior = 0;
  bool currentActive = false;
  bool priorActive = false;
  for (final RevenueDay row in rows) {
    final bool inCurrent =
        row.day >= window.currentFrom && row.day <= window.currentTo;
    final bool inPrior =
        row.day >= window.priorFrom && row.day <= window.priorTo;
    if (inCurrent) {
      current += row.netCents;
      if (!row.isEmpty) currentActive = true;
    } else if (inPrior) {
      prior += row.netCents;
      if (!row.isEmpty) priorActive = true;
    }
  }
  return MonthCompare(
    window: window,
    currentCents: current,
    priorCents: prior,
    currentHasActivity: currentActive,
    priorHasActivity: priorActive,
  );
}

/// [day] 所属**自然周**的第一天（周一）。
///
/// 1970-01-01（业务日 0）是**星期四** ⇒ 那一周的周一是 −3。
/// 所以先平移 3 天再按 7 整除，最后移回来。
///
/// ⚠️ 不能用 `day ~/ 7`：那是「纪元起算每 7 天一刀」，
/// 切出来的边界既不是周一也不是周日 —— 用户看到的「本周」会跟日历对不上
/// （提案 54 用户裁定 ②）。
int weekStartDay(int day) => ((day + 3) / 7).floor() * 7 - 3;

/// [day] 所属**自然月**的第一天。
///
/// 业务日是「本地日序号」，用 UTC 历法还原它的年月日即可
/// （`day * 86400000` 当作 UTC 毫秒 ⇒ 年月日就是那个本地日）。
int monthStartDay(int day) {
  final DateTime date = dayToDate(day);
  return DateTime.utc(date.year, date.month, 1).millisecondsSinceEpoch ~/
      86400000;
}

/// 业务日序号 → 那一天的 `DateTime`（UTC，**年月日即本地日历**）。
///
/// 只用来取年月日 / 星期几，别拿它去跟本地时间做减法。
DateTime dayToDate(int day) =>
    DateTime.fromMillisecondsSinceEpoch(day * 86400000, isUtc: true);

/// 业务日序号 → `2026-10-30`（图上的横轴标签）。
String dayLabel(int day) {
  final DateTime date = dayToDate(day);
  final String m = date.month.toString().padLeft(2, '0');
  final String d = date.day.toString().padLeft(2, '0');
  return '${date.year}-$m-$d';
}

class _MutableBucket {
  _MutableBucket(this.startDay) : endDay = startDay;

  final int startDay;
  int endDay;
  int saleCents = 0;
  int deliveryCents = 0;
  int returnCents = 0;
  int documentCount = 0;
  int inTransitCount = 0;
  int inTransitCents = 0;
  int returnCount = 0;

  void add(RevenueDay data) {
    saleCents += data.saleCents;
    deliveryCents += data.deliveryCents;
    returnCents += data.returnCents;
    documentCount += data.documentCount;
    inTransitCount += data.inTransitCount;
    inTransitCents += data.inTransitCents;
    returnCount += data.returnCount;
  }

  /// [fromDay] 用来把桶的起点**夹进窗口**：窗口的第一周/第一月可能不是从
  /// 日历边界开始的，标一个「10/19」但实际只统计了 10/24 起，会骗人。
  RevenuePoint freeze(int fromDay) => RevenuePoint(
    startDay: math.max(startDay, fromDay),
    endDay: endDay,
    saleCents: saleCents,
    deliveryCents: deliveryCents,
    returnCents: returnCents,
    documentCount: documentCount,
    inTransitCount: inTransitCount,
    inTransitCents: inTransitCents,
    returnCount: returnCount,
  );
}
