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

  static AccountType fromWire(String value) => AccountType.values.firstWhere(
    (AccountType type) => type.wire == value,
    orElse: () => throw ArgumentError('未知账户类型：$value'),
  );
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

  factory Account.fromRow(Map<String, Object?> row) => Account(
    id: row.requiredString('id'),
    name: row.requiredString('name'),
    type: AccountType.fromWire(row.requiredString('type')),
    initialBalance: row.requiredInt('initial_balance'),
    isActive: row.requiredBool('is_active'),
    createdAt: row.requiredInt('created_at'),
    updatedAt: row.requiredInt('updated_at'),
    syncVersion: row.requiredInt('sync_version'),
  );

  static const String table = Schema.accounts;

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
