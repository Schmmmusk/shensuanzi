// 镜像重建之后，**索引必须一起重建**（2026-10-26 真机 P0）。
//
// 现场：手机点「选商品」整页变错误边界，logcat 里是
//   `SqliteException(1): no such index: idx_documents_occurred`
//   ← `QueryDao.recentProducts`（`query_dao.dart:356` 的 `INDEXED BY`）
//   ← `SaleService.recentlySold` ← `_showProductPicker`
//
// 根因：`SyncClient.rebuildMirror()` 只重放**建表语句**（`_createByTable` 用正则
// `CREATE TABLE\s+(\w+)` 从 `Schema.createStatements` 里筛出来的），
// 而 `DROP TABLE` 会把该表的索引**一起删掉** ⇒ 重建后的镜像**一个索引都没有**。
// 偏偏 `recentProducts` / `recentParties` 用 `INDEXED BY`（硬提示，缺索引直接报错，
// 不是"退化到全表扫"）⇒ 客户/商品选择器必炸。
//
// ⚠️ 这条必须在修复前**红**。
import 'dart:io';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

/// 什么都不做的传输桩 —— 本测试只碰 `rebuildMirror()`，不发网络请求。
class _NoopTransport implements Transport {
  @override
  Future<TransportResponse> send(TransportRequest request) async =>
      const TransportResponse(statusCode: 200, body: '{}');
}

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_mirror_idx_');
    // 镜像库必须关 FK（见 `SyncClient` 构造的断言）
    db = Db.open(p.join(box.path, 'mirror.db'), foreignKeys: false);
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  Set<String> indexNames() => <String>{
    for (final Map<String, Object?> row in db.raw.select(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'",
    ))
      row['name']! as String,
  };

  test('rebuildMirror 之后索引必须还在（INDEXED BY 是硬提示，缺了就炸）', () {
    // 前提：新建的库索引是齐的
    expect(
      indexNames(),
      contains('idx_documents_occurred'),
      reason: '前提：Db.open 建库时索引就建好了',
    );

    SyncClient(
      db: db,
      transport: _NoopTransport(),
      baseUri: Uri.parse('http://127.0.0.1:17890'),
      token: 'tok',
    ).rebuildMirror();

    // ① 索引必须被重建出来（与 Schema.createStatements 里的索引同名）
    expect(
      indexNames(),
      contains('idx_documents_occurred'),
      reason: '重建镜像后索引没了 ⇒ 手机点「选商品」直接炸',
    );
    expect(
      indexNames(),
      contains('idx_documents_created'),
      reason: '同步游标靠它（created_at, id）',
    );

    // ② 真正会炸的那两条查询必须能跑
    expect(
      () => QueryDao(db).recentProducts(docTypes: <DocType>[DocType.sale]),
      returnsNormally,
      reason: '商品选择器的入口（INDEXED BY idx_documents_occurred）',
    );
    expect(
      () => QueryDao(db).recentParties(docTypes: <DocType>[DocType.sale]),
      returnsNormally,
      reason: '客户选择器的入口（同一个索引）',
    );
  });

  test('ensureSchemaIndexes：**已经坏了**的镜像能自愈，且幂等', () {
    // 造一个"坏镜像"：表在、索引全没了（就是现场那台手机的状态）
    for (final Map<String, Object?> row in db.raw.select(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'",
    )) {
      db.raw.execute('DROP INDEX IF EXISTS ${row['name']}');
    }
    expect(
      () => QueryDao(db).recentProducts(docTypes: <DocType>[DocType.sale]),
      throwsA(anything),
      reason: '前提：没索引时它确实会抛（不是退化到全表扫）',
    );

    ensureSchemaIndexes(db.raw);

    expect(indexNames(), contains('idx_documents_occurred'));
    expect(
      () => QueryDao(db).recentProducts(docTypes: <DocType>[DocType.sale]),
      returnsNormally,
      reason: '自愈之后商品选择器能打开',
    );
    expect(
      () => ensureSchemaIndexes(db.raw),
      returnsNormally,
      reason: '幂等：每次打开镜像都跑，不许第二次就炸',
    );
  });

  // ---------------------------------------------------------------- D-e（2026-10-26 裁定甲）
  //
  // `rebuildMirror()` 依赖**手写**的顺序常量 `SyncClient.applyOrder`：
  // 它按这个列表 drop + 重建表。现有测试只断言了**顺序**（products 在 documentLines
  // 之前），**没有断言覆盖性** —— 将来 `Schema` 加一张表、忘了登记进 `applyOrder`，
  // 重建时那张表**既不被 drop 也不被重建**，旧数据静默留在镜像里
  //（与 F19「重建不完整」同一类，而且用户永远发现不了，等发现时账已经乱了）。
  //
  // ⚠️ 这是一条**护栏**（不是复现）：当前 applyOrder 是完整的，所以它一开始就是绿的。
  // 反向灵敏度：从 applyOrder 里删掉任意一张表 ⇒ 立刻红。
  test('applyOrder 必须覆盖 Schema 里所有「随镜像重建」的表', () {
    // 从建表语句里取表名（与 `SyncClient._createByTable` 同一套正则）
    final RegExp pattern = RegExp(r'CREATE TABLE\s+(\w+)');
    final Set<String> schemaTables = <String>{
      for (final String sql in Schema.createStatements)
        if (pattern.firstMatch(sql) != null) pattern.firstMatch(sql)!.group(1)!,
    };

    // 这三张**有意**不进 applyOrder：
    // - `sync_queue`：里面是用户还没传过去的单，重建镜像绝不能丢；
    // - `sync_cursor`：重建后由 `cursors.clear()` 单独清；
    // - `clock_offset`：与主机时钟的偏差，跨重建仍有效。
    const Set<String> notRebuilt = <String>{
      'sync_queue',
      'sync_cursor',
      'clock_offset',
    };

    final Set<String> expected = schemaTables.difference(notRebuilt);
    final Set<String> registered = SyncClient.applyOrder.toSet();

    expect(
      expected.difference(registered),
      isEmpty,
      reason: 'Schema 加了表但没登记进 applyOrder ⇒ 重建镜像时它会残留旧数据',
    );
    expect(
      registered.difference(expected),
      isEmpty,
      reason: 'applyOrder 里有 Schema 中不存在的表 ⇒ 重建会直接抛错',
    );
  });
}
