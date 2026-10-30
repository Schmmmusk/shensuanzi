import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 近 30 天营收柱状图（提案 54 §三，第一批 UI）。
///
/// ## 为什么按**周**画，不是按天
///
/// 提案里的两条硬规则在 30 天上会打架：
///
/// - 「数字写在图上，不让人从高度反推」（第 1 条，**不能让**）
/// - 「一屏看完 ≤30 根」（第 2 条）
///
/// 30 根柱子在 900px 里每根只有 30px，金额标签（`¥1,234`）在 15sp 下要 60px 宽
/// —— 必然重叠。提案给的处理顺序是「**先调聚合粒度，而不是缩小字号或省略数字**」，
/// 所以这里按周聚合：近 30 天 = 5~6 根，每根标金额，字号 15sp 不打折。
///
/// 想看每天的明细 → 点「看每天的数字」展开列表（顺带解决读屏与「想抄数字」）。
///
/// ## 间距约定（⚠️ 用户 2026-10-20 报过「两张卡片重叠」）
///
/// 卡片一律 `margin: EdgeInsets.zero`，间距**由父级用 `SizedBox` 显式给**。
/// `Card` 的默认 margin 是 4，两个 zero-margin 卡之间若不留 `SizedBox`，
/// 视觉上就会贴在一起。
class RevenueChartCard extends StatefulWidget {
  const RevenueChartCard({
    super.key,
    required this.queries,
    this.mobileShell = false,
    this.days = 30,
  });

  final QueryDao queries;

  /// 手机壳：柱子矮一点、日期标签用短格式
  final bool mobileShell;

  /// 窗口天数（默认近 30 天）
  final int days;

  @override
  State<RevenueChartCard> createState() => _RevenueChartCardState();
}

class _RevenueChartCardState extends State<RevenueChartCard> {
  bool _showDaily = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 业务日按**本地日**算 —— 与 `documents.business_day` 同一口径
    final int toDay = businessDayOf(DateTime.now().millisecondsSinceEpoch);
    final int fromDay = toDay - (widget.days - 1);

    final List<RevenueDay> rows = widget.queries.dailyRevenue(
      fromDay: fromDay,
      toDay: toDay,
    );
    final List<RevenuePoint> weeks = buildRevenueSeries(
      rows: rows,
      fromDay: fromDay,
      toDay: toDay,
      bucket: RevenueBucket.week,
    );

    final int total = weeks.fold(0, (int s, RevenuePoint p) => s + p.netCents);
    final int activeDays = rows.where((RevenueDay d) => d.netCents != 0).length;
    final int avg = activeDays == 0 ? 0 : (total / activeDays).round();
    final int inTransit = rows.fold(
      0,
      (int s, RevenueDay d) => s + d.inTransitCount,
    );

