import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'read_failures.dart';
import 'schema.dart';
import 'snapshot.dart';

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
  Db._(this.raw, {required bool foreignKeys, this.path})
    : _foreignKeys = foreignKeys;

  /// 底层连接。仅 DAO 与自检脚本使用。
  final Database raw;

  /// 库文件路径（内存库为 `null`）。
  ///
  /// 2026-11-09：**导出要把它交给 isolate** —— 连接不能跨 isolate，
  /// 但「同一个文件在那边再开一条」可以。没有这个字段，页面拿不到路径，
  /// 大表导出就只能留在主线程上冻界面。
  final String? path;

  final bool _foreignKeys;

  /// **读路径的坏数据计数**（#42 甲 · L4 的计数通道，2026-10-14 裁定）。
  ///
  /// 挂在 `Db` 上而不是每个 DAO 上：DAO 已经持有 `db` ⇒ **DAO 构造签名零改动**
  /// （裁定 §二·接线 1 选 A）。**累计**语义、由 UI 在「知道了」时
  /// [ReadFailureLog.clear] —— 详见 `read_failures.dart` 的「生命周期」一节。
  final ReadFailureLog readFailures = ReadFailureLog();

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
  /// 能不能打开这个位置的库并**真读一下文件**（**永不抛**）。
  ///
  /// 用途：启动解析时探测「配置里的位置现在还能用吗」（§审查 BUG-03）——
  /// 目录在、标记在，但库文件可能**坏了 / 被锁 / 是更高 schema**。
  /// 只做 `SELECT count(*) FROM sqlite_master`（真的读文件头，`SELECT 1` 不读）。
  ///
  /// ⚠️ 刻意**不走 [open]**：那会跑迁移链 —— 探测不该有副作用。
  /// 探测「这个路径能不能开成库」——**绝不在 `path` 上留下文件**
  /// （3c-22，2026-10-24）。
  ///
  /// 从前是 `sqlite3.open(path)`：文件不存在时**建出一个空库**，一次判定就把
  /// 用户的空账建出来了（`bootstrap.missingConfigured` 靠注释规避）。
  ///
  /// 现在的两条语义：
  /// - **文件在** ⇒ 只读打开并读一次 `sqlite_master`（库损坏 / 不是库 ⇒ false）；
  /// - **文件不在** ⇒ 探测**父目录可写**（临时文件写完即删）——
  ///   仍然回答「这里能不能开库」，但不创建 `path` 本身。
  static bool probe(String path) {
    final File file = File(path);
    if (!file.existsSync()) {
      final Directory dir = file.parent;
      if (!dir.existsSync()) return false;
      final File tmp = File(
        '${dir.path}${Platform.pathSeparator}.probe-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        tmp.writeAsStringSync('x');
        return true;
      } catch (_) {
        return false;
      } finally {
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {
          // 删不掉不影响结论（下次探测用新名字）
        }
      }
    }
    try {
      final Database db = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        db.select('SELECT count(*) AS c FROM sqlite_master');
        return true;
      } finally {
        db.dispose();
      }
    } catch (_) {
      return false;
    }
  }

  /// ## [onPhase]：开库四步分时（2026-11-10，第四次真机 P2）
  ///
  /// 真机上「冷启动开库」实测 **10–13 秒**（重启后、498 MB 库、NVMe），
  /// 而这里只做四件事。不拆开就分不清到底是
  /// **杀软首次扫描文件**（`sqlite_open` 慢）/ **WAL 恢复**（`wal` 慢）/
  /// **pragma** / **迁移**（不该慢，v8 会早退）。
  ///
  /// 回调给的是**累计毫秒**（与 `StartupTrace` 的语义一致），
  /// 默认 `null` ⇒ 零开销、行为完全不变。
  static Db open(
    String path, {
    bool foreignKeys = true,
    void Function(String phase, int ms)? onPhase,
  }) {
    final Stopwatch clock = Stopwatch()..start();
    final Database db = sqlite3.open(path);
    onPhase?.call('sqlite_open', clock.elapsedMilliseconds);
    try {
      // WAL 必须在事务外设置；它提升并发读性能，且是断电安全性的基础。
      // ⚠️ 库上次**非正常退出**时，这一步会重放 `-wal` —— 大 WAL 就是秒级。
      db.execute('PRAGMA journal_mode = WAL');
      onPhase?.call('wal', clock.elapsedMilliseconds);
      _configure(db, foreignKeys: foreignKeys);
      onPhase?.call('configure', clock.elapsedMilliseconds);
      _migrate(db, path, foreignKeys: foreignKeys);
      onPhase?.call('migrate', clock.elapsedMilliseconds);
      return Db._(db, foreignKeys: foreignKeys, path: path);
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
    // 3b-4（2026-10-24，业务审查 §3.5-4）：**等锁而不是立刻失败**。
    // 从前只设了 `synchronous` / `foreign_keys`，一旦出现第二个写者
    // （备份进程 / 另一个实例 / 杀毒软件扫描）SQLite 立刻 `SQLITE_BUSY`。
    // 3 秒足够任何一次本地写事务收尾。
    db.execute('PRAGMA busy_timeout = 3000');
  }

  /// 迁移。**逐版本、每版一个事务**（`Agents.md` 纪律 14）。
  ///
  /// [path] 为 `null` = 内存库（测试）—— 没有文件可备份，其余逻辑一致。
  ///
  /// **不返回任何东西**：备份路径由 [_backupBeforeMigration] 自己写到盘上，
  /// 没有人在此处消费它（曾经返回 `String?` 给「失败后恢复」用 ——
  /// 那条路径走不到，已删；见 [open] 的说明）。
  static void _migrate(Database db, String? path, {bool foreignKeys = true}) {
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
    // ⚠️ **重建父表必须先关外键**（SQLite 官方「12 步重建」的第 1 步）：
    // v6 要重建 `documents`，而 `document_lines` / `stock_ledger` / `money_ledger` /
    // `party_ledger` / `settlements` 都有行指向它 —— 外键开着时 `DROP TABLE` 直接报错。
    //
    // ⚠️ `PRAGMA foreign_keys` **在事务内是空操作**，所以必须在 `BEGIN` **之前**执行，
    // 且整条迁移链跑完再恢复（不是每版恢复一次）。
    db.execute('PRAGMA foreign_keys = OFF');
    try {
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
    } finally {
      db.execute('PRAGMA foreign_keys = ${foreignKeys ? 'ON' : 'OFF'}');
    }

    // 关过外键就要**复核一遍**：重建表最怕「搬完发现子表指向了不存在的行」，
    // 而那种损坏在后续读写里表现为「查不到」而不是「报错」，极难定位。
    final List<Map<String, Object?>> violations = db.select(
      'PRAGMA foreign_key_check',
    );
    if (violations.isNotEmpty) {
      throw StateError(
        '迁移后外键校验失败：${violations.length} 处引用不存在的行'
        '（第一处：${violations.first}）。请从 .before-v$current 恢复并反馈。',
      );
    }
  }

  /// 迁移前把库拷一份：`<db>.before-v{N}`（`N` = **迁移前**的版本）。
  ///
  /// - **字节拷贝**（不是 `VACUUM INTO`）：这一份的用途是「迁移前的**原样**」，
  ///   而且源库**可能已经损坏** —— `VACUUM` 要求库读得出来，用它等于把安全网
  ///   绑在它要保护的对象上（2026-11-12 用户裁定，见 `proposals/63`）
  /// - 三件加固都在 [copyDatabaseAsIs] 里：**checkpoint 三列一起看** / 先写 `.tmp`
  ///   再原子改名 / 拷完比字节数。从前只 `execute('PRAGMA wal_checkpoint(TRUNCATE)')`
  ///   然后直接 `copySync` —— 那个 checkpoint 的返回值没人看，忙时只归并一半就照拷
  /// - 放**数据目录内**（不是用户的备份目录）：它是迁移过程的产物，
  ///   成功了也**留一份** —— `before-v{N}` 是「升级完立刻后悔」的唯一退路
  /// - 不同版本各自留档（`before-v1` / `before-v2` …），互不覆盖；**同名已存在就跳过**
  ///   （最早那份最接近「迁移前」，比再抓一次更可靠）
  /// - **备份失败就抛** ⇒ 上层的 `catch` 会让这次打开失败：
  ///   宁可先打不开，也不在**没有退路**的情况下改用户的数据
  ///
  /// ⚠️ **前提：此刻没有第二个写者。** 这个前提由**调用顺序**保证 ——
  /// `Db.open` 里先 `sqlite3.open`、再配置、最后才迁移；此时宿主服务未启动、
  /// 界面未建（换数据目录那条路径更严格：`host.stop()` → 关库 → 搬迁）。
  /// `core` 的 `copy_as_is_test.dart` 用「另开一条连接做写事务」来**钉住**这条前提，
  /// 而不是只写在注释里。
  ///
  /// **不返回任何东西**：这份文件是给**人**用的（见 [open]），程序不消费它。
  static void _backupBeforeMigration(
    Database db,
    String path,
    int fromVersion,
  ) {
    final String backupPath = '$path.before-v$fromVersion';
    final CopyProblem? problem = copyDatabaseAsIs(
      db: db,
      source: path,
      target: backupPath,
    );
    if (problem == null) return;
    throw StateError(
      '升级前没能自动备份（${_copyProblemText(problem)}）。'
      '请检查磁盘空间和文件夹权限，然后再打开一次。',
    );
  }

  /// 把 [CopyProblem] 翻成**用户能据此行动**的一句话。
  static String _copyProblemText(CopyProblem problem) => switch (problem) {
    // WAL 没归并完 ⇒ 拷出来可能缺最新事务。磁盘不一定是问题，也可能是
    // 另一个进程/连接正在用这个库。
    CopyProblem.checkpointIncomplete => '数据库还有没写完的内容（可能正被另一个程序打开）',
    CopyProblem.copyFailed => '写不进备份文件',
    CopyProblem.sizeMismatch => '备份文件和原文件大小不一致',
  };

  /// **只读事务**：多次 SELECT 看到**同一个快照**，且**不阻塞任何写者**。
  ///
  /// ## 为什么必须与 [transaction] 分开（2026-11-11，用户审查 P2）
  ///
  /// [transaction] 用的是 `BEGIN IMMEDIATE` —— **拿写锁**，期间别的连接写不进来。
  /// 那是「我要落库」的正确选择，但对「只读但要一致」的场景是灾难：
  /// 导出 26 万单要十几秒，用它就等于让用户十几秒开不了单。
  ///
  /// 这里用 `BEGIN`（deferred）：第一次读时才取得读快照，WAL 模式下**写者照常提交**，
  /// 而我们全程看到的是同一个 read-mark。
  ///
  /// ## 它解决的具体问题
  ///
  /// 26 万单导出搬进 isolate 之后，主 isolate 可以同时处理用户操作。
  /// 而 `DocumentExportJob.load()` 内部是**多段查询**（先取单据，再取核销笔数）——
  /// 两段各是一个独立的读事务，中间主库可以提交新数据，于是可能导出
  /// 「金额按旧状态、核销笔数按新状态」的行。包一层这个事务即可消除。
  ///
  /// ## 与 [transaction] 的关系
  ///
  /// 共用同一个 `_depth`：在外层写事务里调用它不会产生嵌套 `BEGIN`
  /// （复用外层事务的快照）。⚠️ 反过来说，**在它里面调 [transaction] 也不会
  /// 升级成写事务** —— 只读场景不要往里写。
  T readTransaction<T>(T Function() body) {
    if (_depth > 0) {
      _depth++;
      try {
        return body();
      } finally {
        _depth--;
      }
    }

    raw.execute('BEGIN');
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
