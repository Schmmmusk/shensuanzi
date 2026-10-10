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

/// 用户可见文本里命中的开发术语（**空 = 干净**）。
///
/// ⚠️ 判据与各包 `test/support/dev_terms.dart` 的 `expectNoDevTerms` **同一套**，
/// 但这里**内联**、`selfcheck` 保持**自包含**（`tool/` 脚本不依赖 `test/` 夹具；
/// 裁定 §CV·十三·六 §三 路 A）。表本身仍是**单一来源**（core 的
/// `forbiddenDevTermsInUserText`）。
List<String> devTermHits(
  String text, {
  List<String> extra = const <String>[],
}) => <String>[
  for (final String term in <String>[
    ...forbiddenDevTermsInUserText,
    ...extra,
  ])
    if (text.contains(term)) term,
];

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

/// 主机侧**内部错误日志**的捕获（#22 裁定，2026-10-09）。
///
/// 协议违反 / 规则内部 bug 的**细节只进日志**（进 `reason` 的是通用中文）
/// ⇒ 「原因点出列名 X」那几条断言改成查这里。
final List<String> internalErrors = <String>[];

void freshDb() {
  db = Db.openInMemory();
  internalErrors.clear();
  server = SyncServer(
    db,
    onInternalError: (String label, Object error, StackTrace stack) =>
        internalErrors.add('$label｜$error'),
  );
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
    'immediate_payments': ?immediatePayments,
    'allocations': ?allocations,
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
    check('无 party_id 的赊账销售 ⇒ 内部 bug（码 rule_internal_error）',
        r.reasonCode == RejectCode.ruleInternalError, '${r.reasonCode}｜${r.reason}');
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
    check('互斥 ⇒ payload_mutually_exclusive',
        both.reasonCode == RejectCode.payloadMutuallyExclusive,
        '${both.reasonCode}｜${both.reason}');
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
    check('id 不符 ⇒ id_mismatch',
        idMismatch.reasonCode == RejectCode.idMismatch,
        '${idMismatch.reasonCode}｜${idMismatch.reason}');

    final SyncResponse noDocument = server.handle(
      const SyncOperation(
        entity: 'documents',
        entityId: 'd-1',
        operation: SyncOpType.createDocument,
        payload: <String, Object?>{},
      ),
      now: now(),
    );
    check('缺 payload.document ⇒ missing_field',
        noDocument.reasonCode == RejectCode.missingField,
        '${noDocument.reasonCode}｜${noDocument.reason}');

    final SyncResponse unknownField = server.handle(
      const SyncOperation(
        entity: 'documents',
        entityId: 'd-1',
        operation: SyncOpType.createDocument,
        payload: <String, Object?>{'document': null, 'lines_': <Object?>[]},
      ),
      now: now(),
    );
    check('未知顶层字段 ⇒ unknown_field',
        unknownField.reasonCode == RejectCode.unknownField,
        '${unknownField.reasonCode}｜${unknownField.reason}');

    final SyncResponse hostOnly = server.handle(
      opCreateDocument(
        sale,
        lines: oneLine(sale.id, p, 1, 100),
        document: wireDocument(sale)..['created_at'] = 1,
      ),
      now: now(),
    );
    check('document 含主机专属列 ⇒ unwritable_column',
        hostOnly.reasonCode == RejectCode.unwritableColumn,
        '${hostOnly.reasonCode}｜${hostOnly.reason}');
    check('列名 created_at 只进日志（不再进 reason）',
        internalErrors.any((String e) => e.contains('created_at')),
        internalErrors.join(' | '));

    final SyncResponse missingColumn = server.handle(
      opCreateDocument(
        sale,
        lines: oneLine(sale.id, p, 1, 100),
        document: wireDocument(sale)..remove('doc_type'),
      ),
      now: now(),
    );
    check('缺必填列 → rejected', missingColumn.status == SyncStatus.rejected);
    // ⚠️ 断**精确子串**（§CV·十九）：`doc_type` 也出现在 detail 的「必填 id / doc_type / …」
    // 提示里 ⇒ 只断 `contains('doc_type')` 会在 `$error` 丢失时照样绿（空心断言）。
    check('列名 doc_type 只进日志（不再进 reason）',
        internalErrors.any((String e) => e.contains('缺少必填列 `doc_type`')),
        internalErrors.join(' | '));

    final SyncResponse wrongEntity = server.handle(
      const SyncOperation(
        entity: 'products',
        entityId: 'p-1',
        operation: SyncOpType.createDocument,
      ),
      now: now(),
    );
    check('entity 不是 documents → **通用回执**（细节只进日志）',
        wrongEntity.reason == malformedSyncRequestReason,
        '${wrongEntity.reason}');
    db.close();
  }

  // ============================================================ 主数据
  section('createMasterData');
  {
    freshDb();
    final int before = now();
    // §CV·七②（2026-10-09）温和收紧：主机只**采信** `^P\d+$` 的编码建议，
    // 其余**视同未提供**（走自增）。⇒ 夹具必须用**规范码**才能验「原样落库」。
    // ⚠️ 老夹具用 `PM1`（非规范）—— 收紧后它会静默变成自增，本条断言恒红；
    // 之所以能藏这么久：`selfcheck_*` **不在门禁里**，收紧那批我只复跑了 core。
    final String id = syncProduct(code: 'P0001');
    final Product saved = ProductDao(db).findById(id)!;

    check('applied 且字段落库', saved.code == 'P0001');
    check('主机写 sync_version = 0', saved.syncVersion == 0, '${saved.syncVersion}');
    check('主机写 created_at', saved.createdAt >= before);

    final SyncOperation op = opMaster('products', newId(), SyncOpType.createMasterData,
        payload: <String, Object?>{'code': 'PM2', 'name': '商品'});
    check('第一次 applied', server.handle(op, now: now()).status == SyncStatus.applied);
    check('第二次 already_exists',
        server.handle(op, now: now()).status == SyncStatus.alreadyExists);
    check('没有重复行', countOf('products') == 2, '${countOf('products')}');

    // §CV·七② 的另一半（主机侧此前**零覆盖** ⇒ 就是上面那条红藏身之处）：
    // **非规范码** ⇒ 主机改派自增，但**不是** rejected。
    final String reassigned = syncProduct(code: 'PM1');
    final String reassignedCode = ProductDao(db).findById(reassigned)!.code;
    check('非规范编码 ⇒ 视同未提供（改派自增，不拒绝）',
        reassignedCode != 'PM1' &&
            ProductCodeGenerator.pattern.hasMatch(reassignedCode),
        reassignedCode);

    final SyncResponse hostOnly = server.handle(
      opMaster('products', newId(), SyncOpType.createMasterData, payload: {
        'code': 'PM3',
        'name': '商品',
        'sync_version': 5,
      }),
      now: now(),
    );
    check('含 sync_version → rejected', hostOnly.status == SyncStatus.rejected);
    check('列名 sync_version 只进日志（不再进 reason）',
        internalErrors.any((String e) => e.contains('sync_version')),
        internalErrors.join(' | '));

    final SyncResponse unknown = server.handle(
      opMaster('products', newId(), SyncOpType.createMasterData, payload: {
        'code': 'PM4',
        'name': '商品',
        'nope': 1,
      }),
      now: now(),
    );
    check('未知列 nope 只进日志（不再进 reason）',
        unknown.status == SyncStatus.rejected &&
            internalErrors.any((String e) => e.contains('nope')),
        '${unknown.reasonCode}｜${internalErrors.join(' | ')}');

    final SyncResponse boolValue = server.handle(
      opMaster('products', newId(), SyncOpType.createMasterData, payload: {
        'code': 'PM5',
        'name': '商品',
        'is_active': true,
      }),
      now: now(),
    );
    check('bool 值 ⇒ malformed_parameter',
        boolValue.reasonCode == RejectCode.malformedParameter,
        '${boolValue.reasonCode}｜${boolValue.reason}');

    final SyncResponse toDocuments = server.handle(
      opMaster('documents', newId(), SyncOpType.createMasterData),
      now: now(),
    );
    check('target 是 documents ⇒ not_writable_table',
        toDocuments.reasonCode == RejectCode.notWritableTable,
        '${toDocuments.reasonCode}｜${toDocuments.reason}');
    db.close();
  }

  // ============================================================ 编码改派（D1）
  //
  // 与 `test/sync_server_test.dart` 的「createMasterData · 商品编码的主机改派（D1）」
  // 镜像。改派逻辑的唯一出处是 `ProductService.resolvePreferredCode`。
  section('createMasterData · 商品编码的主机改派（D1）');
  {
    freshDb();
    final String firstId = syncProduct(code: 'P7001');
    check('客户端编码可用 ⇒ 原样采用',
        ProductDao(db).findById(firstId)!.code == 'P7001');

    final String secondId = newId();
    final SyncResponse second = server.handle(
      opMaster('products', secondId, SyncOpType.createMasterData, payload: {
        'code': 'P7001',
        'name': '商品乙',
      }),
      now: now(),
    );
    check('同 code 异 id ⇒ applied（改派**不是**错误）',
        second.status == SyncStatus.applied, '${second.reason}');
    check('改派后编码 ≠ 请求的编码（顺延 P7002）',
        ProductDao(db).findById(secondId)!.code == 'P7002',
        ProductDao(db).findById(secondId)!.code);
    check('原占用者的编码一个字都不动',
        ProductDao(db).findById(firstId)!.code == 'P7001');
    check('两条都落库（改派不是拒绝）', countOf('products') == 2,
        '${countOf('products')}');

    final String thirdId = newId();
    final SyncResponse third = server.handle(
      opMaster('products', thirdId, SyncOpType.createMasterData, payload: {
        'code': 'P7001',
        'name': '商品丙',
      }),
      now: now(),
    );
    check(
        '两台设备先后推同一 code ⇒ 先后改派，不撞 UNIQUE',
        third.status == SyncStatus.applied &&
            ProductDao(db).findById(thirdId)!.code == 'P7003',
        '${third.reason} / ${ProductDao(db).findById(thirdId)!.code}');

    final SyncResponse badCode = server.handle(
      opMaster('products', newId(), SyncOpType.createMasterData, payload: {
        'code': 5,
        'name': '商品',
      }),
      now: now(),
    );
    check('code 不是字符串 ⇒ **通用回执**（细节只进日志）',
        badCode.status == SyncStatus.rejected &&
            badCode.reason == malformedSyncRequestReason,
        '${badCode.reason}');
    // 通用回执**文案本身**也要守规矩（用户可见文本）—— §CV·十五
    check('通用回执：不含开发术语且说了「重试」',
        devTermHits(malformedSyncRequestReason).isEmpty &&
            malformedSyncRequestReason.contains('重试'),
        malformedSyncRequestReason);
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
    check('缺 base_version ⇒ missing_field',
        noVersion.reasonCode == RejectCode.missingField,
        '${noVersion.reasonCode}｜${noVersion.reason}');

    // §CV·3（方案丙，2026-10-08）：不存在 ⇒ **upsert 建档**（不再 rejected）。
    //
    // ⚠️ 先换空库：本段上文用 `syncProduct(code: 'PU1')` 造行，而 `PU1` 是**非规范编码**。
    // upsert 路径**必然调用**编码生成器（`resolvePreferredCode(null)`），生成器遇
    // `PU1` 会 `int.tryParse('U1') == null` 抛 StateError。空库 ⇒ 从 `P0001` 起，正常。
    // （测试侧用 `P910` 这类规范码，没有这个问题 —— 见 `sync_server_test.dart`。）
    db.close();
    freshDb();
    final String upsertId = newId();
    final SyncResponse upsert = server.handle(
      opMaster('products', upsertId, SyncOpType.updateMasterData, baseVersion: 0, payload: {
        'name': '离线建的商品',
        'sell_price': 350,
      }),
      now: now(),
    );
    check('目标不存在 ⇒ upsert：applied',
        upsert.status == SyncStatus.applied, '${upsert.reason}');
    check('upsert 用 payload 的 id 建档',
        ProductDao(db).findById(upsertId)!.name == '离线建的商品');
    check('upsert 建档版本从 0 起（与 create 同）',
        ProductDao(db).findById(upsertId)!.syncVersion == 0);
    check('编码由主机生成（update payload 不带 code）',
        ProductDao(db).findById(upsertId)!.code.isNotEmpty,
        ProductDao(db).findById(upsertId)!.code);

    // 乱序收敛：update 先到 ⇒ 建档；create 后到 ⇒ already_exists
    final SyncResponse lateCreate = server.handle(
      opMaster('products', upsertId, SyncOpType.createMasterData, payload: {
        'name': '离线建的商品',
        'code': 'P7788',
        'sell_price': 350,
      }),
      now: now(),
    );
    check('乱序收敛：create 后到 ⇒ already_exists',
        lateCreate.status == SyncStatus.alreadyExists, '${lateCreate.status}');

    // upsert 遇缺必填 ⇒ 约束分类回中文，不含 SQL / 表名
    final SyncResponse missingName = server.handle(
      opMaster('products', newId(), SyncOpType.updateMasterData, baseVersion: 0, payload: {
        'sell_price': 1, // 缺 name（NOT NULL）
      }),
      now: now(),
    );
    final String missingReason = missingName.reason ?? '';
    check('upsert 缺必填 ⇒ rejected', missingName.status == SyncStatus.rejected);
    // 通用术语走**共用表**（core 的 `forbiddenDevTermsInUserText`）；表名是模块特有 ⇒ `extra`
    check('回执不含 SQL / 表名 / 异常类名',
        devTermHits(missingReason, extra: <String>['products']).isEmpty,
        missingReason);

    // §CS·五 ①：系统生成的字段一律以主机为准（payload 里的 code 丢弃）
    final String keep = syncProduct(code: 'P810');
    final String other = syncProduct(code: 'P811');
    final SyncResponse staleCode = server.handle(
      opMaster('products', other, SyncOpType.updateMasterData,
          baseVersion: 0,
          payload: <String, Object?>{'code': 'P810', 'sell_price': 999}),
      now: now(),
    );
    check('带**过期 code** 的 update ⇒ applied（不是 rejected）',
        staleCode.status == SyncStatus.applied, '${staleCode.reason}');
    check('code 以主机为准（仍是 P811）',
        ProductDao(db).findById(other)!.code == 'P811',
        ProductDao(db).findById(other)!.code);
    check('其它字段照常更新',
        ProductDao(db).findById(other)!.sellPrice == 999);
    check('别人的编码不受影响',
        ProductDao(db).findById(keep)!.code == 'P810');
    db.close();
  }

  // ============================================================ 内部错误的回执口径（§CS·五 ③）
  //
  // 与 `test/sync_server_test.dart` 的「内部错误的回执口径」镜像。
  section('内部错误的回执口径（§CS·五 ③）');
  {
    freshDb();
    final List<String> labels = <String>[];
    final List<Object> logged = <Object>[];
    final SyncServer logging = SyncServer(
      db,
      onInternalError: (String label, Object error, StackTrace stack) {
        labels.add(label);
        logged.add(error);
      },
    );

    // products.name 是 NOT NULL ⇒ 缺 name 触发 SQLITE_CONSTRAINT_NOTNULL
    final SyncResponse constraint = logging.handle(
      opMaster('products', newId(), SyncOpType.createMasterData,
          payload: <String, Object?>{'code': 'P820'}),
      now: now(),
    );
    check('约束冲突 ⇒ 中文原因（说清是「不完整或不合法」）',
        constraint.status == SyncStatus.rejected &&
            (constraint.reason?.contains('不完整或不合法') ?? false),
        '${constraint.reason}');
    check(
        '回给客户端的话**不含表名 / 类型名 / SQL**',
        devTermHits(
          constraint.reason ?? '',
          extra: <String>['products', 'Sqlite', 'NOT NULL'],
        ).isEmpty,
        '${constraint.reason}');
    check('原始异常走 onInternalError（含 constraint 细节）',
        logged.length == 1 &&
            logged.single.toString().toLowerCase().contains('constraint'),
        '${logged.isEmpty ? '（无）' : logged.first}');
    check('日志标签带操作名', labels.length == 1, '$labels');
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
    check('payload 含 id 以外字段 ⇒ unwritable_column',
        extra.reasonCode == RejectCode.unwritableColumn,
        '${extra.reasonCode}｜${extra.reason}');

    final SyncResponse missing = server.handle(
      opMaster('products', newId(), SyncOpType.deleteMasterData),
      now: now(),
    );
    check('目标不存在 ⇒ **幂等 already_exists**（不再 rejected，#21 裁定）',
        missing.status == SyncStatus.alreadyExists, '${missing.status}');
    db.close();
  }

  // ============================================================ documentAction
  section('documentAction（R-3 已裁定：mark_delivered）');
  {
    freshDb();
    final String p = syncProduct();
    final String party = syncParty();
    final Document delivery = pending(
      type: DocType.delivery,
      partyId: party,
      totalAmount: 1000,
    );
    final SyncResponse created = server.handle(
      opCreateDocument(delivery, lines: oneLine(delivery.id, p, 2, 500)),
      now: now(),
    );
    check('送货单建单 applied', created.status == SyncStatus.applied,
        '${created.reason}');

    SyncOperation action(String id) => SyncOperation(
      entity: Schema.documents,
      entityId: id,
      operation: SyncOpType.documentAction,
      payload: <String, Object?>{'action': 'mark_delivered'},
    );

    final SyncResponse ok = server.handle(action(delivery.id), now: now());
    check('in_transit → applied', ok.status == SyncStatus.applied, '${ok.reason}');
    check('单据落到 delivered',
        DocumentDao(db).findById(delivery.id)!.status == DocStatus.delivered);

    final SyncResponse again = server.handle(action(delivery.id), now: now());
    check('重复签收 → already_exists', again.status == SyncStatus.alreadyExists);

    // cancelled → conflict + server_state（R-3.4：状态不匹配，客户端自动对齐）
    DocumentDao(db).updateStatusAndPaid(
      id: delivery.id,
      status: DocStatus.cancelled,
      updatedAt: now(),
    );
    final SyncResponse conflict = server.handle(action(delivery.id), now: now());
    check('cancelled → conflict', conflict.status == SyncStatus.conflict);
    check('server_state 带主机状态',
        conflict.serverState?['status'] == DocStatus.cancelled.wire,
        '${conflict.serverState}');

    // 未知动作 / 未知字段 → rejected
    final SyncResponse unknown = server.handle(
      const SyncOperation(
        entity: 'documents',
        entityId: 'd-x',
        operation: SyncOpType.documentAction,
        payload: <String, Object?>{'action': 'un_cancel'},
      ),
      now: now(),
    );
    check('未知动作 ⇒ unknown_action',
        unknown.status == SyncStatus.rejected &&
            unknown.reasonCode == RejectCode.unknownAction,
        '${unknown.reasonCode}｜${unknown.reason}');

    // purchase 收签收 → rejected（规则不允许：docType 不适用）
    freshDb();
    final String p2 = syncProduct();
    final String party2 = syncParty();
    final Document purchase = pending(
      type: DocType.purchase,
      partyId: party2,
      totalAmount: 1000,
    );
    server.handle(
      opCreateDocument(purchase, lines: oneLine(purchase.id, p2, 10, 100)),
      now: now(),
    );
    final SyncResponse wrongType = server.handle(action(purchase.id), now: now());
    check('purchase 收签收 ⇒ action_not_applicable',
        wrongType.status == SyncStatus.rejected &&
            wrongType.reasonCode == RejectCode.actionNotApplicable,
        '${wrongType.reasonCode}｜${wrongType.reason}');

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

  // ===================================== 协议违反：通用回执 + 细节只进日志（§CV·十五）
  //
  // 这些分支**都不该是用户可见的 `rejected`** —— 全是客户端实现的 bug（协议违反），
  // 用户看了也修不了 ⇒ 回执只给通用中文，**诊断细节完整走 `onInternalError`**。
  section('协议违反 ⇒ 通用回执 + 细节只进日志');
  {
    freshDb();
    final List<String> labels = <String>[];
    final List<Object> logged = <Object>[];
    final SyncServer logging = SyncServer(
      db,
      onInternalError: (String label, Object error, StackTrace stack) {
        labels.add(label);
        logged.add(error);
      },
    );

    // ① 白名单外
    final SyncResponse whitelist = logging.handle(
      SyncOperation(
        entity: 'ghost_table',
        entityId: 'i-1',
        operation: SyncOpType.createMasterData,
      ),
      now: now(),
    );
    check('白名单外 ⇒ 通用回执',
        whitelist.reason == malformedSyncRequestReason, '${whitelist.reason}');

    // ② createDocument 的 entity 不对
    final SyncResponse wrongEntity = logging.handle(
      SyncOperation(
        entity: 'products',
        entityId: 'i-2',
        operation: SyncOpType.createDocument,
      ),
      now: now(),
    );
    check('entity 不符 ⇒ 通用回执',
        wrongEntity.reason == malformedSyncRequestReason, '${wrongEntity.reason}');

    // ③ products.code 不是字符串
    final SyncResponse badCode = logging.handle(
      opMaster('products', newId(), SyncOpType.createMasterData,
          payload: <String, Object?>{'code': 5, 'name': '商品'}),
      now: now(),
    );
    check('code 类型不符 ⇒ 通用回执',
        badCode.reason == malformedSyncRequestReason, '${badCode.reason}');

    // ④ **细节全部进了日志**（排障要看的就是它）
    check('三次违反各记一条日志', labels.length == 3, '$labels');
    check('日志保留 entity 名', logged.any((Object e) => '$e'.contains('ghost_table')));
    check('日志保留「必须是 documents」',
        logged.any((Object e) => '$e'.contains('必须是 documents')));
    check('日志保留 code 类型细节',
        logged.any((Object e) => '$e'.contains('code')));
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
    // 实体清单只从 SyncPullResult.entityNames 取（单一定义，加实体时一处改）
    check('恰好 9 个实体', empty.entities.keys.length == 9,
        '${empty.entities.keys.toList()}');
    check('实体名与 entityNames 一致',
        empty.entities.keys.toSet().difference(SyncPullResult.entityNames.toSet()).isEmpty &&
            SyncPullResult.entityNames.toSet().difference(empty.entities.keys.toSet()).isEmpty,
        '${empty.entities.keys.toList()}');
    for (final String entity in SyncPullResult.entityNames) {
      check('空库 $entity 为空', empty.entities[entity]!.isEmpty);
    }
    check('恰好 8 个游标', empty.nextCursors.length == 8,
        '${empty.nextCursors.length}');
    check('游标键与 SyncCursorKeys.all 一致',
        empty.nextCursors.keys.toSet().difference(SyncCursorKeys.all.toSet()).isEmpty &&
            SyncCursorKeys.all.toSet().difference(empty.nextCursors.keys.toSet()).isEmpty);
    check('空库 next_cursors.stock_since = 0',
        empty.nextCursors[SyncCursorKeys.stock] == '0',
        '${empty.nextCursors[SyncCursorKeys.stock]}');
    check('空库 next_cursors.doc_since = "0|"',
        empty.nextCursors[SyncCursorKeys.doc] == '0|',
        '${empty.nextCursors[SyncCursorKeys.doc]}');
    check('空库 next_cursors.products_since = "0|"',
        empty.nextCursors[SyncCursorKeys.products] == '0|',
        '${empty.nextCursors[SyncCursorKeys.products]}');

    final String p = syncProduct(code: 'PR1');
    final String party = syncParty();
    syncPurchase(p, party, 4, 100);

    final SyncPullResult first = server.pull();
    final Map<String, Object?> row = first.entities['stock_ledger']!.single;
    check('拉到 stock_ledger 一行', first.countOf('stock_ledger') == 1);
    check('wire 列名 = 数据库列名', row.containsKey('total_cost') && row.containsKey('seq_no'));
    check('quantity = 4', row['quantity'] == 4, '${row['quantity']}');
    check('total_cost = 400', row['total_cost'] == 400, '${row['total_cost']}');
    check('流水游标推进到 1', first.nextCursors[SyncCursorKeys.stock] == '1',
        '${first.nextCursors[SyncCursorKeys.stock]}');

    final SyncPullResult second = server.pull(
      stockSince: first.nextCursors[SyncCursorKeys.stock]!,
    );
    check('增量：再拉为空', second.countOf('stock_ledger') == 0);
    check('游标保持不变', second.nextCursors[SyncCursorKeys.stock] == '1');

    final String docCursor = first.nextCursors[SyncCursorKeys.doc]!;
    check('documents 游标是复合形式（含 |）', docCursor.contains('|'), docCursor);
    final SyncCursor parsed = SyncCursor.parse(docCursor);
    final Map<String, Object?> lastDoc = first.entities['documents']!.last;
    check('复合游标的时间戳与末行 created_at 一致', parsed.stamp == lastDoc['created_at']);
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
      final String next = result.nextCursors[SyncCursorKeys.doc]!;
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
    check('next_cursors 有 8 个键', result.nextCursors.length == 8,
        '${result.nextCursors.length}');

    final SyncPullResult next = server.pull(
      docSince: result.nextCursors[SyncCursorKeys.doc]!,
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

  // ⚠️ 「不按 limit 截断」**不等于**「可以越过本页主单的边界」。
  // 明细必须恰好是本页那批主单的明细：`documents` 有 `LIMIT`，明细查询也必须
  // 落在同一批主单之内。否则每一页都会带上**后面所有主单**的明细 ——
  // 页数越多越糟（第 1 页就返回全量的明细），客户端还会先收到
  // 「主单还没到」的孤儿明细行。
  section('pull · 明细限制在本页主单内');
  {
    freshDb();
    final String p = syncProduct(code: 'PN3');
    final String party = syncParty();
    for (int i = 0; i < 3; i++) {
      syncPurchase(p, party, 1, 100);
    }

    final SyncPullResult result = server.pull(limit: 1);
    check('limit=1 取到 1 张主单', result.countOf('documents') == 1,
        '${result.countOf('documents')}');
    check('明细也只属于这 1 张主单（不是 3 条）',
        result.countOf('document_lines') == 1,
        '${result.countOf('document_lines')}');
    check('明细的 document_id = 本页唯一主单',
        result.countOf('document_lines') == 1 &&
            result.entities['document_lines']!.single['document_id'] ==
                result.entities['documents']!.single['id']);
    db.close();
  }

  // ============================================================ 主数据（R-13 方案 A）
  section('pull · 主数据');
  {
    freshDb();
    final String p = syncProduct(code: 'PM1', costPrice: 100);

    final SyncPullResult firstB = server.pull();
    final Map<String, Object?> row = firstB.entities['products']!.single;
    check('主数据随 pull 返回', firstB.countOf('products') == 1);
    check('返回全部列（含 sync_version）', row['sync_version'] == 0,
        '${row['sync_version']}');
    check('返回全部列（含 updated_at）', row.containsKey('updated_at'));

    final String productsCursor = firstB.nextCursors[SyncCursorKeys.products]!;
    check('主数据游标是复合形式（含 |）', productsCursor.contains('|'), productsCursor);
    final SyncCursor parsed = SyncCursor.parse(productsCursor);
    check('复合游标的时间戳 = 末行 updated_at', parsed.stamp == row['updated_at'],
        '${parsed.stamp} vs ${row['updated_at']}');
    check('复合游标的 id = 末行 id', parsed.id == row['id']);
    check('主数据游标的时间戳列是 updated_at（不是 created_at）',
        row['updated_at'] != null && parsed.stamp == row['updated_at']);

    // ---- A 改价 → B 带游标拉
    final SyncResponse update = server.handle(
      opMaster('products', p, SyncOpType.updateMasterData, baseVersion: 0,
          payload: <String, Object?>{'cost_price': 120}),
      now: now(),
    );
    check('A 改价 applied', update.status == SyncStatus.applied, '${update.reason}');

    final SyncPullResult secondB = server.pull(productsSince: productsCursor);
    check('B 增量拉到 1 行', secondB.countOf('products') == 1,
        '${secondB.countOf('products')}');
    check('B 拿到新价 120',
        secondB.entities['products']!.single['cost_price'] == 120,
        '${secondB.entities['products']!.single['cost_price']}');
    check('sync_version +1',
        secondB.entities['products']!.single['sync_version'] == 1);

    // ---- 无改动 → 增量页为空
    final SyncPullResult third = server.pull(
      productsSince: secondB.nextCursors[SyncCursorKeys.products]!,
    );
    check('未改动 → 增量页为空', third.countOf('products') == 0);
    check('未改动 → 游标保持',
        third.nextCursors[SyncCursorKeys.products] ==
            secondB.nextCursors[SyncCursorKeys.products]);

    // ---- 软删可见
    final SyncResponse deleted = server.handle(
      opMaster('products', p, SyncOpType.deleteMasterData),
      now: now(),
    );
    check('软删 applied', deleted.status == SyncStatus.applied, '${deleted.reason}');
    final SyncPullResult afterDelete = server.pull(
      productsSince: third.nextCursors[SyncCursorKeys.products]!,
    );
    check('软删行照常返回（否则客户端永远不知道）',
        afterDelete.countOf('products') == 1);
    check('is_active = 0',
        afterDelete.entities['products']!.single['is_active'] == 0);

    // ---- 新客户端全量首拉也能看到软删行
    final SyncPullResult freshClient = server.pull();
    check('全量首拉可见软删行', freshClient.countOf('products') == 1);
    check('全量首拉的 is_active = 0',
        freshClient.entities['products']!.single['is_active'] == 0);
    db.close();
  }

  section('pull · 主数据 limit 与游标推进');
  {
    freshDb();
    // 同一毫秒建 3 个商品 —— 制造「同一 updated_at 多行」
    final int stamp = now();
    for (int i = 0; i < 3; i++) {
      final SyncResponse r = server.handle(
        opMaster('products', newId(), SyncOpType.createMasterData,
            payload: <String, Object?>{'code': 'PM9$i', 'name': '商品$i'}),
        now: stamp,
      );
      if (r.status != SyncStatus.applied) {
        stderr.writeln('夹具失败：第 $i 个商品 → ${r.reason}');
        exit(2);
      }
    }

    final Set<String> seen = <String>{};
    String cursor = '';
    bool advanced = true;
    for (int page = 0; page < 10; page++) {
      final SyncPullResult result = server.pull(
        productsSince: cursor,
        limit: 1,
      );
      final List<Map<String, Object?>> rows = result.entities['products']!;
      if (rows.isEmpty) break;
      seen.add(rows.single['id']! as String);
      final String next = result.nextCursors[SyncCursorKeys.products]!;
      if (next == cursor) advanced = false;
      cursor = next;
    }
    check('limit=1 时主数据游标也推进', advanced);
    check('同一 updated_at 的 3 行全部取到且不重复', seen.length == 3, '${seen.length}');

    check('products_since 非法 → 抛 FormatException',
        throws(() => server.pull(productsSince: 'oops')));
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
