import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 「压货最多的 10 个商品」（提案 54 §三「第三优先」）。
///
/// ## 为什么按**占用资金**排，不按数量
///
/// 用户举的例子：500 个、20 箱、80 千克 —— 数字大小说明不了谁压货多
/// （单位不同、单价差异巨大）。按数量排会把「一箱牙签」排在「十台电机」前面，
/// **误导经营决策**。
///
/// 标题也照实写「按占用资金」，不写「库存最多」。
///
/// ## 口径要在卡上说清
///
/// `占用资金 = SUM(stock_ledger.total_cost)` —— **历史加权平均成本**，
/// 不是「最近进价 × 数量」（`docs/data_model.md` §AA·四 / AA-4 要求标明）。
///
/// ## 间距约定（⚠️ 用户 2026-10-20 报过「两张卡片重叠」）
///
/// `margin: EdgeInsets.zero`，与相邻卡片的间距**由父级 `SizedBox` 给**。
class StockTopCard extends StatelessWidget {
  const StockTopCard({super.key, required this.rows, this.mobileShell = false});

  final List<StockValueRow> rows;
  final bool mobileShell;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final int maxValue = rows
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
              '压货最多的 ${rows.length} 个商品',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '按占用资金排（不是数量）。金额按历史平均成本算，'
              '不是最近一次进价。',
              style: TextStyle(
                height: 1.6,
                fontSize: 13,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
            const SizedBox(height: 12),
            for (int i = 0; i < rows.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: 10),
              _row(theme, rows[i], maxValue),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, StockValueRow row, int maxValue) {
    // 至少留 4% —— 否则最后一名会画成一条看不见的线，用户以为没画
    final double ratio = maxValue <= 0
        ? 0
        : (row.valueCents / maxValue).clamp(0.04, 1.0).toDouble();
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
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Stack(
                  children: <Widget>[
                    Container(height: 10, color: theme.dividerColor),
                    FractionallySizedBox(
                      widthFactor: ratio,
                      child: Container(
                        height: 10,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
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
