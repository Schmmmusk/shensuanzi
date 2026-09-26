// core 自检：`dart run tool/selfcheck_sync_client.dart`
//
// 覆盖客户端同步引擎：游标原样保存（B8）、pull 的事务原子性、
// push 的状态流转与退避、未同步影响（delta）。
// 与 `test/sync_client_test.dart` 断言等价 —— 本机 `dart test` 无法编译测试文件
// （见 `docs/testing.md` §零）。
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**，失败可复现。

import 'dart:convert';
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

int _passed = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void section(String title) => stdout.writeln('\n[$title]');

/// 可编程的假传输层：记录请求，按脚本返回响应。
class FakeTransport implements Transport {
  final List<TransportRequest> requests = <TransportRequest>[];
  final List<Object> _script = <Object>[];

  void replyJson(Map<String, Object?> body) =>
      _script.add(TransportResponse(statusCode: 200, body: jsonEncode(body)));

  void replyRaw(int statusCode, String body) =>
      _script.add(TransportResponse(statusCode: statusCode, body: body));

  void replyThrow(Object error) => _script.add(error);

  TransportRequest get last => requests.last;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    requests.add(request);
    if (_script.isEmpty) {
      throw StateError('FakeTransport 脚本已用尽（第 ${requests.length} 次请求）');
    }
    final Object next = _script.removeAt(0);
    if (next is TransportResponse) return next;
    throw next;
  }
}

int _clock = 1700000000000;
int now() => _clock++;
void resetClock() => _clock = 1700000000000;

const String _productId = 'p-00000000-0000-7000-8000-000000000001';

Map<String, Object?> pullBody({
  List<Map<String, Object?>> documents = const <Map<String, Object?>>[],
  List<Map<String, Object?>> lines = const <Map<String, Object?>>[],
  List<Map<String, Object?>> stock = const <Map<String, Object?>>[],
  List<Map<String, Object?>> products = const <Map<String, Object?>>[],
  Map<String, String> cursors = const <String, String>{},
}) => <String, Object?>{
  'documents': documents,
  'document_lines': lines,
  'stock_ledger': stock,
  'money_ledger': <Object?>[],
  'party_ledger': <Object?>[],
  'settlements': <Object?>[],
  'products': products,
  'parties': <Object?>[],
  'accounts': <Object?>[],
  'next_cursors': cursors,
};

Map<String, Object?> docRow(String id,
        {String docNo = 'CG20260926-001'}) => <String, Object?>{
  'id': id,
  'doc_no': docNo,
  'doc_type': 'purchase',
  'status': 'confirmed',
  'party_id': null,
  'account_id': null,
  'total_amount': 1000,
  'paid_amount': 0,
  'ref_doc_id': null,
  'occurred_at': 1700000000000,
  'time_estimated': 0,
  'created_at': 1700000000000,
  'updated_at': 1700000000000,
  'remark': null,
};

Map<String, Object?> lineRow(String id, String documentId) => <String, Object?>{
  'id': id,
  'document_id': documentId,
  'product_id': _productId,
  'quantity': 10,
  'unit_price': 100,
  'amount': 1000,
  'remark': null,
};

Map<String, Object?> productRow(String id) => <String, Object?>{
  'id': id,
  'code': 'P001',
  'name': '商品',
  'barcode': null,
  'unit': '件',
  'cost_price': 100,
  'sell_price': 200,
  'safety_stock': 0,
  'category': null,
  'is_active': 1,
  'remark': null,
  'created_at': 1700000000000,
  'updated_at': 1700000000000,
  'sync_version': 0,
};

SyncOperation docOp(String id, String docType, List<int> quantities) =>
    SyncOperation(
      entity: Schema.documents,
      entityId: id,
      operation: SyncOpType.createDocument,
      payload: <String, Object?>{
        'document': <String, Object?>{'id': id, 'doc_type': docType},
        'lines': <Object?>[
          for (int i = 0; i < quantities.length; i++)
            <String, Object?>{
              'product_id': 'p$i',
              'quantity': quantities[i],
              'unit_price': 100,
              'amount': quantities[i] * 100,
            },
        ],
      },
    );

Map<String, Object?> receipt(String entityId, String status, {String? reason}) =>
    <String, Object?>{
      'entity_id': entityId,
      'status': status,
      // `?reason` = 空值感知元素（等价于 `if (reason != null) 'reason': reason`）
      'reason': ?reason,
    };

