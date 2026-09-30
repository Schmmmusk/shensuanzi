// 无需 Flutter 的自检入口：`dart run tool/selfcheck.dart`
//
// 为什么需要它：本机（Windows）纯 Dart 环境下 `dart test` 会因创建子进程失败而不可用
// （`ProcessException: 所有的管道范例都在使用中`）。本脚本用进程内的断言代替，
// 覆盖与 `test/` 相同的核心结论。**`test/` 才是正式测试，本脚本是烟雾自检。**
//
// 退出码：全部通过为 0，否则为 1。

import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:shensuanzi_core/sqlite_local.dart';

int _passed = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void section(String title) => stdout.writeln('\n[$title]');

// ---------------------------------------------------------------- 夹具

const String _p1 = 'p-00000000-0000-7000-8000-000000000001';
const String _d1 = 'd-00000000-0000-7000-8000-000000000001';
const String _a1 = 'a-00000000-0000-7000-8000-000000000001';

int _seq = 0;
int now() => 1700000000000 + (_seq++);

void insertProduct(Database db, String id, {String? code}) {
  final int t = now();
  db.execute(
    'INSERT INTO products (id, code, name, created_at, updated_at) VALUES (?,?,?,?,?)',
    <Object?>[id, code ?? id, '商品-$id', t, t],
  );
}

void insertAccount(Database db, String id) {
  final int t = now();
  db.execute(
    'INSERT INTO accounts (id, name, type, created_at, updated_at) VALUES (?,?,?,?,?)',
    <Object?>[id, '账户-$id', 'cash', t, t],
  );
}

void insertDocument(Database db, String id, {String docNo = 'X20260925-001'}) {
  final int t = now();
  db.execute(
    'INSERT INTO documents (id, doc_no, doc_type, status, occurred_at, created_at, updated_at) '
    'VALUES (?,?,?,?,?,?,?)',
    <Object?>[id, docNo, 'purchase', 'confirmed', t, t, t],
  );
}

void insertStock(Database db, String id, int seqNo) {
  final int t = now();
  db.execute(
    'INSERT INTO stock_ledger (id, product_id, document_id, quantity, unit_cost, total_cost, seq_no, occurred_at, created_at) '
    'VALUES (?,?,?,?,?,?,?,?,?)',
    <Object?>[id, _p1, _d1, 1, 100, 100, seqNo, t, t],
  );
}

void insertMoney(Database db, String id, int seqNo) {
  final int t = now();
  db.execute(
    'INSERT INTO money_ledger (id, account_id, document_id, amount, seq_no, occurred_at, created_at) '
    'VALUES (?,?,?,?,?,?,?)',
    <Object?>[id, _a1, _d1, 100, seqNo, t, t],
  );
}

bool throws(void Function() body) {
  try {
    body();
    return false;
  } catch (_) {
    return true;
  }
}

// ---------------------------------------------------------------- 主流程

