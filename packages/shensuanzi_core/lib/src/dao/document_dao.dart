import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/schema.dart';
import '../models/document.dart';
import '../models/document_line.dart';

/// 单据 DAO。**不开事务**（`Agents.md` 纪律 1）。
///
/// ⚠️ 本 DAO **只提供两个写入口**：
/// - [insert] / [insertIfAbsent]：新建单据（业务数据只插入）
/// - [updateStatusAndPaid]：**唯一**允许的 UPDATE，且只碰白名单三列
///
/// 其余任何 UPDATE 都必须在这里加方法并同步 `docs/data_model.md`。
class DocumentDao {
  DocumentDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  /// 幂等插入（同步路径的核心）：单据已存在返回 `false` 且**不修改任何数据**。
  /// 客户端重试因此不会产生重复单据（`docs/sync_protocol.md` §二）。
  bool insertIfAbsent(Document document, List<DocumentLine> lines) {
    if (exists(document.id)) return false;
    insert(document, lines);
    return true;
  }

  void insert(Document document, List<DocumentLine> lines) {
    insertRow(document);
    for (final DocumentLine line in lines) {
      insertLine(line);
    }
  }

  void insertRow(Document document) {
    final Map<String, Object?> row = document.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.documents} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
  }

  void insertLine(DocumentLine line) {
    final Map<String, Object?> row = line.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.documentLines} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
  }

  bool exists(String id) => _raw
      .select('SELECT 1 FROM ${Schema.documents} WHERE id = ? LIMIT 1', <Object?>[
        id,
      ])
      .isNotEmpty;

  /// 单据列表查询（§AC：单据页，只读）。
  ///
  /// - [type] 筛选单据类型；`null` = 全部
  /// - [sinceMillis] 只返回 `occurred_at >=` 该时间的（时间范围筛选）
  /// - JOIN parties 带回**对方名**（散客/散采的 `party_id` 为空 ⇒ `partyName` 为
  ///   `null`，UI 显示「散客」/「散采」而不是空白，§AA 六同款处理）
  /// - 按 `occurred_at` 降序、`created_at` 降序兜底
  List<DocumentSummary> listDocuments({
    DocType? type,
    int? sinceMillis,
    int limit = 200,
  }) {
    final List<Object?> args = <Object?>[];
    final List<String> conditions = <String>[];
    if (type != null) {
      conditions.add('d.doc_type = ?');
      args.add(type.wire);
    }
    if (sinceMillis != null) {
      conditions.add('d.occurred_at >= ?');
      args.add(sinceMillis);
    }
    final String where = conditions.isEmpty
        ? ''
        : 'WHERE ${conditions.join(' AND ')} ';
    args.add(limit);

    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT d.*, pa.name AS party_name '
      'FROM ${Schema.documents} d '
      'LEFT JOIN ${Schema.parties} pa ON pa.id = d.party_id '
      '$where'
      'ORDER BY d.occurred_at DESC, d.created_at DESC '
      'LIMIT ?',
      args,
    );
    return <DocumentSummary>[
      for (final Map<String, Object?> row in rows)
        DocumentSummary(
          document: Document.fromRow(row),
          partyName: row['party_name'] as String?,
        ),
    ];
  }

  Document? findById(String id) {
    final ResultSet rows = _raw.select(
      'SELECT * FROM ${Schema.documents} WHERE id = ?',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return Document.fromRow(rows.first);
  }

  List<DocumentLine> linesOf(String documentId) => _raw
      .select(
        'SELECT * FROM ${Schema.documentLines} WHERE document_id = ? ORDER BY rowid',
        <Object?>[documentId],
      )
      .map(DocumentLine.fromRow)
      .toList(growable: false);

  /// **唯一允许的 UPDATE 入口**。只写 `status` / `paid_amount` / `updated_at`。
  ///
  /// 只在**主机本地事务内**被调用（`RuleEngine`），客户端无法直接触发
  /// （`docs/sync_protocol.md` §三：状态变更走 `documentAction`）。
  void updateStatusAndPaid({
    required String id,
    required int updatedAt,
    DocStatus? status,
    int? paidAmount,
  }) {
    final List<String> sets = <String>[];
    final List<Object?> args = <Object?>[];
    if (status != null) {
      sets.add('status = ?');
      args.add(status.wire);
    }
    if (paidAmount != null) {
      sets.add('paid_amount = ?');
      args.add(paidAmount);
    }
    sets.add('updated_at = ?');
    args.add(updatedAt);
    args.add(id);
    _raw.execute(
      'UPDATE ${Schema.documents} SET ${sets.join(', ')} WHERE id = ?',
      args,
    );
  }

  /// 同前缀下已存在的最大单号（供 `DocNoGenerator` 解析序号）。
  /// [prefixWithDate] 形如 `XS20260925-`。
  String? latestDocNo(String prefixWithDate) {
    final ResultSet rows = _raw.select(
      'SELECT doc_no FROM ${Schema.documents} WHERE doc_no LIKE ? '
      'ORDER BY doc_no DESC LIMIT 1',
      <Object?>['$prefixWithDate%'],
    );
    if (rows.isEmpty) return null;
    return rows.first['doc_no']! as String;
  }

  /// 已核销额（真相口径）——`SUM(settlements.amount)`，
  /// 用于校验 `paid_amount` 缓存（`docs/data_model.md` §五 不变量 4）。
  int settledAmountOf(String targetDocId) {
    final Row row = _raw
        .select(
          'SELECT COALESCE(SUM(amount), 0) AS s FROM ${Schema.settlements} '
          'WHERE target_doc_id = ?',
          <Object?>[targetDocId],
        )
        .first;
    return row['s']! as int;
  }
}

/// [DocumentDao.listDocuments] 的一行：单据 + 对方名（LEFT JOIN，散客为 null）。
class DocumentSummary {
  const DocumentSummary({required this.document, required this.partyName});

  final Document document;

  /// 对方名；散客 / 散采（无对方）为 `null` —— UI 显示「散客」/「散采」
  final String? partyName;
}
