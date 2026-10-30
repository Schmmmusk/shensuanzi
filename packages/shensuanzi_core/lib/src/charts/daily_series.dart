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

  /// 净营收 = 销售 + 送货 − 退货
  int get netCents => saleCents + deliveryCents - returnCents;

  bool get isEmpty => netCents == 0 && documentCount == 0;
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

  int get netCents => saleCents + deliveryCents - returnCents;

  bool get isEmpty => netCents == 0 && documentCount == 0;
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

  void add(RevenueDay data) {
    saleCents += data.saleCents;
    deliveryCents += data.deliveryCents;
    returnCents += data.returnCents;
    documentCount += data.documentCount;
    inTransitCount += data.inTransitCount;
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
  );
}
