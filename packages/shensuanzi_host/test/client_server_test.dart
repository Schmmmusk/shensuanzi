// 端到端：**一台主机 + 两台客户端**，全程走真实 HTTP。
//
// 为什么放在 host 包：它需要 `SyncServer`（host）与 `SyncClient`（core）**同场**，
// 而依赖方向是 host → core。core 侧的自检只能用假的 Transport，
// 无法覆盖「游标跨 push/pull 两个路径」这类只有真主机才能暴露的行为。
//
// 核心守卫：**R-14 的陷阱 1** —— 客户端 push 之后游标**不得**被自己的
// push 推进，否则会**静默跳过**其它设备在中间写入的数据。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；需要可用的 SQLite 原生库。
import 'dart:convert';
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// 真 HTTP 传输：`dart:io HttpClient`（测试本地的参考实现；
/// 应用层的绑定由 Windows / Android 侧自己写，见 `transport.dart` 的边界说明）。
class HttpTransport implements Transport {
  final HttpClient _client = HttpClient();

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final HttpClientRequest outgoing = await _client.openUrl(
      request.method,
      request.uri,
    );
    request.headers.forEach(outgoing.headers.set);
    // ⚠️ 必须**显式 utf8 编码**：`HttpClientRequest.write` 的默认编码
    // 不是 UTF-8，商品名里的中文会在 `write` 处直接抛
    // `Invalid argument: Contains invalid characters`。
    if (request.body != null) outgoing.add(utf8.encode(request.body!));
    final HttpClientResponse response = await outgoing.close();
    return TransportResponse(
      statusCode: response.statusCode,
      body: await response.transform(utf8.decoder).join(),
    );
  }

  void close() => _client.close(force: true);
}

/// `documents` 的 wire 行：只保留白名单列（与主机同一份白名单）
Map<String, Object?> documentWire(Document doc) => <String, Object?>{
  for (final MapEntry<String, Object?> entry in doc.toRow().entries)
    if (SyncWhitelist.isAllowedColumn(Schema.documents, entry.key))
      entry.key: entry.value,
};

/// 一条 `createDocument` 操作（采购入库）
SyncOperation purchaseOp({
  required String docId,
  required String productId,
  required String partyId,
  int quantity = 1,
  int unitPrice = 100,
  required int occurredAt,
}) => SyncOperation(
  entity: Schema.documents,
  entityId: docId,
  operation: SyncOpType.createDocument,
  payload: <String, Object?>{
    'document': documentWire(
      Document(
        id: docId,
        docNo: '${Document.pendingDocNoPrefix}$docId',
        docType: DocType.purchase,
        status: DocStatus.confirmed,
        partyId: partyId,
        totalAmount: quantity * unitPrice,
        occurredAt: occurredAt,
        createdAt: occurredAt,
        updatedAt: occurredAt,
      ),
    ),
    'lines': <Object?>[
      DocumentLine.create(
        documentId: docId,
        productId: productId,
        quantity: quantity,
        unitPrice: unitPrice,
      ).toRow(),
    ],
  },
);

SyncOperation masterOp(String table, String id, Map<String, Object?> payload) =>
    SyncOperation(
      entity: table,
      entityId: id,
      operation: SyncOpType.createMasterData,
      payload: <String, Object?>{'id': id, ...payload},
    );

