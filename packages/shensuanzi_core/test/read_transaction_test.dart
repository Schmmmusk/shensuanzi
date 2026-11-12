// `Db.readTransaction` —— 只读事务：多次 SELECT 看到同一快照，且**不阻塞写者**。
//
// 为什么需要它（2026-11-11 用户审查 P2）：
// 26 万单导出搬进 isolate 之后，主 isolate 可以同时处理用户操作。而
// `DocumentExportJob.load()` 内部是**多段查询**（先取单据，再取核销笔数）——
// 两段各是独立读事务，中间主库能提交新数据 ⇒ 可能导出「金额旧、核销笔数新」的行。
//
// ⚠️ 不能用现成的 `Db.transaction` 解决：它用的是 `BEGIN IMMEDIATE`（写锁），
// 导出十几秒里用户就开不了单。本文件第 2 条用例**就是钉住这个区别的**。
//
// 需要**文件库**：内存库不支持多连接共享（`file::memory:?cache=shared` 之外），
// 而本文件的核心就是「一个连接读、另一个连接写」。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Directory box;
  late String dbPath;
  late Db reader;
  late Db writer;

  int countOf(Db conn) =>
      conn.raw.select('SELECT COUNT(*) AS c FROM products').first['c']! as int;

  void insertProduct(Db conn, String id) {
    conn.raw.execute(
      'INSERT INTO products (id, code, name, unit, cost_price, sell_price, '
      'safety_stock, is_active, created_at, updated_at, sync_version) '
      "VALUES ('$id', '$id', '商品$id', '件', 0, 0, 0, 1, "
      '1700000000000, 1700000000000, 0)',
    );
  }

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_read_tx_');
    dbPath = p.join(box.path, 'shensuanzi.db');
    // 主连接建库（`Db.open` 会跑迁移链，把表建出来）
    final Db bootstrap = Db.open(dbPath);
    insertProduct(bootstrap, 'p0');
    bootstrap.close();

    // 两条独立连接，共享同一个文件（WAL 支持一写多读）
    reader = Db.open(dbPath);
    writer = Db.open(dbPath);
  });

  tearDown(() {
    reader.close();
    writer.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  test('读事务内看不到并发提交；事务结束后能看到', () {
    expect(countOf(reader), 1);

    reader.readTransaction(() {
      // 第一次读 → 确定快照
      expect(countOf(reader), 1);

      // 另一条连接写入并提交（WAL 下不被读事务阻塞）
      insertProduct(writer, 'p1');

      // ⚠️ 关键断言：同一读事务内**看不到**这条新数据
      expect(countOf(reader), 1, reason: '读事务必须钉住快照 —— 否则导出会出现「金额旧、核销笔数新」的混合行');
    });

    // 事务结束后重新读 → 新数据可见
    expect(countOf(reader), 2, reason: '事务结束后应当看到并发提交的数据');
  });

  test('读事务**不阻塞写者**（这条区分 readTransaction 与 transaction）', () {
    reader.readTransaction(() {
      expect(countOf(reader), 1); // 确定快照

      final Stopwatch watch = Stopwatch()..start();
      insertProduct(writer, 'p2');
      watch.stop();

      // `BEGIN IMMEDIATE`（Db.transaction）会让这里卡满 busy_timeout（3000 ms），
      // 然后抛「database is locked」；`BEGIN`（本方法）则应当立即完成。
      expect(
        watch.elapsedMilliseconds,
        lessThan(500),
        reason: '读事务必须不拿写锁 —— 导出 14 秒里用户还要能开单',
      );
    });
  });

  test('body 抛异常后连接仍可用（不回滚成死锁）', () {
    expect(
      () => reader.readTransaction<void>(() {
        expect(countOf(reader), 1);
        throw StateError('故意抛');
      }),
      throwsStateError,
    );
    // 异常路径已 ROLLBACK，连接应能继续用
    expect(countOf(reader), 1);
    reader.readTransaction(() => expect(countOf(reader), 1));
  });

  test('在写事务里嵌套调用不产生第二个 BEGIN（复用外层快照）', () {
    // 外层写事务：readTransaction 应该复用 `_depth`，不再发 BEGIN
    final int value = writer.transaction(() {
      insertProduct(writer, 'p3');
      return writer.readTransaction(() => countOf(writer));
    });
    // 外层事务里能读到自己刚写的（同一连接、同一事务）
    expect(value, 2);
    expect(countOf(reader), 2);
  });
}
