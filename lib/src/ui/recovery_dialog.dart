// 数据体检与恢复（P0，提案 52 §三）。
//
// ## 它解决的是哪一个问题
//
// 库打不开的时候，用户面前的按钮只有「重试」和「更改」。而他的每日备份、
// 升级前留的 `.before-vN` **就躺在旁边** —— 程序认识，他不知道，界面上不存在。
// 于是「数据损坏」在他眼里等于「数据没了」，只能去换一个空文件夹、从零开始。
//
// 这个对话框把那堆文件摆到台面上：几份、哪份好的、里面有多少单据、最后一张
// 是哪天。选一份、确认、接回去 —— 原来的数据文件**改名留存**，不删。
//
// ## 三个界面决定
//
// 1. **边查边显示**：478 MB 的库 `quick_check` 要 850 ms，十几份备份就是十几秒。
//    一次性返回会让界面像死了一样，所以每查完一份就往上加一行。
// 2. **不可用的也列出来，并说清为什么**：用户看到「那份 10 月 20 日的坏了」比
//    只看到「没找到可用的备份」有用得多 —— 后者会让他以为文件都没了。
// 3. **接回要二次确认，并把后果说全**：「当前的数据文件会改名保存，不会删除」。

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

import 'emphasized_text.dart';
/// 打开「数据体检与恢复」。返回 `true` = 已经接回了一份（调用方应当重试打开库）。
Future<bool> showRecoveryDialog(
  BuildContext context, {
  required String dataDirectory,
  required String databasePath,
  required String backupDirectory,
  required int currentSchemaVersion,
}) async {
  final bool? restored = await showDialog<bool>(
    context: context,
    // 体检要读写磁盘，不让点外面误关
    barrierDismissible: false,
    builder: (BuildContext dialogContext) => _RecoveryDialog(
      dataDirectory: dataDirectory,
      databasePath: databasePath,
      backupDirectory: backupDirectory,
      currentSchemaVersion: currentSchemaVersion,
    ),
  );
  return restored ?? false;
}

