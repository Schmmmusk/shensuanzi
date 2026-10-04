// schema 结构与约束。对应 `docs/data_model.md`。
//
// ⚠️ 纯 Dart 测试需要可用的 SQLite 原生库：
//   - 非 Windows：通常能自动找到系统 sqlite3
//   - Windows：需自行提供 sqlite3.dll，或设置环境变量 SQLITE3_DLL 指向它
// 见 `lib/sqlite_local.dart`。
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'package:shensuanzi_core/sqlite_local.dart';
import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;

  setUp(() {
    resetClock();
    db = newMemoryDb();
  });

  tearDown(() => db.close());

  Set<Object?> objectsOfType(String type) => db.raw
      .select("SELECT name FROM sqlite_master WHERE type = ?", <Object?>[type])
      .map((Row r) => r['name'])
      .toSet();

  test('建出全部 12 张表，且没有多余的', () {
    // 双向断言：既查「`allTables` 里的都建了」，也查「建出来的都在 `allTables` 里」。
    // 单向 contains 抓不到「加了表却忘了登记进 allTables」。
    expect(objectsOfType('table'), Schema.allTables.toSet());
  });

  test('user_version 写入 Schema.version', () {
    expect(db.schemaVersion, Schema.version);
  });

  test('建出全部索引', () {
    const List<String> expected = <String>[
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
    final Set<Object?> indexes = objectsOfType('index');
    for (final String index in expected) {
      expect(indexes, contains(index), reason: '缺少索引 $index');
    }
  });

  test('业务表没有 is_active / sync_version（它们是主数据专属）', () {
    for (final String table in Schema.businessTables) {
      final Set<Object?> columns = db.raw
          .select('PRAGMA table_info($table)')
          .map((Row r) => r['name'])
          .toSet();
      expect(columns, isNot(contains('is_active')), reason: '$table 不应有 is_active');
      expect(
        columns,
        isNot(contains('sync_version')),
        reason: '$table 不应有 sync_version',
      );
    }
  });

  test('documents 的 time_estimated 存在（P1-9）', () {
    final Set<Object?> columns = db.raw
        .select('PRAGMA table_info(${Schema.documents})')
        .map((Row r) => r['name'])
        .toSet();
    expect(columns, contains('time_estimated'));
  });

  test('四张流水表都没有 sync_version', () {
    for (final String table in <String>[
      Schema.stockLedger,
      Schema.moneyLedger,
      Schema.partyLedger,
      Schema.settlements,
    ]) {
      final Set<Object?> columns = db.raw
          .select('PRAGMA table_info($table)')
          .map((Row r) => r['name'])
          .toSet();
      expect(columns, isNot(contains('sync_version')));
    }
  });

  group('外键', () {
    test('默认开启', () {
      expect(db.foreignKeysEnabled, isTrue);
    });

    test('拒绝引用不存在的单据', () {
      insertProduct(db.raw, productId);
      expect(
        () => db.raw.execute(
          'INSERT INTO document_lines (id, document_id, product_id, quantity, unit_price, amount) '
          'VALUES (?,?,?,?,?,?)',
          <Object?>['l-1', 'no-such-doc', productId, 1, 100, 100],
        ),
        throwsA(isA<SqliteException>()),
      );
    });

    test('拒绝引用不存在的商品', () {
      insertDocument(db.raw, documentId);
      expect(
        () => db.raw.execute(
          'INSERT INTO document_lines (id, document_id, product_id, quantity, unit_price, amount) '
          'VALUES (?,?,?,?,?,?)',
          <Object?>['l-2', documentId, 'no-such-product', 1, 100, 100],
        ),
        throwsA(isA<SqliteException>()),
      );
    });

    test('可关闭（客户端镜像批量写入时需要）', () {
      final Db loose = newMemoryDb(foreignKeys: false);
      addTearDown(loose.close);
      expect(loose.foreignKeysEnabled, isFalse);
      expect(
        () => loose.raw.execute(
          'INSERT INTO document_lines (id, document_id, product_id, quantity, unit_price, amount) '
          'VALUES (?,?,?,?,?,?)',
          <Object?>['l-3', 'no-such-doc', 'no-such-product', 1, 100, 100],
        ),
        returnsNormally,
      );
    });
  });

  group('约束', () {
    test('documents.doc_no 唯一（主机生成正式号）', () {
      insertDocument(db.raw, documentId, docNo: 'CG20260925-001');
      expect(
        () => insertDocument(db.raw, 'd-2', docNo: 'CG20260925-001'),
        throwsA(isA<SqliteException>()),
      );
    });

    test('products.code 唯一', () {
      insertProduct(db.raw, productId, code: 'P001');
      expect(
        () => insertProduct(db.raw, 'p-2', code: 'P001'),
        throwsA(isA<SqliteException>()),
      );
    });

    test('seq_no 每表独立：不同表可复用同一序号', () {
      seedMinimal(db);
      insertStock(db.raw, 's-1', seqNo: 1);
      expect(() => insertMoney(db.raw, 'm-1', seqNo: 1), returnsNormally);
    });

    test('seq_no 同表内唯一', () {
      seedMinimal(db);
      insertStock(db.raw, 's-1', seqNo: 1);
      expect(() => insertStock(db.raw, 's-dup', seqNo: 1), throwsA(isA<SqliteException>()));
    });

    test('clock_offset 只允许一行（CHECK id = 1）', () {
      db.raw.execute(
        'INSERT INTO clock_offset (id, offset_ms, updated_at) VALUES (1, 0, ?)',
        <Object?>[now()],
      );
      expect(
        () => db.raw.execute(
          'INSERT INTO clock_offset (id, offset_ms, updated_at) VALUES (2, 0, ?)',
          <Object?>[now()],
        ),
        throwsA(isA<SqliteException>()),
      );
    });
  });

  // ============================================================ 迁移框架
  //
  // **两层保护**（reply.md §二·②）：
  //  - **化石库**（`test/fixtures/v1_empty.db`）：端到端 —— 真 v1 库能不能升上来。
  //    化石由 `tool/make_fixture.dart` 从 git 历史生成，**一旦提交不再修改**。
  //  - **执行器单元测试**（本组最后一条）：ALTER / 事务 / 回滚本身对不对。
  //    它用「当前 DDL 建表 + [downgradeToV1] 降级」造 v1 形状 —— 测的不是历史，
  //    是执行器；与化石测试**不冲突**，两条各管一层。
  //    ⚠️ 降级**跟着迁移链走**（逐条读 `migrationStep`），不是手写一个 `DROP COLUMN`
  //    —— 手写的那个在 v3 加列后就造错了形状（2026-10-03 真实踩过）。
  group('迁移框架', () {
    test('migrationStep(1) 恰好一条 ALTER，且点名 products 与列', () {
      final List<String> statements = Schema.migrationStep(1);
      expect(statements, hasLength(1));
      expect(
        statements.single,
        contains('ALTER TABLE products ADD COLUMN package_note'),
      );
    });

    test('migrationStep(2) 恰好五条 ALTER，点名两张表与五列（v3，§BD）', () {
      final List<String> statements = Schema.migrationStep(2);
      expect(statements, hasLength(5));
      expect(
        statements.every((String s) => s.startsWith('ALTER TABLE')),
        isTrue,
        reason: '全是 ADD COLUMN —— 纪律 14：加列不重建表',
      );
      expect(
        statements[0],
        contains('ALTER TABLE products ADD COLUMN package_unit TEXT'),
      );
      expect(
        statements[1],
        contains('ALTER TABLE products ADD COLUMN package_size INTEGER'),
      );
      expect(
        statements[2],
        contains(
          'ALTER TABLE document_lines ADD COLUMN discount_amount '
          'INTEGER NOT NULL DEFAULT 0',
        ),
        reason: 'NOT NULL 必须带非空默认（ALTER ADD COLUMN 的硬要求）',
      );
      expect(
        statements[3],
        contains('ALTER TABLE document_lines ADD COLUMN entry_quantity INTEGER'),
      );
      expect(
        statements[4],
        contains('ALTER TABLE document_lines ADD COLUMN entry_unit TEXT'),
      );
    });

    test('改 v3 不许回头改 v2 那一步（迁移链逐版本、只追加）', () {
      expect(Schema.migrationStep(1), hasLength(1));
      expect(Schema.migrationStep(1).single, contains('package_note'));
    });

    test('migrationStep(当前版) → MissingMigrationException（当前没有下一步）', () {
      expect(
        () => Schema.migrationStep(Schema.version),
        throwsA(isA<MissingMigrationException>()),
      );
    });

    test('旧代码打开新库 → SchemaTooNewException（拒绝，不是崩溃）', () {
      final Directory box = Directory.systemTemp.createTempSync('sz_too_new_');
      addTearDown(() => deleteQuietly(box));
      final String path = '${box.path}/new.db';

      // 造一个「更新版本创建的库」：只写 user_version
      final Database raw = sqlite3.open(path);
      raw.execute('PRAGMA user_version = ${Schema.version + 1}');
      raw.dispose();

      expect(
        () => Db.open(path),
        throwsA(isA<SchemaTooNewException>()),
        reason: '拒绝比崩溃好：拒绝能告诉用户「升级软件或从备份恢复」',
      );
    });

    test('迁移失败路径要求连接**立即释放**（否则 Windows 上句柄泄漏）', () {
      // 与「是否回滚」无关 —— 失败后连接必须已经 dispose，
      // 否则 Windows 上 .db 文件句柄被持有，用户连临时目录都删不掉
      // （本仓自检里真实出现过）。
      final Directory box = Directory.systemTemp.createTempSync('sz_leak_');
      final String path = '${box.path}/new.db';

      final Database raw = sqlite3.open(path);
      raw.execute('PRAGMA user_version = ${Schema.version + 1}');
      raw.dispose();

      expect(() => Db.open(path), throwsA(isA<SchemaTooNewException>()));

      // 句柄已释放的**可观测证据**：目录删得掉
      deleteQuietly(box);
      expect(
        box.existsSync(),
        isFalse,
        reason: '迁移失败必须 dispose 连接，否则文件句柄泄漏',
      );
    });

    test('已是最新的库重复打开 → 不重复改表（幂等）', () {
      final Directory box = Directory.systemTemp.createTempSync('sz_reopen_');
      addTearDown(() => deleteQuietly(box));
      final String path = '${box.path}/d.db';

      final Db first = Db.open(path);
      expect(first.schemaVersion, Schema.version);
      first.close();

      // 第二次：current == version → `_migrate` 直接返回，不重复建表/迁移
      final Db second = Db.open(path);
      addTearDown(second.close);
      expect(second.schemaVersion, Schema.version);
    });

    test('新库直接含 package_note 列（不用迁移）', () {
      final List<String> columns = db.raw
          .select('PRAGMA table_info(products)')
          .map((Row r) => r['name']! as String)
          .toList();
      expect(columns, contains('package_note'));
    });

    test('新库直接含 v3 五列（不用迁移）', () {
      Set<Object?> columnsOf(String table) => db.raw
          .select('PRAGMA table_info($table)')
          .map((Row r) => r['name'])
          .toSet();
      expect(
        columnsOf(Schema.products),
        containsAll(<String>['package_unit', 'package_size']),
      );
      expect(
        columnsOf(Schema.documentLines),
        containsAll(<String>[
          'discount_amount',
          'entry_quantity',
          'entry_unit',
        ]),
      );
    });

    test('document_lines 新列的默认值：让价 0、录入原文 NULL', () {
      // 造一条**故意不填新列**的行 ⇒ 看默认值（外键开着，先建商品与单据）
      final int t = now();
      db.raw.execute(
        'INSERT INTO products (id, code, name, unit, created_at, updated_at) '
        "VALUES ('p-def', 'P0001', '苹果', '个', ?, ?)",
        <Object?>[t, t],
      );
      db.raw.execute(
        'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
        'occurred_at, created_at, updated_at) '
        "VALUES ('d-def', 'XS1', 'sale', 'confirmed', 0, ?, ?, ?)",
        <Object?>[t, t, t],
      );
      db.raw.execute(
        'INSERT INTO document_lines (id, document_id, product_id, quantity, '
        "unit_price, amount) VALUES ('l-def', 'd-def', 'p-def', 36, 2083, 75000)",
      );

      final Map<String, Object?> row = db.raw
          .select("SELECT * FROM document_lines WHERE id = 'l-def'")
          .first;
      expect(row['discount_amount'], 0, reason: '让价默认 0（不是 NULL）');
      expect(row['entry_quantity'], isNull);
      expect(
        row['entry_unit'],
        isNull,
        reason: 'null = 用户没在两种单位间切换（§BD·三 第 2 条）',
      );
      expect(
        row['quantity'],
        36,
        reason: '⚠️ quantity 仍是**最小单位数量** —— 本步（1a）不动口径',
      );
    });

    test('化石库（v1_empty.db）升到当前版：结构补列、老数据仍在、列可写', () {
      // ⚠️ **先拷贝再打开**：`Db.open` 会就地迁移 —— 直接打开化石会把它改坏，
      // 而化石一旦被改就等于篡改历史（docs/testing.md）
      final File fixture = File('test/fixtures/v1_empty.db');
      expect(
        fixture.existsSync(),
        isTrue,
        reason: '化石缺失：先在 core 包里跑 dart run tool/make_fixture.dart',
      );

      final Directory box = Directory.systemTemp.createTempSync('sz_fixture_');
      addTearDown(() => deleteQuietly(box));
      final String path = '${box.path}/v1.db';
      fixture.copySync(path);

      // 往化石副本里塞一条 v1 风格的老数据（化石只建结构，不带数据）
      final Database raw = sqlite3.open(path);
      expect(
        raw.select('PRAGMA user_version').first['user_version'],
        1,
        reason: '化石必须是 v1',
      );
      final int t = now();
      raw.execute(
        'INSERT INTO products (id, code, name, unit, created_at, updated_at) '
        "VALUES ('p-v1', 'P0001', '矿泉水', '瓶', ?, ?)",
        <Object?>[t, t],
      );
      raw.dispose();

      // 正常入口打开 → 逐版迁移到当前版本
      final Db migrated = Db.open(path);
      addTearDown(migrated.close);

      expect(migrated.schemaVersion, Schema.version);
      expect(
        migrated.raw
            .select("SELECT name FROM products WHERE id = 'p-v1'")
            .first['name'],
        '矿泉水',
        reason: '迁移不能丢数据',
      );
      expect(
        migrated.raw
            .select("SELECT package_note FROM products WHERE id = 'p-v1'")
            .first['package_note'],
        isNull,
        reason: 'ALTER ADD COLUMN 对已有行自动取 NULL，不需要回填',
      );

      // 新列是活的，不是摆设
      migrated.raw.execute(
        "UPDATE products SET package_note = '1 箱 = 48 瓶' WHERE id = 'p-v1'",
      );
      expect(
        migrated.raw
            .select("SELECT package_note FROM products WHERE id = 'p-v1'")
            .first['package_note'],
        '1 箱 = 48 瓶',
      );
    });

    // ---------------------------------------------------------------- 环级验证
    //
    // 审查意见 §五：「迁移链是**链**，写完一环就该验证一环」——
    // 于是这里不只测「最终到了 v3」，还测「**中间的 v2 那一环真的跑了**」
    // 与「某一环失败时，链停在哪、有没有半个结构」。
    test('化石升至 v3：**两环都跑**（v1→v2→v3），五列到齐', () {
      final File fixture = File('test/fixtures/v1_empty.db');
      final Directory box = Directory.systemTemp.createTempSync('sz_ring_ok_');
      addTearDown(() => deleteQuietly(box));
      final String path = '${box.path}/v3.db';
      fixture.copySync(path); // ⚠️ 先拷贝再打开（直接开会把化石改坏）

      final Db migrated = Db.open(path);
      addTearDown(migrated.close);
      expect(migrated.schemaVersion, 3);

      Set<Object?> columnsOf(String table) => migrated.raw
          .select('PRAGMA table_info($table)')
          .map((Row r) => r['name'])
          .toSet();

      // 环级：v1→v2 那一环的产物在 ⇒ 证明链是**逐环**跑的，不是一步跳到 v3
      // （「只查最终结构」的断言漏得掉这一点：v2 的列可以由别的路径补上）
      expect(columnsOf(Schema.products), contains('package_note'));
      // 环级：v2→v3 那一环的产物
      expect(
        columnsOf(Schema.products),
        containsAll(<String>['package_unit', 'package_size']),
      );
      expect(
        columnsOf(Schema.documentLines),
        containsAll(<String>[
          'discount_amount',
          'entry_quantity',
          'entry_unit',
        ]),
      );

      // 迁移后的库里新列是**活的**（不是只有结构）
      final int t = now();
      migrated.raw.execute(
        'INSERT INTO products (id, code, name, unit, created_at, updated_at) '
        "VALUES ('p-live', 'P0002', '苹果', '个', ?, ?)",
        <Object?>[t, t],
      );
      migrated.raw.execute(
        'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
        'occurred_at, created_at, updated_at) '
        "VALUES ('d-live', 'XS2', 'sale', 'confirmed', 0, ?, ?, ?)",
        <Object?>[t, t, t],
      );
      migrated.raw.execute(
        'INSERT INTO document_lines (id, document_id, product_id, quantity, '
        'unit_price, amount, entry_quantity, entry_unit) '
        "VALUES ('l-live', 'd-live', 'p-live', 36, 2083, 75000, 3, '箱')",
      );
      final Map<String, Object?> line = migrated.raw
          .select("SELECT * FROM document_lines WHERE id = 'l-live'")
          .first;
      expect(line['entry_quantity'], 3);
      expect(line['entry_unit'], '箱');
      expect(line['discount_amount'], 0, reason: '没填让价 ⇒ 默认 0');
    });

    test('环级：v2→v3 失败 ⇒ **停在 v2**（该版整条回滚）、重试从断点继续', () {
      final File fixture = File('test/fixtures/v1_empty.db');
      final Directory box = Directory.systemTemp.createTempSync('sz_ring_bad_');
      addTearDown(() => deleteQuietly(box));
      final String path = '${box.path}/ring.db';
      fixture.copySync(path);

      // 预先塞一个 v3 要加的同名列 ⇒ v2→v3 的**最后一条** ALTER 必然 duplicate column。
      // 这样前四条会执行、失败发生在中间，正好检验「每版一个事务」。
      final Database raw = sqlite3.open(path);
      raw.execute('ALTER TABLE document_lines ADD COLUMN entry_unit TEXT');
      raw.execute('PRAGMA user_version = 1');
      raw.dispose();

      expect(() => Db.open(path), throwsA(isA<SqliteException>()));

      final Database chk = sqlite3.open(path);
      expect(
        chk.select('PRAGMA user_version').first['user_version'],
        2,
        reason: 'v1→v2 那一环**已提交并保留** —— 每版一个事务的粒度',
      );
      final Set<Object?> products = chk
          .select('PRAGMA table_info(products)')
          .map((Row r) => r['name'])
          .toSet();
      expect(products, contains('package_note'));
      expect(
        products,
        isNot(contains('package_unit')),
        reason: 'v2→v3 那一版**整条事务回滚** —— 没留下半个结构',
      );
      final Set<Object?> lines = chk
          .select('PRAGMA table_info(document_lines)')
          .map((Row r) => r['name'])
          .toSet();
      expect(
        lines,
        isNot(contains('discount_amount')),
        reason: '同一版的后几条也回滚了（不只失败那一条）',
      );
      expect(lines, contains('entry_unit'), reason: '那是人为塞的，不是迁移加的');
      chk.dispose();

      expect(
        File('$path.before-v1').existsSync(),
        isTrue,
        reason: '失败的退路要留着供诊断',
      );

      // 重试：从断点继续，**只跑 v2 → v3**
      final Database fix = sqlite3.open(path);
      fix.execute('ALTER TABLE document_lines DROP COLUMN entry_unit');
      fix.dispose();

      final Db retry = Db.open(path);
      addTearDown(retry.close);
      expect(
        retry.schemaVersion,
        3,
        reason: '重试**能成功**本身就证明 v1→v2 **没有重跑** —— '
            'package_note 已在（上一步提交的），若重跑 v1→v2 会报 duplicate column。'
            '这正是「断点续跑」的可观测证据（§BE：失败不停在起点、也不自动回滚）',
      );
      expect(
        File('$path.before-v2').existsSync(),
        isTrue,
        reason: '重试时 current = 2 ⇒ 备份叫 before-v2（不覆盖 before-v1）',
      );
      expect(File('$path.before-v1').existsSync(), isTrue);

      // 第三条：**重开 ⇒ 从 v2→v3 继续，不重跑 v1→v2**。
      // 证据有两层：
      //  ① 这次 `Db.open` **成功了** —— 若它真重跑 v1→v2，那一步会因
      //     `package_note` 已存在而报 duplicate column，早就抛了；
      //  ② 列不重复（再显式钉一次，免得将来有人改成"容忍重复"）。
      final List<Object?> names = retry.raw
          .select('PRAGMA table_info(${Schema.products})')
          .map((Row r) => r['name'])
          .toList();
      expect(
        names.where((Object? n) => n == 'package_note').length,
        1,
        reason: 'package_note 只有一列 ⇒ 重试没有重跑 v1→v2（从断点继续）',
      );
    });

    test('存量库迁移前先备份：<db>.before-v1 是升级前的样子', () {
      final File fixture = File('test/fixtures/v1_empty.db');
      final Directory box = Directory.systemTemp.createTempSync('sz_backup_');
      addTearDown(() => deleteQuietly(box));
      final String path = '${box.path}/v1.db';
      fixture.copySync(path);

      final Db migrated = Db.open(path);
      addTearDown(migrated.close);
      expect(migrated.schemaVersion, Schema.version);

      final File backup = File('$path.before-v1');
      expect(backup.existsSync(), isTrue, reason: '升级前必须留一份退路');

      // 备份是**迁移前**的样子：user_version 仍是 1、没有新列
      final Database raw = sqlite3.open(backup.path);
      expect(raw.select('PRAGMA user_version').first['user_version'], 1);
      expect(
        raw.select('PRAGMA table_info(products)').map((Row r) => r['name']),
        isNot(contains('package_note')),
      );
      raw.dispose();
    });

    test('空库（v0）不备份 —— 没有旧数据要保', () {
      final Directory box = Directory.systemTemp.createTempSync('sz_nov0_');
      addTearDown(() => deleteQuietly(box));
      final String path = '${box.path}/fresh.db';

      final Db fresh = Db.open(path);
      addTearDown(fresh.close);
      expect(fresh.schemaVersion, Schema.version);
      expect(File('$path.before-v0').existsSync(), isFalse);
    });

    test('迁移失败（**第一环就失败**）⇒ 仍是 v1、没有半升级状态；备份留给人工', () {
      // 构造「迁移必然失败」的库：v1 结构上**已经有 package_note 列**
      // ⇒ v1→v2 的 `ALTER TABLE ... ADD COLUMN` 报 duplicate column。
      //
      // ⚠️ 本用例只能证明「**第一环**失败时库还是 v1」—— 那是**因为什么都没提交**，
      // **不是**因为软件做了回滚。软件**不做**自动回滚（§BE）；
      // 「部分成功后再失败会停在哪儿」由下面那条**环级**用例证明
      // （v1→v2 成功、v2→v3 失败 ⇒ 停在 v2）。
      // 旧注释说「「恢复」的完整验证需要两版迁移」已过时：v3 就是两版。
      final File fixture = File('test/fixtures/v1_empty.db');
      final Directory box = Directory.systemTemp.createTempSync('sz_failmig_');
      addTearDown(() => deleteQuietly(box));
      final String path = '${box.path}/v1.db';
      fixture.copySync(path);

      final Database raw = sqlite3.open(path);
      raw.execute('ALTER TABLE products ADD COLUMN package_note TEXT');
      raw.execute('PRAGMA user_version = 1');
      raw.dispose();

      expect(() => Db.open(path), throwsA(isA<SqliteException>()));

      expect(
        File('$path.before-v1').existsSync(),
        isTrue,
        reason: '失败了也要把退路留着供诊断',
      );

      final Database check = sqlite3.open(path);
      expect(
        check.select('PRAGMA user_version').first['user_version'],
        1,
        reason: '没有半升级状态',
      );
      check.dispose();
    });

    test('执行器单元测试：降级构造的 v1 库也走完整迁移（ALTER + 事务）', () {
      final Directory box = Directory.systemTemp.createTempSync('sz_exec_');
      addTearDown(() => deleteQuietly(box));
      final String path = '${box.path}/v1.db';

      final Database raw = sqlite3.open(path);
      for (final String sql in Schema.createStatements) {
        raw.execute(sql);
      }
      // ⚠️ 降级必须**跟着迁移链走**（把每一版加过的列都摘掉）。
      // 手写一个 `DROP COLUMN package_note` 在 v2 时代是对的，v3 加列后就错了 ——
      // 它造出来的是 **v2 形状**，v2→v3 会报
      // `duplicate column name: package_unit`（2026-10-03 真实踩过）。
      downgradeToV1(raw);
      final int t = now();
      raw.execute(
        'INSERT INTO products (id, code, name, unit, created_at, updated_at) '
        "VALUES ('p-v1', 'P0001', '矿泉水', '瓶', ?, ?)",
        <Object?>[t, t],
      );
      raw.execute('PRAGMA user_version = 1');
      raw.dispose();

      final Db migrated = Db.open(path);
      addTearDown(migrated.close);

      expect(migrated.schemaVersion, Schema.version);
      // v1→v2 那一环
      expect(
        migrated.raw
            .select("SELECT package_note FROM products WHERE id = 'p-v1'")
            .first['package_note'],
        isNull,
      );
      // v2→v3 那一环 —— **两环都要断言**：只查最终版本号会让「链跳环」溜过去
      final Set<Object?> columns = migrated.raw
          .select('PRAGMA table_info(${Schema.products})')
          .map((Row r) => r['name'])
          .toSet();
      expect(columns, containsAll(<String>['package_unit', 'package_size']));
      expect(
        migrated.raw
            .select("SELECT package_unit FROM products WHERE id = 'p-v1'")
            .first['package_unit'],
        isNull,
        reason: '新列对降级造出来的老行自动取 NULL，不需要回填',
      );
    });

    test('降级构造出来的形状 == 化石的 v1 形状（逐表逐列 + 索引）', () {
      // 这条是 [downgradeToV1] 的**前提校验**：若「当前 DDL 减去迁移链加过的列」
      // 不再等于真 v1，那上面那条「执行器单元测试」测的就是**臆造的形状** ——
      // 它可能照样绿，却什么也没证明（v3 加列时就真的造错了形状）。
      final File fixture = File('test/fixtures/v1_empty.db');
      final Directory box = Directory.systemTemp.createTempSync('sz_dg_');
      addTearDown(() => deleteQuietly(box));
      final String fossilPath = '${box.path}/v1.db';
      final String downgradedPath = '${box.path}/dg.db';
      fixture.copySync(fossilPath);

      final Database raw = sqlite3.open(downgradedPath);
      for (final String sql in Schema.createStatements) {
        raw.execute(sql);
      }
      downgradeToV1(raw);
      raw.dispose();

      List<String> columnsOf(Database d, String table) => d
          .select('PRAGMA table_info($table)')
          .map((Row r) => r['name']! as String)
          .toList();
      List<String> indexesOf(Database d) => d
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name NOT LIKE 'sqlite_autoindex_%' ORDER BY name",
          )
          .map((Row r) => r['name']! as String)
          .toList();

      final Database fossil = sqlite3.open(fossilPath);
      final Database downgraded = sqlite3.open(downgradedPath);
      addTearDown(fossil.dispose);
      addTearDown(downgraded.dispose);

      for (final String table in Schema.allTables) {
        expect(
          columnsOf(downgraded, table),
          columnsOf(fossil, table),
          reason: '$table 的列（**含顺序**）必须与 v1 化石一致',
        );
      }
      expect(
        indexesOf(downgraded),
        indexesOf(fossil),
        reason: '索引也不该有差异（人工塞的 autoindex 已排除）',
      );
    });
  });
}

