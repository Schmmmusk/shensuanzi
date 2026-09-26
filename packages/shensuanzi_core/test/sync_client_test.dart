// 客户端同步引擎（`docs/sync_protocol.md` + R-14 裁定）。
//
// 覆盖：游标原样保存（B8）、pull 的事务原子性、push 的状态流转与退避、
// 未同步影响（delta）—— 全部**不依赖真实网络**（假的 Transport）。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；需要可用的 SQLite 原生库，见 `lib/sqlite_local.dart`。
import 'dart:convert';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// 可编程的假传输层：记录请求，按脚本返回响应。
class FakeTransport implements Transport {
  final List<TransportRequest> requests = <TransportRequest>[];
  final List<Object> _script = <Object>[];

  /// 入队一个 JSON 响应（200）
  void replyJson(Map<String, Object?> body) =>
      _script.add(TransportResponse(statusCode: 200, body: jsonEncode(body)));

  void replyRaw(int statusCode, String body) =>
      _script.add(TransportResponse(statusCode: statusCode, body: body));

  /// 入队一个「传输层异常」（模拟断网）
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

/// 一条 §8.2 形状的拉取响应（只给需要的实体）
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
        {int createdAt = 1700000000000, String docNo = 'CG20260926-001'}) =>
    <String, Object?>{
      'id': id,
      'doc_no': docNo,
      'doc_type': 'purchase',
      'status': 'confirmed',
      'party_id': null,
      'account_id': null,
      'total_amount': 1000,
      'paid_amount': 0,
      'ref_doc_id': null,
      'occurred_at': createdAt,
      'time_estimated': 0,
      'created_at': createdAt,
      'updated_at': createdAt,
      'remark': null,
    };

Map<String, Object?> lineRow(String id, String documentId, String product) =>
    <String, Object?>{
      'id': id,
      'document_id': documentId,
      'product_id': product,
      'quantity': 10,
      'unit_price': 100,
      'amount': 1000,
      'remark': null,
    };

Map<String, Object?> stockRow(
  String id,
  String product,
  String document, {
  int seqNo = 1,
}) => <String, Object?>{
  'id': id,
  'product_id': product,
  'document_id': document,
  'quantity': 10,
  'unit_cost': 100,
  'total_cost': 1000,
  'seq_no': seqNo,
  'occurred_at': 1700000000000,
  'time_estimated': 0,
  'created_at': 1700000000000,
};

