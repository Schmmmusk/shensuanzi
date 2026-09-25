import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/schema.dart';
import '../models/document.dart';
import '../models/document_line.dart';
import '../rules/payment_entry.dart';
import '../rules/rule_engine.dart';
import 'sync_operation.dart';
import 'whitelist.dart';

/// `documents` / `document_lines` 的拉取游标：`"<created_at>|<id>"`。
///
/// **为什么不只用一个 `created_at`**：它**不唯一**。用 `>` 会丢掉同一毫秒里
/// 剩下的行；用 `>=` 又会在「同一毫秒的行数 > `limit`」时**永远取回同一页**
/// （死循环）。复合游标是唯一既**不丢行**又能**保证推进**的方案，
/// 而且与 `sync_protocol.md` §七「客户端按 `(created_at, id)` 排序」一致。
///
/// 四张流水表相反：`seq_no` 本身唯一且单调，所以那些表的游标就是整数字符串。
/// 两者在 wire 上统一为**字符串**（HTTP 查询串本来就是字符串）。
class SyncCursor {
  const SyncCursor(this.createdAt, this.id);

  /// 起始游标（`doc_since` / `line_since` 缺省时用）
  static const SyncCursor start = SyncCursor(0, '');

  final int createdAt;
  final String id;

  static SyncCursor parse(String? raw) {
    if (raw == null || raw.isEmpty) return start;
    final int bar = raw.indexOf('|');
    if (bar < 0) {
      throw FormatException(
        '游标格式应为 "<created_at>|<id>"（如 "1700000000000|0192…"），实际 "$raw"',
      );
    }
    return SyncCursor(int.parse(raw.substring(0, bar)), raw.substring(bar + 1));
  }

  String get wire => '$createdAt|$id';

  @override
  String toString() => wire;
}

/// 一次拉取的结果。
///
/// [entities] 的键就是**表名**（与 `sync_protocol.md` §8.2 的响应字段一一对应）；
/// [nextCursors] 的键见 [SyncServer] 的 `cursor*` 常量。
class SyncPullResult {
  const SyncPullResult({required this.entities, required this.nextCursors});

  final Map<String, List<Map<String, Object?>>> entities;
  final Map<String, String> nextCursors;

  int countOf(String entity) => entities[entity]?.length ?? 0;

  Map<String, Object?> toJson() => <String, Object?>{
    ...entities,
    'next_cursors': nextCursors,
  };
}

/// 主机侧同步服务（`docs/sync_protocol.md`）。
///
/// ## 边界
///
/// - **不含 HTTP**。本类接收 [SyncOperation]、返回 [SyncResponse]。
///   HTTP 适配层（shelf）属于 Windows 应用侧，只负责 JSON ↔ 对象的搬运。
///   这样同步逻辑是**纯 Dart**，可在没有网络、没有 Flutter 的环境里测试。
/// - **落库一律走 [RuleEngine]**（`Agents.md` 纪律 9）：客户端只推 `Document`，
///   主机按 `doc_type` 分派规则。`SyncServer` 自己**不写任何流水**。
/// - **表名 / 列名必须先过白名单**（纪律 10）：见 [SyncWhitelist]。
///   本文件里所有拼进 SQL 的表名都只来自白名单常量或 `Schema.*` 常量，
///   **没有任何一处来自客户端输入**。
/// - **一条 op 一个事务**。失败只影响该条，不回滚同一批里的其它条目
///   （它们是各自独立的队列条目，见 §六）。
class SyncServer {
  SyncServer(this.db) : _engine = RuleEngine(db);

  final Db db;
  final RuleEngine _engine;

  Database get _raw => db.raw;

  /// 一次拉取每个实体的最大行数
  static const int defaultPullLimit = 500;

  // 游标键（= `sync_protocol.md` §8.2 的查询参数名与 `next_cursors` 键）
  static const String cursorStock = 'stock_since';
  static const String cursorMoney = 'money_since';
  static const String cursorParty = 'party_since';
  static const String cursorSettle = 'settle_since';
  static const String cursorDoc = 'doc_since';

  /// `createDocument` 的 payload 允许出现的顶层字段（`sync_protocol.md` §8.1）
  static const Set<String> documentPayloadKeys = <String>{
    'document',
    'lines',
    'immediate_payments',
    'allocations',
  };

