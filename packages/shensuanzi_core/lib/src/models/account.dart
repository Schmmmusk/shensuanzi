import '../db/read_failures.dart';
import '../db/schema.dart';
import 'base.dart';

/// 资金账户类型，见 `docs/data_model.md` §2.3
enum AccountType {
  cash('cash'),
  wechat('wechat'),
  alipay('alipay'),
  bank('bank'),
  other('other');

  const AccountType(this.wire);

  final String wire;

  /// 严格版：**不认识就抛**。用于 **wire 报文校验**（客户端推上来的畸形请求要拒绝，
  /// 那条通道是 `RejectCode` / `malformedSyncRequestReason`）。
  static AccountType fromWire(String value) => AccountType.values.firstWhere(
    (AccountType type) => type.wire == value,
    orElse: () => throw ArgumentError('未知账户类型：$value'),
  );

  /// **读库用**（#42 甲 · L2）：未知值 ⇒ `null`，**不抛**。
  ///
  /// 调用方按政策处置（兜底保留该行 / 跳过该行），并**必须记进**
  /// `ReadFailureLog` —— 不记就是静默丢数据（裁定：L4 是 L1 的前提）。
  static AccountType? fromWireOrNull(String value) {
    for (final AccountType type in AccountType.values) {
      if (type.wire == value) return type;
    }
    return null;
  }
}

/// 资金账户（主数据）
class Account extends MutableEntity {
  const Account({
    required this.id,
    required this.name,
    required this.type,
    this.initialBalance = 0,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
    this.syncVersion = 0,
  });

  /// [failures] 用来记录「这一行的哪一列被兜底了」（**不传 = 只兜底不记录**，
  /// 自检 / 纯单元测试用）。见 `read_failures.dart`。
  ///
  /// ⚠️ `type` 认不出 ⇒ **兜底 [AccountType.other]，但整行保留**（#42 裁定 §三）：
  /// 账户与它的**余额**必须看得见 —— 少报钱比多报钱糟得多。
  factory Account.fromRow(
    Map<String, Object?> row, {
    ReadFailureLog? failures,
  }) {
    final String rawType = row.requiredString('type');
    final AccountType? type = AccountType.fromWireOrNull(rawType);
    if (type == null) {
      failures?.record(
        table: Schema.accounts,
        column: 'type',
        reason: '认不出的账户类型',
        value: rawType,
      );
    }
    return Account(
      id: row.requiredString('id'),
      name: row.requiredString('name'),
      type: type ?? AccountType.other,
      initialBalance: row.requiredInt('initial_balance'),
      isActive: row.requiredBool('is_active'),
      createdAt: row.requiredInt('created_at'),
      updatedAt: row.requiredInt('updated_at'),
      syncVersion: row.requiredInt('sync_version'),
    );
  }

  static const String table = Schema.accounts;

  @override
  final String id;
  final String name;
  final AccountType type;

  /// 期初余额（分）。
  /// ⚠️ 修改它会**重算全部历史余额**（见 `docs/data_model.md` §2.3），UI 必须提示。
  final int initialBalance;
  final bool isActive;
  final int createdAt;
  final int updatedAt;

  @override
  final int syncVersion;

  @override
  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'name': name,
    'type': type.wire,
    'initial_balance': initialBalance,
    'is_active': boolToInt(isActive),
    'created_at': createdAt,
    'updated_at': updatedAt,
    'sync_version': syncVersion,
  };

  @override
  Account withSyncVersion(int version) => Account(
    id: id,
    name: name,
    type: type,
    initialBalance: initialBalance,
    isActive: isActive,
    createdAt: createdAt,
    updatedAt: updatedAt,
    syncVersion: version,
  );
}