Map<String, Object?> productRow(String id, {int updatedAt = 1700000000000}) =>
    <String, Object?>{
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
      'created_at': updatedAt,
      'updated_at': updatedAt,
      'sync_version': 0,
    };

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late FakeTransport transport;
  late SyncClient client;

  setUp(() {
    resetClock();
    // 客户端镜像是**副本**：完整性由主机保证，本地 FK 关闭（见 SyncClient 构造函数）
    db = newMemoryDb(foreignKeys: false);
    transport = FakeTransport();
    client = SyncClient(
      db: db,
      transport: transport,
      baseUri: Uri.parse('http://127.0.0.1:17890'),
      token: 'tok-abc',
      clock: now,
    );
  });

  tearDown(() => db.close());

  test('镜像开着外键 → 构造时明确拒绝（否则 pull 会变成毒丸）', () {
    final Db strict = newMemoryDb();

    expect(
      () => SyncClient(
        db: strict,
        transport: FakeTransport(),
        baseUri: Uri.parse('http://127.0.0.1:17890'),
        token: 't',
      ),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('foreignKeys: false'),
        ),
      ),
    );
    strict.close();
  });

  // ============================================================ 游标表
  group('SyncCursorDao', () {
    test('空表 → 空 map（= 从头拉，不需要「已初始化」标志）', () {
      expect(client.cursors.getAll(), isEmpty);
    });

    test('upsertAll 写入并可覆盖，值原样保存', () {
      client.cursors.upsertAll(<String, String>{
        SyncCursorKeys.stock: '200',
        SyncCursorKeys.doc: '1700000000000|0192abc',
      }, now: now());

      expect(client.cursors.getAll(), <String, String>{
        SyncCursorKeys.stock: '200',
        SyncCursorKeys.doc: '1700000000000|0192abc',
      });

      client.cursors.upsertAll(<String, String>{
        SyncCursorKeys.stock: '500',
      }, now: now());

      expect(client.cursors.getAll()[SyncCursorKeys.stock], '500');
      expect(client.cursors.getAll().length, 2, reason: '覆盖不是新增');
    });

    test('游标是**不透明**的：换成主机不认识的编码也照样存与回传', () {
      const String opaque = 'eyJzZXEiOjEyMywiayI6ImFiYyJ9';
      client.cursors.upsertAll(<String, String>{SyncCursorKeys.stock: opaque}, now: now());

      expect(client.cursors.getAll()[SyncCursorKeys.stock], opaque);
    });

    test('clear 清空', () {
      client.cursors.upsertAll(<String, String>{SyncCursorKeys.stock: '1'}, now: now());
      client.cursors.clear();
      expect(client.cursors.getAll(), isEmpty);
    });
  });

  // ============================================================ 队列
  group('SyncQueueDao', () {
    SyncOperation purchaseOp(String id) => SyncOperation(
      entity: Schema.documents,
      entityId: id,
      operation: SyncOpType.createDocument,
      payload: <String, Object?>{
        'document': <String, Object?>{'id': id, 'doc_type': 'purchase'},
        'lines': <Object?>[
          <String, Object?>{
            'product_id': productId,
            'quantity': 10,
            'unit_price': 100,
            'amount': 1000,
          },
        ],
      },
    );

    test('入队 → pending、立即可送', () {
      client.queue.enqueue(SyncQueueEntry.create(purchaseOp('d1'), now: now()));

      final List<SyncQueueEntry> due = client.queue.due(now());
      expect(due, hasLength(1));
      expect(due.single.status, SyncQueueStatus.pending);
      expect(due.single.retryCount, 0);
      expect(due.single.toOperation().entityId, 'd1');
      expect(due.single.toOperation().payload['lines'], isA<List<Object?>>());
    });

    test('markSent 后不再是「到期」条目（但仍在表里）', () {
      final SyncQueueEntry entry =
          client.queue.enqueue(SyncQueueEntry.create(purchaseOp('d1'), now: now()));

      client.queue.markSent(entry.id);

      expect(client.queue.due(now()), isEmpty);
      expect(client.queue.withStatus(SyncQueueStatus.sent), hasLength(1));
    });

    test('markFailed：dead=false → 仍 pending 但退避；dead=true → 死信', () {
      final SyncQueueEntry entry =
          client.queue.enqueue(SyncQueueEntry.create(purchaseOp('d1'), now: now()));

      client.queue.markFailed(
        entry.id,
        error: '规则拒绝',
        retryCount: 1,
        nextRetryAt: 5000,
        dead: false,
      );
      SyncQueueEntry? current = client.queue.findById(entry.id);
      expect(current!.status, SyncQueueStatus.pending);
      expect(current.retryCount, 1);
      expect(current.lastError, '规则拒绝');
      expect(current.isDue(4999), isFalse);
      expect(current.isDue(5000), isTrue);

      client.queue.markFailed(
        entry.id,
        error: '重试超限',
        retryCount: 11,
        nextRetryAt: 0,
        dead: true,
      );
      current = client.queue.findById(entry.id);
      expect(current!.status, SyncQueueStatus.failed);
    });

    test('clearConfirmed：只清 sent 且 id 命中的条目', () {
      final SyncQueueEntry a =
          client.queue.enqueue(SyncQueueEntry.create(purchaseOp('d-a'), now: now()));
      final SyncQueueEntry b =
          client.queue.enqueue(SyncQueueEntry.create(purchaseOp('d-b'), now: now()));
      final SyncQueueEntry c =
          client.queue.enqueue(SyncQueueEntry.create(purchaseOp('d-c'), now: now()));
      client.queue.markSent(a.id);
      client.queue.markSent(b.id);
      client.queue.markSent(c.id);

      // 只确认了 d-a
      final int removed = client.queue.clearConfirmed(<String>{'d-a'});

      expect(removed, 1);
      expect(client.queue.findById(a.id), isNull);
      expect(client.queue.findById(b.id), isNotNull, reason: '没确认的必须留着');
      expect(client.queue.findById(c.id), isNotNull);
    });

    test('clearConfirmed：pending 的条目即使 id 命中也不清（它还没推送成功）', () {
      final SyncQueueEntry entry =
          client.queue.enqueue(SyncQueueEntry.create(purchaseOp('d-x'), now: now()));

      expect(client.queue.clearConfirmed(<String>{'d-x'}), 0);
      expect(client.queue.findById(entry.id), isNotNull);
    });
  });

  // ============================================================ 拉取
  group('pull', () {
    test('请求形状：GET /api/sync/pull + Bearer + limit；无游标时不带 since 参数', () async {
      transport.replyJson(pullBody());

      await client.pull(limit: 100);

      expect(transport.last.method, 'GET');
      expect(transport.last.uri.path, SyncClient.pullPath);
      expect(transport.last.headers['Authorization'], 'Bearer tok-abc');
      expect(transport.last.uri.queryParameters['limit'], '100');
      expect(
        transport.last.uri.queryParameters.containsKey(SyncCursorKeys.stock),
        isFalse,
        reason: '首次拉取没有游标 —— 缺失即从头拉',
      );
    });

    test('已存游标时带进查询串（原样回传，不解析）', () async {
      client.cursors.upsertAll(<String, String>{
        SyncCursorKeys.stock: '200',
        SyncCursorKeys.doc: '1700000000000|0192abc',
      }, now: now());
      transport.replyJson(pullBody());

      await client.pull();

      expect(transport.last.uri.queryParameters[SyncCursorKeys.stock], '200');
      expect(
        transport.last.uri.queryParameters[SyncCursorKeys.doc],
        '1700000000000|0192abc',
      );
    });

    test('落库 9 个实体中的行，并保存游标', () async {
      transport.replyJson(
        pullBody(
          documents: <Map<String, Object?>>[docRow('d1')],
          lines: <Map<String, Object?>>[lineRow('l1', 'd1', productId)],
          stock: <Map<String, Object?>>[stockRow('s1', productId, 'd1')],
          products: <Map<String, Object?>>[productRow(productId)],
          cursors: <String, String>{
            SyncCursorKeys.stock: '1',
            SyncCursorKeys.doc: '1700000000000|d1',
            SyncCursorKeys.products: '1700000000000|p1',
          },
        ),
      );

      final SyncPullReport report = await client.pull();

      expect(report.totalRows, 4);
      expect(report.entities[Schema.documents], 1);
      expect(report.entities[Schema.documentLines], 1);
      expect(report.entities[Schema.stockLedger], 1);
      expect(report.entities[Schema.products], 1);
      expect(report.entities[Schema.accounts], 0);

      expect(client.cursors.getAll(), <String, String>{
        SyncCursorKeys.stock: '1',
        SyncCursorKeys.doc: '1700000000000|d1',
        SyncCursorKeys.products: '1700000000000|p1',
      });
    });

    test('落库按依赖顺序（主数据先），不是 §8.2 的字段顺序', () {
      // 断言的是**顺序常量本身**：§8.2 把主数据列在最后，而 applyOrder 把它提前。
      // 若有人「顺手」把 applyOrder 改回 entityNames，这条会失败。
      expect(
        SyncClient.applyOrder.indexOf(Schema.products),
        lessThan(SyncClient.applyOrder.indexOf(Schema.documentLines)),
      );
      expect(
        SyncClient.applyOrder.indexOf(Schema.documents),
        lessThan(SyncClient.applyOrder.indexOf(Schema.stockLedger)),
      );
      expect(SyncClient.applyOrder.toSet(), SyncPullResult.entityNames.toSet());
    });

    test('B8：pull 后 sync_cursor 与 next_cursors 逐字段一致', () async {
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
      transport.replyJson(pullBody(cursors: cursors));

      final SyncPullReport report = await client.pull();

      expect(report.nextCursors, cursors);
      expect(client.cursors.getAll(), cursors, reason: '不变量 B8');
    });

    test('重复拉同一页 → 幂等（不产生重复行）', () async {
      final Map<String, Object?> body = pullBody(
        documents: <Map<String, Object?>>[docRow('d1')],
        lines: <Map<String, Object?>>[lineRow('l1', 'd1', productId)],
        products: <Map<String, Object?>>[productRow(productId)],
      );
      transport.replyJson(body);
      transport.replyJson(body);

      await client.pull();
      await client.pull();

      expect(
        db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n'],
        1,
      );
      expect(
        db.raw.select('SELECT COUNT(*) AS n FROM document_lines').first['n'],
        1,
      );
    });

    test('已存在的行被主机版本覆盖（含 doc_no 回填）', () async {
      // 本地乐观写入的占位单据
      db.raw.execute(
        'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
        'occurred_at, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)',
        <Object?>['d1', '~local-1', 'purchase', 'confirmed', 0, 1, 1, 1],
      );

      transport.replyJson(
        pullBody(documents: <Map<String, Object?>>[docRow('d1')]),
      );
      await client.pull();

      final Map<String, Object?> row = Map<String, Object?>.from(
        db.raw.select('SELECT * FROM documents WHERE id = ?', <Object?>['d1']).first,
      );
      expect(row['doc_no'], 'CG20260926-001', reason: '主机分配的正式单号回填');
      expect(row['total_amount'], 1000);
      expect(
        db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n'],
        1,
      );
    });

    test('未知实体键被忽略（主机新增实体不会让旧客户端崩，也不落库）', () async {
      final Map<String, Object?> body = pullBody(
        documents: <Map<String, Object?>>[docRow('d1')],
      )..['warehouses'] = <Object?>[
        <String, Object?>{'id': 'w1', 'name': '仓库'},
      ];
      transport.replyJson(body);

      final SyncPullReport report = await client.pull();

      expect(report.totalRows, 1, reason: '只落白名单内的实体');
      expect(report.entities.containsKey('warehouses'), isFalse);
      expect(
        db.raw
            .select("SELECT COUNT(*) AS n FROM sqlite_master WHERE name = 'warehouses'")
            .first['n'],
        0,
      );
    });

    test('非法行（缺 id）→ 整批回滚：行与游标都不落库', () async {
      transport.replyJson(
        pullBody(
          documents: <Map<String, Object?>>[docRow('d1')],
          products: <Map<String, Object?>>[
            <String, Object?>{'code': 'P-no-id', 'name': '坏行'},
          ],
          cursors: <String, String>{SyncCursorKeys.stock: '1'},
        ),
      );

      await expectLater(client.pull(), throwsA(isA<FormatException>()));

      expect(
        db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n'],
        0,
        reason: '同事务回滚 —— 不能出现「行落了一半、游标已推进」',
      );
      expect(client.cursors.getAll(), isEmpty);
    });

    test('清理已确认的 sent 条目；本页没见到的留着', () async {
      final SyncQueueEntry seen = client.queue.enqueue(
        SyncQueueEntry.create(
          SyncOperation(
            entity: Schema.documents,
            entityId: 'd1',
            operation: SyncOpType.createDocument,
          ),
          now: now(),
        ),
      );
      final SyncQueueEntry notSeen = client.queue.enqueue(
        SyncQueueEntry.create(
          SyncOperation(
            entity: Schema.documents,
            entityId: 'd2',
            operation: SyncOpType.createDocument,
          ),
          now: now(),
        ),
      );
      client.queue.markSent(seen.id);
      client.queue.markSent(notSeen.id);

      transport.replyJson(
        pullBody(documents: <Map<String, Object?>>[docRow('d1')]),
      );
      final SyncPullReport report = await client.pull();

      expect(report.confirmedQueueEntries, 1);
      expect(client.queue.findById(seen.id), isNull);
      expect(
        client.queue.findById(notSeen.id),
        isNotNull,
        reason: '分页之外的单据还没确认 —— 一刀切会提前归零未同步影响',
      );
    });

    test('非 200 → SyncHttpException（401 可识别为需要重新配对）', () async {
      transport.replyRaw(401, '{"error":"令牌错误"}');

      await expectLater(
        client.pull(),
        throwsA(
          isA<SyncHttpException>()
              .having((SyncHttpException e) => e.statusCode, 'statusCode', 401)
              .having((SyncHttpException e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );
    });

    test('响应缺 next_cursors → FormatException', () async {
      transport.replyJson(<String, Object?>{'documents': <Object?>[]});

      await expectLater(client.pull(), throwsA(isA<FormatException>()));
    });

    test('游标值不是字符串 → FormatException（不静默接受数字）', () async {
      transport.replyJson(<String, Object?>{
        'next_cursors': <String, Object?>{SyncCursorKeys.stock: 200},
      });

      await expectLater(client.pull(), throwsA(isA<FormatException>()));
    });

    test('doc_no 撞车 → 明确的 StateError（不是裸的 SqliteException），并整批回滚', () async {
      transport.replyJson(pullBody(documents: <Map<String, Object?>>[docRow('d1')]));
      await client.pull();

      // 主机侧 doc_no 唯一，所以「另一张单用了同一个 doc_no」只可能是本地镜像损坏
      transport.replyJson(pullBody(documents: <Map<String, Object?>>[docRow('d2')]));

      await expectLater(
        client.pull(),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('doc_no'),
          ),
        ),
      );
      expect(
        db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n'],
        1,
        reason: '整批回滚 —— 不能留下半页',
      );
    });
  });

  // ============================================================ 推送
  group('push', () {
    SyncQueueEntry enqueueDoc(String id) => client.queue.enqueue(
      SyncQueueEntry.create(
        SyncOperation(
          entity: Schema.documents,
          entityId: id,
          operation: SyncOpType.createDocument,
          payload: <String, Object?>{
            'document': <String, Object?>{'id': id, 'doc_type': 'sale'},
            'lines': <Object?>[
              <String, Object?>{
                'product_id': productId,
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

    Map<String, Object?> pushBody(List<Map<String, Object?>> results) =>
        <String, Object?>{'results': results};

    Map<String, Object?> receipt(String entityId, String status, {String? reason}) =>
        <String, Object?>{
          'entity_id': entityId,
          'status': status,
          if (reason != null) 'reason': reason,
        };

    test('队列为空 → 不发请求', () async {
      final SyncPushReport report = await client.push();

      expect(report.attempts, 0);
      expect(transport.requests, isEmpty);
    });

    test('applied → 条目转 sent（**不删除**，等 pull 确认）', () async {
      final SyncQueueEntry entry = enqueueDoc('d1');
      transport.replyJson(pushBody(<Map<String, Object?>>[receipt('d1', 'applied')]));

      final SyncPushReport report = await client.push();

      expect(report.sent, 1);
      expect(report.attempts, 1);
      final SyncQueueEntry? after = client.queue.findById(entry.id);
      expect(after, isNotNull);
      expect(after!.status, SyncQueueStatus.sent);
    });

    test('请求体形状：operations 数组 + payload 原样', () async {
      enqueueDoc('d1');
      transport.replyJson(pushBody(<Map<String, Object?>>[receipt('d1', 'applied')]));

      await client.push();

      expect(transport.last.method, 'POST');
      final Map<String, Object?> body =
          jsonDecode(transport.last.body!) as Map<String, Object?>;
      final List<Object?> ops = body['operations']! as List<Object?>;
      expect(ops, hasLength(1));
      final Map<String, Object?> op = Map<String, Object?>.from(ops.single! as Map);
      expect(op['entity'], Schema.documents);
      expect(op['entity_id'], 'd1');
      expect(op['operation'], 'createDocument');
      expect((op['payload']! as Map)['lines'], isA<List<Object?>>());
    });

    test('回执按 entity_id 配对，**顺序打乱也不影响**', () async {
      final SyncQueueEntry a = enqueueDoc('d-a');
      final SyncQueueEntry b = enqueueDoc('d-b');
      transport.replyJson(
        pushBody(<Map<String, Object?>>[
          receipt('d-b', 'applied'),
          receipt('d-a', 'rejected', reason: '规则拒绝'),
        ]),
      );

      final SyncPushReport report = await client.push();

      expect(report.sent, 1);
      expect(report.rejected, 1);
      expect(client.queue.findById(b.id)!.status, SyncQueueStatus.sent);
      expect(client.queue.findById(a.id)!.status, SyncQueueStatus.pending);
      expect(client.queue.findById(a.id)!.lastError, '规则拒绝');
    });

    test('rejected → 重试计数 +1、退避 1s、记原因（含 v1 的 action_not_implemented）',
        () async {
      final SyncQueueEntry entry = enqueueDoc('d1');
      final int t = now();
      transport.replyJson(
        pushBody(<Map<String, Object?>>[
          receipt('d1', 'rejected', reason: 'action_not_implemented'),
        ]),
      );

      await client.push();

      final SyncQueueEntry after = client.queue.findById(entry.id)!;
      expect(after.retryCount, 1);
      expect(after.lastError, 'action_not_implemented');
      expect(after.nextRetryAt, t + 1000, reason: '首次退避 1s');
      expect(after.isDue(after.nextRetryAt - 1), isFalse);
    });

    test('退避序列 1s / 4s / 16s / 64s', () async {
      // 用**固定时钟**的客户端：否则每次 `now()` 都会推进，
      // 差值里会混进「调用次数」而不是纯粹的退避长度。
      const int fixed = 1700000000000;
      final SyncClient c = SyncClient(
        db: db,
        transport: transport,
        baseUri: Uri.parse('http://127.0.0.1:17890'),
        token: 't',
        clock: () => fixed,
      );
      final SyncQueueEntry entry = enqueueDoc('d1');
      final List<int> delays = <int>[];

      for (int i = 0; i < 4; i++) {
        transport.replyJson(
          pushBody(<Map<String, Object?>>[receipt('d1', 'rejected', reason: 'x')]),
        );
        await c.push();
        final SyncQueueEntry current = c.queue.findById(entry.id)!;
        delays.add(current.nextRetryAt - fixed);
        // 把退避时间归零 —— 模拟「等到期了再试一次」（否则条目不可送，push 不发请求）
        c.queue.markFailed(
          entry.id,
          error: current.lastError!,
          retryCount: current.retryCount,
          nextRetryAt: 0,
          dead: false,
        );
      }

      expect(delays, <int>[1000, 4000, 16000, 64000]);
    });

    test('重试超限（>10）→ 死信，且**退出自动重试**（等人工处理）', () async {
      final SyncQueueEntry entry = enqueueDoc('d1');

      for (int i = 0; i <= SyncClient.maxRetries; i++) {
        transport.replyJson(
          pushBody(<Map<String, Object?>>[receipt('d1', 'rejected', reason: 'x')]),
        );
        await client.push();
        final SyncQueueEntry current = client.queue.findById(entry.id)!;
        client.queue.markFailed(
          entry.id,
          error: current.lastError!,
          retryCount: current.retryCount,
          nextRetryAt: 0,
          dead: current.retryCount > SyncClient.maxRetries,
        );
      }

      final SyncQueueEntry after = client.queue.findById(entry.id)!;
      expect(after.retryCount, SyncClient.maxRetries + 1);
      expect(after.status, SyncQueueStatus.failed);
      expect(after.isDue(now()), isFalse);
      expect(client.queue.due(now()), isEmpty, reason: '死信不再自动重试');

      // 人工处理之后放回队列
      client.queue.requeue(entry.id);
      final SyncQueueEntry requeued = client.queue.findById(entry.id)!;
      expect(requeued.status, SyncQueueStatus.pending);
      expect(requeued.retryCount, 0);
      expect(requeued.lastError, isNull);
      expect(requeued.isDue(now()), isTrue);
    });

    test('conflict → 用 server_state 覆盖本地并删除条目', () async {
      final SyncQueueEntry entry = client.queue.enqueue(
        SyncQueueEntry.create(
          SyncOperation(
            entity: Schema.products,
            entityId: productId,
            operation: SyncOpType.updateMasterData,
            baseVersion: 3,
            payload: <String, Object?>{'id': productId, 'name': '我的名字'},
          ),
          now: now(),
        ),
      );
      transport.replyJson(pushBody(<Map<String, Object?>>[
        <String, Object?>{
          'entity_id': productId,
          'status': 'conflict',
          'server_state': productRow(productId),
        },
      ]));

      final SyncPushReport report = await client.push();

      expect(report.conflicts, 1);
      expect(client.queue.findById(entry.id), isNull, reason: '冲突已解决 → 条目删除');
      final Map<String, Object?> row = Map<String, Object?>.from(
        db.raw.select('SELECT * FROM products WHERE id = ?', <Object?>[productId]).first,
      );
      expect(row['name'], '商品', reason: '本地被主机状态覆盖（主机赢）');
    });

    test('某条没有回执 → 该条排重试，其它条不受影响', () async {
      final SyncQueueEntry a = enqueueDoc('d-a');
      final SyncQueueEntry b = enqueueDoc('d-b');
      transport.replyJson(pushBody(<Map<String, Object?>>[receipt('d-a', 'applied')]));

      final SyncPushReport report = await client.push();

      expect(report.sent, 1);
      expect(report.retried, 1);
      expect(client.queue.findById(a.id)!.status, SyncQueueStatus.sent);
      expect(client.queue.findById(b.id)!.status, SyncQueueStatus.pending);
      expect(client.queue.findById(b.id)!.lastError, contains('无回执'));
    });

    test('传输层异常 → 整批退避、状态仍 pending、**不抛异常**', () async {
      final SyncQueueEntry entry = enqueueDoc('d1');
      transport.replyThrow(StateError('断网'));

      final SyncPushReport report = await client.push();

      expect(report.attempts, 1);
      expect(report.retried, 1);
      final SyncQueueEntry after = client.queue.findById(entry.id)!;
      expect(after.status, SyncQueueStatus.pending, reason: '断网不是业务拒绝');
      expect(after.retryCount, 1);
      expect(after.lastError, contains('断网'));
    });

    test('非 200 → 整批退避并抛出 SyncHttpException（不伪装成业务拒绝）', () async {
      final SyncQueueEntry entry = enqueueDoc('d1');
      transport.replyRaw(500, 'boom');

      await expectLater(client.push(), throwsA(isA<SyncHttpException>()));
      final SyncQueueEntry after = client.queue.findById(entry.id)!;
      expect(after.status, SyncQueueStatus.pending);
      expect(after.lastError, contains('HTTP 500'));
    });

    test('已 sent 的条目不会被再次推送', () async {
      final SyncQueueEntry entry = enqueueDoc('d1');
      client.queue.markSent(entry.id);
      transport.replyJson(pushBody(<Map<String, Object?>>[receipt('d1', 'applied')]));

      final SyncPushReport report = await client.push();

      expect(report.attempts, 0);
      expect(transport.requests, isEmpty);
    });
  });

  // ============================================================ 未同步影响
  group('未同步影响（delta）', () {
    SyncQueueEntry queueDoc(String id, String docType, List<int> quantities) =>
        client.queue.enqueue(
          SyncQueueEntry.create(
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
            ),
            now: now(),
          ),
        );

    test('符号：进货 / 销售退货为正，销售 / 送货 / 采购退货为负', () {
      expect(SyncClient.deltaOf(queueDoc('a', 'purchase', <int>[10])), <String, int>{'p0': 10});
      expect(SyncClient.deltaOf(queueDoc('b', 'sale', <int>[3])), <String, int>{'p0': -3});
      expect(
        SyncClient.deltaOf(queueDoc('c', 'sale_return', <int>[2])),
        <String, int>{'p0': 2},
      );
      expect(
        SyncClient.deltaOf(queueDoc('d', 'purchase_return', <int>[4])),
        <String, int>{'p0': -4},
      );
      expect(SyncClient.deltaOf(queueDoc('e', 'delivery', <int>[5])), <String, int>{'p0': -5});
    });

    test('盘点与资金单据贡献 0（客户端算不出盘点影响，也不该估算资金）', () {
      expect(SyncClient.deltaOf(queueDoc('a', 'stocktake', <int>[7])), isEmpty);
      expect(SyncClient.deltaOf(queueDoc('b', 'receipt', <int>[7])), isEmpty);
      expect(SyncClient.deltaOf(queueDoc('c', 'payment', <int>[7])), isEmpty);
    });

    test('多行分别累计', () {
      expect(
        SyncClient.deltaOf(queueDoc('a', 'sale', <int>[3, 2])),
        <String, int>{'p0': -3, 'p1': -2},
      );
    });

    test('主数据操作不影响库存', () {
      final SyncQueueEntry entry = client.queue.enqueue(
        SyncQueueEntry.create(
          SyncOperation(
            entity: Schema.products,
            entityId: productId,
            operation: SyncOpType.createMasterData,
            payload: <String, Object?>{'id': productId, 'name': 'x'},
          ),
          now: now(),
        ),
      );
      expect(SyncClient.deltaOf(entry), isEmpty);
    });

    test('unsyncedDelta 合计 pending + sent + failed', () {
      final SyncQueueEntry a = queueDoc('a', 'purchase', <int>[10]); // +10
      final SyncQueueEntry b = queueDoc('b', 'sale', <int>[3]); // -3
      final SyncQueueEntry c = queueDoc('c', 'sale', <int>[2]); // -2
      client.queue.markSent(b.id);
      client.queue.markFailed(c.id,
          error: 'x', retryCount: 11, nextRetryAt: 0, dead: true);
      // a 仍 pending

      expect(client.unsyncedDelta(), <String, int>{'p0': 5});
      expect(a.status, SyncQueueStatus.pending);
      expect(client.queue.findById(c.id)!.status, SyncQueueStatus.failed);
    });

    test('stockViewOf：权威 + 未同步，并给出贡献者', () {
      // 权威镜像：stock_ledger 有 +10
      seedMinimal(db);
      insertStock(db.raw, 's1', quantity: 10, totalCost: 1000);
      final SyncQueueEntry sale = queueDoc('a', 'sale', <int>[3]);

      final StockView view = client.stockViewOf(productId);

      expect(view.authoritative, 10);
      expect(view.unsynced, -3);
      expect(view.display, 7, reason: '用户卖掉的 3 件立刻可见');
      expect(view.hasUnsynced, isTrue);
      expect(view.contributors.map((SyncQueueEntry e) => e.entityId), <String>['a']);
      expect(sale.entityId, 'a');
    });
  });

  // ============================================================ 时钟
  group('时钟偏移', () {
    // 固定时钟：偏移是「两个时刻之差」，用会推进的时钟算不出确定值
    const int fixed = 1700000000000;
    SyncClient fixedClockClient() => SyncClient(
      db: db,
      transport: transport,
      baseUri: Uri.parse('http://127.0.0.1:17890'),
      token: 't',
      clock: () => fixed,
    );

    test('默认 0（尚未配对）', () {
      expect(fixedClockClient().clockOffset.offsetMs, 0);
      expect(fixedClockClient().estimatedServerTime(), fixed);
    });

    test('recordClockOffset 记录 server − client，并可用于估算主机时刻', () {
      final SyncClient c = fixedClockClient();
      final int offset = c.recordClockOffset(fixed + 3600000);

      expect(offset, 3600000);
      expect(c.clockOffset.offsetMs, 3600000);
      expect(c.estimatedServerTime(), fixed + 3600000);
    });

    test('重复记录会覆盖（每次握手更新）', () {
      final SyncClient c = fixedClockClient();
      c.recordClockOffset(fixed + 1000);
      c.recordClockOffset(fixed + 2000);
      expect(c.clockOffset.offsetMs, 2000);
    });
  });
}