    return Card(
      key: const Key('overview-revenue-chart'),
      // ⚠️ 必须 zero：默认 4 会和相邻卡片的 margin 叠加/挤压，看起来像「叠在一起」
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(widget.mobileShell ? 14 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('最近 ${widget.days} 天卖了多少', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              // 口径写在卡上，用户能自己核对（也是「不撒谎」的一部分）
              '按周看。销售额 = 店内销售 + 送货 − 退货；未签收的送货也算。',
              style: TextStyle(
                height: 1.6,
                fontSize: 13,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
            const SizedBox(height: 12),
            if (weeks.isEmpty || total == 0)
              _emptyHint(theme)
            else ...<Widget>[
              Semantics(
                label: _summaryText(total, avg, weeks.length),
                child: SizedBox(
                  height: widget.mobileShell ? 150 : 190,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: RevenueBarPainter(
                      points: weeks,
                      barColor: theme.colorScheme.primary,
                      negativeColor: theme.colorScheme.error,
                      labelColor:
                          theme.textTheme.bodyMedium?.color ?? Colors.black87,
                      axisColor: theme.dividerColor,
                      compact: widget.mobileShell,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // 规则 4：图下面必有一句人话总结（不是让人自己比）
              Text(
                _summaryText(total, avg, weeks.length),
                key: const Key('overview-revenue-summary'),
                style: const TextStyle(
                  height: 1.6,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (inTransit > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '其中 $inTransit 张送货还没签收（钱可能还没到手）',
                    style: TextStyle(
                      height: 1.6,
                      fontSize: 13,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('overview-revenue-daily-toggle'),
                  onPressed: () => setState(() => _showDaily = !_showDaily),
                  child: Text(_showDaily ? '收起每天的数字' : '看每天的数字'),
                ),
              ),
              if (_showDaily) _dailyList(theme, rows, fromDay, toDay),
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyHint(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Text(
      '最近 ${widget.days} 天还没有销售记录。开一单之后这里就有图了。',
      key: const Key('overview-revenue-empty'),
      style: TextStyle(
        height: 1.7,
        fontSize: 15,
        color: theme.textTheme.bodySmall?.color,
      ),
    ),
  );

  String _summaryText(int total, int avg, int weeks) {
    final String head = '最近 ${widget.days} 天合计 ¥${Money.formatGrouped(total)}';
    if (total == 0) return '$head。';
    return '$head，平均每个有生意的日子 ¥${Money.formatGrouped(avg)}'
        '（共 $weeks 周）。';
  }

  /// 每天的数字（可展开）—— 读屏天然可读，也方便用户抄下来对账。
  Widget _dailyList(
    ThemeData theme,
    List<RevenueDay> rows,
    int fromDay,
    int toDay,
  ) {
    // 从最近一天往回排：用户最关心昨天、前天
    final List<RevenueDay> sorted = rows.toList()
      ..sort((RevenueDay a, RevenueDay b) => b.day.compareTo(a.day));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 4),
        for (final RevenueDay d in sorted)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 92,
                  child: Text(
                    dayLabel(d.day),
                    style: TextStyle(
                      fontSize: 14,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '¥${Money.formatGrouped(d.netCents)}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (d.inTransitCount > 0)
                  Text(
                    '含未签收 ${d.inTransitCount}',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 柱状图绘制。
///
/// 只做两件事：按 `netCents` 画柱、把金额写在柱子上。
/// **不画网格线**（对中老年是噪音）、**不用渐变色**（规则 3：只用两种颜色）。
class RevenueBarPainter extends CustomPainter {
  RevenueBarPainter({
    required this.points,
    required this.barColor,
    required this.negativeColor,
    required this.labelColor,
    required this.axisColor,
    this.compact = false,
  });

  final List<RevenuePoint> points;
  final Color barColor;

  /// 负数（退货多于销售的那一周）用的颜色 —— 就是规则 3 说的「第二种颜色」
  final Color negativeColor;
  final Color labelColor;
  final Color axisColor;
  final bool compact;

  /// 柱子上方留给金额标签的高度
  static const double _labelBand = 24;

  /// 柱子下方留给日期标签的高度
  static const double _axisBand = 22;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    int maxPos = 0;
    int maxNeg = 0;
    for (final RevenuePoint p in points) {
      maxPos = math.max(maxPos, p.netCents);
      maxNeg = math.max(maxNeg, -p.netCents);
    }
    final int span = maxPos + maxNeg;
    if (span <= 0) return;

    // 负数柱子的金额标签要画在柱子**下方**，得单独给它一条带子 ——
    // 否则它会压到日期标签上（第一版就是直接画，渲染出来才发现）。
    final double negLabelBand = maxNeg > 0 ? 26 : 0;
    final double barArea = size.height - _labelBand - _axisBand - negLabelBand;
    if (barArea <= 0) return;

    // 有负数时把基线抬高，否则基线贴底
    final double baselineY = _labelBand + barArea * (maxPos / span);
    final double unit = barArea / span; // 每一「分」占多少像素

    final Paint axis = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, baselineY), Offset(size.width, baselineY), axis);

    final double slot = size.width / points.length;
    final double barWidth = math.min(slot * 0.56, compact ? 36 : 56);

    for (int i = 0; i < points.length; i++) {
      final RevenuePoint p = points[i];
      final double centerX = slot * i + slot / 2;
      final double h = p.netCents.abs() * unit;
      final bool negative = p.netCents < 0;

      if (h > 0) {
        final Rect rect = negative
            ? Rect.fromLTWH(centerX - barWidth / 2, baselineY, barWidth, h)
            : Rect.fromLTWH(centerX - barWidth / 2, baselineY - h, barWidth, h);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          Paint()..color = negative ? negativeColor : barColor,
        );
      }

      // 金额写在柱子外侧（正数在上、负数在下）—— 规则 1：不让人从高度反推
      //
      // ⚠️ 正负两种要用**不同的对齐**：正数让文字**底边**贴柱顶（往上长），
      // 负数让文字**顶边**贴柱底（往下长）。第一版两者都用 `bottomForAbove`，
      // 结果负数的金额直接画进了柱子里面（渲染出来才发现）。
      _drawText(
        canvas,
        '¥${Money.formatGrouped(p.netCents.abs())}',
        centerX,
        negative ? baselineY + h + 2 : baselineY - h - 4,
        size: compact ? 13 : 15,
        bold: true,
        align: negative ? _Align.top : _Align.bottomForAbove,
      );

      // 日期（或周范围）写在轴下方
      _drawText(
        canvas,
        _rangeLabel(p, compact: compact || slot < 96),
        centerX,
        size.height - _axisBand + 4,
        size: 13,
        bold: false,
        align: _Align.top,
        color: labelColor.withValues(alpha: 0.72),
      );
    }
  }

  /// `10/21–10/27`（或窄的时候只写 `10/21`）。
  ///
  /// ⚠️ 用 **`startDay`/`endDay`** 而不是「周一起 + 6 天」：窗口的第一周
  /// 可能不是从周一开始的（`buildRevenueSeries` 会把 `startDay` 夹到窗口内），
  /// 按日历硬算会标出一个根本没统计的日期。
  String _rangeLabel(RevenuePoint p, {required bool compact}) {
    final String start = _monthDay(p.startDay);
    if (compact || p.startDay == p.endDay) return start;
    return '$start–${_monthDay(p.endDay)}';
  }

  String _monthDay(int day) {
    final DateTime date = dayToDate(day);
    return '${date.month}/${date.day}';
  }

  void _drawText(
    Canvas canvas,
    String text,
    double centerX,
    double y, {
    required double size,
    required bool bold,
    required _Align align,
    Color? color,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
          color: color ?? labelColor,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final double dx = centerX - painter.width / 2;
    final double dy = align == _Align.top ? y : y - painter.height;
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant RevenueBarPainter old) =>
      old.points != points ||
      old.barColor != barColor ||
      old.negativeColor != negativeColor ||
      old.labelColor != labelColor ||
      old.axisColor != axisColor ||
      old.compact != compact;
}

enum _Align {
  /// 文字**底边**贴 `y`（画在柱子上方时用）
  bottomForAbove,

  /// 文字**顶边**贴 `y`（画在轴下方时用）
  top,
}
