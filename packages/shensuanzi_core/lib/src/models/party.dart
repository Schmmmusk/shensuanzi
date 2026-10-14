import '../db/read_failures.dart';
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

  /// 严格版：**不认识就抛**。用于 **wire 报文校验**（畸形请求要拒绝）。
  static PartyRole fromWire(String value) => PartyRole.values.firstWhere(
    (PartyRole role) => role.wire == value,
    orElse: () => throw ArgumentError('未知往来方角色：$value'),
  );

  /// **读库用**（#42 甲 · L2）：未知值 ⇒ `null`，**不抛**。
  /// 调用方（[Party.decodeRoles]）**丢弃该角色但保留整行** —— 少一个角色标签，
  /// 总好过整张往来方页打不开（欠款看不见才是真损失）。
  static PartyRole? fromWireOrNull(String value) {
    for (final PartyRole role in PartyRole.values) {
      if (role.wire == value) return role;
    }
    return null;
  }
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

  /// [failures] 记录「哪个角色被丢了 / roles 整列坏掉」（不传 = 只兜底不记录）。
  ///
  /// ⚠️ **`roles` 列是 #42 的原始触发点**（注入 `"  　\t  "` ⇒ 原来直接抛 ⇒
  /// 往来方页整页变灰）。现在的处置：**丢角色、保整行** —— 少一个标签不影响
  /// 这个人还在列表里、欠款还看得见（裁定 §三）。
  factory Party.fromRow(
    Map<String, Object?> row, {
    ReadFailureLog? failures,
  }) => Party(
    id: row.requiredString('id'),
    name: row.requiredString('name'),
    phone: row.optionalString('phone'),
    address: row.optionalString('address'),
    roles: decodeRoles(row.requiredString('roles'), failures: failures),
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

  /// 解码 `roles`。**任何坏值都不再抛**（#42 甲 · L2）—— 认不出的角色**丢弃**，
  /// 计入 [failures]；整列不是数组也**不抛**，返回空角色表（行仍然保留）。
  static List<PartyRole> decodeRoles(String json, {ReadFailureLog? failures}) {
    if (json.isEmpty || json == '[]') return const <PartyRole>[];
    final String trimmed = json.trim();
    if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) {
      // 整列坏 ⇒ 角色表留空，但**这一行照样能用**（原来这里抛 ⇒ 整页变灰）
      failures?.record(
        table: Schema.parties,
        column: 'roles',
        reason: 'roles 不是 JSON 数组',
      );
      return const <PartyRole>[];
    }
    final String body = trimmed.substring(1, trimmed.length - 1).trim();
    if (body.isEmpty) return const <PartyRole>[];
    final List<PartyRole> roles = <PartyRole>[];
    for (final String raw in body.split(',')) {
      final String value = raw.trim().replaceAll('"', '');
      if (value.isEmpty) continue;
      final PartyRole? role = PartyRole.fromWireOrNull(value);
      if (role == null) {
        // ⚠️ 记**原值**：枚举 wire 值是固定字母表，不是经营数据 ——
        // 记它才能区分「用户数据坏了」与「我们自己枚举拼错了」（裁定 §二·④）
        failures?.record(
          table: Schema.parties,
          column: 'roles',
          reason: '认不出的往来方角色',
          value: value,
        );
        continue;
      }
      roles.add(role);
    }
    return List<PartyRole>.unmodifiable(roles);
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
