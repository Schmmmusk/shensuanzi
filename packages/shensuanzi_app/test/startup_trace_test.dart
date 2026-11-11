// 启动埋点的单元测试（纯 Dart，`dart test` / `flutter test` 都能跑）。
//
// ## 为什么只测「格式」与「关闭时零行为」
//
// 开关是**编译期常量**（`const bool.fromEnvironment`）：测试进程没传
// `--dart-define=SSZ_STARTUP_TRACE=true`，所以 `kStartupTrace` 恒 false。
// 于是这里钉两件事：
//  1. **关闭时不许有任何副作用**（不记录、不建文件）—— 这正是正式包的行为；
//  2. **格式必须对**（用纯函数 `startupLine` / `pageLine` 直接喂数据）。
//     格式写歪了，现场解析不出来 —— 比没有埋点更糟。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  group('关闭时零副作用（= 正式包行为）', () {
    setUp(StartupTrace.resetForTest);

    test('kStartupTrace 在测试里是 false（没传 dart-define）', () {
      expect(kStartupTrace, isFalse);
    });

    test('mark 不记录任何东西', () {
      StartupTrace.mark('T0_main');
      StartupTrace.mark('T1_run_app');
      expect(StartupTrace.marks, isEmpty);
    });

    test('flushAfterFirstFrame 也不建文件、不起定时器', () async {
      final Directory dir = Directory.systemTemp.createTempSync('ssz_trace2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      // 关着时它应当立刻返回（不排 Timer —— 排了会让测试报「有遗留定时器」）
      StartupTrace.flushAfterFirstFrame();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(dir.listSync(), isEmpty);
    });

    test('appendSettled 关闭时也不建文件', () async {
      final Directory dir = Directory.systemTemp.createTempSync('ssz_trace3_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File target = File('${dir.path}/startup-trace.jsonl');
      await StartupTrace.appendSettled(
        page: 'documents',
        firstMs: 10,
        settledMs: 20,
        frames: 2,
        timedOut: false,
        file: target,
      );
      expect(target.existsSync(), isFalse);
    });

    test('flushStartup 不建文件', () async {
      final Directory dir = Directory.systemTemp.createTempSync('ssz_trace_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File target = File('${dir.path}/startup-trace.jsonl');

      await StartupTrace.flushStartup(file: target);
      await StartupTrace.appendSwitch('documents', 123, file: target);

      expect(
        target.existsSync(),
        isFalse,
        reason: '开关关着还写盘 = 正式包每次启动都留一个文件，绝不能发生',
      );
    });
  });

  group('格式（纯函数）', () {
    test('startupLine：六个点位按顺序、是合法 JSON', () {
      final DateTime now = DateTime(2026, 10, 28, 19, 30);
      final String line = startupLine(<Map<String, Object?>>[
        <String, Object?>{'name': 'T0_main', 'ms': 0},
        <String, Object?>{'name': 'T1_run_app', 'ms': 380},
        <String, Object?>{'name': 'T2_db_open', 'ms': 520},
        <String, Object?>{'name': 'T3_services', 'ms': 640},
        <String, Object?>{'name': 'T4_first_frame', 'ms': 3980},
      ], now);

      expect(line, isNot(contains('\n')), reason: '一行一条，落盘才好按行解析');
      final Map<String, dynamic> json =
          jsonDecode(line) as Map<String, dynamic>;
      expect(json['kind'], 'startup');
      expect(json['ts'], now.toIso8601String());
      final List<dynamic> marks = json['marks'] as List<dynamic>;
      expect(marks.length, 5);
      expect(
        marks.map((dynamic e) => (e as Map<String, dynamic>)['name']).toList(),
        <String>[
          'T0_main',
          'T1_run_app',
          'T2_db_open',
          'T3_services',
          'T4_first_frame',
        ],
      );
      expect((marks.last as Map<String, dynamic>)['ms'], 3980);
    });

    test('startupLine：带库信息（现场第一眼要能分清测的是哪个库）', () {
      final Map<String, dynamic> json =
          jsonDecode(
                startupLine(
                  <Map<String, Object?>>[
                    <String, Object?>{'name': 'T0_main', 'ms': 0},
                  ],
                  DateTime(2026, 10, 28, 20, 0),
                  db: r'F:\ssz\shensuanzi.db',
                  dbMb: 478.09,
                  host: 'L19',
                ),
              )
              as Map<String, dynamic>;
      expect(json['db'], 'F:/ssz/shensuanzi.db', reason: '反斜杠统一成正斜杠');
      expect(json['dbMb'], 478.1, reason: '保留一位小数，够判断量级');
      expect(json['host'], 'L19', reason: '不记机器名，两台机的数据永远对不上号');
      expect((json['marks'] as List<dynamic>).length, 1);
    });

    test('startupLine：空列表也是合法 JSON（不许拼出 ",]"）', () {
      final String line = startupLine(<Map<String, Object?>>[], DateTime(2026));
      expect(jsonDecode(line), <String, dynamic>{
        'kind': 'startup',
        'ts': DateTime(2026).toIso8601String(),
        'marks': <dynamic>[],
      });
    });

    test('settledLine：首帧 / 稳定 / 帧数 / 超时标记都在', () {
      final Map<String, dynamic> json =
          jsonDecode(
                settledLine(
                  page: 'documents',
                  firstMs: 221,
                  settledMs: 1740,
                  frames: 9,
                  timedOut: false,
                ),
              )
              as Map<String, dynamic>;
      expect(json['kind'], 'settled');
      expect(json['page'], 'documents');
      expect(json['firstMs'], 221);
      expect(json['settledMs'], 1740);
      expect(json['frames'], 9, reason: '帧数 = 首帧 + 后续重绘；用来判断中间有没有二次渲染');
      expect(json['timedOut'], false);
    });

    test('pageLine：切页一行', () {
      final Map<String, dynamic> json =
          jsonDecode(
                pageLine('documents', 1340, DateTime(2026, 10, 28, 19, 31)),
              )
              as Map<String, dynamic>;
      expect(json['kind'], 'page');
      expect(json['page'], 'documents');
      expect(json['ms'], 1340);
    });
  });

  test('defaultFile 落在 %APPDATA%\\神算子\\日志\\ 下（与崩溃日志同目录）', () {
    final String path = StartupTrace.defaultFile().path;
    expect(path, endsWith(r'神算子\日志\startup-trace.jsonl'));
  });

  // 2026-11-01 真机：Android 上 `APPDATA` 为空、`Directory.systemTemp` 不可写
  // ⇒ 埋点**一行都没写出来**（异常被 flushStartup 的 catch 吞掉）。
  // 现在改成「跟着数据库走」：库在数据目录里，`日志/` 是它的兄弟。
  test('traceFileFor：落在库文件旁边的「日志」目录（两端都成立）', () {
    final String path = StartupTrace.traceFileFor(
      p.join('data', '神算子', 'shensuanzi.db'),
    ).path;
    expect(path, p.join('data', '神算子', '日志', 'startup-trace.jsonl'));
  });

  // ==========================================================================
  // 库探针（2026-11-11）：`dbMb` 报 0.0 而库实际是 498 MiB ⇒ 必须能分辨
  // 「文件真小」与「这个 API 读错了」。
  // ==========================================================================
  group('dbProbeLine（库探针）', () {
    /// 真正的 SQLite 文件头：`SQLite format 3\0`
    const List<int> sqliteHeader = <int>[
      0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, // "SQLite f"
      0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00, // "ormat 3\0"
    ];

    test('真库：两条途径读数必须一致，文件头是 SQLite，同目录 -wal 也在', () {
      final Directory dir = Directory.systemTemp.createTempSync('ssz-probe-');
      addTearDown(() => dir.deleteSync(recursive: true));

      final File db = File(p.join(dir.path, 'shensuanzi.db'));
      db.writeAsBytesSync(<int>[...sqliteHeader, ...List<int>.filled(4096, 0)]);
      File(p.join(dir.path, 'shensuanzi.db-wal')).writeAsBytesSync(<int>[0, 0]);

      final Map<String, dynamic> json =
          jsonDecode(dbProbeLine(db.path, DateTime(2026, 11, 11)))
              as Map<String, dynamic>;

      expect(json['kind'], 'dbprobe');
      // ⚠️ 核心断言：两条独立途径读同一个大小。不一致 ⇒ 是「读法 / 过滤驱动」的问题，
      // 一致且为 0 才是「文件真小」。
      expect(
        json['lengthSync'],
        json['statBytes'],
        reason: '`lengthSync` 与 `statSync().size` 不一致 —— 现场会出现「库明明很大却报 0」',
      );
      expect(json['lengthSync'], 16 + 4096);
      expect(json['statType'], 'file');
      expect(json['head'], sqliteHeader, reason: '文件头不是 SQLite 魔数 ⇒ 打开的不是库');
      expect(json['siblings'], contains('shensuanzi.db-wal:2'));
      expect(json['siblings'], contains('shensuanzi.db:4112'));
    });

    test('不存在的路径：大小是 null 而不是 0（0 会被误读成「空库」）', () {
      final String missing = p.join(
        Directory.systemTemp.path,
        '__no_such_ssz_dir__',
        'shensuanzi.db',
      );
      final Map<String, dynamic> json =
          jsonDecode(dbProbeLine(missing, DateTime(2026, 11, 11)))
              as Map<String, dynamic>;

      expect(json['lengthSync'], isNull);
      expect(json['statBytes'], isNull);
      expect(json['head'], isNull);
      expect(json['siblings'], isEmpty);
    });

    test('0 字节文件：两个大小都是 0，但 head 为空 —— 与「空库」可分辨', () {
      final Directory dir = Directory.systemTemp.createTempSync('ssz-probe0-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File db = File(p.join(dir.path, 'shensuanzi.db'))..createSync();

      final Map<String, dynamic> json =
          jsonDecode(dbProbeLine(db.path, DateTime(2026, 11, 11)))
              as Map<String, dynamic>;

      expect(json['lengthSync'], 0);
      expect(json['statBytes'], 0);
      // 0 字节 ⇒ 读不到头。这与「真库但 lengthSync 读错」是两种不同现象。
      expect(json['head'], isEmpty);
    });
  });
}
