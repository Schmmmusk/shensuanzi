import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/schema.dart';
import '../models/party.dart';

/// 往来方 DAO。**不开事务**（`Agents.md` 纪律 1）。
class PartyDao {
  PartyDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  bool insertIfAbsent(Party party) {
    if (exists(party.id)) return false;
    insert(party);
    return true;
  }

  void insert(Party party) {
    final Map<String, Object?> row = party.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.parties} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
  }

  bool exists(String id) => _raw
      .select('SELECT 1 FROM ${Schema.parties} WHERE id = ? LIMIT 1', <Object?>[id])
      .isNotEmpty;

  Party? findById(String id) {
    final ResultSet rows = _raw.select(
      'SELECT * FROM ${Schema.parties} WHERE id = ?',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return Party.fromRow(rows.first);
  }

  /// [role] 过滤在 Dart 侧做 —— `roles` 是 JSON 文本，SQL 里精确匹配会误伤
  /// （如 `"supplier"` 会命中 `"supplier_x"`）。
  List<Party> findAll({PartyRole? role, bool? active, int limit = 200}) =>
      _select(role: role, active: active, limit: limit);

  /// **导出用**：不分页（§AF-5）。
  ///
  /// ⚠️ `active` 默认 `null` = **含停用** —— 一个**已停用但还欠着钱**的客户
  /// 必须在导出里（否则会计对不上这笔应收）。同 AF-12 的道理。
  List<Party> findAllForExport({PartyRole? role, bool? active}) =>
      _select(role: role, active: active, limit: null);

  List<Party> _select({PartyRole? role, bool? active, required int? limit}) {
    final List<String> conditions = <String>[];
    final List<Object?> args = <Object?>[];
    if (active != null) {
      conditions.add('is_active = ?');
      args.add(active ? 1 : 0);
    }
    final String where = conditions.isEmpty
        ? ''
        : ' WHERE ${conditions.join(' AND ')}';
    final String tail = limit == null ? '' : ' LIMIT ?';
    if (limit != null) args.add(limit);
    Iterable<Party> parties = _raw
        .select(
          'SELECT * FROM ${Schema.parties}$where ORDER BY name$tail',
          args,
        )
        .map(Party.fromRow);
    if (role != null) {
      parties = parties.where((Party p) => p.roles.contains(role));
    }
    return parties.toList(growable: false);
  }

  void update(Party party) {
    _raw.execute(
      '''
      UPDATE ${Schema.parties} SET
        name = ?, phone = ?, address = ?, roles = ?,
        credit_limit = ?, is_active = ?, remark = ?,
        updated_at = ?, sync_version = ?
      WHERE id = ?
      ''',
      <Object?>[
        party.name,
        party.phone,
        party.address,
        Party.encodeRoles(party.roles),
        party.creditLimit,
        party.isActive ? 1 : 0,
        party.remark,
        party.updatedAt,
        party.syncVersion,
        party.id,
      ],
    );
  }

  void softDelete(String id, {required int updatedAt}) {
    _raw.execute(
      'UPDATE ${Schema.parties} SET is_active = 0, sync_version = sync_version + 1, '
      'updated_at = ? WHERE id = ?',
      <Object?>[updatedAt, id],
    );
  }
}
