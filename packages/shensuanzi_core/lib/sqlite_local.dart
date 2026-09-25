// 本地（纯 Dart）运行时的 SQLite 原生库加载辅助。
//
// **生产路径不依赖本文件**：Flutter 应用由 `sqlite3_flutter_libs` 提供原生库。
// 本文件只服务于「不启动 Flutter 的本地验证」场景
// （各包的 `test/` 与 `tool/selfcheck*.dart`）。
//
// 放在 `lib/` 而不是 `tool/`：**`shensuanzi_host` 的测试也要用它**，
// 而包之间只能通过 `package:` 导入。故它是 core 的公开 API 之一，
// 但**不在 `shensuanzi_core.dart` 里 re-export** —— 需要时显式：
//
// ```dart
// import 'package:shensuanzi_core/sqlite_local.dart';
// ```
//
// 加载顺序：
//   1. 环境变量 `SQLITE3_DLL` 指定的绝对路径（最高优先级，便于指定任意 SQLite 构建）
//   2. 系统默认查找（`sqlite3.dll`）
//   3. Windows 内置的 `winsqlite3.dll`（无官方 sqlite3.dll 时的兜底）

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

bool _installed = false;

/// 幂等；多次调用只有第一次生效。
void useLocalSqlite() {
  if (_installed) return;
  _installed = true;
  if (!Platform.isWindows) return;
  open.overrideFor(OperatingSystem.windows, _openWindows);
}

DynamicLibrary _openWindows() {
  final List<String> candidates = _candidates();
  final List<String> failures = <String>[];
  for (final String candidate in candidates) {
    try {
      return DynamicLibrary.open(candidate);
    } catch (e) {
      failures.add('$candidate → $e');
    }
  }
  throw StateError(
    '未能加载 SQLite 原生库。已尝试：\n  ${failures.join('\n  ')}\n'
    '请设置环境变量 SQLITE3_DLL 指向可用的 sqlite3.dll。',
  );
}

List<String> _candidates() {
  final String? fromEnv = Platform.environment['SQLITE3_DLL'];
  return <String>[
    if (fromEnv != null && fromEnv.isNotEmpty) fromEnv,
    'sqlite3.dll',
    r'C:\Windows\System32\winsqlite3.dll',
  ];
}
