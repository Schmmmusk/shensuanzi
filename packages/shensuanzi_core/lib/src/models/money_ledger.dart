import '../db/schema.dart';
import 'base.dart';

/// 资金流水（业务数据，**不可变**）
///
/// ## 方案 C 下的强约束（`Agents.md` 纪律 11）
///
/// **`document_id` 必须指向一张 `receipt` / `payment` 单，绝不指向主单。**
/// 即"任何一笔钱的进或出，都对应一张独立的收付款单"（`docs/rules.md` §零）。
/// 主单（`purchase` / `sale` / …）不直接写本表。
class MoneyLedger extends ImmutableEntity {
  const MoneyLedger({
    required this.id,
    required this.accountId,
    required this.documentId,
    required this.amount,
    required this.seqNo,
    required this.occurredAt,
    this.timeEstimated = false,
    this.externalRef,
    required this.createdAt,
  });

  factory MoneyLedger.fromRow(Map<String, Object?> row) => MoneyLedger(
    id: row.requiredString('id'),
    accountId: row.requiredString('account_id'),
    documentId: row.requiredString('document_id'),
    amount: row.requiredInt('amount'),
    seqNo: row.requiredInt('seq_no'),
    occurredAt: row.requiredInt('occurred_at'),
    timeEstimated: row.requiredBool('time_estimated'),
    externalRef: row.optionalString('external_ref'),
    createdAt: row.requiredInt('created_at'),
  );

  static const String table = Schema.moneyLedger;

  @override
  final String id;
  final String accountId;

  /// ⚠️ **必须指向 `receipt` / `payment` 单**
  final String documentId;

  /// 正数收入，负数支出
  final int amount;
  final int seqNo;
  final int occurredAt;
  final bool timeEstimated;

  /// 预留：微信 / 支付宝交易号
  final String? externalRef;
  final int createdAt;

  @override
  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'account_id': accountId,
    'document_id': documentId,
    'amount': amount,
    'seq_no': seqNo,
    'occurred_at': occurredAt,
    'time_estimated': boolToInt(timeEstimated),
    'external_ref': externalRef,
    'created_at': createdAt,
  };
}
