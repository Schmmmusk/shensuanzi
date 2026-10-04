/// 设置页：界面缩放（五档 + 重置）+ 店名 + 数据安全区（含备份）。
///
/// ## 裁定落点（`docs/reply_review.md` §AC + §AE）
///
/// - **SC-1**：缩放是**全局文字缩放**（`TextScaler`，中老年用户的本命功能）+
///   导航宽度联动；**必须有「重置」按钮**（调到 200% 发现乱了一键恢复，遗漏 2）
/// - **SC-2**：店名 ≤ 20 字符，显示在概览页顶部（本页只采集）
/// - **遗漏 1（数据安全区）**：位置 / 备份目录 + 「打开文件夹」按钮 ——
///   用户想看那里有什么，让看不让点是纯粹的挫败。
/// - **§AE-5**：「上次备份：时间（来源）」+ 需要提醒时**红字**
///   （超 3 天没备份，**或最近一次备份没成功** —— 遗漏 2）；状态行可点开目录
/// - **§AE 遗漏 5**：手动备份的结果用 SnackBar 说（成功带完整路径）
/// - **§AE 遗漏 6**：第一次进设置页的人不知道「上次备份：从未」是什么意思
///   —— 补两行说明，并把 §AE-1 的技术承诺（**普通数据库文件**）写进界面
/// - **§AE 遗漏 11**：点了「立即备份」立刻禁用 +「备份中…」
/// - 修改**立即生效**：`onChanged` 回调把新 `AppConfig` 交给宿主
///   （`ShensuanziApp` setState + `configStore.save`），不等「保存」按钮
///   —— 这类偏好不需要确认动作
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

import 'host_service_section.dart';

