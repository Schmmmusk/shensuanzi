import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/read_failures.dart';
import '../db/schema.dart';
import '../models/account.dart';

/// 资金账户 DAO。**不开事务**（`Agents.md` 纪律 1）。
class AccountDao {
  AccountDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  bool insertIfAbsent(Account account) {
    if (exists(account.id)) return false;
    insert(account);
    return true;
  }

  void insert(Account account) {
    final Map<String, Object?> row = account.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.accounts} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
  }

  bool exists(String id) => _raw.select(
    'SELECT 1 FROM ${Schema.accounts} WHERE id = ? LIMIT 1',
    <Object?>[id],
  ).isNotEmpty;

  /// ⚠️ **#42 甲 · L1**：坏行跳过 + 计数（见 `party_dao.findById` 的同款说明）。
  Account? findById(String id) {
    final List<Account> found = decodeRows(
      _raw.select('SELECT * FROM ${Schema.accounts} WHERE id = ?', <Object?>[
        id,
      ]),
      (Map<String, Object?> row) =>
          Account.fromRow(row, failures: db.readFailures),
      table: Schema.accounts,
      failures: db.readFailures,
    );
    return found.isEmpty ? null : found.first;
  }

  List<Account> findAll({bool? active, int limit = 200}) =>
      _select(active: active, limit: limit);

  /// **导出 / 显示用**：不分页（与 `PartyDao.findAllForExport` 同口径）。
  ///
  /// ⚠️ 显示口径不能用 `findAll`（默认 200 条）—— 一个**停用但还有钱**的账户
  /// 被条数上限挤掉，用户会以为钱丢了（同 OBS-05 的「幽灵账」）。
  List<Account> findAllForExport({bool? active}) =>
      _select(active: active, limit: null);

  List<Account> _select({bool? active, required int? limit}) {
    final String where = active == null
        ? ''
        : ' WHERE is_active = ${active ? 1 : 0}';
    final String tail = limit == null ? '' : ' LIMIT ?';
    return decodeRows(
      _raw.select(
        'SELECT * FROM ${Schema.accounts}$where ORDER BY name$tail',
        <Object?>[?limit],
      ),
      (Map<String, Object?> row) =>
          Account.fromRow(row, failures: db.readFailures),
      table: Schema.accounts,
      failures: db.readFailures,
    );
  }

  /// **真实总数**（与 [findAll] 同口径，但不受 `limit` 截断）。
  ///
  /// 为什么必须有它（2026-10-27，现实用户暴雷）：`findAll` 默认 `limit: 200`，
  /// 账户页把 `visible.length` 当成「共 N 个」⇒ 过 200 个后**永远显示 200**。
  int countAll({bool? active}) {
    final String where = active == null
        ? ''
        : ' WHERE is_active = ${active ? 1 : 0}';
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT COUNT(*) AS c FROM ${Schema.accounts}$where',
      const <Object?>[],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  void update(Account account) {
    _raw.execute(
      '''
      UPDATE ${Schema.accounts} SET
        name = ?, type = ?, initial_balance = ?, is_active = ?,
        updated_at = ?, sync_version = ?
      WHERE id = ?
      ''',
      <Object?>[
        account.name,
        account.type.wire,
        account.initialBalance,
        account.isActive ? 1 : 0,
        account.updatedAt,
        account.syncVersion,
        account.id,
      ],
    );
  }

  void softDelete(String id, {required int updatedAt}) {
    _raw.execute(
      'UPDATE ${Schema.accounts} SET is_active = 0, sync_version = sync_version + 1, '
      'updated_at = ? WHERE id = ?',
      <Object?>[updatedAt, id],
    );
  }

  /// 账户余额 = `initial_balance + SUM(money_ledger.amount)`
  /// （`docs/data_model.md` §五 不变量 2）
  int balanceOf(String accountId, {int sinceSeqNo = 1 << 62}) {
    final Row row = _raw
        .select(
          '''
          SELECT COALESCE(a.initial_balance, 0) + COALESCE((
            SELECT SUM(amount) FROM ${Schema.moneyLedger}
            WHERE account_id = a.id AND seq_no < ?
          ), 0) AS balance
          FROM ${Schema.accounts} a WHERE a.id = ?
          ''',
          <Object?>[sinceSeqNo, accountId],
        )
        .first;
    return row['balance']! as int;
  }
}
