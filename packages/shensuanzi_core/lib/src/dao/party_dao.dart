import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/read_failures.dart';
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

  bool exists(String id) => _raw.select(
    'SELECT 1 FROM ${Schema.parties} WHERE id = ? LIMIT 1',
    <Object?>[id],
  ).isNotEmpty;

  /// [id] 查一条。
  ///
  /// ⚠️ **#42 甲 · L1**：坏行**跳过 + 计数**（原来抛穿 ⇒ 整页变灰）。
  /// ⇒ 返回值 `null` 现在有**两种**含义：「没有这一条」与「有但读不出来」；
  /// 后者会计入 `db.readFailures`（UI 的「有 N 条记录暂时显示不全」）。
  Party? findById(String id) {
    final List<Party> found = decodeRows(
      _raw.select('SELECT * FROM ${Schema.parties} WHERE id = ?', <Object?>[
        id,
      ]),
      (Map<String, Object?> row) =>
          Party.fromRow(row, failures: db.readFailures),
      table: Schema.parties,
      failures: db.readFailures,
    );
    return found.isEmpty ? null : found.first;
  }

  /// [role] 过滤在 Dart 侧做 —— `roles` 是 JSON 文本，SQL 里精确匹配会误伤
  /// （如 `"supplier"` 会命中 `"supplier_x"`）。
  List<Party> findAll({PartyRole? role, bool? active, int limit = 200}) =>
      _select(role: role, active: active, limit: limit);

  /// **真实总数**（与 [findAll] 同口径，但不受 `limit` 截断）。
  ///
  /// 为什么必须有它（2026-10-27，现实用户暴雷）：`findAll` 默认 `limit: 200`，
  /// 往来方页把 `visible.length` 当成「共 N 个」⇒ 过 200 个后**永远显示 200**。
  ///
  /// [role] 非空时只能取回再过滤 —— `roles` 是 JSON 文本，SQL 里精确匹配会误伤
  /// （`"supplier"` 命中 `"supplier_x"`）。往来方量级本来就小，这里不带 `limit`。
  int countAll({PartyRole? role, bool? active}) {
    if (role != null) {
      return _select(role: role, active: active, limit: null).length;
    }
    final ({String where, List<Object?> args}) filter = _where(active);
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT COUNT(*) AS c FROM ${Schema.parties}${filter.where}',
      filter.args,
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 过滤条件 + 参数的**唯一来源**（[findAll] 与 [countAll] 共用）。
  ({String where, List<Object?> args}) _where(bool? active) {
    final List<String> conditions = <String>[];
    final List<Object?> args = <Object?>[];
    if (active != null) {
      conditions.add('is_active = ?');
      args.add(active ? 1 : 0);
    }
    return (
      where: conditions.isEmpty ? '' : ' WHERE ${conditions.join(' AND ')}',
      args: args,
    );
  }

  /// **导出用**：不分页（§AF-5）。
  ///
  /// ⚠️ `active` 默认 `null` = **含停用** —— 一个**已停用但还欠着钱**的客户
  /// 必须在导出里（否则会计对不上这笔应收）。同 AF-12 的道理。
  List<Party> findAllForExport({PartyRole? role, bool? active}) =>
      _select(role: role, active: active, limit: null);

  List<Party> _select({PartyRole? role, bool? active, required int? limit}) {
    final ({String where, List<Object?> args}) filter = _where(active);
    final String where = filter.where;
    final List<Object?> args = filter.args;
    final String tail = limit == null ? '' : ' LIMIT ?';
    if (limit != null) args.add(limit);
    // #42 甲 · L1：逐行保护 —— **一条坏行不再让整张往来方页打不开**
    Iterable<Party> parties = decodeRows(
      _raw.select(
        'SELECT * FROM ${Schema.parties}$where ORDER BY name$tail',
        args,
      ),
      (Map<String, Object?> row) =>
          Party.fromRow(row, failures: db.readFailures),
      table: Schema.parties,
      failures: db.readFailures,
    );
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
