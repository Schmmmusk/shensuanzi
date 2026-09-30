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
  /// 列表（默认过滤掉**自动生成的收付款单**，见 [_summaries]）
  List<DocumentSummary> listDocuments({
    DocType? type,
    int? sinceMillis,
    int limit = 200,
    bool includeAutoSettlements = false,
  }) => _summaries(
    type: type,
    sinceMillis: sinceMillis,
    limit: limit,
    includeAutoSettlements: includeAutoSettlements,
  );

  /// **导出用**：不分页（§AF-5）。
  ///
  /// 为什么另开一个入口而不是让调用方传 `limit: null`：导出跟列表的
  /// **失败代价完全不同** —— 列表少一行用户会翻页找，导出少一行
  /// **谁都不知道**（他拿去给会计了）。让「不分页」这件事在调用点
  /// 显式可读，比省一个方法重要。
  ///
  /// 过滤条件与 [listDocuments] **完全一致**（同一个 `_summaries`），
  /// 只是不设 `LIMIT`。个体户一年的单据几千条，一次读进内存无压力。
  List<DocumentSummary> listDocumentsForExport({
    DocType? type,
    int? sinceMillis,
    bool includeAutoSettlements = false,
  }) => _summaries(
    type: type,
    sinceMillis: sinceMillis,
    limit: null,
    includeAutoSettlements: includeAutoSettlements,
  );

  /// 详情页用：按 id 取一行（含对方名）。不存在 → `null`。
  ///
  /// 与列表**同一份 JOIN**（`LEFT JOIN parties`），所以对方名的口径一致
  /// —— 散客 / 散采为 `null`，由 `documentPartyLabel` 统一成文字。
  DocumentSummary? summaryById(String id) {
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT d.*, pa.name AS party_name '
      'FROM ${Schema.documents} d '
      'LEFT JOIN ${Schema.parties} pa ON pa.id = d.party_id '
      'WHERE d.id = ? LIMIT 1',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    final Map<String, Object?> row = rows.first;
    return DocumentSummary(
      document: Document.fromRow(row),
      partyName: row['party_name'] as String?,
    );
  }

  List<DocumentSummary> _summaries({
    DocType? type,
    int? sinceMillis,
    required int? limit,
    bool includeAutoSettlements = false,
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
    if (!includeAutoSettlements) {
      // **自动生成的收付款单不进列表**（§AN·二 / `docs/data_model.md` §3.6）：
      // 销售时主机自动生成收款单，若也列出来，用户看到「一笔交易两条记录」
      // 会以为系统记重了。手动创建的收款单（`ref_doc_id IS NULL`）**要显示**。
      //
      // ⚠️ 条件必须**同时**限定 `doc_type` —— 只判 `ref_doc_id IS NOT NULL`
      // 会把**退货单**（`sale_return` / `purchase_return` 的 `ref_doc_id`
      // 指向原单）一起滤掉，退货凭空消失在列表里。
      conditions.add(
        "NOT (d.doc_type IN ('receipt', 'payment') AND d.ref_doc_id IS NOT NULL)",
      );
    }
    final String where = conditions.isEmpty
        ? ''
        : 'WHERE ${conditions.join(' AND ')} ';
    final String tail = limit == null ? '' : 'LIMIT ?';
    if (limit != null) args.add(limit);

    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT d.*, pa.name AS party_name '
      'FROM ${Schema.documents} d '
      'LEFT JOIN ${Schema.parties} pa ON pa.id = d.party_id '
      '$where'
      'ORDER BY d.occurred_at DESC, d.created_at DESC '
      '$tail',
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
