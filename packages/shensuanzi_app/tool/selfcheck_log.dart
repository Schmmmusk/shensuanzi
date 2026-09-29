// 最小日志（`AppLog` / `formatLogLine`）的**自检**（§AG-5）。
//
// ⚠️ 与 `test/log_test.dart` 是**两套并行镜像断言**：改一边必须改另一边，
// 且断言用的 API 名也要一致（`docs/testing.md` §零「四条硬纪律」第 1 条）。
//
// 跑法：`dart run tool/selfcheck_log.dart`
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name');
  } else {
    _fail++;
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  →  $detail'}');
  }
}

void section(String title) => stdout.writeln('\n── $title ──');

Future<void> main() async {
  final DateTime fixed = DateTime(2026, 9, 29, 10, 40, 0);
  final Directory box = Directory.systemTemp.createTempSync('ssz_log_');
  final AppConfigStore store = AppConfigStore(
    File(p.join(box.path, '神算子', 'config.json')),
  );

  AppLog logAt(String name) =>
      AppLog(directory: Directory(p.join(box.path, name)), now: () => fixed);

  try {
    section('AppLog（§AG-5 最小日志）');

    // 目录推导：跟随配置文件（⇒ 生产落在 %APPDATA%\神算子\日志\）
    final AppLog beside = AppLog.besideConfig(store);
    check(
      '日志目录跟随配置文件（生产即 %APPDATA%\\神算子\\日志）',
      beside.directory.path == p.join(box.path, '神算子', '日志') &&
          p.basename(beside.file.path) == '神算子-日志.txt',
      beside.directory.path,
    );

    check(
      'formatLogLine：[ISO 时间] [级别] 消息',
      formatLogLine(fixed, '信息', '你好') ==
          '[2026-09-29T10:40:00.000] [信息] 你好',
      formatLogLine(fixed, '信息', '你好'),
    );

    // startup：三要素
    final AppLog startupLog = logAt('日志1')
      ..startup(
        appVersion: AppVersion.value,
        schemaVersion: '1',
        osVersion: 'Windows 10 测试版',
      );
    check(
      'startup：版本 / 数据格式版本 / 系统版本',
      startupLog.file.readAsStringSync().contains(
        '启动 神算子 v${AppVersion.value} · schema v1 · Windows 10 测试版',
      ),
    );

    // crash：完整堆栈
    final AppLog crashLog = logAt('日志2');
    try {
      throw StateError('炸了');
    } catch (error, stack) {
      crashLog.crash(error, stack);
    }
    final String crashText = crashLog.file.readAsStringSync();
    check(
      'crash：异常文本 + 完整堆栈',
      crashText.contains('未捕获异常：Bad state: 炸了') &&
          crashText.contains('#0'),
    );

    // 追加不覆盖
    final AppLog appendLog = logAt('日志3')
      ..write('第一条')
      ..write('第二条');
    final List<String> lines = appendLog.file.readAsLinesSync();
    check(
      '追加不覆盖：两次写入两行',
      lines.length == 2 &&
          lines[0].contains('第一条') &&
          lines[1].contains('第二条'),
    );

    // 写日志失败绝不抛（生产可用性的关键）
    final File blocker = File(p.join(box.path, 'blocker'))
      ..writeAsStringSync('占位');
    final AppLog blocked = AppLog(
      directory: Directory(p.join(blocker.path, '日志')),
      now: () => fixed,
    );
    bool threw = false;
    try {
      blocked.write('这条写不进去，但不能让程序崩');
    } catch (_) {
      threw = true;
    }
    check('写日志失败绝不抛（静默放弃）', !threw && !blocked.file.existsSync());
  } finally {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  }

  stdout.writeln(
    '\n自检完成：$_pass 过，$_fail 挂'
    '${_failures.isEmpty ? '' : '  →  ${_failures.join('；')}'}',
  );
  if (_fail > 0) exit(1);
}
