/// 主界面（**空骨架**）。
///
/// 第 1 天只做到这里：把「数据在哪」明确告诉用户，并把接下来的核心闭环
/// **列出来但标成待实现**。按 `docs/ui_principles.md` §1.1 ——
/// 中老年用户不会主动探索，所以功能入口**必须常驻可见 + 带文字**，
/// 不能用图标按钮或汉堡菜单藏着。
library;

import 'package:flutter/material.dart';

/// 核心闭环的五个步骤（`docs/reply.md` §五 的第 2–9 天）
const List<String> _pipeline = <String>[
  '商品建档',
  '采购入库',
  '库存查询',
  '销售开单',
  '收款',
];

class HomePage extends StatelessWidget {
  const HomePage({
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

  /// 数据库是否已成功打开 —— 用来在界面上给用户一个「真的通了」的确认
  final bool databaseReady;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('神算子')),
      body: ListView(
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
                  SelectableText(dataDirectory, style: const TextStyle(height: 1.6)),
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
                        databaseReady ? Icons.check_circle_outline : Icons.error_outline,
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
          Text('接下来要做的', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final String step in _pipeline)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                // 行高按 ui_principles：表格行 ≥ 48，这里给 56 更宽裕
                minVerticalPadding: 16,
                title: Text(step, style: const TextStyle(height: 1.6)),
                trailing: Text(
                  '待实现',
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
