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

  /// 注入给主机的时钟。**可变** —— 需要「时间前进」的用例自己调 [tick]。
  ///
  /// 为什么不能一直用常量：主数据的拉取游标是 `(updated_at, id)`，
  /// 而 `updated_at` 取自主机时钟。时钟不动 ⇒ 两次改动落在同一毫秒 ⇒
  /// `(stamp, id) >` 的谓词认不出后一次改动（见 R-14）。
  int hostClock = fixedNow;

  /// 让主机时钟前进 1ms（模拟「稍后」发生的一次写）
  int tick() => ++hostClock;

  setUp(() async {
    resetClock();
    hostClock = fixedNow;
    db = newMemoryDb();
    identity = HostIdentityStore.inMemory().loadOrCreate(now: fixedNow);
    server = await HostHttpServer.start(
      db: db,
      identity: identity,
      ports: testPorts,
      address: InternetAddress.loopbackIPv4,
      clock: () => hostClock,
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

  /// `documents` 的 wire 行：只保留白名单列。
  ///
  /// 用 [SyncWhitelist]（**与主机侧同一份白名单**）剔除主机专属列
  /// （`created_at` / `updated_at` / `paid_amount`），
  /// 于是夹具**不可能**写出会被主机判 `rejected` 的列。
  Map<String, Object?> documentWire(Document doc) => <String, Object?>{
    for (final MapEntry<String, Object?> entry in doc.toRow().entries)
      if (SyncWhitelist.isAllowedColumn(Schema.documents, entry.key))
        entry.key: entry.value,
  };

  /// `createDocument` 的 payload（采购入库）。
  ///
  /// ⚠️ 主单与明细都用**模型的 `toRow()`** 生成，**不手写 JSON**：
  /// wire 约定是「值 = `toRow()` 的形态」（`sync_protocol.md` §8.2 前）。
  /// 手写会漏字段 —— 2026-09-25 真实漏过明细的 `id`，整条 op 被判 `rejected`，
  /// 而断言只比 `status`，失败信息里看不到原因。
  Map<String, Object?> purchaseOp({
    required String docId,
    required String productId,
    required String partyId,
    int quantity = 10,
    int unitPrice = 100,
  }) => <String, Object?>{
    'entity': 'documents',
    'entity_id': docId,
    'operation': 'createDocument',
    'payload': <String, Object?>{
      'document': documentWire(
        Document(
          id: docId,
          docNo: '', // 空 = 临时展示号，主机分配正式单号
          docType: DocType.purchase,
          status: DocStatus.confirmed,
          partyId: partyId,
          totalAmount: quantity * unitPrice,
          occurredAt: fixedNow,
          createdAt: fixedNow,
          updatedAt: fixedNow,
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
  };

  /// 逐条回执的 `reason`，供 [expect] 的 `reason:` 使用。
  ///
  /// 只比 `status` 时，`rejected` 本身不告诉你为什么 —— 得回头加打印再跑一遍。
  String reasonsOf(Map<String, Object?> pushJson) => <String>[
    for (final Object? item in pushJson['results']! as List)
      '${(item! as Map)['entity_id']}: '
          '${(item as Map)['status']}'
          '${(item as Map)['reason'] == null ? '' : ' (${(item as Map)['reason']})'}',
  ].join(' | ');

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
    test('空库返回空实体与初始游标（9 实体 + 8 游标）', () async {
      final (int status, Map<String, Object?> json) = await call(
        'GET',
        '/api/sync/pull',
        bearer: token(),
      );

      expect(status, 200);
      expect(json['stock_ledger'], isEmpty);
      expect(
        json.keys.toSet().difference(<String>{
          ...SyncPullResult.entityNames,
          'next_cursors',
        }),
        isEmpty,
        reason: '响应体只允许 9 个实体 + next_cursors',
      );
      final Map<String, Object?> cursors =
          Map<String, Object?>.from(json['next_cursors']! as Map);
      expect(cursors.keys.toSet(), SyncCursorKeys.all.toSet());
      expect(cursors[SyncCursorKeys.stock], '0');
      expect(cursors[SyncCursorKeys.doc], '0|');
      expect(cursors[SyncCursorKeys.products], '0|');
    });

    test('推送后能拉到业务实体与主数据（R-13 方案 A）', () async {
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
            purchaseOp(docId: docId, productId: productId, partyId: partyId),
          ],
        },
      );
      expect(pushStatus, 200);
      expect(
        <Object?>[
          for (final Object? r in pushJson['results']! as List)
            (r! as Map)['status'],
        ],
        <Object?>['applied', 'applied'],
        // 带上逐条 reason：否则失败信息里只有「rejected」，没有原因
        reason: reasonsOf(pushJson),
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
      // 主数据也并入 pull（R-13 方案 A）：商品 1（`createProduct`）+ 往来方 1
      expect(json['products'], hasLength(1));
      expect(json['parties'], hasLength(1));
      expect(json['accounts'], isEmpty);
      final Map<String, Object?> cursors =
          Map<String, Object?>.from(json['next_cursors']! as Map);
      expect(
        cursors[SyncCursorKeys.stock],
        '1',
        reason: '游标推进到已拉取的最大 seq_no',
      );
      expect(
        cursors[SyncCursorKeys.products]!.toString(),
        contains('|'),
        reason: '主数据游标是复合游标',
      );
    });

    test('改价后带 products_since 能拉到新价（R-13 的核心场景）', () async {
      final (int createStatus, Map<String, Object?> createJson) = await call(
        'POST',
        '/api/sync/push',
        bearer: token(),
        body: <String, Object?>{
          'operations': <Object?>[
            masterOp('products', newId(), <String, Object?>{
              'code': 'H006',
              'name': '商品-H006',
              'cost_price': 100,
            }),
          ],
        },
      );
      expect(createStatus, 200, reason: '$createJson');

      // 先全量拉一次，记下游标（并确认初始价）
      final (int firstStatus, Map<String, Object?> first) = await call(
        'GET',
        '/api/sync/pull',
        bearer: token(),
      );
      expect(firstStatus, 200);
      final Map<String, Object?> created =
          (first['products']! as List).single as Map<String, Object?>;
      expect(created['cost_price'], 100);
      final String productsCursor =
          (first['next_cursors']! as Map)[SyncCursorKeys.products]! as String;

      // 改价（推进主机时钟：真实世界里这两次写不会挤在同一毫秒）
      tick();
      final (int updateStatus, Map<String, Object?> updateJson) = await call(
        'POST',
        '/api/sync/push',
        bearer: token(),
        body: <String, Object?>{
          'operations': <Object?>[
            <String, Object?>{
              'entity': 'products',
              'entity_id': created['id'],
              'operation': 'updateMasterData',
              'base_version': 0,
              'payload': <String, Object?>{'cost_price': 120},
            },
          ],
        },
      );
      expect(updateStatus, 200, reason: '$updateJson');
      expect(
        ((updateJson['results']! as List).single! as Map)['status'],
        'applied',
        reason: '$updateJson',
      );

      // 增量拉取：带游标才能看到这次改动
      final (int deltaStatus, Map<String, Object?> delta) = await call(
        'GET',
        '/api/sync/pull?products_since=${Uri.encodeQueryComponent(productsCursor)}',
        bearer: token(),
      );
      expect(deltaStatus, 200);
      expect(
        (delta['products']! as List), hasLength(1),
        reason: '改动必须能被另一台设备感知',
      );
      expect(
        ((delta['products']! as List).single! as Map)['cost_price'],
        120,
      );
      // 每个实体的游标**独立**：给了一个游标，其余实体照常返回（从头拉）
      expect(
        delta.keys.toSet().containsAll(SyncPullResult.entityNames),
        isTrue,
        reason: '别指望「给一个游标 ⇒ 整页都是增量的」',
      );
    });

    test('⚠️ 已知边界（R-14）：同一毫秒内的二次改动，带游标拉不到', () async {
      // 这条**断言当前行为**，不是断言「正确行为」。
      // 它的作用是把这个边界摆在门禁里 —— 一旦做了 R-14 的修复（主机分配
      // 单调 `updated_at`，或主数据加 `sync_seq` 列），这条会立刻失败，
      // 逼着把它翻过来，而不是让边界悄悄留在代码里。
      final (_, Map<String, Object?> createJson) = await call(
        'POST',
        '/api/sync/push',
        bearer: token(),
        body: <String, Object?>{
          'operations': <Object?>[
            masterOp('products', newId(), <String, Object?>{
              'code': 'H007',
              'name': '商品-H007',
              'cost_price': 100,
            }),
          ],
        },
      );
      expect(
        ((createJson['results']! as List).single! as Map)['status'],
        'applied',
        reason: '$createJson',
      );

      final (_, Map<String, Object?> first) = await call(
        'GET',
        '/api/sync/pull',
        bearer: token(),
      );
      final String cursor =
          (first['next_cursors']! as Map)[SyncCursorKeys.products]! as String;
      final Map<String, Object?> created =
          (first['products']! as List).single as Map<String, Object?>;

      // 不 tick：这次改动与上一次落在**同一毫秒**
      final (_, Map<String, Object?> updateJson) = await call(
        'POST',
        '/api/sync/push',
        bearer: token(),
        body: <String, Object?>{
          'operations': <Object?>[
            <String, Object?>{
              'entity': 'products',
              'entity_id': created['id'],
              'operation': 'updateMasterData',
              'base_version': 0,
              'payload': <String, Object?>{'cost_price': 130},
            },
          ],
        },
      );
      expect(
        ((updateJson['results']! as List).single! as Map)['status'],
        'applied',
        reason: '$updateJson',
      );

      final (_, Map<String, Object?> delta) = await call(
        'GET',
        '/api/sync/pull?products_since=${Uri.encodeQueryComponent(cursor)}',
        bearer: token(),
      );
      expect(
        (delta['products']! as List),
        isEmpty,
        reason: '游标谓词是 (updated_at, id) > 游标；同一毫秒的同 id 改动不满足，被漏掉',
      );
      // 但全量重拉（无游标）看得到 —— 说明数据没丢，只是增量感知不到
      final (_, Map<String, Object?> full) = await call(
        'GET',
        '/api/sync/pull',
        bearer: token(),
      );
      expect(
        ((full['products']! as List).single! as Map)['cost_price'],
        130,
    );
    });

    test('明细漏 id → rejected，且原因点出列名（HTTP 全链路）', () async {
      final String productId = await createProduct('H005');
      final String partyId = newId();
      final String docId = newId();

      final Map<String, Object?> op = purchaseOp(
        docId: docId,
        productId: productId,
        partyId: partyId,
      );
      // 故意去掉明细的 id —— 这是 2026-09-25 真实踩过的坑：
      // `document_lines.id` 由客户端生成、主机原样落库（sync_protocol.md §8.1）
      final Map<String, Object?> line =
          ((op['payload']! as Map)['lines']! as List).first as Map<String, Object?>;
      line.remove('id');

      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/sync/push',
        bearer: token(),
        body: <String, Object?>{
          'operations': <Object?>[op],
        },
      );

      expect(status, 200);
      final Map<String, Object?> receipt = Map<String, Object?>.from(
        (json['results']! as List).first as Map,
      );
      expect(receipt['status'], 'rejected');
      expect(
        '${receipt['reason']}',
        contains('缺少必填列 `id`'),
        reason: '失败原因必须点到具体列名，否则只能靠复跑定位',
      );
      expect(DocumentDao(db).findById(docId), isNull, reason: '被拒的单据不落库');
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
