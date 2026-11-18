// 数据抢救 P0（体检 + 接回）的测试 —— 2026-10-29，提案 52 §三。
//
// 这一层的每一个错误都是**数据级的**（拿坏的盖掉好的、旧 WAL 污染新库、
// 留存文件其实打不开），所以用例都拿**真 SQLite 文件库**跑，不用内存库。
//
// 覆盖：
//   · 扫描：自动/手动备份、`.before-vN` 都能找到；时间取文件名；单据数对
//   · 体检：坏文件标 unreadable、版本更高标 newerSchema、不可用的不能选
//   · 接回：新库能开且数据在、旧库改名留存**且仍可读**、`-wal`/`-shm` 一起走
//   · 安全：候选坏了 ⇒ 一个字节都不动
//   · 文案：不出现「损坏 / 数据库」这类吓人的词（用户补充建议）
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

void main() {
  useLocalSqlite();

  late Directory root;
  late Directory dataDir;
  late Directory backupDir;
  late String databasePath;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ssz_recovery_');
    dataDir = Directory(p.join(root.path, '神算子数据'))..createSync();
    backupDir = Directory(p.join(root.path, '神算子备份'))..createSync();
    databasePath = p.join(dataDir.path, 'shensuanzi.db');
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶尔还有句柄没释放 —— 临时目录，删不掉就算了
    }
  });

  /// 造一个有 [docs] 张单据的库；返回路径。
  /// [schemaVersion] 默认跟随**当前版本** —— 写死数字的话，每次升 schema
  /// 都会让一批无关用例红一次（v7 就踩了）。
  String makeDb(String path, {int docs = 3, int schemaVersion = Schema.version}) {
    final Db db = Db.open(path);
    for (int i = 0; i < docs; i++) {
      final int at = DateTime(2026, 10, 20 + i, 10).millisecondsSinceEpoch;
      db.raw.execute(
        'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
        'paid_amount, occurred_at, time_estimated, created_at, updated_at, '
        'business_day) '
        'VALUES (?, ?, ?, ?, 0, 0, ?, 0, ?, ?, ?)',
        <Object?>[
          'd$i',
          'CG2026102$i-001',
          'purchase',
          'confirmed',
          at,
          at,
          at,
          businessDayOf(at),
        ],
      );
    }
    if (schemaVersion != Schema.version) {
      // 模拟「新版本软件做的备份」：只改版本号，结构不动
      db.raw.execute('PRAGMA user_version = $schemaVersion');
    }
    db.close();
    return path;
  }

  /// 把 [databasePath] 复制成一份备份（文件名按真实规则）。
  String makeBackup({
    required DateTime time,
    bool manual = false,
    int schemaVersion = 6,
  }) {
    final String name = BackupFileName(
      manual: manual,
      schemaVersion: schemaVersion,
      time: time,
    ).fileName;
    final String target = p.join(backupDir.path, name);
    File(databasePath).copySync(target);
    return target;
  }

  Future<List<RecoveryCandidate>> scan() => scanRecoveryCandidates(
    dataDirectory: dataDir.path,
    backupDirectory: backupDir.path,
    currentSchemaVersion: Schema.version,
  ).toList();

  // ============================================================ 扫描
  group('扫描', () {
    test('空目录 ⇒ 没有任何候选', () async {
      expect(await scan(), isEmpty);
    });

    test('自动备份与手动备份都能找到，时间取文件名，单据数正确', () async {
      makeDb(databasePath);
      makeBackup(time: DateTime(2026, 10, 27, 9, 5));
      makeBackup(time: DateTime(2026, 10, 28, 15, 30), manual: true);

      final List<RecoveryCandidate> found = await scan();
      expect(found.length, 2);
      // 时间倒序：最近的排最上面（用户最可能想要它）
      expect(found.first.source, RecoverySource.manualBackup);
      expect(found.first.time, DateTime(2026, 10, 28, 15, 30));
      expect(found.last.source, RecoverySource.autoBackup);
      expect(found.last.time, DateTime(2026, 10, 27, 9, 5));

      for (final RecoveryCandidate c in found) {
        expect(c.state, RecoveryState.ok);
        expect(c.documentCount, 3, reason: '三张根单');
        expect(c.schemaVersion, Schema.version);
        expect(c.lastDocumentAt, isNotNull);
        expect(c.usable, isTrue);
      }
    });

    test('升级前留存的 shensuanzi.db.before-v5 也能当退路', () async {
      makeDb(databasePath);
      final String archived = '$databasePath.before-v5';
      File(databasePath).copySync(archived);

      final List<RecoveryCandidate> found = await scan();
      expect(found.length, 1);
      expect(found.single.source, RecoverySource.beforeMigration);
      expect(found.single.fileName, 'shensuanzi.db.before-v5');
      expect(found.single.state, RecoveryState.ok);
    });

    test('文件头坏掉的备份 ⇒ unreadable，且不能选', () async {
      makeDb(databasePath);
      final String backup = makeBackup(time: DateTime(2026, 10, 27, 9, 5));
      // 头 100 字节清零（提案 52 实测里最典型的「打不开」形态）
      final RandomAccessFile raf = File(backup).openSync(mode: FileMode.append);
      raf.setPositionSync(0);
      raf.writeFromSync(List<int>.filled(100, 0));
      raf.closeSync();

      final RecoveryCandidate c = (await scan()).single;
      expect(c.state, RecoveryState.unreadable);
      expect(c.usable, isFalse);
      expect(c.note, contains('不是'));
    });

    test('体检**不在备份目录里留垃圾**（-wal / -shm）', () async {
      // 2026-10-29 实测：普通的 `mode: readOnly` 打开 WAL 模式的库，
      // **仍会创建** `-shm` / `-wal` 两个文件。体检十次就在「神算子备份」里
      // 留二十个空文件 —— 用户打开文件夹会看到一堆莫名其妙的东西，
      // 而那个目录本来是他最需要看得懂的地方。
      makeDb(databasePath);
      makeBackup(time: DateTime(2026, 10, 27, 9, 5));
      makeBackup(time: DateTime(2026, 10, 28, 15, 30), manual: true);

      Set<String> names() => backupDir
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .toSet();

      final Set<String> before = names();
      await scan();
      expect(
        names(),
        before,
        reason: '体检必须只读不动文件（用 immutable=1 打开，别用普通 readOnly）',
      );
    });

    test('比当前软件新的备份 ⇒ newerSchema，并说清为什么不能选', () async {
      makeDb(databasePath, schemaVersion: Schema.version + 1);
      makeBackup(
        time: DateTime(2026, 10, 27, 9, 5),
        schemaVersion: Schema.version + 1,
      );

      final RecoveryCandidate c = (await scan()).single;
      expect(c.state, RecoveryState.newerSchema);
      expect(c.usable, isFalse);
      expect(c.note, contains('新版本'));
    });
  });

  // ============================================================ 清单先行（2026-11-18）
  //
  // 用户裁定甲：先列目录、再按需体检。
  // 起因是 7 份 498 MB 的备份在那台虚拟机上要 17 分钟才出全（`quick_check`
  // 要整库逐页读，实测 150 s/份）。
  group('清单先行（不打开库）', () {
    test('全部列出来，按时间倒序，state 一律 unchecked', () {
      makeDb(databasePath, docs: 2);
      final String older = makeBackup(time: DateTime(2026, 11, 15, 9));
      final String newer = makeBackup(time: DateTime(2026, 11, 17, 9), manual: true);

      final List<RecoveryCandidate> listed = listRecoveryCandidates(
        dataDirectory: dataDir.path,
        backupDirectory: backupDir.path,
      );

      expect(listed, hasLength(2));
      expect(listed.first.path, newer, reason: '时间倒序：最近那份排最前');
      expect(listed.last.path, older);
      for (final RecoveryCandidate c in listed) {
        expect(c.state, RecoveryState.unchecked);
        expect(c.usable, isFalse, reason: '未体检不许被当成「可用」');
        expect(c.bytes, File(c.path).lengthSync(), reason: '大小要能直接显示');
      }
    });

    test('**不打开**库：不是数据库的文件照样列出（体检才会说它坏）', () async {
      makeDb(databasePath, docs: 1);
      // 名字符合备份规则，内容是垃圾 —— 体检必然 unreadable
      final String garbage = p.join(
        backupDir.path,
        BackupFileName(
          manual: true,
          schemaVersion: 6,
          time: DateTime(2026, 11, 16, 10),
        ).fileName,
      );
      File(garbage).writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);

      final List<RecoveryCandidate> listed = listRecoveryCandidates(
        dataDirectory: dataDir.path,
        backupDirectory: backupDir.path,
      );
      expect(
        listed.single.state,
        RecoveryState.unchecked,
        reason: '清单阶段若去打开它，就会提前变成 unreadable —— 那正是这轮要去掉的等待',
      );

      // 对照：真体检时它确实被判为不可读（说明上面不是「假通过」）
      final List<RecoveryCandidate> scanned = await scan();
      expect(scanned.single.state, RecoveryState.unreadable);
    });

    test('清单里也能看见 `.before-vN`（来源标对）', () {
      makeDb(databasePath, docs: 1);
      File(p.join(dataDir.path, 'shensuanzi.db.before-v7'))
          .writeAsBytesSync(File(databasePath).readAsBytesSync());

      final List<RecoveryCandidate> listed = listRecoveryCandidates(
        dataDirectory: dataDir.path,
        backupDirectory: backupDir.path,
      );
      expect(listed.single.source, RecoverySource.beforeMigration);
      expect(listed.single.state, RecoveryState.unchecked);
    });
  });

  // ============================================================ 接回
  group('接回', () {
    test('接回后：新库能开、数据在、旧库改名留存**且仍可读**', () async {
      makeDb(databasePath, docs: 3);
      final String backup = makeBackup(time: DateTime(2026, 10, 27, 9, 5));

      // 把当前库改成「另一种内容」，用来证明接回来的确实是备份那份
      File(databasePath).deleteSync();
      makeDb(databasePath, docs: 7);

      final RecoveryRestoreResult result = await restoreFromCandidate(
        candidatePath: backup,
        databasePath: databasePath,
        currentSchemaVersion: Schema.version,
        now: () => DateTime(2026, 10, 29, 15, 30, 5),
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(result.archivedPath, '$databasePath.broken-20261029-153005');

      // ① 新库能开，且是备份那份（3 张单，不是 7 张）
      final Db db = Db.open(databasePath);
      final int count =
          db.raw
                  .select(
                    'SELECT COUNT(*) FROM documents WHERE ref_doc_id IS NULL',
                  )
                  .first
                  .values
                  .first!
              as int;
      db.close();
      expect(count, 3);

      // ② 旧库确实留着了，而且**还能开**（留一个打不开的文件等于没留）
      final File archived = File(result.archivedPath!);
      expect(archived.existsSync(), isTrue);
      final Db old = Db.open(archived.path);
      final int oldCount =
          old.raw
                  .select(
                    'SELECT COUNT(*) FROM documents WHERE ref_doc_id IS NULL',
                  )
                  .first
                  .values
                  .first!
              as int;
      old.close();
      expect(oldCount, 7, reason: '留存的是用户原来的那份');
    });

    test('`-wal` / `-shm` 必须跟着一起改名（否则旧 WAL 会污染新库）', () async {
      makeDb(databasePath);
      final String backup = makeBackup(time: DateTime(2026, 10, 27, 9, 5));

      // 手工造两个 sidecar：真实的 WAL 内容无关紧要，测的是「改名逻辑覆盖了它们」
      File('$databasePath-wal').writeAsStringSync('stale wal');
      File('$databasePath-shm').writeAsStringSync('stale shm');

      final RecoveryRestoreResult result = await restoreFromCandidate(
        candidatePath: backup,
        databasePath: databasePath,
        currentSchemaVersion: Schema.version,
      );
      expect(result.ok, isTrue, reason: result.message);

      expect(
        File('$databasePath-wal').existsSync(),
        isFalse,
        reason: '旧的 -wal 留在原地 ⇒ 新库一打开就被旧库的 WAL 覆盖，比不恢复更糟',
      );
      expect(File('$databasePath-shm').existsSync(), isFalse);
      expect(File('${result.archivedPath!}-wal').existsSync(), isTrue);
      expect(File('${result.archivedPath!}-shm').existsSync(), isTrue);
    });

    test('原来就没有库文件（「库不见了」场景）⇒ 不产生留存文件', () async {
      makeDb(databasePath);
      final String backup = makeBackup(time: DateTime(2026, 10, 27, 9, 5));
      File(databasePath).deleteSync();

      final RecoveryRestoreResult result = await restoreFromCandidate(
        candidatePath: backup,
        databasePath: databasePath,
        currentSchemaVersion: Schema.version,
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(result.archivedPath, isNull);
      expect(File(databasePath).existsSync(), isTrue);
    });

    test('候选是坏的 ⇒ 一个字节都不动（拿坏的盖掉能用的最糟）', () async {
      makeDb(databasePath, docs: 5);
      final String backup = makeBackup(time: DateTime(2026, 10, 27, 9, 5));
      final RandomAccessFile raf = File(backup).openSync(mode: FileMode.append);
      raf.setPositionSync(0);
      raf.writeFromSync(List<int>.filled(100, 0));
      raf.closeSync();

      final int before = File(databasePath).lengthSync();
      final RecoveryRestoreResult result = await restoreFromCandidate(
        candidatePath: backup,
        databasePath: databasePath,
        currentSchemaVersion: Schema.version,
      );
      expect(result.ok, isFalse);
      expect(result.message, isNotNull);
      expect(File(databasePath).lengthSync(), before, reason: '原库没被动过');

      // 也没有留下任何 .broken / .restoring 垃圾
      final List<String> names = dataDir
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .toList();
      expect(names.where((String n) => n.contains('broken')), isEmpty);
      expect(names.where((String n) => n.contains('restoring')), isEmpty);
    });

    test('候选在体检之后被删了 ⇒ 说清「请重新体检」，不崩', () async {
      makeDb(databasePath);
      final String backup = makeBackup(time: DateTime(2026, 10, 27, 9, 5));
      File(backup).deleteSync();

      final RecoveryRestoreResult result = await restoreFromCandidate(
        candidatePath: backup,
        databasePath: databasePath,
        currentSchemaVersion: Schema.version,
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('已经不在了'));
      expect(File(databasePath).existsSync(), isTrue);
    });
  });

  // 2026-10-31 联调 #0（用户裁定 A + B）：「修复本机账本」的前半步 —— 留档。
  group('留档（重建本机账本）', () {
    test('坏库 + -wal + -shm 一起改名，坏文件仍可读、原名消失', () {
      // 故意造一个**不是 SQLite** 的文件（真机现场：disk I/O error）
      File(databasePath).writeAsStringSync('这不是一个数据库' * 100);
      File('$databasePath-wal').writeAsStringSync('wal');
      File('$databasePath-shm').writeAsStringSync('shm');

      final ArchiveResult result = archiveBrokenDatabase(
        databasePath: databasePath,
        now: () => DateTime(2026, 10, 31, 16, 21, 22),
      );

      expect(result.ok, isTrue, reason: result.problem ?? '');
      expect(
        result.archivedPath,
        '$databasePath.broken-20261031-162122',
        reason: '命名与「接回」同一套（brokenStamp）',
      );
      // 三个文件都挪走了，一个都不许留 —— 只挪 .db 的话，新库一打开
      // 就会被旧库的 WAL 覆盖（restoreFromCandidate 第 ② 步同源）
      for (final String sidecar in <String>['', '-wal', '-shm']) {
        expect(
          File('$databasePath$sidecar').existsSync(),
          isFalse,
          reason: '原名 $sidecar 必须让开',
        );
        expect(
          File('${result.archivedPath}$sidecar').existsSync(),
          isTrue,
          reason: '留档必须带上 $sidecar',
        );
      }
      // 「不会删」这句话要能验：内容一个字节都没少
      expect(
        File(result.archivedPath!).readAsStringSync(),
        '这不是一个数据库' * 100,
      );
    });

    test('库文件本来就不存在 ⇒ 也算成功，只是没有可留档的', () {
      final ArchiveResult result = archiveBrokenDatabase(
        databasePath: databasePath,
      );
      expect(result.ok, isTrue);
      expect(result.archivedPath, isNull, reason: '没东西可留，别造一个空文件');
      expect(
        dataDir.listSync().where(
          (FileSystemEntity e) => p.basename(e.path).contains('broken'),
        ),
        isEmpty,
      );
    });

    test('留档之后原地开新库 ⇒ 拿到的是**空账**，旧数据只在 .broken 里', () {
      makeDb(databasePath, docs: 3);
      final ArchiveResult result = archiveBrokenDatabase(
        databasePath: databasePath,
      );
      expect(result.ok, isTrue);

      final Db fresh = Db.open(databasePath);
      addTearDown(fresh.close);
      expect(
        fresh.raw.select('SELECT COUNT(*) FROM documents').first.values.first,
        0,
        reason: '重建 = 空账（旧数据在留档里，不在新库里）',
      );

      final Db old = Db.open(result.archivedPath!);
      addTearDown(old.close);
      expect(
        old.raw.select('SELECT COUNT(*) FROM documents').first.values.first,
        3,
        reason: '留档的文件必须还能打开、数据还在',
      );
    });
  });

  // ------------------------------------------------------------ 2026-11-17（真机 P0）
  //
  // 现场：搬走假账后启动 → 数据恢复页 → 点「找回数据」→ **整个界面卡死**，只能强杀，
  // 日志一行都没有。根因：接回在 UI isolate 上**同步**拷整个库 + `quick_check`。
  // 这条钉「复制期间主 isolate 还能跑别的任务」—— 同步实现会让 ticks 恒为 0。
  test('接回不在 UI 线程上跑（复制期间主 isolate 仍能执行任务）', () async {
    // 候选撑到 ~30 MB：太小的话复制 + 体检短于一个 event-loop 滴答，
    // 同步实现也「看起来没问题」，这条用例就废了。
    final String candidate = p.join(
      backupDir.path,
      'shensuanzi-20261117-090000.db',
    );
    makeDb(candidate, docs: 3);
    final Db pad = Db.open(candidate);
    pad.raw.execute('CREATE TABLE pad(x BLOB)');
    for (int i = 0; i < 30; i++) {
      pad.raw.execute('INSERT INTO pad VALUES (randomblob(1000000))');
    }
    pad.close();
    expect(File(candidate).lengthSync(), greaterThan(20 * 1024 * 1024));

    makeDb(databasePath, docs: 1); // 现库（接回时会被改名留存）

    int ticks = 0;
    final Timer timer = Timer.periodic(
      const Duration(milliseconds: 5),
      (Timer _) => ticks++,
    );
    final RecoveryRestoreResult result = await restoreFromCandidate(
      candidatePath: candidate,
      databasePath: databasePath,
      currentSchemaVersion: Schema.version,
    );
    timer.cancel();

    expect(result.ok, isTrue, reason: result.message ?? '接回失败');
    expect(
      ticks,
      greaterThan(0),
      reason: '同步实现跑在 UI isolate 上 ⇒ 复制期间一个滴答都跑不了（真机 = 整窗卡死）',
    );
  });
}
