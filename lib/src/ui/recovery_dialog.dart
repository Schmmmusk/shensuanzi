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
// 4. **「不可用」只留给体检得出的结论**（2026-11-18 用户反馈）：清单先行之后，
//    别人被接回期间这一行只是暂时不能点，写「请等待体检完成」—— 写「不可用」
//    会让人以为整堆备份都坏了。

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart'
    show unexpectedFailureAdvice;

import 'app_dialog.dart';
import 'emphasized_text.dart';

/// 打开「数据体检与恢复」。返回 `true` = 已经接回了一份（调用方应当重试打开库）。
///
/// [log]（N-f 站点 4，2026-11-05 裁定甲）：体检 / 接回失败时的**原始异常出口**。
/// 之前这个对话框没有任何日志参数 ⇒ 界面只能把 `$error` 拼给用户看，
/// 而现场（栈、errno）当场就没了。传了它，界面才可以说「日志里有详细原因」。
Future<bool> showRecoveryDialog(
  BuildContext context, {
  required String dataDirectory,
  required String databasePath,
  required String backupDirectory,
  required int currentSchemaVersion,
  AppLog? log,
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
      log: log,
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
    this.log,
  });

  final String dataDirectory;
  final String databasePath;
  final String backupDirectory;
  final int currentSchemaVersion;

  /// 原始异常的唯一去处；`null` = 没接（此时界面**不许**提日志）。
  final AppLog? log;

  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  /// 候选清单（**清单先行**：只有文件名 / 大小 / 时间，还没体检）
  final List<RecoveryCandidate> _candidates = <RecoveryCandidate>[];

  /// 还在列目录（只有一瞬；列完就 false）
  bool _listing = true;

  /// 正在接回（禁用所有按钮，避免连点）
  bool _restoring = false;

  /// 正在接回的那一份（`_restoring` 时才有值）—— 用来把「这一份」与
  /// 「其余还没轮到体检的那些」在界面上分开说（2026-11-18 用户反馈）。
  String? _restoringPath;

  /// 接回失败的原因（留在对话框里，不弹 SnackBar —— 这个页面没有 Scaffold 之外的容器）
  String? _error;

  @override
  void initState() {
    super.initState();
    _list();
  }

  /// 列目录（**不体检**）—— 见 `listRecoveryCandidates` 的说明。
  ///
  /// ⚠️ 2026-11-18 用户裁定甲：原来是「逐份 `quick_check` 完再显示」，
  /// 7 份 498 MB 的备份在那台虚拟机上要 17 分钟才出全。现在清单立刻出，
  /// **点哪份才体检哪份**；接回前 `_restoreSync` 里还会完整体检一次，
  /// 所以坏文件照样接不进去（安全性没降，只是把等待挪到用户已经决定之后）。
  Future<void> _list() async {
    try {
      final List<RecoveryCandidate> listed = listRecoveryCandidates(
        dataDirectory: widget.dataDirectory,
        backupDirectory: widget.backupDirectory,
      );
      if (!mounted) return;
      setState(() {
        _candidates
          ..clear()
          ..addAll(listed);
      });
    } catch (error, stack) {
      // 列目录失败（备份目录读不了）—— 说清是哪一步，别静默。
      //
      // N-f 站点 4（2026-11-05 裁定甲）：原文进日志、界面给人话；
      // **没传 log 时不提日志**（裁定 ③）。
      widget.log?.crash(error, stack, label: '列出备份失败');
      if (!mounted) return;
      setState(() {
        _error = unexpectedFailureAdvice(
          error,
          logged: widget.log != null,
          lead: '找备份时出错。',
        );
      });
    } finally {
      if (mounted) setState(() => _listing = false);
    }
  }

  Future<void> _restore(RecoveryCandidate candidate) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext confirmContext) => AppDialog(
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
      _restoringPath = candidate.path;
      _error = null;
    });
    // 2026-11-17 真机：接回把 500 MB 的库同步拷在 UI 线程上跑 ⇒ 整个界面卡死、
    // 日志一行都没有（写日志也被同一线程堵住）。现在真正的活在 `recovery.dart`
    // 的工作 isolate 里做；这里只负责「开始 / 结果」两行日志，让下一次有现场。
    widget.log?.write(
      '开始接回：${candidate.fileName}'
      '（${(candidate.bytes / 1048576).toStringAsFixed(1)} MB）',
    );
    final RecoveryRestoreResult result = await restoreFromCandidate(
      candidatePath: candidate.path,
      databasePath: widget.databasePath,
      currentSchemaVersion: widget.currentSchemaVersion,
      // 来源与时间**由这里给**（评审 P2）：体检结论回写到行上时要靠它们，
      // 让数据层自己猜就会把「手动备份」显示成「自动备份」、时间变「时间不明」。
      source: candidate.source,
      time: candidate.time,
    );
    widget.log?.write(
      result.ok ? '接回成功：${result.candidatePath}' : '接回失败：${result.message}',
    );
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _restoring = false;
      _restoringPath = null;
      _error = result.message;
      // 体检结论回写那一行（2026-11-18 用户反馈）：点了坏的那份被拦下之后，
      // 这一行若还写着「还没检查」，用户就得靠上方报错去猜是哪一份。
      // `checked == null` = 没体检过（文件在点按前就没了 / 现库占用），
      // 那种情况**不许**改状态 —— 结论不是「这份坏了」。
      final RecoveryCandidate? checked = result.checked;
      if (checked != null) {
        final int index = _candidates.indexWhere(
          (RecoveryCandidate c) => c.path == checked.path,
        );
        if (index >= 0) _candidates[index] = checked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<RecoveryCandidate> usable = _candidates
        .where((RecoveryCandidate c) => c.usable)
        .toList(growable: false);

    return AppDialog(
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
            if (_listing)
              Row(
                children: <Widget>[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '正在找备份…',
                    key: const Key('recovery-listing'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              )
            else if (_restoring)
              Row(
                children: <Widget>[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      // 真机上这两步合计可能要几分钟（体检整库 + 复制整库），
                      // 先说清「在做什么、别关软件」，比一个转圈有用。
                      '正在体检并接回这份备份…（可能要几分钟，先别关软件）',
                      key: const Key('recovery-restoring'),
                      style: theme.textTheme.bodySmall,
                    ),
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
      if (_listing) {
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
    // 未体检的也能点：点了先体检这一份、通过才接回（2026-11-18 裁定甲）。
    final bool canUse =
        (candidate.usable || candidate.state == RecoveryState.unchecked) &&
        !_restoring;

    // 「不可用」只留给**体检过、结论是不能用**的那几行（坏了 / 版本太新 / 读不到）。
    // 正在接回另一份时，其余行的按钮要禁掉；没体检过的那些若也写「不可用」，
    // 用户会以为这一堆备份全坏了（2026-11-18 用户反馈）。
    final bool isCurrent = _restoring && candidate.path == _restoringPath;
    final bool waitingTurn =
        _restoring && !isCurrent && candidate.state == RecoveryState.unchecked;

    // 行内容：来源 + 时间 + 大小（同一行放不下就折行）、说明、原因。
    //
    // ⚠️ 这里原本是 `Row` + 两个 `SizedBox(width: 8)`。在 371 px 宽的窗口上实测
    // （2026-11-18）：「2026-11-16 09:00」这个**不可断行**的词有 228 px，
    // 而整行只剩 ~175 px ⇒ 它直接溢出到对话框外面（`RenderFlex` 没报错，
    // 因为整行被 `ListView` 裁掉了，字是「缺一块」而不是「变红」）。
    // 换成 `Wrap`：放不下就把「大小」挪到下一行，一行永远只处理一个不可断行的词。
    final Widget info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            _sourceChip(theme, candidate.source),
            Text(
              formatRecoveryTime(candidate.time),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              formatRecoverySize(candidate.bytes),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(_describeContent(candidate), style: theme.textTheme.bodySmall),
        if (candidate.note != null)
          Text(
            candidate.note!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
      ],
    );

    final Widget action = canUse
        ? FilledButton.tonal(
            key: ValueKey<String>('recovery-use-${candidate.fileName}'),
            onPressed: () => _restore(candidate),
            child: const Text('用这一份'),
          )
        : Text(
            isCurrent
                ? '正在体检…'
                : waitingTurn
                ? '请等待体检完成'
                : '不可用',
            key: ValueKey<String>('recovery-row-status-${candidate.fileName}'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.disabledColor,
            ),
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      // 窄到放不下「说明 + 按钮」并排时，按钮挪到下一行、右对齐。
      // 断点取 300：并排时说明列只剩 `宽 - 68`，而时间文本本身就要 228 px。
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth < 300) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                info,
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerRight, child: action),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: info),
              const SizedBox(width: 12),
              action,
            ],
          );
        },
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
    if (candidate.state == RecoveryState.unchecked) {
      // ⚠️ 不能说「读不出里面的内容」—— 那是「检查过、读不出」的结论，
      // 这两件事对用户的含义完全相反（前者是坏文件，后者是还没看）。
      //
      // 正在接回另一份时这一行没有按钮可点，所以不能叫用户去点（纪律 17）。
      if (_restoring) {
        return candidate.path == _restoringPath
            ? '正在体检这一份…'
            : '还没检查 —— 等这一份接完再点别的';
      }
      return '还没检查 —— 点「用这一份」会先体检这一份，通过才接回';
    }
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
    // ⚠️ 未体检时**不要**把「还没检查」拼进来：用户已经点了「用这一份」，
    // 再说一遍「还没检查」像是没响应。体检就在确认之后、复制之前（`_restoreSync`）。
    final String content = candidate.state == RecoveryState.unchecked
        ? ''
        : '，${_describeContent(candidate)}';
    return '${formatRecoveryTime(candidate.time)} 的那份'
        '（${_sourceLabel(candidate.source)}，${formatRecoverySize(candidate.bytes)}'
        '$content）';
  }

  String _sourceLabel(RecoverySource source) => switch (source) {
    RecoverySource.autoBackup => '自动备份',
    RecoverySource.manualBackup => '手动备份',
    RecoverySource.beforeMigration => '升级前留存',
  };

  String _summary(List<RecoveryCandidate> usable) {
    final int total = _candidates.length;
    if (total == 0) return '';
    final int unchecked = _candidates
        .where((RecoveryCandidate c) => c.state == RecoveryState.unchecked)
        .length;
    if (unchecked > 0) {
      // 清单先行：没体检是**常态**，不是「不能用」。
      return '共 $total 份（$unchecked 份还没检查）。点哪一份就先体检哪一份。';
    }
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
