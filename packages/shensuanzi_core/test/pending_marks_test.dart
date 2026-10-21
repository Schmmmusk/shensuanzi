// `PendingMarks` 的测试（D2b —— `data_model.md §4.4` 第 3 条「乐观行必须可分辨」）。
//
// 乐观写让刚建的行立刻可见；本类回答**对偶问题**：哪几行主机还没确认。
//
// ⚠️ **分工**：本测试只验**判定**（哪些 id 算未确认）；
// 「界面上到底有没有那行浅灰小字」由根包 widget 测试守
// （`test/products_page_test.dart` / `parties_page_test.dart` / `account_page_test.dart`）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late Db db;
  late SyncQueueDao queue;
  late PendingMarks marks;

  setUp(() {
    db = newMemoryDb();
    queue = SyncQueueDao(db);
    marks = PendingMarks(queue);
  });

  tearDown(() => db.close());

  /// 队列条目 id 刻意与实体 id 不同 —— 这样「传错 id」会当场暴露
  /// （`markSent` / `markFailed` 收的是**条目** id，`clearConfirmed` 收**实体** id）。
  SyncQueueEntry entry(String entityId) => SyncQueueEntry(
    id: 'q-$entityId',
    entity: Schema.products,
    entityId: entityId,
    operation: SyncOpType.createMasterData,
    createdAt: now(),
  );

  test('空队列 ⇒ 没有行是「待同步」', () {
    expect(marks.ids, isEmpty);
  });

  test('乐观写入了、还在 pending ⇒ 该行「待同步」', () {
    queue.enqueue(entry('p1'));
    expect(marks.ids, <String>{'p1'});
  });

  test('主机已收下（sent）、还没被 pull 确认 ⇒ **仍算**「待同步」', () {
    queue.enqueue(entry('p1'));
    queue.markSent('q-p1');

    expect(marks.ids, <String>{
      'p1',
    }, reason: 'sent =「主机已收下、但 pull 还没见到」⇒ 还没确认');
  });

  test('推送成功 + pull 真的见到 ⇒ 不再算（小字该消失）', () {
    queue.enqueue(entry('p1'));
    queue.markSent('q-p1'); // 主机已收下 ⇒ sent
    queue.clearConfirmed(<String>{'p1'}); // pull 真的见到了 ⇒ 清

    expect(marks.ids, isEmpty);
  });

  test('**还没推送**的条目不因 pull 被清 —— `clearConfirmed` 只删 `sent`', () {
    queue.enqueue(entry('p1'));

    // 即便 pull「声称」见到了它，`pending` 也不该被清 ——
    // 那会把「主机根本没收下、本地唯一一份」的数据丢掉（R-14 附带问题 3）。
    queue.clearConfirmed(<String>{'p1'});

    expect(marks.ids, <String>{'p1'}, reason: '清只针对 sent；pending 是「还没发出去」');
  });

  test('死信（failed）**不算** —— 它要人工处理，混进来会让小字常亮', () {
    queue.enqueue(entry('p1'));
    queue.markFailed(
      'q-p1',
      error: 'rejected',
      retryCount: SyncClient.maxRetries + 1,
      nextRetryAt: 0,
      dead: true,
    );

    expect(marks.ids, isEmpty);
  });

  test('多条一起：pending 与 sent **都**在集合里，没写过的行不在', () {
    queue.enqueue(entry('p1'));
    queue.enqueue(entry('p2'));
    queue.markSent('q-p2');

    expect(marks.ids, <String>{'p1', 'p2'});
    expect(marks.ids.contains('p3'), isFalse, reason: '没在队列里的行不该带「待同步」小字');
  });
}
