/// 首启「选择数据存放位置」对话框。
///
/// ## 这个 widget 只负责画
///
/// 默认路径从哪来、什么时候算警告、什么时候要二次确认、按钮该不该可点 ——
/// **全部在 [DataDirectoryDialogModel] 里**（纯 Dart，`dart test` 覆盖）。
/// 这里只做三件事：
///
/// 1. 把 model 的字段摆到屏幕上
/// 2. 「更改」→ 调系统文件夹选择器，把结果交给 `model.choosePath`
/// 3. 「开始使用」→ 调 `model.confirm`，成功就把 `location` pop 回去
///
/// **为什么这么薄**：Flutter 的 widget 测试在本机跑不了，能验证的只有纯 Dart。
/// 把判断全挪走，这一层的出错面就只剩「摆放」。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

/// 弹对话框。返回 `null` = 用户没选就退出了（调用方需要处理这种情况）。
///
/// [pickDirectory] 由调用方注入（见 `src/folder_picker.dart`）——
/// 这样 widget 本身不依赖任何插件，可被替换成任意实现。
Future<DataLocation?> showDataDirectoryDialog(
  BuildContext context, {
  required DataDirectoryDialogModel model,
  required Future<String?> Function() pickDirectory,
  bool firstRun = false,
  String? lostLocationNote,
  String? defaultPath,
}) => showDialog<DataLocation>(
  context: context,
  // 数据位置是启动前提：点外面关掉会让程序卡在「没有库」的状态
  barrierDismissible: false,
  builder: (BuildContext dialogContext) => _DataDirectoryDialog(
    model: model,
    pickDirectory: pickDirectory,
    firstRun: firstRun,
    lostLocationNote: lostLocationNote,
    defaultPath: defaultPath,
  ),
);

class _DataDirectoryDialog extends StatefulWidget {
  const _DataDirectoryDialog({
    required this.model,
    required this.pickDirectory,
    required this.firstRun,
    this.lostLocationNote,
    this.defaultPath,
  });

  final DataDirectoryDialogModel model;
  final Future<String?> Function() pickDirectory;

  /// 覆盖「机器给的默认位置」（**仅供测试注入**，§BR·补 2 方案 B）；
  /// `null` = 用 `model.open()` 自己解析出来的真实默认位置。
  /// ⚠️ 必须与 `startupDecision(defaultDataDirectory:)` 的注入值一致（见 `open` 的注释）。
  final String? defaultPath;

  /// 替换掉「欢迎」那一句的说明；`null` = 显示默认内容。
  ///
  /// 三种来源（都与 [firstRun] 互斥 —— 它们出现的场景**都不是**「第一次启动」）：
  ///
  /// 1. §审查 OBS-15：配置**读不懂**（`locationLost`）—— 说「数据没丢，
  ///    只是我记不住位置了」，并给找回的路；
  /// 2. §AG 遗漏 1：位置**记着**但那文件夹现在用不了（被搬走 / 盘符变了）
  ///    —— 说清「上次用的是哪个、该怎么办」；
  /// 3. §审查 OBS-11 前半：首启撞上「默认位置已有数据」，用户选了「新位置」
  ///    —— 说清「那份数据不会被删」（免得他以为被覆盖了）。
  final String? lostLocationNote;

  /// **是不是真的第一次启动**（还没有任何配置）。
  ///
  /// 为什么不能「对话框一出现就当首次」：这个对话框**两种情况都会出现** ——
  /// 真正的首次启动，以及「配置里的位置失效了」（盘符变了 / 数据被搬走 / 设置被清）。
  /// 后者再显示「这是第一次启动」就是**假话**（§AG 遗漏 1）。
  final bool firstRun;

  @override
  State<_DataDirectoryDialog> createState() => _DataDirectoryDialogState();
}

class _DataDirectoryDialogState extends State<_DataDirectoryDialog> {
  /// 选择器 / 落盘进行中 —— 期间禁掉按钮，避免重复点
  bool _busy = false;

  DataDirectoryDialogModel get _model => widget.model;

  @override
  void initState() {
    super.initState();
    // 首次打开：用**默认位置**起步（不弹目录框，用户直接确认或更改）
    if (_model.path.isEmpty) _model.open(defaultPath: widget.defaultPath);
  }

