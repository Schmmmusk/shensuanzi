import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

/// SQLite 连接的薄封装：打开、迁移、**可重入事务**。
///
/// ## 事务边界（`Agents.md` 纪律 1）
///
/// **DAO 不开事务，事务由 RuleEngine / SyncServer 统一开。**
/// [transaction] 因此**必须可重入** —— `RuleEngine.purchaseInbound` 会调用
/// `DocumentDao.insertIfAbsent`，若两者各开一次事务，SQLite 会抛
/// `cannot start a transaction within a transaction`。
///
/// 可重入语义：只有**最外层**真正 `BEGIN` / `COMMIT`；内层复用外层事务。
/// 因此**内层"成功"并不代表数据已落盘**，只有最外层 `COMMIT` 才算数 ——
/// 这也正是"任一失败整单回滚"（`docs/rules.md`）所需要的语义。
class Db {
  Db._(this.raw, {required bool foreignKeys}) : _foreignKeys = foreignKeys;

  /// 底层连接。仅 DAO 与自检脚本使用。
  final Database raw;

  final bool _foreignKeys;

  /// 事务嵌套深度。`0` = 不在事务中。
  int _depth = 0;

  /// 打开（或创建）文件数据库，必要时自动迁移 schema。
  static Db open(String path, {bool foreignKeys = true}) {
    final Database db = sqlite3.open(path);
    // WAL 必须在事务外设置；它提升并发读性能，且是断电安全性的基础。
    db.execute('PRAGMA journal_mode = WAL');
    _configure(db, foreignKeys: foreignKeys);
    _migrate(db);
    return Db._(db, foreignKeys: foreignKeys);
  }

  /// 内存数据库 —— 测试默认使用它。
  ///
  /// 内存库不支持 WAL（`journal_mode` 会保持 `memory`），故不设置。
  static Db openInMemory({bool foreignKeys = true}) {
    final Database db = sqlite3.openInMemory();
    _configure(db, foreignKeys: foreignKeys);
    _migrate(db);
    return Db._(db, foreignKeys: foreignKeys);
  }

  /// 当前是否处于事务中
  bool get inTransaction => _depth > 0;

  /// 是否启用了外键约束
  bool get foreignKeysEnabled => _foreignKeys;

  /// 数据库 schema 版本（`PRAGMA user_version`）
  int get schemaVersion =>
      raw.select('PRAGMA user_version').first['user_version']! as int;

  static void _configure(Database db, {required bool foreignKeys}) {
    db.execute('PRAGMA foreign_keys = ${foreignKeys ? 'ON' : 'OFF'}');
    db.execute('PRAGMA synchronous = NORMAL');
  }

  static void _migrate(Database db) {
    final int current =
        db.select('PRAGMA user_version').first['user_version']! as int;
    if (current == Schema.version) return;

    if (current > Schema.version) {
      throw StateError(
        '数据库 schema 版本 $current 高于本程序支持的 ${Schema.version}，请升级程序后再打开',
      );
    }

    // v0（空库）直接建全量表；v1 起的存量库走 migrationStatements 逐版升级
    // （v1 → v2：products 加 package_note，见 Schema.migrationStatements）。
    final List<String> statements = current == 0
        ? Schema.createStatements
        : Schema.migrationStatements(current);

    db.execute('BEGIN');
    try {
      for (final String sql in statements) {
        db.execute(sql);
      }
      db.execute('PRAGMA user_version = ${Schema.version}');
      db.execute('COMMIT');
    } catch (_) {
      _rollbackQuietly(db);
      rethrow;
    }
  }

  /// **可重入**事务。
  ///
  /// 最外层 `BEGIN IMMEDIATE`（立即取写锁，避免升级锁失败）；
  /// 内层直接复用，不产生新的 `BEGIN`。
  /// 任一层的 body 抛出异常 → 整个事务回滚并原样向上抛出。
  T transaction<T>(T Function() body) {
    if (_depth > 0) {
      _depth++;
      try {
        return body();
      } finally {
        _depth--;
      }
    }

    raw.execute('BEGIN IMMEDIATE');
    _depth = 1;
    try {
      final T result = body();
      raw.execute('COMMIT');
      return result;
    } catch (_) {
      _rollbackQuietly(raw);
      rethrow;
    } finally {
      _depth = 0;
    }
  }

  /// 回滚失败时**不覆盖原始异常** —— 原始异常才是根因。
  static void _rollbackQuietly(Database db) {
    try {
      db.execute('ROLLBACK');
    } catch (_) {
      // 事务可能已因错误自动结束，忽略
    }
  }

  void close() => raw.dispose();
}
