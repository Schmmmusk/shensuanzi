// schema 结构与约束。对应 `docs/data_model.md`。
//
// ⚠️ 纯 Dart 测试需要可用的 SQLite 原生库：
//   - 非 Windows：通常能自动找到系统 sqlite3
//   - Windows：需自行提供 sqlite3.dll，或设置环境变量 SQLITE3_DLL 指向它
// 见 `tool/sqlite_local.dart`。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../tool/sqlite_local.dart';
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

  test('建出全部 11 张表', () {
    final Set<Object?> tables = objectsOfType('table');
    for (final String table in Schema.allTables) {
      expect(tables, contains(table), reason: '缺少表 $table');
    }
  });

  test('user_version 写入 Schema.version', () {
    expect(db.schemaVersion, Schema.version);
  });

  test('建出全部索引', () {
    const List<String> expected = <String>[
      'idx_products_barcode',
      'idx_parties_phone',
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
}
