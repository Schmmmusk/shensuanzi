/// 生成 **schema v1 化石库**（`test/fixtures/v1_empty.db`）。
///
/// ## 为什么内嵌 DDL，而不是 import `Schema`
///
/// 化石必须是**当时真正跑过的结构**。用当前的 `Schema.createStatements`
/// 生成 = **循环验证**：造出来的「v1 库」带着今天的定义，迁移测试永远是绿的，
/// 而真用户的库不是那样。所以这里的 DDL 是**逐字抄自 git 历史**的文本快照，
/// **不得「顺手同步」成当前版本**。
///
/// **来源**：`git show 7da3323~1:packages/shensuanzi_core/lib/src/db/schema.dart`
/// （`7da3323` = 引入 schema v2 的提交；`~1` = 它之前，即 v1 的最后状态）。
/// 复核命令：
///
/// ```bash
/// git show 7da3323~1:packages/shensuanzi_core/lib/src/db/schema.dart | \
///   sed -n '/static const List<String> createStatements/,/^  \];$/p'
/// ```
///
/// ## 用法
///
/// ```bash
/// cd packages/shensuanzi_core
/// dart run tool/make_fixture.dart            # 首次生成
/// dart run tool/make_fixture.dart --force    # 重建（需显式确认，见下）
/// ```
///
/// ⚠️ **化石一旦提交就不再修改**（`docs/testing.md`「迁移测试」）——
/// 改了它 = 篡改历史 = 迁移测试通过但真用户会炸。所以文件已存在时**必须**
/// 加 `--force` 才会重建。
///
/// ⚠️ **测试打开化石前必须先拷贝到临时目录**：`Db.open` 会就地跑迁移，
/// 直接打开化石文件会把 v1 结构升级成 v2——**化石就被改坏了**。
///
/// ## 自检（写出前，不通过则拒绝落盘）
///
/// 1. `PRAGMA user_version == 1`
/// 2. `products` 表**不含** `package_note`（v2 才加的列——防止误粘 v2 DDL）
/// 3. 表集合 == 12 张
/// 4. 索引 == 26 个
library;

import 'dart:io';

import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:sqlite3/sqlite3.dart';

// ------------------------------------------------------------------ 表名常量
//
// 与 `Schema` 同名同值 —— 下面 DDL 里的 `$products` 等插值靠它们成立。
// **不要**改成 import Schema：化石的定义必须自包含（见文件头）。

const String products = 'products';
const String parties = 'parties';
const String accounts = 'accounts';
const String documents = 'documents';
const String documentLines = 'document_lines';
const String stockLedger = 'stock_ledger';
const String moneyLedger = 'money_ledger';
const String partyLedger = 'party_ledger';
const String settlements = 'settlements';
const String syncQueue = 'sync_queue';
const String clockOffset = 'clock_offset';
const String syncCursor = 'sync_cursor';

