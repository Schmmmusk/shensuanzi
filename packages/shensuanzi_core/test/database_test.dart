// 连接与事务语义。核心是 **P0-1：`Db.transaction` 必须可重入** ——
// 这是审查发现的最确定缺陷（DAO 与 RuleEngine 都开事务会抛
// `cannot start a transaction within a transaction`），此处作为回归防线。
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
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

  int productCount([String? where]) => db.raw
      .select(
        'SELECT COUNT(*) AS c FROM products${where == null ? '' : ' WHERE $where'}',
      )
      .first['c']!
      as int;

  group('基础', () {
    test('file 数据库启用 WAL 并自动迁移', () {
      final Directory dir = Directory.systemTemp.createTempSync('ssz_db_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String path = '${dir.path}${Platform.pathSeparator}test.db';

      final Db fileDb = Db.open(path);
      addTearDown(fileDb.close);

      expect(fileDb.schemaVersion, Schema.version);
      expect(fileDb.raw.select('PRAGMA journal_mode').first['journal_mode'], 'wal');
      expect(File(path).existsSync(), isTrue);
    });

    test('重复打开同一个文件不会重复建表', () {
      final Directory dir = Directory.systemTemp.createTempSync('ssz_db_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String path = '${dir.path}${Platform.pathSeparator}test.db';

      Db.open(path).close();
      final Db second = Db.open(path);
      addTearDown(second.close);

      expect(second.schemaVersion, Schema.version);
      expect(
        second.raw
            .select(
              "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name=?",
              <Object?>[Schema.products],
            )
            .first['c'],
        1,
      );
    });
  });

  group('可重入事务（P0-1 回归）', () {
    test('单层事务返回 body 的值', () {
      expect(db.transaction(() => 'ok'), 'ok');
    });

    test('两层嵌套不报错，且返回最内层结果', () {
      final int result = db.transaction(() {
        insertProduct(db.raw, 'p-1');
        return db.transaction(() => 7);
      });
      expect(result, 7);
      expect(productCount(), 1);
    });

    test('三层嵌套不报错', () {
      db.transaction(() {
        insertProduct(db.raw, 'p-1');
        db.transaction(() {
          insertProduct(db.raw, 'p-2');
          db.transaction(() {
            insertProduct(db.raw, 'p-3');
          });
        });
      });
      expect(productCount(), 3);
    });

    test('嵌套期间的写入在最外层提交后可见', () {
      expect(productCount(), 0);
      db.transaction(() {
        insertProduct(db.raw, 'p-1');
        db.transaction(() => insertProduct(db.raw, 'p-2'));
      });
      expect(productCount(), 2);
    });

    test('inTransaction 正确反映嵌套深度', () {
      expect(db.inTransaction, isFalse);
      db.transaction(() {
        expect(db.inTransaction, isTrue);
        db.transaction(() {
          expect(db.inTransaction, isTrue);
        });
        expect(db.inTransaction, isTrue, reason: '内层退出后仍在外层事务中');
      });
      expect(db.inTransaction, isFalse);
    });
  });

  group('回滚', () {
    test('外层异常回滚全部写入', () {
      expect(
        () => db.transaction(() {
          insertProduct(db.raw, 'p-1');
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
      expect(productCount(), 0);
      expect(db.inTransaction, isFalse);
    });

    test('内层异常导致整单回滚（外层写入一并撤销）', () {
      expect(
        () => db.transaction(() {
          insertProduct(db.raw, 'p-outer');
          db.transaction(() {
            insertProduct(db.raw, 'p-inner');
            throw StateError('inner boom');
          });
        }),
        throwsA(isA<StateError>()),
      );
      expect(productCount(), 0, reason: '规则要求「任一失败整单回滚」');
    });

    test('内层异常可被外层捕获（捕获后事务状态由调用方负责）', () {
      db.transaction(() {
        insertProduct(db.raw, 'p-1');
        try {
          db.transaction(() {
            insertProduct(db.raw, 'p-never');
            throw StateError('caught');
          });
        } on StateError {
          // 注意：v1 不用 SAVEPOINT，内层失败不会自动回滚到内层起点 ——
          // 语义是「任一失败整单回滚」，因此捕获后是否提交由调用方决定。
          // 此处只断言异常被捕获且外层可正常收尾，不假设写入结果。
        }
      });
      expect(db.inTransaction, isFalse);
    });

    test('回滚后连接仍可继续使用', () {
      try {
        db.transaction(() => throw StateError('x'));
      } on StateError {
        // 预期
      }
      expect(() => db.transaction(() => insertProduct(db.raw, 'p-ok')), returnsNormally);
      expect(productCount(), 1);
    });
  });
}