class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog({
    required this.dataDirectory,
    required this.databasePath,
    required this.backupDirectory,
    required this.currentSchemaVersion,
  });

  final String dataDirectory;
  final String databasePath;
  final String backupDirectory;
  final int currentSchemaVersion;

  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  /// 已经体检完的候选（流式追加）
  final List<RecoveryCandidate> _candidates = <RecoveryCandidate>[];

  /// 还在检查（流没结束）
  bool _scanning = true;

  /// 正在接回（禁用所有按钮，避免连点）
  bool _restoring = false;

  /// 接回失败的原因（留在对话框里，不弹 SnackBar —— 这个页面没有 Scaffold 之外的容器）
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    try {
      await for (final RecoveryCandidate candidate in scanRecoveryCandidates(
        dataDirectory: widget.dataDirectory,
        backupDirectory: widget.backupDirectory,
        currentSchemaVersion: widget.currentSchemaVersion,
      )) {
        if (!mounted) return;
        setState(() => _candidates.add(candidate));
      }
    } catch (error) {
      // 体检本身失败（比如备份目录读不了）—— 说清是哪一步，别静默
      if (!mounted) return;
      setState(() => _error = '检查备份时出错：$error');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _restore(RecoveryCandidate candidate) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext confirmContext) => AlertDialog(
        title: const Text('用这份接回去？'),
        content: EmphasizedText(
          '${_describe(candidate)}\n\n'
          '接回去之后：\n'
          '· 现在打不开的那个数据文件会**改名保存**（名字带 broken），不会删除；\n'
          '· 用这一份备份代替它，软件会用这份的数据重新打开。\n\n'
          '这份之后新录的单据不会在里面 —— 它只是备份。',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('recovery-cancel-restore'),
            onPressed: () => Navigator.of(confirmContext).pop(false),
            child: const Text('再想想'),
          ),
          FilledButton(
            key: const Key('recovery-confirm-restore'),
            onPressed: () => Navigator.of(confirmContext).pop(true),
            child: const Text('接回去'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _restoring = true;
      _error = null;
    });
    final RecoveryRestoreResult result = await restoreFromCandidate(
      candidatePath: candidate.path,
      databasePath: widget.databasePath,
      currentSchemaVersion: widget.currentSchemaVersion,
    );
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _restoring = false;
      _error = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<RecoveryCandidate> usable = _candidates
        .where((RecoveryCandidate c) => c.usable)
        .toList(growable: false);

    return AlertDialog(
      title: const Text('数据体检与恢复'),
      content: SizedBox(
        width: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '下面是从「${_folderName(widget.backupDirectory)}」和数据文件夹里'
              '找到的备份。选一份接回去 —— 现在打不开的那个文件会改名保存，'
              '不会被删掉。',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            if (_error != null) ...<Widget>[
              Container(
                key: const Key('recovery-error'),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Flexible(child: _buildList(theme, usable)),
            const SizedBox(height: 8),
            if (_scanning)
              Row(
                children: <Widget>[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '正在检查…（已查 ${_candidates.length} 份）',
                    key: const Key('recovery-scanning'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              )
            else
              Text(
                _summary(usable),
                key: const Key('recovery-summary'),
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('recovery-close'),
          onPressed: _restoring ? null : () => Navigator.of(context).pop(false),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildList(ThemeData theme, List<RecoveryCandidate> usable) {
    if (_candidates.isEmpty) {
      if (_scanning) {
        return const SizedBox(height: 80);
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '这个文件夹里没有找到任何备份。\n'
          '如果数据很重要，先别急着新建空账 —— 可以在文件管理器里找找'
          '「${_folderName(widget.backupDirectory)}」文件夹、或者 U 盘 / 网盘里'
          '有没有以前拷走的 shensuanzi.db。',
          key: const Key('recovery-empty'),
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: _candidates.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (BuildContext context, int index) =>
            _row(theme, _candidates[index]),
      ),
    );
  }

  Widget _row(ThemeData theme, RecoveryCandidate candidate) {
    final bool canUse = candidate.usable && !_restoring;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    _sourceChip(theme, candidate.source),
                    const SizedBox(width: 8),
                    Text(
                      formatRecoveryTime(candidate.time),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatRecoverySize(candidate.bytes),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _describeContent(candidate),
                  style: theme.textTheme.bodySmall,
                ),
                if (candidate.note != null)
                  Text(
                    candidate.note!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (canUse)
            FilledButton.tonal(
              key: ValueKey<String>('recovery-use-${candidate.fileName}'),
              onPressed: () => _restore(candidate),
              child: const Text('用这一份'),
            )
          else
            Text(
              '不可用',
              key: ValueKey<String>('recovery-unusable-${candidate.fileName}'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.disabledColor,
              ),
            ),
        ],
      ),
    );
  }

  Widget _sourceChip(ThemeData theme, RecoverySource source) {
    final (String label, Color color) = switch (source) {
      RecoverySource.autoBackup => ('自动备份', theme.colorScheme.primary),
      RecoverySource.manualBackup => ('手动备份', theme.colorScheme.tertiary),
      RecoverySource.beforeMigration => ('升级前留存', theme.colorScheme.secondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }

  /// 「1234 张单据，最后一单 2026-10-27」—— 用户判断选哪份靠这一行
  String _describeContent(RecoveryCandidate candidate) {
    final int? count = candidate.documentCount;
    if (count == null) return '读不出里面的内容（可能不是本软件的数据文件）';
    if (count == 0) return '里面没有单据（空账）';
    final String last = candidate.lastDocumentAt == null
        ? '日期读不出来'
        : '最后一单 ${formatRecoveryDay(candidate.lastDocumentAt!)}';
    return '$count 张单据，$last';
  }

  /// 二次确认里那句话（要能让用户一眼认出「我选的是哪一份」）
  String _describe(RecoveryCandidate candidate) {
    return '${formatRecoveryTime(candidate.time)} 的那份'
        '（${_sourceLabel(candidate.source)}，${formatRecoverySize(candidate.bytes)}，'
        '${_describeContent(candidate)}）';
  }

  String _sourceLabel(RecoverySource source) => switch (source) {
    RecoverySource.autoBackup => '自动备份',
    RecoverySource.manualBackup => '手动备份',
    RecoverySource.beforeMigration => '升级前留存',
  };

  String _summary(List<RecoveryCandidate> usable) {
    final int total = _candidates.length;
    if (total == 0) return '';
    if (usable.isEmpty) {
      return '共 $total 份，但都不能用。';
    }
    return '共 $total 份，其中 ${usable.length} 份可用。';
  }

  /// 只显示最后一级目录名（完整路径太长，挤掉真正要看的按钮）
  String _folderName(String path) {
    final int index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index < 0 ? path : path.substring(index + 1);
  }
}

/// `2026-10-28 15:30`
String formatRecoveryTime(DateTime? time) {
  if (time == null) return '时间不明';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

/// `2026-10-27`
String formatRecoveryDay(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

/// `478 MB` / `12.3 MB` / `860 KB`
String formatRecoverySize(int bytes) {
  if (bytes >= 1024 * 1024) {
    final double mb = bytes / (1024 * 1024);
    return mb >= 100 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes 字节';
}
