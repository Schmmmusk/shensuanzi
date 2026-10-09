// 三态条判定依据的测试（B3a·裁定 ④）。
//
// 「已同步」≠「队列为空」：`sent` 还在队列里（等 pull 确认）但主机已收下，
// 所以判定 = 没有 pending 和 failed；`sent` 不显示。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late Db db;
  late SyncQueueDao queue;

  SyncQueueEntry entry(String id) => SyncQueueEntry(
    id: id,
    entity: Schema.documents,
    entityId: 'entity-$id',
    operation: SyncOpType.createDocument,
    createdAt: 1700000000000,
  );

  setUp(() {
    db = newMemoryDb();
    queue = SyncQueueDao(db);
  });

  tearDown(() => db.close());

  test('空队列 ⇒ 已同步（0 / 0）', () {
    final SyncQueueTriage triage = queue.counts();
    expect(triage.pendingCount, 0);
    expect(triage.failedCount, 0);
    expect(triage.isSynced, isTrue);
  });

  test('一条 pending ⇒ 待同步 1，未同步', () {
    queue.enqueue(entry('e1'));
    final SyncQueueTriage triage = queue.counts();
    expect(triage.pendingCount, 1);
    expect(triage.failedCount, 0);
    expect(triage.isSynced, isFalse);
  });

  test('pending → sent ⇒ **已同步**（sent 不显示 —— 主机已收下）', () {
    queue.enqueue(entry('e1'));
    queue.markSent('e1');
    final SyncQueueTriage triage = queue.counts();
    expect(triage.pendingCount, 0);
    expect(triage.failedCount, 0);
    expect(triage.isSynced, isTrue, reason: '已同步 ≠ 队列为空：sent 还在但不算');
    expect(queue.count(), 1, reason: '条目还在等 pull 确认');
  });

  test('死信 ⇒ 失败 1，与待同步**并列**不覆盖', () {
    queue.enqueue(entry('e1'));
    queue.enqueue(entry('e2'));
    queue.markSent('e2');
    queue.enqueue(entry('e3'));
    queue.markFailed(
      'e3',
      error: 'rejected',
      retryCount: SyncClient.maxRetries + 1,
      nextRetryAt: 0,
      dead: true,
    );

    final SyncQueueTriage triage = queue.counts();
    expect(triage.pendingCount, 1, reason: 'e1 还在 pending');
    expect(triage.failedCount, 1, reason: 'e3 死信');
    expect(triage.isSynced, isFalse);
  });

  test('明细列表：pending / failed 各自可查（withStatus，sent 除外）', () {
    queue.enqueue(entry('e1'));
    queue.enqueue(entry('e2'));
    queue.enqueue(entry('e3'));
    queue.markSent('e2');
    queue.markFailed(
      'e3',
      error: 'boom',
      retryCount: SyncClient.maxRetries + 1,
      nextRetryAt: 0,
      dead: true,
    );

    expect(queue.withStatus(SyncQueueStatus.pending).map((SyncQueueEntry e) => e.id), <String>['e1']);
    expect(queue.withStatus(SyncQueueStatus.failed).map((SyncQueueEntry e) => e.id), <String>['e3']);
  });

  // ---------------- D2b：镜像主数据行的 `isPending` 判定 ----------------

  test('unconfirmedEntityIds：pending + sent 都算「未确认」，failed 不算', () {
    queue.enqueue(entry('e1')); // pending
    queue.enqueue(entry('e2'));
    queue.markSent('e2'); // sent：主机已收下、等 pull 确认
    queue.enqueue(entry('e3'));
    queue.markFailed(
      'e3',
      error: 'boom',
      retryCount: SyncClient.maxRetries + 1,
      nextRetryAt: 0,
      dead: true,
    );

    expect(
      queue.unconfirmedEntityIds(),
      <String>{'entity-e1', 'entity-e2'},
      reason: 'pending + sent 都未确认；failed（死信）不算 —— 否则「待同步」会常亮',
    );
  });

  test('unconfirmedEntityIds：pull 确认后不再算（clearConfirmed 删条目）', () {
    queue.enqueue(entry('e1'));
    queue.markSent('e1');
    expect(queue.unconfirmedEntityIds(), <String>{'entity-e1'});

    queue.clearConfirmed(<String>{'entity-e1'});
    expect(
      queue.unconfirmedEntityIds(),
      isEmpty,
      reason: 'pull 见到该 id ⇒ 条目删除 ⇒ 不再是「待同步」',
    );
  });

  test('unconfirmedEntityIds：同一实体两条 op ⇒ 去重成一个 id', () {
    // D2b：客户端**不合并**同一实体的 create + update（靠主机 upsert 收敛）⇒
    // 队列里会有两条同 entity_id 的条目，标记必须是**一个**。
    queue.enqueue(
      SyncQueueEntry(
        id: 'c1',
        entity: Schema.products,
        entityId: 'p1',
        operation: SyncOpType.createMasterData,
        createdAt: 1700000000000,
      ),
    );
    queue.enqueue(
      SyncQueueEntry(
        id: 'u1',
        entity: Schema.products,
        entityId: 'p1',
        operation: SyncOpType.updateMasterData,
        createdAt: 1700000000001,
      ),
    );

    expect(queue.unconfirmedEntityIds(), <String>{'p1'}, reason: 'Set 去重');
  });
}
