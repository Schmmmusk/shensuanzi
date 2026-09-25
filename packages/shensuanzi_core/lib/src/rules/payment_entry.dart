/// 同步 payload 里的两类资金条目（`docs/sync_protocol.md` §8.1）。
///
/// 两者**互斥**：一个 `createDocument` op 要么带 `immediate_payments`（说明是主单），
/// 要么带 `allocations`（说明是独立收付款单），不能同时非空。
library;

/// **立即收付款条目** —— 用于主单（`purchase` / `sale` / `sale_return` / `purchase_return`）。
///
/// 主机据此**自动生成**一张 `receipt` / `payment` 单，并写 `settlement` +
/// `money_ledger` + `party_ledger`。客户端**不预生成**那些单据。
class PaymentEntry {
  const PaymentEntry({required this.accountId, required this.amount});

  factory PaymentEntry.fromJson(Map<String, Object?> json) => PaymentEntry(
    accountId: json['account_id']! as String,
    amount: json['amount']! as int,
  );

  /// 资金账户。必须已存在（外键会拒）
  final String accountId;

  /// 金额（分），**必须 > 0**
  final int amount;

  Map<String, Object?> toJson() => <String, Object?>{
    'account_id': accountId,
    'amount': amount,
  };
}

/// **核销分配条目** —— 用于用户手动创建的独立收付款单（RULE-004 / RULE-005）。
class Allocation {
  const Allocation({required this.targetDocId, required this.amount});

  factory Allocation.fromJson(Map<String, Object?> json) => Allocation(
    targetDocId: json['target_doc_id'] as String?,
    amount: json['amount']! as int,
  );

  /// 被核销单。`null` = 预收 / 预付
  final String? targetDocId;

  /// 本次核销金额（分），**必须 > 0**
  final int amount;

  Map<String, Object?> toJson() => <String, Object?>{
    'target_doc_id': targetDocId,
    'amount': amount,
  };
}
