// 图表在**大库**上会不会失真 —— 探针（2026-11-01，用户提出的待办）。
//
// 用法：`dart run tool/chart_scale_probe.dart <库文件> [--keep]`
//
// ## 它回答什么
//
// 用户原话：「26.4 万单下柱状图 / 欠款横条 / 压货榜的比例是否失真
// （尤其『小额只保 4px』在极端数据下会不会让所有条看起来一样长）」。
//
// 所以这个探针**不画图**，只做两件事：
// 1. 用真库算出三处图表要用的**原始数字**（近 30 天按周营收 / 压货 Top10 / 应收应付）；
// 2. 按**真实的渲染规则**换算成像素（`RatioBar`：比例照实算、最少 4px；
//    营收柱：高度 = 金额 × 单位，没有下限），再统计「有多少条看不出差别」。
//
// 判据（写在输出里，避免「看了数字不知道该下什么结论」）：
// - `≤1px` 的条：**画不出来**，等于没有；
// - `4px` 封顶的条（只有 `RatioBar` 有下限）：长度不再携带信息；
// - 若「看不出差别的条」超过一半 ⇒ 线性刻度在这份数据上已经失效，
//   该考虑对数刻度（或分段刻度）。
//
// ⚠️ **源库不动**：先复制到临时文件再打开（`Db.open` 会碰 WAL / 可能迁移）。
import 'dart:io';
import 'dart:math' as math;

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/chart_scale_probe.dart <库文件> [--keep]');
    exit(2);
  }
  useLocalSqlite();

  final String src = args.first;
  final bool keep = args.contains('--keep');
  final File source = File(src);
  if (!source.existsSync()) {
    stderr.writeln('库不存在：$src');
    exit(2);
  }

  final String tmp =
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'chart-probe-${DateTime.now().millisecondsSinceEpoch}.db';
  final Stopwatch copyWatch = Stopwatch()..start();
  source.copySync(tmp);
  stdout.writeln('复制到临时库：$tmp（${copyWatch.elapsedMilliseconds} ms）');

  final Db db = Db.open(tmp, foreignKeys: false);
  try {
    final QueryDao q = QueryDao(db);
    final int toDay = businessDayOf(DateTime.now().millisecondsSinceEpoch);
    final int fromDay = toDay - 29;

    _revenue(q, fromDay: fromDay, toDay: toDay);
    _stockTop(q);
    _balance(q);
  } finally {
    db.close();
    if (!keep) {
      for (final String suffix in <String>['', '-wal', '-shm']) {
        final File f = File('$tmp$suffix');
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } catch (_) {
            // 删不掉就留着，不影响结论
          }
        }
      }
    }
  }
}

/// 金额（分）→ `¥1,234.56`
String _money(int cents) {
  final String sign = cents < 0 ? '-' : '';
  final int abs = cents.abs();
  return '$sign¥${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
}

// ---------------------------------------------------------------- 营收柱状图

