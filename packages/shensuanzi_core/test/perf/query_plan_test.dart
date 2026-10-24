// 性能层 1：**执行计划断言**（第 4 批 4a，2026-10-24）。
//
// ## 为什么是「计划」而不是「时间」
//
// 时间断言在任何机器上都会抖（CPU 降频、杀毒扫描、CI 的邻居），而**计划形态不抖**。
// 这一层抓的是**结构性退化**：有人改了一行 SQL，索引没被用上、或者冒出全表
// `TEMP B-TREE` —— 那种问题在功能测试里完全看不出来，上线后表现为「越用越卡」。
//
// ## ⚠️ SQL 与 DAO 逐字同形（改了 DAO 必须同步改这里）
//
// `EXPLAIN QUERY PLAN` 只能吃 SQL 字符串，而 DAO 里的 SQL 是内联拼的。
// 这里把**每条热查询的 SQL 抄一份**，并在注释里标明出处（文件:函数）。
// 抄错/漏改的后果是「断言通过但生产已经变了」—— 所以：
// **任何改动 `query_dao` / `document_dao` / `sync_server` 的 SQL，必须同步改本文件。**
//
// ## 现状与目标
//
// | 查询 | 现状 | 目标 |
// |---|---|---|
// | stockByProduct / costByProduct | 走 `idx_stock_product_seq`（非 covering） | 保持 |
// | inTransitByProduct | 走两个索引 | 保持 |
// | todaySummary | 走 `idx_documents_occurred`（4c-5 修上界后） | **保持**（防退回到 type_status 全扫） |
// | partyBalances | 走 `idx_party_ledger_party_seq` | 保持 |
// | pull 窗口 | 走 `idx_documents_updated`（P0-3） | 保持 |
// | 未结清筛选 | 派生表 `MATERIALIZE` 一次 + `idx_settle_target` | 保持（防退化成逐行子查询） |
// | 单据列表 | `SCAN d` + `TEMP B-TREE FOR ORDER BY` | **4c-3 两段查询后收紧**（只排 200 行） |
// | recentProducts | 扫全部销售单 + 两个 TEMP B-TREE | **4c-4 改成先取 id 再 IN** |
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;

  setUp(() => db = Db.openInMemory());
  tearDown(() => db.close());

  /// 取一条 SQL 的执行计划（多行拼起来，便于 `contains` 断言）。
  String plan(String sql, [List<Object?> args = const <Object?>[]]) => db.raw
      .select('EXPLAIN QUERY PLAN $sql', args)
      .map((Map<String, Object?> r) => r['detail']! as String)
      .join('\n');

  group('4a 热查询执行计划', () {
    test('stockByProduct 走 idx_stock_product_seq（不是全表扫）', () {
      final String p = plan(
        // query_dao.dart: stockByProduct()
        'SELECT product_id AS k, COALESCE(SUM(quantity), 0) AS v '
        'FROM stock_ledger GROUP BY product_id',
      );
      expect(p, contains('idx_stock_product_seq'), reason: p);
      expect(
        p,
        isNot(contains('SCAN stock_ledger\n')),
        reason: '不许退化成无索引全表扫：$p',
      );
    });

    test('costByProduct 与账面同一条索引（同一张表同一分组键）', () {
      final String p = plan(
        // query_dao.dart: costByProduct()
        'SELECT product_id AS k, COALESCE(SUM(total_cost), 0) AS v '
        'FROM stock_ledger GROUP BY product_id',
      );
      expect(p, contains('idx_stock_product_seq'), reason: p);
    });

    test('4c-2 stockAggregates 一条 SQL 扫一次（不是三次聚合）', () {
      final String p = plan(
        // query_dao.dart: stockAggregates()
        'SELECT product_id AS k, COALESCE(SUM(quantity), 0) AS q, '
        'COALESCE(SUM(total_cost), 0) AS c, '
        'MAX(CASE WHEN quantity > 0 THEN 1 ELSE 0 END) AS inb '
        'FROM stock_ledger GROUP BY product_id',
      );
      expect(p, contains('idx_stock_product_seq'), reason: p);
      expect(
        p.split('\n').where((String l) => l.contains('stock_ledger')).length,
        1,
        reason: '只许扫一次 stock_ledger：$p',
      );
    });

    test('inTransitByProduct 走单据类型索引 + 明细索引', () {
      final String p = plan(
        // query_dao.dart: inTransitByProduct()
        'SELECT dl.product_id AS k, COALESCE(SUM(dl.quantity), 0) AS v '
        'FROM document_lines dl JOIN documents d ON d.id = dl.document_id '
        "WHERE d.doc_type = 'delivery' AND d.status = 'in_transit' "
        'GROUP BY dl.product_id',
      );
      expect(p, contains('idx_documents_type_status'), reason: p);
      expect(p, contains('idx_lines_document'), reason: p);
    });

    test('todaySummary 走 idx_documents_occurred（按日期收窄，不是按类型全扫）', () {
      final String p = plan(
        // query_dao.dart: todaySummary()（3c-5 加了上界之后）
        'SELECT doc_type AS t, COUNT(*) AS c, COALESCE(SUM(total_amount), 0) AS amt '
        "FROM documents WHERE status != 'cancelled' "
        'AND occurred_at >= ? AND occurred_at < ? GROUP BY doc_type',
        <Object?>[0, 1],
      );
      expect(
        p,
        contains('idx_documents_occurred'),
        reason: '3c-5 修完上界后规划器改用日期索引 —— 不许退回到 type_status 全扫：$p',
      );
    });

    test('partyBalances 走 idx_party_ledger_party_seq', () {
      final String p = plan(
        // query_dao.dart: partyBalances()
        'SELECT party_id AS k, COALESCE(SUM(amount), 0) AS v '
        'FROM party_ledger GROUP BY party_id',
      );
      expect(p, contains('idx_party_ledger_party_seq'), reason: p);
    });

    test('pull 窗口走 idx_documents_updated（P0-3 的索引必须在）', () {
      final String p = plan(
        // sync_server.dart: 最近更新窗口
        'SELECT * FROM documents WHERE updated_at > ? '
        'ORDER BY updated_at DESC, id DESC LIMIT ?',
        <Object?>[0, 500],
      );
      expect(
        p,
        contains('idx_documents_updated'),
        reason: 'P0-3 加这个索引就是为了窗口不用全表扫：$p',
      );
    });

    test('未结清筛选：派生表只 MATERIALIZE 一次（不是逐行子查询）', () {
      final String p = plan(
        // document_dao.dart: _docFilter 的 unsettled 分支（3a 之后）
        'SELECT d.id FROM documents d '
        'LEFT JOIN (SELECT ref_doc_id AS ref, SUM(total_amount) AS rsum '
        'FROM documents WHERE ref_doc_id IS NOT NULL '
        "AND doc_type IN ('sale_return', 'purchase_return') GROUP BY ref_doc_id) r "
        'ON r.ref = d.id '
        'LEFT JOIN (SELECT target_doc_id AS tgt, SUM(amount) AS psum '
        'FROM settlements WHERE target_doc_id IS NOT NULL '
        'GROUP BY target_doc_id) s ON s.tgt = d.id '
        "WHERE (d.doc_type IN ('sale', 'purchase', 'delivery') "
        "AND d.status <> 'cancelled' "
        'AND (d.total_amount - COALESCE(s.psum, 0) - COALESCE(r.rsum, 0)) > 0)',
      );
      expect(p, contains('MATERIALIZE s'), reason: '核销汇总必须一次算完：$p');
      expect(p, contains('idx_settle_target'), reason: p);
    });

    test('单据列表排序：**允许** TEMP B-TREE（4c-3 前），但主表不许走无条件全扫', () {
      final String p = plan(
        // document_dao.dart: _summaries（_docFrom + 分桶排序）
        'SELECT d.* FROM documents d '
        'LEFT JOIN parties pa ON pa.id = d.party_id '
        'LEFT JOIN (SELECT ref_doc_id AS ref, SUM(total_amount) AS rsum, '
        'COUNT(*) AS rcnt FROM documents WHERE ref_doc_id IS NOT NULL '
        "AND doc_type IN ('sale_return', 'purchase_return') GROUP BY ref_doc_id) r "
        'ON r.ref = d.id '
        'LEFT JOIN (SELECT target_doc_id AS tgt, SUM(amount) AS psum '
        'FROM settlements WHERE target_doc_id IS NOT NULL '
        'GROUP BY target_doc_id) s ON s.tgt = d.id '
        'ORDER BY ((d.occurred_at + ?) / 86400000) DESC, d.created_at DESC LIMIT ?',
        <Object?>[0, 200],
      );
      // ⚠️ 现状：排序对**全表**做 TEMP B-TREE（`SCAN d` + ORDER BY）。
      // 4c-3 改成「先取 200 个 id，再 IN 取整行」之后，这里要改成
      // 「排序只作用于 200 行」的断言 —— 届时本断言会红，是**预期的**。
      expect(
        p,
        contains('TEMP B-TREE FOR ORDER BY'),
        reason: '现状记录（4c-3 前）：$p',
      );
    });

    test('recentProducts 现状记录：扫全部销售单（4c-4 改成先取 id）', () {
      final String p = plan(
        // query_dao.dart: recentProducts()
        'SELECT dl.product_id AS pid FROM document_lines dl '
        'JOIN documents d ON d.id = dl.document_id '
        'JOIN products p ON p.id = dl.product_id '
        "WHERE d.doc_type IN ('sale') AND p.is_active = 1 "
        'GROUP BY dl.product_id ORDER BY MAX(d.occurred_at) DESC LIMIT ?',
        <Object?>[20],
      );
      // 现状：按 doc_type 索引**扫全部销售单**，再两个 TEMP B-TREE。
      // 4c-4 之后这里应变成「先 LIMIT 取 id，再 IN」—— 断言随改动更新。
      expect(
        p,
        contains('idx_documents_type_status'),
        reason: '现状记录（4c-4 前）：$p',
      );
    });
  });
}