Map<String, Object?> pushBody(List<Map<String, Object?>> results) =>
    <String, Object?>{'results': results};

Future<void> main() async {
  useLocalSqlite();
  resetClock();
  final Db db = Db.openInMemory(foreignKeys: false);
  final FakeTransport transport = FakeTransport();
  final SyncClient client = SyncClient(
    db: db,
    transport: transport,
    baseUri: Uri.parse('http://127.0.0.1:17890'),
    token: 'tok-abc',
    clock: now,
  );

  // ============================================================ 镜像契约
  section('客户端镜像的 FK 契约');
  {
    // 镜像是副本：完整性由主机保证，本地 FK 必须关闭 ——
    // 否则 pull 会变成毒丸（某行引用的主数据落在本页之外时永远插不进去）
    final Db strict = Db.openInMemory();
    Object? thrown;
    try {
      SyncClient(
        db: strict,
        transport: FakeTransport(),
        baseUri: Uri.parse('http://127.0.0.1:17890'),
        token: 't',
      );
    } catch (error) {
      thrown = error;
    }
    check('镜像开着外键 → 构造时明确拒绝',
        thrown is StateError &&
            thrown.message.contains('foreignKeys: false'),
        '$thrown');
    strict.close();
  }

  section('落库顺序');
  {
    const List<String> order = SyncClient.applyOrder;
    check('主数据排在明细之前（不照 §8.2 的字段顺序）',
        order.indexOf(Schema.products) < order.indexOf(Schema.documentLines) &&
            order.indexOf(Schema.documents) < order.indexOf(Schema.stockLedger));
    check('覆盖全部 9 个实体，且无多余',
        order.toSet().length == 9 &&
            order.toSet().difference(SyncPullResult.entityNames.toSet()).isEmpty,
        '${order.toSet().difference(SyncPullResult.entityNames.toSet())}');
  }

  // ============================================================ 游标表
  section('SyncCursorDao');
  {
    check('空表 → 空 map（= 从头拉）', client.cursors.getAll().isEmpty);

    client.cursors.upsertAll(<String, String>{
      SyncCursorKeys.stock: '200',
      SyncCursorKeys.doc: '1700000000000|0192abc',
    }, now: now());
    check('upsertAll 写入', client.cursors.getAll().length == 2);
    check('值原样保存（不解析）',
        client.cursors.getAll()[SyncCursorKeys.doc] == '1700000000000|0192abc');

    client.cursors.upsertAll(<String, String>{SyncCursorKeys.stock: '500'},
        now: now());
    check('覆盖不是新增', client.cursors.getAll().length == 2);
    check('覆盖后的值', client.cursors.getAll()[SyncCursorKeys.stock] == '500');

    const String opaque = 'eyJzZXEiOjEyMywiayI6ImFiYyJ9';
    client.cursors
        .upsertAll(<String, String>{SyncCursorKeys.money: opaque}, now: now());
    check('不透明游标（base64 风格）照样存回',
        client.cursors.getAll()[SyncCursorKeys.money] == opaque);

    client.cursors.clear();
    check('clear 清空', client.cursors.getAll().isEmpty);
  }

  // ============================================================ 队列
  section('SyncQueueDao');
  {
    final SyncQueueEntry entry =
        client.queue.enqueue(SyncQueueEntry.create(docOp('d1', 'sale', <int>[3]),
            now: now()));
    final List<SyncQueueEntry> due = client.queue.due(now());
    check('入队 → pending 且立即可送',
        due.length == 1 && due.single.status == SyncQueueStatus.pending);
    check('payload 往返（lines 仍是数组）',
        due.single.toOperation().payload['lines'] is List<Object?>);

    client.queue.markSent(entry.id);
    check('markSent 后不再是到期条目', client.queue.due(now()).isEmpty);
    check('markSent 后仍在表里（sent）',
        client.queue.withStatus(SyncQueueStatus.sent).length == 1);

    client.queue.markFailed(entry.id,
        error: '规则拒绝', retryCount: 1, nextRetryAt: 5000, dead: false);
    final SyncQueueEntry? after = client.queue.findById(entry.id);
    check('markFailed(dead=false) → 仍 pending', after!.status == SyncQueueStatus.pending);
    check('退避时间生效', !after.isDue(4999) && after.isDue(5000));
    check('失败原因已记', after.lastError == '规则拒绝');

    client.queue.markFailed(entry.id,
        error: '重试超限', retryCount: 11, nextRetryAt: 0, dead: true);
    check('markFailed(dead=true) → 死信 failed',
        client.queue.findById(entry.id)!.status == SyncQueueStatus.failed);
    db.close();
  }

  // ============================================================ 拉取
  {
    final Db db2 = Db.openInMemory(foreignKeys: false);
    final FakeTransport t2 = FakeTransport();
    final SyncClient c2 = SyncClient(
      db: db2,
      transport: t2,
      baseUri: Uri.parse('http://127.0.0.1:17890'),
      token: 'tok-abc',
      clock: now,
    );

    section('pull · 请求形状');
    t2.replyJson(pullBody());
    await c2.pull(limit: 100);
    check('方法 GET', t2.last.method == 'GET');
    check('路径 ${SyncClient.pullPath}', t2.last.uri.path == SyncClient.pullPath);
    check('Bearer 头', t2.last.headers['Authorization'] == 'Bearer tok-abc');
    check('limit 参数', t2.last.uri.queryParameters['limit'] == '100');
    check('首次拉取不带 since（缺失即从头拉）',
        !t2.last.uri.queryParameters.containsKey(SyncCursorKeys.stock));

    c2.cursors.upsertAll(<String, String>{
      SyncCursorKeys.stock: '200',
      SyncCursorKeys.doc: '1700000000000|0192abc',
    }, now: now());
    t2.replyJson(pullBody());
    await c2.pull();
    check('已存游标原样进查询串',
        t2.last.uri.queryParameters[SyncCursorKeys.stock] == '200' &&
            t2.last.uri.queryParameters[SyncCursorKeys.doc] ==
                '1700000000000|0192abc');

    section('pull · 落库与 B8');
    const Map<String, String> cursors = <String, String>{
      SyncCursorKeys.stock: '200',
      SyncCursorKeys.money: '88',
      SyncCursorKeys.party: '134',
      SyncCursorKeys.settle: '25',
      SyncCursorKeys.doc: '1700000000100|0192def',
      SyncCursorKeys.products: '1700000000100|0192ghi',
      SyncCursorKeys.parties: '1700000000100|0192jkl',
      SyncCursorKeys.accounts: '1700000000100|0192mno',
    };
    t2.replyJson(pullBody(
      documents: <Map<String, Object?>>[docRow('d1')],
      lines: <Map<String, Object?>>[lineRow('l1', 'd1')],
      products: <Map<String, Object?>>[productRow(_productId)],
      cursors: cursors,
    ));
    final SyncPullReport report = await c2.pull();
    check('落库 3 行', report.totalRows == 3, '${report.totalRows}');
    check('documents 1 行', report.entities[Schema.documents] == 1);
    check('document_lines 1 行', report.entities[Schema.documentLines] == 1);
    check('products 1 行', report.entities[Schema.products] == 1);
    check('B8：sync_cursor 与 next_cursors 逐字段一致',
        _mapEquals(c2.cursors.getAll(), cursors), '${c2.cursors.getAll()}');

    section('pull · 幂等与覆盖');
    final Map<String, Object?> samePage = pullBody(
      documents: <Map<String, Object?>>[docRow('d1')],
      lines: <Map<String, Object?>>[lineRow('l1', 'd1')],
    );
    t2.replyJson(samePage);
    await c2.pull();
    check('重复拉同一页不产生重复行',
        db2.raw.select('SELECT COUNT(*) AS n FROM documents').first['n'] == 1);

    // 本地乐观写入的占位单据 → 被主机版本覆盖（doc_no 回填）
    db2.raw.execute(
      'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
      'occurred_at, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)',
      <Object?>['d9', '~local-1', 'purchase', 'confirmed', 0, 1, 1, 1],
    );
    t2.replyJson(pullBody(
      documents: <Map<String, Object?>>[
        docRow('d9', docNo: 'CG20260926-009'),
      ],
    ));
    await c2.pull();
    final Map<String, Object?> merged = Map<String, Object?>.from(
      db2.raw.select('SELECT * FROM documents WHERE id = ?', <Object?>['d9']).first,
    );
    check('已存在的行被主机版本覆盖', merged['doc_no'] == 'CG20260926-009');
    check('覆盖不产生第二行',
        db2.raw.select('SELECT COUNT(*) AS n FROM documents').first['n'] == 2);

    section('pull · 边界');
    t2.replyJson(
      pullBody(documents: <Map<String, Object?>>[docRow('d1')])
        ..['warehouses'] = <Object?>[
          <String, Object?>{'id': 'w1'},
        ],
    );
    final SyncPullReport unknown = await c2.pull();
    check('未知实体键被忽略（不落库）',
        !unknown.entities.containsKey('warehouses') && unknown.totalRows == 1);

    final int docsBefore = db2.raw
        .select('SELECT COUNT(*) AS n FROM documents')
        .first['n']! as int;
    c2.cursors.clear();
    t2.replyJson(pullBody(
      documents: <Map<String, Object?>>[docRow('d1')],
      products: <Map<String, Object?>>[
        <String, Object?>{'code': 'P-no-id', 'name': '坏行'},
      ],
      cursors: <String, String>{SyncCursorKeys.stock: '1'},
    ));
    Object? thrown;
    try {
      await c2.pull();
    } catch (error) {
      thrown = error;
    }
    check('缺 id 的行 → FormatException', thrown is FormatException, '$thrown');
    check('整批回滚：行没落',
        db2.raw.select('SELECT COUNT(*) AS n FROM documents').first['n'] ==
            docsBefore);
    check('整批回滚：游标没推进', c2.cursors.getAll().isEmpty);

    t2.replyRaw(401, '{"error":"令牌错误"}');
    Object? httpError;
    try {
      await c2.pull();
    } catch (error) {
      httpError = error;
    }
    check('401 → SyncHttpException',
        httpError is SyncHttpException && httpError.isUnauthorized);

    t2.replyJson(<String, Object?>{'documents': <Object?>[]});
    Object? missingCursor;
    try {
      await c2.pull();
    } catch (error) {
      missingCursor = error;
    }
    check('缺 next_cursors → FormatException', missingCursor is FormatException);

    t2.replyJson(<String, Object?>{
      'next_cursors': <String, Object?>{SyncCursorKeys.stock: 200},
    });
    Object? numericCursor;
    try {
      await c2.pull();
    } catch (error) {
      numericCursor = error;
    }
    check('游标不是字符串 → FormatException', numericCursor is FormatException);

    // doc_no 撞车：主机侧唯一，所以这只可能是本地镜像损坏 ——
    // 要求给出**带上下文**的 StateError，而不是裸的 SqliteException
    final int docsBeforeClash = db2.raw
        .select('SELECT COUNT(*) AS n FROM documents')
        .first['n']! as int;
    t2.replyJson(pullBody(documents: <Map<String, Object?>>[docRow('d2')]));
    Object? clash;
    try {
      await c2.pull();
    } catch (error) {
      clash = error;
    }
    check('doc_no 撞车 → 带上下文的 StateError',
        clash is StateError && clash.message.contains('doc_no'), '$clash');
    check('撞车也整批回滚',
        db2.raw.select('SELECT COUNT(*) AS n FROM documents').first['n'] ==
            docsBeforeClash);

    section('pull · 清除已确认的 sent');
    final SyncQueueEntry seen =
        c2.queue.enqueue(SyncQueueEntry.create(docOp('d1', 'sale', <int>[1]), now: now()));
    final SyncQueueEntry notSeen =
        c2.queue.enqueue(SyncQueueEntry.create(docOp('d2', 'sale', <int>[1]), now: now()));
    c2.queue.markSent(seen.id);
    c2.queue.markSent(notSeen.id);
    t2.replyJson(pullBody(documents: <Map<String, Object?>>[docRow('d1')]));
    final SyncPullReport cleared = await c2.pull();
    check('本次见到的 sent 条目被清除', cleared.confirmedQueueEntries == 1);
    check('见到的条目已删', c2.queue.findById(seen.id) == null);
    check('未确认的（分页之外）留着',
        c2.queue.findById(notSeen.id) != null);
    db2.close();
  }

  // ============================================================ 推送
  {
    final Db db3 = Db.openInMemory(foreignKeys: false);
    final FakeTransport t3 = FakeTransport();
    final SyncClient c3 = SyncClient(
      db: db3,
      transport: t3,
      baseUri: Uri.parse('http://127.0.0.1:17890'),
      token: 'tok-abc',
      clock: now,
    );

    section('push · 状态流转');
    final SyncPushReport empty = await c3.push();
    check('队列为空 → 不发请求',
        empty.attempts == 0 && t3.requests.isEmpty);

    final SyncQueueEntry a =
        c3.queue.enqueue(SyncQueueEntry.create(docOp('d-a', 'sale', <int>[3]), now: now()));
    final SyncQueueEntry b =
        c3.queue.enqueue(SyncQueueEntry.create(docOp('d-b', 'sale', <int>[3]), now: now()));
    t3.replyJson(pushBody(<Map<String, Object?>>[
      receipt('d-b', 'applied'),
      receipt('d-a', 'rejected', reason: 'action_not_implemented'),
    ]));
    final SyncPushReport pushed = await c3.push();
    check('回执按 entity_id 配对（顺序打乱不影响）',
        pushed.sent == 1 && pushed.rejected == 1);
    check('applied → 条目转 sent（**不删除**）',
        c3.queue.findById(b.id)!.status == SyncQueueStatus.sent);
    check('rejected → 转 pending 并记原因',
        c3.queue.findById(a.id)!.status == SyncQueueStatus.pending &&
            c3.queue.findById(a.id)!.lastError == 'action_not_implemented');
    check('推送请求是 POST', t3.last.method == 'POST');
    check('请求体含 operations 数组',
        (jsonDecode(t3.last.body!) as Map<String, Object?>)['operations'] is List<Object?>);

    section('push · 结构与边界');
    // a 还在退避中、b 已是 sent ⇒ 没有到期条目 ⇒ 不该再发请求
    final SyncPushReport idle = await c3.push();
    check('没有到期条目 → 不发请求（sent 不会被重复推送）',
        idle.attempts == 0 && t3.requests.length == 1, '${t3.requests.length}');

    final SyncQueueEntry conflictEntry = c3.queue.enqueue(
      SyncQueueEntry.create(
        SyncOperation(
          entity: Schema.products,
          entityId: _productId,
          operation: SyncOpType.updateMasterData,
          baseVersion: 3,
          payload: <String, Object?>{'id': _productId, 'name': '我的名字'},
        ),
        now: now(),
      ),
    );
    t3.replyJson(pushBody(<Map<String, Object?>>[
      <String, Object?>{
        'entity_id': _productId,
        'status': 'conflict',
        'server_state': productRow(_productId),
      },
    ]));
    final SyncPushReport conflicted = await c3.push();
    check('conflict → 覆盖本地 + 删除条目',
        conflicted.conflicts == 1 && c3.queue.findById(conflictEntry.id) == null);
    check('本地被 server_state 覆盖（主机赢）',
        db3.raw
                .select('SELECT name FROM products WHERE id = ?', <Object?>[_productId])
                .first['name'] ==
            '商品');
    db3.close();
  }

  // ============================================================ 退避
  {
    final Db db4 = Db.openInMemory(foreignKeys: false);
    final FakeTransport t4 = FakeTransport();

    section('push · 退避与死信');
    // 固定时钟：退避是「两个时刻之差」，用会推进的时钟算不出确定值
    const int fixed = 1700000000000;
    final SyncClient backoff = SyncClient(
      db: db4,
      transport: t4,
      baseUri: Uri.parse('http://127.0.0.1:17890'),
      token: 'tok-abc',
      clock: () => fixed,
    );
    final SyncQueueEntry entry = backoff.queue.enqueue(
      SyncQueueEntry.create(docOp('d1', 'sale', <int>[1]), now: fixed),
    );
    final List<int> delays = <int>[];
    for (int i = 0; i < 4; i++) {
      t4.replyJson(pushBody(<Map<String, Object?>>[
        receipt('d1', 'rejected', reason: 'x'),
      ]));
      await backoff.push();
      final SyncQueueEntry current = backoff.queue.findById(entry.id)!;
      delays.add(current.nextRetryAt - fixed);
      // 退避归零 —— 模拟「等到期了再试一次」（否则条目不可送，push 不发请求）
      backoff.queue.markFailed(entry.id,
          error: 'x',
          retryCount: current.retryCount,
          nextRetryAt: 0,
          dead: false);
    }
    check('退避序列 1s / 4s / 16s / 64s', delays.join(',') == '1000,4000,16000,64000',
        delays.join(','));

    backoff.queue.markFailed(entry.id,
        error: 'x',
        retryCount: SyncClient.maxRetries + 1,
        nextRetryAt: 0,
        dead: true);
    check('重试超限 → 死信 failed',
        backoff.queue.findById(entry.id)!.status == SyncQueueStatus.failed);
    check('死信**退出自动重试**（due 不含它）',
        backoff.queue.due(fixed).isEmpty &&
            !backoff.queue.findById(entry.id)!.isDue(fixed));
    backoff.queue.requeue(entry.id);
    check('requeue 放回队列（清零重试与错误）',
        backoff.queue.findById(entry.id)!.status == SyncQueueStatus.pending &&
            backoff.queue.findById(entry.id)!.retryCount == 0 &&
            backoff.queue.findById(entry.id)!.lastError == null);

    section('push · 传输层失败与无回执');
    final SyncQueueEntry q = backoff.queue.enqueue(
      SyncQueueEntry.create(docOp('d-q', 'sale', <int>[1]), now: fixed),
    );
    t4.replyThrow(StateError('断网'));
    final SyncPushReport netFail = await backoff.push();
    check('传输异常不抛出、整批退避',
        netFail.attempts >= 1 && netFail.retried == netFail.attempts,
        '${netFail.attempts}/${netFail.retried}');
    check('断网不是业务拒绝（状态仍 pending）',
        backoff.queue.findById(q.id)!.status == SyncQueueStatus.pending);
    check('断网原因已记', backoff.queue.findById(q.id)!.lastError!.contains('断网'));

    final SyncQueueEntry noReceipt = backoff.queue.enqueue(
      SyncQueueEntry.create(docOp('d-nr', 'sale', <int>[1]), now: fixed),
    );
    t4.replyJson(pushBody(<Map<String, Object?>>[]));
    final SyncPushReport missing = await backoff.push();
    check('没有回执 → 该条排重试', missing.retried >= 1);
    check('无回执条目仍 pending',
        backoff.queue.findById(noReceipt.id)!.status == SyncQueueStatus.pending);
    check('无回执的原因写明「主机未返回回执」',
        backoff.queue.findById(noReceipt.id)!.lastError == '主机未返回该条目的回执',
        '${backoff.queue.findById(noReceipt.id)!.lastError}');

    backoff.queue.markFailed(noReceipt.id,
        error: 'x', retryCount: 0, nextRetryAt: 0, dead: false);
    t4.replyRaw(500, 'boom');
    Object? httpError;
    try {
      await backoff.push();
    } catch (error) {
      httpError = error;
    }
    check('非 200 → SyncHttpException（不伪装成业务拒绝）',
        httpError is SyncHttpException);
    check('非 200 也记了 HTTP 状态',
        backoff.queue.findById(noReceipt.id)!.lastError!.contains('HTTP 500'));
    db4.close();
  }

  // ============================================================ delta
  {
    final Db db5 = Db.openInMemory(foreignKeys: false);
    final SyncClient c5 = SyncClient(
      db: db5,
      transport: FakeTransport(),
      baseUri: Uri.parse('http://127.0.0.1:17890'),
      token: 't',
      clock: now,
    );

    section('未同步影响（delta）');
    Map<String, int> delta(String type, List<int> qty) => SyncClient.deltaOf(
      SyncQueueEntry.create(docOp('x', type, qty), now: now()),
    );

    check('purchase → +', _mapEquals(delta('purchase', <int>[10]), <String, int>{'p0': 10}));
    check('sale → −', _mapEquals(delta('sale', <int>[3]), <String, int>{'p0': -3}));
    check('sale_return → +',
        _mapEquals(delta('sale_return', <int>[2]), <String, int>{'p0': 2}));
    check('purchase_return → −',
        _mapEquals(delta('purchase_return', <int>[4]), <String, int>{'p0': -4}));
    check('delivery → −', _mapEquals(delta('delivery', <int>[5]), <String, int>{'p0': -5}));
    check('stocktake → 空（客户端算不出账面数量）', delta('stocktake', <int>[7]).isEmpty);
    check('receipt → 空', delta('receipt', <int>[7]).isEmpty);
    check('payment → 空', delta('payment', <int>[7]).isEmpty);
    check('多行分别累计',
        _mapEquals(delta('sale', <int>[3, 2]), <String, int>{'p0': -3, 'p1': -2}));
    check(
      '主数据操作不影响库存',
      SyncClient.deltaOf(
        SyncQueueEntry.create(
          SyncOperation(
            entity: Schema.products,
            entityId: 'p',
            operation: SyncOpType.createMasterData,
          ),
          now: now(),
        ),
      ).isEmpty,
    );

    final SyncQueueEntry d1 =
        c5.queue.enqueue(SyncQueueEntry.create(docOp('a', 'purchase', <int>[10]), now: now()));
    final SyncQueueEntry d2 =
        c5.queue.enqueue(SyncQueueEntry.create(docOp('b', 'sale', <int>[3]), now: now()));
    final SyncQueueEntry d3 =
        c5.queue.enqueue(SyncQueueEntry.create(docOp('c', 'sale', <int>[2]), now: now()));
    c5.queue.markSent(d2.id);
    c5.queue.markFailed(d3.id,
        error: 'x', retryCount: 11, nextRetryAt: 0, dead: true);
    check('unsyncedDelta 合计 pending + sent + failed',
        _mapEquals(c5.unsyncedDelta(), <String, int>{'p0': 5}),
        '${c5.unsyncedDelta()}');
    check('a 仍是 pending / c 已死信',
        c5.queue.findById(d1.id)!.status == SyncQueueStatus.pending &&
            c5.queue.findById(d3.id)!.status == SyncQueueStatus.failed);

    section('库存视图（权威 + 未同步）');
    // 权威镜像：stock_ledger +10
    db5.raw.execute(
      'INSERT INTO products (id, code, name, created_at, updated_at) VALUES (?,?,?,?,?)',
      <Object?>[_productId, 'P001', '商品', 1, 1],
    );
    db5.raw.execute(
      'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
      'occurred_at, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)',
      <Object?>['doc', 'X1', 'purchase', 'confirmed', 1000, 1, 1, 1],
    );
    db5.raw.execute(
      'INSERT INTO stock_ledger (id, product_id, document_id, quantity, unit_cost, '
      'total_cost, seq_no, occurred_at, created_at) VALUES (?,?,?,?,?,?,?,?,?)',
      <Object?>['s1', _productId, 'doc', 10, 100, 1000, 1, 1, 1],
    );
    // 再加一张未同步的销售单（-3）
    c5.queue.enqueue(
      SyncQueueEntry.create(
        SyncOperation(
          entity: Schema.documents,
          entityId: 'sale-1',
          operation: SyncOpType.createDocument,
          payload: <String, Object?>{
            'document': <String, Object?>{'id': 'sale-1', 'doc_type': 'sale'},
            'lines': <Object?>[
              <String, Object?>{
                'product_id': _productId,
                'quantity': 3,
                'unit_price': 100,
                'amount': 300,
              },
            ],
          },
        ),
        now: now(),
      ),
    );

    final StockView view = c5.stockViewOf(_productId);
    check('权威库存 = 10', view.authoritative == 10, '${view.authoritative}');
    check('未同步影响 = -3', view.unsynced == -3, '${view.unsynced}');
    check('显示库存 = 7（刚卖掉的立刻可见）', view.display == 7, '${view.display}');
    check('有未同步影响标记', view.hasUnsynced);
    check('贡献者指向那张单', view.contributors.length == 1 &&
        view.contributors.single.entityId == 'sale-1');

    section('时钟偏移');
    // 固定时钟：偏移是「两个时刻之差」，用会推进的时钟算不出确定值
    const int fixedClock = 1700000000000;
    final SyncClient clocked = SyncClient(
      db: db5,
      transport: FakeTransport(),
      baseUri: Uri.parse('http://127.0.0.1:17890'),
      token: 't',
      clock: () => fixedClock,
    );
    check('默认 offset = 0', clocked.clockOffset.offsetMs == 0);
    check('未配对时估算主机时刻 = 本地时刻',
        clocked.estimatedServerTime() == fixedClock);
    final int offset = clocked.recordClockOffset(fixedClock + 3600000);
    check('记录 server − client', offset == 3600000, '$offset');
    check('估算主机时刻 = 本地 + offset',
        clocked.estimatedServerTime() == fixedClock + 3600000);
    clocked.recordClockOffset(fixedClock + 2000);
    check('重复记录会覆盖', clocked.clockOffset.offsetMs == 2000);
    db5.close();
  }

  stdout.writeln('\n${'=' * 46}');
  if (_failures.isEmpty) {
    stdout.writeln('全部通过：$_passed 项');
    exit(0);
  }
  stdout.writeln('通过 $_passed 项，失败 ${_failures.length} 项：');
  for (final String failure in _failures) {
    stdout.writeln('  - $failure');
  }
  exit(1);
}

bool _mapEquals(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final String key in a.keys) {
    if (!b.containsKey(key) || b[key] != a[key]) return false;
  }
  return true;
}