void _revenue(QueryDao q, {required int fromDay, required int toDay}) {
  final MonthCompareWindow window = monthCompareWindow(toDay);
  final List<RevenueDay> wide = q.dailyRevenue(
    fromDay: window.priorFrom < fromDay ? window.priorFrom : fromDay,
    toDay: toDay,
  );
  final List<RevenueDay> rows = <RevenueDay>[
    for (final RevenueDay d in wide)
      if (d.day >= fromDay && d.day <= toDay) d,
  ];
  final List<RevenuePoint> weeks = buildRevenueSeries(
    rows: rows,
    fromDay: fromDay,
    toDay: toDay,
    bucket: RevenueBucket.week,
  );

  stdout.writeln('\n[近 30 天营收柱状图] 桶=${weeks.length}（按周聚合）');
  stdout.writeln('  ${'桶'.padRight(14)}${'净额'.padLeft(14)}  移动端柱高  桌面端柱高');

  int maxPos = 0;
  int maxNeg = 0;
  for (final RevenuePoint p in weeks) {
    maxPos = math.max(maxPos, p.netCents);
    maxNeg = math.max(maxNeg, -p.netCents);
  }
  final int span = maxPos + maxNeg;

  // 与 `RevenueChartCard` 一致的几何：高度 150（手机）/ 190（桌面），
  // 上方留 24 给金额标签、下方留 22 给日期、有负数时再多 26。
  double pxHeight(RevenuePoint p, double area) {
    if (span <= 0) return 0;
    return p.netCents.abs() * (area / span);
  }

  final double negBand = maxNeg > 0 ? 26 : 0;
  final double mobileArea = 150 - 24 - 22 - negBand;
  final double desktopArea = 190 - 24 - 22 - negBand;

  int invisibleMobile = 0;
  for (final RevenuePoint p in weeks) {
    final String label = '${p.startDay}~${p.endDay}';
    final double m = pxHeight(p, mobileArea);
    final double d = pxHeight(p, desktopArea);
    if (p.netCents != 0 && m < 1) invisibleMobile++;
    stdout.writeln(
      '  ${label.padRight(14)}${_money(p.netCents).padLeft(14)}'
      '  ${m.toStringAsFixed(1).padLeft(8)}px  ${d.toStringAsFixed(1).padLeft(8)}px',
    );
  }
  stdout.writeln(
    '  ⇒ 最大 ${_money(maxPos)} / 最小非零 '
    '${_money(weeks.map((RevenuePoint p) => p.netCents.abs()).where((int v) => v > 0).fold<int>(0, math.min))}'
    '；手机端 <1px 的柱子：$invisibleMobile / ${weeks.length}',
  );
}

// ---------------------------------------------------------------- 压货榜

void _stockTop(QueryDao q) {
  final StockTopSummary top = q.stockTop();
  stdout.writeln('\n[压货榜 Top${top.rows.length}]（RatioBar：比例照实算，最少 4px）');
  if (top.rows.isEmpty) {
    stdout.writeln('  （空）');
    return;
  }
  final int maxCents = top.rows.first.valueCents;
  // 卡内可用宽度：手机 328（360 - 16*2）、桌面 700
  const double mobileWidth = 328;
  const double desktopWidth = 700;
  int clamped = 0;
  stdout.writeln('  ${'商品'.padRight(12)}${'占用资金'.padLeft(14)}  手机宽  桌面宽');
  for (final StockValueRow row in top.rows) {
    final double ratio = maxCents <= 0 ? 0 : row.valueCents / maxCents;
    final double m = math.max(mobileWidth * ratio, 4);
    final double d = math.max(desktopWidth * ratio, 4);
    final bool hitFloor = mobileWidth * ratio < 4;
    if (hitFloor) clamped++;
    stdout.writeln(
      '  ${_clip(row.name, 12).padRight(12)}${_money(row.valueCents).padLeft(14)}'
      '  ${m.toStringAsFixed(1).padLeft(6)}px${d.toStringAsFixed(1).padLeft(7)}px'
      '${hitFloor ? '  ← 触底 4px' : ''}',
    );
  }
  stdout.writeln(
    '  ⇒ 触底 4px：$clamped / ${top.rows.length}；'
    '最大/最小 = ${top.rows.first.valueCents ~/ math.max(1, top.rows.last.valueCents)}:1',
  );
}

// ---------------------------------------------------------------- 应收应付

void _balance(QueryDao q) {
  final ReceivablesSummary r = q.receivablesSummary();
  final PayablesSummary p = q.payablesSummary();
  final int maxCents = math.max(r.totalCents, p.totalCents);
  stdout.writeln('\n[应收 / 应付横条]（只有两条，比例照实算）');
  stdout.writeln(
    '  应收 ${_money(r.totalCents)}（${r.partyCount} 家）'
    '  应付 ${_money(p.totalCents)}（${p.partyCount} 家）',
  );
  if (maxCents > 0) {
    stdout.writeln(
      '  ⇒ 手机端宽度：应收 ${(328 * r.totalCents / maxCents).toStringAsFixed(1)}px、'
      '应付 ${(328 * p.totalCents / maxCents).toStringAsFixed(1)}px'
      '（短的那条若 < 4px 会触底，但只有两条，肉眼仍能比）',
    );
  }
}

String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max - 1)}…';
