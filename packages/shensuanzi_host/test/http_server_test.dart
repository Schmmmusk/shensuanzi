// 主机 HTTP 层（`docs/sync_protocol.md` §8 / §9）。
//
// 覆盖：端口探测、路由、Bearer 鉴权、JSON 往返、错误码。
// 核心主张：**这一层只做搬运** —— 协议语义在 SyncServer，业务规则在 RuleEngine。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；需要可用的 SQLite 原生库，见 `lib/sqlite_local.dart`。
import 'dart:convert';
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late HostIdentity identity;
  late HostHttpServer server;
  late String base;

  // 避开 17890（生产端口），免得与本机真跑着的实例撞车
  const PortRange testPorts = PortRange(start: 17985, end: 17999);
  final int fixedNow = 1700000000000;

  setUp(() async {
    resetClock();
    db = newMemoryDb();
    identity = HostIdentityStore.inMemory().loadOrCreate(now: fixedNow);
    server = await HostHttpServer.start(
      db: db,
      identity: identity,
      ports: testPorts,
      address: InternetAddress.loopbackIPv4,
      clock: () => fixedNow,
    );
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.close(force: true);
    db.close();
  });

  String token() => identity.plaintextToken!;

  Future<(int, Map<String, Object?>)> call(
    String method,
    String path, {
    String? bearer,
    Object? body,
    String? rawBody,
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.openUrl(
        method,
        Uri.parse('$base$path'),
      );
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

  Map<String, Object?> masterOp(String entity, String id, Map<String, Object?> payload) =>
      <String, Object?>{
        'entity': entity,
        'entity_id': id,
        'operation': 'createMasterData',
        'payload': <String, Object?>{'id': id, ...payload},
      };

  /// 经 HTTP 建一个商品，返回 id
  Future<String> createProduct(String code) async {
    final String id = newId();
    final (int status, Map<String, Object?> json) = await call(
      'POST',
      '/api/sync/push',
      bearer: token(),
      body: <String, Object?>{
        'operations': <Object?>[
          masterOp('products', id, <String, Object?>{
            'code': code,
            'name': '商品-$code',
          }),
        ],
      },
    );
    expect(status, 200, reason: '$json');
    return id;
  }

  // ============================================================ 端口与路由

  group('启动', () {
    test('端口落在给定范围内', () {
      expect(server.port, greaterThanOrEqualTo(testPorts.start));
      expect(server.port, lessThanOrEqualTo(testPorts.end));
    });

    test('同端口范围第二次启动会落到下一个端口', () async {
      final HostHttpServer second = await HostHttpServer.start(
        db: db,
        identity: identity,
        ports: testPorts,
        address: InternetAddress.loopbackIPv4,
        clock: () => fixedNow,
      );
      addTearDown(() => second.close(force: true));

      expect(second.port, isNot(server.port));
    });
  });

  group('/api/health', () {
    test('不需要鉴权（扫码前就要能探到）', () async {
      final (int status, Map<String, Object?> json) = await call('GET', '/api/health');

      expect(status, 200);
      expect(json['ok'], isTrue);
      expect(json['api_version'], HostHttpServer.apiVersion);
      expect(json['schema_version'], Schema.version);
      expect(json['server_time'], fixedNow, reason: '时钟由外部注入');
    });

    test('不泄露业务数据', () async {
      final (_, Map<String, Object?> json) = await call('GET', '/api/health');

      expect(json.keys.toSet(), <String>{
        'ok',
        'api_version',
        'server_time',
        'schema_version',
      });
    });
  });

  // ============================================================ 鉴权

  group('Bearer 鉴权', () {
    test('缺 Authorization → 401', () async {
      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/sync/push',
        body: <String, Object?>{'operations': <Object?>[]},
      );

      expect(status, 401);
      expect(json['error'], contains('令牌'));
    });

    test('令牌错误 → 401', () async {
      final (int status, _) = await call(
        'POST',
        '/api/sync/push',
        bearer: 'wrong-token',
        body: <String, Object?>{'operations': <Object?>[]},
      );
      expect(status, 401);
    });

    test('前缀不是 Bearer → 401', () async {
      final (int status, _) = await call(
        'POST',
        '/api/sync/push',
        bearer: null,
        body: <String, Object?>{'operations': <Object?>[]},
      );
      expect(status, 401);
    });

    test('pull 同样需要鉴权', () async {
      final (int status, _) = await call('GET', '/api/sync/pull');
      expect(status, 401);
    });
  });

  // ============================================================ push

  group('POST /api/sync/push', () {
    test('合法请求 → 200 + results', () async {
      final String id = newId();
      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/sync/push',
        bearer: token(),
        body: <String, Object?>{
          'operations': <Object?>[
            masterOp('products', id, <String, Object?>{
              'code': 'H001',
              'name': '商品',
            }),
          ],
        },
      );

      expect(status, 200);
      final List<Object?> results = json['results']! as List<Object?>;
      expect(results, hasLength(1));
      expect((results.single! as Map)['entity_id'], id);
      expect((results.single as Map)['status'], 'applied');
      expect(ProductDao(db).findById(id), isNotNull);
    });

    test('一条被拒不拖累同批其它条目', () async {
      final String good = newId();
      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/sync/push',
        bearer: token(),
        body: <String, Object?>{
          'operations': <Object?>[
            masterOp('products', good, <String, Object?>{
              'code': 'H002',
              'name': '商品',
            }),
            <String, Object?>{
              'entity': 'sqlite_master', // 白名单外
              'entity_id': 'bad',
              'operation': 'createMasterData',
            },
          ],
        },
      );

      expect(status, 200, reason: '协议层成功，业务失败在 results 里');
      final List<Object?> results = json['results']! as List<Object?>;
      expect((results[0]! as Map)['status'], 'applied');
      expect((results[1]! as Map)['status'], 'rejected');
    });

    test('请求体不是 JSON → 400', () async {
      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/sync/push',
        bearer: token(),
        rawBody: 'not json at all',
      );

      expect(status, 400);
      expect(json['error'], isNotNull);
    });

    test('缺 operations → 400', () async {
      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/sync/push',
        bearer: token(),
        body: <String, Object?>{'ops': <Object?>[]},
      );

      expect(status, 400);
      expect('${json['error']}', contains('operations'));
    });
  });

  // ============================================================ pull

  group('GET /api/sync/pull', () {
    test('空库返回空实体与初始游标', () async {
      final (int status, Map<String, Object?> json) = await call(
        'GET',
        '/api/sync/pull',
        bearer: token(),
      );

      expect(status, 200);
      expect(json['stock_ledger'], isEmpty);
      final Map<String, Object?> cursors =
          Map<String, Object?>.from(json['next_cursors']! as Map);
      expect(cursors[SyncCursorKeys.stock], '0');
      expect(cursors[SyncCursorKeys.doc], '0|');
    });

    test('推送后能拉到业务实体与游标（pull 不含主数据）', () async {
      final String productId = await createProduct('H003');
      final String partyId = newId();

      // 一张采购单 → documents / document_lines / stock_ledger / party_ledger 各一行
      final String docId = newId();
      final (int pushStatus, Map<String, Object?> pushJson) = await call(
        'POST',
        '/api/sync/push',
        bearer: token(),
        body: <String, Object?>{
          'operations': <Object?>[
            masterOp('parties', partyId, <String, Object?>{'name': '往来方'}),
            <String, Object?>{
              'entity': 'documents',
              'entity_id': docId,
              'operation': 'createDocument',
              'payload': <String, Object?>{
                'document': <String, Object?>{
                  'id': docId,
                  'doc_type': 'purchase',
                  'status': 'confirmed',
                  'party_id': partyId,
                  'total_amount': 1000,
                  'occurred_at': fixedNow,
                  'time_estimated': 0,
                },
                'lines': <Object?>[
                  <String, Object?>{
                    'product_id': productId,
                    'quantity': 10,
                    'unit_price': 100,
                    'amount': 1000,
                  },
                ],
              },
            },
          ],
        },
      );
      expect(pushStatus, 200);
      expect(
        (pushJson['results']! as List).map((Object? r) => (r! as Map)['status']),
        <Object?>['applied', 'applied'],
      );

      final (int status, Map<String, Object?> json) = await call(
        'GET',
        '/api/sync/pull',
        bearer: token(),
      );

      expect(status, 200);
      expect(json['documents'], hasLength(1));
      expect(json['document_lines'], hasLength(1));
      expect(json['stock_ledger'], hasLength(1));
      expect(json['party_ledger'], hasLength(1));
      expect(
        json.containsKey('products'),
        isFalse,
        reason: 'pull 只返回 §8.2 的 6 个业务实体；主数据走 §8.3',
      );
      expect(
        (json['next_cursors']! as Map)[SyncCursorKeys.stock],
        '1',
        reason: '游标推进到已拉取的最大 seq_no',
      );
    });

    test('游标非法 → 400', () async {
      final (int status, Map<String, Object?> json) = await call(
        'GET',
        '/api/sync/pull?doc_since=not-a-cursor',
        bearer: token(),
      );

      expect(status, 400);
      expect('${json['error']}', contains('游标'));
    });

    test('limit 可传', () async {
      await createProduct('H004');
      final (int status, Map<String, Object?> json) = await call(
        'GET',
        '/api/sync/pull?limit=0',
        bearer: token(),
      );

      expect(status, 200);
      expect(json['documents'], isEmpty, reason: 'limit=0 → 空页');
    });
  });
}