/// 设置页。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.config,
    required this.configStore,
    this.backupDirectory,
    this.backupStatusLine,
    this.backupNeedsAttention = false,
    this.onBackupNow,
    this.hostService,
    this.dataPathsNote,
    this.hostSyncNote,
    this.onExportBackup,
    required this.onChanged,
  });

  /// 当前配置（宿主持有真相，本页只编辑）
  final AppConfig config;

  /// 配置的读写入口（改完立即 `save` + 回调宿主）
  final AppConfigStore configStore;

  /// 备份目录（宿主从 `DataLocation` 带来；`null` = 不显示该行）
  final String? backupDirectory;

  /// 「上次备份：…」整行文案（纯 Dart 的 `backupStatusLine` 给；
  /// `null` = 备份不可用 → 整块不显示）
  final String? backupStatusLine;

  /// 超 3 天没备份 → 状态行标红（AE-5）
  final bool backupNeedsAttention;

  /// 「立即备份」；`null` = 不可用 → 不显示按钮（空按钮比不做糟）
  final Future<BackupOutcome> Function()? onBackupNow;

  /// 主机同步服务（§AH · AH-A）。`null` = 库没开起来 / 页面在测试里单跑
  /// ⇒ 整块显示「不可用」而不是装作能用（与 `backupStatusLine` 同款判定）。
  final HostServiceController? hostService;

  /// 数据区路径行的替代文案（§BH·六 B1c：Android 私有目录用户打不开，
  /// 「打开」按钮无效 ⇒ 显示友好文案、隐藏两行路径）。`null` = 桌面（零变化）。
  final String? dataPathsNote;

  /// 多设备同步区的替代文案（§BH·六 B1c：Android 是**客户端**，不做主机 ——
  /// 显示「到电脑上开主机、手机扫码」的引导）。`null` = 桌面（hostService 面板）。
  final String? hostSyncNote;

  /// 「导出备份到手机文件」（§BH·六 B1c；裁定：v1.1 之前必须有）。
  /// 宿主实现（SAF 选位置 → 拷贝 db 文件），返回给用户看的结果文案；
  /// `null` = 不显示入口（桌面备份在兄弟目录，直接可拷）。
  final Future<String> Function()? onExportBackup;

  /// 任何修改都会回调（宿主据此热应用缩放 / 店名）
  final void Function(AppConfig config) onChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _shopName =
      TextEditingController(text: widget.config.shopName ?? '');

  /// **本页的当前生效配置** —— 每次修改基于它（而不是打开页面时的快照），
  /// 否则连续改两项（先缩放再店名）会互相覆盖
  late AppConfig _current = widget.config;

  /// 店名超长的即时提示（SC-2：≤ 20 字符）
  String? _shopNameError;

  /// 「立即备份」进行中（遗漏 11：禁用 + 文案，先给反馈再谈并发）
  bool _backupBusy = false;

  /// 「导出备份」进行中（§BH·六 B1c；与备份按钮同款「先禁用再谈并发」）
  bool _exporting = false;

  @override
  void dispose() {
    _shopName.dispose();
    super.dispose();
  }

  /// 手动「立即备份」。文案（含完整路径）来自领域层，本页不造句。
  Future<void> _backupNow() async {
    final Future<BackupOutcome> Function()? run = widget.onBackupNow;
    if (run == null || _backupBusy) return;
    setState(() => _backupBusy = true);
    final BackupOutcome outcome = await run();
    if (!mounted) return;
    setState(() => _backupBusy = false);
    // 遗漏 5：SnackBar 带完整路径（用户可立刻复制到文件管理器）
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(backupOutcomeMessage(outcome)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 「导出备份到手机文件」（§BH·六 B1c）。宿主实现（SAF 选位置 → 拷贝
  /// db 文件），返回的文案直接进 SnackBar（与「立即备份」同款反馈）。
  Future<void> _exportBackup() async {
    final Future<String> Function()? run = widget.onExportBackup;
    if (run == null || _exporting) return;
    setState(() => _exporting = true);
    // ⚠️ **必须兜住一切异常** —— 真机教训：file_selector 在 Android 不支持
    // 「选保存位置」，抛出后 `_exporting` 永远 true（只剩转圈）。
    String message;
    try {
      message = await run();
    } catch (error) {
      message = '导出失败（$error）—— 请把这句话告诉技术支持';
    }
    if (!mounted) return;
    setState(() => _exporting = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  void _apply(AppConfig newConfig) {
    setState(() => _current = newConfig);
    widget.configStore.save(newConfig);
    widget.onChanged(newConfig);
  }

  void _updateShopName(String text) {
    final String trimmed = text.trim();
    if (trimmed.length > 20) {
      setState(() => _shopNameError = '店名最长 20 个字，多出的部分不会被保存');
      return;
    }
    setState(() => _shopNameError = null);
    _apply(
      AppConfig(
        dataDirectory: _current.dataDirectory,
        uiScale: _current.uiScale,
        shopName: trimmed.isEmpty ? null : trimmed,
      ),
    );
  }

  /// 用系统文件管理器打开文件夹（Windows；打开失败静默 —— 不打断用户）
  Future<void> _openFolder(String path) async {
    try {
      await Process.run('explorer', <String>[path]);
    } catch (_) {
      // explorer 打不开（路径失效等）不影响页面
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final UiScale current = _current.uiScale;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('设置', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),

              // ---- 界面缩放（SC-1 + 遗漏 2）----
              _Section(
                title: '界面大小',
                children: <Widget>[
                  Text(
                    '觉得字小就调大。改完立即生效，全应用一起变。',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<UiScale>(
                    key: const Key('setting-scale'),
                    initialValue: current,
                    items: <DropdownMenuItem<UiScale>>[
                      for (final UiScale scale in UiScale.values)
                        DropdownMenuItem<UiScale>(
                          value: scale,
                          child: Text(scale.label),
                        ),
                    ],
                    onChanged: (UiScale? value) {
                      if (value == null || value == _current.uiScale) return;
                      _apply(
                        AppConfig(
                          dataDirectory: _current.dataDirectory,
                          uiScale: value,
                          shopName: _current.shopName,
                        ),
                      );
                    },
                    decoration: const InputDecoration(
                      labelText: '界面大小',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 遗漏 2：一键重置 —— 200% 下发现乱了的退路
                  TextButton.icon(
                    key: const Key('setting-reset-scale'),
                    onPressed: _current.uiScale == UiScale.standard
                        ? null
                        : () => _apply(
                            AppConfig(
                              dataDirectory: _current.dataDirectory,
                              uiScale: UiScale.standard,
                              shopName: _current.shopName,
                            ),
                          ),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('恢复默认大小'),
                  ),
                ],
              ),

              // ---- 店名（SC-2）----
              _Section(
                title: '店名（可选）',
                children: <Widget>[
                  TextField(
                    key: const Key('setting-shop-name'),
                    controller: _shopName,
                    // 刻意**不设 maxLength**：输入阶段截断会让 onChanged 永远
                    // 收不到超长文本，「超长提示」成死代码 —— 放手让用户输入，
                    // 超长时显示提示且不落盘（SC-2）
                    onChanged: _updateShopName,
                    decoration: InputDecoration(
                      labelText: '店名',
                      hintText: '显示在概览页，比如「王记小卖部」',
                      errorText: _shopNameError,
                      counterText: '',
                    ),
                  ),
                ],
              ),

              // ---- 数据安全区（遗漏 1 + §AE-5 / 遗漏 5、6、11）----
              _Section(
                title: '数据',
                children: <Widget>[
                  // §BH·六 B1c：Android 私有目录用户打不开，「打开」按钮无效
                  // ⇒ 显示友好文案、隐藏两行路径（桌面 `null` = 零变化）
                  if (widget.dataPathsNote != null)
                    Text(
                      widget.dataPathsNote!,
                      style: TextStyle(
                        height: 1.6,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    )
                  else if (_current.dataDirectory != null) ...<Widget>[
                    _FolderRow(
                      label: '数据位置',
                      path: _current.dataDirectory!,
                      onOpen: () => _openFolder(_current.dataDirectory!),
                    ),
                    if (widget.backupDirectory != null) ...<Widget>[
                      const SizedBox(height: 8),
                      _FolderRow(
                        label: '备份位置',
                        path: widget.backupDirectory!,
                        onOpen: () => _openFolder(widget.backupDirectory!),
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],
                  if (widget.backupStatusLine != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            widget.backupStatusLine!,
                            style: TextStyle(
                              height: 1.6,
                              // AE-5：超 3 天没备份 → 红字（数据安全要看得见）
                              color: widget.backupNeedsAttention
                                  ? theme.colorScheme.error
                                  : null,
                              fontWeight: widget.backupNeedsAttention
                                  ? FontWeight.w700
                                  : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (widget.onBackupNow != null)
                          FilledButton.icon(
                            key: const Key('setting-backup-now'),
                            onPressed: _backupBusy ? null : _backupNow,
                            icon: const Icon(Icons.save_alt, size: 18),
                            label: Text(_backupBusy ? '备份中…' : '立即备份'),
                          ),
                      ],
                    ),
                  ],
                  // §BH·六 B1c（裁定：v1.1 之前必须有）：卸载 = 数据全丢，
                  // Android 上唯一的保留手段就是导出备份
                  if (widget.onExportBackup != null) ...<Widget>[
                    const SizedBox(height: 4),
                    ListTile(
                      key: const Key('setting-export-backup'),
                      contentPadding: EdgeInsets.zero,
                      leading: _exporting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload_file_outlined),
                      title: Text(
                        _exporting ? '导出中…' : '导出备份到手机文件',
                        style: const TextStyle(height: 1.6),
                      ),
                      subtitle: Text(
                        '把备份文件存到你选的位置（可发微信 / 存网盘）',
                        style: TextStyle(
                          height: 1.6,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _exporting ? null : _exportBackup,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    // 遗漏 6：第一次看到「上次备份：从未」的人要知道这是什么，
                    // 以及「数据永远属于他」（§AE-1 的技术承诺写进界面）
                    '每天首次打开软件会自动备份一次。\n'
                    '备份文件是普通的数据库文件，可以用任何 SQLite 工具打开。',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ],
              ),

              // ---- 多设备同步（§AH · AH-A 落地；原 §AG-6「开发中」占位在此退场）----
              //
              // §AG-6 当年裁定「显示一行灰字、不隐藏」：藏起来用户不会知道将来
              // 会有这个功能。现在功能真的到了，占位换成实装 —— 那条裁定的目的
              // （让用户看得见产品在往哪走）已完成，不是被推翻。
              _Section(
                title: '多设备同步',
                children: <Widget>[
                  // §BH·六 B1c：Android 是**客户端**，不做主机 —— 显示引导
                  // 而不是 Windows 同款二维码（真机反馈，2026-10-04）
                  if (widget.hostSyncNote != null)
                    Text(
                      widget.hostSyncNote!,
                      style: TextStyle(
                        height: 1.6,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    )
                  else if (widget.hostService == null)
                    Text(
                      '数据目录还没准备好，这个功能暂时用不了。'
                      '先把上面的数据位置设好，再回来打开它。',
                      style: TextStyle(height: 1.6, color: theme.hintColor),
                    )
                  else
                    HostServicePanel(controller: widget.hostService!),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 数据安全区的一行：路径 + 「打开文件夹」按钮
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.label,
    required this.path,
    required this.onOpen,
  });

  final String label;
  final String path;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label, style: const TextStyle(height: 1.6)),
              Text(
                path,
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: onOpen,
          icon: const Icon(Icons.folder_open, size: 18),
          label: const Text('打开'),
        ),
      ],
    );
  }
}

/// 一个小节：标题 + 内容（与帮助页同构；两页都用「标题 + 卡片内容」的形态）
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}
