import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'revenue_chart.dart' show ChartBar, RevenueBarPainter;

/// 毛利趋势卡（N-a，2026-11-06）。
///
/// ## 这张卡的存在理由：数字必须能被拆开解释
///
/// 用户裁定（`docs/reply.md` §P2·3）：
///
/// > 销售收入、出库成本、退货退款和盘点损失不能混成一条没有区分的流水。
/// > 否则图表虽然能算出一个数字，却无法解释这个数字是怎样形成的。
///
/// 所以「看每天怎么算出来的」展开后**不是**一行金额，而是四个分量。用户看到
/// 「昨天毛利是负的」时，能立刻看出是「盘亏 ¥180」还是「退了 ¥500 的货」。
///
/// ## 与营收卡的关系：收入那一路是同一个数
///
/// 两张图的收入都来自 `QueryDao.dailyRevenue`，所以对得上账。
/// **口径分叉是账目类软件最坏的错**（纪律 18 同源）。
///
/// ## 间距约定同营收卡
///
/// `margin: EdgeInsets.zero`，间距由父级用 `SizedBox` 显式给。
class GrossMarginChartCard extends StatefulWidget {
  const GrossMarginChartCard({
    super.key,
    required this.rows,
    required this.fromDay,
    required this.toDay,
    this.mobileShell = false,
  });

  /// **已经查好的**按日毛利分项（稀疏）。
  ///
  /// ⚠️ 同营收卡：由父级传入，不在 `build()` 里查库（否则「点一下备份」这种
  /// 纯 UI 重建也会重跑一遍全历史聚合）。
  ///
  /// ⚠️ 可能含窗口外的天，卡片自己按 `fromDay..toDay` 裁。
  final List<GrossMarginDay> rows;

  final int fromDay;
  final int toDay;

  /// 手机壳：柱子矮一点、留白小一点
  final bool mobileShell;

  /// 窗口天数（只用于文案「最近 N 天」）
  int get days => toDay - fromDay + 1;

  @override
  State<GrossMarginChartCard> createState() => _GrossMarginChartCardState();
}

class _GrossMarginChartCardState extends State<GrossMarginChartCard> {
  bool _showDaily = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<GrossMarginDay> rows = <GrossMarginDay>[
      for (final GrossMarginDay d in widget.rows)
        if (d.day >= widget.fromDay && d.day <= widget.toDay) d,
    ];
    final List<GrossMarginPoint> weeks = buildGrossMarginSeries(
      rows: rows,
      fromDay: widget.fromDay,
      toDay: widget.toDay,
      bucket: RevenueBucket.week,
    );

    final int margin = weeks.fold(
      0,
      (int s, GrossMarginPoint p) => s + p.grossMarginCents,
    );
    final int revenue = weeks.fold(
      0,
      (int s, GrossMarginPoint p) => s + p.revenueCents,
    );
    // 「有没有做过生意」按经营活动算，不按毛利正负（同营收卡，用户审查 2026-10-30）
    final bool hasActivity = rows.isNotEmpty;
    final int activeDays = rows.where((GrossMarginDay d) => !d.isEmpty).length;