  Future<void> _onPick() async {
    setState(() => _busy = true);
    try {
      final String? picked = await widget.pickDirectory();
      if (picked != null && picked.trim().isNotEmpty) {
        _model.choosePath(picked);
      }
    } catch (_) {
      // 选择器自身出错（权限 / 插件异常）不该让对话框崩掉：
      // 保持原路径，用户还能「更改」或直接用默认位置
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onConfirm() async {
    setState(() => _busy = true);
    // 二次确认：按钮文案是「就用这个文件夹」时才放行
    final ConfirmOutcome outcome = _model.confirm(
      acceptForeign: _model.needsForeignConfirm,
    );
    if (!mounted) return;
    if (outcome == ConfirmOutcome.created || outcome == ConfirmOutcome.reused) {
      Navigator.of(context).pop(_model.location);
      return;
    }
    setState(() => _busy = false);
  }

  /// 「开始使用」该不该可点。
  ///
  /// ⚠️ 与 `model.canConfirm` 不同：**二次确认时 `canConfirm` 是 `false`**
  /// （因为要先问），但按钮要能点 —— 点了就是「我确认」。
  bool get _primaryEnabled => _model.needsForeignConfirm || _model.canConfirm;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AlertDialog(
      title: const Text('选择数据存放位置'),
      content: SizedBox(
        width: 420,
        // ⚠️ **内容必须可滚动**（2026-09-29 回归修复）。
        //
        // 起因：加了首启欢迎语之后，`flutter test` 的两个启动场景报
        // 「A RenderFlex overflowed by 36 pixels on the bottom」。
        // **这不是测试挑剔 —— 是真缺陷**：内容高度 = 欢迎语 + 路径 + 容量提示 +
        // 提醒 + 按钮，在**缩放调到 200%**（本软件已发布的最高档，中老年用户的本命功能）
        // 或窗口很小时会顶出屏幕，用户**看不到「开始使用」按钮** ——
        // 首启就卡住，是最糟的一种失败。
        //
        // 用 `SingleChildScrollView` 而不是「把字改小」：字号是给用户放大的，
        // 不该为了塞进 380px 而牺牲可读性。
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // §AG 遗漏 1：首启的第一句话要回答「这是什么、会不会上传」——
              // 用户刚解压完就被问「放哪」，不解释一句他会以为程序有问题。
              // ⚠️ 只在**真正的首次启动**显示（见 [firstRun]）。
              if (widget.firstRun) ...<Widget>[
                Text(
                  '欢迎使用神算子',
                  style: const TextStyle(
                    height: 1.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '这是第一次启动。请告诉神算子把你的数据放在哪 —— '
                  '数据存在你自己电脑里，不会上传。',
                  style: const TextStyle(height: 1.6),
                ),
                const SizedBox(height: 16),
              ],
              // §审查 OBS-15：配置读不懂时替换掉「欢迎」的位置 ——
              // 说的是「数据还在，只是我记不住位置了」，并给一条找回的路
              if (widget.lostLocationNote != null) ...<Widget>[
                Text(
                  widget.lostLocationNote!,
                  style: const TextStyle(
                    height: 1.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(
                _model.needsForeignConfirm
                    ? '这个文件夹里已经有别的东西：'
                    : '建议放在非系统盘：',
                style: const TextStyle(height: 1.6),
              ),
              const SizedBox(height: 8),
              // 路径可能很长（`C:\Users\xxx\...`），给用户能选中复制的机会
              SelectableText(
                _model.path,
                style: const TextStyle(height: 1.6, fontWeight: FontWeight.w600),
              ),
              if (_model.capacityHint != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  _model.capacityHint!,
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              ],
              if (_model.notice != null) ...<Widget>[
                const SizedBox(height: 12),
                _noticeBox(context),
              ],
              const SizedBox(height: 12),
              Text(
                '不要放在 U 盘或网盘同步文件夹里。',
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : _onPick,
          child: const Text('更改'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => Navigator.of(context).pop(null),
          child: const Text('退出'),
        ),
        FilledButton(
          onPressed: (_busy || !_primaryEnabled) ? null : _onConfirm,
          child: Text(_model.needsForeignConfirm ? '就用这个文件夹' : '开始使用'),
        ),
      ],
    );
  }

  /// 提示条：**图标 + 颜色 + 一句话（含「怎么办」）**。
  ///
  /// 颜色不能只用红绿区分 —— 中老年用户里色觉异常的比例不低，
  /// 所以同时给图标与文字。
  Widget _noticeBox(BuildContext context) {
    final bool isError = _model.noticeKind == DialogNoticeKind.error;
    final Color color = isError
        ? Theme.of(context).colorScheme.error
        // 低饱和橙：警告不用纯红（`docs/ui_principles.md` §二）
        : const Color(0xFF9A5B00);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            isError ? Icons.error_outline : Icons.warning_amber_outlined,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _model.notice!,
              style: TextStyle(color: color, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}