  // ------------------------------------------------------------ 推送

  /// 批量推送（`sync_protocol.md` §8.1）。**逐条独立处理**，互不影响。
  ///
  /// [now] = 主机当前时间（毫秒）。**必须由调用方传入**，不在内部取 ——
  /// 这样单测可复现，也让「主机时钟为准」成为显式约定。
  List<SyncResponse> push(
    List<SyncOperation> operations, {
    required int now,
  }) => <SyncResponse>[
    for (final SyncOperation op in operations) handle(op, now: now),
  ];

  /// 处理单条操作。
  SyncResponse handle(SyncOperation op, {required int now}) {
    try {
      if (!SyncWhitelist.isWritableTable(op.entity)) {
        return SyncResponse.rejected(op.entityId, '表不在白名单内：${op.entity}');
      }
      switch (op.operation) {
        case SyncOpType.createDocument:
          return _createDocument(op, now);
        case SyncOpType.createMasterData:
          return _createMasterData(op, now);
        case SyncOpType.updateMasterData:
          return _updateMasterData(op, now);
        case SyncOpType.deleteMasterData:
          return _deleteMasterData(op, now);
        case SyncOpType.documentAction:
          return SyncResponse.rejected(
            op.entityId,
            'action_not_implemented: v1 不落地「动作」通道'
            '（R-3，见 docs/reply.md）',
          );
      }
    } on FormatException catch (error) {
      return SyncResponse.rejected(op.entityId, error.message);
    } catch (error) {
      return SyncResponse.rejected(op.entityId, '操作失败：$error');
    }
  }

  // ------------------------------------------------------------ createDocument

  SyncResponse _createDocument(SyncOperation op, int now) {
    if (op.entity != Schema.documents) {
      return SyncResponse.rejected(
        op.entityId,
        'createDocument 的 entity 必须是 ${Schema.documents}，实际 ${op.entity}',
      );
    }

    final Set<String> unknownKeys = op.payload.keys
        .toSet()
        .difference(documentPayloadKeys);
    if (unknownKeys.isNotEmpty) {
      return SyncResponse.rejected(
        op.entityId,
        'createDocument 的 payload 含未知字段：${unknownKeys.join(', ')}'
        '（允许：${documentPayloadKeys.join(', ')}）',
      );
    }

    final Object? rawDocument = op.payload['document'];
    if (rawDocument is! Map) {
      return SyncResponse.rejected(
        op.entityId,
        'createDocument 缺少 payload.document',
      );
    }
    final Map<String, Object?> raw = Map<String, Object?>.from(rawDocument);

    final List<String> badColumns = SyncWhitelist.offendingColumns(
      Schema.documents,
      raw.keys,
    );
    if (badColumns.isNotEmpty) {
      return SyncResponse.rejected(
        op.entityId,
        'documents 含不可写列：${badColumns.join(', ')}',
      );
    }

    final Map<String, Object?> values = SyncValueCheck.normalize(raw);
    if (values['id'] != op.entityId) {
      return SyncResponse.rejected(
        op.entityId,
        'payload.document.id（${values['id']}）必须等于 entity_id（${op.entityId}）'
        '—— id 是幂等键（sync_protocol.md §二）',
      );
    }

    // 主机专属字段补默认值。客户端的值不可能覆盖它们 ——
    // 白名单已把 hostOnlyColumns 挡在外面，所以展开顺序是安全的。
    final Map<String, Object?> row = <String, Object?>{
      'doc_no': '', // 空 = 临时展示号，主机 `_prepare` 会分配正式单号
      'total_amount': 0,
      'paid_amount': 0,
      'time_estimated': 0,
      'created_at': now,
      'updated_at': now,
      ...values,
    };

    final Document document;
    final List<DocumentLine> lines;
    try {
      document = Document.fromRow(row);
      lines = _linesFrom(op.payload['lines'], documentId: op.entityId);
    } catch (error) {
      return SyncResponse.rejected(
        op.entityId,
        '单据字段缺失或类型不符（必填：id / doc_type / status / occurred_at）：$error',
      );
    }

    final List<PaymentEntry> immediate = _jsonList(
      op.payload['immediate_payments'],
      'immediate_payments',
      PaymentEntry.fromJson,
    );
    final List<Allocation> allocations = _jsonList(
      op.payload['allocations'],
      'allocations',
      Allocation.fromJson,
    );

    // 落库一律走 RuleEngine（纪律 9）：互斥校验、按 doc_type 分派、
    // seq_no 分配、流水写入、paid_amount 刷新全在里面。
    // 事务也由 RuleEngine 开 —— 此处**不再包一层**。
    return _mapOutcome(
      op.entityId,
      _engine.dispatch(
        document: document,
        lines: lines,
        immediatePayments: immediate,
        allocations: allocations,
        now: now,
      ),
    );
  }

