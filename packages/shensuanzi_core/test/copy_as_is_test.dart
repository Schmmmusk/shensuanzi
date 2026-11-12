// 「一份数据库副本」的两个原语：`copyDatabaseAsIs`（字节保真）与
// `snapshotDatabaseTo`（一致快照）。对应 `docs/proposals/63-同款备份路径-处置方案.md`。
//
// 这两条路径修的是**同一类 bug 的两个面**：
//   - 拷贝：checkpoint 返回值没人看 → 忙时只归并一半就照拷
//   - 快照：源库默认 `readWriteCreate` 打开 → 文件不在时凭空建空库、报「成功」
//
// ⚠️ 纯 Dart 测试需要可用的 SQLite 原生库，见 `lib/sqlite_local.dart`。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Directory box;
  late String dbPath;
  late Db db;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_snapshot_');
    dbPath = p.join(box.path, 'shensuanzi.db');
    db = Db.open(dbPath);
    // 一条单据 —— 用来断言「副本里真有数据」
    db.raw.execute(
      "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
      'paid_amount, occurred_at, time_estimated, created_at, updated_at, '
      'business_day) '
      "VALUES ('d1', 'CG20260928-001', 'purchase', 'confirmed', 0, 0, "
      '1700000000000, 0, 1700000000000, 1700000000000, '
      '${businessDayOf(1700000000000)})',
    );
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  /// 副本里能读到的那条单据（用来证明「拷的是内容，不是空壳」）
  int countDocuments(String path) {
    final Database raw = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return raw.select('SELECT COUNT(*) AS c FROM documents').first['c']!
          as int;
    } finally {
      raw.dispose();
    }
  }

  group('copyDatabaseAsIs（迁移前备份：字节保真）', () {
    test('正常拷贝 ⇒ 无问题码、内容与原库一致、user_version 相同', () {
      final String target = p.join(box.path, 'before.db');

      final CopyProblem? problem = copyDatabaseAsIs(
        db: db.raw,
        source: dbPath,
        target: target,
      );

      expect(problem, isNull);
      expect(File(target).existsSync(), isTrue);
      expect(countDocuments(target), 1);
      final Database copy = sqlite3.open(target, mode: OpenMode.readOnly);
      try {
        expect(
          copy.select('PRAGMA user_version').first.values.first,
          db.schemaVersion,
        );
      } finally {
        copy.dispose();
      }
      // 正式的 `.before-vN` 旁边不该有 tmp
      expect(File('$target.tmp').existsSync(), isFalse);
    });

    test('另一条连接持读事务 ⇒ checkpoint 归并不完 ⇒ 返回 checkpointIncomplete（不是照拷）', () {
      final String target = p.join(box.path, 'before.db');
      // 先让 WAL 里堆上帧（不 checkpoint）
      for (int i = 0; i < 40; i++) {
        db.raw.execute(
          "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
          'paid_amount, occurred_at, time_estimated, created_at, updated_at, '
          'business_day) '
          "VALUES ('x$i', 'CG20260928-1$i', 'purchase', 'confirmed', 0, 0, "
          '1700000000000, 0, 1700000000000, 1700000000000, '
          '${businessDayOf(1700000000000)})',
        );
      }
      // 第二条连接拿住读快照（钉住 read-mark）
      final Database reader = sqlite3.open(dbPath);
      reader.execute('BEGIN');
      reader.select('SELECT COUNT(*) FROM documents');

      try {
        final CopyProblem? problem = copyDatabaseAsIs(
          db: db.raw,
          source: dbPath,
          target: target,
        );
        expect(
          problem,
          CopyProblem.checkpointIncomplete,
          reason:
              'busy/log/checkpointed 三列必须一起看 —— '
              '这种情形下 wal_checkpoint 是**正常返回**的，不抛异常',
        );
        expect(File(target).existsSync(), isFalse, reason: '不确定一致就不产出副本');
      } finally {
        reader.execute('ROLLBACK');
        reader.dispose();
      }
    });

    test('同名备份已存在 ⇒ 跳过，且**不覆盖**（保留最早那份）', () {
      final String target = p.join(box.path, 'before.db');
      File(target).writeAsStringSync('早期版本留档');

      final CopyProblem? problem = copyDatabaseAsIs(
        db: db.raw,
        source: dbPath,
        target: target,
      );

      expect(problem, isNull);
      expect(File(target).readAsStringSync(), '早期版本留档');
    });

    test('改名失败（目标位置是个目录）⇒ copyFailed，tmp 不残留', () {
      final String target = p.join(box.path, 'before.db');
      Directory(target).createSync();

      final CopyProblem? problem = copyDatabaseAsIs(
        db: db.raw,
        source: dbPath,
        target: target,
      );

      expect(problem, CopyProblem.copyFailed);
      expect(File('$target.tmp').existsSync(), isFalse, reason: '失败不留半成品');
    });
  });

  group('snapshotDatabaseTo（一致快照：归档/导出/备份）', () {
    test('正常生成 ⇒ 可读、内容一致、无 -wal/-shm 残留', () {
      final String target = p.join(box.path, 'snap.db');

      final SnapshotProblem? problem = snapshotDatabaseTo(
        source: dbPath,
        target: target,
      );

      expect(problem, isNull);
      expect(countDocuments(target), 1);
      // 校验走只读连接 ⇒ 不会像 `Db.open` 那样把副本切成 WAL 并留下 sidecar
      expect(File('$target-wal').existsSync(), isFalse);
      expect(File('$target-shm').existsSync(), isFalse);
    });

    test('源文件不在 ⇒ sourceMissing，且**不会凭空建出空库**', () {
      final String missing = p.join(box.path, 'nope.db');
      final String target = p.join(box.path, 'snap.db');

      final SnapshotProblem? problem = snapshotDatabaseTo(
        source: missing,
        target: target,
      );

      expect(problem, SnapshotProblem.sourceMissing);
      expect(
        File(missing).existsSync(),
        isFalse,
        reason: '默认 readWriteCreate 会在这里建一个空库 ⇒ 「备份成功」而备份是空的',
      );
      expect(File(target).existsSync(), isFalse);
    });

    test('目标就是源库自己 ⇒ writeFailed，源库完好', () {
      final int before = File(dbPath).lengthSync();

      final SnapshotProblem? problem = snapshotDatabaseTo(
        source: dbPath,
        target: dbPath,
      );

      expect(problem, SnapshotProblem.writeFailed);
      expect(File(dbPath).lengthSync(), before);
      expect(countDocuments(dbPath), 1, reason: '源库必须还能读');
    });

    test('源库不是数据库 ⇒ unreadable，目标不残留', () {
      final String broken = p.join(box.path, 'broken.db');
      File(broken).writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
      final String target = p.join(box.path, 'snap.db');

      final SnapshotProblem? problem = snapshotDatabaseTo(
        source: broken,
        target: target,
      );

      expect(problem, SnapshotProblem.unreadable);
      expect(File(target).existsSync(), isFalse);
    });
  });

  // 手机「导出本机数据」把「未同步单据清单」和 `.db` 一起交给分享面板。
  // 清单的用途是**照着它核对哪些单没传上去** ⇒ 两者必须出自同一时刻。
  // 这一组钉的就是那个性质：清单从**快照**里读，不是从活的队列里读。
  group('SyncQueueDao.unsentIn（从快照读队列 ⇒ 与库副本同一时间边界）', () {
    SyncQueueEntry entry(String id, int createdAt) => SyncQueueEntry(
      id: id,
      entity: 'documents',
      entityId: id,
      operation: SyncOpType.createDocument,
      payload: const <String, Object?>{'id': 'x'},
      createdAt: createdAt,
    );

    test('快照之后队列又变了 ⇒ 清单仍是快照那一刻的样子', () {
      final SyncQueueDao live = SyncQueueDao(db);
      live.enqueue(entry('q1', 1000));
      live.enqueue(entry('q2', 2000));

      final String snap = p.join(box.path, 'snap.db');
      expect(snapshotDatabaseTo(source: dbPath, target: snap), isNull);

      // 快照**之后**：一条被用户放弃、一条推送成功（转 sent）、又新开一单
      live.discard('q1', reason: '用户放弃'); // 仍是「未同步」口径里的一条
      live.markSent('q2');
      live.enqueue(entry('q3', 4000));

      final List<String> fromSnapshot = SyncQueueDao.unsentIn(
        snap,
      ).map((SyncQueueEntry e) => e.entityId).toList();
      expect(
        fromSnapshot,
        <String>['q1', 'q2'],
        reason: '清单必须来自快照；活库此刻已经不是这两条了',
      );
      // 反证：活库确实变了 —— 没有这一步，上面那条即使读活库也可能「碰巧」通过
      expect(
        SyncQueueDao(
          db,
        ).unsent().map((SyncQueueEntry e) => e.entityId).toList(),
        <String>['q1', 'q3'],
      );
    });

    test('`sent` 不算「未同步」—— 与活库的 unsent() 同一口径', () {
      final SyncQueueDao live = SyncQueueDao(db);
      live.enqueue(entry('q1', 1000));
      live.enqueue(entry('q2', 2000));
      live.markSent('q2');

      final String snap = p.join(box.path, 'snap.db');
      expect(snapshotDatabaseTo(source: dbPath, target: snap), isNull);

      expect(
        SyncQueueDao.unsentIn(snap)
            .map((SyncQueueEntry e) => e.entityId)
            .toList(),
        <String>['q1'],
      );
    });

    test('读不了快照 ⇒ 抛（导出那边据此**阻断分享**，不给缺单的包）', () {
      final String snap = p.join(box.path, 'snap.db');
      File(snap).writeAsStringSync('不是数据库');

      expect(() => SyncQueueDao.unsentIn(snap), throwsA(isA<SqliteException>()));
    });
  });
}
