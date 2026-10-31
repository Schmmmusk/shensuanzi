import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'ratio_bar.dart';

/// 「压货最多的 10 个商品」（提案 54 §三「第三优先」）。
///
/// ## 为什么按**占用资金**排，不按数量
///
/// 用户举的例子：500 个、20 箱、80 千克 —— 数字大小说明不了谁压货多
/// （单位不同、单价差异巨大）。按数量排会把「一箱牙签」排在「十台电机」前面，
/// **误导经营决策**。标题也照实写「按占用资金」，不写「库存最多」。
///
/// ## 成本三态（用户审查 2026-10-30）
///
/// 只有 `cost > 0` 的商品进榜。另外两种**不假装它们占用 ¥0**：
///
/// - **待校准**（`cost == 0`，期初录入没记进价）：显示 ¥0 会让用户以为
///   「这货不要钱」。库存页早就有「待校准」这个词，这里沿用同一套语言。
/// - **负成本**（`cost < 0`，超卖 / 退货摊穿）：横条画成负数没有意义。
///
/// 两种都只报**数量**，放在卡底一行提示里。
///
/// ## 间距约定（⚠️ 用户 2026-10-20 报过「两张卡片重叠」）
///
/// `margin: EdgeInsets.zero`，与相邻卡片的间距**由父级 `SizedBox` 给**。
class StockTopCard extends StatelessWidget {
  const StockTopCard({
    super.key,
    required this.summary,
    this.mobileShell = false,
  });

  final StockTopSummary summary;
  final bool mobileShell;

  @override
  Widget build(BuildContext context) {
    if (summary.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final List<StockValueRow> rows = summary.rows;
    final int maxValue = rows.isEmpty
        ? 0
        : rows
              .map((StockValueRow r) => r.valueCents)
              .reduce((int a, int b) => a > b ? a : b);

    return Card(
      key: const Key('overview-stock-top'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(mobileShell ? 14 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              rows.isEmpty ? '压货榜' : '压货最多的 ${rows.length} 个商品',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '按占用资金排（不是数量）。金额按历史平均成本算，不是最近一次进价。',
              style: TextStyle(
                height: 1.6,
                fontSize: 13,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  '目前没有「成本已知且有库存」的商品，排不出榜。',
                  style: TextStyle(
                    height: 1.7,
                    fontSize: 15,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              )
            else ...<Widget>[
              const SizedBox(height: 12),
              for (int i = 0; i < rows.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 10),
                _row(theme, rows[i], maxValue),
              ],
            ],
            // 两种「不能进榜」的，各说一句 —— 数量照报，但不假装有金额
            if (summary.uncalibratedCount > 0)
              _notice(
                theme,
                key: 'overview-stock-top-uncalibrated',
                text:
                    '另有 ${summary.uncalibratedCount} 种商品成本未校准'
                    '（期初没记进价），暂不参与排名 —— 下次进货会自动校准。',
              ),
            if (summary.negativeCostCount > 0)
              _notice(
                theme,
                key: 'overview-stock-top-negative',
                text:
                    '还有 ${summary.negativeCostCount} 种商品成本为负'
                    '（超卖或退货把成本摊穿了），见「库存」页。',
              ),
          ],
        ),
      ),
    );
  }

  Widget _notice(
    ThemeData theme, {
    required String key,
    required String text,
  }) => Padding(
    key: Key(key),
    padding: const EdgeInsets.only(top: 10),
    child: Text(
      text,
      style: TextStyle(
        height: 1.6,
        fontSize: 13,
        color: theme.textTheme.bodySmall?.color,
      ),
    ),
  );

  Widget _row(ThemeData theme, StockValueRow row, int maxValue) {
    return Column(
      key: Key('overview-stock-top-${row.productId}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                row.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(height: 1.5, fontSize: 15),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '¥${Money.formatGrouped(row.valueCents)}',
              style: const TextStyle(
                height: 1.5,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Row(
          children: <Widget>[
            Expanded(
              child: RatioBar(
                cents: row.valueCents,
                maxCents: maxValue,
                color: theme.colorScheme.primary,
                height: 10,
                barKey: Key('overview-stock-top-${row.productId}-bar'),
              ),
            ),
            const SizedBox(width: 8),
            // 数量 + 单位：**各自单位照实写，不换算、不跨商品求和**
            Text(
              '${row.quantity} ${row.unit}',
              style: TextStyle(
                height: 1.4,
                fontSize: 13,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
