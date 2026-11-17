import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'ratio_bar.dart';

/// 「这个月和上个月」横条对比（提案 54 §六 第三批的月度对比）。
///
/// ## 为什么比**同期**，不比整月
///
/// 今天是 10 月 8 日，拿「本月 1–8 日」去比「上月 1–30 日」，数字必然难看 ——
/// 那不是生意变差，是**窗口不等长**。所以上月只取同样天数（`monthCompareWindow`），
/// 并且卡片上把两段日期都印出来，用户能自己核对。
///
/// ## 为什么不上色
///
/// 「比上月多」是好事，但**不用红/绿**：本仓的红绿约定是给股价涨跌的
/// （见 `<regional_conventions>`），营收不是股票 —— 上红色会让用户以为
/// 「涨了要小心」。只用字重表达。
///
/// ## 间距约定（⚠️ 用户 2026-10-20 报过「两张卡片重叠」）
///
/// `margin: EdgeInsets.zero`，与相邻卡片的间距**由父级 `SizedBox` 给**。
class MonthCompareCard extends StatelessWidget {
  const MonthCompareCard({
    super.key,
    required this.compare,
    this.mobileShell = false,
    this.usePercent = false,
  });

  final MonthCompare compare;
  final bool mobileShell;

  /// 变化量用**百分数**（`+595%`）还是**倍数**（`6.9 倍`）。
  ///
  /// 默认倍数（2026-10-31 真机）：基期很小时百分比会爆炸 ——
  /// 上月 ¥140、本月 ¥973 显示「+595%」，看着像涨了六倍，
  /// 其实只是上月基数太小。倍数说法更贴近个体户的直觉。
  final bool usePercent;

