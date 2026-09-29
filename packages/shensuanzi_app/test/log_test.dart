// 最小日志（`AppLog` / `formatLogLine`）的测试（§AG-5）。
//
// 覆盖：日志目录的**推导规则**（跟随配置文件）/ 行格式 / 启动行三要素 /
// 崩溃的完整堆栈 / **追加不覆盖** / **写日志失败绝不抛**。
//
// ⚠️ 「写日志失败绝不抛」这条是**生产可用性**的关键：磁盘满、目录被设只读时，
// 记不了日志是小事，**因为记日志而崩掉是大事**。这条断言做了反向验证
// （去掉 try/catch 即红）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  group('AppLog（§AG-5 最小日志）', () {
    late Directory box;
    late AppConfigStore store;
    final DateTime fixed = DateTime(2026, 9, 29, 10, 40, 0);

    setUp(() {
      box = Directory.systemTemp.createTempSync('shensuanzi_log_');
      store = AppConfigStore(File(p.join(box.path, '神算子', 'config.json')));
    });

    tearDown(() {
      try {
        box.deleteSync(recursive: true);
      } catch (_) {
        // 删不掉不影响结论
      }
    });

    /// 固定时钟 + 沙箱目录（**绝不碰真实 `%APPDATA%`**）
    AppLog logAt(String name) =>
        AppLog(directory: Directory(p.join(box.path, name)), now: () => fixed);

    test('日志目录跟随配置文件（生产即 %APPDATA%\\神算子\\日志）', () {
      final AppLog log = AppLog.besideConfig(store);

      expect(log.directory.path, p.join(box.path, '神算子', '日志'));
      expect(p.basename(log.file.path), '神算子-日志.txt');
    });

    test('formatLogLine：[ISO 时间] [级别] 消息（本地时间）', () {
      expect(
        formatLogLine(fixed, '信息', '你好'),
        '[2026-09-29T10:40:00.000] [信息] 你好',
      );
    });

    test('startup：版本 / 数据格式版本 / 系统版本三件事都进日志', () {
      final AppLog log = logAt('日志1')..startup(
        appVersion: AppVersion.value,
        schemaVersion: '1',
        osVersion: 'Windows 10 测试版',
      );

      expect(
        log.file.readAsStringSync(),
        contains(
          '[2026-09-29T10:40:00.000] [信息] 启动 神算子 '
          'v${AppVersion.value} · schema v1 · Windows 10 测试版',
        ),
      );
    });

    test('crash：异常文本 + **完整堆栈**（没有堆栈的日志等于没写）', () {
      final AppLog log = logAt('日志2');
      try {
        throw StateError('炸了');
      } catch (error, stack) {
        log.crash(error, stack);
      }

      final String text = log.file.readAsStringSync();
      expect(text, contains('未捕获异常：Bad state: 炸了'));
      expect(text, contains('#0'), reason: '堆栈必须留下 —— 否则定位不到行');
    });

    test('追加不覆盖：两次写入两行（日志是累积的）', () {
      final AppLog log = logAt('日志3')
        ..write('第一条')
        ..write('第二条');

      final List<String> lines = log.file.readAsLinesSync();
      expect(lines, hasLength(2));
      expect(lines[0], contains('第一条'));
      expect(lines[1], contains('第二条'));
    });

    test('**写日志失败绝不抛**（目录建不出来 → 静默放弃）', () {
      // 日志目录的路径上蹲一个同名文件（真实场景：目录被误删后建了同名文件 / 无权限）
      final File blocker = File(p.join(box.path, 'blocker'));
      blocker.writeAsStringSync('占位');
      final AppLog log = AppLog(
        directory: Directory(p.join(blocker.path, '日志')),
        now: () => fixed,
      );

      expect(
        () => log.write('这条写不进去，但不能让程序崩'),
        returnsNormally,
        reason: '记日志是辅助手段，不能反过来把主流程拖垮',
      );
      expect(log.file.existsSync(), isFalse);
    });
  });
}