  // ------------------------------------------------------------ 主数据

  SyncResponse _createMasterData(SyncOperation op, int now) {
    final SyncResponse? guard = _requireMasterData(op);
    if (guard != null) return guard;

    final Map<String, Object?> values = SyncValueCheck.normalize(op.payload);
    if (values['id'] != null && values['id'] != op.entityId) {
      return SyncResponse.rejected(
        op.entityId,
        'payload.id（${values['id']}）必须等于 entity_id（${op.entityId}）',
      );
    }

    return db.transaction<SyncResponse>(() {
      if (_exists(op.entity, op.entityId)) {
        return SyncResponse(
          entityId: op.entityId,
          status: SyncStatus.alreadyExists,
        );
      }
      // created_at / updated_at / sync_version 由主机写（纪律 10 + §七）
      _insertRow(op.entity, <String, Object?>{
        ...values,
        'id': op.entityId,
        'created_at': now,
        'updated_at': now,
        'sync_version': 0,
      });
      return SyncResponse(entityId: op.entityId, status: SyncStatus.applied);
    });
  }

  SyncResponse _updateMasterData(SyncOperation op, int now) {
    final SyncResponse? guard = _requireMasterData(op);
    if (guard != null) return guard;

    if (op.baseVersion == null) {
      return SyncResponse.rejected(
        op.entityId,
        'updateMasterData 必须带 base_version（乐观锁，sync_protocol.md §四）',
      );
    }

    final Map<String, Object?> values = SyncValueCheck.normalize(op.payload)
      ..remove('id');

    return db.transaction<SyncResponse>(() {
      final Row? current = _findRow(op.entity, op.entityId);
      if (current == null) {
        return SyncResponse.rejected(op.entityId, '主数据不存在：${op.entityId}');
      }

      final int version = current['sync_version']! as int;
      if (version != op.baseVersion) {
        // 主机赢：把主机侧当前状态回给客户端（§四）
        return SyncResponse(
          entityId: op.entityId,
          status: SyncStatus.conflict,
          serverState: Map<String, Object?>.from(current),
        );
      }

      _updateRow(op.entity, op.entityId, <String, Object?>{
        ...values,
        'updated_at': now,
        'sync_version': version + 1,
      });
      return SyncResponse(entityId: op.entityId, status: SyncStatus.applied);
    });
  }

  SyncResponse _deleteMasterData(SyncOperation op, int now) {
    final SyncResponse? guard = _requireMasterData(op);
    if (guard != null) return guard;

    final Set<String> extraKeys = op.payload.keys
        .toSet()
        .difference(const <String>{'id'});
    if (extraKeys.isNotEmpty) {
      return SyncResponse.rejected(
        op.entityId,
        'deleteMasterData 的 payload 只允许 id，实际含：${extraKeys.join(', ')}',
      );
    }

    return db.transaction<SyncResponse>(() {
      final Row? current = _findRow(op.entity, op.entityId);
      if (current == null) {
        return SyncResponse.rejected(op.entityId, '主数据不存在：${op.entityId}');
      }
      if ((current['is_active']! as int) == 0) {
        return SyncResponse(
          entityId: op.entityId,
          status: SyncStatus.alreadyExists, // 已软删 → 幂等
        );
      }
      // 软删：只翻 is_active，**从不 DELETE**
      _updateRow(op.entity, op.entityId, <String, Object?>{
        'is_active': 0,
        'updated_at': now,
        'sync_version': (current['sync_version']! as int) + 1,
      });
      return SyncResponse(entityId: op.entityId, status: SyncStatus.applied);
    });
  }

