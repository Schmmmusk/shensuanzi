/// 「缺货榜」卡片（提案 61，2026-11-13 裁定：布局**甲**、超卖置顶、
/// 金额按参考进价、未设安全库存时出引导卡）。
///
/// ## 与压货榜的关系
///
/// **新增一张榜，不是把压货榜改反**（2026-11-11 用户裁定）。两榜回答的问题不同：
///
/// | 榜 | 回答 | 位置 |
/// |---|---|---|
/// | 缺货榜 | **哪些货要买**、大概要花多少钱 | 概览在上、库存页在前（决策 3 甲） |
/// | 压货榜 | 哪些货占着钱 | 概览在下、库存页在后 |
///
/// 刻意**不合并成一张卡**（否决决策 3 丙）：一张卡两套颜色两套口径，
/// 目标用户里有不熟悉软件的人，独立卡片各自收起、各自有标题更好懂。
///
/// ## 三处文案红线（决策 1 的补充裁定）
///
/// 金额来自 `products.cost_price`，它只是**参考进价**，不是供应商的真实报价，
/// 也不是成本真相（成本真相在 `stock_ledger.total_cost`）。所以：
///
/// - 必须写「**预计补货金额**」+「按商品档案中的参考进价估算，实际采购金额以供应商报价为准」；
/// - **不许**出现「成本」「约合」这类像已经算准了的词（测试
///   `test/low_stock_card_test.dart` 会对整张卡做断言）。
///
/// ## 两个「不能假装」的计数
///
/// | 情况 | 处理 | 为什么 |
/// |---|---|---|
/// | `cost_price == 0` | 只报缺口件数，标「单价未填」 | 显示 `¥0` 会让用户以为「补这批货不要钱」 |
/// | 从没进过货（`hasInbound == false`） | 照常进榜，单独计数 | 这类恰恰最紧急（刚建档、设了安全库存、还没进货）—— 但不能混进压货榜的「待校准」 |
///
/// ## 间距约定（与压货榜同款）
///
/// `margin: EdgeInsets.zero`，与相邻卡片的间距**由父级 `SizedBox` 给**
/// （用户 2026-10-20 报过「两张卡片重叠」）。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'app_colors.dart';
import 'ratio_bar.dart';
import 'shortage.dart';

class LowStockCard extends StatelessWidget {
  const LowStockCard({
    super.key,
    required this.summary,
    this.mobileShell = false,
    this.onOpenAll,
  });

  final ShortageSummary summary;
  final bool mobileShell;

  /// 「查看全部」的出口（概览页传：点一下切到库存页）。
  ///
  /// `null` = 不显示按钮（库存页自己就是全部）。
  final VoidCallback? onOpenAll;

  @override
  Widget build(BuildContext context) {
    if (!summary.isVisible) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);

    // 决策 4 乙：全店都没设安全库存 ⇒ **普通信息提示**（不是警告、不是空白）。
    // 做成警告会让新用户以为软件坏了；完全空白则让人以为功能没做。
    if (summary.showGuide) return _guideCard(theme);

    final List<ShortageRow> oversold = summary.oversold;
    final List<ShortageRow> restock = summary.restock;
    final int maxCents = <ShortageRow>[
      ...oversold,
      ...restock,
    ].fold<int>(0, (int m, ShortageRow r) => r.gapCents > m ? r.gapCents : m);

