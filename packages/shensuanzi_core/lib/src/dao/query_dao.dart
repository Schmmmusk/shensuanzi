import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/schema.dart';
import '../models/document.dart';
import '../models/party.dart';
import '../models/product.dart';
import 'party_dao.dart';
import 'product_dao.dart';

/// **RULE-006 库存 / 余额查询**（`docs/rules.md`）。
///
/// 全是聚合读：**不开事务、不改任何数据**（`Agents.md` 纪律 1）。
///
/// 「真相」口径见 `docs/data_model.md` §五 —— 本类不维护任何余额表，
/// 每次都从流水算：
///
/// - 库存 = `SUM(stock_ledger.quantity)`
/// - 资金 = `accounts.initial_balance + SUM(money_ledger.amount)`
/// - 往来 = `SUM(party_ledger.amount)`（**正 = 应收，负 = 应付**）
///
/// 返回**批量映射**而不是逐条查询：列表页一次拿全，
/// 逐条查会退化成 N+1。
class QueryDao {
  QueryDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  /// 每个商品的**账面库存**。
  ///
  /// 只包含有流水的商品 —— 从没进过货的商品不会出现在结果里
  /// （消费端用 `map[id] ?? 0` 取值）。
  Map<String, int> stockByProduct() => _keyedSum(
    'SELECT product_id AS k, COALESCE(SUM(quantity), 0) AS v '
    'FROM ${Schema.stockLedger} GROUP BY product_id',
  );

  /// 每个商品的**库存成本余值**（历史加权平均口径，R-9）。
  ///
  /// ⚠️ 语义：这是「按历史加权平均成本算的剩余存货价值」，
  /// **不是「最近一次进价 × 数量」** —— 进价变过时两者不同，
  /// UI 必须标明口径（§AA 四 / AA-4）。超卖时余值为**负**（R-9）。
  /// 与 [stockByProduct] 同形状：只含有流水的商品，消费端 `?? 0`。
  Map<String, int> costByProduct() => _keyedSum(
    'SELECT product_id AS k, COALESCE(SUM(total_cost), 0) AS v '
    'FROM ${Schema.stockLedger} GROUP BY product_id',
  );

  /// **在途数量**：送货单里 `status = in_transit` 的未签收数量
  /// （`docs/rules.md` RULE-003 的在途视图）。
  Map<String, int> inTransitByProduct() => _keyedSum(
    'SELECT dl.product_id AS k, COALESCE(SUM(dl.quantity), 0) AS v '
    'FROM ${Schema.documentLines} dl '
    'JOIN ${Schema.documents} d ON d.id = dl.document_id '
    "WHERE d.doc_type = '${DocType.delivery.wire}' "
    "  AND d.status = '${DocStatus.inTransit.wire}' "
    'GROUP BY dl.product_id',
  );

  /// **在店可售** = 账面库存 − 在途数量。
  ///
  /// 送货单创建时货已离店（账面已扣），所以在店可售要再减掉在途。
  /// **低库存告警必须用这个，不能用账面库存。**
  Map<String, int> availableInStore() {
    final Map<String, int> book = stockByProduct();
    for (final MapEntry<String, int> entry in inTransitByProduct().entries) {
      book[entry.key] = (book[entry.key] ?? 0) - entry.value;
    }
    return book;
  }

  /// 账户余额 = `initial_balance + SUM(money_ledger.amount)`。
  ///
  /// **含所有账户**（包括一条流水都没有的），所以是 LEFT JOIN。
  Map<String, int> accountBalances() => _keyedSum(
    'SELECT a.id AS k, a.initial_balance + COALESCE(SUM(m.amount), 0) AS v '
    'FROM ${Schema.accounts} a '
    'LEFT JOIN ${Schema.moneyLedger} m ON m.account_id = a.id '
    'GROUP BY a.id',
  );

  /// 往来余额。正 = 对方欠我（应收），负 = 我欠对方（应付）。
  Map<String, int> partyBalances() => _keyedSum(
    'SELECT party_id AS k, COALESCE(SUM(amount), 0) AS v '
    'FROM ${Schema.partyLedger} GROUP BY party_id',
  );

  /// 是否存在任何单据（§AE 遗漏 1：空库跳过**自动**备份的判定 ——
  /// 刚建好数据目录还没录东西时，不该生成一份份相同的空库备份；
  /// 「手动立即备份」不受此限制，那是用户的主动意图）。
  bool hasAnyDocument() => _raw
      .select('SELECT 1 FROM ${Schema.documents} LIMIT 1')
      .isNotEmpty;

