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
    required this.rows,
    required this.fromDay,
    required this.toDay,
    this.mobileShell = false,
  });

  /// **已经查好的**按日营收（稀疏：只含有经营活动的那几天）。
  ///
  /// ⚠️ 由父级传入而不是自己查（用户审查 2026-10-30）：`build()` 里直接查库，
  /// 会让「点一下备份」这种纯 UI 状态变化也重跑一遍全历史聚合。
  /// 概览页把整页数据算一次、缓存住，重建时直接复用。
  ///
  /// ⚠️ **可能包含窗口外的天**（父级为「月度对比」一次查够两个窗口）。
  /// 卡片自己按 `fromDay..toDay` 裁 —— 因为「平均每个有生意的日子」
  /// 和「在途 N 张」都是直接遍历这个列表算的，混进窗口外的天会失真。
  /// 裁在卡片里而不是调用方，是为了**不管谁传进来都不会算错**。
  final List<RevenueDay> rows;

  final int fromDay;
  final int toDay;

  /// 手机壳：柱子矮一点、日期标签用短格式
  final bool mobileShell;

  /// 窗口天数（由 `fromDay..toDay` 推出，只用于文案「最近 N 天」）
  int get days => toDay - fromDay + 1;

  @override
  State<RevenueChartCard> createState() => _RevenueChartCardState();
}

class _RevenueChartCardState extends State<RevenueChartCard> {
  bool _showDaily = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<RevenueDay> rows = <RevenueDay>[
      for (final RevenueDay d in widget.rows)
        if (d.day >= widget.fromDay && d.day <= widget.toDay) d,
    ];
    final List<RevenuePoint> weeks = buildRevenueSeries(
      rows: rows,
      fromDay: widget.fromDay,
      toDay: widget.toDay,
      bucket: RevenueBucket.week,
    );

    final int total = weeks.fold(0, (int s, RevenuePoint p) => s + p.netCents);
    // **有没有做过生意**，不是「净额是不是 0」（用户审查 2026-10-30）：
    // 卖了 ¥500 又退了 ¥500 ⇒ 净额 0，但那天当然有生意。
    final bool hasActivity = rows.isNotEmpty;
    // 分母同样按经营活动算 —— 用净额判会把「当天卖光又全退」的日子漏掉，
    // 于是「平均每个有生意的日子」被算高。
    final int activeDays = rows.where((RevenueDay d) => !d.isEmpty).length;
    final int avg = activeDays == 0 ? 0 : (total / activeDays).round();
    final int inTransit = rows.fold(
      0,
      (int s, RevenueDay d) => s + d.inTransitCount,
    );
    final int inTransitCents = rows.fold(
      0,
      (int s, RevenueDay d) => s + d.inTransitCents,
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
            if (!hasActivity)
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
                    // 只报张数不够：¥100 的在途和 ¥100,000 的在途，那句话一模一样
                    '其中 $inTransit 张送货还没签收，共 '
                    '¥${Money.formatGrouped(inTransitCents)}（钱可能还没到手）',
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
              if (_showDaily) _dailyList(theme, rows),
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
    if (total == 0) {
      // 净额为 0 但**有经营活动**：卖的和退的一样多。
      // 不能说「没有销售记录」—— 那是另一回事（用户审查 2026-10-30）。
      return '$head —— 这段时间卖的和退的正好一样多，净额是 0。';
    }
    return '$head，平均每个有生意的日子 ¥${Money.formatGrouped(avg)}'
        '（共 $weeks 周）。';
  }

