// SyncServer 自检：`dart run tool/selfcheck_sync.dart`
//
// 与 `test/sync_server_test.dart` 断言等价 —— 本机 `dart test` 无法编译测试文件
// （`test_core` 编译内核时要用 `frontend_server` 子进程，见 `docs/testing.md` §零）。
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**，失败可复现。
// 每个场景一个独立内存库。

import 'dart:convert';
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_local.dart';

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

int _clock = 1700000000000;
int now() => _clock++;

bool throws(void Function() body) {
  try {
    body();
    return false;
  } catch (_) {
    return true;
  }
}

late Db db;
late SyncServer server;

void freshDb() {
  db = Db.openInMemory();
  server = SyncServer(db);
}

int countOf(String table) =>
    db.raw.select('SELECT COUNT(*) AS c FROM $table').first['c']! as int;

// ---------------------------------------------------------------- 夹具

/// 客户端会推的 document 主体 = **`toRow()` 去掉主机专属列**
Map<String, Object?> wireDocument(Document d) => d.toRow()
  ..remove('paid_amount')
  ..remove('created_at')
  ..remove('updated_at');

Document pending({
  required DocType type,
  String? partyId,
  String? accountId,
  int totalAmount = 0,
}) => Document(
  id: newId(),
  docNo: '${Document.pendingDocNoPrefix}abc123',
  docType: type,
  status: DocStatus.confirmed,
  partyId: partyId,
  accountId: accountId,
  totalAmount: totalAmount,
  occurredAt: now(),
  createdAt: now(),
  updatedAt: now(),
);

