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
}