  /// 每天的数字（可展开）—— 读屏天然可读，也方便用户抄下来对账。
  Widget _dailyList(ThemeData theme, List<RevenueDay> rows) {
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
                // ⚠️ **不许用固定宽度**（2026-10-31 真机截图发现）：
                // 界面缩放 125% 时 14sp 的 `2026-10-20` 比 92px 宽，
                // 日期被折成「2026-10-2」+「0」两行 —— 完全没法读。
                // 日期用自然宽度（不折行），金额占剩余空间右对齐。
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
                    // 「含未签收」并进金额那一格：单独一列在放大后会把它挤出去
                    d.inTransitCount > 0
                        ? '¥${Money.formatGrouped(d.netCents)}'
                              '（含未签收 ${d.inTransitCount}）'
                        : '¥${Money.formatGrouped(d.netCents)}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 柱子上方的金额文字。
///
/// ## 两个决定（用户审查 2026-10-30）
///
/// 1. **负数带负号**：柱子朝下 + 变红还不够 —— 金额标签本身要能独立表达数值，
///    不能让用户靠「柱子在哪边」推断正负。
/// 2. **≥¥100 时只写整数元**：图上比的是量级，分位是噪音；而且 `.00` 三个字符
///    会让标签在窄窗口里互相压住（30 天 × 5~6 根时每根只有 50~60px）。
///    **这是改格式，不是缩字号** —— 15sp 不打折。
///
/// [withCurrency] 为 `false` 时省略 `¥`（窄窗口用；卡片标题与总结句里都有单位）。
String barAmountLabel(
  int cents, {
  bool withCurrency = true,
  bool withSeparators = true,
}) {
  final String sign = cents < 0 ? '−' : '';
  final String symbol = withCurrency ? '¥' : '';
  final int abs = cents.abs();
  final String body = abs >= 100
      // ≥¥100 只写整数元：分位是噪音，且 `.00` 会挤掉邻居
      ? Money.formatGrouped(
          (abs ~/ 100) * 100,
        ).replaceFirst(RegExp(r'\.00$'), '')
      : Money.formatGrouped(abs);
  return '$sign$symbol${withSeparators ? body : body.replaceAll(',', '')}';
}

/// 柱子上到底写哪种写法：**先省千分位，最后才省 ¥**。
///
/// ## 为什么要抽成纯函数
///
/// 这段「退让顺序」是产品规则（数字必须带单位），但它**按实际字体宽度**决策，
/// 而画布上的文字在 widget 测试里读不出来。抽出来之后可以用假的 `measure`
/// 把优先级钉住 —— 不需要真的渲染。
///
/// ## 顺序（2026-10-31 真机定）
///
/// 1. `¥12,600` —— 最好
/// 2. `¥12600` —— 省千分位
/// 3. `12600` —— 实在放不下才省 ¥（数字失去单位，是**最后**的退让）
///
/// 从前手机（compact）直接从第 3 档起步，标签成了「534」「0.00」——
/// 数字失去单位，用户得回头看总结句才知道那是钱。
String chooseBarLabel(
  int cents, {
  required double slot,
  required double Function(String text) measure,
}) {
  final double limit = slot - 6;
  final String full = barAmountLabel(cents);
  if (measure(full) <= limit) return full;
  final String noSeparator = barAmountLabel(cents, withSeparators: false);
  if (measure(noSeparator) <= limit) return noSeparator;
  return barAmountLabel(cents, withCurrency: false, withSeparators: false);
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

    // 负数柱子的金额标签要画在柱子**下方**，得单独给它一条带子 ——
    // 否则它会压到日期标签上（第一版就是直接画，渲染出来才发现）。
    final double negLabelBand = maxNeg > 0 ? 26 : 0;
    final double barArea = size.height - _labelBand - _axisBand - negLabelBand;
    if (barArea <= 0) return;

    // 有负数时把基线抬高，否则基线贴底。
    // ⚠️ `span == 0`（这段时间卖的和退的正好抵消）时**不能提前 return** ——
    // 那会画出一块空白，用户以为图坏了。基线照画、金额照写「¥0」。
    final double baselineY = span <= 0
        ? _labelBand + barArea
        : _labelBand + barArea * (maxPos / span);
    final double unit = span <= 0 ? 0 : barArea / span;

    final Paint axis = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, baselineY), Offset(size.width, baselineY), axis);

    final double slot = size.width / points.length;
    // 上限 56 太细：5 根柱子在 1600px 宽的卡里格位约 317px，56px 只占 17.6%，
    // 看起来像细棍（2026-10-31 真机截图实测）。72px 与金额标签宽度接近，
    // 视觉上更「实」，同时仍远小于格位、不会连成一片。
    final double barWidth = math.min(slot * 0.56, compact ? 36 : 72);

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
      //
      // ⚠️ **按实际字体量宽度**（用户审查 2026-10-30）：光靠「缩字号」或
      // 「窗口测试不报错」都不能证明标签没互相压住 —— 那是画布上的事，
      // Flutter 的布局异常看不到。这里先排一次版，宽了就退到**无千分位**写法
      // （还是 15sp，只是少两个逗号）。
      // 退让顺序见 `chooseBarLabel`：先省千分位，最后才省 ¥。
      // 宽度按**实际字体**量 —— 标签是画布上的字，Flutter 的布局检查看不见它。
      final TextPainter label = _layout(
        chooseBarLabel(
          p.netCents,
          slot: slot,
          measure: (String text) => _layout(text, 15).width,
        ),
        15,
      );
      _paint(
        canvas,
        label,
        centerX,
        negative ? baselineY + h + 2 : baselineY - h - 4,
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
    _paint(
      canvas,
      _layout(text, size, bold: bold, color: color),
      centerX,
      y,
      align: align,
    );
  }

  TextPainter _layout(
    String text,
    double size, {
    bool bold = false,
    Color? color,
  }) => TextPainter(
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

  void _paint(
    Canvas canvas,
    TextPainter painter,
    double centerX,
    double y, {
    required _Align align,
  }) {
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