/// v1 的建表语句（**逐字抄自 git 历史，见文件头**）。
const List<String> _v1CreateStatements = <String>[
  // ============================ 主数据 ============================
  '''
    CREATE TABLE $products (
      id            TEXT PRIMARY KEY,
      code          TEXT NOT NULL UNIQUE,
      name          TEXT NOT NULL,
      barcode       TEXT,
      unit          TEXT NOT NULL DEFAULT '件',
      cost_price    INTEGER NOT NULL DEFAULT 0,
      sell_price    INTEGER NOT NULL DEFAULT 0,
      safety_stock  INTEGER NOT NULL DEFAULT 0,
      category      TEXT,
      is_active     INTEGER NOT NULL DEFAULT 1,
      remark        TEXT,
      created_at    INTEGER NOT NULL,
      updated_at    INTEGER NOT NULL,
      sync_version  INTEGER NOT NULL DEFAULT 0
    )
    ''',
  'CREATE INDEX idx_products_barcode ON $products(barcode)',
  // 同步拉取游标：主数据用 (updated_at, id) 复合（R-13 方案 A）。
  // 与 documents 的 (created_at, id) 同构 —— 时间戳不唯一，必须带 id 兜底。
  'CREATE INDEX idx_products_updated ON $products(updated_at, id)',

  '''
    CREATE TABLE $parties (
      id            TEXT PRIMARY KEY,
      name          TEXT NOT NULL,
      phone         TEXT,
      address       TEXT,
      roles         TEXT NOT NULL DEFAULT '[]',
      credit_limit  INTEGER NOT NULL DEFAULT 0,
      is_active     INTEGER NOT NULL DEFAULT 1,
      remark        TEXT,
      created_at    INTEGER NOT NULL,
      updated_at    INTEGER NOT NULL,
      sync_version  INTEGER NOT NULL DEFAULT 0
    )
    ''',
  'CREATE INDEX idx_parties_phone ON $parties(phone)',
  'CREATE INDEX idx_parties_updated ON $parties(updated_at, id)',

  '''
    CREATE TABLE $accounts (
      id              TEXT PRIMARY KEY,
      name            TEXT NOT NULL,
      type            TEXT NOT NULL,
      initial_balance INTEGER NOT NULL DEFAULT 0,
      is_active       INTEGER NOT NULL DEFAULT 1,
      created_at      INTEGER NOT NULL,
      updated_at      INTEGER NOT NULL,
      sync_version    INTEGER NOT NULL DEFAULT 0
    )
    ''',
  'CREATE INDEX idx_accounts_updated ON $accounts(updated_at, id)',

  // ============================ 单据 ============================
  '''
    CREATE TABLE $documents (
      id              TEXT PRIMARY KEY,
      doc_no          TEXT NOT NULL UNIQUE,
      doc_type        TEXT NOT NULL,
      status          TEXT NOT NULL,
      party_id        TEXT,
      account_id      TEXT,
      total_amount    INTEGER NOT NULL DEFAULT 0,
      paid_amount     INTEGER NOT NULL DEFAULT 0,
      ref_doc_id      TEXT,
      occurred_at     INTEGER NOT NULL,
      time_estimated  INTEGER NOT NULL DEFAULT 0,
      created_at      INTEGER NOT NULL,
      updated_at      INTEGER NOT NULL,
      remark          TEXT
    )
    ''',
  'CREATE INDEX idx_documents_type_status ON $documents(doc_type, status)',
  'CREATE INDEX idx_documents_party       ON $documents(party_id)',
  'CREATE INDEX idx_documents_occurred    ON $documents(occurred_at)',
  'CREATE INDEX idx_documents_ref         ON $documents(ref_doc_id)',
  // 同步拉取游标：`documents` 没有 seq_no，用 (created_at, id) 复合游标
  // （见 docs/sync_protocol.md §8.2 / R-4 处置）
  'CREATE INDEX idx_documents_created     ON $documents(created_at, id)',

  '''
    CREATE TABLE $documentLines (
      id           TEXT PRIMARY KEY,
      document_id  TEXT NOT NULL,
      product_id   TEXT NOT NULL,
      quantity     INTEGER NOT NULL,
      unit_price   INTEGER NOT NULL,
      amount       INTEGER NOT NULL,
      remark       TEXT,
      FOREIGN KEY (document_id) REFERENCES $documents(id),
      FOREIGN KEY (product_id)  REFERENCES $products(id)
    )
    ''',
  'CREATE INDEX idx_lines_document ON $documentLines(document_id)',
  'CREATE INDEX idx_lines_product  ON $documentLines(product_id)',

  // ============================ 四张流水 ============================
  // ⚠️ 业务数据不可变：不提供 UPDATE。total_cost 是成本真相，unit_cost 只是派生展示值。
  '''
    CREATE TABLE $stockLedger (
      id              TEXT PRIMARY KEY,
      product_id      TEXT NOT NULL,
      document_id     TEXT NOT NULL,
      quantity        INTEGER NOT NULL,
      unit_cost       INTEGER NOT NULL DEFAULT 0,
      total_cost      INTEGER NOT NULL DEFAULT 0,
      seq_no          INTEGER NOT NULL,
      occurred_at     INTEGER NOT NULL,
      time_estimated  INTEGER NOT NULL DEFAULT 0,
      created_at      INTEGER NOT NULL,
      FOREIGN KEY (product_id)  REFERENCES $products(id),
      FOREIGN KEY (document_id) REFERENCES $documents(id)
    )
    ''',
  'CREATE INDEX idx_stock_product_seq ON $stockLedger(product_id, seq_no)',
  'CREATE INDEX idx_stock_document    ON $stockLedger(document_id)',
  'CREATE UNIQUE INDEX idx_stock_seq  ON $stockLedger(seq_no)',

  '''
    CREATE TABLE $moneyLedger (
      id              TEXT PRIMARY KEY,
      account_id      TEXT NOT NULL,
      document_id     TEXT NOT NULL,
      amount          INTEGER NOT NULL,
      seq_no          INTEGER NOT NULL,
      occurred_at     INTEGER NOT NULL,
      time_estimated  INTEGER NOT NULL DEFAULT 0,
      external_ref    TEXT,
      created_at      INTEGER NOT NULL,
      FOREIGN KEY (account_id)  REFERENCES $accounts(id),
      FOREIGN KEY (document_id) REFERENCES $documents(id)
    )
    ''',
  'CREATE INDEX idx_money_account_seq ON $moneyLedger(account_id, seq_no)',
  'CREATE INDEX idx_money_document    ON $moneyLedger(document_id)',
  'CREATE UNIQUE INDEX idx_money_seq  ON $moneyLedger(seq_no)',

  '''
    CREATE TABLE $partyLedger (
      id              TEXT PRIMARY KEY,
      party_id        TEXT NOT NULL,
      document_id     TEXT NOT NULL,
      amount          INTEGER NOT NULL,
      seq_no          INTEGER NOT NULL,
      occurred_at     INTEGER NOT NULL,
      time_estimated  INTEGER NOT NULL DEFAULT 0,
      created_at      INTEGER NOT NULL,
      FOREIGN KEY (party_id)    REFERENCES $parties(id),
      FOREIGN KEY (document_id) REFERENCES $documents(id)
    )
    ''',
  'CREATE INDEX idx_party_ledger_party_seq ON $partyLedger(party_id, seq_no)',
  'CREATE INDEX idx_party_ledger_document  ON $partyLedger(document_id)',
  'CREATE UNIQUE INDEX idx_party_ledger_seq ON $partyLedger(seq_no)',

  // 核销关系。target_doc_id = NULL 表示预收/预付。
  // 分配（allocations）随同步 payload 传入，由 RuleEngine 在 RULE-004/005 内消费
  // —— 见 docs/sync_protocol.md §8.1（R-1 裁定）。
  '''
    CREATE TABLE $settlements (
      id              TEXT PRIMARY KEY,
      receipt_doc_id  TEXT NOT NULL,
      target_doc_id   TEXT,
      amount          INTEGER NOT NULL,
      seq_no          INTEGER NOT NULL,
      time_estimated  INTEGER NOT NULL DEFAULT 0,
      created_at      INTEGER NOT NULL,
      FOREIGN KEY (receipt_doc_id) REFERENCES $documents(id),
      FOREIGN KEY (target_doc_id)  REFERENCES $documents(id)
    )
    ''',
  'CREATE INDEX idx_settle_receipt ON $settlements(receipt_doc_id)',
  'CREATE INDEX idx_settle_target  ON $settlements(target_doc_id)',
  'CREATE UNIQUE INDEX idx_settle_seq ON $settlements(seq_no)',

  // ============================ 同步（仅客户端使用） ============================
  '''
    CREATE TABLE $syncQueue (
      id             TEXT PRIMARY KEY,
      entity         TEXT NOT NULL,
      entity_id      TEXT NOT NULL,
      operation      TEXT NOT NULL,
      base_version   INTEGER,
      payload        TEXT NOT NULL,
      status         TEXT NOT NULL DEFAULT 'pending',
      retry_count    INTEGER NOT NULL DEFAULT 0,
      last_error     TEXT,
      created_at     INTEGER NOT NULL,
      next_retry_at  INTEGER NOT NULL DEFAULT 0
    )
    ''',
  'CREATE INDEX idx_sync_status ON $syncQueue(status, next_retry_at)',
  'CREATE INDEX idx_sync_entity ON $syncQueue(entity_id, operation)',

  // ============================ 时钟偏移（仅客户端使用） ============================
  '''
    CREATE TABLE $clockOffset (
      id          INTEGER PRIMARY KEY CHECK (id = 1),
      offset_ms   INTEGER NOT NULL DEFAULT 0,
      updated_at  INTEGER NOT NULL
    )
    ''',

  // ============================ 拉取游标（仅客户端使用） ============================
  // R-14 方案 A。**游标是「服务器已交付到哪里」的凭证，不是「本地有什么」的推导**：
  // 客户端只**原样保存**主机返回的 `next_cursors` 值，从不解析、从不从镜像水位推算。
  //
  // 为什么不从 `MAX(本地镜像)` 推算：写入路径有三条 —— pull、push 的回程、
  // 本地离线写。后两条会让本地镜像**越过**服务器已交付的水位，
  // 于是推算出的游标会跳过后一段服务器数据，且**静默丢数据**（不报错、不自愈）。
  '''
    CREATE TABLE $syncCursor (
      entity      TEXT PRIMARY KEY,
      cursor      TEXT NOT NULL,
      updated_at  INTEGER NOT NULL
    )
    ''',
];

