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
  ///
  /// ⚠️ **失败路径必须 `dispose` 连接**：迁移抛错（SQL 失败 / 缺迁移 /
  /// 版本高于程序）时若直接向上抛，`sqlite3.open` 建立的连接不会关闭 ——
  /// Windows 上 `.db` 文件句柄被持有（临时目录删不掉），长期反复尝试还会累积。
  static Db open(String path, {bool foreignKeys = true}) {
    final Database db = sqlite3.open(path);
    try {
      // WAL 必须在事务外设置；它提升并发读性能，且是断电安全性的基础。
      db.execute('PRAGMA journal_mode = WAL');
      _configure(db, foreignKeys: foreignKeys);
      _migrate(db);
      return Db._(db, foreignKeys: foreignKeys);
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  /// 内存数据库 —— 测试默认使用它。
  ///
  /// 内存库不支持 WAL（`journal_mode` 会保持 `memory`），故不设置。
  /// 失败路径同样 `dispose`（与 [open] 对称：内存库虽无文件句柄，
  /// 但泄漏的连接会在长测试进程里累积）。
  static Db openInMemory({bool foreignKeys = true}) {
    final Database db = sqlite3.openInMemory();
    try {
      _configure(db, foreignKeys: foreignKeys);
      _migrate(db);
      return Db._(db, foreignKeys: foreignKeys);
    } catch (_) {
      db.dispose();
      rethrow;
    }
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

    // 旧代码打开新库 → **拒绝**（`SchemaTooNewException`）。
    // 拒绝比崩溃好：拒绝能告诉用户「升级软件或从备份恢复」，崩溃只会让
    // 用户以为软件坏了（reply.md §3.5）。
    if (current > Schema.version) {
      throw SchemaTooNewException(
        dbVersion: current,
        appVersion: Schema.version,
      );
    }

    // v0（空库）= 「从无到有」，直接建全量表 —— 这不是迁移，没有旧数据可保。
    if (current == 0) {
      db.execute('BEGIN');
      try {
        for (final String sql in Schema.createStatements) {
          db.execute(sql);
        }
        db.execute('PRAGMA user_version = ${Schema.version}');
        db.execute('COMMIT');
      } catch (_) {
        _rollbackQuietly(db);
        rethrow;
      }
      return;
    }

    // 存量库：**逐版本**跑迁移链，**每版一个事务** ——
    // v1 → v3 中途失败时 v1 → v2 的部分保留，重试只跑 v2 → v3（粒度更细）。
    // `migrationStep` 在 BEGIN **之前**取：缺迁移时没有事务要回滚，
    // 也不该留下半个结构（`MissingMigrationException` 在启动即拦）。
    for (int v = current + 1; v <= Schema.version; v++) {
      final List<String> steps = Schema.migrationStep(v - 1);
      db.execute('BEGIN');
      try {
        for (final String sql in steps) {
          db.execute(sql);
        }
        db.execute('PRAGMA user_version = $v');
        db.execute('COMMIT');
      } catch (_) {
        _rollbackQuietly(db);
        rethrow;
      }
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
