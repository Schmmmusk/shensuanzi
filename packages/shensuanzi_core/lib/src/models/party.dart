import '../db/schema.dart';
import 'base.dart';

/// 往来方角色。存为 JSON 数组文本，见 `docs/data_model.md` §2.2。
enum PartyRole {
  supplier('supplier'),
  customer('customer'),
  carrier('carrier');

  const PartyRole(this.wire);

  /// 落库用的值
  final String wire;

  static PartyRole fromWire(String value) => PartyRole.values.firstWhere(
    (PartyRole role) => role.wire == value,
    orElse: () => throw ArgumentError('未知往来方角色：$value'),
  );
}

/// 往来方（客户 / 供应商 / 司机统一存这张表）
class Party extends MutableEntity {
  const Party({
    required this.id,
    required this.name,
    this.phone,
    this.address,
    this.roles = const <PartyRole>[],
    this.creditLimit = 0,
    this.isActive = true,
    this.remark,
    required this.createdAt,
    required this.updatedAt,
    this.syncVersion = 0,
  });

  factory Party.fromRow(Map<String, Object?> row) => Party(
    id: row.requiredString('id'),
    name: row.requiredString('name'),
    phone: row.optionalString('phone'),
    address: row.optionalString('address'),
    roles: decodeRoles(row.requiredString('roles')),
    creditLimit: row.requiredInt('credit_limit'),
    isActive: row.requiredBool('is_active'),
    remark: row.optionalString('remark'),
    createdAt: row.requiredInt('created_at'),
    updatedAt: row.requiredInt('updated_at'),
    syncVersion: row.requiredInt('sync_version'),
  );

  /// `roles` 以 JSON 数组文本入库，如 `["supplier","customer"]`
  static String encodeRoles(List<PartyRole> roles) =>
      '[${roles.map((PartyRole r) => '"${r.wire}"').join(',')}]';

  static List<PartyRole> decodeRoles(String json) {
    if (json.isEmpty || json == '[]') return const <PartyRole>[];
    final String trimmed = json.trim();
    if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) {
      throw ArgumentError('roles 不是 JSON 数组：$json');
    }
    final String body = trimmed.substring(1, trimmed.length - 1).trim();
    if (body.isEmpty) return const <PartyRole>[];
    return body
        .split(',')
        .map((String s) => s.trim().replaceAll('"', ''))
        .where((String s) => s.isNotEmpty)
        .map(PartyRole.fromWire)
        .toList(growable: false);
  }

  static const String table = Schema.parties;

  @override
  final String id;
  final String name;
  final String? phone;
  final String? address;
  final List<PartyRole> roles;

  /// 赊账额度（分）
  final int creditLimit;
  final bool isActive;
  final String? remark;
  final int createdAt;
  final int updatedAt;

  @override
  final int syncVersion;

  @override
  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'name': name,
    'phone': phone,
    'address': address,
    'roles': encodeRoles(roles),
    'credit_limit': creditLimit,
    'is_active': boolToInt(isActive),
    'remark': remark,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'sync_version': syncVersion,
  };

  @override
  Party withSyncVersion(int version) => Party(
    id: id,
    name: name,
    phone: phone,
    address: address,
    roles: roles,
    creditLimit: creditLimit,
    isActive: isActive,
    remark: remark,
    createdAt: createdAt,
    updatedAt: updatedAt,
    syncVersion: version,
  );
}
