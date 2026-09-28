/// 设置页：界面缩放（五档 + 重置）+ 店名 + 数据安全区。
///
/// ## 裁定落点（`docs/reply_review.md` §AC）
///
/// - **SC-1**：缩放是**全局文字缩放**（`TextScaler`，中老年用户的本命功能）+
///   导航宽度联动；**必须有「重置」按钮**（调到 200% 发现乱了一键恢复，遗漏 2）
/// - **SC-2**：店名 ≤ 20 字符，显示在概览页顶部（本页只采集）
/// - **遗漏 1（数据安全区）**：位置 / 备份目录 + 「打开文件夹」按钮 ——
///   用户想看那里有什么，让看不让点是纯粹的挫败。**「立即备份」按钮 v1 不放**
///   （备份执行机制尚未实现，空按钮比不做糟，§AA 同款判断；记录在案）
/// - 修改**立即生效**：`onChanged` 回调把新 `AppConfig` 交给宿主
///   （`ShensuanziApp` setState + `configStore.save`），不等「保存」按钮
///   —— 这类偏好不需要确认动作
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

/// 设置页。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.config,
    required this.configStore,
    this.backupDirectory,
    required this.onChanged,
  });

  /// 当前配置（宿主持有真相，本页只编辑）
  final AppConfig config;

  /// 配置的读写入口（改完立即 `save` + 回调宿主）
  final AppConfigStore configStore;

  /// 备份目录（宿主从 `DataLocation` 带来；`null` = 不显示该行）
  final String? backupDirectory;

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

  @override
  void dispose() {
    _shopName.dispose();
    super.dispose();
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

              // ---- 数据安全区（遗漏 1：位置 / 备份目录 + 「打开文件夹」）----
              _Section(
                title: '数据',
                children: <Widget>[
                  if (_current.dataDirectory != null) ...<Widget>[
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
                  Text(
                    '每天关店前软件会提醒备份；备份文件夹在数据文件夹旁边。',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
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