void main() {
  useLocalSqlite();
  stdout.writeln('SQLite: ${sqlite3.version.libVersion}');

  final Db db = Db.openInMemory();
  final Database raw = db.raw;

  section('A. schema 建表');
  final Set<Object?> tables = raw
      .select("SELECT name FROM sqlite_master WHERE type = 'table'")
      .map((Row r) => r['name'])
      .toSet();
  for (final String table in Schema.allTables) {
    check('表 $table', tables.contains(table));
  }
  // 双向：也查「建出来的都在 allTables 里」——单向包含抓不到「加了表却忘了登记」
  check('没有多余的表（表集与 Schema.allTables 相等）',
      tables.difference(Schema.allTables.toSet()).isEmpty,
      '${tables.difference(Schema.allTables.toSet())}');
  check('schema 版本 = ${Schema.version}', db.schemaVersion == Schema.version,
      '实际 ${db.schemaVersion}');

  section('B. 索引');
  const List<String> expectedIndexes = <String>[
    'idx_products_barcode',
    'idx_products_updated',
    'idx_parties_phone',
    'idx_parties_updated',
    'idx_accounts_updated',
    'idx_documents_type_status',
    'idx_documents_party',
    'idx_documents_occurred',
    'idx_documents_ref',
    'idx_documents_created',
    'idx_lines_document',
    'idx_lines_product',
    'idx_stock_product_seq',
    'idx_stock_document',
    'idx_stock_seq',
    'idx_money_account_seq',
    'idx_money_document',
    'idx_money_seq',
    'idx_party_ledger_party_seq',
    'idx_party_ledger_document',
    'idx_party_ledger_seq',
    'idx_settle_receipt',
    'idx_settle_target',
    'idx_settle_seq',
    'idx_sync_status',
    'idx_sync_entity',
  ];
  final Set<Object?> indexes = raw
      .select("SELECT name FROM sqlite_master WHERE type = 'index'")
      .map((Row r) => r['name'])
      .toSet();
  for (final String index in expectedIndexes) {
    check('索引 $index', indexes.contains(index));
  }

  section('C. 外键约束');
  check('外键已开启', db.foreignKeysEnabled);
  insertProduct(raw, _p1);
  insertAccount(raw, _a1);
  insertDocument(raw, _d1);
  check(
    '拒绝引用不存在的单据',
    throws(() {
      raw.execute(
        'INSERT INTO document_lines (id, document_id, product_id, quantity, unit_price, amount) '
        "VALUES (?,?,?,?,?,?)",
        <Object?>['l-bad', 'no-such-doc', _p1, 1, 1, 1],
      );
      raw.execute('DELETE FROM document_lines WHERE id = ?', <Object?>['l-bad']);
    }),
  );

  section('D. 可重入事务（P0-1）');
  final int nested = db.transaction(() {
    insertProduct(raw, 'p-n1', code: 'p-n1');
    return db.transaction(() {
      insertProduct(raw, 'p-n2', code: 'p-n2');
      return db.transaction(() => 42);
    });
  });
  check('三层嵌套返回最内层结果', nested == 42, '实际 $nested');
  check('事务结束后 inTransaction == false', !db.inTransaction);
  final int inserted = raw
      .select("SELECT COUNT(*) AS c FROM products WHERE id IN ('p-n1','p-n2')")
      .first['c']! as int;
  check('嵌套事务内的写入已落盘', inserted == 2, '实际 $inserted');

  section('E. 失败回滚');
  check(
    '异常向上抛出',
    throws(() {
      db.transaction(() {
        insertProduct(raw, 'p-rollback', code: 'p-rollback');
        throw StateError('boom');
      });
    }),
  );
  final int rolledBack = raw
      .select("SELECT COUNT(*) AS c FROM products WHERE id = 'p-rollback'")
      .first['c']! as int;
  check('回滚后写入不可见', rolledBack == 0, '实际 $rolledBack');
  check('回滚后 inTransaction == false', !db.inTransaction);

  section('F. 嵌套失败 → 整单回滚');
  check(
    '内层抛异常传播到外层',
    throws(() {
      db.transaction(() {
        insertProduct(raw, 'p-outer', code: 'p-outer');
        db.transaction(() {
          insertProduct(raw, 'p-inner', code: 'p-inner');
          throw StateError('inner boom');
        });
      });
    }),
  );
  final int survivors = raw
      .select("SELECT COUNT(*) AS c FROM products WHERE id IN ('p-outer','p-inner')")
      .first['c']! as int;
  check('外层的写入一并回滚', survivors == 0, '实际 $survivors');

  section('G. seq_no 每表独立');
  insertStock(raw, 's-1', 1);
  check('另一张流水表可复用 seq_no = 1', !throws(() => insertMoney(raw, 'm-1', 1)));
  check('同一张表内 seq_no 唯一（UNIQUE 生效）',
      throws(() => insertStock(raw, 's-dup', 1)));

  section('H. 金额舍入（round-half-up）');
  check('302 / 3 = 101', Money.divideRoundHalfUp(302, 3) == 101,
      '实际 ${Money.divideRoundHalfUp(302, 3)}');
  check('300 / 3 = 100', Money.divideRoundHalfUp(300, 3) == 100);
  check('1 / 2 = 1（半数进位）', Money.divideRoundHalfUp(1, 2) == 1);
  check('-302 / 3 = -101（半数远离零）', Money.divideRoundHalfUp(-302, 3) == -101);
  check('-1 / 2 = -1', Money.divideRoundHalfUp(-1, 2) == -1);
  check('0 / 7 = 0', Money.divideRoundHalfUp(0, 7) == 0);
  check('除以 0 抛错', throws(() => Money.divideRoundHalfUp(1, 0)));
  check('Money.format(-1234) = -12.34', Money.format(-1234) == '-12.34',
      Money.format(-1234));

  section('I. UUIDv7');
  final List<String> ids = List<String>.generate(500, (_) => newId());
  check('500 个 id 互不相同', ids.toSet().length == 500);
  check('版本位为 7', ids.every((String id) => id[14] == '7'),
      ids.firstWhere((String id) => id[14] != '7', orElse: () => '<全部为 7>'));

  section('J. 列级断言');
  Set<Object?> columnsOf(String table) => raw
      .select('PRAGMA table_info($table)')
      .map((Row r) => r['name'])
      .toSet();
  check('documents 有 time_estimated（P1-9）',
      columnsOf(Schema.documents).contains('time_estimated'));
  for (final String table in Schema.businessTables) {
    final Set<Object?> cols = columnsOf(table);
    check('$table 无 is_active', !cols.contains('is_active'));
    check('$table 无 sync_version', !cols.contains('sync_version'));
  }
  check('documents 无 sync_version（P0-7）',
      !columnsOf(Schema.documents).contains('sync_version'));
  for (final String table in Schema.masterDataTables) {
    final Set<Object?> cols = columnsOf(table);
    check('$table 有 is_active + sync_version',
        cols.contains('is_active') && cols.contains('sync_version'));
  }

  section('K. 唯一约束');
  check('doc_no 唯一（先有 X20260925-001）',
      throws(() => insertDocument(raw, 'd-dup', docNo: 'X20260925-001')));
  insertProduct(raw, 'p-code-a', code: 'P001');
  check('products.code 唯一', throws(() => insertProduct(raw, 'p-dup', code: 'P001')));
  check('clock_offset 只允许 id = 1',
      throws(() {
        raw.execute(
          'INSERT INTO clock_offset (id, offset_ms, updated_at) VALUES (2, 0, ?)',
          <Object?>[now()],
        );
      }));

  section('L. 文件数据库启用 WAL');
  final Directory tmp = Directory.systemTemp.createTempSync('ssz_selfcheck');
  final String dbPath = '${tmp.path}${Platform.pathSeparator}sc.db';
  final Db fileDb = Db.open(dbPath);
  check('journal_mode = wal',
      fileDb.raw.select('PRAGMA journal_mode').first['journal_mode'] == 'wal',
      '${fileDb.raw.select('PRAGMA journal_mode').first['journal_mode']}');
  check('schema 版本已迁移', fileDb.schemaVersion == Schema.version);
  fileDb.close();
  final Db reopened = Db.open(dbPath);
  check('重复打开不重复迁移', reopened.schemaVersion == Schema.version);
  reopened.close();
  tmp.deleteSync(recursive: true);

  section('M. 迁移链（reply.md Schema 篇 / §AK·二）');

  final List<String> step1 = Schema.migrationStep(1);
  check(
      'migrationStep(1) 恰好一条 ALTER package_note',
      step1.length == 1 &&
          step1.single.contains('ALTER TABLE products ADD COLUMN package_note'),
      '${step1.length} 条');

  var missingThrown = false;
  try {
    Schema.migrationStep(Schema.version);
  } on MissingMigrationException {
    missingThrown = true;
  }
  check('migrationStep(当前版) → MissingMigrationException（漏写迁移启动即拦）',
      missingThrown);

  final Directory migTmp = Directory.systemTemp.createTempSync('ssz_migrate');
  String migPath(String name) => '${migTmp.path}${Platform.pathSeparator}$name';

  // 旧代码打开新库 → 拒绝（不是崩溃）
  var tooNewThrown = false;
  final Database tooNewRaw = sqlite3.open(migPath('toonew.db'));
  tooNewRaw.execute('PRAGMA user_version = ${Schema.version + 1}');
  tooNewRaw.dispose();
  try {
    Db.open(migPath('toonew.db'));
  } on SchemaTooNewException {
    tooNewThrown = true;
  }
  check('旧代码打开新库 → SchemaTooNewException（拒绝比崩溃好）', tooNewThrown);

  // 迁移失败后连接必须**已释放** —— 与上面同一场景的延伸：
  // Windows 上句柄没释放 ⇒ 目录删不掉（本仓真实出现过）
  final Directory leakTmp = Directory.systemTemp.createTempSync('ssz_leak');
  final String leakPath = '${leakTmp.path}${Platform.pathSeparator}new.db';
  final Database leakRaw = sqlite3.open(leakPath);
  leakRaw.execute('PRAGMA user_version = ${Schema.version + 1}');
  leakRaw.dispose();
  try {
    Db.open(leakPath);
  } on SchemaTooNewException {
    // 预期路径
  }
  var leakRemoved = true;
  try {
    leakTmp.deleteSync(recursive: true);
  } catch (_) {
    leakRemoved = false;
  }
  check('迁移失败后连接已关闭（目录可删 ⇒ 句柄已释放）', leakRemoved);

  // 化石库端到端 —— ⚠️ **先拷贝再打开**：Db.open 会就地迁移，直接打开会改坏化石
  final File fixture = File('test/fixtures/v1_empty.db');
  if (!fixture.existsSync()) {
    check('化石库 v1_empty.db 存在', false,
        '缺文件：先在 core 包跑 dart run tool/make_fixture.dart');
  } else {
    final String fxPath = migPath('v1.db');
    fixture.copySync(fxPath);
    final Database fxRaw = sqlite3.open(fxPath);
    final int fxVersion =
        fxRaw.select('PRAGMA user_version').first['user_version']! as int;
    final int fxNow = now();
    fxRaw.execute(
      'INSERT INTO products (id, code, name, unit, created_at, updated_at) '
      "VALUES ('p-v1', 'P0001', '矿泉水', '瓶', ?, ?)",
      <Object?>[fxNow, fxNow],
    );
    fxRaw.dispose();

    check('化石是 v1（user_version = 1）', fxVersion == 1, '实际 $fxVersion');
    final Db fxMigrated = Db.open(fxPath);
    check('化石库升到当前版本', fxMigrated.schemaVersion == Schema.version);
    check(
        '迁移不丢数据',
        fxMigrated.raw
                .select("SELECT name FROM products WHERE id = 'p-v1'")
                .first['name'] ==
            '矿泉水');
    check(
        '新列对老行取 NULL',
        fxMigrated.raw
                .select("SELECT package_note FROM products WHERE id = 'p-v1'")
                .first['package_note'] ==
            null);
    fxMigrated.close();

    // 迁移前自动备份（reply.md Schema 篇 §3.2）—— 升级前必须留退路
    final File fxBackup = File('$fxPath.before-v1');
    check('迁移前已备份 <db>.before-v1', fxBackup.existsSync());
    if (fxBackup.existsSync()) {
      final Database backupRaw = sqlite3.open(fxBackup.path);
      final int backupVersion =
          backupRaw.select('PRAGMA user_version').first['user_version']! as int;
      final bool backupHasNewColumn = backupRaw
          .select('PRAGMA table_info(products)')
          .map((Row r) => r['name'])
          .contains('package_note');
      backupRaw.dispose();
      check('备份是**迁移前**的样子（v1 且无 package_note）',
          backupVersion == 1 && !backupHasNewColumn,
          'v$backupVersion / 有新列=$backupHasNewColumn');
    }
  }

  // 空库（v0）不备份 —— 没有旧数据要保
  final String freshPath = migPath('fresh.db');
  final Db fresh = Db.open(freshPath);
  check('空库（v0）不备份', !File('$freshPath.before-v0').existsSync());
  fresh.close();
  try {
    migTmp.deleteSync(recursive: true);
  } catch (_) {
    // Windows 上文件可能还被占用 —— 不影响结论
  }

  db.close();
  check('close() 后可用', !db.inTransaction);

  stdout.writeln('\n${'=' * 46}');
  if (_failures.isEmpty) {
    stdout.writeln('全部通过：$_passed 项');
    exit(0);
  }
  stdout.writeln('通过 $_passed 项，失败 ${_failures.length} 项：');
  for (final String failure in _failures) {
    stdout.writeln('  - $failure');
  }
  exit(1);
}
