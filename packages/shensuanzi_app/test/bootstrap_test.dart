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

    test('BUG-03 回归：目录与标记都在、但库文件损坏 → resolved() 为 null', () {
      final AppBootstrap bootstrap = bootstrapIn(box);
      final DataLocation created = bootstrap.prepare(sandboxPath(box, 'data'));
      // 把库文件写成垃圾文本（模拟「not a database」）
      File(created.databasePath).writeAsStringSync('not a database');

      // 修复前：resolved() 仍返回该位置 ⇒ 反复打开坏库、永远停在错误页
      expect(
        bootstrap.resolved(),
        isNull,
        reason: '库打不开就不该解析成「可用位置」（§审查 BUG-03）',
      );

      // §审查 2026-10-05 真机：**必须能认出「是哪个目录坏了」** ——
      // 否则启动流程会把它当成「首次启动」弹向导，而向导会覆盖 config，
      // 用户原来的目录（实测 `D://fed`）就再也切不回去了。
      final DataLocation? broken = bootstrap.unusableConfigured();
      expect(broken, isNotNull, reason: '知道是哪个目录坏 —— 与「没配过」区分开');
      expect(broken!.directory, created.directory);
    });

    test('没配过 / 位置合法 ⇒ unusableConfigured() 为 null（不误报「坏了」）', () {
      final AppBootstrap bootstrap = bootstrapIn(box);

      // ① 根本没配过
      expect(bootstrap.unusableConfigured(), isNull);

      // ② 配过且库好着（新建的空库也是有效 SQLite 文件）
      final DataLocation created = bootstrap.prepare(sandboxPath(box, 'data'));
      Db.open(created.databasePath).close();
      expect(bootstrap.unusableConfigured(), isNull, reason: '好库不算「坏」');
      expect(bootstrap.resolved(), isNotNull, reason: '好库要能解析出来');
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

  // ============================================================ 启动场景判定
  //
  // §审查「启动路径健壮性」批次：六个场景收在一次判定里（`startup.dart`）。
  // 判错的代价是**用户的目录从配置里消失**（真机踩过），所以逐条钉住。
  group('启动场景判定（startupDecision）', () {
    /// 默认位置落在**沙箱里**：没有可用的非系统盘 ⇒ 退到 `<home>/神算子数据`。
    /// （绝不能让它去真 D 盘建目录。）
    AppBootstrap boot() => bootstrapIn(
      box,
      environment: machine(home: box.path, drives: <DriveInfo>[]),
    );

    test('没配过 + 默认位置**没有**数据 ⇒ welcome（可以正常说「欢迎」）', () {
      final AppBootstrap b = boot();
      expect(b.startupDecision().scenario, StartupScenario.welcome);
      // 提前把「默认位置是什么」钉住，免得将来换夹具时这条测试失去意义
      expect(
        b.policy.defaultDataDirectory(),
        p.join(box.path, '神算子数据'),
        reason: '没有可用的非系统盘 ⇒ 退到 <home>/神算子数据（沙箱内）',
      );
    });

    test('没配过 + 默认位置**已有数据** ⇒ firstRunWithData（OBS-11 前半）', () {
      final AppBootstrap b = boot();
      // 造「上次装过、这次重装」的现场：默认位置有标记 + 真库，但**没有配置**
      final String dir = b.policy.defaultDataDirectory();
      Directory(dir).createSync(recursive: true);
      DataMarker.write(dir, schemaVersion: Schema.version, now: 1700000000000);
      Db.open(p.join(dir, AppBootstrap.databaseFileName)).close();

      final StartupDecision decision = b.startupDecision();
      expect(decision.scenario, StartupScenario.firstRunWithData);
      expect(
        decision.defaultPath,
        dir,
        reason: '要告诉用户「是哪个位置已有数据」',
      );
    });

    test('配过 + 库能打开 ⇒ openExisting', () {
      final AppBootstrap b = boot();
      final DataLocation created = b.prepare(sandboxPath(box, 'data'));
      Db.open(created.databasePath).close();

      final StartupDecision decision = b.startupDecision();
      expect(decision.scenario, StartupScenario.openExisting);
      expect(decision.location!.directory, created.directory);
    });

    test('配过 + **库打不开** ⇒ brokenDatabase（错误页，绝不走向导）', () {
      final AppBootstrap b = boot();
      final DataLocation created = b.prepare(sandboxPath(box, 'data'));
      File(created.databasePath).writeAsStringSync('这不是一个有效的 SQLite 库');

      final StartupDecision decision = b.startupDecision();
      expect(decision.scenario, StartupScenario.brokenDatabase);
      expect(
        decision.location!.directory,
        created.directory,
        reason: '错误页要说清是**哪个**目录打不开',
      );
    });

    test('配过 + **库文件被删** ⇒ missingDatabase（不许静默建空库）', () {
      // 审计报告 #1：标记还在、库被误删 ⇒ 从前会一路走到「新建空库」，
      // 用户对着空账簿继续开单（2026-10-07 裁定，docs/reply.md §6 的 #1）
      final AppBootstrap b = boot();
      final DataLocation created = b.prepare(sandboxPath(box, 'data'));
      Db.open(created.databasePath).close();
      File(created.databasePath).deleteSync();

      final StartupDecision decision = b.startupDecision();

      expect(decision.scenario, StartupScenario.missingDatabase);
      expect(
        decision.location!.directory,
        created.directory,
        reason: '要告诉用户是**哪个**目录缺库文件（提示里得写出路径）',
      );
      expect(
        File(created.databasePath).existsSync(),
        isFalse,
        reason: '判定本身**绝不许**顺手把空库建出来',
      );
    });

    test('missingDatabase 与 brokenDatabase 必须分得开（同目录两种病）', () {
      final AppBootstrap b = boot();
      final DataLocation created = b.prepare(sandboxPath(box, 'data'));

      // ① 文件在、内容不是 SQLite ⇒ brokenDatabase（可「重试」）
      File(created.databasePath).writeAsStringSync('这不是一个有效的 SQLite 库');
      expect(
        b.startupDecision().scenario,
        StartupScenario.brokenDatabase,
      );

      // ② 文件没了 ⇒ missingDatabase（要教从备份恢复）
      File(created.databasePath).deleteSync();
      expect(
        b.startupDecision().scenario,
        StartupScenario.missingDatabase,
      );
    });

    test('createEmptyDatabase：只在确实没有文件时建，绝不覆盖', () {
      final AppBootstrap b = boot();
      final DataLocation created = b.prepare(sandboxPath(box, 'data'));

      // ① 没有文件 ⇒ 建出一份能打开的库
      b.createEmptyDatabase(created);
      expect(File(created.databasePath).existsSync(), isTrue);
      expect(b.startupDecision().scenario, StartupScenario.openExisting);

      // ② 已经有文件（用户刚拷回来的真库）⇒ 明确拒绝，不覆盖
      expect(
        () => b.createEmptyDatabase(created),
        throwsA(isA<StateError>()),
      );
    });

    test('配过 + **目录被删** ⇒ recoverLocation（带上「上次用的路径」）', () {
      final AppBootstrap b = boot();
      final DataLocation created = b.prepare(sandboxPath(box, 'data'));
      Directory(created.directory).deleteSync(recursive: true);

      final StartupDecision decision = b.startupDecision();
      expect(decision.scenario, StartupScenario.recoverLocation);
      expect(
        decision.previousPath,
        created.directory,
        reason: '§AG 遗漏 1：要能说「上次用的是这个路径，现在找不到了」',
      );
    });

    test('配置被截断 + 抢救得到 + 库能开 ⇒ salvageConfig（用户无感）', () {
      final AppBootstrap b = boot();
      final DataLocation created = b.prepare(sandboxPath(box, 'data'));
      Db.open(created.databasePath).close();
      // 写到一半断电：JSON 截断，但 data_directory 那段还在
      File(p.join(box.path, 'config.json')).writeAsStringSync(
        '{\n  "data_directory": ${jsonEncode(created.directory)},\n  "ui_sca',
      );

      final StartupDecision decision = b.startupDecision();
      expect(decision.scenario, StartupScenario.salvageConfig);
      expect(decision.location!.directory, created.directory);
    });

    test('配置被截断 + 抢救不到 ⇒ recoverLocation（previousPath 为空）', () {
      final AppBootstrap b = boot();
      File(p.join(box.path, 'config.json')).writeAsStringSync('{ 根本不是 JSON');

      final StartupDecision decision = b.startupDecision();
      expect(decision.scenario, StartupScenario.recoverLocation);
      expect(decision.previousPath, isNull, reason: '读不出路径就别编一个');
    });

    test('defaultDataDirectory 注入：**只替换那一个值**，判定照走真实文件系统', () {
      final AppBootstrap b = boot();

      // 「注入的默认位置」真的建在磁盘上（有标记 + 真库）——判定必须真的读盘
      final String injected = sandboxPath(box, '注入的默认位置');
      Directory(injected).createSync(recursive: true);
      DataMarker.write(injected, schemaVersion: Schema.version, now: 1700000000000);
      Db.open(p.join(injected, AppBootstrap.databaseFileName)).close();

      // ① 注入了，而且那个位置**真的有**数据 ⇒ firstRunWithData
      final StartupDecision withData = b.startupDecision(
        defaultDataDirectory: injected,
      );
      expect(withData.scenario, StartupScenario.firstRunWithData);
      expect(withData.defaultPath, injected);

      // ② 不注入 ⇒ 回到机器算出来的那个（沙箱内、没有数据）⇒ welcome
      //    —— **生产行为一个字都不变**（§BR·补 2 Case 3）
      expect(
        b.startupDecision().scenario,
        StartupScenario.welcome,
        reason: '不注入时不该有任何差别',
      );

      // ③ 配置里有路径之后，注入值**不参与任何判定**（裁定写死的边界）
      final DataLocation created = b.prepare(sandboxPath(box, 'data'));
      Db.open(created.databasePath).close();
      expect(
        b.startupDecision(defaultDataDirectory: injected).scenario,
        StartupScenario.openExisting,
        reason: '§BR·补 2：注入只影响「真·第一次启动」那一支',
      );
    });
  });
}
