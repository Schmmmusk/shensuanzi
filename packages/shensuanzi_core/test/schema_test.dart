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
  //    它用「当前 DDL 建表 + DROP COLUMN 降级」造 v1 形状 —— 测的不是历史，
  //    是执行器；与化石测试**不冲突**，两条各管一层。
  group('迁移框架', () {
    test('migrationStep(1) 恰好一条 ALTER，且点名 products 与列', () {
      final List<String> statements = Schema.migrationStep(1);
      expect(statements, hasLength(1));
      expect(
        statements.single,
        contains('ALTER TABLE products ADD COLUMN package_note'),
      );
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

    test('迁移失败后连接已关闭 → 临时目录可删（句柄不泄漏）', () {
      // 迁移失败的恢复要求连接**立即释放** —— 否则 Windows 上 .db 文件句柄
      // 被持有，用户连数据目录都删不掉（本仓自检里真实出现过）。
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

    test('迁移失败 → 库回到迁移前（仍能打开、仍是 v1），备份留着供诊断', () {
      // 构造「迁移必然失败」的库：v1 结构上**已经有 package_note 列**
      // ⇒ v1→v2 的 `ALTER TABLE ... ADD COLUMN` 报 duplicate column。
      // ⚠️ 「恢复」的完整验证需要两版迁移（部分成功后再失败）—— 当前只有
      // v1→v2 一版，故本用例覆盖的是「备份生成 + 失败后没有半升级状态」。
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
      raw.execute('ALTER TABLE products DROP COLUMN package_note');
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
      expect(
        migrated.raw
            .select("SELECT package_note FROM products WHERE id = 'p-v1'")
            .first['package_note'],
        isNull,
      );
    });
  });
}

/// 临时目录删不掉不影响结论（Windows 上文件可能还被占用）
void deleteQuietly(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {
    // ignore
  }
}
