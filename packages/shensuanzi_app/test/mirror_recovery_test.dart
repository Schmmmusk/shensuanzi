// 镜像**文件本身**打不开时的隔离恢复（`MobileSyncService.recoverBrokenMirror`）
// —— 2026-10-31 用户裁定「状态 3」（`docs/reply.md` §四）。
//
// ## 用户点出的死角
//
// > 设置页现有的「重建本机数据副本」也存在这个限制：它先调用 `_meta()`，
// > 而 `_meta()` 又会调用 `openMirror()`。镜像打不开时，
// > 甚至无法进入真正的重建步骤。
//
// 所以这条路径必须**一步都不碰旧库**：抢队列（副本上）→ 留档原件 →
// 建新副本 → 回填队列。这一组用例就是钉这四步，外加「救不回来的要说出来」。
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
  late PairingStore pairing;
  late MobileSyncService service;
  late String workDir;

  setUp(() {
    box = Directory.systemTemp.createTempSync('ssz_mirror_recovery_');
    mirrorPath = p.join(box.path, 'mirror', 'shensuanzi_mirror.db');
    Directory(p.dirname(mirrorPath)).createSync(recursive: true);
    pairing = PairingStore(File(p.join(box.path, 'pairing.json')));
    service = MobileSyncService(mirrorPath: mirrorPath, pairingStore: pairing);
    workDir = p.join(box.path, 'mirror', 'rescue-tmp');
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {}
  });

  void pair() => pairing.save(
    const PairingInfo(
      hostId: 'h-1',
      ip: '127.0.0.1',
      port: 17890,
      token: 'tok',
    ),
  );

  SyncQueueEntry queued(
    String id, {
    SyncQueueStatus status = SyncQueueStatus.pending,
    int createdAt = 1700000000000,
  }) => SyncQueueEntry(
    id: id,
    entity: 'documents',
    entityId: 'doc-$id',
    operation: SyncOpType.createDocument,
    payload: <String, Object?>{'id': 'doc-$id'},
    status: status,
    createdAt: createdAt,
  );

  /// 造一份「**打不开但读得出**」的镜像。
  ///
  /// 手法：`user_version` 设成比程序高的数字 ⇒ `Db.open` 抛（版本不匹配），
  /// 而底层文件完好、`sync_queue` 一行不少。真机上等价于
  /// 「`PRAGMA journal_mode = WAL` 报 disk I/O error」—— 文件没坏，是**打不开**。
  void seedUnopenableMirror() {
    final Db db = service.openMirror();
    final SyncQueueDao queue = SyncQueueDao(db);
    queue.enqueue(queued('a', createdAt: 1700000001000));
    queue.enqueue(
      queued('b', status: SyncQueueStatus.sent, createdAt: 1700000002000),
    );
    queue.enqueue(
      queued('c', status: SyncQueueStatus.failed, createdAt: 1700000003000),
    );
    db.raw.execute('PRAGMA user_version = 999');
    db.close();
  }

  test('留档原件 + 抢回队列 + 新副本能开 + sent 降级重推', () {
    pair();
    seedUnopenableMirror();

    final MirrorRecoveryResult result = service.recoverBrokenMirror(
      workDirectory: workDir,
    );

    expect(result.ok, isTrue, reason: result.message ?? '');
    expect(result.restored, 3, reason: '三条都要抢回来');
    expect(result.lostCount, 0);
    expect(result.paired, isTrue);

    // ① 原件留档（改名，不删）
    expect(result.archivedPath, isNotNull);
    expect(File(result.archivedPath!).existsSync(), isTrue);
    expect(
      File(result.archivedPath!).lengthSync(),
      greaterThan(0),
      reason: '留档里得有内容，不是空壳',
    );

    // ② 新副本能开、队列回填
    final Db fresh = service.openMirror();
    expect(fresh.schemaVersion, Schema.version);
    // `unsent()` = 除 `sent` 以外的全部（`pending` + `failed`）
    final List<SyncQueueEntry> rows = SyncQueueDao(fresh).unsent();
    expect(
      rows.map((SyncQueueEntry e) => e.id).toList()..sort(),
      <String>['a', 'b', 'c'],
      reason: '三条都要回填；`sent` 已经降级成 pending ⇒ 也在里面',
    );
    expect(
      rows.firstWhere((SyncQueueEntry e) => e.id == 'b').status,
      SyncQueueStatus.pending,
      reason:
          'sent 的语义是「主机已收下、本机没确认」；新副本里没有它 ⇒ 降级重推'
          '（推送按实体 id 幂等，重推比漏推安全）',
    );
    expect(
      SyncQueueDao(
        fresh,
      ).allForHostSwitch().firstWhere((SyncQueueEntry e) => e.id == 'c').status,
      SyncQueueStatus.failed,
      reason: '死信保持死信 —— 用户还得看得见它',
    );

    // ③ 身份跟着过来（同一台主机 ⇒ 不用重新扫码）
    expect(MirrorMeta(fresh).hostId, 'h-1');
  });

  test('文件彻底认不出 ⇒ 照样能重建，但**如实说一条都没抢回**', () {
    pair();
    service.openMirror().close();
    File(mirrorPath).writeAsBytesSync(List<int>.filled(4096, 0x42));

    final MirrorRecoveryResult result = service.recoverBrokenMirror(
      workDirectory: workDir,
    );

    expect(result.ok, isTrue, reason: '认不出也要能把副本重建起来');
    expect(result.restored, 0);
    expect(result.rescue.attempted, isTrue);
    expect(result.rescue.problem, isNotNull, reason: '为什么抢不回，要说出来');
    expect(service.openMirror().schemaVersion, Schema.version);
  });

  test('没配对也要能修（修完让用户去扫码，不假装已同步）', () {
    service.openMirror().close();
    File(mirrorPath).writeAsBytesSync(List<int>.filled(1024, 0x42));

    final MirrorRecoveryResult result = service.recoverBrokenMirror(
      workDirectory: workDir,
    );

    expect(result.ok, isTrue);
    expect(result.paired, isFalse);
    expect(service.openMirror().schemaVersion, Schema.version);
  });

  test('恢复之后**不留副本垃圾**（rescue-tmp 清干净）', () {
    pair();
    seedUnopenableMirror();
    service.recoverBrokenMirror(workDirectory: workDir);
    final Directory dir = Directory(workDir);
    expect(
      dir.existsSync() ? dir.listSync() : <FileSystemEntity>[],
      isEmpty,
      reason: '抢救副本必须清掉 —— 那是几百 MB 的临时文件',
    );
  });
}
