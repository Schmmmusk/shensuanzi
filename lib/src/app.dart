/// 应用启动流程。
///
/// ```text
/// 启动 → AppEnvironment.detect()
///   → service.existing()                 // 配置里的位置现在还能用吗
///        ├─ 能 → 直接开库 → 主界面
///        └─ 不能 → 弹「选择数据存放位置」→ 开库 → 主界面
/// ```
///
/// 为什么 `existing()` 要**重跑一遍校验**而不是信配置：用户可能把数据目录
/// 搬走了、盘符变了、标记文件被删了 —— 配置里「有路径」不等于「能用」。
/// 详见 `docs/data_directory.md` §六。
///
/// ⚠️ **打开数据库在这里发生**（而不是在对话框里）：对话框只管「路径可用」，
/// 库能不能建起来是下一步的事，两件事分开才能把失败原因说清楚。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'folder_picker.dart';
import 'ui/app_shell.dart';
import 'ui/data_directory_dialog.dart';

class ShensuanziApp extends StatefulWidget {
  const ShensuanziApp({super.key});

  @override
  State<ShensuanziApp> createState() => _ShensuanziAppState();
}

class _ShensuanziAppState extends State<ShensuanziApp> {
  /// 真机事实只探测一次（盘符 / 环境变量）
  final DataDirectoryService _service = DataDirectoryService(
    environment: AppEnvironment.detect(),
  );

  DataLocation? _location;

  /// 打开着的数据库；成功后一直持有，供后续功能页使用
  Db? _db;

  /// 开库失败的原因（含「怎么办」）
  String? _dbFailure;

  @override
  void initState() {
    super.initState();
    // 首帧之后再弹对话框：此时才有可用的 Navigator
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }

  Future<void> _prepare() async {
    final DataLocation? existing = _service.existing();
    if (existing != null) {
      _openDatabase(existing);
      return;
    }
    if (!mounted) return;

    final DataLocation? chosen = await showDataDirectoryDialog(
      context,
      model: DataDirectoryDialogModel(_service),
      pickDirectory: pickDirectory,
    );
    if (chosen == null) return; // 用户退出了 —— 界面会停在「需要选择位置」
    _openDatabase(chosen);
  }

  void _openDatabase(DataLocation location) {
    try {
      final Db db = _service.open(location);
      setState(() {
        _location = location;
        _db = db;
        _dbFailure = null;
      });
    } catch (error) {
      setState(() {
        _location = location;
        _db = null;
        _dbFailure = '数据文件打不开（$error）。'
            '如果这个文件夹在 U 盘或网盘里，请换到本机磁盘上的文件夹。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '神算子',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // 低饱和蓝作主色：红色只留给错误与告警（`docs/ui_principles.md` §二）
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FA8)),
        scaffoldBackgroundColor: const Color(0xFFFAFAFA),
        useMaterial3: true,
      ),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (_dbFailure != null) {
      return _StartupPage(
        message: _dbFailure!,
        actionLabel: '重新选择位置',
        onAction: () async {
          setState(() => _dbFailure = null);
          _location = null;
          _db = null;
          await _prepare();
        },
      );
    }

    final DataLocation? location = _location;
    if (location == null) {
      return _StartupPage(
        message: '需要一个文件夹来存放数据，才能开始使用。',
        actionLabel: '选择数据存放位置',
        onAction: _prepare,
      );
    }

    return AppShell(
      dataDirectory: location.directory,
      backupDirectory: location.backupDirectory,
      schemaVersion: location.marker.schemaVersion,
      databaseReady: _db != null,
    );
  }
}

/// 还没进入主界面时的过渡页（选位置 / 开库失败）。
///
/// 刻意**不做**欢迎页、店名输入、账户预设 —— 那些按 `docs/reply.md` §五
/// 放到第 10 天回补。
class _StartupPage extends StatelessWidget {
  const _StartupPage({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            // 常驻可见的文字按钮，不用图标（`docs/ui_principles.md` §1.1）
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    ),
  );
}
