// §AF-5 自检：`dart run tool/selfcheck_export_reads.dart`
//
// 与 `test/export_reads_test.dart` 断言等价（**改一边必须改另一边**）：
// 三个「导出用读取入口」不分页；商品 / 往来方导出默认**含停用**。
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**，失败可复现。
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';

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

void section(String title) => stdout.writeln('\n── $title ──');

/// 打破 200 上限需要的行数（页面默认 `limit = 200`）
const int _overCap = 201;

late Db db;
int _clock = 1700000000000;
int now() => _clock++;

void freshDb() {
  _clock = 1700000000000;
  db = Db.openInMemory();
}

void seedProducts(int count) {
  for (int i = 0; i < count; i++) {
    final int t = now();
    final String id = 'p-${i.toString().padLeft(4, '0')}';
    db.raw.execute(
      'INSERT INTO products (id, code, name, cost_price, created_at, updated_at) '
      'VALUES (?,?,?,?,?,?)',
      <Object?>[id, 'P${i.toString().padLeft(4, '0')}', '商品-$id', 0, t, t],
    );
  }
}

void seedParties(int count) {
  for (int i = 0; i < count; i++) {
    final int t = now();
    final String id = 'y-${i.toString().padLeft(4, '0')}';
    db.raw.execute(
      'INSERT INTO parties (id, name, created_at, updated_at) VALUES (?,?,?,?)',
      <Object?>[id, '往来方-$id', t, t],
    );
  }
}

void insertDocument(String id, {required String docNo, String type = 'purchase'}) {
  final int t = now();
  db.raw.execute(
    'INSERT INTO documents '
    '(id, doc_no, doc_type, status, total_amount, occurred_at, created_at, updated_at) '
    'VALUES (?,?,?,?,?,?,?,?)',
    <Object?>[id, docNo, type, 'confirmed', 0, t, t, t],
  );
}

void seedDocuments(int count) {
  for (int i = 0; i < count; i++) {
    insertDocument(
      'd-${i.toString().padLeft(4, '0')}',
      docNo: 'CG20260925-${i.toString().padLeft(3, '0')}',
    );
  }
}

void deactivate(String table, String id) => db.raw.execute(
  'UPDATE $table SET is_active = 0 WHERE id = ?',
  <Object?>[id],
);

void main() {
  useLocalSqlite();

  // ============================================================ 商品
  section('ProductDao.findAllForExport');
  {
    freshDb();
    seedProducts(_overCap);
    check(
      '超过 200 件：页面（服务层）截断在 200，导出不截断',
      ProductService(db).list().length == 200 &&
          ProductDao(db).findAllForExport().length == _overCap &&
          ProductService(db).listForExport().length == _overCap,
    );

    freshDb();
    seedProducts(3);
    deactivate('products', 'p-0000');
    check(
      '默认含停用；显式 active: true 才只看启用',
      ProductService(db).list().length == 2 &&
          ProductDao(db).findAllForExport().length == 3 &&
          ProductService(db).listForExport().length == 3 &&
          ProductService(db).listForExport(active: true).length == 2,
    );

    freshDb();
    seedProducts(3);
    check('query 过滤在导出路径上同样生效',
        ProductDao(db).findAllForExport(query: 'P0001').length == 1);
    db.close();
  }

  // ============================================================ 往来方
  section('PartyDao.findAllForExport');
  {
    freshDb();
    seedParties(_overCap);
    check(
      '超过 200 个：页面（服务层）截断在 200，导出不截断',
      PartyService(PartyDao(db)).list().length == 200 &&
          PartyDao(db).findAllForExport().length == _overCap &&
          PartyService(PartyDao(db)).listForExport().length == _overCap,
    );

    freshDb();
    seedParties(3);
    deactivate('parties', 'y-0000');
    check(
      '默认含停用（停用但还欠钱的客户必须在导出里）',
      PartyService(PartyDao(db)).list().length == 2 &&
          PartyDao(db).findAllForExport().length == 3 &&
          PartyService(PartyDao(db)).listForExport().length == 3,
    );
    db.close();
  }

  // ============================================================ 单据
  section('DocumentDao.listDocumentsForExport');
  {
    freshDb();
    seedDocuments(_overCap);
    check(
      '超过 200 张：页面截断在 200，导出不截断',
      DocumentDao(db).listDocuments().length == 200 &&
          DocumentDao(db).listDocumentsForExport().length == _overCap,
    );

    freshDb();
    seedDocuments(3);
    insertDocument('d-sale-0001', docNo: 'XS20260925-001', type: 'sale');
    check(
      'types 过滤在导出路径上同样生效',
      DocumentDao(db).listDocumentsForExport().length == 4 &&
          DocumentDao(db)
                  .listDocumentsForExport(types: <DocType>{DocType.sale})
                  .length ==
              1 &&
          DocumentDao(db)
                  .listDocumentsForExport(types: <DocType>{DocType.purchase})
                  .length ==
              3,
    );

    freshDb();
    insertDocument('d-old', docNo: 'CG20260901-001');
    final int boundary = now(); // 边界取在「老单之后、新单之前」
    seedParties(1);
    insertDocument('d-party', docNo: 'CG20260926-001');
    db.raw.execute(
      'UPDATE documents SET party_id = ? WHERE id = ?',
      <Object?>['y-0000', 'd-party'],
    );
    final List<DocumentSummary> all = DocumentDao(db).listDocumentsForExport();
    check(
      'sinceMillis 过滤 + 带回对方名（散客为 null）',
      all.length == 2 &&
          all
                  .firstWhere((DocumentSummary s) => s.document.id == 'd-party')
                  .partyName ==
              '往来方-y-0000' &&
          all
                  .firstWhere((DocumentSummary s) => s.document.id == 'd-old')
                  .partyName ==
              null &&
          DocumentDao(db).listDocumentsForExport(sinceMillis: boundary).length == 1,
    );
    db.close();
  }

  // ============================================================ 汇总
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
