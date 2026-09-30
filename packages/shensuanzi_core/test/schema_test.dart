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

  // ============================================================ 迁移（v1 → v2）
  //
  // §AJ·AI-5：schema 升 2（products 加 package_note）。迁移测试**必须造一个
  // 真的 v1 老库**走 `Db.open` 全流程，只测 `migrationStatements` 返回什么
  // 字符串是虚假的安全感（写错表名 / 忘了执行都测不出来）。
  group('迁移（v1 → v2：products 补 package_note）', () {
    test('migrationStatements(1) 恰好一条 ALTER，且点名 products 与列', () {
      final List<String> statements = Schema.migrationStatements(1);
      expect(statements, hasLength(1));
      expect(
        statements.single,
        contains('ALTER TABLE products ADD COLUMN package_note'),
      );
    });

    test('已是最新版 → 没有迁移语句（重复打开不重复改表）', () {
      expect(Schema.migrationStatements(Schema.version), isEmpty);
    });

    test('新库直接含 package_note 列（不用迁移）', () {
      final List<String> columns = db.raw
          .select('PRAGMA table_info(products)')
          .map((Row r) => r['name']! as String)
          .toList();
      expect(columns, contains('package_note'));
    });

    test('v1 老库经 Db.open 自动升到 v2：老行 package_note 为 NULL，且可补写', () {
      final Directory box = Directory.systemTemp.createTempSync(
        'shensuanzi_schema_v1_',
      );
      addTearDown(() {
        try {
          box.deleteSync(recursive: true);
        } catch (_) {
          // 删不掉不影响结论
        }
      });
      final String path = '${box.path}/v1.db';

      // ---- 造一个 v1 老库：用当前 DDL 建表后**降级** —— 删掉 package_note、
      // 版本号写回 1。这样 v1 的表形状永远跟着当前 DDL 走，不会漂移。
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

      // ---- 用正常入口打开：应自动走 migrationStatements(1) 并升到 v2
      final Db migrated = Db.open(path);
      addTearDown(migrated.close);

      expect(migrated.schemaVersion, Schema.version);
      final Map<String, Object?> row = migrated.raw
          .select("SELECT package_note FROM products WHERE id = 'p-v1'")
          .first;
      expect(
        row['package_note'],
        isNull,
        reason: 'ALTER ADD COLUMN 对已有行自动取 NULL，不需要回填',
      );

      // ---- 老行补写备注也能存能读（列是活的，不是摆设）
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
  });
}
