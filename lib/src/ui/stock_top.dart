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
    this.onOpenAll,
    this.totalCount,
  });

  final StockTopSummary summary;
  final bool mobileShell;

  /// 「查看全部」的出口（2026-11-01，用户裁定 A1）。
  ///
  /// `null` = 不显示按钮。概览页传它（点一下切到库存页 —— 完整榜就在那一页顶部），
  /// 库存页自己**不传**（它已经是全部了）。
  final VoidCallback? onOpenAll;

  /// 完整榜的总行数（用于「查看全部 N 个」的 N）。
  ///
  /// 概览页只渲染前 3 行，但按钮上要写「全部有几个」—— 所以这个数必须
  /// 由调用方给（`summary.rows.length` 在概览页是截断后的 3）。
  /// `null` = 与 [summary] 一致。
  final int? totalCount;

  @override
  Widget build(BuildContext context) {
    if (summary.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final List<StockValueRow> rows = summary.rows;
    // ⚠️ 2026-11-26 真机 bug：金额被折成两行（`¥1,186.` / `81`）。
    // 根因是**测量用的字体不是渲染用的字体** —— `TextPainter` 没带
    // `fontFamily`，用的是 Roboto 的度量，而真机主题是微软雅黑（更宽），
    // 于是量出来的列宽比实际需要的小，`Text` 就换行了。
    // 现在两个样式都从 `theme.textTheme` 派生（带 family），测量与渲染**同一份**。
    final TextStyle amountStyle =
        (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.5,
        );
    final TextStyle quantityStyle =
        (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
          fontSize: 13,
          height: 1.4,
        );
    final double trailingColumn = _trailingColumnWidth(
      context,
      rows,
      amountStyle,
      quantityStyle,
    );
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
              // 2026-11-26（提案 §2.1）：「数量」原来各占各的自然宽 ⇒
              // 每行的柱子**可用宽度不同**，柱长根本不可比（金额看着"每行位置都不同"
              // 是同一个病根的另一面）。这里先量出所有行里最宽的那条数量文案，
              // 统一给一个列宽：柱子在同一个 x 结束，金额与数量同列右对齐。
              for (int i = 0; i < rows.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 10),
                _row(
                  theme,
                  rows[i],
                  maxValue,
                  trailingColumn,
                  amountStyle,
                  quantityStyle,
                ),
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
            // 「查看全部」只在**概览页**出现（库存页自己就是全部，不传它）。
            // 文字用「全部 N 个」而不是「查看更多」：用户要的是数量感
            //（知道还有多少个没看到），不是一个模糊的方向词。
            if (onOpenAll != null) ...<Widget>[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('stock-top-open-all'),
                  onPressed: onOpenAll,
                  child: Text(
                    (totalCount ?? rows.length) > rows.length
                        ? '查看全部 ${totalCount ?? rows.length} 个'
                        : '去库存页看',
                  ),
                ),
              ),
            ],
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

  /// 所有行共用的**右侧数字列**宽度（逻辑像素）。
  ///
  /// 金额（16px w600）与数量（13px）**共用这一列**：金额右对齐在列里 ⇒
  /// 三行的个位对齐、可以直接上下比较；数量也右对齐在同一列 ⇒ 视觉成一条线。
  ///
  /// ⚠️ 2026-11-26 之前这里是 `Flexible`（2026-11-18 为窄窗加的）：
  /// `Flexible` 会跟 `Expanded(name)` **平分**剩余空间，而 `Text` 只取自身宽度、
  /// 从分到的框**左边**开始画 ⇒ 金额被顶到卡片中间、各行的右边缘还参差
  ///（截图 `20261126-压货榜-数量列对齐-125%.png` 之前那一版就是这个样子）。
  /// 改成**测量出来的固定列宽**后，柱子在同一个 x 结束、柱长才可比。
  double _trailingColumnWidth(
    BuildContext context,
    List<StockValueRow> rows,
    TextStyle amountStyle,
    TextStyle quantityStyle,
  ) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    double measure(String text, TextStyle style) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final double width = painter.width;
      painter.dispose();
      return width;
    }

    double widest = 0;
    for (final StockValueRow row in rows) {
      final double amount = measure(
        '¥${Money.formatGrouped(row.valueCents)}',
        amountStyle,
      );
      final double quantity = measure(
        '${row.quantity} ${row.unit}',
        quantityStyle,
      );
      if (amount > widest) widest = amount;
      if (quantity > widest) widest = quantity;
    }
    return widest + 2;
  }

  Widget _row(
    ThemeData theme,
    StockValueRow row,
    int maxValue,
    double trailingColumn,
    TextStyle amountStyle,
    TextStyle quantityStyle,
  ) {
    return Column(
      key: Key('overview-stock-top-${row.productId}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
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
            // 金额放进**与数量共用的右列**（该列宽由 `_trailingColumnWidth` 量出）：
            // 右对齐 ⇒ 各行个位对齐；列宽固定 ⇒ 柱子在同一个 x 结束。
            // ⚠️ 列宽是"所有行里最宽的那条金额/数量"，所以不会比原来更窄 ——
            // 2026-11-18 那个"88 px 极窄卡顶出去"的问题不会回来。
            SizedBox(
              width: trailingColumn,
              child: Text(
                '¥${Money.formatGrouped(row.valueCents)}',
                textAlign: TextAlign.right,
                // 单行 + 不换行：列宽是按**同一份样式**量出来的，正常不会不够；
                // 万一字体回退导致差几个像素，也宁可溢出 1 px，不要折成两行
                //（真机 2026-11-26 就是这么坏的）。
                maxLines: 1,
                softWrap: false,
                style: amountStyle,
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
            // 数量 + 单位：**各自单位照实写，不换算、不跨商品求和**。
            // 固定列宽（卡片级算好）⇒ 所有行的柱子在同一 x 结束，柱长可比。
            SizedBox(
              width: trailingColumn,
              child: Text(
                '${row.quantity} ${row.unit}',
                textAlign: TextAlign.right,
                maxLines: 1,
                softWrap: false,
                style: quantityStyle,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
