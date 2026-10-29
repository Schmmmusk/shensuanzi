// 数据抢救 P1 的界面（2026-10-29，提案 52 §四·P1）。
//
// ## 三个阶段的文案原则（用户补充建议第 2 条）
//
// 全程不出现「表 / 行 / SQL / 数据库损坏」这类词。用户要读到的是：
// 「找回了 100 张进货单，其中 2 张的明细可能缺失」。
//
// ## 为什么它藏在「找回数据」之后
//
// 抢救是**最后手段**：结果不完整、可能缺流水。备份能用时绝不该走这条路。
// 所以入口是错误页上的一个低调文字按钮，且点下去先有一段解释与确认。

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

/// 跑一次抢救：确认 → 执行 → 报告。返回 `true` 表示产出了结果文件。
Future<bool> showRescueFlow(
  BuildContext context, {
  required String sourcePath,
  required String outputPath,
  required String outputDirectory,
}) async {
  final bool? go = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('从坏掉的文件里尽量找回'),
      content: const Text(
        '这个办法用在「备份也没有、或者备份都坏了」的时候。\n\n'
        '它会尽量把还能读出来的单据读出来，另存成一个新文件 —— '
        '**你原来的文件一个字节都不会动**，还会被设成只读，防止误改。\n\n'
        '要说清楚：救回来的东西**可能不完整**。缺了明细或流水的单据，'
        '我会单独列出来给你看，不会偷偷混进去。',
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('rescue-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('先不试'),
        ),
        FilledButton(
          key: const Key('rescue-start'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('开始找回'),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return false;

  final RescueReport report = await showDialog<RescueReport>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext dialogContext) => _RunningDialog(
      sourcePath: sourcePath,
      outputPath: outputPath,
      outputDirectory: outputDirectory,
    ),
  ).then((RescueReport? value) => value ?? const RescueReport.failed('已取消'));
  if (!context.mounted) return false;

  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _ReportDialog(report: report, outputDirectory: outputDirectory),
  );
  return report.ok;
}

/// 执行中的对话框（跑完自己 pop 出报告）。
class _RunningDialog extends StatefulWidget {
  const _RunningDialog({
    required this.sourcePath,
    required this.outputPath,
    required this.outputDirectory,
  });

  final String sourcePath;
  final String outputPath;
  final String outputDirectory;

  @override
  State<_RunningDialog> createState() => _RunningDialogState();
}

class _RunningDialogState extends State<_RunningDialog> {
  String _step = '准备中…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // 先让这一帧画出来，否则用户看不到「正在抢救」就开始卡
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final RescueReport report = await rescueDatabase(
      sourcePath: widget.sourcePath,
      outputPath: widget.outputPath,
      onProgress: (RescueProgress progress) {
        if (!mounted) return;
        setState(() => _step = progress.detail);
      },
    );
    if (!mounted) return;
    Navigator.of(context).pop(report);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('正在找回…'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Text(_step, key: const Key('rescue-step')),
          const SizedBox(height: 8),
          Text(
            '大文件可能要几十秒，别关软件。你原来的文件不会被动。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// 报告对话框 —— 用户要能一眼看出「找回了什么、少了什么」。
class _ReportDialog extends StatelessWidget {
  const _ReportDialog({required this.report, required this.outputDirectory});

  final RescueReport report;
  final String outputDirectory;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (!report.ok) {
      return AlertDialog(
        title: const Text('没能找回数据'),
        content: Text(
          report.failure ?? '原因不明',
          key: const Key('rescue-failure'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('找回完成'),
      content: SizedBox(
        width: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              _headline(),
              key: const Key('rescue-headline'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            // 按类型分：用户心里的单位是「进货单 / 销售单」，不是「行」
            for (final RescueTypeStat stat in report.typeStats)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  stat.incomplete == 0
                      ? '· ${stat.label} ${stat.total} 张，全部完整'
                      : '· ${stat.label} ${stat.total} 张，'
                            '其中 ${stat.incomplete} 张可能不完整',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            if (report.unreadableTables.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '这几类数据完全没读到：${report.unreadableTables.join('、')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (report.issues.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text('下面这些单据没放进去（点开可以看是哪些）：', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 4),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: report.issues.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final RescueIssue issue = report.issues[index];
                      return ListTile(
                        key: ValueKey<String>('rescue-issue-${issue.docId}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${issue.typeLabel} ${issue.docNo}'
                          '${issue.totalAmount == null ? '' : ' · ${_money(issue.totalAmount!)}'}'
                          '${issue.occurredAt == null ? '' : ' · ${_day(issue.occurredAt!)}'}',
                        ),
                        subtitle: Text(issue.detail ?? issue.summary),
                      );
                    },
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '结果存在这个文件夹里（原来的文件没动）：\n$outputDirectory',
              key: const Key('rescue-output'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('rescue-done'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }

  String _headline() {
    if (report.totalDocuments == 0) {
      return '这个文件里没有找到单据。';
    }
    if (report.issues.isEmpty) {
      return '找回了 ${report.totalDocuments} 张单据，全部完整，可以直接用。';
    }
    return '找回了 ${report.totalDocuments} 张单据，'
        '其中 ${report.importedDocuments} 张完整、'
        '${report.issues.length} 张可能不完整。';
  }

  String _money(int cents) => '¥${(cents / 100).toStringAsFixed(2)}';

  String _day(DateTime time) =>
      '${time.year}-${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';
}
