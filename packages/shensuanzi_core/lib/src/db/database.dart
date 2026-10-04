import 'dart:io';

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
  ///
  /// ## 迁移失败时**不会**自动回滚（2026-10-03 裁定 · §BE）
  ///
  /// 两条事实**别搞混**：
  ///
  /// 1. **库停在「最后一版已提交的版本」** —— 迁移链**每版一个事务**
  ///    （见 [_migrate]），所以「v1→v2 成功、v2→v3 失败」时库**停在 v2**；
  ///    下次打开会**从断点继续**（只跑 v2→v3）。**不是**回到 v1。
  /// 2. **`<db>.before-v{N}` 是「人工退路」，不是自动回滚点** —— 它是
  ///    迁移前那份文件的拷贝，**由人**在需要时使用（恢复流程见用户手册
  ///    「备份与恢复」一章）。软件**不会**在失败时拿它覆盖回去。
  ///
  /// **为什么不留自动回滚**：回滚到 v1 会让下一轮**从头重跑**并**重蹈同一失败**；
  /// 「停在断点、修好再继续」既保住已完成的工作，也让失败点更可诊断。
  ///
  /// ⚠️ **曾经这里写着「迁移失败 → 从迁移前备份恢复」，还配了一个 `_restoreFrom`** ——
  /// 但那条路径**根本走不到**（`backupPath` 在抛异常时不会被赋值），
  /// 属「**文档描述了不存在的功能**」。已按**纪律 17** 删掉。
  static Db open(String path, {bool foreignKeys = true}) {
    final Database db = sqlite3.open(path);
    try {
      // WAL 必须在事务外设置；它提升并发读性能，且是断电安全性的基础。
      db.execute('PRAGMA journal_mode = WAL');
      _configure(db, foreignKeys: foreignKeys);
      _migrate(db, path);
      return Db._(db, foreignKeys: foreignKeys);
    } catch (_) {
      // 先关连接：Windows 上文件被占用就写不回去（也决定临时目录删不删得掉）
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
      _migrate(db, null);
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

  /// 迁移。**逐版本、每版一个事务**（`Agents.md` 纪律 14）。
  ///
  /// [path] 为 `null` = 内存库（测试）—— 没有文件可备份，其余逻辑一致。
  ///
  /// **不返回任何东西**：备份路径由 [_backupBeforeMigration] 自己写到盘上，
  /// 没有人在此处消费它（曾经返回 `String?` 给「失败后恢复」用 ——
  /// 那条路径走不到，已删；见 [open] 的说明）。
  static void _migrate(Database db, String? path) {
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

    // ---- 存量库：**先备份，再迁移**。
    //
    // 备份是**迁移的第一道防线，比回滚更重要** —— 回滚只能保证「结构没有
    // 半成品」，回不到「升级前的样子」；而文件级备份与崩溃时机无关
    // （reply.md Schema 篇 §3.2 / §七）。
    //
    // ⚠️ 备份**只写盘**，程序**不消费**它：它不是自动回滚点，而是**人工退路**
    //    （见 [open]）。**也不接返回值** —— 曾经接来喂 `_restoreFrom`，而那条
    //    路径走不到（纪律 17：不留「描述不存在功能」的代码）。
    if (path != null) _backupBeforeMigration(db, path, current);

    // **逐版本**跑迁移链，**每版一个事务** ——
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

  /// 迁移前把库拷一份：`<db>.before-v{N}`（`N` = **迁移前**的版本）。
  ///
  /// - **必须先 `wal_checkpoint(TRUNCATE)` 再拷**：WAL 模式下直接拷 `.db`
  ///   会丢掉未 checkpoint 的事务（与 `Agents.md` §四「备份模式」同一条纪律）
  /// - 放**数据目录内**（不是用户的备份目录）：它是迁移过程的产物，
  ///   成功了也**留一份** —— `before-v{N}` 是「升级完立刻后悔」的唯一退路
  /// - 不同版本各自留档（`before-v1` / `before-v2` …），互不覆盖
  /// - **备份失败就抛** ⇒ 上层的 `catch` 会让这次打开失败：
  ///   宁可先打不开，也不在**没有退路**的情况下改用户的数据
  ///
  /// **不返回任何东西**：这份文件是给**人**用的（见 [open]），程序不消费它。
  static void _backupBeforeMigration(
    Database db,
    String path,
    int fromVersion,
  ) {
    final String backupPath = '$path.before-v$fromVersion';
    try {
      db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      File(path).copySync(backupPath);
    } catch (error) {
      throw StateError(
        '升级前没能自动备份（$error）。'
        '请检查磁盘空间和文件夹权限，然后再打开一次。',
      );
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
