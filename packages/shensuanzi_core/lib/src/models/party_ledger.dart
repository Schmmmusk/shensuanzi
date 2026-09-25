import '../db/schema.dart';
import 'base.dart';

/// 往来流水（业务数据，**不可变**）
///
/// [amount] 的口径：**正数 = 对方欠我，负数 = 我欠对方**。
///
/// 记账方向见 `docs/rules.md`：
///
/// | 动作 | `amount` |
/// |---|---|
/// | 采购入库 | `-total`（我欠供应商） |
/// | 采购付款 | `+付款额`（欠款减少） |
/// | 销售（赊账） | `+total`（客户欠我） |
/// | 客户收款 | `-收款额`（客户欠款减少） |
/// | 销售退货 | `-退货额` |
/// | 采购退货 | `+退货额` |
///
/// 余额 = `SUM(party_ledger.amount) GROUP BY party_id`；正数表示应收，负数表示应付。
class PartyLedger extends ImmutableEntity {
  const PartyLedger({
    required this.id,
    required this.partyId,
    required this.documentId,
    required this.amount,
    required this.seqNo,
    required this.occurredAt,
    this.timeEstimated = false,
    required this.createdAt,
  });

  factory PartyLedger.fromRow(Map<String, Object?> row) => PartyLedger(
    id: row.requiredString('id'),
    partyId: row.requiredString('party_id'),
    documentId: row.requiredString('document_id'),
    amount: row.requiredInt('amount'),
    seqNo: row.requiredInt('seq_no'),
    occurredAt: row.requiredInt('occurred_at'),
    timeEstimated: row.requiredBool('time_estimated'),
    createdAt: row.requiredInt('created_at'),
  );

  static const String table = Schema.partyLedger;

  final String id;
  final String partyId;
  final String documentId;

  /// 正数 = 对方欠我，负数 = 我欠对方
  final int amount;
  final int seqNo;
  final int occurredAt;
  final bool timeEstimated;
  final int createdAt;

  @override
  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'party_id': partyId,
    'document_id': documentId,
    'amount': amount,
    'seq_no': seqNo,
    'occurred_at': occurredAt,
    'time_estimated': boolToInt(timeEstimated),
    'created_at': createdAt,
  };
}
