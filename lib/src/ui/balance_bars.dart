import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'ratio_bar.dart';

/// 应收 / 应付横条（提案 54 §三「第二优先」）。
///
/// 数据**早就有**（`receivablesSummary` / `payablesSummary`），只是从来没画出来。
/// 解决的是「我到底欠人多少、人欠我多少」—— 个体户每天都会想的问题。
///
/// ## 为什么是横条而不是数字
///
/// 「要留心」卡里已经有数字了。横条给的是**两者谁大**的一眼感：
/// 欠供应商 ¥8,000 和客户欠我 ¥800，两个数字并排看要读半天，
/// 两条长度一比就出来了。
///
/// ## 间距约定（⚠️ 用户 2026-10-20 报过「两张卡片重叠」）
///
/// `margin: EdgeInsets.zero`，与相邻卡片的间距**由父级 `SizedBox` 给**。
class BalanceBarsCard extends StatelessWidget {
  const BalanceBarsCard({
    super.key,
    required this.receivables,
    required this.payables,
    this.mobileShell = false,
  });

  final ReceivablesSummary receivables;
  final PayablesSummary payables;
  final bool mobileShell;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 两边都没欠款 ⇒ 整张卡不出现（页面上少一块噪音）
    if (receivables.totalCents <= 0 && payables.totalCents <= 0) {
      return const SizedBox.shrink();
    }

    final int maxCents = [
      receivables.totalCents,
      payables.totalCents,
    ].reduce((int a, int b) => a > b ? a : b);

    return Card(
      key: const Key('overview-balance-bars'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(mobileShell ? 14 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('欠款一览', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            // 应付在前：要还出去的钱比要收进来的更急（F13 的同一判断）
            if (payables.totalCents > 0)
              _bar(
                theme,
                key: 'overview-balance-payable',
                label: '我欠别人（应付）',
                cents: payables.totalCents,
                partyCount: payables.partyCount,
                maxCents: maxCents,
                color: theme.colorScheme.error,
              ),
            if (receivables.totalCents > 0) ...<Widget>[
              if (payables.totalCents > 0) const SizedBox(height: 10),
              _bar(
                theme,
                key: 'overview-balance-receivable',
                label: '别人欠我（应收）',
                cents: receivables.totalCents,
                partyCount: receivables.partyCount,
                maxCents: maxCents,
                color: theme.colorScheme.primary,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bar(
    ThemeData theme, {
    required String key,
    required String label,
    required int cents,
    required int partyCount,
    required int maxCents,
    required Color color,
  }) {
    return Column(
      key: Key(key),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: const TextStyle(height: 1.5, fontSize: 15),
              ),
            ),
            Text(
              '¥${Money.formatGrouped(cents)}',
              style: const TextStyle(
                height: 1.5,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        RatioBar(
          cents: cents,
          maxCents: maxCents,
          color: color,
          barKey: Key('$key-bar'),
        ),
        const SizedBox(height: 2),
        Text(
          '$partyCount 家未结',
          style: TextStyle(
            height: 1.5,
            fontSize: 13,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
      ],
    );
  }
}
