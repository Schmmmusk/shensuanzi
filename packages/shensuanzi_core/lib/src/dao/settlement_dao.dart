import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/schema.dart';
import '../models/settlement.dart';

/// 核销关系 DAO。**不开事务**（`Agents.md` 纪律 1）。
class SettlementDao {
  SettlementDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  void insert(Settlement entry) {
    final Map<String, Object?> row = entry.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.settlements} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
  }

  /// 单据已收额 = `SUM(amount WHERE target_doc_id = X)`
  /// —— **`paid_amount` 的唯一口径**（`docs/data_model.md` §五 B4）
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

  /// 收付款单已核销额 = `SUM(amount WHERE receipt_doc_id = X)`
  ///
  /// `receipt.total_amount - 已核销额` 即**预收 / 预付余额**
  int allocatedAmountOf(String receiptDocId) {
    final Row row = _raw
        .select(
          'SELECT COALESCE(SUM(amount), 0) AS s FROM ${Schema.settlements} '
          'WHERE receipt_doc_id = ?',
          <Object?>[receiptDocId],
        )
        .first;
    return row['s']! as int;
  }

  List<Settlement> ofReceipt(String receiptDocId) => _raw
      .select(
        'SELECT * FROM ${Schema.settlements} WHERE receipt_doc_id = ? ORDER BY seq_no',
        <Object?>[receiptDocId],
      )
      .map(Settlement.fromRow)
      .toList(growable: false);

  List<Settlement> ofTarget(String targetDocId) => _raw
      .select(
        'SELECT * FROM ${Schema.settlements} WHERE target_doc_id = ? ORDER BY seq_no',
        <Object?>[targetDocId],
      )
      .map(Settlement.fromRow)
      .toList(growable: false);

  /// 该 `receipt` 是否已核销过该 `target`（用于诊断重复核销）
  bool links(String receiptDocId, String targetDocId) => _raw
      .select(
        'SELECT 1 FROM ${Schema.settlements} '
        'WHERE receipt_doc_id = ? AND target_doc_id = ? LIMIT 1',
        <Object?>[receiptDocId, targetDocId],
      )
      .isNotEmpty;

  /// **这笔收款核销了哪些单**（详情页：收款单 → 对端）。
  ///
  /// `LEFT JOIN`：`target_doc_id = NULL`（预收）也返回，`docId` / `docNo` 为 null
  /// —— 预收是**要显示**的信息（「这 5000 里有 800 是预收」）。
  List<SettlementView> settlementsOfReceipt(String receiptDocId) => _views(
    'WHERE s.receipt_doc_id = ?',
    'd.id = s.target_doc_id',
    <Object?>[receiptDocId],
  );

  /// **这单被哪些收款核销过**（详情页：销售单 → 对端）。
  ///
  /// 与 [settlementsOfReceipt] **对称**：同一张 `settlements` 表的另一个方向，
  /// 命名对称 → 实现对称 → 测试对称（reply.md 六个待审查项 · 6）。
  List<SettlementView> settlementsOfTarget(String targetDocId) => _views(
    'WHERE s.target_doc_id = ?',
    'd.id = s.receipt_doc_id',
    <Object?>[targetDocId],
  );

  /// 两个方向共用的查询体（只差「哪一列是对端」）
  List<SettlementView> _views(
    String where,
    String joinOn,
    List<Object?> args,
  ) => _raw
      .select(
        'SELECT d.id AS doc_id, d.doc_no AS doc_no, '
        's.amount AS amount, s.created_at AS created_at '
        'FROM ${Schema.settlements} s '
        'LEFT JOIN ${Schema.documents} d ON $joinOn '
        '$where '
        'ORDER BY s.seq_no',
        args,
      )
      .map(
        (Row r) => SettlementView(
          docId: r['doc_id'] as String?,
          docNo: r['doc_no'] as String?,
          amount: r['amount']! as int,
          occurredAt: r['created_at']! as int,
        ),
      )
      .toList(growable: false);
}