List<DocumentLine> oneLine(String docId, String productId, int qty, int price) =>
    <DocumentLine>[
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

String syncProduct({String code = 'P001', int costPrice = 0}) {
  final String id = newId();
  final SyncResponse r = server.handle(
    opMaster('products', id, SyncOpType.createMasterData, payload: {
      'code': code,
      'name': '商品-$code',
      'cost_price': costPrice,
    }),
    now: now(),
  );
  if (r.status != SyncStatus.applied) {
    stderr.writeln('夹具失败：syncProduct → ${r.reason}');
    exit(2);
  }
  return id;
}

String syncParty() {
  final String id = newId();
  final SyncResponse r = server.handle(
    opMaster('parties', id, SyncOpType.createMasterData, payload: {
      'name': '往来方',
    }),
    now: now(),
  );
  if (r.status != SyncStatus.applied) {
    stderr.writeln('夹具失败：syncParty → ${r.reason}');
    exit(2);
  }
  return id;
}

String syncAccount() {
  final String id = newId();
  final SyncResponse r = server.handle(
    opMaster('accounts', id, SyncOpType.createMasterData, payload: {
      'name': '现金',
      'type': 'cash',
    }),
    now: now(),
  );
  if (r.status != SyncStatus.applied) {
    stderr.writeln('夹具失败：syncAccount → ${r.reason}');
    exit(2);
  }
  return id;
}

void syncPurchase(String productId, String partyId, int qty, int unitPrice) {
  final Document d = pending(
    type: DocType.purchase,
    partyId: partyId,
    totalAmount: qty * unitPrice,
  );
  final SyncResponse r = server.handle(
    opCreateDocument(d, lines: oneLine(d.id, productId, qty, unitPrice)),
    now: now(),
  );
  if (r.status != SyncStatus.applied) {
    stderr.writeln('夹具失败：syncPurchase → ${r.reason}');
    exit(2);
  }
}

void main() {
  useLocalSqlite();

  // ============================================================ createDocument
  section('createDocument');
  {
    freshDb();
    final String p = syncProduct(code: 'PC1');
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

    final SyncResponse first = server.handle(op, now: now());
    check('applied', first.status == SyncStatus.applied, '${first.reason}');
    check('主机分配了正式单号',
        !DocumentDao(db).findById(purchase.id)!.docNo.startsWith(Document.pendingDocNoPrefix));
    check('RuleEngine 写了库存流水', countOf('stock_ledger') == 1, '${countOf('stock_ledger')}');
    check('RuleEngine 写了往来流水', countOf('party_ledger') == 1);
    check('库存 = 10', StockLedgerDao(db).stockOf(p) == 10);
    check('回执 entity_id 与推送一致', first.entityId == purchase.id);

    final SyncResponse second = server.handle(op, now: now());
    check('幂等：第二次 already_exists',
        second.status == SyncStatus.alreadyExists, '${second.status}');
    check('幂等：没有重复流水', countOf('stock_ledger') == 1);
    check('幂等：库存未翻倍', StockLedgerDao(db).stockOf(p) == 10);
    db.close();
  }

  section('createDocument · 落库走 RuleEngine');
  {
    freshDb();
    final String p = syncProduct(code: 'PC2');
    final Document sale = pending(type: DocType.sale, totalAmount: 500);

    final SyncResponse r = server.handle(
      opCreateDocument(sale, lines: oneLine(sale.id, p, 1, 500)),
      now: now(),
    );
    check('无 party_id 的赊账销售 → rejected', r.status == SyncStatus.rejected);
    check('拒绝原因来自规则引擎（party_id）',
        r.reason?.contains('party_id') ?? false, '${r.reason}');
    check('整单回滚：单据未落库', DocumentDao(db).findById(sale.id) == null);
    check('整单回滚：没有流水', countOf('stock_ledger') == 0);
    db.close();
  }

  section('createDocument · 立即收付款');
  {
    freshDb();
    final String p = syncProduct(code: 'PC3');
    final String party = syncParty();
    final String account = syncAccount();
    final Document sale = pending(
      type: DocType.sale,
      partyId: party,
      totalAmount: 500,
    );

    final SyncResponse r = server.handle(
      opCreateDocument(
        sale,
        lines: oneLine(sale.id, p, 1, 500),
        immediatePayments: <Map<String, Object?>>[
          <String, Object?>{'account_id': account, 'amount': 500},
        ],
      ),
      now: now(),
    );
    check('applied', r.status == SyncStatus.applied, '${r.reason}');
    check('主机自动生成 receipt 单',
        db.raw
                .select("SELECT COUNT(*) AS c FROM documents WHERE doc_type = 'receipt'")
                .first['c'] ==
            1);
    check('主单 paid_amount = 500',
        DocumentDao(db).findById(sale.id)!.paidAmount == 500);
    check('主单 status = settled',
        DocumentDao(db).findById(sale.id)!.status == DocStatus.settled);

    final SyncResponse both = server.handle(
      opCreateDocument(
        pending(type: DocType.sale, partyId: party, totalAmount: 100),
        lines: oneLine(newId(), p, 1, 100),
        immediatePayments: <Map<String, Object?>>[
          <String, Object?>{'account_id': account, 'amount': 100},
        ],
        allocations: <Map<String, Object?>>[
          <String, Object?>{'target_doc_id': null, 'amount': 100},
        ],
      ),
      now: now(),
    );
    check('immediate_payments 与 allocations 互斥 → rejected',
        both.status == SyncStatus.rejected);
    check('互斥原因可读', both.reason?.contains('互斥') ?? false, '${both.reason}');
    db.close();
  }

  section('createDocument · 契约校验');
  {
    freshDb();
    final String p = syncProduct(code: 'PC4');
    final Document sale = pending(type: DocType.sale, totalAmount: 100);

    final SyncResponse idMismatch = server.handle(
      opCreateDocument(
        sale,
        lines: oneLine(sale.id, p, 1, 100),
        entityId: newId(),
      ),
      now: now(),
    );
    check('entity_id ≠ document.id → rejected',
        idMismatch.status == SyncStatus.rejected);
    check('原因指向幂等键', idMismatch.reason?.contains('幂等键') ?? false,
        '${idMismatch.reason}');

    final SyncResponse noDocument = server.handle(
      const SyncOperation(
        entity: 'documents',
        entityId: 'd-1',
        operation: SyncOpType.createDocument,
        payload: <String, Object?>{},
      ),
      now: now(),
    );
    check('缺 payload.document → rejected',
        noDocument.reason?.contains('缺少 payload.document') ?? false,
        '${noDocument.reason}');

    final SyncResponse unknownField = server.handle(
      const SyncOperation(
        entity: 'documents',
        entityId: 'd-1',
        operation: SyncOpType.createDocument,
        payload: <String, Object?>{'document': null, 'lines_': <Object?>[]},
      ),
      now: now(),
    );
    check('未知顶层字段 → rejected',
        unknownField.reason?.contains('未知字段') ?? false, '${unknownField.reason}');

    final SyncResponse hostOnly = server.handle(
      opCreateDocument(
        sale,
        lines: oneLine(sale.id, p, 1, 100),
        document: wireDocument(sale)..['created_at'] = 1,
      ),
      now: now(),
    );
    check('document 含主机专属列 → rejected',
        hostOnly.reason?.contains('不可写列') ?? false, '${hostOnly.reason}');
    check('原因点出列名 created_at',
        hostOnly.reason?.contains('created_at') ?? false, '${hostOnly.reason}');

    final SyncResponse missingColumn = server.handle(
      opCreateDocument(
        sale,
        lines: oneLine(sale.id, p, 1, 100),
        document: wireDocument(sale)..remove('doc_type'),
      ),
      now: now(),
    );
    check('缺必填列 → rejected', missingColumn.status == SyncStatus.rejected);
    check('原因点出列名 doc_type',
        missingColumn.reason?.contains('doc_type') ?? false, '${missingColumn.reason}');

    final SyncResponse wrongEntity = server.handle(
      const SyncOperation(
        entity: 'products',
        entityId: 'p-1',
        operation: SyncOpType.createDocument,
      ),
      now: now(),
    );
    check('entity 不是 documents → rejected',
        wrongEntity.reason?.contains('必须是 documents') ?? false,
        '${wrongEntity.reason}');
    db.close();
  }

  // ============================================================ 主数据
  section('createMasterData');
  {
    freshDb();
    final int before = now();
    final String id = syncProduct(code: 'PM1');
    final Product saved = ProductDao(db).findById(id)!;

    check('applied 且字段落库', saved.code == 'PM1');
    check('主机写 sync_version = 0', saved.syncVersion == 0, '${saved.syncVersion}');
    check('主机写 created_at', saved.createdAt >= before);

    final SyncOperation op = opMaster('products', newId(), SyncOpType.createMasterData,
        payload: <String, Object?>{'code': 'PM2', 'name': '商品'});
    check('第一次 applied', server.handle(op, now: now()).status == SyncStatus.applied);
    check('第二次 already_exists',
        server.handle(op, now: now()).status == SyncStatus.alreadyExists);
    check('没有重复行', countOf('products') == 2, '${countOf('products')}');

    final SyncResponse hostOnly = server.handle(
      opMaster('products', newId(), SyncOpType.createMasterData, payload: {
        'code': 'PM3',
        'name': '商品',
        'sync_version': 5,
      }),
      now: now(),
    );
    check('含 sync_version → rejected', hostOnly.status == SyncStatus.rejected);
    check('原因指向列名', hostOnly.reason?.contains('sync_version') ?? false,
        '${hostOnly.reason}');

    final SyncResponse unknown = server.handle(
      opMaster('products', newId(), SyncOpType.createMasterData, payload: {
        'code': 'PM4',
        'name': '商品',
        'nope': 1,
      }),
      now: now(),
    );
    check('未知列 → rejected', unknown.reason?.contains('nope') ?? false,
        '${unknown.reason}');

    final SyncResponse boolValue = server.handle(
      opMaster('products', newId(), SyncOpType.createMasterData, payload: {
        'code': 'PM5',
        'name': '商品',
        'is_active': true,
      }),
      now: now(),
    );
    check('bool 值 → rejected（wire 用 1/0）',
        boolValue.reason?.contains('1 / 0') ?? false, '${boolValue.reason}');

    final SyncResponse toDocuments = server.handle(
      opMaster('documents', newId(), SyncOpType.createMasterData),
      now: now(),
    );
    check('target 是 documents → rejected',
        toDocuments.reason?.contains('只支持主数据表') ?? false,
        '${toDocuments.reason}');
    db.close();
  }

  section('updateMasterData');
  {
    freshDb();
    final String id = syncProduct(code: 'PU1');

    final SyncResponse ok = server.handle(
      opMaster('products', id, SyncOpType.updateMasterData, baseVersion: 0, payload: {
        'sell_price': 1234,
      }),
      now: now(),
    );
    check('base_version 匹配 → applied', ok.status == SyncStatus.applied, '${ok.reason}');
    check('字段已更新', ProductDao(db).findById(id)!.sellPrice == 1234);
    check('sync_version 0 → 1', ProductDao(db).findById(id)!.syncVersion == 1);

    final SyncResponse stale = server.handle(
      opMaster('products', id, SyncOpType.updateMasterData, baseVersion: 0, payload: {
        'sell_price': 999,
      }),
      now: now(),
    );
    check('base_version 落后 → conflict', stale.status == SyncStatus.conflict);
    check('回传 server_state', stale.serverState != null);
    check('server_state.sync_version = 1', stale.serverState!['sync_version'] == 1,
        '${stale.serverState!['sync_version']}');
    check('主机赢：值没被覆盖', ProductDao(db).findById(id)!.sellPrice == 1234);

    final SyncResponse noVersion = server.handle(
      opMaster('products', id, SyncOpType.updateMasterData, payload: {
        'sell_price': 1,
      }),
      now: now(),
    );
    check('缺 base_version → rejected',
        noVersion.reason?.contains('base_version') ?? false, '${noVersion.reason}');

    final SyncResponse missing = server.handle(
      opMaster('products', newId(), SyncOpType.updateMasterData, baseVersion: 0, payload: {
        'sell_price': 1,
      }),
      now: now(),
    );
    check('目标不存在 → rejected', missing.reason?.contains('不存在') ?? false,
        '${missing.reason}');
    db.close();
  }

  section('deleteMasterData');
  {
    freshDb();
    final String id = syncProduct(code: 'PD1');
    final SyncOperation op = opMaster('products', id, SyncOpType.deleteMasterData);

    final SyncResponse first = server.handle(op, now: now());
    check('applied', first.status == SyncStatus.applied, '${first.reason}');
    check('软删：is_active = 0', !ProductDao(db).findById(id)!.isActive);
    check('从不 DELETE：行还在', countOf('products') == 1);

    final SyncResponse second = server.handle(op, now: now());
    check('已删 → already_exists（幂等）',
        second.status == SyncStatus.alreadyExists, '${second.status}');
    check('幂等时不再 +sync_version', ProductDao(db).findById(id)!.syncVersion == 1,
        '${ProductDao(db).findById(id)!.syncVersion}');

    final SyncResponse extra = server.handle(
      opMaster('products', id, SyncOpType.deleteMasterData, payload: {
        'name': '改名',
      }),
      now: now(),
    );
    check('payload 含 id 以外字段 → rejected',
        extra.reason?.contains('只允许 id') ?? false, '${extra.reason}');

    final SyncResponse missing = server.handle(
      opMaster('products', newId(), SyncOpType.deleteMasterData),
      now: now(),
    );
    check('目标不存在 → rejected', missing.reason?.contains('不存在') ?? false,
        '${missing.reason}');
    db.close();
  }

  // ============================================================ documentAction
  section('documentAction（v1 不落地）');
  {
    freshDb();
    final SyncResponse r = server.handle(
      const SyncOperation(
        entity: 'documents',
        entityId: 'd-1',
        operation: SyncOpType.documentAction,
        payload: <String, Object?>{'action': 'mark_delivered'},
      ),
      now: now(),
    );
    check('rejected', r.status == SyncStatus.rejected);
    check('错误码 action_not_implemented',
        r.reason?.contains('action_not_implemented') ?? false, '${r.reason}');
    db.close();
  }

  // ============================================================ 白名单
  section('白名单（纪律 10）');
  {
    freshDb();
    for (final String entity in <String>[
      'stock_ledger',
      'sqlite_master',
      'document_lines',
      'sync_queue',
      'x',
    ]) {
      final SyncResponse r = server.handle(
        SyncOperation(
          entity: entity,
          entityId: 'i-1',
          operation: SyncOpType.createMasterData,
        ),
        now: now(),
      );
      check('table $entity → rejected', r.status == SyncStatus.rejected);
    }
    check('白名单外没有任何行被写入', countOf('products') == 0 && countOf('documents') == 0);
    db.close();
  }

  // ============================================================ 批量
  section('push 批量');
  {
    freshDb();
    final String good = newId();
    final String party = syncParty();
    final Document purchase = pending(
      type: DocType.purchase,
      partyId: party,
      totalAmount: 100,
    );
    final String p2 = syncProduct(code: 'PB1');

    final List<SyncResponse> results = server.push(<SyncOperation>[
      opMaster('products', good, SyncOpType.createMasterData,
          payload: <String, Object?>{'code': 'PB2', 'name': '商品'}),
      const SyncOperation(
        entity: 'nope',
        entityId: 'bad',
        operation: SyncOpType.createMasterData,
      ),
      opCreateDocument(purchase, lines: oneLine(purchase.id, p2, 1, 100)),
    ], now: now());

    check('三条都有回执', results.length == 3);
    check('第一条 applied', results[0].status == SyncStatus.applied);
    check('第二条 rejected', results[1].status == SyncStatus.rejected);
    check('第三条不受前一条影响 applied',
        results[2].status == SyncStatus.applied, '${results[2].reason}');
    check('事务独立：好单已落库', countOf('documents') == 1);
    check('回执按 entity_id 配对',
        <String>{for (final SyncResponse r in results) r.entityId}.length == 3);
    db.close();
  }

  // ============================================================ pull
  section('pull');
  {
    freshDb();
    final SyncPullResult empty = server.pull();
    check('空库 stock_ledger 为空', empty.entities['stock_ledger']!.isEmpty);
    check('空库 next_cursors.stock_since = 0',
        empty.nextCursors[SyncServer.cursorStock] == '0',
        '${empty.nextCursors[SyncServer.cursorStock]}');
    check('空库 next_cursors.doc_since = "0|"',
        empty.nextCursors[SyncServer.cursorDoc] == '0|',
        '${empty.nextCursors[SyncServer.cursorDoc]}');

    final String p = syncProduct(code: 'PR1');
    final String party = syncParty();
    syncPurchase(p, party, 4, 100);

    final SyncPullResult first = server.pull();
    final Map<String, Object?> row = first.entities['stock_ledger']!.single;
    check('拉到 stock_ledger 一行', first.countOf('stock_ledger') == 1);
    check('wire 列名 = 数据库列名', row.containsKey('total_cost') && row.containsKey('seq_no'));
    check('quantity = 4', row['quantity'] == 4, '${row['quantity']}');
    check('total_cost = 400', row['total_cost'] == 400, '${row['total_cost']}');
    check('流水游标推进到 1', first.nextCursors[SyncServer.cursorStock] == '1',
        '${first.nextCursors[SyncServer.cursorStock]}');

    final SyncPullResult second = server.pull(
      stockSince: first.nextCursors[SyncServer.cursorStock]!,
    );
    check('增量：再拉为空', second.countOf('stock_ledger') == 0);
    check('游标保持不变', second.nextCursors[SyncServer.cursorStock] == '1');

    final String docCursor = first.nextCursors[SyncServer.cursorDoc]!;
    check('documents 游标是复合形式（含 |）', docCursor.contains('|'), docCursor);
    final SyncCursor parsed = SyncCursor.parse(docCursor);
    final Map<String, Object?> lastDoc = first.entities['documents']!.last;
    check('复合游标的 created_at 与末行一致', parsed.createdAt == lastDoc['created_at']);
    check('复合游标的 id 与末行一致', parsed.id == lastDoc['id']);

    final SyncPullResult docIncrement = server.pull(docSince: docCursor);
    check('documents 增量：再拉为空', docIncrement.countOf('documents') == 0);
    db.close();
  }

  section('pull · limit 与游标推进');
  {
    freshDb();
    final String p = syncProduct(code: 'PL1');
    final String party = syncParty();

    // 同一毫秒连开 3 张单 —— 制造「同一 created_at 多行」
    final int stamp = now();
    for (int i = 0; i < 3; i++) {
      final Document d = pending(
        type: DocType.purchase,
        partyId: party,
        totalAmount: 100,
      );
      final SyncResponse r = server.handle(
        opCreateDocument(d, lines: oneLine(d.id, p, 1, 100)),
        now: stamp,
      );
      if (r.status != SyncStatus.applied) {
        stderr.writeln('夹具失败：第 $i 张单 → ${r.reason}');
        exit(2);
      }
    }

    final Set<String> seen = <String>{};
    String cursor = '';
    bool advanced = true;
    for (int page = 0; page < 10; page++) {
      final SyncPullResult result = server.pull(docSince: cursor, limit: 1);
      final List<Map<String, Object?>> rows = result.entities['documents']!;
      if (rows.isEmpty) break;
      seen.add(rows.single['id']! as String);
      final String next = result.nextCursors[SyncServer.cursorDoc]!;
      if (next == cursor) advanced = false;
      cursor = next;
    }
    check('limit=1 时游标也推进（不会死循环）', advanced);
    check('同一 created_at 的 3 行全部取到且不重复', seen.length == 3, '${seen.length}');
    db.close();
  }

  section('pull · 游标格式');
  {
    freshDb();
    check('doc_since 非法 → 抛 FormatException',
        throws(() => server.pull(docSince: 'not-a-cursor')));
    check('stock_since 非整数 → 抛 FormatException',
        throws(() => server.pull(stockSince: 'x')));
    db.close();
  }

  section('pull · 明细随主单');
  {
    freshDb();
    final String p = syncProduct(code: 'PN1');
    final String party = syncParty();
    syncPurchase(p, party, 2, 100);

    final SyncPullResult result = server.pull();
    check('本页 1 张主单', result.countOf('documents') == 1);
    check('明细一并返回（1 条）', result.countOf('document_lines') == 1,
        '${result.countOf('document_lines')}');
    check('明细的 document_id 指向本页主单',
        result.entities['document_lines']!.single['document_id'] ==
            result.entities['documents']!.single['id']);
    check('next_cursors 里没有 line_since',
        !result.nextCursors.containsKey('line_since'),
        '${result.nextCursors.keys.toList()}');
    check('next_cursors 有 5 个键', result.nextCursors.length == 5,
        '${result.nextCursors.length}');

    final SyncPullResult next = server.pull(
      docSince: result.nextCursors[SyncServer.cursorDoc]!,
    );
    check('下一页明细不再重复', next.countOf('document_lines') == 0);
    db.close();
  }

  section('pull · 明细不按 limit 截断');
  {
    freshDb();
    final String p = syncProduct(code: 'PN2');
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
    check('3 条明细的采购单 applied',
        response.status == SyncStatus.applied, '${response.reason}');

    final SyncPullResult result = server.pull(limit: 1);
    check('limit=1 只取 1 张主单', result.countOf('documents') == 1);
    check('但该主单的 3 条明细都在', result.countOf('document_lines') == 3,
        '${result.countOf('document_lines')}');
    db.close();
  }

  // ============================================================ JSON 契约
  section('wire JSON 编解码');
  {
    freshDb();
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
    check('SyncOperation 往返：entity', decoded.entity == original.entity);
    check('SyncOperation 往返：entityId', decoded.entityId == original.entityId);
    check('SyncOperation 往返：operation', decoded.operation == SyncOpType.createDocument);
    check('SyncOperation 往返：payload',
        jsonEncode(decoded.payload) == jsonEncode(original.payload));

    const SyncResponse rejected = SyncResponse(
      entityId: 'd-1',
      status: SyncStatus.rejected,
      reason: 'boom',
    );
    check('SyncResponse.toJson 含 status',
        rejected.toJson()['status'] == 'rejected');
    check('SyncResponse.toJson 含 reason', rejected.toJson()['reason'] == 'boom');
    check('SyncResponse 无 server_state 时不输出该键',
        !rejected.toJson().containsKey('server_state'));

    final Map<String, Object?> pullJson = server.pull().toJson();
    check('SyncPullResult.toJson 平铺实体 + next_cursors',
        pullJson.containsKey('documents') && pullJson.containsKey('next_cursors'));
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
