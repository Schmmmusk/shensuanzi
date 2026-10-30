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
}
