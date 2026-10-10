// host 自检：`dart run tool/selfcheck_client_server.dart`
//
// 端到端：**一台主机 + 两台客户端**，全程走真实 HTTP（`dart:io HttpClient`）。
// 与 `test/client_server_test.dart` 断言等价 —— 本机 `dart test` 无法编译测试文件
// （见 `docs/testing.md` §零）。
//
// 核心守卫：**R-14 的陷阱 1** —— 客户端 push 之后游标**不得**被自己的 push 推进。
//
// ⚠️ **每段用独立的 World**（主机 + 两个镜像 + 主数据），与测试文件的 `setUp` 隔离一致。
// 第一版是「一个 World 跑到底」，于是断言全被前一段的残留数据带偏 ——
// 自检脚本自己也会踩「夹具没隔离」这个坑。
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**，失败可复现。

import 'dart:convert';
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

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

/// 真 HTTP 传输（测试本地的参考实现）
class HttpTransport implements Transport {
  final HttpClient _client = HttpClient();

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final HttpClientRequest outgoing = await _client.openUrl(
      request.method,
      request.uri,
    );
    request.headers.forEach(outgoing.headers.set);
    // ⚠️ 必须**显式 utf8 编码**：`HttpClientRequest.write` 的默认编码不是 UTF-8，
    // 商品名里的中文会在 write 处直接抛
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

int _clock = 1700000000000;
int now() => _clock++;
void resetClock() => _clock = 1700000000000;

const int _hostNow = 1700000000000;
const PortRange _testPorts = PortRange(start: 17960, end: 17974);

Map<String, Object?> documentWire(Document doc) => <String, Object?>{
  for (final MapEntry<String, Object?> entry in doc.toRow().entries)
    if (SyncWhitelist.isAllowedColumn(Schema.documents, entry.key))
      entry.key: entry.value,
};

SyncOperation purchaseOp({
  required String docId,
  required String productId,
  required String partyId,
  int quantity = 1,
  int unitPrice = 100,
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
        occurredAt: _hostNow,
        createdAt: _hostNow,
        updatedAt: _hostNow,
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

int mirroredDocuments(Db mirror) =>
    mirror.raw.select('SELECT COUNT(*) AS n FROM documents').first['n']! as int;

Set<String> mirroredDocumentIds(Db mirror) => mirror.raw
    .select('SELECT id FROM documents')
    .map((row) => row['id']! as String)
    .toSet();

/// 一段自检的完整环境：**每次新建**，段末销毁。
class World {
  World._(
    this.hostDb,
    this.server,
    this.transport,
    this.mirrorA,
    this.mirrorB,
    this.clientA,
    this.clientB,
    this.token,
    this.productId,
    this.partyId,
  );

  final Db hostDb;
  final HostHttpServer server;
  final HttpTransport transport;
  final Db mirrorA;
  final Db mirrorB;
  final SyncClient clientA;
  final SyncClient clientB;
  final String token;
  final String productId;
  final String partyId;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${server.port}');

  static Future<World> start() async {
    resetClock();
    final Db hostDb = Db.openInMemory();
    final HostIdentity identity =
        HostIdentityStore.inMemory().loadOrCreate(now: _hostNow);
    final String token = identity.plaintextToken!;
    final HostHttpServer server = await HostHttpServer.start(
      db: hostDb,
      identity: identity,
      ports: _testPorts,
      address: InternetAddress.loopbackIPv4,
      clock: () => _hostNow,
    );
    final HttpTransport transport = HttpTransport();
    final Uri baseUri = Uri.parse('http://127.0.0.1:${server.port}');
    final Db mirrorA = Db.openInMemory(foreignKeys: false);
    final Db mirrorB = Db.openInMemory(foreignKeys: false);
    final SyncClient clientA = SyncClient(
      db: mirrorA,
      transport: transport,
      baseUri: baseUri,
      token: token,
      clock: now,
    );
    final SyncClient clientB = SyncClient(
      db: mirrorB,
      transport: transport,
      baseUri: baseUri,
      token: token,
      clock: now,
    );
    final String productId = newId();
    final String partyId = newId();
    clientA.queue.enqueue(
      SyncQueueEntry.create(
        masterOp(Schema.products, productId,
            <String, Object?>{'code': 'P001', 'name': '商品甲'}),
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
    if (boot.sent != 2) {
      throw StateError('夹具失败：主数据引导 → ${boot.lastError} ${boot.errors}');
    }
    return World._(hostDb, server, transport, mirrorA, mirrorB, clientA,
        clientB, token, productId, partyId);
  }

  Future<void> dispose() async {
    transport.close();
    await server.close(force: true);
    hostDb.close();
    mirrorA.close();
    mirrorB.close();
  }
}

Future<void> main() async {
  useLocalSqlite();

  // ============================================================ 陷阱 1
  section('陷阱 1 回归守卫：先 push 后 pull 不得跳过中间那段');
  {
    final World w = await World.start();

    // ① A 先拉一次，游标停在「什么都没有」
    await w.clientA.pull();
    check('拉取后 stock 游标为 0',
        (w.clientA.cursors.getAll()[SyncCursorKeys.stock] ?? '0') == '0');

    // ② 另一台设备 B 在 A 不知情时写了 5 张单
    final List<String> bDocIds = <String>[];
    for (int i = 0; i < 5; i++) {
      final String id = newId();
      bDocIds.add(id);
      w.clientB.queue.enqueue(
        SyncQueueEntry.create(
          purchaseOp(docId: id, productId: w.productId, partyId: w.partyId),
          now: now(),
        ),
      );
    }
    final SyncPushReport bPush = await w.clientB.push();
    check('B 推了 5 张', bPush.sent == 5, '${bPush.lastError} ${bPush.errors}');

    // ③ A 离线开单并推送成功（主机分配的 seq_no 在 B 那 5 张之后）
    final String aDocId = newId();
    w.clientA.queue.enqueue(
      SyncQueueEntry.create(
        purchaseOp(
          docId: aDocId,
          productId: w.productId,
          partyId: w.partyId,
          quantity: 7,
        ),
        now: now(),
      ),
    );
    final SyncPushReport aPush = await w.clientA.push();
    check('A 推了自己的 1 张', aPush.sent == 1, '${aPush.lastError} ${aPush.errors}');

    // ④ 关键：自己的 push 不推进拉取游标
    check('**push 不推进拉取游标**',
        (w.clientA.cursors.getAll()[SyncCursorKeys.stock] ?? '0') == '0',
        '${w.clientA.cursors.getAll()}');

    // ⑤ A 再拉 —— 必须把 B 那 5 张也拉回来
    final SyncPullReport pull = await w.clientA.pull();
    check('拉到 6 条 stock_ledger（B 的 5 + A 的 1）',
        pull.entities[Schema.stockLedger] == 6,
        '${pull.entities[Schema.stockLedger]}');
    check('B 的 5 张都在本地镜像里',
        mirroredDocumentIds(w.mirrorA).containsAll(<String>[...bDocIds, aDocId]));
    check('镜像共 6 张单', mirroredDocuments(w.mirrorA) == 6);
    check('库存 = 12（5×1 + 7）',
        QueryDao(w.mirrorA).stockByProduct()[w.productId] == 12,
        '${QueryDao(w.mirrorA).stockByProduct()}');
    await w.dispose();
  }

  // ============================================================ 陷阱 2
  section('陷阱 2：客户端时钟快 1 小时也不得跳过服务器数据');
  {
    final World w = await World.start();

    final String bDocId = newId();
    w.clientB.queue.enqueue(
      SyncQueueEntry.create(
        purchaseOp(docId: bDocId, productId: w.productId, partyId: w.partyId),
        now: now(),
      ),
    );
    await w.clientB.push();

    // A 的时钟比主机快 1 小时
    final Db skewedMirror = Db.openInMemory(foreignKeys: false);
    final SyncClient skewed = SyncClient(
      db: skewedMirror,
      transport: w.transport,
      baseUri: w.baseUri,
      token: w.token,
      clock: () => _hostNow + 3600000,
    );

    final SyncPullReport pull = await skewed.pull();
    check('时钟快 1h 的客户端照样拉到 1 张',
        pull.entities[Schema.documents] == 1, '${pull.entities[Schema.documents]}');
    check('且就是 B 那张', mirroredDocumentIds(skewedMirror).contains(bDocId));
    skewedMirror.close();
    await w.dispose();
  }

  // ============================================================ 跨设备
  section('跨设备可见与幂等');
  {
    final World w = await World.start();

    final String docId = newId();
    w.clientA.queue.enqueue(
      SyncQueueEntry.create(
        purchaseOp(
          docId: docId,
          productId: w.productId,
          partyId: w.partyId,
          quantity: 3,
        ),
        now: now(),
      ),
    );
    final SyncPushReport push = await w.clientA.push();
    check('A 推送成功', push.sent == 1, '${push.lastError} ${push.errors}');

    await w.clientB.pull();
    final Map<String, Object?> row = Map<String, Object?>.from(
      w.mirrorB.raw
          .select('SELECT * FROM documents WHERE id = ?', <Object?>[docId]).first,
    );
    check('B 拿到主机分配的正式单号',
        !(row['doc_no']! as String).startsWith(Document.pendingDocNoPrefix),
        '${row['doc_no']}');
    check('B 的镜像里有这张单', mirroredDocuments(w.mirrorB) == 1);
    check('B 的库存 = 3', QueryDao(w.mirrorB).stockByProduct()[w.productId] == 3);

    await w.clientB.pull();
    check('重复 pull 不产生重复单据', mirroredDocuments(w.mirrorB) == 1);
    check(
        '重复 pull 不产生重复明细',
        w.mirrorB.raw
                .select('SELECT COUNT(*) AS n FROM document_lines')
                .first['n'] ==
            1);
    check(
        '重复 pull 不产生重复流水',
        w.mirrorB.raw
                .select('SELECT COUNT(*) AS n FROM stock_ledger')
                .first['n'] ==
            1);
    await w.dispose();
  }

  section('未同步影响：push 后可见，pull 后归零');
  {
    final World w = await World.start();

    final String docId = newId();
    w.clientA.queue.enqueue(
      SyncQueueEntry.create(
        purchaseOp(
          docId: docId,
          productId: w.productId,
          partyId: w.partyId,
          quantity: 3,
        ),
        now: now(),
      ),
    );
    await w.clientA.push();

    check('push 后条目不删、转为 sent',
        w.clientA.queue.withStatus(SyncQueueStatus.sent).any(
            (SyncQueueEntry e) => e.entityId == docId),
        '${w.clientA.queue.withStatus(SyncQueueStatus.sent).map((SyncQueueEntry e) => e.entityId)}');
    final StockView before = w.clientA.stockViewOf(w.productId);
    check('显示库存立刻包含刚卖的 3 件',
        before.display == 3 && before.unsynced == 3 && before.authoritative == 0,
        'display=${before.display} authoritative=${before.authoritative}');
    check('贡献者指向那张单',
        before.contributors.length == 1 &&
            before.contributors.single.entityId == docId);

    await w.clientA.pull();
    final StockView after = w.clientA.stockViewOf(w.productId);
    check('pull 确认后队列条目被清除',
        w.clientA.queue.withStatus(SyncQueueStatus.sent).isEmpty);
    check('权威镜像到位、未同步归零',
        after.authoritative == 3 && after.unsynced == 0 && !after.hasUnsynced,
        'authoritative=${after.authoritative} unsynced=${after.unsynced}');
    await w.dispose();
  }

  // ============================================================ 冲突
  section('乐观锁冲突（主机赢）');
  {
    final World w = await World.start();
    await w.clientA.pull();
    await w.clientB.pull();

    SyncOperation rename(String name) => SyncOperation(
      entity: Schema.products,
      entityId: w.productId,
      operation: SyncOpType.updateMasterData,
      baseVersion: 0,
      payload: <String, Object?>{'id': w.productId, 'name': name},
    );

    w.clientA.queue.enqueue(SyncQueueEntry.create(rename('甲改的名字'), now: now()));
    final SyncPushReport first = await w.clientA.push();
    check('A 基于 version 0 更新成功', first.sent == 1, first.errors.join(' | '));

    w.clientB.queue.enqueue(SyncQueueEntry.create(rename('乙改的名字'), now: now()));
    final SyncPushReport second = await w.clientB.push();
    check('B 的 base_version 过期 → conflict', second.conflicts == 1);
    check('冲突条目已删除', w.clientB.queue.all().isEmpty);
    final Map<String, Object?> local = Map<String, Object?>.from(
      w.mirrorB.raw
          .select('SELECT name FROM products WHERE id = ?', <Object?>[w.productId])
          .first,
    );
    check('本地被 server_state 覆盖（主机赢）', local['name'] == '甲改的名字',
        '${local['name']}');
    await w.dispose();
  }

  // ============================================================ 主数据入队（D1）
  section('D1：手机用已被占用的编码建档 ⇒ 主机改派 + pull 收敛');
  {
    final World w = await World.start();
    // World.start() 里 A 已用 P001 建了「商品甲」；B 没拉过 ⇒ 镜像为空，
    // 离线生成也落在 P001 上（§CH 提案 A §3）。
    final String bProductId = newId();
    w.clientB.queue.enqueue(
      SyncQueueEntry.create(
        masterOp(Schema.products, bProductId,
            <String, Object?>{'code': 'P001', 'name': '商品乙'}),
        now: now(),
      ),
    );
    final SyncPushReport push = await w.clientB.push();
    check('B 推成功（改派对客户端不是错误）',
        push.sent == 1 && push.rejected == 0, push.errors.join(' | '));

    final Map<String, Object?> hostRow = Map<String, Object?>.from(
      w.hostDb.raw
          .select('SELECT code FROM products WHERE id = ?', <Object?>[bProductId])
          .first,
    );
    check('主机改派了 B 的编码（≠ P001）', hostRow['code'] != 'P001',
        '${hostRow['code']}');
    check(
        '两条都落库（改派不是拒绝）',
        (w.hostDb.raw.select('SELECT COUNT(*) AS n FROM products').first['n']
                as int) ==
            2);
    check(
        '原占用者（商品甲）仍是 P001',
        w.hostDb.raw
                .select("SELECT code FROM products WHERE name = '商品甲'")
                .first['code'] ==
            'P001');

    await w.clientB.pull();
    final List<Map<String, Object?>> mirrorRows = w.mirrorB.raw
        .select('SELECT id, code FROM products WHERE id = ?', <Object?>[bProductId])
        .map((r) => <String, Object?>{'id': r['id'], 'code': r['code']})
        .toList();
    check('镜像只有一行（乐观行与 pull 行同 id ⇒ UPSERT 覆盖）',
        mirrorRows.length == 1, '${mirrorRows.length}');
    check('镜像收敛到主机改派后的编码',
        mirrorRows.single['code'] == hostRow['code'],
        '${mirrorRows.single['code']} vs ${hostRow['code']}');
    await w.dispose();
  }

  // ============================================================ v1 边界
  section('v1 边界：documentAction 与鉴权');
  {
    final World w = await World.start();

    final String docId = newId();
    w.clientA.queue.enqueue(
      SyncQueueEntry.create(
        purchaseOp(docId: docId, productId: w.productId, partyId: w.partyId),
        now: now(),
      ),
    );
    await w.clientA.push();
    await w.clientA.pull();

    final SyncQueueEntry action = w.clientA.queue.enqueue(
      SyncQueueEntry.create(
        SyncOperation(
          entity: Schema.documents,
          entityId: docId,
          operation: SyncOpType.documentAction,
          // R-3（2026-09-29 裁定）后的 payload 契约：只有 action 与 occurred_at
          payload: <String, Object?>{
            'action': 'mark_delivered',
            'occurred_at': _hostNow,
          },
        ),
        now: now(),
      ),
    );
    final SyncPushReport report = await w.clientA.push();
    check('documentAction（purchase 收签收）→ rejected', report.rejected == 1);
    final SyncQueueEntry after = w.clientA.queue.findById(action.id)!;
    check('rejected → 进重试而非死信',
        after.status == SyncQueueStatus.pending && after.retryCount == 1);
    // #22 裁定：协议违反（非送货单不能签收）的回执给通用中文 ⇒ 队列里存的
    // 也是它；细节（`purchase 不适用签收`）只在**主机日志**里。
    check('失败原因 = 协议违反的通用文案',
        after.lastError == malformedSyncRequestReason, '${after.lastError}');

    final SyncClient wrong = SyncClient(
      db: w.mirrorA,
      transport: w.transport,
      baseUri: w.baseUri,
      token: 'not-the-token',
      clock: now,
    );
    Object? thrown;
    try {
      await wrong.pull();
    } catch (error) {
      thrown = error;
    }
    check('错令牌 → SyncHttpException(401)',
        thrown is SyncHttpException && thrown.isUnauthorized,
        '$thrown');
    await w.dispose();
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