  /// 是否存在**任何**库存流水（§AD 遗漏 2）。
  ///
  /// 库存页据此区分入口文案：`false` = 首次 →「录入现有货物」；
  /// `true` = 再次 →「重新清点」。一次 EXISTS 查询，O(1) 级别。
  bool hasAnyStockLedger() => _raw
      .select('SELECT 1 FROM ${Schema.stockLedger} LIMIT 1')
      .isNotEmpty;

  /// 发生过**正数量入库**（数量 > 0 的流水）的商品集合（§AD 遗漏 1）。
  ///
  /// 库存页成本列的三态判断：
  /// - 商品不在集合里 → **从未入库** →「未进货」
  /// - 在集合里且 [costByProduct] 余值为 0 → 期初录入过、成本未校准 →「待校准」
  /// - 在集合里且余值 ≠ 0 → 正常显示金额
  ///
  /// 「数量 > 0」涵盖采购入库与盘盈（RULE-009 的 diff > 0）——
  /// 两者都意味着「这个商品真实进过货」，成本口径有意义。
  Set<String> inboundProductIds() => <String>{
    for (final Row row in _raw.select(
      'SELECT DISTINCT product_id AS k '
      'FROM ${Schema.stockLedger} WHERE quantity > 0',
    ))
      row['k']! as String,
  };

  Map<String, int> _keyedSum(String sql) => <String, int>{
    for (final Row row in _raw.select(sql)) row['k']! as String: row['v']! as int,
  };

  /// 最近**交易过**的商品（选择器空查询时显示的「最近使用」）。
  ///
  /// [docTypes] 决定哪些单据算「交易过」：采购页传 `[purchase]`、
  /// 销售页传 `[sale]` —— **一处 SQL 两处共用**（`docs/reply_review.md` §Z 五），
  /// 不为采购/销售各写一个平行方法。
  ///
  /// 只含**启用中**的商品，按最近一次交易时间倒序；没有任何历史时返回空列表
  /// （界面退化为纯搜索）。个体工商户大部分单据是重复进货/出货 ——
  /// 打开选择器就能点到常买的货，不用每次敲搜索词。
  List<Product> recentProducts({
    required List<DocType> docTypes,
    int limit = 20,
  }) {
    if (docTypes.isEmpty) return const <Product>[];
    final String placeholders = List<String>.filled(docTypes.length, '?').join(',');
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT dl.product_id AS pid '
      'FROM ${Schema.documentLines} dl '
      'JOIN ${Schema.documents} d ON d.id = dl.document_id '
      'JOIN ${Schema.products} p ON p.id = dl.product_id '
      'WHERE d.doc_type IN ($placeholders) AND p.is_active = 1 '
      'GROUP BY dl.product_id '
      'ORDER BY MAX(d.occurred_at) DESC '
      'LIMIT ?',
      <Object?>[...docTypes.map((DocType t) => t.wire), limit],
    );
    final ProductDao products = ProductDao(db);
    final List<Product> result = <Product>[];
    for (final Map<String, Object?> row in rows) {
      final Product? product = products.findById(row['pid']! as String);
      if (product != null) result.add(product);
    }
    return result;
  }

  /// 最近**交易过**的往来方（客户/供应商选择器空查询时显示的「最近往来」，
  /// §Z 遗漏 3 —— 客户群稳定，一开店就能点到常客）。
  ///
  /// 语义与 [recentProducts] 完全对称：[docTypes] 决定哪些单据算「交易过」，
  /// 只含**启用中**的往来方，按最近一次交易时间倒序；没有历史返回空列表。
  /// 无往来的单据（散客/散采）`party_id` 为空，天然被排除。
  List<Party> recentParties({
    required List<DocType> docTypes,
    int limit = 20,
  }) {
    if (docTypes.isEmpty) return const <Party>[];
    final String placeholders = List<String>.filled(docTypes.length, '?').join(',');
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT d.party_id AS pid '
      'FROM ${Schema.documents} d '
      'JOIN ${Schema.parties} pa ON pa.id = d.party_id '
      'WHERE d.doc_type IN ($placeholders) AND d.party_id IS NOT NULL '
      '  AND pa.is_active = 1 '
      'GROUP BY d.party_id '
      'ORDER BY MAX(d.occurred_at) DESC '
      'LIMIT ?',
      <Object?>[...docTypes.map((DocType t) => t.wire), limit],
    );
    final PartyDao parties = PartyDao(db);
    final List<Party> result = <Party>[];
    for (final Map<String, Object?> row in rows) {
      final Party? party = parties.findById(row['pid']! as String);
      if (party != null) result.add(party);
    }
    return result;
  }
}
