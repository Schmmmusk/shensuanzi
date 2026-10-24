/// 草稿橙条（三个开单页共用，真实诉求批 ①，2026-10-24，§CV·一百零三）。
///
/// 为什么不各页各写一份：三个开单页逐字段同构（本仓已多次踩「改一页忘了另两页」），
/// 而这条橙条是**用户唯一会看到的草稿入口** —— 抄三遍必然出现三份措辞。
///
/// `prefix` 只影响 Key（`sale-draft-banner` / `purchase-draft-banner` /
/// `delivery-draft-banner`），测试靠它定位。
library;

import 'package:flutter/material.dart';

class DraftBanner extends StatelessWidget {
  const DraftBanner({
    super.key,
    required this.prefix,
    required this.savedAt,
    required this.lineCount,
    required this.onRestore,
    required this.onDiscard,
  });

  /// Key 前缀（`sale` / `purchase` / `delivery`）
  final String prefix;

  /// 草稿保存时间（`null` = 旧草稿没有这个字段）
  final DateTime? savedAt;

  /// 草稿里有几行（让用户判断是不是他那一单）
  final int lineCount;

  final VoidCallback onRestore;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime? at = savedAt;
    final String when = at == null
        ? '上次'
        : '${at.month}月${at.day}日 '
              '${at.hour.toString().padLeft(2, '0')}:'
              '${at.minute.toString().padLeft(2, '0')}';
    return Container(
      key: Key('$prefix-draft-banner'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '发现 $when 未提交的草稿（$lineCount 行）',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '要不要接着上次的填？恢复会覆盖现在填的内容。',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: theme.colorScheme.onTertiaryContainer,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                key: Key('$prefix-draft-discard'),
                onPressed: onDiscard,
                child: const Text('放弃'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                key: Key('$prefix-draft-restore'),
                onPressed: onRestore,
                child: const Text('恢复'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