    return Card(
      key: const Key('low-stock-card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(mobileShell ? 14 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              summary.hasAny ? '该补货的 ${summary.totalCount} 个商品' : '缺货榜',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '按预计补货金额排（缺口 × 参考进价）。'
              '按商品档案中的参考进价估算，实际采购金额以供应商报价为准。',
              style: TextStyle(
                height: 1.6,
                fontSize: 13,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
            if (!summary.hasAny)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  '没有要补的货 —— 设了安全库存的商品都还够。',
                  key: const Key('low-stock-none'),
                  style: TextStyle(
                    height: 1.7,
                    fontSize: 15,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              ),
            // ⚠️ 超卖**置顶**：账已经对不上了，比「缺货」更严重（决策 2）。
            if (oversold.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              _sectionHeader(
                theme,
                key: 'low-stock-oversold-header',
                text: '已超卖（${summary.oversoldCount} 个）',
                color: theme.colorScheme.error,
                icon: Icons.warning_amber_rounded,
              ),
              const SizedBox(height: 8),
              for (int i = 0; i < oversold.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 10),
                _row(theme, oversold[i], maxCents, oversold: true),
              ],
            ],
            if (restock.isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              _sectionHeader(
                theme,
                key: 'low-stock-restock-header',
                text: '该补货（${summary.restockCount} 个）',
                color: AppColors.warningOrange,
                icon: Icons.inventory_2_outlined,
              ),
              const SizedBox(height: 8),
              for (int i = 0; i < restock.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 10),
                _row(theme, restock[i], maxCents, oversold: false),
              ],
            ],
            // 两种「不能假装」的，各说一句 —— 数量照报，但不假装有金额
            if (summary.priceUnsetCount > 0)
              _notice(
                theme,
                key: 'low-stock-price-unset',
                text:
                    '另有 ${summary.priceUnsetCount} 种没填参考进价，只报缺口件数、'
                    '不参与金额排名（填在「商品 → 编辑 → 参考进价」）。',
              ),
            if (summary.neverInboundCount > 0)
              _notice(
                theme,
                key: 'low-stock-never-inbound',
                text:
                    '其中 ${summary.neverInboundCount} 种从没进过货'
                    '（刚建档或只有过出库）—— 缺口按安全库存算，金额按参考进价估算。',
              ),
            if (onOpenAll != null) ...<Widget>[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('low-stock-open-all'),
                  onPressed: onOpenAll,
                  child: Text(
                    summary.totalCount > _shownCount()
                        ? '查看全部 ${summary.totalCount} 个'
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

  int _shownCount() => summary.oversold.length + summary.restock.length;

  /// 引导卡（决策 4 乙）：**普通提示**，用主题色而不是橙/红。
  Widget _guideCard(ThemeData theme) => Card(
    key: const Key('low-stock-card'),
    margin: EdgeInsets.zero,
    child: Padding(
      padding: EdgeInsets.all(mobileShell ? 14 : 16),
      child: Column(
        key: const Key('low-stock-guide'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.info_outline,
                size: 18,
                color: theme.textTheme.bodySmall?.color,
              ),
              const SizedBox(width: 6),
              Text('还没有设置安全库存', style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '设置后，商品快没货时，这里就会提醒你。',
            style: TextStyle(height: 1.7, fontSize: 15),
          ),
          const SizedBox(height: 6),
          Text(
            '怎么设：商品 → 编辑 → 安全库存',
            style: TextStyle(
              height: 1.6,
              fontSize: 13,
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _sectionHeader(
    ThemeData theme, {
    required String key,
    required String text,
    required Color color,
    required IconData icon,
  }) => Row(
    key: Key(key),
    children: <Widget>[
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 6),
      Text(
        text,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    ],
  );

  Widget _row(
    ThemeData theme,
    ShortageRow row,
    int maxCents, {
    required bool oversold,
  }) {
    final Color color = oversold
        ? theme.colorScheme.error
        : AppColors.warningOrange;
    // 超卖段要说两件事：**已经卖穿多少**（在店可售，负数）与**要补多少**
    // （缺口 = 补到安全库存）。两个数都给，但**不混用**（决策 1 的公式裁定）。
    final String qtyText = oversold
        ? '在店可售 ${row.inStore} ${row.unit} · 补 ${row.gapQty} ${row.unit}'
        : '缺 ${row.gapQty} ${row.unit}';

    return Column(
      key: Key('low-stock-${oversold ? 'oversold' : 'restock'}-${row.id}'),
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
              _amountText(row),
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
                cents: row.gapCents,
                maxCents: maxCents,
                color: color,
                height: 10,
                barKey: Key(
                  'low-stock-${oversold ? 'oversold' : 'restock'}-${row.id}-bar',
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 超卖那一段的数量用红色 —— 这是「账已经对不上」的那个数
            Text(
              qtyText,
              style: TextStyle(
                height: 1.4,
                fontSize: 13,
                color: oversold ? color : theme.textTheme.bodySmall?.color,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 金额区三种形态，各不假装：
  /// - 正常 ⇒ `预计补货 ¥120.00`
  /// - 单价没填 ⇒ `单价未填`（**不写 ¥0**）
  /// - 缺口为 0（刚好等于安全库存）⇒ `刚好到安全库存`（不写 ¥0）
  String _amountText(ShortageRow row) {
    if (row.priceUnset) return '单价未填';
    if (row.gapIsZero) return '刚好到安全库存';
    return '预计补货 ¥${Money.formatGrouped(row.gapCents)}';
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
}