/// 把「当前 DDL 建出来的库」降级成 **v1 的形状** —— 供「执行器单元测试」造历史形状。
///
/// 做法：把 `migrationStep` 里**所有** `ALTER TABLE <t> ADD COLUMN <c> …` 加过的列
/// 逐个 `DROP COLUMN`。**于是加新迁移时不必回来改这个助手** —— 它跟着迁移链走
/// （v3 那次正是因为手写了一个 `DROP COLUMN`，测试报
/// `duplicate column name: package_unit`）。
///
/// ⚠️ 前提：迁移**只加列**（`Agents.md` 纪律 14/15：只增不删、语义变更视作新字段）。
/// 哪天真的出现「改类型 / 重建表」，这个助手就不够用 —— 那时应当**加新化石**，
/// 而不是继续手搓形状。
void downgradeToV1(Database raw) {
  final RegExp addColumn = RegExp(r'^ALTER TABLE (\w+) ADD COLUMN (\w+) ');
  // ⚠️ `v` 只到 `version - 1`：`migrationStep(version)` 本身会抛
  //    `MissingMigrationException`（"没有下一步"），不能拿去循环。
  for (int v = 1; v < Schema.version; v++) {
    for (final String sql in Schema.migrationStep(v)) {
      final RegExpMatch? match = addColumn.firstMatch(sql.trim());
      if (match != null) {
        raw.execute(
          'ALTER TABLE ${match.group(1)} DROP COLUMN ${match.group(2)}',
        );
      }
    }
  }
}

/// 临时目录删不掉不影响结论（Windows 上文件可能还被占用）
void deleteQuietly(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {
    // ignore
  }
}
