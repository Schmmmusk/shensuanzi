// SyncServer（`docs/sync_protocol.md`）—— 主机侧同步领域层。
//
// 覆盖：五类操作、白名单、幂等、乐观锁、拉取与游标。
// 核心主张：**落库一律走 RuleEngine**（纪律 9），同步层自己不写流水；
// **表名/列名必须先过白名单**（纪律 10）。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`（`test` 是 dev_dependency），
// 且 Windows 需要可用的 SQLite 原生库，见 `lib/sqlite_local.dart`。
import 'dart:convert';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';
import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late SyncServer server;

  setUp(() {
    resetClock();
    db = newMemoryDb();
    server = SyncServer(db);
  });

  tearDown(() => db.close());

  // ------------------------------------------------------------ 夹具

  /// 客户端会推的 document 主体 = **`toRow()` 去掉主机专属列**。
  ///
  /// 这条等式就是 wire 约定的核心（见 `sync_operation.dart` 的文档注释）：
  /// 测试里也照此构造，于是「wire = row」不再只是注释里的一句话。
  Map<String, Object?> wireDocument(Document d) => d.toRow()
    ..remove('paid_amount')
    ..remove('created_at')
    ..remove('updated_at');

  Document pending({
    required DocType type,
    String? partyId,
    String? accountId,
    int totalAmount = 0,
    String? refDocId,
  }) => Document(
    id: newId(),
    docNo: '${Document.pendingDocNoPrefix}abc123',
    docType: type,
    status: DocStatus.confirmed,
    partyId: partyId,
    accountId: accountId,
    totalAmount: totalAmount,
    refDocId: refDocId,
    occurredAt: now(),
    createdAt: now(),
    updatedAt: now(),
  );

  List<DocumentLine> oneLine(
    String docId,
    String productId,
    int qty,
    int price,
  ) => <DocumentLine>[
    DocumentLine.create(
      documentId: docId,
      productId: productId,
      quantity: qty,
      unitPrice: price,
    ),
  ];

  SyncOperation opCreateDocument(
    Document d, {
    List<DocumentLine> lines = const <DocumentLine>[],
    Object? immediatePayments,
    Object? allocations,
    Map<String, Object?>? document,
    String? entityId,
  }) => SyncOperation(
    entity: 'documents',
    entityId: entityId ?? d.id,
    operation: SyncOpType.createDocument,
    payload: <String, Object?>{
      'document': document ?? wireDocument(d),
      'lines': <Object?>[for (final DocumentLine line in lines) line.toRow()],
      if (immediatePayments != null) 'immediate_payments': immediatePayments,
      if (allocations != null) 'allocations': allocations,
    },
  );

  SyncOperation opMaster(
    String entity,
    String id,
    SyncOpType type, {
    Map<String, Object?> payload = const <String, Object?>{},
    int? baseVersion,
  }) => SyncOperation(
    entity: entity,
    entityId: id,
    operation: type,
    baseVersion: baseVersion,
    payload: <String, Object?>{'id': id, ...payload},
  );

  /// 经同步通道建主数据，返回 id
  String syncProduct({String code = 'P001', int costPrice = 0}) {
    final String id = newId();
    final SyncResponse response = server.handle(
      opMaster('products', id, SyncOpType.createMasterData, payload: {
        'code': code,
        'name': '商品-$code',
        'cost_price': costPrice,
      }),
      now: now(),
    );
    expect(response.status, SyncStatus.applied, reason: response.reason);
    return id;
  }

  String syncParty() {
    final String id = newId();
    final SyncResponse response = server.handle(
      opMaster('parties', id, SyncOpType.createMasterData, payload: {
        'name': '往来方',
      }),
      now: now(),
    );
    expect(response.status, SyncStatus.applied, reason: response.reason);
    return id;
  }

  String syncAccount({int initialBalance = 0}) {
    final String id = newId();
    final SyncResponse response = server.handle(
      opMaster('accounts', id, SyncOpType.createMasterData, payload: {
        'name': '现金',
        'type': 'cash',
        'initial_balance': initialBalance,
      }),
      now: now(),
    );
    expect(response.status, SyncStatus.applied, reason: response.reason);
    return id;
  }

  void syncPurchase(String productId, String partyId, int qty, int unitPrice) {
    final Document d = pending(
      type: DocType.purchase,
      partyId: partyId,
      totalAmount: qty * unitPrice,
    );
    final SyncResponse response = server.handle(
      opCreateDocument(d, lines: oneLine(d.id, productId, qty, unitPrice)),
      now: now(),
    );
    expect(response.status, SyncStatus.applied, reason: response.reason);
  }

  int countOf(String table) =>
      db.raw.select('SELECT COUNT(*) AS c FROM $table').first['c']! as int;

  // ============================================================ createDocument

  group('createDocument', () {
    test('applied，且流水由 RuleEngine 写入（同步层自己不写）', () {
      final String p = syncProduct();
      final String party = syncParty();

      final Document purchase = pending(
        type: DocType.purchase,
        partyId: party,
        totalAmount: 1000,
      );
      final SyncResponse response = server.handle(
        opCreateDocument(purchase, lines: oneLine(purchase.id, p, 10, 100)),
        now: now(),
      );

      expect(response.status, SyncStatus.applied, reason: response.reason);

      final Document saved = DocumentDao(db).findById(purchase.id)!;
      expect(saved.docNo, isNot(startsWith(Document.pendingDocNoPrefix)),
          reason: '主机分配了正式单号');
      expect(countOf('stock_ledger'), 1);
      expect(countOf('party_ledger'), 1);
      expect(StockLedgerDao(db).stockOf(p), 10);
    });

    test('幂等：同 entity_id 推两次 → already_exists，且不产生重复流水', () {
      final String p = syncProduct();
      final String party = syncParty();
      final Document purchase = pending(
        type: DocType.purchase,
        partyId: party,
        totalAmount: 1000,
      );
      final SyncOperation op = opCreateDocument(
        purchase,
        lines: oneLine(purchase.id, p, 10, 100),
      );

      expect(server.handle(op, now: now()).status, SyncStatus.applied);
      final SyncResponse second = server.handle(op, now: now());

      expect(second.status, SyncStatus.alreadyExists);
      expect(countOf('stock_ledger'), 1, reason: '没有重复流水');
      expect(StockLedgerDao(db).stockOf(p), 10);
    });

    test('落库走 RuleEngine：无 party_id 的赊账销售被规则拒绝', () {
      final String p = syncProduct();
      final Document sale = pending(
        type: DocType.sale,
        totalAmount: 500,
      );
      final SyncResponse response = server.handle(
        opCreateDocument(sale, lines: oneLine(sale.id, p, 1, 500)),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('party_id'));
      expect(DocumentDao(db).findById(sale.id), isNull);
    });

    test('immediate_payments → 主机自动生成 receipt 单', () {
      final String p = syncProduct();
      final String party = syncParty();
      final String account = syncAccount();
      final Document sale = pending(
        type: DocType.sale,
        partyId: party,
        totalAmount: 500,
      );
      final SyncResponse response = server.handle(
        opCreateDocument(
          sale,
          lines: oneLine(sale.id, p, 1, 500),
          immediatePayments: <Map<String, Object?>>[
            <String, Object?>{'account_id': account, 'amount': 500},
          ],
        ),
        now: now(),
      );

      expect(response.status, SyncStatus.applied, reason: response.reason);
      expect(
        db.raw
            .select("SELECT COUNT(*) AS c FROM documents WHERE doc_type = 'receipt'")
            .first['c'],
        1,
      );
      expect(DocumentDao(db).findById(sale.id)!.paidAmount, 500);
    });

    test('immediate_payments 与 allocations 同时非空 → rejected', () {
      final String p = syncProduct();
      final String party = syncParty();
      final String account = syncAccount();
      final Document sale = pending(
        type: DocType.sale,
        partyId: party,
        totalAmount: 500,
      );
      final SyncResponse response = server.handle(
        opCreateDocument(
          sale,
          lines: oneLine(sale.id, p, 1, 500),
          immediatePayments: <Map<String, Object?>>[
            <String, Object?>{'account_id': account, 'amount': 500},
          ],
          allocations: <Map<String, Object?>>[
            <String, Object?>{'target_doc_id': null, 'amount': 500},
          ],
        ),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('互斥'));
    });

    test('entity_id 与 payload.document.id 不一致 → rejected', () {
      final String p = syncProduct();
      final Document sale = pending(type: DocType.sale, totalAmount: 100);
      final SyncResponse response = server.handle(
        opCreateDocument(
          sale,
          lines: oneLine(sale.id, p, 1, 100),
          entityId: newId(), // 故意不一致
        ),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('幂等键'));
    });

    test('缺 payload.document → rejected', () {
      final SyncResponse response = server.handle(
        const SyncOperation(
          entity: 'documents',
          entityId: 'd-1',
          operation: SyncOpType.createDocument,
          payload: <String, Object?>{},
        ),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('缺少 payload.document'));
    });

    test('payload 含未知顶层字段 → rejected', () {
      final SyncResponse response = server.handle(
        const SyncOperation(
          entity: 'documents',
          entityId: 'd-1',
          operation: SyncOpType.createDocument,
          payload: <String, Object?>{'document': null, 'lines_': <Object?>[]},
        ),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('未知字段'));
    });

    test('document 含主机专属列（created_at）→ rejected', () {
      final String p = syncProduct();
      final Document sale = pending(type: DocType.sale, totalAmount: 100);
      final Map<String, Object?> document = wireDocument(sale)
        ..['created_at'] = 1;
      final SyncResponse response = server.handle(
        opCreateDocument(
          sale,
          lines: oneLine(sale.id, p, 1, 100),
          document: document,
        ),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('不可写列'));
      expect(response.reason, contains('created_at'));
    });

    test('document 缺必填列 → rejected，且原因点出列名', () {
      final String p = syncProduct();
      final Document sale = pending(type: DocType.sale, totalAmount: 100);
      final Map<String, Object?> document = wireDocument(sale)
        ..remove('doc_type');
      final SyncResponse response = server.handle(
        opCreateDocument(
          sale,
          lines: oneLine(sale.id, p, 1, 100),
          document: document,
        ),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('doc_type'), reason: response.reason);
    });

    test('entity 不是 documents → rejected', () {
      final SyncResponse response = server.handle(
        const SyncOperation(
          entity: 'products',
          entityId: 'p-1',
          operation: SyncOpType.createDocument,
        ),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('必须是 documents'));
    });
  });

  // ============================================================ 主数据

  group('createMasterData', () {
    test('applied，created_at / updated_at / sync_version 由主机写', () {
      final int before = now();
      final String id = syncProduct(code: 'P900');

      final Product saved = ProductDao(db).findById(id)!;
      expect(saved.code, 'P900');
      expect(saved.syncVersion, 0);
      expect(saved.createdAt, greaterThanOrEqualTo(before));
    });

    test('幂等：同 id 两次 → already_exists', () {
      final String id = newId();
      final SyncOperation op = opMaster('products', id, SyncOpType.createMasterData, payload: {
        'code': 'P901',
        'name': '商品',
      });
      expect(server.handle(op, now: now()).status, SyncStatus.applied);
      expect(server.handle(op, now: now()).status, SyncStatus.alreadyExists);
      expect(countOf('products'), 1);
    });

    test('含主机专属列（sync_version）→ rejected', () {
      final SyncResponse response = server.handle(
        opMaster('products', newId(), SyncOpType.createMasterData, payload: {
          'code': 'P902',
          'name': '商品',
          'sync_version': 5,
        }),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('sync_version'));
    });

    test('未知列 → rejected', () {
      final SyncResponse response = server.handle(
        opMaster('products', newId(), SyncOpType.createMasterData, payload: {
          'code': 'P903',
          'name': '商品',
          'nope': 1,
        }),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('nope'));
    });

    test('bool 值被拒（wire 约定布尔用 1/0）', () {
      final SyncResponse response = server.handle(
        opMaster('products', newId(), SyncOpType.createMasterData, payload: {
          'code': 'P904',
          'name': '商品',
          'is_active': true,
        }),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('1 / 0'));
    });

    test('target 是 documents → rejected（只支持主数据表）', () {
      final SyncResponse response = server.handle(
        opMaster('documents', newId(), SyncOpType.createMasterData),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('只支持主数据表'));
    });
  });

  group('updateMasterData', () {
    test('base_version 匹配 → applied，sync_version + 1', () {
      final String id = syncProduct(code: 'P910');

      final SyncResponse response = server.handle(
        opMaster('products', id, SyncOpType.updateMasterData, baseVersion: 0, payload: {
          'sell_price': 1234,
        }),
        now: now(),
      );

      expect(response.status, SyncStatus.applied, reason: response.reason);
      final Product saved = ProductDao(db).findById(id)!;
      expect(saved.sellPrice, 1234);
      expect(saved.syncVersion, 1);
    });

    test('base_version 落后 → conflict，并回传 server_state', () {
      final String id = syncProduct(code: 'P911');
      // 先成功改一次 → 主机版本变成 1
      server.handle(
        opMaster('products', id, SyncOpType.updateMasterData, baseVersion: 0, payload: {
          'sell_price': 100,
        }),
        now: now(),
      );

      // 客户端仍以为版本是 0
      final SyncResponse response = server.handle(
        opMaster('products', id, SyncOpType.updateMasterData, baseVersion: 0, payload: {
          'sell_price': 999,
        }),
        now: now(),
      );

      expect(response.status, SyncStatus.conflict);
      expect(response.serverState, isNotNull);
      expect(response.serverState!['sync_version'], 1);
      expect(response.serverState!['sell_price'], 100, reason: '主机赢');
      expect(ProductDao(db).findById(id)!.sellPrice, 100, reason: '未被覆盖');
    });

    test('缺 base_version → rejected', () {
      final String id = syncProduct(code: 'P912');
      final SyncResponse response = server.handle(
        opMaster('products', id, SyncOpType.updateMasterData, payload: {
          'sell_price': 1,
        }),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('base_version'));
    });

    test('目标不存在 → rejected', () {
      final SyncResponse response = server.handle(
        opMaster('products', newId(), SyncOpType.updateMasterData, baseVersion: 0, payload: {
          'sell_price': 1,
        }),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('不存在'));
    });
  });

  group('deleteMasterData', () {
    test('applied，是软删（is_active = 0），行还在', () {
      final String id = syncProduct(code: 'P920');

      final SyncResponse response = server.handle(
        opMaster('products', id, SyncOpType.deleteMasterData),
        now: now(),
      );

      expect(response.status, SyncStatus.applied, reason: response.reason);
      expect(ProductDao(db).findById(id)!.isActive, isFalse);
      expect(countOf('products'), 1, reason: '从不 DELETE');
    });

    test('已删 → already_exists（幂等）', () {
      final String id = syncProduct(code: 'P921');
      final SyncOperation op = opMaster('products', id, SyncOpType.deleteMasterData);

      expect(server.handle(op, now: now()).status, SyncStatus.applied);
      expect(server.handle(op, now: now()).status, SyncStatus.alreadyExists);
      expect(ProductDao(db).findById(id)!.syncVersion, 1, reason: '不再 +1');
    });

    test('payload 含 id 以外的字段 → rejected', () {
      final String id = syncProduct(code: 'P922');
      final SyncResponse response = server.handle(
        opMaster('products', id, SyncOpType.deleteMasterData, payload: {
          'name': '改个名',
        }),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('只允许 id'));
      expect(ProductDao(db).findById(id)!.isActive, isTrue);
    });

    test('目标不存在 → rejected', () {
      final SyncResponse response = server.handle(
        opMaster('products', newId(), SyncOpType.deleteMasterData),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('不存在'));
    });
  });

  // ============================================================ documentAction

  group('documentAction（v1 不落地）', () {
    test('一律 rejected + action_not_implemented', () {
      final SyncResponse response = server.handle(
        const SyncOperation(
          entity: 'documents',
          entityId: 'd-1',
          operation: SyncOpType.documentAction,
          payload: <String, Object?>{'action': 'mark_delivered'},
        ),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('action_not_implemented'));
    });
  });

  // ============================================================ 白名单

  group('白名单（纪律 10）', () {
    test('业务表（stock_ledger）不在可写白名单 → rejected', () {
      final SyncResponse response = server.handle(
        const SyncOperation(
          entity: 'stock_ledger',
          entityId: 's-1',
          operation: SyncOpType.createMasterData,
        ),
        now: now(),
      );

      expect(response.status, SyncStatus.rejected);
      expect(response.reason, contains('白名单'));
    });

    test('任意表名都进不来（schemas / sqlite_master）', () {
      for (final String entity in <String>['sqlite_master', 'document_lines', 'x']) {
        final SyncResponse response = server.handle(
          SyncOperation(
            entity: entity,
            entityId: 'i-1',
            operation: SyncOpType.createMasterData,
          ),
          now: now(),
        );
        expect(response.status, SyncStatus.rejected, reason: entity);
      }
    });
  });

  // ============================================================ 批量

  group('push 批量', () {
    test('逐条独立：一条被拒不拖累其它条目', () {
      final String p = newId();
      final String party = syncParty();
      final Document good = pending(
        type: DocType.purchase,
        partyId: party,
        totalAmount: 100,
      );

      final List<SyncResponse> results = server.push(<SyncOperation>[
        opMaster('products', p, SyncOpType.createMasterData, payload: {
          'code': 'P930',
          'name': '商品',
        }),
        // 中间夹一条必然失败的
        const SyncOperation(
          entity: 'nope',
          entityId: 'bad',
          operation: SyncOpType.createMasterData,
        ),
        opCreateDocument(good, lines: oneLine(good.id, p, 1, 100)),
      ], now: now());

      expect(results, hasLength(3));
      expect(results[0].status, SyncStatus.applied);
      expect(results[1].status, SyncStatus.rejected);
      expect(results[2].status, SyncStatus.applied, reason: results[2].reason);
      expect(countOf('documents'), 1);
    });

    test('回执按 entity_id 配对（顺序无关）', () {
      final String a = newId();
      final String b = newId();
      final List<SyncResponse> results = server.push(<SyncOperation>[
        opMaster('products', a, SyncOpType.createMasterData, payload: {
          'code': 'PA',
          'name': 'A',
        }),
        opMaster('products', b, SyncOpType.createMasterData, payload: {
          'code': 'PB',
          'name': 'B',
        }),
      ], now: now());

      expect(<String>{for (final SyncResponse r in results) r.entityId}, <String>{a, b});
    });
  });

  // ============================================================ 拉取

  group('pull', () {
    test('空库 → 9 个实体都空，8 个游标原样返回', () {
      final SyncPullResult result = server.pull();

      // 实体清单只从 SyncPullResult.entityNames 取 —— 加实体时改那儿一处，
      // 「拉了几个」与「拉的是哪几个」不会各说各话
      expect(result.entities.keys.toSet(), SyncPullResult.entityNames.toSet());
      expect(SyncPullResult.entityNames, hasLength(9));
      for (final String entity in SyncPullResult.entityNames) {
        expect(result.entities[entity], isEmpty, reason: entity);
      }

      expect(result.nextCursors.keys.toSet(), SyncCursorKeys.all.toSet());
      // 流水表：整数字符串游标
      for (final String key in <String>[
        SyncCursorKeys.stock,
        SyncCursorKeys.money,
        SyncCursorKeys.party,
        SyncCursorKeys.settle,
      ]) {
        expect(result.nextCursors[key], '0', reason: key);
      }
      // documents 与主数据：复合游标
      for (final String key in <String>[
        SyncCursorKeys.doc,
        SyncCursorKeys.products,
        SyncCursorKeys.parties,
        SyncCursorKeys.accounts,
      ]) {
        expect(result.nextCursors[key], '0|', reason: key);
      }
    });

    test('拉到的行就是 wire 形态（列名 = 数据库列名）', () {
      final String p = syncProduct(code: 'P940');
      final String party = syncParty();
      syncPurchase(p, party, 4, 100);

      final SyncPullResult result = server.pull();
      final Map<String, Object?> row = result.entities['stock_ledger']!.single;

      expect(row['product_id'], p);
      expect(row['quantity'], 4);
      expect(row['total_cost'], 400);
      expect(row['seq_no'], 1);
      expect(row.containsKey('unit_cost'), isTrue);
    });

    test('流水游标是 seq_no，取回 next 后再拉为空（增量）', () {
      final String p = syncProduct(code: 'P941');
      final String party = syncParty();
      syncPurchase(p, party, 3, 100);

      final SyncPullResult first = server.pull();
      expect(first.countOf('stock_ledger'), 1);
      expect(first.nextCursors[SyncCursorKeys.stock], '1');

      final SyncPullResult second = server.pull(
        stockSince: first.nextCursors[SyncCursorKeys.stock]!,
      );
      expect(second.countOf('stock_ledger'), 0, reason: '没有新流水');
      expect(second.nextCursors[SyncCursorKeys.stock], '1');
    });

    test('documents 游标是 "<created_at>|<id>"，与 §七 的排序一致', () {
      final String p = syncProduct(code: 'P942');
      final String party = syncParty();
      syncPurchase(p, party, 1, 100);

      final SyncPullResult result = server.pull();
      final String cursor = result.nextCursors[SyncCursorKeys.doc]!;

      expect(cursor, contains('|'));
      final SyncCursor parsed = SyncCursor.parse(cursor);
      final Map<String, Object?> last = result.entities['documents']!.last;
      expect(parsed.stamp, last['created_at']);
      expect(parsed.id, last['id']);
    });

    test('documents 增量：next 之后不再返回同一行', () {
      final String p = syncProduct(code: 'P943');
      final String party = syncParty();
      syncPurchase(p, party, 1, 100);

      final SyncPullResult first = server.pull();
      expect(first.countOf('documents'), 1);

      final SyncPullResult second = server.pull(
        docSince: first.nextCursors[SyncCursorKeys.doc]!,
      );
      expect(second.countOf('documents'), 0);
    });

    test('limit 生效，且游标保证推进（同一 created_at 的多行不丢也不重复）', () {
      final String p = syncProduct(code: 'P944');
      final String party = syncParty();

      // 连开 3 张单 —— 主单 created_at 都是「主机收到的 now」，
      // 这里刻意用一个固定 now，制造同一毫秒多行
      final int stamp = now();
      for (int i = 0; i < 3; i++) {
        final Document d = pending(
          type: DocType.purchase,
          partyId: party,
          totalAmount: 100,
        );
        final SyncResponse response = server.handle(
          opCreateDocument(d, lines: oneLine(d.id, p, 1, 100)),
          now: stamp,
        );
        expect(response.status, SyncStatus.applied, reason: response.reason);
      }

      final Set<String> seen = <String>{};
      String cursor = '';
      for (int page = 0; page < 10; page++) {
        final SyncPullResult result = server.pull(docSince: cursor, limit: 1);
        final List<Map<String, Object?>> rows = result.entities['documents']!;
        if (rows.isEmpty) break;
        seen.add(rows.single['id']! as String);
        final String next = result.nextCursors[SyncCursorKeys.doc]!;
        expect(next, isNot(cursor), reason: '游标必须推进，否则会死循环');
        cursor = next;
      }
      expect(seen, hasLength(3), reason: '同一 created_at 的 3 行都被取到且不重复');
    });

    test('游标格式错误 → 抛 FormatException（HTTP 层应映射成 400）', () {
      expect(() => server.pull(docSince: 'not-a-cursor'), throwsFormatException);
      expect(() => server.pull(stockSince: 'x'), throwsFormatException);
    });

    test('document_lines 随主单同页返回，且没有 line_since 游标', () {
      final String p = syncProduct(code: 'P945');
      final String party = syncParty();
      syncPurchase(p, party, 2, 100);

      final SyncPullResult result = server.pull();

      expect(result.countOf('documents'), 1);
      expect(result.countOf('document_lines'), 1, reason: '明细随主单走');
      expect(
        result.entities['document_lines']!.single['document_id'],
        result.entities['documents']!.single['id'],
      );
      expect(
        result.nextCursors.keys.toSet(),
        <String>{
          SyncCursorKeys.stock,
          SyncCursorKeys.money,
          SyncCursorKeys.party,
          SyncCursorKeys.settle,
          SyncCursorKeys.doc,
          SyncCursorKeys.products,
          SyncCursorKeys.parties,
          SyncCursorKeys.accounts,
        },
        reason: '明细没有独立游标 —— §8.2 的 doc_since 已经覆盖它',
      );

      final SyncPullResult next = server.pull(
        docSince: result.nextCursors[SyncCursorKeys.doc]!,
      );
      expect(next.countOf('document_lines'), 0, reason: '明细不会重复出现');
    });

    test('明细不按 limit 截断：limit=1 时该主单的 3 条明细都在', () {
      final String p = syncProduct(code: 'P946');
      final String party = syncParty();
      final Document purchase = pending(
        type: DocType.purchase,
        partyId: party,
        totalAmount: 300,
      );

      final SyncResponse response = server.handle(
        opCreateDocument(purchase, lines: <DocumentLine>[
          DocumentLine.create(
            documentId: purchase.id,
            productId: p,
            quantity: 1,
            unitPrice: 100,
          ),
          DocumentLine.create(
            documentId: purchase.id,
            productId: p,
            quantity: 1,
            unitPrice: 100,
          ),
          DocumentLine.create(
            documentId: purchase.id,
            productId: p,
            quantity: 1,
            unitPrice: 100,
          ),
        ]),
        now: now(),
      );
      expect(response.status, SyncStatus.applied, reason: response.reason);

      final SyncPullResult result = server.pull(limit: 1);
      expect(result.countOf('documents'), 1);
      expect(
        result.countOf('document_lines'),
        3,
        reason: '截断明细会造出「有主单但明细不全」的镜像',
      );
    });

    // 「不按 limit 截断」**不等于**「可以越过本页主单的边界」：
    // 明细必须恰好是本页那批主单的明细。修复前明细查询没有 `LIMIT`，
    // 于是每页都带上后面所有主单的明细（第 1 页就返回全量明细）。
    test('明细不越过本页主单的边界：limit=1 时不含后面主单的明细', () {
      final String p = syncProduct(code: 'P947');
      final String party = syncParty();
      for (int i = 0; i < 3; i++) {
        syncPurchase(p, party, 1, 100);
      }

      final SyncPullResult result = server.pull(limit: 1);

      expect(result.countOf('documents'), 1);
      expect(
        result.countOf('document_lines'),
        1,
        reason: 'limit=1 只该返回那 1 张主单的明细，不是全部 3 条',
      );
      expect(
        result.entities['document_lines']!.single['document_id'],
        result.entities['documents']!.single['id'],
        reason: '明细的 document_id 必须指向本页返回的主单',
      );
    });

    // ---------------------------------------------- 主数据（R-13 方案 A）

    test('主数据随 pull 返回，游标是 "<updated_at>|<id>"，且返回全部列', () {
      final String p = syncProduct(code: 'P950', costPrice: 100);

      final SyncPullResult result = server.pull();
      final Map<String, Object?> row = result.entities['products']!.single;

      expect(row['id'], p);
      expect(
        row['sync_version'],
        0,
        reason: '必须给 sync_version —— 客户端下次 update 要拿它当 base_version',
      );
      expect(row.containsKey('updated_at'), isTrue, reason: '游标列必须在响应里');

      final SyncCursor parsed = SyncCursor.parse(
        result.nextCursors[SyncCursorKeys.products]!,
      );
      expect(parsed.stamp, row['updated_at']);
      expect(parsed.id, row['id']);
    });

    test('A 改了价格 → B 带游标 pull 就能拿到新价（R-13 的核心场景）', () {
      final String p = syncProduct(code: 'P951', costPrice: 100);

      // B 首次全量拉取，记下游标
      final SyncPullResult bFirst = server.pull();
      expect(bFirst.entities['products']!.single['cost_price'], 100);

      // A 改价
      final SyncResponse update = server.handle(
        opMaster(
          'products',
          p,
          SyncOpType.updateMasterData,
          payload: <String, Object?>{'cost_price': 120},
          baseVersion: 0,
        ),
        now: now(),
      );
      expect(update.status, SyncStatus.applied, reason: update.reason);

      // B 增量拉取
      final SyncPullResult bSecond = server.pull(
        productsSince: bFirst.nextCursors[SyncCursorKeys.products]!,
      );
      expect(bSecond.entities['products']!, hasLength(1), reason: '改动必须可见');
      final Map<String, Object?> changed = bSecond.entities['products']!.single;
      expect(changed['cost_price'], 120);
      expect(changed['sync_version'], 1, reason: '乐观锁计数 +1');
      expect(changed['updated_at'], greaterThan(bFirst.entities['products']!.single['updated_at'] as int));
    });

    test('未改动的主数据不会重复出现在增量页里', () {
      final String kept = syncProduct(code: 'P952');
      final SyncPullResult first = server.pull();
      final String cursor = first.nextCursors[SyncCursorKeys.products]!;

      final SyncPullResult second = server.pull(productsSince: cursor);
      expect(second.entities['products'], isEmpty, reason: '没有改动就没有行');
      expect(second.nextCursors[SyncCursorKeys.products], cursor);
      expect(kept, isNotEmpty);
    });

    test('软删的行照常返回（客户端据此在本地标记删除）', () {
      final String p = syncProduct(code: 'P953');
      final SyncPullResult before = server.pull();

      final SyncResponse deleted = server.handle(
        opMaster('products', p, SyncOpType.deleteMasterData),
        now: now(),
      );
      expect(deleted.status, SyncStatus.applied, reason: deleted.reason);

      final SyncPullResult after = server.pull(
        productsSince: before.nextCursors[SyncCursorKeys.products]!,
      );
      expect(after.entities['products']!, hasLength(1), reason: '软删必须可见，否则客户端永远不知道');
      expect(after.entities['products']!.single['is_active'], 0);
    });

    test('从未见过该商品的新客户端：全量首拉就能拿到 is_active = 0 的行', () {
      final String p = syncProduct(code: 'P954');
      server.handle(
        opMaster('products', p, SyncOpType.deleteMasterData),
        now: now(),
      );

      final SyncPullResult fresh = server.pull(); // 无游标 = 全量
      expect(fresh.entities['products']!, hasLength(1));
      expect(fresh.entities['products']!.single['is_active'], 0);
    });

    test('同一毫秒内多次更新 → (updated_at, id) 游标不丢行、不重复、必推进', () {
      final int stamp = now();
      const int count = 3;

      for (int i = 0; i < count; i++) {
        final String id = newId();
        final SyncResponse response = server.handle(
          opMaster('products', id, SyncOpType.createMasterData, payload: <String, Object?>{
            'code': 'P96$i',
            'name': '商品$i',
          }),
          now: stamp, // ← 刻意同一毫秒
        );
        expect(response.status, SyncStatus.applied, reason: response.reason);
      }

      final Set<String> seen = <String>{};
      String cursor = '';
      for (int page = 0; page < 10; page++) {
        final SyncPullResult result = server.pull(
          productsSince: cursor,
          limit: 1,
        );
        final List<Map<String, Object?>> rows = result.entities['products']!;
        if (rows.isEmpty) break;
        seen.add(rows.single['id']! as String);
        final String next = result.nextCursors[SyncCursorKeys.products]!;
        expect(next, isNot(cursor), reason: '游标必须推进，否则会死循环');
        cursor = next;
      }
      expect(seen, hasLength(count), reason: '同一 updated_at 的行都被取到且不重复');
    });

    test('主数据游标格式错误 → 抛 FormatException', () {
      expect(
        () => server.pull(productsSince: 'oops'),
        throwsFormatException,
      );
    });
  });

  // ============================================================ JSON 契约

  group('wire JSON 编解码', () {
    test('SyncOperation 往返一致', () {
      final SyncOperation original = SyncOperation(
        entity: 'documents',
        entityId: 'd-1',
        operation: SyncOpType.createDocument,
        payload: <String, Object?>{
          'document': <String, Object?>{'id': 'd-1', 'total_amount': 100},
          'lines': <Object?>[
            <String, Object?>{'quantity': 1},
          ],
        },
      );

      final SyncOperation decoded = SyncOperation.fromJson(
        Map<String, Object?>.from(
          jsonDecode(jsonEncode(original.toJson())) as Map<Object?, Object?>,
        ),
      );

      expect(decoded.entity, original.entity);
      expect(decoded.entityId, original.entityId);
      expect(decoded.operation, original.operation);
      expect(decoded.payload['document'], original.payload['document']);
    });

    test('SyncResponse 序列化含 status / reason / server_state', () {
      const SyncResponse rejected = SyncResponse(
        entityId: 'd-1',
        status: SyncStatus.rejected,
        reason: 'boom',
      );
      expect(rejected.toJson(), <String, Object?>{
        'entity_id': 'd-1',
        'status': 'rejected',
        'reason': 'boom',
      });

      const SyncResponse conflict = SyncResponse(
        entityId: 'p-1',
        status: SyncStatus.conflict,
        serverState: <String, Object?>{'sync_version': 2},
      );
      expect(conflict.toJson()['server_state'], <String, Object?>{'sync_version': 2});
      expect(conflict.toJson().containsKey('reason'), isFalse);
    });

    test('SyncPullResult.toJson 把实体平铺并附 next_cursors', () {
      final SyncPullResult result = server.pull();
      final Map<String, Object?> json = result.toJson();

      expect(json.containsKey('documents'), isTrue);
      expect(json.containsKey('next_cursors'), isTrue);
    });
  });
}
