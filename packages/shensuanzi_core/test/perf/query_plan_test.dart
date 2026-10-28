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
// | stockByProduct / costByProduct / stockAggregates | **`COVERING INDEX idx_stock_covering`**（v5 起，从前是窄索引 `idx_stock_product_seq` ⇒ 每行回表） | **保持 covering** |
// | inTransitByProduct | 走两个索引 | 保持 |
// | todaySummary | 走 `idx_documents_occurred`（4c-5 修上界后） | **保持**（防退回到 type_status 全扫） |
// | partyBalances | **`COVERING INDEX idx_party_covering`**（v5 起） | **保持 covering** |
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
    // v5（2026-10-24，§CV·九十八）：索引从 `idx_stock_product_seq(product_id, seq_no)`
    // **加宽**成 `idx_stock_covering(product_id, seq_no, quantity, total_cost)`。
    // 断言从「用这条索引」收紧成「用 **COVERING** 这条索引」—— 非 covering 时
    // 37 万行每行都要回表（实测 1336 ms vs 37.6 ms，35×），只断言索引名**抓不到**
    // 「有人把索引改回两列」这种退化。
    test('stockByProduct 走 COVERING idx_stock_covering（不是全表扫）', () {
      final String p = plan(
        // query_dao.dart: stockByProduct()
        'SELECT product_id AS k, COALESCE(SUM(quantity), 0) AS v '
        'FROM stock_ledger GROUP BY product_id',
      );
      expect(
        p,
        contains('COVERING INDEX idx_stock_covering'),
        reason: '必须是覆盖索引（`quantity` 不能回表）：$p',
      );
      expect(
        p,
        isNot(contains('SCAN stock_ledger\n')),
        reason: '不许退化成无索引全表扫：$p',
      );
    });

    test('costByProduct 与账面同一条覆盖索引（同一张表同一分组键）', () {
      final String p = plan(
        // query_dao.dart: costByProduct()
        'SELECT product_id AS k, COALESCE(SUM(total_cost), 0) AS v '
        'FROM stock_ledger GROUP BY product_id',
      );
      expect(
        p,
        contains('COVERING INDEX idx_stock_covering'),
        reason: '`total_cost` 也必须在索引里：$p',
      );
    });

    test('4c-2 stockAggregates 一条 SQL 扫一次（不是三次聚合）', () {
      final String p = plan(
        // query_dao.dart: stockAggregates()
        'SELECT product_id AS k, COALESCE(SUM(quantity), 0) AS q, '
        'COALESCE(SUM(total_cost), 0) AS c, '
        'MAX(CASE WHEN quantity > 0 THEN 1 ELSE 0 END) AS inb '
        'FROM stock_ledger GROUP BY product_id',
      );
      expect(
        p,
        contains('COVERING INDEX idx_stock_covering'),
        reason: '4c-2 合并后的三列都要覆盖（否则省下的两次全扫白省）：$p',
      );
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

    test('partyBalances 走 COVERING idx_party_covering', () {
      final String p = plan(
        // query_dao.dart: partyBalances()
        'SELECT party_id AS k, COALESCE(SUM(amount), 0) AS v '
        'FROM party_ledger GROUP BY party_id',
      );
      expect(
        p,
        contains('COVERING INDEX idx_party_covering'),
        reason: 'v5：`amount` 在索引里，26 万行不再逐行回表（648 → 27.7 ms）：$p',
      );
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

    // 4c（2026-10-24，§CV·九十九）：列表页改成**两段查询**。
    // 第一段只取 id，**不许再出现 `MATERIALIZE`**（那两个派生表从前被全量物化
    // 26 万 / 10 万行，占 105 ms；现在只对 200 个 id 聚合）。
    //
    // ⚠️ 排序仍然是 `TEMP B-TREE`，这是**已知且已裁定保留**的：日桶表达式用不了
    // 索引，而「表达式索引」会绑死建库时区（提案 §1.3 已否掉）。
    test('4c 单据列表第一段：不许 MATERIALIZE（派生表留给第二段）', () {
      final String p = plan(
        // document_dao.dart: _summaries 第一段（常见路径：无「未结清」筛选）
        'SELECT d.id FROM documents d '
        'LEFT JOIN parties pa ON pa.id = d.party_id '
        'WHERE d.ref_doc_id IS NULL AND NOT ('
        "d.doc_type IN ('receipt', 'payment') AND ("
        'SELECT COUNT(DISTINCT s.target_doc_id) FROM settlements s '
        'WHERE s.receipt_doc_id = d.id AND s.target_doc_id IS NOT NULL) = 1) '
        'ORDER BY ((d.occurred_at + ?) / 86400000) DESC, d.created_at DESC LIMIT ?',
        <Object?>[28800000, 200],
      );
      expect(
        p,
        isNot(contains('MATERIALIZE')),
        reason: '第一段只取 id，带上派生表会从 124 ms 变 316 ms：$p',
      );
      expect(
        p,
        contains('idx_documents_ref'),
        reason: 'ref_doc_id IS NULL 走索引：$p',
      );
    });

    // 4c：`recentProducts` 改成「倒序走最近 N 张单，凑满即停」。
    // **必须**走 `idx_documents_occurred`；不写 `INDEXED BY` 时规划器会选
    // `idx_documents_type_status` 再排 11.2 万行（实测 122 ms，白瞎索引）。
    test('4c recentProducts 走 idx_documents_occurred（不许退成 type_status 全扫）', () {
      final String p = plan(
        // query_dao.dart: recentProducts()
        'SELECT d.id AS did, dl.product_id AS pid '
        'FROM (SELECT id, occurred_at FROM documents '
        '      INDEXED BY idx_documents_occurred '
        "      WHERE doc_type IN ('sale') "
        '      ORDER BY occurred_at DESC LIMIT ?) d '
        'JOIN document_lines dl ON dl.document_id = d.id '
        'JOIN products p ON p.id = dl.product_id '
        'WHERE p.is_active = 1 '
        'ORDER BY d.occurred_at DESC',
        <Object?>[2000],
      );
      expect(p, contains('idx_documents_occurred'), reason: p);
      expect(
        p,
        isNot(contains('idx_documents_type_status')),
        reason: '退成 type_status 会把 11.2 万张销售单全扫一遍：$p',
      );
    });

    // 2026-10-28（性能实测后修）：`countDocuments` 从前无条件复用列表的
    // 三个 join，`COUNT(*)` 用不到「退货汇总 / 核销汇总」两个派生表却把它们
    // 整表物化 —— 26 万单库上实测 **300 ms**。只带 WHERE 需要的表后 **64 ms**。
    // 这条钉住「计数不许再出现 MATERIALIZE」。
    test('计数（rootsOnly）不许物化派生表', () {
      final String p = plan(
        // document_dao.dart: countDocuments → _fromFor + _docFilter
        'SELECT COUNT(*) AS c FROM documents d '
        'WHERE d.ref_doc_id IS NULL AND NOT ('
        "d.doc_type IN ('receipt', 'payment') AND ("
        'SELECT COUNT(DISTINCT s.target_doc_id) FROM settlements s '
        'WHERE s.receipt_doc_id = d.id AND s.target_doc_id IS NOT NULL) = 1)',
      );
      expect(
        p,
        isNot(contains('MATERIALIZE')),
        reason: '计数带上派生表会从 64 ms 变 300 ms：$p',
      );
    });

    test('4c recentParties 同样走 idx_documents_occurred', () {
      final String p = plan(
        // query_dao.dart: recentParties()
        'SELECT d.id AS did, d.party_id AS pid '
        'FROM (SELECT id, party_id, occurred_at FROM documents '
        '      INDEXED BY idx_documents_occurred '
        "      WHERE doc_type IN ('sale') AND party_id IS NOT NULL "
        '      ORDER BY occurred_at DESC LIMIT ?) d '
        'JOIN parties pa ON pa.id = d.party_id '
        'WHERE pa.is_active = 1 '
        'ORDER BY d.occurred_at DESC',
        <Object?>[2000],
      );
      expect(p, contains('idx_documents_occurred'), reason: p);
    });
  });
}
