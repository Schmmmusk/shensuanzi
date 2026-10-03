import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Directory box;
  late DataDirectoryService service;

  setUp(() {
    box = sandbox();
    service = serviceIn(box);
  });

  tearDown(() {
    if (box.existsSync()) box.deleteSync(recursive: true);
  });

  // ============================================================ ① 默认位置
  group('① resolveDefault', () {
    test('有非系统盘 → D:\\神算子数据', () {
      expect(service.resolveDefault(), r'D:\神算子数据');
    });

    test('只有系统盘 → 用户目录下', () {
      final DataDirectoryService onlyC = serviceIn(
        box,
        environment: systemDriveOnly(),
      );
      expect(onlyC.resolveDefault(), r'C:\Users\tester\神算子数据');
    });

    test('与策略层同源（不自己算一遍）', () {
      expect(service.policy, same(service.bootstrap.policy));
      expect(
        service.resolveDefault(),
        service.policy.defaultDataDirectory(),
      );
    });
  });

  // ============================================================ ② 校验
  group('② validate', () {
    test('ok / warn / reject 三档都能返回', () {
      expect(service.validate(r'D:\神算子数据').verdict, DirectoryVerdict.ok);

      final DirectoryAdvice warn =
          service.validate(r'C:\Users\tester\AppData\Local\神算子');
      expect(warn.verdict, DirectoryVerdict.warn);
      expect(warn.isUsable, isTrue, reason: '警告不拦人');

      expect(service.validate(r'C:\').verdict, DirectoryVerdict.reject);
    });

    test('与策略层同源', () {
      expect(
        service.validate(r'C:\Windows\x').verdict,
        service.policy.inspect(r'C:\Windows\x').verdict,
      );
    });
  });

  // ============================================================ ③ 初始化
  group('③ ensureInitialized', () {
    test('空目录 → 创建 + 写标记 + 记配置，createdNow = true', () {
      final String dir = sandboxPath(box, 'data');
      final DataLocation location = service.ensureInitialized(dir, now: 111);

      expect(location.createdNow, isTrue);
      expect(Directory(dir).existsSync(), isTrue);
      expect(service.isShensuanziDir(dir), isTrue);
      expect(service.policy, same(service.bootstrap.policy));
      expect(service.bootstrap.loadConfig().dataDirectory, location.directory);
    });

    test('目录不存在 → 会被创建出来', () {
      final DataLocation location =
          service.ensureInitialized(p.join(box.path, 'a', 'b', '神算子数据'));
      expect(Directory(location.directory).existsSync(), isTrue);
    });

    test('再度初始化同一目录 → 复用（createdNow = false）', () {
      final String dir = sandboxPath(box, 'data');
      service.ensureInitialized(dir, now: 111);

      final DataLocation again = service.ensureInitialized(dir, now: 999);
      expect(again.createdNow, isFalse);
      expect(again.marker.createdAt, 111, reason: '不重写标记');
    });

    test('非空且无标记 → 抛 DataDirectoryRejected，且带「怎么办」', () {
      final String other = sandboxPath(box, 'other');
      Directory(other).createSync(recursive: true);
      File(p.join(other, '别人的东西.txt')).writeAsStringSync('x');

      expect(
        () => service.ensureInitialized(other),
        throwsA(isA<DataDirectoryRejected>()),
      );

      DataDirectoryRejected? caught;
      try {
        service.ensureInitialized(other);
      } on DataDirectoryRejected catch (error) {
        caught = error;
      }
      expect(caught!.howTo, isNotNull);
      expect(caught.reason, contains('已经有别的东西'));
    });

    test('确认过之后（acceptForeignDirectory）→ 放行', () {
      final String other = sandboxPath(box, 'other');
      Directory(other).createSync(recursive: true);
      File(p.join(other, '别人的东西.txt')).writeAsStringSync('x');

      final DataLocation location = service.ensureInitialized(
        other,
        acceptForeignDirectory: true,
      );
      expect(location.createdNow, isTrue);
      expect(File(p.join(other, '别人的东西.txt')).existsSync(), isTrue);
    });

    test('非法路径 → 抛，且不会留下标记文件', () {
      expect(
        () => service.ensureInitialized(r'C:\'),
        throwsA(isA<DataDirectoryRejected>()),
      );
    });
  });

  // ============================================================ ④ 标记判断
  group('④ isShensuanziDir', () {
    test('普通目录 → false', () {
      final String dir = sandboxPath(box, 'plain');
      Directory(dir).createSync(recursive: true);
      expect(service.isShensuanziDir(dir), isFalse);
    });

    test('不存在的目录 → false（不抛）', () {
      expect(service.isShensuanziDir(sandboxPath(box, 'nope')), isFalse);
    });

    test('初始化过的目录 → true', () {
      final String dir = sandboxPath(box, 'data');
      service.ensureInitialized(dir);
      expect(service.isShensuanziDir(dir), isTrue);
    });

    test('「配置被清 → 选中老目录 → 认得出是老数据」这条链路', () {
      final String dir = sandboxPath(box, 'data');
      service.ensureInitialized(dir, now: 111);
      service.bootstrap.configStore.clear();

      // 软件此时完全不知道数据在哪，但用户一选原目录就能认出来
      expect(service.existing(), isNull);
      expect(service.isShensuanziDir(dir), isTrue);

      final DataLocation recovered = service.ensureInitialized(dir);
      expect(recovered.createdNow, isFalse);
      expect(recovered.marker.createdAt, 111);
    });
  });

  // ============================================================ 启动恢复
  group('existing', () {
    test('没配过 → null（弹对话框）', () {
      expect(service.existing(), isNull);
    });

    test('配过且有标记 → 直接可用', () {
      final DataLocation created = service.ensureInitialized(
        sandboxPath(box, 'data'),
      );
      final DataLocation? existing = service.existing();
      expect(existing, isNotNull);
      expect(existing!.directory, created.directory);
      expect(existing.createdNow, isFalse);
    });

    test('配置指向的目录被删了 → null', () {
      final String dir = sandboxPath(box, 'data');
      service.ensureInitialized(dir);
      Directory(dir).deleteSync(recursive: true);
      expect(service.existing(), isNull);
    });
  });

  // ============================================================ 展示与开库
  group('展示与开库', () {
    test('spaceHint 取真实容量，拿不到就 null', () {
      expect(service.spaceHint(r'D:\神算子数据'), 'D 盘剩余 128.0 GB');
      expect(
        serviceIn(box, environment: machine(drives: <DriveInfo>[]))
            .spaceHint(r'D:\神算子数据'),
        isNull,
      );
    });

    test('open 打开的是数据目录里的库，user_version 已写入', () {
      final DataLocation location =
          service.ensureInitialized(sandboxPath(box, 'data'));
      final Db db = service.open(location);

      expect(File(location.databasePath).existsSync(), isTrue);
      expect(
        db.raw.select('PRAGMA user_version').first.values.first,
        Schema.version,
      );
      expect(db.foreignKeysEnabled, isTrue, reason: '主机端外键开启');
      db.close();
    });
  });

  // ============================================== ⑤ 刷新标记（§AQ·六 方案 A）
  //
  // 背景：`refreshMarker` 在 `_openDatabase` 里与 `Db.open` **同处一个 try**，
  // 目录变只读 / 磁盘满时它会抛 ⇒ **开得好好的库**被连坐成「数据文件打不开」。
  // 裁定（2026-10-02）：走不抛版本，失败只记日志。

  group('⑤ tryRefreshMarker（诊断动作永不抛）', () {
    /// 指到一个「**其实是个文件**」的路径 —— `DataMarker.write` 里的
    /// `Directory(...).createSync(recursive: true)` 必然抛 `FileSystemException`。
    DataLocation locationAt(String directory) => DataLocation(
      directory: directory,
      marker: const DataMarker(schemaVersion: 1, createdAt: 0),
      createdNow: false,
      backupDirectory: p.join(box.path, 'backup'),
      exportDirectory: p.join(box.path, 'export'),
    );

    String blockingFile(String name) {
      final String path = sandboxPath(box, name);
      File(path).writeAsStringSync('我不是目录');
      return path;
    }

    test('目录正常 → 刷新成功、返回 null、标记真的跟上了', () {
      final DataLocation location =
          service.ensureInitialized(sandboxPath(box, 'data'), now: 111);

      final Object? error =
          service.tryRefreshMarker(location, Schema.version + 1);

      expect(error, isNull);
      expect(
        DataMarker.read(location.directory)!.schemaVersion,
        Schema.version + 1,
        reason: '不抛 ≠ 什么也不做：成功路径必须真的写进去',
      );
    });

    test('目录写不进去 → **返回原因、不抛**（启动不会因此崩）', () {
      final DataLocation location = locationAt(blockingFile('blocked'));

      // 关键断言：这里**不写** `throwsA` —— 它必须**安静地**返回一个原因。
      final Object? error =
          service.tryRefreshMarker(location, Schema.version);

      expect(error, isNotNull);
      expect(error, isA<FileSystemException>());
    });

    test('⚠️ 反向灵敏度：**未加保护**的 refreshMarker 仍会抛 —— 证明上一条不是空断言', () {
      final DataLocation location = locationAt(blockingFile('blocked2'));

      expect(
        () => service.refreshMarker(location, Schema.version),
        throwsA(isA<FileSystemException>()),
        reason: '两个方法必须行为可分，否则 tryRefreshMarker 的 try 是死代码',
      );
    });
  });
}
