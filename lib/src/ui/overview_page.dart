/// 概览页 —— 回答两个问题：**我的数据在哪**、**现在能不能用**。
///
/// 这是落地页（左侧导航第一项）。刻意不塞业务数字：等核心闭环做完，
/// 这里才放「今日销售 / 库存告急 / 欠款」这类聚合（RULE-006 的查询已就绪）。
library;

import 'package:flutter/material.dart';

class OverviewPage extends StatelessWidget {
  const OverviewPage({
    super.key,
    required this.dataDirectory,
    required this.backupDirectory,
    required this.schemaVersion,
    required this.databaseReady,
  });

  /// 数据目录（用户选的，数据库就放在这里）
  final String dataDirectory;

  /// 备份目录（数据目录的**兄弟目录**，见 `docs/data_directory.md` §八）
  final String backupDirectory;

  final int schemaVersion;

  /// 数据库是否已成功打开
  final bool databaseReady;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('你的数据在', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                SelectableText(
                  dataDirectory,
                  style: const TextStyle(height: 1.6),
                ),
                const SizedBox(height: 12),
                Text(
                  '备份会放在旁边：$backupDirectory',
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Icon(
                      databaseReady
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 20,
                      color: databaseReady
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        databaseReady
                            ? '数据文件已就绪（版本 $schemaVersion）'
                            : '数据文件打不开，请到设置里换一个位置',
                        style: const TextStyle(height: 1.6),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('从这里开始', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '左边的功能列表一直可见：开单、查库存、管商品都在那里。',
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
      ],
    );
  }
}