  /// 主数据操作的公共前置：表必须是主数据表，且 payload 列名全在白名单内。
  /// 返回非 null 表示已经可以短路返回。
  SyncResponse? _requireMasterData(SyncOperation op) {
    if (!SyncWhitelist.isMasterData(op.entity)) {
      return SyncResponse.rejected(
        op.entityId,
        '${op.operation.wire} 只支持主数据表'
        '（${SyncWhitelist.masterDataTables.join(' / ')}），实际 ${op.entity}',
      );
    }
    final List<String> badColumns = SyncWhitelist.offendingColumns(
      op.entity,
      op.payload.keys,
    );
    if (badColumns.isNotEmpty) {
      return SyncResponse.rejected(
        op.entityId,
        '${op.entity} 含不可写列：${badColumns.join(', ')}',
      );
    }
    return null;
  }

  // ------------------------------------------------------------ 拉取

  /// 增量拉取（`sync_protocol.md` §8.2）。
  ///
  /// ## 游标语义
  ///
  /// | 实体 | 游标 | 为什么 |
  /// |---|---|---|
  /// | 四张流水 | `seq_no`（整数字符串） | `seq_no` 唯一且单调，`>` 即安全 |
  /// | `documents` | `"<created_at>\|<id>"` | `created_at` **不唯一**，见 [SyncCursor] |
  /// | `document_lines` | **无独立游标** | 明细随主单走，理由见下 |
  ///
  /// **`document_lines` 没有独立游标是刻意的**：它**没有时间列**（`data_model.md`
  /// §3.2），而且明细与主单**在同一个事务里写入**，永远不会单独存在。
  /// 所以它按「本页 `documents`」取 —— 这正是 §8.2 只给了 `doc_since`
  /// 而没有 `line_since` 的原因。
  ///
  /// 因此 [limit] 限制的是**主单条数**；明细条数由「本页主单的明细总数」决定，
  /// **不额外截断** —— 截断会造出「有主单但明细不全」的镜像，
  /// 而那恰恰是「明细随主单走」要避免的状态。
  SyncPullResult pull({
    String stockSince = '0',
    String moneySince = '0',
    String partySince = '0',
    String settleSince = '0',
    String docSince = '',
    int limit = defaultPullLimit,
  }) {
    final Map<String, List<Map<String, Object?>>> entities =
        <String, List<Map<String, Object?>>>{};
    final Map<String, String> next = <String, String>{};

    void bySeqNo(String table, String key, String since) {
      final int from = _parseSeqNoCursor(since, key);
      final List<Map<String, Object?>> rows = _select(
        'SELECT * FROM $table WHERE seq_no > ? ORDER BY seq_no LIMIT ?',
        <Object?>[from, limit],
      );
      entities[table] = rows;
      next[key] = rows.isEmpty ? '$from' : '${rows.last['seq_no']! as int}';
    }

    bySeqNo(Schema.stockLedger, cursorStock, stockSince);
    bySeqNo(Schema.moneyLedger, cursorMoney, moneySince);
    bySeqNo(Schema.partyLedger, cursorParty, partySince);
    bySeqNo(Schema.settlements, cursorSettle, settleSince);

    // documents 与「它这一页的明细」用**同一个页边界**，保证不漏不串。
    final SyncCursor from = SyncCursor.parse(docSince);
    final List<Map<String, Object?>> documents = _select(
      'SELECT * FROM ${Schema.documents} '
      'WHERE created_at > ? OR (created_at = ? AND id > ?) '
      'ORDER BY created_at, id LIMIT ?',
      <Object?>[from.createdAt, from.createdAt, from.id, limit],
    );
    entities[Schema.documents] = documents;
    entities[Schema.documentLines] = _linesOfPage(from, limit);
    next[cursorDoc] = documents.isEmpty
        ? from.wire
        : SyncCursor(
            documents.last['created_at']! as int,
            documents.last['id']! as String,
          ).wire;

    return SyncPullResult(entities: entities, nextCursors: next);
  }

  /// 取「本页 `documents` 的全部明细」。谓词与主单页边界**完全一致**。
  List<Map<String, Object?>> _linesOfPage(SyncCursor from, int limit) => _select(
    'SELECT dl.* FROM ${Schema.documentLines} dl '
    'JOIN ${Schema.documents} d ON d.id = dl.document_id '
    'WHERE d.created_at > ? OR (d.created_at = ? AND d.id > ?) '
    'ORDER BY d.created_at, d.id, dl.id',
    <Object?>[from.createdAt, from.createdAt, from.id],
  );

