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
}
