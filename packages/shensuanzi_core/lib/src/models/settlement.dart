import '../db/schema.dart';
import 'base.dart';

/// 核销关系（业务数据，**不可变**）
///
/// ## 两类 `receipt_doc_id`（`docs/data_model.md` §3.6）
///
/// | 来源 | `receipt.ref_doc_id` |
/// |---|---|
/// | 用户手动创建（RULE-004 / RULE-005） | `null` |
/// | 主机自动生成（RULE-001 / 002 / 007 / 008） | 指向来源主单 |
///
/// 两类在表结构上**无差异**。
///
/// 核心公式：
/// ```text
/// 收款单已核销额 = SUM(amount WHERE receipt_doc_id = X)
/// 收款单未核销额 = receipt.total_amount - 已核销额    ← 预收
/// 单据已收额     = SUM(amount WHERE target_doc_id = X)  ← paid_amount 的唯一口径
/// ```
class Settlement extends ImmutableEntity {
  const Settlement({
    required this.id,
    required this.receiptDocId,
    required this.targetDocId,
    required this.amount,
    required this.seqNo,
    this.timeEstimated = false,
    required this.createdAt,
  });

  factory Settlement.fromRow(Map<String, Object?> row) => Settlement(
    id: row.requiredString('id'),
    receiptDocId: row.requiredString('receipt_doc_id'),
    targetDocId: row.optionalString('target_doc_id'),
    amount: row.requiredInt('amount'),
    seqNo: row.requiredInt('seq_no'),
    timeEstimated: row.requiredBool('time_estimated'),
    createdAt: row.requiredInt('created_at'),
  );

  static const String table = Schema.settlements;

  @override
  final String id;

  /// 收款单 / 付款单。**不会指向主单**（B4'）
  final String receiptDocId;

  /// 被核销单。`null` = 预收 / 预付
  final String? targetDocId;

  final int amount;
  final int seqNo;
  final bool timeEstimated;
  final int createdAt;

  @override
  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'receipt_doc_id': receiptDocId,
    'target_doc_id': targetDocId,
    'amount': amount,
    'seq_no': seqNo,
    'time_estimated': boolToInt(timeEstimated),
    'created_at': createdAt,
  };
}