void main() {
  setUpAll(useLocalSqlite);

  const PortRange testPorts = PortRange(start: 17960, end: 17974);
  const int hostNow = 1700000000000;

  late Db hostDb;
  late HostIdentity identity;
  late HostHttpServer server;
  late HttpTransport transport;
  late Db mirrorA;
  late Db mirrorB;
  late SyncClient clientA;
  late SyncClient clientB;
  late String token;
  late String productId;
  late String partyId;

  setUp(() async {
    resetClock();
    hostDb = newMemoryDb();
    identity = HostIdentityStore.inMemory().loadOrCreate(now: hostNow);
    token = identity.plaintextToken!;
    server = await HostHttpServer.start(
      db: hostDb,
      identity: identity,
      ports: testPorts,
      address: InternetAddress.loopbackIPv4,
      clock: () => hostNow,
    );
    transport = HttpTransport();
    mirrorA = newMemoryDb(foreignKeys: false);
    mirrorB = newMemoryDb(foreignKeys: false);
    clientA = SyncClient(
      db: mirrorA,
      transport: transport,
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      token: token,
      clock: now,
    );
    clientB = SyncClient(
      db: mirrorB,
      transport: transport,
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      token: token,
      clock: now,
    );

    // 主数据也走真实推送路径
    productId = newId();
    partyId = newId();
    clientA.queue.enqueue(
      SyncQueueEntry.create(
        masterOp(Schema.products, productId, <String, Object?>{
          'code': 'P001',
          'name': '商品甲',
        }),
        now: now(),
      ),
    );
    clientA.queue.enqueue(
      SyncQueueEntry.create(
        masterOp(Schema.parties, partyId, <String, Object?>{'name': '供应商甲'}),
        now: now(),
      ),
    );
    final SyncPushReport boot = await clientA.push();
    expect(boot.sent, 2, reason: boot.errors.join(' | '));
  });

  tearDown(() async {
    transport.close();
    await server.close(force: true);
    hostDb.close();
    mirrorA.close();
    mirrorB.close();
  });

  int mirroredDocuments(Db mirror) =>
      mirror.raw.select('SELECT COUNT(*) AS n FROM documents').first['n']! as int;

  Set<String> mirroredDocumentIds(Db mirror) => mirror.raw
      .select('SELECT id FROM documents')
      .map((row) => row['id']! as String)
      .toSet();

  // ============================================================ 陷阱 1

  test('陷阱 1 回归守卫：先 push 后 pull **不得跳过**中间那段流水', () async {
    // ① A 先拉一次 —— 游标停在「什么都没有」
    await clientA.pull();
    expect(clientA.cursors.getAll()[SyncCursorKeys.stock] ?? '0', '0');

    // ② 另一台设备 B 在 A 不知情的情况下写了 5 张单
    final List<String> bDocIds = <String>[];
    for (int i = 0; i < 5; i++) {
      final String id = newId();
      bDocIds.add(id);
      clientB.queue.enqueue(
        SyncQueueEntry.create(
          purchaseOp(
            docId: id,
            productId: productId,
            partyId: partyId,
            occurredAt: hostNow,
          ),
          now: now(),
        ),
      );
    }
    final SyncPushReport bPush = await clientB.push();
    expect(bPush.sent, 5, reason: bPush.errors.join(' | '));

    // ③ A 离线开单并推送成功 —— 主机分配的 seq_no 在 B 那 5 张**之后**
    final String aDocId = newId();
    clientA.queue.enqueue(
      SyncQueueEntry.create(
        purchaseOp(
          docId: aDocId,
          productId: productId,
          partyId: partyId,
          quantity: 7,
          occurredAt: hostNow,
        ),
        now: now(),
      ),
    );
    final SyncPushReport aPush = await clientA.push();
    expect(aPush.sent, 1, reason: aPush.errors.join(' | '));

    // ④ **关键断言**：自己的 push 不推进拉取游标
    expect(
      clientA.cursors.getAll()[SyncCursorKeys.stock] ?? '0',
      '0',
      reason: '游标是「服务器已交付到哪里」，push 的回程不经过 pull',
    );

    // ⑤ A 再拉 —— 必须把 B 那 5 张也拉回来
    final SyncPullReport pull = await clientA.pull();

    expect(
      pull.entities[Schema.stockLedger],
      6,
      reason: 'B 的 5 张 + A 自己的 1 张；B 的 5 张若被跳过就是静默丢数据',
    );
    expect(mirroredDocumentIds(mirrorA), containsAll(<String>[...bDocIds, aDocId]));
    expect(mirroredDocuments(mirrorA), 6);

    // 库存 = 5 × 1 + 7 = 12
    final QueryDao queries = QueryDao(mirrorA);
    expect(queries.stockByProduct()[productId], 12);
  });

  test('陷阱 2：客户端时钟快 1 小时，也不得跳过服务器数据', () async {
    // A 的时钟比主机快 1 小时
    final SyncClient skewed = SyncClient(
      db: mirrorA,
      transport: transport,
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      token: token,
      clock: () => hostNow + 3600000,
    );

    // B 先在主机上写一张（主机 created_at = hostNow，落在 A 的本地时间之前）
    final String bDocId = newId();
    clientB.queue.enqueue(
      SyncQueueEntry.create(
        purchaseOp(
          docId: bDocId,
          productId: productId,
          partyId: partyId,
          occurredAt: hostNow,
        ),
        now: now(),
      ),
    );
    await clientB.push();

    // A（时钟快 1h）拉取
    final SyncPullReport pull = await skewed.pull();

    expect(
      pull.entities[Schema.documents],
      1,
      reason: '游标来自主机，与本地时钟无关',
    );
    expect(mirroredDocumentIds(mirrorA), contains(bDocId));
  });

  // ============================================================ 跨设备可见

  test('A 推的单，B 拉得到（含主机的正式单号）', () async {
    final String docId = newId();
    clientA.queue.enqueue(
      SyncQueueEntry.create(
        purchaseOp(
          docId: docId,
          productId: productId,
          partyId: partyId,
          quantity: 3,
          occurredAt: hostNow,
        ),
        now: now(),
      ),
    );
    final SyncPushReport push = await clientA.push();
    expect(push.sent, 1, reason: push.errors.join(' | '));

    await clientB.pull();

    final Map<String, Object?> row = Map<String, Object?>.from(
      mirrorB.raw
          .select('SELECT * FROM documents WHERE id = ?', <Object?>[docId])
          .first,
    );
    expect(row['doc_no'], isNot(startsWith(Document.pendingDocNoPrefix)),
        reason: '拉回来的是主机分配的正式单号');
    expect(mirroredDocuments(mirrorB), 1);
    expect(QueryDao(mirrorB).stockByProduct()[productId], 3);
  });

  test('重复 pull 幂等（主机与镜像都不产生重复行）', () async {
    final String docId = newId();
    clientA.queue.enqueue(
      SyncQueueEntry.create(
        purchaseOp(
          docId: docId,
          productId: productId,
          partyId: partyId,
          occurredAt: hostNow,
        ),
        now: now(),
      ),
    );
    await clientA.push();

    await clientB.pull();
    await clientB.pull();

    expect(mirroredDocuments(mirrorB), 1);
    expect(
      mirrorB.raw.select('SELECT COUNT(*) AS n FROM document_lines').first['n'],
      1,
    );
    expect(
      mirrorB.raw.select('SELECT COUNT(*) AS n FROM stock_ledger').first['n'],
      1,
    );
  });

  test('pull 后清除已确认的 sent 条目 → 未同步影响归零', () async {
    final String docId = newId();
    clientA.queue.enqueue(
      SyncQueueEntry.create(
        purchaseOp(
          docId: docId,
          productId: productId,
          partyId: partyId,
          quantity: 3,
          occurredAt: hostNow,
        ),
        now: now(),
      ),
    );
    await clientA.push();

    // push 之后：条目不删，转为 sent —— 「我卖了 3 件」立刻可见
    expect(
      clientA.queue
          .withStatus(SyncQueueStatus.sent)
          .any((SyncQueueEntry entry) => entry.entityId == docId),
      isTrue,
      reason: '主数据引导那两条也在 sent 里，所以按 entityId 找自己那条',
    );
    expect(clientA.stockViewOf(productId).display, 3);
    expect(clientA.stockViewOf(productId).authoritative, 0);
    expect(clientA.stockViewOf(productId).unsynced, 3);

    // pull 确认后：条目清除，权威镜像到位
    await clientA.pull();

    expect(clientA.queue.all(), isEmpty);
    expect(clientA.stockViewOf(productId).display, 3);
    expect(clientA.stockViewOf(productId).authoritative, 3);
    expect(clientA.stockViewOf(productId).unsynced, 0);
  });

  // ============================================================ 冲突

  test('两台同时改同一商品 → 后到者收到 conflict 且本地被覆盖', () async {
    // A、B 各自拉一次，拿到同一个 base_version = 0
    await clientA.pull();
    await clientB.pull();

    SyncOperation rename(String name) => SyncOperation(
      entity: Schema.products,
      entityId: productId,
      operation: SyncOpType.updateMasterData,
      baseVersion: 0,
      payload: <String, Object?>{'id': productId, 'name': name},
    );

    clientA.queue.enqueue(SyncQueueEntry.create(rename('甲改的名字'), now: now()));
    final SyncPushReport first = await clientA.push();
    expect(first.sent, 1);

    clientB.queue.enqueue(SyncQueueEntry.create(rename('乙改的名字'), now: now()));
    final SyncPushReport second = await clientB.push();

    expect(second.conflicts, 1, reason: 'B 的 base_version 已过期');
    expect(clientB.queue.all(), isEmpty, reason: '冲突已解决 → 条目删除');

    final Map<String, Object?> local = Map<String, Object?>.from(
      mirrorB.raw
          .select('SELECT name FROM products WHERE id = ?', <Object?>[productId])
          .first,
    );
    expect(local['name'], '甲改的名字', reason: '主机赢 —— 本地被 server_state 覆盖');
  });

  // ============================================================ 主数据入队（D1）

  test('D1：手机上用**已被占用**的编码建档 ⇒ 主机改派，pull 后镜像收敛（同 id、不重复行）', () async {
    // setUp 里 A 已经用 P001 建了「商品甲」。B 没拉过 ⇒ 自己的镜像里是空的，
    // 离线生成也落在 P001 上（§CH 提案 A §3：客户端按镜像 max(code)+1 生成）。
    final String bProductId = newId();
    clientB.queue.enqueue(
      SyncQueueEntry.create(
        masterOp(Schema.products, bProductId, <String, Object?>{
          'code': 'P001',
          'name': '商品乙',
        }),
        now: now(),
      ),
    );
    final SyncPushReport push = await clientB.push();
    expect(push.sent, 1, reason: push.errors.join(' | '));
    expect(push.rejected, 0, reason: '改派对客户端不是错误');

    // 主机侧：两个商品都在，编码不重复（主机改派了 B 那条）
    final Map<String, Object?> hostRow = Map<String, Object?>.from(
      hostDb.raw
          .select('SELECT code FROM products WHERE id = ?', <Object?>[bProductId])
          .first,
    );
    expect(hostRow['code'], isNot('P001'), reason: 'P001 已被商品甲占用 ⇒ 改派');
    expect(
      hostDb.raw.select('SELECT COUNT(*) AS n FROM products').first['n'],
      2,
      reason: '改派不是拒绝 —— 两条都要落库',
    );
    expect(
      hostDb.raw
          .select("SELECT code FROM products WHERE name = '商品甲'")
          .first['code'],
      'P001',
      reason: '原占用者不受影响',
    );

    // B pull ⇒ 镜像同 id 收敛到主机的真码，且**只有一行**（乐观行不残留）
    await clientB.pull();
    final List<Map<String, Object?>> mirrorRows = mirrorB.raw
        .select(
          'SELECT id, code FROM products WHERE id = ?',
          <Object?>[bProductId],
        )
        .map((r) => <String, Object?>{'id': r['id'], 'code': r['code']})
        .toList();
    expect(mirrorRows, hasLength(1), reason: '乐观行与 pull 行同 id ⇒ UPSERT 覆盖，不新增');
    expect(
      mirrorRows.single['code'],
      hostRow['code'],
      reason: '镜像收敛到主机改派后的编码',
    );
  });

  // ============================================================ v1 边界

  test('documentAction：purchase 收 mark_delivered → rejected（规则不允许），进重试', () async {
    final String docId = newId();
    clientA.queue.enqueue(
      SyncQueueEntry.create(
        purchaseOp(
          docId: docId,
          productId: productId,
          partyId: partyId,
          occurredAt: hostNow,
        ),
        now: now(),
      ),
    );
    await clientA.push();
    await clientA.pull();

    final SyncQueueEntry action = clientA.queue.enqueue(
      SyncQueueEntry.create(
        SyncOperation(
          entity: Schema.documents,
          entityId: docId,
          operation: SyncOpType.documentAction,
          // R-3（2026-09-29 裁定）后的 payload 契约：只有 action 与 occurred_at
          payload: <String, Object?>{
            'action': 'mark_delivered',
            'occurred_at': hostNow,
          },
        ),
        now: now(),
      ),
    );

    final SyncPushReport report = await clientA.push();

    expect(report.rejected, 1, reason: 'purchase 不适用「签收」—— 规则不允许');
    final SyncQueueEntry after = clientA.queue.findById(action.id)!;
    expect(after.status, SyncQueueStatus.pending, reason: 'rejected 排重试（§六 处置不变）');
    // #22 裁定（2026-10-09）：协议违反（非送货单不能签收）的回执只给通用中文
    // ⇒ 队列里存的也是它；细节（`purchase 不适用签收`）只在**主机日志**里。
    // 镜像 `tool/selfcheck_client_server.dart` 的同名断言。
    expect(after.lastError, malformedSyncRequestReason);
    expect(after.retryCount, 1);
  });

  test('令牌错误 → SyncHttpException(401)，不写队列', () async {
    final SyncClient wrong = SyncClient(
      db: mirrorA,
      transport: transport,
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'not-the-token',
      clock: now,
    );

    await expectLater(
      wrong.pull(),
      throwsA(
        isA<SyncHttpException>().having(
          (SyncHttpException e) => e.isUnauthorized,
          'isUnauthorized',
          isTrue,
        ),
      ),
    );
  });
}