  @override
  Widget build(BuildContext context) {
    // 两段都没有经营活动 ⇒ 整张卡不出现（页面上少一块噪音）
    if (compare.isEmpty) return const SizedBox.shrink();

    final ThemeData theme = Theme.of(context);
    final MonthCompareWindow w = compare.window;
    final int maxCents = compare.currentCents > compare.priorCents
        ? compare.currentCents
        : compare.priorCents;

    return Card(
      key: const Key('overview-month-compare'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(mobileShell ? 14 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('这个月和上个月', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              // 两张卡都在说「营收」，必须说清不是同一个区间，
              // 否则用户会问「为什么上面写 ¥X、这里写 ¥Y，是不是算错了」
              '按日历月比，和上面「最近 30 天」不是同一个区间。'
              '两段天数一样，比的是同期。',
              style: TextStyle(
                height: 1.6,
                fontSize: 13,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
            const SizedBox(height: 12),
            _row(
              context,
              theme,
              key: 'overview-month-current',
              label: '本月',
              range: _rangeLabel(w.currentFrom, w.currentTo),
              cents: compare.currentCents,
              maxCents: maxCents,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 10),
            _row(
              context,
              theme,
              key: 'overview-month-prior',
              label: '上月同期',
              range: _rangeLabel(w.priorFrom, w.priorTo),
              cents: compare.priorCents,
              maxCents: maxCents,
              // ⚠️ **不能**用 `dividerColor`：那正是 `RatioBar` 的**轨道色**，
              // 填充和轨道同色 ⇒ 条长完全看不出来（2026-10-31 真机截图发现：
              // ¥973 对 ¥140，两条看起来一样长）。
              // 用 primary 的浅色：同一色系、弱化，但仍与轨道分得开。
              color: theme.colorScheme.primary.withValues(alpha: 0.38),
            ),
            const SizedBox(height: 12),
            // 规则 4：下面必有一句人话总结（不是让人自己比两条的长度）
            Text(
              _summary(compare, usePercent: usePercent),
              key: const Key('overview-month-summary'),
              style: const TextStyle(
                height: 1.6,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 区间至少留这么宽（逻辑像素）：再窄就只剩省略号，用户看不出那是哪一段日期。
  static const double _minRangeWidth = 56;

  /// 量一段**单行**文本的宽度（用当前 `TextScaler`，所以系统字号 200% 也算得准）。
  ///
  /// 为什么量而不是猜断点：标签与金额的字数会变（`¥190.00` 与 `¥123,456.00` 差一倍），
  /// 写死「宽度 < 200 就换行」在某个金额上必然失效。
  static double _textWidth(String text, TextStyle style, TextScaler scaler) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final double width = painter.width;
    painter.dispose();
    return width;
  }

  Widget _row(
    BuildContext context,
    ThemeData theme, {
    required String key,
    required String label,
    required String range,
    required int cents,
    required int maxCents,
    required Color color,
  }) {
    const TextStyle labelStyle = TextStyle(height: 1.5, fontSize: 15);
    const TextStyle moneyStyle = TextStyle(
      height: 1.5,
      fontSize: 16,
      fontWeight: FontWeight.w600,
    );
    const TextStyle rangeStyle = TextStyle(height: 1.5, fontSize: 13);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final String money = '¥${Money.formatGrouped(cents)}';

    return Column(
      key: Key(key),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // **2026-11-17（用户真机日志）**：原来这里是一行
        // 「标签 + 区间(Expanded) + 金额」，标签与金额**都不可压缩**。
        // 窄窗口（卡片 154 逻辑宽）+ 大字时，光「上月同期」+「¥7,930.00」就超宽，
        // 区间已经挤到 0 宽也救不回来 ⇒ `RenderFlex overflowed by 17 pixels`，
        // 截图上金额右侧被黄黑条切掉 —— **账上的钱看不全**。
        //
        // 现在的判据：量出「标签 + 金额」的真实宽度，**金额永远完整一行**，
        // 放不下就把金额落到第二行（区间继续在它上面的那一行吃省略号）。
        // 不给金额加 `FittedBox(scaleDown)`：金额缩小到读不清，比换行更糟。
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final double need =
                _textWidth(label, labelStyle, scaler) +
                _textWidth(money, moneyStyle, scaler) +
                14; // 6 + 8 两个间距
            if (box.maxWidth >= need + _minRangeWidth) {
              return Row(
                children: <Widget>[
                  Text(label, style: labelStyle),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      range,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: rangeStyle.copyWith(
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(money, style: moneyStyle),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(label, style: labelStyle),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        range,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: rangeStyle.copyWith(
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(money, style: moneyStyle),
              ],
            );
          },
        ),
        const SizedBox(height: 3),
        RatioBar(
          cents: cents,
          maxCents: maxCents,
          color: color,
          height: 10,
          barKey: Key('$key-bar'),
        ),
      ],
    );
  }

  /// `10/1–10/31`（同年同月不重复写月份）。
  String _rangeLabel(int from, int to) {
    final DateTime a = dayToDate(from);
    final DateTime b = dayToDate(to);
    if (a.month == b.month) return '${a.month}/${a.day}–${b.day}';
    return '${a.month}/${a.day}–${b.month}/${b.day}';
  }

  /// 一句人话。
  ///
  /// 三个分支的判据都是「**有没有经营活动**」，不是「净额是不是 0」：
  /// 卖了 ¥500 又退了 ¥500 的那天净额是 0，但它确实做了生意，
  /// 说成「还没有生意」就是撒谎（与 `RevenueDay.isEmpty` 同一个教训）。
  String _summary(MonthCompare c, {required bool usePercent}) {
    if (!c.priorHasActivity) {
      // 上月同期为 0 时**没有百分比**（`percent` 返回 null）——
      // 界面不能写「+∞%」或「+100%」，那是编出来的数
      return '上月同期还没有生意 —— 这个月是第一次有进账，没法和上月比。';
    }
    if (!c.currentHasActivity) {
      return '这个月还没有生意（上月同期 '
          '¥${Money.formatGrouped(c.priorCents)}）。';
    }
    if (c.deltaCents == 0) {
      return '和上月同期一样多（¥${Money.formatGrouped(c.currentCents)}）。';
    }
    // 净额归零（卖了又全退）时，「是上月的 0 倍」这种话没有意义
    if (c.currentCents == 0) {
      return '这个月净额是 0（上月同期 '
          '¥${Money.formatGrouped(c.priorCents)}）。';
    }
    final String detail = usePercent ? _percentText(c) : _ratioText(c);
    return c.deltaCents > 0
        ? '比上月同期多 ¥${Money.formatGrouped(c.deltaCents)}$detail。'
        : '比上月同期少 ¥${Money.formatGrouped(c.deltaCents.abs())}$detail。';
  }

  /// `（+595%）`
  String _percentText(MonthCompare c) {
    final int? pct = c.percent;
    if (pct == null) return '';
    return '（${pct > 0 ? '+' : '−'}${pct.abs()}%）';
  }

  /// `，是上月的 6.9 倍`
  ///
  /// 保留一位小数；≥10 倍就取整（`12 倍` 比 `11.8 倍` 好读）。
  /// 末尾的 `.0` 去掉 —— 「7 倍」比「7.0 倍」顺眼。
  String _ratioText(MonthCompare c) {
    final double ratio = c.currentCents / c.priorCents;
    final String value = ratio >= 10
        ? ratio.round().toString()
        : ratio.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
    return '，是上月的 $value 倍';
  }
}