/// v1 的期望表（自检用；12 张）
const List<String> _expectedTables = <String>[
  products,
  parties,
  accounts,
  documents,
  documentLines,
  stockLedger,
  moneyLedger,
  partyLedger,
  settlements,
  syncQueue,
  clockOffset,
  syncCursor,
];

/// v1 的期望索引数（26 个；v2 未加索引，两版相同）
const int _expectedIndexCount = 26;

void main(List<String> args) {
  useLocalSqlite();

  const String outPath = 'test/fixtures/v1_empty.db';
  final File out = File(outPath);

  if (out.existsSync() && !args.contains('--force')) {
    stderr.writeln(
      '❌ $outPath 已存在。\n'
      '   化石一旦提交就不再修改（docs/testing.md）；确实要重建请加 --force。',
    );
    exit(1);
  }

  out.parent.createSync(recursive: true);
  if (out.existsSync()) out.deleteSync();

  final Database db = sqlite3.open(outPath);
  for (final String sql in _v1CreateStatements) {
    db.execute(sql);
  }
  db.execute('PRAGMA user_version = 1');

  // ---- 自检：化石必须**真的是 v1**（写出前校验，不通过就拒绝落盘）
  final List<String> problems = <String>[];

  final int userVersion =
      db.select('PRAGMA user_version').first['user_version']! as int;
  if (userVersion != 1) {
    problems.add('user_version = $userVersion，应为 1');
  }

  final Set<String> productColumns = db
      .select('PRAGMA table_info($products)')
      .map((Row r) => r['name']! as String)
      .toSet();
  if (productColumns.contains('package_note')) {
    problems.add(
      'products 含 package_note —— 这是 v2 才加的列，'
      '说明脚本里粘的是 v2 的 DDL（化石必须是 v1）',
    );
  }

  final Set<String> tables = db
      .select("SELECT name FROM sqlite_master WHERE type = 'table'")
      .map((Row r) => r['name']! as String)
      .toSet();
  if (tables.length != _expectedTables.length) {
    problems.add('表 ${tables.length} 张，应为 ${_expectedTables.length} 张：$tables');
  }
  for (final String table in _expectedTables) {
    if (!tables.contains(table)) problems.add('缺表 $table');
  }

  // ⚠️ 必须排除 `sqlite_autoindex_%`：TEXT 主键与 UNIQUE 约束会自动生成
  // 隐藏索引（11 张 TEXT 主键表 + products.code + documents.doc_no = 13 个），
  // 它们不是我们写的索引。只数**显式**的 26 个。
  final int indexCount = db
      .select(
        "SELECT COUNT(*) AS n FROM sqlite_master "
        "WHERE type = 'index' AND name NOT LIKE 'sqlite_autoindex_%'",
      )
      .first['n']!
      as int;
  if (indexCount != _expectedIndexCount) {
    problems.add('索引 $indexCount 个，应为 $_expectedIndexCount 个');
  }

  db.dispose();

  if (problems.isNotEmpty) {
    out.deleteSync(); // 坏化石不许落盘
    stderr.writeln('❌ 自检不通过，已删除产物：');
    for (final String p in problems) {
      stderr.writeln('   - $p');
    }
    exit(1);
  }

  stdout.writeln(
    '✅ 已生成 $outPath\n'
    '   v1 化石：${tables.length} 表 / $indexCount 索引 / user_version = 1\n'
    '   来源：git 7da3323~1 的 createStatements（见脚本文件头复核命令）',
  );
}
