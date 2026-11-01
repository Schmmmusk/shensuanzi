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

import 'support/dev_terms.dart';
import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late HostIdentity identity;
  late HostHttpServer server;
  late String base;

  /// 主机侧**内部错误日志**的捕获（#22 裁定，2026-10-09）。
  ///
  /// 协议违反 / 规则内部 bug 的**细节只进日志**（回执只给通用中文，
  /// `response.reason` 不再承担「哪里错了」）⇒「原因点出列名 X」那类断言
  /// 改成查这里 —— 与 `sync_server_test` 同一处置，分支可定位性由此保住。
  final List<String> internalErrors = <String>[];

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
    internalErrors.clear();
    db = newMemoryDb();
    identity = HostIdentityStore.inMemory().loadOrCreate(now: fixedNow);
    server = await HostHttpServer.start(
      db: db,
      identity: identity,
      ports: testPorts,
      address: InternetAddress.loopbackIPv4,
      clock: () => hostClock,
      onInternalError: (String label, Object error, StackTrace stack) =>
          internalErrors.add('$label｜$error'),
      // A4：批准后下发的配对码 —— 生产里由控制器现取（端口要等绑完才知道），
      // 测试里用同一份形状的字符串，好让「手机能解析」这件事真的被验到
      pairingUri: () =>
          'shensuanzi://pair?host_id=${identity.hostId}&ip=127.0.0.1'
          '&port=${server.port}&token=${identity.plaintextToken}&v=1',
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

  Map<String, Object?> masterOp(
    String entity,
    String id,
    Map<String, Object?> payload,
  ) => <String, Object?>{
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
    for (final Object? item in pushJson['results']! as List) receiptLine(item),
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
      final (int status, Map<String, Object?> json) = await call(
        'GET',
        '/api/health',
      );

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

    test('缺 operations → 400，且响应体是**固定文案**（§CV·十五）', () async {
      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/sync/push',
        bearer: token(),
        body: <String, Object?>{'ops': <Object?>[]},
      );

      expect(status, 400);
      // 响应体只放**固定文案**；「哪个字段缺了」这种动态内容走主机日志
      expect(json['error'], '请求格式有误，请重试。');
      expectNoDevTerms('${json['error']}');
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
          // 2026-10-07（docs/reply.md §1）：分页「还有没有下一页」的显式信号
          'has_more',
          // 2026-10-23（P0-3）：窗口取满 ⇒ 最新状态没带全 ⇒ 客户端推迟清队列
          'doc_window_truncated',
        }),
        isEmpty,
        reason: '响应体只允许 9 个实体 + next_cursors + has_more + doc_window_truncated',
      );
      // 空库 ⇒ 每路都空 ⇒ 不可能还有下一页
      expect(json['has_more'], isFalse);
      final Map<String, Object?> cursors = Map<String, Object?>.from(
        json['next_cursors']! as Map,
      );
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
      final Map<String, Object?> cursors = Map<String, Object?>.from(
        json['next_cursors']! as Map,
      );
      expect(cursors[SyncCursorKeys.stock], '1', reason: '游标推进到已拉取的最大 seq_no');
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
        (delta['products']! as List),
        hasLength(1),
        reason: '改动必须能被另一台设备感知',
      );
      expect(((delta['products']! as List).single! as Map)['cost_price'], 120);
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
      expect(((full['products']! as List).single! as Map)['cost_price'], 130);
    });

    test('明细漏 id → rejected + reason_code，列名细节只进日志（HTTP 全链路）', () async {
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
          ((op['payload']! as Map)['lines']! as List).first
              as Map<String, Object?>;
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
      // #22 裁定（2026-10-09）：协议违反（客户端漏了明细 id）的回执**只给通用中文**，
      // 分支区分改由 **reason_code** 承担（这里是 HTTP 层，所以查 JSON 字段）。
      expect(
        receipt['reason_code'],
        'field_type_mismatch',
        reason: '协议违反 ⇒ 落 `lines` 解析失败那类码',
      );
      // 列名的定位价值**没有丢** —— 它随原始异常进主机日志（回执不再回显）。
      // 「失败原因必须点到具体列名」这条要求因此改由这里承担。
      // #42 补正（2026-10-16）：#42 把缺列异常改成 `RowDecodeException`，本条与
      // `selfcheck_host` 同批漏改（复跑抓出）⇒ 补齐；新子串只可能由被测路径给出。
      expect(
        internalErrors.any(
          (String e) => e.contains('RowDecodeException(id: 缺少这一列)'),
        ),
        isTrue,
        reason: '细节必须点到具体列名，否则只能靠复跑定位',
      );
      expect(DocumentDao(db).findById(docId), isNull, reason: '被拒的单据不落库');
    });

    test('游标非法 → 400，且响应体是**固定文案**（不回显「哪个游标」）', () async {
      final (int status, Map<String, Object?> json) = await call(
        'GET',
        '/api/sync/pull?doc_since=not-a-cursor',
        bearer: token(),
      );

      expect(status, 400);
      // §CV·十五：游标名与值都是诊断信息 ⇒ 进日志，不回显给用户
      expect(json['error'], '请求格式有误，请重试。');
      expectNoDevTerms('${json['error']}');
    });

    // P2 #6（业务审查 §3.7）：`limit` 必须校验 —— 从前 `limit=0` 被接受，
    // 每个分页实体都「取满」（`rows.length == 0 == limit`）⇒ `has_more` 恒 true
    // ⇒ 客户端死循环；超大 limit 则一次拉全库（内存峰值不可控）。
    test('P2 #6：limit 越界（0 / 超大）⇒ 400，不再静默接受', () async {
      await createProduct('H004');
      for (final String bad in <String>['0', '99999', '-5']) {
        final (int status, Map<String, Object?> json) = await call(
          'GET',
          '/api/sync/pull?limit=$bad',
          bearer: token(),
        );
        expect(
          status,
          400,
          reason: 'limit=$bad 必须拒绝 —— 0 会让 has_more 恒 true（死循环）',
        );
        expect(json['error'], '请求格式有误，请重试。');
      }

      // 合法边界照常工作
      final (int ok, Map<String, Object?> json) = await call(
        'GET',
        '/api/sync/pull?limit=1',
        bearer: token(),
      );
      expect(ok, 200);
      expect(json['products'], isNotEmpty, reason: 'limit=1 合法，取 1 条主数据');
    });
  });

  // ============================================================ 6 位短码配对
  //
  // 提案 58 · A4 乙（2026-11-01 用户裁定）：手机端不再抄 100 个字符的配对码，
  // 改成输电脑屏幕上的 6 位数字。**码本身不是凭据** —— 拿到它只能建一条
  // 待确认请求，令牌要等电脑前的人点「允许」。这一组盯的就是这条链路。
  group('6 位短码配对', () {
    /// 建一条待确认请求，返回 request_id
    Future<String> requestPairing(String code, {String device = '安卓手机'}) async {
      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/pair/request',
        body: <String, Object?>{'code': code, 'device_name': device},
      );
      expect(status, 200, reason: '$json');
      return json['request_id']! as String;
    }

    test('正确码 ⇒ 200 + request_id，主机侧出现待确认设备（含来源地址）', () async {
      final String code = server.pairRequests.issueCode();
      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/pair/request',
        body: <String, Object?>{
          'code': code,
          'device_name': '安卓手机（Android 14）',
        },
      );
      expect(status, 200, reason: '$json');
      expect(json['status'], 'awaiting');
      final String id = json['request_id']! as String;
      expect(id.length, 16);

      final PairPending pending = server.pairRequests.pendingAwaiting().single;
      expect(pending.id, id);
      expect(pending.deviceName, contains('Android'));
      expect(
        pending.ip,
        '127.0.0.1',
        reason: '来源地址由服务端从 socket 取 —— 请求体里没有这一项，编不出来',
      );
    });

    test('错码 ⇒ 400 + 说清「再看一眼电脑上的 6 位」+ 剩余次数递减', () async {
      final String code = server.pairRequests.issueCode();
      final String wrong = code == '000000' ? '111111' : '000000';
      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/pair/request',
        body: <String, Object?>{'code': wrong, 'device_name': 'x'},
      );
      expect(status, 400);
      expect('${json['error']}', contains('6 位数字'));
      expect(json['remaining'], PairRequests.maxAttemptsPerCode - 1);
      expect(server.pairRequests.pendingAwaiting(), isEmpty);
    });

    test('试错用完 ⇒ 409 作废，之后输对也不认', () async {
      final String code = server.pairRequests.issueCode();
      final String wrong = code == '000000' ? '111111' : '000000';
      for (int i = 0; i < PairRequests.maxAttemptsPerCode - 1; i++) {
        await call(
          'POST',
          '/api/pair/request',
          body: <String, Object?>{'code': wrong, 'device_name': 'x'},
        );
      }
      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/pair/request',
        body: <String, Object?>{'code': wrong, 'device_name': 'x'},
      );
      expect(status, 409);
      expect('${json['error']}', contains('作废'));

      final (int status2, _) = await call(
        'POST',
        '/api/pair/request',
        body: <String, Object?>{'code': code, 'device_name': 'x'},
      );
      expect(status2, 409, reason: '作废后连正确码也不能再用');
    });

    test('未批准 ⇒ awaiting 且不下发凭据；批准后下发可解析的配对码', () async {
      final String id = await requestPairing(server.pairRequests.issueCode());

      final (int s1, Map<String, Object?> j1) = await call(
        'GET',
        '/api/pair/status?request_id=$id',
      );
      expect(s1, 200);
      expect(j1['status'], 'awaiting');
      expect(
        j1.containsKey('pairing_code'),
        isFalse,
        reason: '没点允许之前，一个字节的凭据都不能给',
      );

      expect(server.pairRequests.approve(id), isTrue);
      final (int s2, Map<String, Object?> j2) = await call(
        'GET',
        '/api/pair/status?request_id=$id',
      );
      expect(s2, 200);
      expect(j2['status'], 'approved');
      final PairingPayload payload = PairingPayload.parse(
        j2['pairing_code']! as String,
      );
      expect(payload.hostId, identity.hostId);
      expect(payload.token, identity.plaintextToken);
      expect(payload.port, server.port);
    });

    test('拒绝 ⇒ denied（手机据此说「电脑上点了拒绝」）', () async {
      final String id = await requestPairing(server.pairRequests.issueCode());
      expect(server.pairRequests.deny(id), isTrue);
      final (int status, Map<String, Object?> json) = await call(
        'GET',
        '/api/pair/status?request_id=$id',
      );
      expect(status, 200);
      expect(json['status'], 'denied');
    });

    test('不认识的 request_id ⇒ 404（不按「最新一条」兜底）', () async {
      await requestPairing(server.pairRequests.issueCode());
      final (int status, Map<String, Object?> json) = await call(
        'GET',
        '/api/pair/status?request_id=0123456789abcdef',
      );
      expect(status, 404);
      expect('${json['error']}', contains('失效'));
    });

    test('请求体不是 JSON ⇒ 400，且日志里**不出现短码**（约束 5）', () async {
      final String code = server.pairRequests.issueCode();
      // ⚠️ 用「少一个右括号」而不是「数字没加引号」：后者是合法 JSON。
      // `jsonDecode` 抛的 `FormatException.toString()` 会**把整行源文本打出来**
      //（实测：`FormatException: Unexpected end of input (at character 17)` +
      // 下一行原文）—— 而这一行里就有短码。日志若记 `'$error'` 就泄了。
      final (int status, Map<String, Object?> json) = await call(
        'POST',
        '/api/pair/request',
        rawBody: '{"code":"$code"',
      );
      expect(status, 400);
      expect(json['error'], isNotNull);
      expect(internalErrors, isNotEmpty, reason: '内部错误仍要留痕');
      for (final String line in internalErrors) {
        expect(line.contains(code), isFalse, reason: '短码不许进日志：$line');
      }
      expect('${json['error']}'.contains(code), isFalse);
    });

    test('同一 IP 一分钟超过 10 次 ⇒ 429（先于码的判断）', () async {
      server.pairRequests.issueCode();
      int last = 0;
      Map<String, Object?> json = <String, Object?>{};
      for (int i = 0; i < PairRequests.maxRequestsPerIp; i++) {
        final (int status, Map<String, Object?> body) = await call(
          'POST',
          '/api/pair/request',
          body: <String, Object?>{'code': '999999', 'device_name': 'x'},
        );
        last = status;
        json = body;
      }
      expect(last, isNot(429), reason: '前 10 次不该被限流');
      final (int status, Map<String, Object?> body) = await call(
        'POST',
        '/api/pair/request',
        body: <String, Object?>{'code': '999999', 'device_name': 'x'},
      );
      expect(status, 429);
      expect('${body['error']}', contains('等一分钟'));
      expect(json, isNotNull);
    });
  });
}

/// 把一条推送回执渲染成 `entity_id: status (reason)`。
///
/// 刻意**不在字符串插值里逐处 `as Map` 强转** —— JSON 解出来是 `Object?`，
/// 在这里一次性转成 `Map<String, Object?>`，之后全是安全取值。
/// （原来的写法触发了 `unnecessary_cast`，而且同一表达式里连转四次。）
String receiptLine(Object? raw) {
  final Map<String, Object?> item = raw is Map
      ? Map<String, Object?>.from(raw)
      : <String, Object?>{};
  final Object? reason = item['reason'];
  return '${item['entity_id']}: ${item['status']}'
      '${reason == null ? '' : ' ($reason)'}';
}
