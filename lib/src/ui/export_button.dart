/// 导出按钮 —— **五个列表页共用**（§AF-2：每页右上角，按钮文案每页不同）。
///
/// ## 判断不在这里
///
/// 导什么、列怎么排、怎么转义、写哪个文件全在 `shensuanzi_app`
/// （`ExportService` + `export_tables.dart`）。本控件只做三件事：
///
/// | 事 | 依据 |
/// |---|---|
/// | 点击即禁用 +「导出中…」 | 遗漏 3（视觉反馈优先于逻辑防护） |
/// | 先弹「正在导出…」，出结果再替换 | AF-11 的「更简单」版：100ms 完成用户看不到，1 秒完成用户看到「在做事」 |
/// | 结果交给 SnackBar（成功带**完整路径** + 「打开文件夹」） | 遗漏 5 / AF-4 |
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

/// 打开文件管理器并**选中**刚导出的文件。
///
/// ⚠️ **`/select,` 后面那个逗号是微软的语法**（AF-4）——
/// 少写它只会打开目录、不选中文件，用户还得自己找。
Future<void> revealInExplorer(String path) async {
  try {
    await Process.run('explorer', <String>['/select,', path]);
  } catch (_) {
    // 打不开不影响结论：用户还能自己在文件夹里找
  }
}

class ExportButton extends StatefulWidget {
  const ExportButton({super.key, required this.label, required this.export});

  /// 按钮文字（**说清导的是什么**：`导出全部商品` / `导出当前筛选的单据`…）
  final String label;

  /// 真正的导出动作（页面把表拼好交进来）
  final Future<ExportOutcome> Function() export;

  @override
  State<ExportButton> createState() => _ExportButtonState();
}

class _ExportButtonState extends State<ExportButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    // ⚠️ 先取 messenger：await 之后再用 context 会被
    // `use_build_context_synchronously` 拦，而且那时候 widget 可能已经没了
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    messenger.showSnackBar(
      const SnackBar(content: Text('正在导出…'), duration: Duration(seconds: 2)),
    );

    final ExportOutcome outcome = await widget.export();
    if (!mounted) return;
    setState(() => _busy = false);

    // ⚠️ 这里**故意**不用 `showSnack`：await 之后 `context` 可能已经失效，
    // 只能用 await 之前取好的 messenger。它自带 removeCurrentSnackBar（F12 的两条规矩都满足）。
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(exportOutcomeMessage(outcome)),
          duration: const Duration(seconds: 6),
          // ⚠️ `persist: false` **必须显式写**（2026-10-28 用户实测 P2）：
          // Flutter 3.38+ 的 M3 规范里 `persist` 默认是 `action != null`
          // （SDK `snack_bar.dart:303`）—— 带按钮的 SnackBar **永远不退**，
          // 只能被下一条挤下去。用户原话：「弹出的消息不自动退下，容易以为软件坏了」。
          persist: false,
          action: outcome is ExportSuccess
              ? SnackBarAction(
                  label: '打开文件夹',
                  onPressed: () => revealInExplorer(outcome.path),
                )
              : null,
        ),
      );
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: _busy ? null : _run,
    icon: const Icon(Icons.ios_share, size: 18),
    label: Text(_busy ? '导出中…' : widget.label),
  );
}
