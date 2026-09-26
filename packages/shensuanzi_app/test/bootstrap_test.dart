import 'dart:convert';
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

  setUp(() => box = sandbox());
  tearDown(() {
    if (box.existsSync()) box.deleteSync(recursive: true);
  });

  // ============================================================ 目录内容
  group('目录内容判定', () {
    test('不存在 → missing', () {
      expect(contentsOf(sandboxPath(box, 'nope')), DirectoryContents.missing);
    });

    test('存在且为空 → empty', () {
      final String dir = sandboxPath(box, 'fresh');
      Directory(dir).createSync(recursive: true);
      expect(contentsOf(dir), DirectoryContents.empty);
    });

    test('有标记文件 → ours', () {
      final String dir = sandboxPath(box, 'ours');
      DataMarker.write(dir, schemaVersion: Schema.version, now: 1700000000000);
      expect(contentsOf(dir), DirectoryContents.ours);
    });

    test('非空且没有标记 → foreign（可能是选错了文件夹）', () {
      final String dir = sandboxPath(box, 'other');
      Directory(dir).createSync(recursive: true);
      File(p.join(dir, '别人的报表.xlsx')).writeAsStringSync('x');
      expect(contentsOf(dir), DirectoryContents.foreign);
    });

    test('标记文件损坏 → 仍算 ours（文件名在），但读出来是 null', () {
      final String dir = sandboxPath(box, 'broken');
      Directory(dir).createSync(recursive: true);
      File(p.join(dir, DataMarker.fileName)).writeAsStringSync('{ 坏的');

      expect(contentsOf(dir), DirectoryContents.ours);
      expect(DataMarker.read(dir), isNull);
    });
  });

  // ============================================================ 标记文件
  group('标记文件 .shensuanzi-data', () {
    test('写在数据目录里，名字固定', () {
      final String dir = sandboxPath(box, 'data');
      final DataMarker marker = DataMarker.write(
        dir,
        schemaVersion: Schema.version,
        now: 1700000000000,
      );

      expect(File(p.join(dir, '.shensuanzi-data')).existsSync(), isTrue);
      expect(DataMarker.fileIn(dir).path, p.join(dir, '.shensuanzi-data'));
      expect(marker.schemaVersion, Schema.version);
      expect(marker.createdAt, 1700000000000);
      expect(DataMarker.existsIn(dir), isTrue);
    });

    test('写进去再读回来，字段一致', () {
      final String dir = sandboxPath(box, 'data');
      DataMarker.write(dir, schemaVersion: Schema.version, now: 1234567890);

      final DataMarker? back = DataMarker.read(dir);
      expect(back, isNotNull);
      expect(back!.schemaVersion, Schema.version);
      expect(back.createdAt, 1234567890);
      expect(back.app, '神算子');
    });

    test('标记里带 schema 版本 —— 将来版本不匹配能认出来', () {
      final String dir = sandboxPath(box, 'data');
      DataMarker.write(dir, schemaVersion: Schema.version, now: 1);

      final Map<String, Object?> json =
          Map<String, Object?>.from(
            jsonDecode(DataMarker.fileIn(dir).readAsStringSync()) as Map,
          );
      expect(json['schema_version'], Schema.version);
      expect(json['created_at'], 1);
      expect(json['app'], '神算子');
    });

    test('读取不存在的标记 → null（不抛）', () {
      expect(DataMarker.read(sandboxPath(box, 'nope')), isNull);
    });

    test('字段缺失 / 类型不对 → null（不抛）', () {
      final String dir = sandboxPath(box, 'data');
      Directory(dir).createSync(recursive: true);
      DataMarker.fileIn(dir).writeAsStringSync(jsonEncode(<String, Object?>{
        'app': '神算子',
        'schema_version': '三',
      }));
      expect(DataMarker.read(dir), isNull);
    });
  });

  // ============================================================ 恢复逻辑
  group('启动恢复：resolved()', () {
    test('没配过 → null（走向导）', () {
      expect(bootstrapIn(box).resolved(), isNull);
    });

    test('配过 + 目录有标记 → 直接复用，createdNow = false', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      final DataLocation created = bootstrap.prepare(sandboxPath(box, 'data'));

      final DataLocation? restored = bootstrap.resolved();
      expect(restored, isNotNull);
      expect(restored!.directory, created.directory);
      expect(restored.createdNow, isFalse);
      expect(restored.marker.schemaVersion, Schema.version);
      expect(restored.databasePath, p.join(created.directory, 'shensuanzi.db'));
    });

    test('配置被清理软件删掉 → null（走向导，但数据还在原地）', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      final String dir = sandboxPath(box, 'data');
      bootstrap.prepare(dir);

      bootstrap.configStore.clear();
      expect(bootstrap.resolved(), isNull);

      // 数据目录里的标记没被动过
      expect(DataMarker.existsIn(dir), isTrue);
    });

    test('配置指向的目录被删了 → null', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      final String dir = sandboxPath(box, 'data');
      bootstrap.prepare(dir);
      Directory(dir).deleteSync(recursive: true);

      expect(bootstrap.resolved(), isNull);
    });

    test('配置指向一个有别人东西的目录 → null（不乱认）', () {
      final String other = sandboxPath(box, 'other');
      Directory(other).createSync(recursive: true);
      File(p.join(other, '别人的东西.txt')).writeAsStringSync('x');

      bootstrapIn(box).saveConfig(AppConfig(dataDirectory: other));

      expect(bootstrapIn(box).resolved(), isNull);
    });

    test('配置指向一个已废弃的非法目录（如 C:\\Windows\\x）→ null', () {
      bootstrapIn(box).saveConfig(
        AppConfig(dataDirectory: r'C:\Windows\神算子'),
      );
      expect(bootstrapIn(box).resolved(), isNull);
    });
  });

  // ============================================================ 首次启动
  group('向导：prepare()', () {
    test('空目录 → 创建、写标记、记配置', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      final String dir = sandboxPath(box, 'data');

      final DataLocation location = bootstrap.prepare(dir, now: 1700000000000);

      expect(location.createdNow, isTrue);
      expect(Directory(dir).existsSync(), isTrue);
      expect(DataMarker.existsIn(dir), isTrue);
      expect(contentsOf(dir), DirectoryContents.ours);
      expect(bootstrap.loadConfig().dataDirectory, location.directory);
    });

    test('再选同一个目录 → 复用，不覆盖标记（createdAt 是首次建的时间）', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      final String dir = sandboxPath(box, 'data');
      bootstrap.prepare(dir, now: 111);

      final DataLocation again = bootstrap.prepare(dir, now: 999);
      expect(again.createdNow, isFalse);
      expect(again.marker.createdAt, 111, reason: '标记不该被第二次调用重写');
    });

    test('配置被清后重选原目录 → 数据立刻回来，不需要用户记住路径', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      final String dir = sandboxPath(box, 'data');
      bootstrap.prepare(dir, now: 111);
      bootstrap.configStore.clear();

      final DataLocation back = bootstrap.prepare(dir);
      expect(back.createdNow, isFalse);
      expect(back.marker.createdAt, 111);
      expect(bootstrap.resolved(), isNotNull);
    });

    test('新位置：目录不存在也会被创建', () {
      final DataLocation location = bootstrapIn(box).prepare(
        p.join(box.path, 'a', 'b', '神算子数据'),
      );
      expect(Directory(location.directory).existsSync(), isTrue);
    });

    test('非空且没有标记 → 拒绝，并给出「怎么办」；配置不被改写', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      final String other = sandboxPath(box, 'other');
      Directory(other).createSync(recursive: true);
      File(p.join(other, '别人的东西.txt')).writeAsStringSync('x');

      DataDirectoryRejected? caught;
      try {
        bootstrap.prepare(other);
      } on DataDirectoryRejected catch (error) {
        caught = error;
      }

      expect(caught, isNotNull, reason: '非空且无标记的目录必须被拒');
      expect(caught!.advice.verdict, DirectoryVerdict.reject);
      expect(caught.howTo, isNotNull, reason: '错误信息要说「怎么办」');
      expect(caught.reason, contains('已经有别的东西'));
      expect(bootstrap.loadConfig().dataDirectory, isNull, reason: '拒绝后不该记下路径');
      expect(DataMarker.existsIn(other), isFalse, reason: '拒绝后不该写标记');
    });

    test('用户确认过之后（acceptForeignDirectory）→ 放行，且不动里面的文件', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      final String other = sandboxPath(box, 'other');
      Directory(other).createSync(recursive: true);
      File(p.join(other, '别人的东西.txt')).writeAsStringSync('x');

      final DataLocation location = bootstrap.prepare(
        other,
        acceptForeignDirectory: true,
      );

      expect(location.createdNow, isTrue);
      expect(File(p.join(other, '别人的东西.txt')).existsSync(), isTrue);
      expect(DataMarker.existsIn(other), isTrue);
    });

    test('非法位置（系统盘根 / 系统目录 / 相对路径）→ 一律拒绝', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      for (final String bad in <String>[
        r'C:\',
        r'C:\Windows\神算子',
        r'C:\Program Files\神算子',
        'data',
        '',
      ]) {
        expect(
          () => bootstrap.prepare(bad),
          throwsA(isA<DataDirectoryRejected>()),
          reason: bad,
        );
      }
    });

    test('备份目录是数据目录的兄弟目录', () {
      final DataLocation location = bootstrapIn(box).prepare(
        p.join(box.path, '神算子数据'),
      );
      expect(location.backupDirectory, p.join(box.path, '神算子备份'));
      expect(
        location.backupDirectory,
        isNot(location.directory),
        reason: '备份不能在数据目录里面（会形成「备份里包含备份」）',
      );
    });
  });

  // ============================================================ 打开数据库
  group('打开数据库', () {
    test('open 建库并把 user_version 写成 Schema.version', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      final DataLocation location = bootstrap.prepare(sandboxPath(box, 'data'));

      final Db db = bootstrap.open(location);
      expect(File(location.databasePath).existsSync(), isTrue);

      final Object? version =
          db.raw.select('PRAGMA user_version').first.values.first;
      expect(version, Schema.version);

      db.close();
    });

    test('主机端外键是开着的（与客户端镜像相反）', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      final DataLocation location = bootstrap.prepare(sandboxPath(box, 'data'));

      final Db db = bootstrap.open(location);
      expect(db.foreignKeysEnabled, isTrue);
      db.close();
    });
  });
}
