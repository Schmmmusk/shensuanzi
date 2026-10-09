// host 自检：`dart run tool/selfcheck_host.dart`
//
// 覆盖令牌 / 主机身份 / 配对载荷 / 二维码数据 / shelf HTTP 层。
// 与 `test/{auth,pairing,http_server}_test.dart` 断言等价 ——
// 本机 `dart test` 无法编译测试文件（见 `docs/testing.md` §零）。
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**，失败可复现。

import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

bool throws(void Function() body) {
  try {
    body();
    return false;
  } catch (_) {
    return true;
  }
}

const int _fixedNow = 1700000000000;
const PortRange _testPorts = PortRange(start: 17985, end: 17999);

/// 注入给主机的时钟。**可变** —— 需要「时间前进」的用例自己调 [tick]。
///
/// 为什么不能一直是常量：主数据的拉取游标是 `(updated_at, id)`，
/// 而 `updated_at` 取自主机时钟。时钟不动 ⇒ 两次改动落在同一毫秒 ⇒
/// `(stamp, id) >` 的谓词认不出后一次改动（见 R-14）。
int _clock = _fixedNow;

/// 让主机时钟前进 1ms（模拟「稍后」发生的一次写）
int tick() => ++_clock;

Future<void> main() async {
  useLocalSqlite();

  // ============================================================ 令牌
  section('HostToken');
  {
    final String a = HostToken.generate(random: Random(42));
    final String b = HostToken.generate(random: Random(42));
    check('注入种子可复现', a == b, a);
    check('不同种子不同结果', a != HostToken.generate(random: Random(43)));
    check('真实随机两次不同', HostToken.generate() != HostToken.generate());
    check('明文是 32 字节的 Base64', base64Url.decode(a).length == 32);

    check('hashOf 稳定', HostToken.hashOf('t') == HostToken.hashOf('t'));
    check('hashOf 是 64 位十六进制', HostToken.hashOf('t').length == 64);
    check('hashOf 区分内容', HostToken.hashOf('t') != HostToken.hashOf('u'));

    final String hash = HostToken.hashOf('secret');
    check('matches 正确令牌', HostToken.matches('secret', hash));
    check('matches 错误令牌', !HostToken.matches('secrez', hash));
    check('matches 空串', !HostToken.matches('', hash));
    check('matches null', !HostToken.matches(null, hash));

    check('constantTimeEquals 相等', HostToken.constantTimeEquals('abc', 'abc'));
    check('constantTimeEquals 等长不等', !HostToken.constantTimeEquals('abc', 'abd'));
    check('constantTimeEquals 不等长', !HostToken.constantTimeEquals('abc', 'ab'));
  }

  // ============================================================ 主机身份
  section('HostIdentityStore');
  {
    final HostIdentityStore store = HostIdentityStore.inMemory();
    final HostIdentity first = store.loadOrCreate(now: _fixedNow);

    check('首次生成 host_id', first.hostId.isNotEmpty);
    check('首次带明文（可画二维码）', first.canShowQr);
    check('明文能通过校验', first.authorizes(first.plaintextToken));

    final HostIdentity loaded = store.loadOrCreate(now: _fixedNow + 1);
    check('再次读取 host_id 不变', loaded.hostId == first.hostId);
    check('再次读取哈希不变', loaded.tokenHash == first.tokenHash);
    check('再次读取**没有明文**（哈希不可逆）', !loaded.canShowQr);
    check('重启后仍能校验旧令牌（只需哈希）',
        loaded.authorizes(first.plaintextToken));

    final HostIdentity after = store.reset(now: _fixedNow + 2);
    check('reset 换 host_id', after.hostId != first.hostId);
    check('reset 后旧令牌失效', !after.authorizes(first.plaintextToken));
    check('reset 后新令牌可用', after.authorizes(after.plaintextToken));
    check('reset 后能重新画二维码', after.canShowQr);
    check('落盘的哈希已更新', store.storedHash() == after.tokenHash);

    final String serialized = jsonEncode(first.toJson());
    check('落盘 JSON 不含明文', !serialized.contains(first.plaintextToken!));
    check('落盘 JSON 含哈希', serialized.contains(first.tokenHash));
    check('toJson 没有 token 键', !first.toJson().containsKey('token'));
  }

  // ============================================================ 配对载荷
  section('PairingPayload');
  {
    const PairingPayload sample = PairingPayload(
      hostId: 'h-0001',
      ip: '192.168.1.5',
      port: 17890,
      token: 'dG9rZW4=',
    );
    check('uri 是 shensuanzi://pair', sample.uri.startsWith('shensuanzi://pair?'));
    check('uri 含 host_id', sample.uri.contains('host_id=h-0001'));
    check('uri 含 port', sample.uri.contains('port=17890'));
    check('uri 含 v=1', sample.uri.contains('v=1'));

    final PairingPayload parsed = PairingPayload.parse(sample.uri);
    check('往返：host_id', parsed.hostId == sample.hostId);
    check('往返：ip', parsed.ip == sample.ip);
    check('往返：port', parsed.port == sample.port);
    check('往返：token', parsed.token == sample.token);
    check('往返：uri 稳定', parsed.uri == sample.uri);

    const PairingPayload tricky = PairingPayload(
      hostId: 'h-0002',
      ip: '10.0.0.2',
      port: 17891,
      token: 'a-b_c=d+e/f',
    );
    check('URL 不安全字符也能往返',
        PairingPayload.parse(tricky.uri).token == tricky.token);

    for (final String bad in <String>[
      'https://pair?host_id=x',
      'shensuanzi://other?host_id=x',
      '随便一句话',
      '',
    ]) {
      check('非配对码 → FormatException（$bad）',
          throws(() => PairingPayload.parse(bad)));
    }
    check('缺 token → FormatException',
        throws(() => PairingPayload.parse('shensuanzi://pair?host_id=h&ip=1.1.1.1&port=1')));
    check('缺 host_id → FormatException',
        throws(() => PairingPayload.parse('shensuanzi://pair?ip=1.1.1.1&port=1&token=t')));
    for (final String port in <String>['0', '-1', '70000', 'abc']) {
      check('port=$port → FormatException',
          throws(() => PairingPayload.parse(
              'shensuanzi://pair?host_id=h&ip=1.1.1.1&port=$port&token=t')));
    }
  }

  // ============================================================ 二维码
  section('PairingQr');
  {
    const PairingPayload sample = PairingPayload(
      hostId: 'h-0001',
      ip: '192.168.1.5',
      port: 17890,
      token: 'dG9rZW4=',
    );
    final PairingQr qr = PairingQr(sample);
    final List<List<bool>> matrix = qr.matrix;
    final int n = qr.moduleCount;

    check('uri 与载荷一致', qr.uri == sample.uri);
    check('moduleCount ≥ 21（最小 QR 版本）', n >= 21, '$n');
    check('矩阵是 n 行', matrix.length == n);
    check('每行 n 列', matrix.every((List<bool> row) => row.length == n));
    final int dark = matrix
        .expand((List<bool> row) => row)
        .where((bool cell) => cell)
        .length;
    check('有深色模块', dark > 0, '$dark');
    check('左上定位角是深色', matrix[0][0]);
    check('右上定位角是深色', matrix[0][n - 1]);
    check('左下定位角是深色', matrix[n - 1][0]);

    const PairingPayload other = PairingPayload(
      hostId: 'h-0009',
      ip: '192.168.1.9',
      port: 17899,
      token: 'other',
    );
    final List<List<bool>> otherMatrix = PairingQr(other).matrix;
    check('不同内容矩阵不同', matrix.length != otherMatrix.length || matrix != otherMatrix);
  }

  // ============================================================ HTTP
  section('HTTP 层');
  {
    final Db db = Db.openInMemory();
    final HostIdentity identity = HostIdentityStore.inMemory().loadOrCreate(now: _fixedNow);
    final String token = identity.plaintextToken!;
    final HostHttpServer server = await HostHttpServer.start(
      db: db,
      identity: identity,
      ports: _testPorts,
      address: InternetAddress.loopbackIPv4,
      clock: () => _clock,
    );
    final String base = 'http://127.0.0.1:${server.port}';

    Future<(int, Map<String, Object?>)> call(
      String method,
      String path, {
      String? bearer,
      Object? body,
      String? rawBody,
    }) async {
      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest request =
            await client.openUrl(method, Uri.parse('$base$path'));
        if (bearer != null) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
        }
        if (rawBody != null) {
          request.write(rawBody);
        } else if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final HttpClientResponse response = await request.close();
        final String text = await response.transform(utf8.decoder).join();
        return (
          response.statusCode,
          Map<String, Object?>.from(jsonDecode(text) as Map<Object?, Object?>),
        );
      } finally {
        client.close(force: true);
      }
    }

    check('端口落在给定范围',
        server.port >= _testPorts.start && server.port <= _testPorts.end,
        '${server.port}');

    final (int healthStatus, Map<String, Object?> health) =
        await call('GET', '/api/health');
    check('health 无需鉴权 → 200', healthStatus == 200, '$healthStatus');
    check('health.ok = true', health['ok'] == true);
    check('health 用注入的时钟', health['server_time'] == _fixedNow);
    check('health 不含业务数据',
        health.keys.toSet().length == 4, '${health.keys.toList()}');

    final (int noAuth, Map<String, Object?> noAuthJson) = await call(
      'POST',
      '/api/sync/push',
      body: <String, Object?>{'operations': <Object?>[]},
    );
    check('push 缺令牌 → 401', noAuth == 401, '$noAuth');
    check('401 带 error 说明', '${noAuthJson['error']}'.contains('令牌'));
    check('push 错令牌 → 401',
        (await call('POST', '/api/sync/push', bearer: 'nope', body: <String, Object?>{'operations': <Object?>[]})).$1 == 401);
    check('pull 缺令牌 → 401', (await call('GET', '/api/sync/pull')).$1 == 401);

    final String productId = newId();
    final (int pushStatus, Map<String, Object?> pushJson) = await call(
      'POST',
      '/api/sync/push',
      bearer: token,
      body: <String, Object?>{
        'operations': <Object?>[
          <String, Object?>{
            'entity': 'products',
            'entity_id': productId,
            'operation': 'createMasterData',
            'payload': <String, Object?>{
              'id': productId,
              'code': 'HH1',
              'name': '商品',
            },
          },
          <String, Object?>{
            'entity': 'sqlite_master',
            'entity_id': 'bad',
            'operation': 'createMasterData',
          },
        ],
      },
    );
    check('push 合法 → 200', pushStatus == 200, '$pushStatus');
    final List<Object?> results = pushJson['results']! as List<Object?>;
    check('results 两条', results.length == 2);
    check('第一条 applied', (results[0]! as Map)['status'] == 'applied');
    check('第二条 rejected', (results[1]! as Map)['status'] == 'rejected');
    check('一条被拒不拖累同批', ProductDao(db).findById(productId) != null);

    check('非法 JSON → 400',
        (await call('POST', '/api/sync/push', bearer: token, rawBody: 'nope')).$1 == 400);
    final (int noOps, Map<String, Object?> noOpsJson) = await call(
      'POST',
      '/api/sync/push',
      bearer: token,
      body: <String, Object?>{'ops': <Object?>[]},
    );
    check('缺 operations → 400', noOps == 400, '$noOps');
    // §CV·十五：响应体只放**固定文案**（动态异常内容走主机日志）
    check('400 说明是**固定文案**（不回显异常）',
        '${noOpsJson['error']}' == '请求格式有误，请重试。',
        '${noOpsJson['error']}');

    final (int pullStatus, Map<String, Object?> pullJson) =
        await call('GET', '/api/sync/pull', bearer: token);
    check('pull → 200', pullStatus == 200, '$pullStatus');
    check('pull 含 next_cursors', pullJson.containsKey('next_cursors'));
    final Map<String, Object?> cursors =
        Map<String, Object?>.from(pullJson['next_cursors']! as Map);
    check('stock_since 初始为 0', cursors[SyncCursorKeys.stock] == '0');
    check('doc_since 初始为 0|', cursors[SyncCursorKeys.doc] == '0|');
    check('products_since 是复合游标',
        cursors[SyncCursorKeys.products]!.toString().contains('|'),
        '${cursors[SyncCursorKeys.products]}');
    check('空库 stock_ledger 为空', (pullJson['stock_ledger']! as List).isEmpty);
    // R-13 方案 A：pull **含主数据**（不再是「只返 6 个业务实体」）。
    // 9 个实体 + next_cursors **+ has_more**（2026-10-07 §CL 新增）= 11 个键。
    // ⚠️ 2026-10-08 修：`has_more` 上线时这里漏更 ⇒ 断言陈旧（2 项常红，
    // 与本次改动无关）—— 凡是数「响应体顶层键个数」的断言，加键就必须改这里。
    check('pull 含主数据（products 在响应里）', pullJson.containsKey('products'));
    check('pull 恰好 9 个实体 + next_cursors + has_more', pullJson.keys.length == 11,
        '${pullJson.keys.toList()}');
    check('实体名与 SyncPullResult.entityNames 一致',
        pullJson.keys
            .toSet()
            .difference(<String>{
              ...SyncPullResult.entityNames,
              'next_cursors',
              'has_more',
            })
            .isEmpty);
    check('恰好 8 个游标', cursors.length == 8, '${cursors.length}');

    final (int badCursor, Map<String, Object?> badCursorJson) =
        await call('GET', '/api/sync/pull?doc_since=oops', bearer: token);
    check('游标非法 → 400', badCursor == 400, '$badCursor');
    // §CV·十五：游标名与值都是诊断信息 ⇒ 进日志，不回显给用户
    check('400 说明是**固定文案**（不回显「哪个游标」）',
        '${badCursorJson['error']}' == '请求格式有误，请重试。',
        '${badCursorJson['error']}');

    final (int zeroLimit, Map<String, Object?> zeroLimitJson) =
        await call('GET', '/api/sync/pull?limit=0', bearer: token);
    check('limit=0 → 200 且空页',
        zeroLimit == 200 && (zeroLimitJson['documents']! as List).isEmpty);

    // ---------------------------------------------- createDocument 全链路
    // ⚠️ 主单与明细**都用模型的 toRow()** 生成，不手写 JSON：
    // wire 约定是「值 = toRow() 的形态」（§8.2 前）。
    // 手写会漏字段 —— 2026-09-25 真实漏过明细的 `id`，
    // 整条 op 被判 rejected，而断言只比 status，看不到原因。
    final String partyId = newId();
    final String docId = newId();
    final Document draft = Document(
      id: docId,
      docNo: '', // 空 = 临时展示号，主机分配正式单号
      docType: DocType.purchase,
      status: DocStatus.confirmed,
      partyId: partyId,
      totalAmount: 1000,
      occurredAt: _fixedNow,
      createdAt: _fixedNow,
      updatedAt: _fixedNow,
    );
    final Map<String, Object?> docWire = <String, Object?>{
      for (final MapEntry<String, Object?> e in draft.toRow().entries)
        if (SyncWhitelist.isAllowedColumn(Schema.documents, e.key))
          e.key: e.value,
    };

    final (int docPush, Map<String, Object?> docPushJson) = await call(
      'POST',
      '/api/sync/push',
      bearer: token,
      body: <String, Object?>{
        'operations': <Object?>[
          <String, Object?>{
            'entity': 'parties',
            'entity_id': partyId,
            'operation': 'createMasterData',
            'payload': <String, Object?>{'id': partyId, 'name': '往来方'},
          },
          <String, Object?>{
            'entity': 'documents',
            'entity_id': docId,
            'operation': 'createDocument',
            'payload': <String, Object?>{
              'document': docWire,
              'lines': <Object?>[
                DocumentLine.create(
                  documentId: docId,
                  productId: productId,
                  quantity: 10,
                  unitPrice: 100,
                ).toRow(),
              ],
            },
          },
        ],
      },
    );
    final List<Object?> docResults = docPushJson['results']! as List<Object?>;
    String receipts() => <String>[
      for (final Object? r in docResults) receiptLine(r),
    ].join(' | ');

    check('createDocument 推送 → 200', docPush == 200, '$docPush');
    check('两条都 applied', docResults.every((Object? r) => (r! as Map)['status'] == 'applied'),
        receipts());
    final Document? saved = DocumentDao(db).findById(docId);
    check('单据已落库', saved != null);
    check('明细 1 行',
        db.raw.select('SELECT 1 FROM document_lines WHERE document_id = ?',
            <Object?>[docId]).length == 1);
    check('主机分配了正式单号（不再是临时展示号）',
        saved != null && !saved.docNo.startsWith(Document.pendingDocNoPrefix),
        '${saved?.docNo}');
    check('主机写入 paid_amount = 0（派生缓存）', saved?.paidAmount == 0);

    final (int pull2Status, Map<String, Object?> pull2) =
        await call('GET', '/api/sync/pull', bearer: token);
    check('拉取 → 200', pull2Status == 200, '$pull2Status');
    check('documents 1 行', (pull2['documents']! as List).length == 1);
    check('document_lines 1 行', (pull2['document_lines']! as List).length == 1);
    check('stock_ledger 1 行', (pull2['stock_ledger']! as List).length == 1);
    check('party_ledger 1 行', (pull2['party_ledger']! as List).length == 1);
    final Map<String, Object?> cursors2 =
        Map<String, Object?>.from(pull2['next_cursors']! as Map);
    check('stock_since 推进到 1', cursors2[SyncCursorKeys.stock] == '1',
        '${cursors2[SyncCursorKeys.stock]}');
    check('doc_since 推进（不再是起始值）',
        cursors2[SyncCursorKeys.doc] != '0|', '${cursors2[SyncCursorKeys.doc]}');

    final (int pull3Status, Map<String, Object?> pull3) = await call(
      'GET',
      '/api/sync/pull'
          '?stock_since=${cursors2[SyncCursorKeys.stock]}'
          '&doc_since=${Uri.encodeQueryComponent('${cursors2[SyncCursorKeys.doc]}')}',
      bearer: token,
    );
    check('按游标再拉增量 → 空', pull3Status == 200, '$pull3Status');
    check('增量不再返回 documents', (pull3['documents']! as List).isEmpty);
    check('增量不再返回 stock_ledger', (pull3['stock_ledger']! as List).isEmpty);

    // 明细漏 id → rejected，且原因点到列名。
    // 这是 2026-09-25 真实踩过的坑（夹具手写 JSON 漏字段），钉住它，
    // 免得下次又靠「跑一遍看输出」定位。
    final String badDoc = newId();
    final Map<String, Object?> badOp = <String, Object?>{
      'entity': 'documents',
      'entity_id': badDoc,
      'operation': 'createDocument',
      'payload': <String, Object?>{
        'document': <String, Object?>{
          for (final MapEntry<String, Object?> e in draft.toRow().entries)
            if (SyncWhitelist.isAllowedColumn(Schema.documents, e.key))
              e.key: e.value,
          'id': badDoc,
        },
        'lines': <Object?>[
          DocumentLine.create(
            documentId: badDoc,
            productId: productId,
            quantity: 1,
            unitPrice: 100,
          ).toRow()
            ..remove('id'),
        ],
      },
    };
    final (int badStatus, Map<String, Object?> badJson) = await call(
      'POST',
      '/api/sync/push',
      bearer: token,
      body: <String, Object?>{
        'operations': <Object?>[badOp],
      },
    );
    final Map<String, Object?> badReceipt = Map<String, Object?>.from(
      (badJson['results']! as List).first! as Map,
    );
    check('明细漏 id → 200 + rejected', badStatus == 200, '$badStatus');
    check('漏 id 的明细 → rejected', badReceipt['status'] == 'rejected',
        '${badReceipt['reason']}');
    check('原因点到列名 `id`',
        '${badReceipt['reason']}'.contains('缺少必填列 `id`'),
        '${badReceipt['reason']}');
    check('被拒的单据不落库', DocumentDao(db).findById(badDoc) == null);

    // ---------------------------------------------- 主数据增量（R-13 方案 A）
    final String productsCursor =
        cursors2[SyncCursorKeys.products]! as String;
    tick(); // 真实世界里「改价」不会与「创建」挤在同一毫秒
    final (int updStatus, Map<String, Object?> updJson) = await call(
      'POST',
      '/api/sync/push',
      bearer: token,
      body: <String, Object?>{
        'operations': <Object?>[
          <String, Object?>{
            'entity': 'products',
            'entity_id': productId,
            'operation': 'updateMasterData',
            'base_version': 0,
            'payload': <String, Object?>{'cost_price': 120},
          },
        ],
      },
    );
    check('改价 → 200', updStatus == 200, '$updStatus');
    check('改价 applied',
        ((updJson['results']! as List).single! as Map)['status'] == 'applied',
        '$updJson');

    final (int deltaStatus, Map<String, Object?> delta) = await call(
      'GET',
      '/api/sync/pull'
          '?products_since=${Uri.encodeQueryComponent(productsCursor)}',
      bearer: token,
    );
    check('带 products_since 增量拉取 → 200', deltaStatus == 200, '$deltaStatus');
    check('增量拉到改动的那一行', (delta['products']! as List).length == 1,
        '${delta['products']}');
    check('拉到的是新价 120',
        ((delta['products']! as List).single! as Map)['cost_price'] == 120);
    // 每个实体的游标**独立**：只给 products_since，其它实体就按「从头拉」返回。
    // （别指望「给一个游标 ⇒ 整页都是增量的」。）
    check('各游标独立：只给 products_since 时 documents 从头拉回来',
        (delta['documents']! as List).isNotEmpty,
        '${(delta['documents']! as List).length}');

    // ⚠️ 已知边界（R-14）：同一毫秒内的二次改动，带游标拉不到。
    // 这条**断言当前行为**，作用是把这个边界摆在门禁里 ——
    // 一旦按 R-14 修复（主机分配单调 `updated_at`，或主数据加 `sync_seq`），
    // 它会立刻失败，逼着把它翻过来，而不是让边界悄悄留在代码里。
    final String boundaryId = newId();
    await call(
      'POST',
      '/api/sync/push',
      bearer: token,
      body: <String, Object?>{
        'operations': <Object?>[
          <String, Object?>{
            'entity': 'products',
            'entity_id': boundaryId,
            'operation': 'createMasterData',
            'payload': <String, Object?>{'code': 'HZ1', 'name': '边界商品'},
          },
        ],
      },
    );
    final (_, Map<String, Object?> boundaryFirst) =
        await call('GET', '/api/sync/pull', bearer: token);
    final String boundaryCursor =
        (boundaryFirst['next_cursors']! as Map)[SyncCursorKeys.products]! as String;

    // 不 tick：与上一次写落在同一毫秒
    await call(
      'POST',
      '/api/sync/push',
      bearer: token,
      body: <String, Object?>{
        'operations': <Object?>[
          <String, Object?>{
            'entity': 'products',
            'entity_id': boundaryId,
            'operation': 'updateMasterData',
            'base_version': 0,
            'payload': <String, Object?>{'cost_price': 130},
          },
        ],
      },
    );
    final (_, Map<String, Object?> boundaryDelta) = await call(
      'GET',
      '/api/sync/pull'
          '?products_since=${Uri.encodeQueryComponent(boundaryCursor)}',
      bearer: token,
    );
    check('R-14 边界：同一毫秒的同 id 改动被增量漏掉',
        (boundaryDelta['products']! as List).isEmpty,
        '${boundaryDelta['products']}');
    final (_, Map<String, Object?> boundaryFull) =
        await call('GET', '/api/sync/pull', bearer: token);
    check('R-14 边界：但全量重拉看得到（数据没丢）',
        ((boundaryFull['products']! as List)
                .cast<Map<String, Object?>>()
                .firstWhere((Map<String, Object?> r) => r['id'] == boundaryId))['cost_price'] ==
            130);

    await server.close(force: true);
    db.close();
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

/// 把一条推送回执渲染成 `status (reason)`（自检侧不带 `entity_id` 前缀）。
///
/// 同 `test/http_server_test.dart`：一次转换，字符串里**不做 `as Map` 强转**。
String receiptLine(Object? raw) {
  final Map<String, Object?> item = raw is Map
      ? Map<String, Object?>.from(raw)
      : <String, Object?>{};
  final Object? reason = item['reason'];
  return '${item['status']}${reason == null ? '' : ' ($reason)'}';
}
