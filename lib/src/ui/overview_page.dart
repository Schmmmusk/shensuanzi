/// 概览页 —— 回答三个问题：**我的数据在哪**、**现在能不能用**、**数据安全吗**。
///
/// 这是落地页（左侧导航第一项）。刻意不塞业务数字：等核心闭环做完，
/// 这里才放「今日销售 / 库存告急 / 欠款」这类聚合（RULE-006 的查询已就绪）。
///
/// ## 裁定落点（`docs/reply_review.md` §AE-3 / §AE-5）
///
/// - **橙卡**（AE-3 的「两层机制」上层）：单次备份失败**静默**，但
///   「超过 3 天没成功备份」必须在**用户不会主动打开设置页**的地方说出来 ——
///   概览页原本就是启动落地页，它有这个位置优势。
/// - **文案与判定都来自纯 Dart**（`backupReminderText`）：这里只负责摆，
///   不造句、不算天数（`docs/ui_principles.md` §二）。
/// - **按钮防抖**（遗漏 11）：点下去立刻禁用 +「备份中…」—— 用户要确信
///   「我的操作被接受了」；服务侧的单飞是兜底，不是替代。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

/// 提醒橙 —— **不用错误红**（可以不拦人的提醒一律橙色，
/// `docs/ui_principles.md` §1.3；与 `product_form_dialog.dart` 的内联提示同色）
const Color _noticeColor = Color(0xFFB45309);
const Color _noticeBackground = Color(0xFFFFF7ED);

class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.dataDirectory,
    required this.backupDirectory,
    required this.schemaVersion,
    required this.databaseReady,
    this.shopName,
    this.backupReminder,
    this.onBackupNow,
    this.locationNote,
  });

  /// 数据目录（用户选的，数据库就放在这里）
  final String dataDirectory;

  /// 备份目录（数据目录的**兄弟目录**，见 `docs/data_directory.md` §八）
  final String backupDirectory;

  final int schemaVersion;

  /// 数据库是否已成功打开
  final bool databaseReady;

  /// 店名（设置页采集；空则显示「概览」，SC-2）
  final String? shopName;

  /// 备份提醒文案（`null` = 不需要提醒 → 不显示橙卡）。
  /// 由 `shensuanzi_app` 的 `backupReminderText` 给出 —— 与设置页红字同源
  final String? backupReminder;

  /// 「立即备份」；`null` = 备份不可用（库还没打开）→ 不显示按钮
  final Future<BackupOutcome> Function()? onBackupNow;

  /// 「你的数据在」的显示文案（§BH·五 B1b 裁定 2：Android 私有目录用户
  /// 打不开，显示友好文案而非具体路径；路径挪到帮助页「关于」小字）。
  /// `null` = 显示真实路径（桌面行为，零变化）。
  final String? locationNote;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  bool _busy = false;

  /// 遗漏 11：**视觉反馈优先于逻辑防护** —— 先禁用按钮，再谈并发。
  /// 结果文案（含完整路径）由领域层给（`backupOutcomeMessage`，遗漏 5）。
  Future<void> _backupNow() async {
    final Future<BackupOutcome> Function()? run = widget.onBackupNow;
    if (run == null || _busy) return;
    setState(() => _busy = true);
    final BackupOutcome outcome = await run();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(backupOutcomeMessage(outcome)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? reminder = widget.backupReminder;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        // ---- 数据安全橙卡（AE-3：用户不会主动查，所以要主动呈现）----
        if (reminder != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              margin: EdgeInsets.zero,
              color: _noticeBackground,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 22,
                      color: _noticeColor,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            reminder,
                            style: const TextStyle(height: 1.6),
                          ),
                          const SizedBox(height: 10),
                          if (widget.onBackupNow != null)
                            FilledButton.icon(
                              key: const Key('overview-backup-now'),
                              onPressed: _busy ? null : _backupNow,
                              icon: const Icon(Icons.save_alt, size: 18),
                              label: Text(_busy ? '备份中…' : '立即备份'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        if (widget.shopName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              widget.shopName!,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('你的数据在', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                if (widget.locationNote != null)
                  Text(
                    widget.locationNote!,
                    style: const TextStyle(height: 1.6),
                  )
                else ...<Widget>[
                  SelectableText(
                    widget.dataDirectory,
                    style: const TextStyle(height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '备份会放在旁边：${widget.backupDirectory}',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Icon(
                      widget.databaseReady
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 20,
                      color: widget.databaseReady
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.databaseReady
                            ? '数据文件已就绪（版本 ${widget.schemaVersion}）'
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
