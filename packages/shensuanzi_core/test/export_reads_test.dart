// §AF-5：**导出用读取入口**不分页（页面列表仍保留 200 上限）。
//
// ## 为什么值得单独一套断言
//
// 导出跟着 200 上限走会造成**静默截断**：一年几千张单的店点「导出」，
// 只拿到最近 200 条，而且**文件里看不出被截断** —— 用户拿去给会计，
// 就会漏账。这是本项目最危险的一类 bug（错得没有声音）。
//
// 三个入口：`DocumentDao.listDocumentsForExport` /
// `ProductDao.findAllForExport` / `PartyDao.findAllForExport`。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；Windows 需要可用的 SQLite 原生库
// （见 `lib/sqlite_local.dart`）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

import 'package:shensuanzi_core/sqlite_local.dart';
import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  /// 打破 200 上限需要的行数（页面默认 `limit = 200`）
  const int overCap = 201;

  late Db db;

  setUp(() {
    resetClock();
    db = newMemoryDb();
  });

  tearDown(() => db.close());

  /// 造 [count] 件商品（`code` / `name` 由夹具按 id 保证唯一）
  void seedProducts(int count) {
    for (int i = 0; i < count; i++) {
      final String id = 'p-${i.toString().padLeft(4, '0')}';
      insertProduct(db.raw, id, code: 'P${i.toString().padLeft(4, '0')}');
    }
  }

  void seedParties(int count) {
    for (int i = 0; i < count; i++) {
      insertParty(db.raw, 'y-${i.toString().padLeft(4, '0')}');
    }
  }

  void seedDocuments(int count) {
    for (int i = 0; i < count; i++) {
      insertDocument(
        db.raw,
        'd-${i.toString().padLeft(4, '0')}',
        docNo: 'CG20260925-${i.toString().padLeft(3, '0')}',
      );
    }
  }

  void deactivate(String table, String id) => db.raw.execute(
    'UPDATE $table SET is_active = 0 WHERE id = ?',
    <Object?>[id],
  );

  // ============================================================ 商品

  group('ProductDao.findAllForExport', () {
    test('超过 200 件：页面列表截断，导出不截断（AF-5）', () {
      seedProducts(overCap);

      expect(
        ProductService(db).list().length,
        200,
        reason: '页面（服务层）仍是 200 —— 本批不动它（不回归）',
      );
      expect(ProductDao(db).findAllForExport().length, overCap);
      expect(
        ProductService(db).listForExport().length,
        overCap,
        reason: '页面拿的是服务层，导出入口也得在服务层给到',
      );
    });

    test('默认含停用；显式 active: true 才只看启用（AF-12）', () {
      seedProducts(3);
      deactivate('products', 'p-0000');

      expect(ProductService(db).list().length, 2, reason: '页面默认只看启用');
      expect(
        ProductDao(db).findAllForExport().length,
        3,
        reason: '「带走数据」不该偷偷少东西（导出入口默认 active = null）',
      );
      expect(ProductService(db).listForExport().length, 3);
      expect(ProductService(db).listForExport(active: true).length, 2);
    });

    test('query 过滤在导出路径上同样生效', () {
      seedProducts(3);
      expect(ProductDao(db).findAllForExport(query: 'P0001').length, 1);
    });
  });

  // ============================================================ 往来方

  group('PartyDao.findAllForExport', () {
    test('超过 200 个：导出不截断（AF-5）', () {
      seedParties(overCap);

      expect(PartyService(PartyDao(db)).list().length, 200);
      expect(PartyDao(db).findAllForExport().length, overCap);
      expect(PartyService(PartyDao(db)).listForExport().length, overCap);
    });

    test('默认含停用 —— 停用但还欠钱的客户必须在导出里', () {
      seedParties(3);
      deactivate('parties', 'y-0000');

      expect(PartyService(PartyDao(db)).list().length, 2, reason: '页面默认只看启用');
      expect(
        PartyDao(db).findAllForExport().length,
        3,
        reason: '否则会计对不上这笔应收',
      );
      expect(PartyService(PartyDao(db)).listForExport().length, 3);
    });
  });

  // ============================================================ 单据

  group('DocumentDao.listDocumentsForExport', () {
    test('超过 200 张：导出不截断（AF-5）', () {
      seedDocuments(overCap);

      expect(DocumentDao(db).listDocuments().length, 200);
      expect(DocumentDao(db).listDocumentsForExport().length, overCap);
    });

    test('type 过滤在导出路径上同样生效', () {
      seedDocuments(3);
      insertDocument(
        db.raw,
        'd-sale-0001',
        docNo: 'XS20260925-001',
        docType: 'sale',
      );

      expect(DocumentDao(db).listDocumentsForExport().length, 4);
      expect(
        DocumentDao(db).listDocumentsForExport(type: DocType.sale).length,
        1,
      );
      expect(
        DocumentDao(db).listDocumentsForExport(type: DocType.purchase).length,
        3,
      );
    });

    test('sinceMillis 过滤 + 带回对方名（散客为 null）', () {
      insertDocument(db.raw, 'd-old', docNo: 'CG20260901-001');
      // 边界取在「老单之后、新单之前」（`now()` 每次调用都 +1，单调可复现）
      final int boundary = now();
      insertParty(db.raw, partyId);
      insertDocument(db.raw, 'd-party', docNo: 'CG20260926-001');
      db.raw.execute(
        'UPDATE documents SET party_id = ? WHERE id = ?',
        <Object?>[partyId, 'd-party'],
      );

      final List<DocumentSummary> all = DocumentDao(db).listDocumentsForExport();
      expect(all, hasLength(2));
      expect(
        all
            .firstWhere((DocumentSummary s) => s.document.id == 'd-party')
            .partyName,
        '往来方-$partyId',
      );
      expect(
        all.firstWhere((DocumentSummary s) => s.document.id == 'd-old').partyName,
        isNull,
        reason: '散客 / 散采无对方 —— UI 与导出都要显示文字（AF-9）',
      );
      expect(
        DocumentDao(db).listDocumentsForExport(sinceMillis: boundary),
        hasLength(1),
        reason: '跟随页面 chips 的时间过滤，只是不设上限',
      );
    });
  });
}