    return Card(
      key: const Key('overview-gross-margin-chart'),
      // ⚠️ 必须 zero（同营收卡，用户 2026-10-20 报过「两张卡片重叠」）
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(widget.mobileShell ? 14 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '最近 ${widget.days} 天赚了多少',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              // 口径写在卡上，用户能自己核对（「不撒谎」的一部分）
              '按周看。毛利 = 收入 − 卖出去的货的成本 − 盘点丢的货 − 退货退回来的'
              '成本。进货花的钱不算在这里。',
              style: TextStyle(
                height: 1.6,
                fontSize: 13,
                color: theme.textTheme.bodyMedium?.color,
              ),
            ),
            const SizedBox(height: 12),
            if (!hasActivity)
              _emptyHint(theme)
            else ...<Widget>[
              Semantics(
                label: _summaryText(margin, revenue, activeDays),
                child: SizedBox(
                  height: widget.mobileShell ? 150 : 190,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: RevenueBarPainter(
                      points: <ChartBar>[
                        for (final GrossMarginPoint p in weeks)
                          ChartBar.grossMargin(p),
                      ],
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
              Text(
                _summaryText(margin, revenue, activeDays),
                key: const Key('overview-gross-margin-summary'),
                style: const TextStyle(
                  height: 1.6,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('overview-gross-margin-daily-toggle'),
                  onPressed: () => setState(() => _showDaily = !_showDaily),
                  child: Text(_showDaily ? '收起每天的明细' : '看每天怎么算出来的'),
                ),
              ),
              if (_showDaily) _dailyBreakdown(theme, rows),
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
      key: const Key('overview-gross-margin-empty'),
      style: TextStyle(
        height: 1.7,
        fontSize: 15,
        color: theme.textTheme.bodySmall?.color,
      ),
    ),
  );

  /// 图下面那句人话总结（UI 原则：不让人自己从高度反推）。
  ///
  /// ⚠️ 「毛利率」对目标用户是黑话 ⇒ 说成「每收 ¥100 大约赚 ¥X」。
  String _summaryText(int margin, int revenue, int activeDays) {
    final String head =
        '最近 ${widget.days} 天毛利 ¥${Money.formatGrouped(margin)}';
    if (revenue <= 0) {
      // 收入 ≤ 0（没卖 / 卖的被退货抵完还倒贴）⇒ 比率没有意义，不能除
      return '$head —— 这段时间卖的钱都被退货抵完了，谈不上赚。';
    }
    final int per100 = ((margin * 100) / revenue).round();
    final String rate = '每收 ¥100 大约赚 ¥${Money.formatGrouped(per100)}';
    if (margin < 0) {
      // 负毛利要说人话：不是「赚了负的」，是**亏的**；并且给下一步（UI 原则：
      // 错误信息说「怎么办」）
      return '$head —— 这段时间是亏的（$rate）。'
          '点开下面的明细，看看是不是哪天盘亏或者退货多了。';
    }
    final int avg = activeDays == 0 ? 0 : (margin / activeDays).round();
    return '$head（$rate），平均每个有生意的日子 ¥${Money.formatGrouped(avg)}。';
  }

  /// 每天的分项明细 —— **裁定要求的「可解释性」就落在这里**。
  ///
  /// 一行毛利 + 一行分量。为 0 的分量不显示（盘亏不是天天有，摆一排 0 是噪音）。
  Widget _dailyBreakdown(ThemeData theme, List<GrossMarginDay> rows) {
    // 从最近一天往回排：用户最关心昨天、前天
    final List<GrossMarginDay> sorted = rows.toList()
      ..sort((GrossMarginDay a, GrossMarginDay b) => b.day.compareTo(a.day));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 4),
        for (final GrossMarginDay d in sorted)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    // ⚠️ 不用固定宽度（营收卡 2026-10-31 的教训：125% 缩放下
                    // 日期被折成两行）。日期自然宽度，毛利占剩余空间右对齐。
                    Text(
                      dayLabel(d.day),
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '毛利 ¥${Money.formatGrouped(d.grossMarginCents)}',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          // 负数红色（UI 原则：负库存同款处理）
                          color: d.grossMarginCents < 0
                              ? theme.colorScheme.error
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _breakdownLine(d),
                  style: TextStyle(
                    height: 1.6,
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

  /// 一行分量。**为 0 的分量省略**，收入恒显示（它是基准）。
  static String _breakdownLine(GrossMarginDay d) {
    final List<String> parts = <String>[
      '收入 ¥${Money.formatGrouped(d.revenueCents)}',
    ];
    if (d.saleCostCents != 0) {
      parts.add('卖货成本 ¥${Money.formatGrouped(d.saleCostCents)}');
    }
    if (d.stocktakeLossCents != 0) {
      parts.add('盘点损失 ¥${Money.formatGrouped(d.stocktakeLossCents)}');
    }
    if (d.returnCostAdjustCents != 0) {
      // 这个字段本身是**负的**（回吐成本）。说成「退货退回成本 ¥6」比
      // 「退货调整 ¥-6」好读 —— 减号已经由 `join(' − ')` 统一给出。
      parts.add('退货退回成本 ¥${Money.formatGrouped(-d.returnCostAdjustCents)}');
    }
    return '${parts.join(' − ')}。';
  }
}