  // ------------------------------------------------------------ 内部

  SyncResponse _mapOutcome(String entityId, RuleOutcome outcome) {
    switch (outcome.status) {
      case RuleStatus.applied:
        return SyncResponse(entityId: entityId, status: SyncStatus.applied);
      case RuleStatus.alreadyExists:
        return SyncResponse(
          entityId: entityId,
          status: SyncStatus.alreadyExists,
        );
      case RuleStatus.rejected:
        return SyncResponse.rejected(entityId, outcome.reason ?? '规则拒绝');
    }
  }

  /// `payload.lines` → `DocumentLine` 列表。
  ///
  /// `document_id` 缺省时补成 [documentId] —— 它由 payload 结构唯一确定，
  /// 且 `RuleEngine` 还会再校验一次它是否等于主单 id，所以补默认值不会掩盖错误。
  List<DocumentLine> _linesFrom(Object? raw, {required String documentId}) {
    if (raw == null) return const <DocumentLine>[];
    if (raw is! List) throw const FormatException('payload.lines 必须是数组');
    return <DocumentLine>[
      for (final Object? item in raw)
        DocumentLine.fromRow(_lineRow(item, documentId)),
    ];
  }

  Map<String, Object?> _lineRow(Object? item, String documentId) {
    if (item is! Map) {
      throw const FormatException('payload.lines 的元素必须是对象');
    }
    final Map<String, Object?> row = Map<String, Object?>.from(item);
    final List<String> badColumns = SyncWhitelist.offendingColumns(
      Schema.documentLines,
      row.keys,
    );
    if (badColumns.isNotEmpty) {
      throw FormatException('document_lines 含不可写列：${badColumns.join(', ')}');
    }
    row['document_id'] ??= documentId;
    return SyncValueCheck.normalize(row);
  }

  List<T> _jsonList<T>(
    Object? raw,
    String field,
    T Function(Map<String, Object?>) fromJson,
  ) {
    if (raw == null) return <T>[];
    if (raw is! List) {
      throw FormatException('payload.$field 必须是数组');
    }
    return <T>[
      for (final Object? item in raw)
        if (item is Map)
          fromJson(SyncValueCheck.normalize(Map<String, Object?>.from(item)))
        else
          throw FormatException('payload.$field 的元素必须是对象'),
    ];
  }

  int _parseSeqNoCursor(String raw, String key) {
    final int? value = int.tryParse(raw);
    if (value == null) {
      throw FormatException('游标 $key 必须是整数，实际 "$raw"');
    }
    return value;
  }

  List<Map<String, Object?>> _select(String sql, List<Object?> args) =>
      <Map<String, Object?>>[
        for (final Row row in _raw.select(sql, args))
          Map<String, Object?>.from(row),
      ];

  /// ⚠️ [id] 是绑定参数，但 [table] 会拼进 SQL —— 调用点必须先过白名单。
  bool _exists(String table, String id) => _raw
      .select('SELECT 1 FROM $table WHERE id = ? LIMIT 1', <Object?>[id])
      .isNotEmpty;

  /// ⚠️ 同 [_exists]：`table` 必须已过白名单。
  Row? _findRow(String table, String id) {
    final ResultSet rows = _raw.select(
      'SELECT * FROM $table WHERE id = ?',
      <Object?>[id],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// ⚠️ `table` 与 `row.keys` 必须已过白名单。
  void _insertRow(String table, Map<String, Object?> row) {
    final List<String> columns = row.keys.toList(growable: false);
    _raw.execute(
      'INSERT INTO $table (${columns.join(', ')}) '
      'VALUES (${List<String>.filled(columns.length, '?').join(', ')})',
      <Object?>[for (final String column in columns) row[column]],
    );
  }

  /// ⚠️ 同 [_insertRow]。
  void _updateRow(String table, String id, Map<String, Object?> values) {
    if (values.isEmpty) return;
    final List<String> columns = values.keys.toList(growable: false);
    _raw.execute(
      'UPDATE $table SET '
      '${columns.map((String column) => '$column = ?').join(', ')} '
      'WHERE id = ?',
      <Object?>[for (final String column in columns) values[column], id],
    );
  }
}
