import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/schema.dart';
import '../models/document.dart';

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

  Map<String, int> _keyedSum(String sql) => <String, int>{
    for (final Row row in _raw.select(sql)) row['k']! as String: row['v']! as int,
  };
}
