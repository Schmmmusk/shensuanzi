// 镜像损坏时的队列抢救（`rescueMirrorQueue` / `queueRescueReport`）—— 2026-10-31。
//
// ## 用户裁定（`docs/reply.md` §四「状态 3」）
//
// > 镜像文件无法打开 · **隔离恢复**：不直接覆盖原文件。先保留原件和 WAL 相关文件，
// > 尝试独立抢救队列；之后再创建新镜像、重新拉取。
// >
// > 电脑上的业务数据是可重新获取的；手机上尚未上传的操作是必须优先保护的。
//
// 所以这一层只做两件事：**在副本上抢队列**、**把抢到什么如实写成清单**。
// 原件由调用方留档（`archiveBrokenDatabase`），本层**从不删除原件**。
//
// 运行：`dart test`
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late String mirrorPath;
  late String work;

  setUp(() {
    box = Directory.systemTemp.createTempSync('ssz_mirror_rescue_');
    mirrorPath = p.join(box.path, 'mirror', 'shensuanzi_mirror.db');
    Directory(p.dirname(mirrorPath)).createSync(recursive: true);
    work = p.join(box.path, 'rescue-tmp');
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {}
  });

  SyncQueueEntry entry({
    required String id,
    SyncOpType op = SyncOpType.createDocument,
    SyncQueueStatus status = SyncQueueStatus.pending,
    int createdAt = 1700000000000,
    String entity = 'documents',
  }) => SyncQueueEntry(
    id: id,
    entity: entity,
    entityId: 'doc-$id',
    operation: op,
    payload: <String, Object?>{'id': 'doc-$id', 'doc_no': 'XS-$id'},
    status: status,
    createdAt: createdAt,
  );

  /// 造一份「能开」的镜像（= 真机上的正常文件），返回句柄（**不关**，
  /// 这样条目还留在 `-wal` 里 —— 正是真机坏掉时的样子）
  Db makeMirror(List<SyncQueueEntry> entries) {
    final Db db = Db.open(mirrorPath, foreignKeys: false);
    final SyncQueueDao queue = SyncQueueDao(db);
    for (final SyncQueueEntry e in entries) {
      queue.enqueue(e);
    }
    return db;
  }

  group('抢救', () {
    test('文件头坏 ⇒ 一条也抢不回，但**原件一个字节都没动**，原因说人话', () {
      final Db db = makeMirror(<SyncQueueEntry>[entry(id: 'a')]);
      db.close();
      // 覆盖文件头（真机现场是 disk I/O error / not a database）
      File(mirrorPath).writeAsBytesSync(List<int>.filled(4096, 0x42));
      final List<int> before = File(mirrorPath).readAsBytesSync();

      final MirrorQueueRescue rescue = rescueMirrorQueue(
        mirrorPath: mirrorPath,
        workDirectory: work,
      );

      expect(rescue.attempted, isTrue);
      expect(rescue.ok, isFalse);
      expect(rescue.entries, isEmpty);
      expect(rescue.problem, isNotNull);
      // 人话：不许出现 SQL 术语
      expect(rescue.problem, isNot(contains('SqliteException')));
      expect(rescue.problem, isNot(contains('malformed')));
      // 原件没动过
      expect(File(mirrorPath).readAsBytesSync(), before);
      // 副本清干净了（不许在用户目录里留垃圾）
      final Directory workDir = Directory(work);
      expect(
        workDir.existsSync() ? workDir.listSync() : <FileSystemEntity>[],
        isEmpty,
      );
    });

    test('文件不存在 ⇒ attempted = false（这不是失败）', () {
      final MirrorQueueRescue rescue = rescueMirrorQueue(
        mirrorPath: mirrorPath,
        workDirectory: work,
      );
      expect(rescue.attempted, isFalse);
      expect(rescue.ok, isTrue, reason: '没有文件可抢 ≠ 抢救失败');
      expect(rescue.entries, isEmpty);
    });

    test('**`-wal` 里没 checkpoint 的条目也能抢回**（真机坏掉时最新的单就在那）', () {
      // 句柄**故意不关**：条目还在 WAL 里，`.db` 本体是空的
      final Db db = makeMirror(<SyncQueueEntry>[
        entry(id: 'a', createdAt: 1700000001000),
        entry(id: 'b', createdAt: 1700000002000, status: SyncQueueStatus.sent),
      ]);
      addTearDown(db.close);

      final MirrorQueueRescue rescue = rescueMirrorQueue(
        mirrorPath: mirrorPath,
        workDirectory: work,
      );

      expect(rescue.ok, isTrue, reason: rescue.problem ?? '');
      expect(
        rescue.entries.map((SyncQueueEntry e) => e.id).toList(),
        <String>['a', 'b'],
        reason: '只拷 .db 不拷 -wal 就会漏掉这两条',
      );
      // 字段一个不变（回填要靠它们）
      final SyncQueueEntry b = rescue.entries.last;
      expect(b.status, SyncQueueStatus.sent);
      expect(b.entityId, 'doc-b');
      expect(b.payload['doc_no'], 'XS-b');
      expect(b.createdAt, 1700000002000);
    });

    test('跑完把副本删干净（不许在用户目录里留半个库）', () {
      final Db db = makeMirror(<SyncQueueEntry>[entry(id: 'a')]);
      db.close();
      rescueMirrorQueue(mirrorPath: mirrorPath, workDirectory: work);
      final Directory workDir = Directory(work);
      expect(
        workDir.existsSync() ? workDir.listSync() : <FileSystemEntity>[],
        isEmpty,
        reason: '副本（含 -wal / -shm）必须清掉',
      );
    });
  });

  group('清单（用户裁定：救不回来的必须说出来）', () {
    test('抢回 N 条 ⇒ 说清条数、明细、状态', () {
      final Db db = makeMirror(<SyncQueueEntry>[
        entry(id: 'a', createdAt: 1700000001000),
        entry(
          id: 'b',
          createdAt: 1700000002000,
          status: SyncQueueStatus.failed,
          op: SyncOpType.createMasterData,
          entity: 'products',
        ),
      ]);
      db.close();
      final MirrorQueueRescue rescue = rescueMirrorQueue(
        mirrorPath: mirrorPath,
        workDirectory: work,
      );

      final String report = queueRescueReport(
        rescue: rescue,
        at: DateTime(2026, 10, 31, 22, 5),
        archivedPath: '$mirrorPath.broken-20261031-220500',
      );

      expect(report, contains('抢回 2 条'));
      expect(report, contains('单据'));
      expect(report, contains('商品'));
      expect(report, contains('新增资料'));
      expect(report, contains('待传'));
      expect(report, contains('失败（需人工）'));
      expect(report, contains('broken-20261031-220500'));
    });

    test('一条也没抢回 ⇒ **不许**说「已经找回」，要写明原因', () {
      final MirrorQueueRescue failed = MirrorQueueRescue(
        entries: const <SyncQueueEntry>[],
        unreadableRows: 0,
        problem: '这个文件已经认不出来了（文件头坏了），里面的东西没法读',
        attempted: true,
      );
      final String report = queueRescueReport(
        rescue: failed,
        at: DateTime(2026, 10, 31, 22, 5),
      );
      expect(report, contains('一条也没能读出来'));
      expect(report, contains('文件头坏了'));
      expect(report, isNot(contains('抢回')));
      expect(report, isNot(contains('已经找回')));
    });

    test('有读不出来的行 ⇒ 明说「这部分没法还原，不要当成已找回」', () {
      final MirrorQueueRescue partial = MirrorQueueRescue(
        entries: <SyncQueueEntry>[entry(id: 'a')],
        unreadableRows: 3,
        problem: null,
        attempted: true,
      );
      final String report = queueRescueReport(
        rescue: partial,
        at: DateTime(2026, 10, 31, 22, 5),
      );
      expect(report, contains('另有 3 条'));
      expect(report, contains('请不要当成「已经找回」'));
    });
  });
}
