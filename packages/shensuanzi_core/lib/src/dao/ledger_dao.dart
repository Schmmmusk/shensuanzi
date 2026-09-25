import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/schema.dart';
import '../models/document.dart';
import '../models/money_ledger.dart';
import '../models/party_ledger.dart';
import '../models/stock_ledger.dart';

/// 库存成本的**当前余值快照**：`Σ total_cost` 与 `Σ quantity`。
///
/// 因为 `stock_ledger` 里入库的 `total_cost` 为正、出库为负，
/// 两者相加即「当前库存的总成本」，两列数量相加即「当前库存数量」。
class StockCostSnapshot {
  const StockCostSnapshot({required this.totalCost, required this.quantity});

  final int totalCost;
  final int quantity;

  bool get isEmpty => quantity == 0;
}

/// 库存流水 DAO。**不开事务**（`Agents.md` 纪律 1）。
class StockLedgerDao {
  StockLedgerDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  void insert(StockLedger entry) {
    final Map<String, Object?> row = entry.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.stockLedger} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
  }

  /// 账面库存 = `SUM(quantity)`（`docs/data_model.md` §五 不变量 1）
  int stockOf(String productId) {
    final Row row = _raw
        .select(
          'SELECT COALESCE(SUM(quantity), 0) AS s FROM ${Schema.stockLedger} '
          'WHERE product_id = ?',
          <Object?>[productId],
        )
        .first;
    return row['s']! as int;
  }

  /// 当前库存成本余值（见 [StockCostSnapshot]）
  StockCostSnapshot costSnapshotOf(String productId) {
    final Row row = _raw
        .select(
          '''
          SELECT COALESCE(SUM(total_cost), 0) AS c,
                 COALESCE(SUM(quantity), 0)   AS q
          FROM ${Schema.stockLedger} WHERE product_id = ?
          ''',
          <Object?>[productId],
        )
        .first;
    return StockCostSnapshot(
      totalCost: row['c']! as int,
      quantity: row['q']! as int,
    );
  }

  /// 最近一次入库的 `unit_cost`（账面数量 ≤ 0 时出库/盘亏用，见 `docs/data_model.md` §六）
  int? lastInboundUnitCost(String productId) {
    final ResultSet rows = _raw.select(
      '''
      SELECT unit_cost FROM ${Schema.stockLedger}
      WHERE product_id = ? AND quantity > 0
      ORDER BY seq_no DESC LIMIT 1
      ''',
      <Object?>[productId],
    );
    if (rows.isEmpty) return null;
    return rows.first['unit_cost']! as int;
  }

  /// **某单据下某商品**的库存流水合计（带符号的原始值）。
  ///
  /// 用于退货成本分摊：取原单的成本与数量（`docs/data_model.md` §3.3）。
  /// 该单据没有此商品的流水时返回 `null`（用 `HAVING COUNT(*) > 0` 区分
  /// 「无流水」与「合计恰好为 0」）。
  StockCostSnapshot? documentProductFlow({
    required String documentId,
    required String productId,
  }) {
    final ResultSet rows = _raw.select(
      '''
      SELECT COALESCE(SUM(total_cost), 0) AS c,
             COALESCE(SUM(quantity), 0)   AS q
      FROM ${Schema.stockLedger}
      WHERE document_id = ? AND product_id = ?
      HAVING COUNT(*) > 0
      ''',
      <Object?>[documentId, productId],
    );
    if (rows.isEmpty) return null;
    final Row row = rows.first;
    return StockCostSnapshot(
      totalCost: row['c']! as int,
      quantity: row['q']! as int,
    );
  }

  /// **某原单**某商品**已被退货**的累计（带符号的原始值）。
  ///
  /// [returnType] 只统计本退货类型，因此 `sale_return` 与 `purchase_return`
  /// 的累计互不干扰。没有前序退货时返回 `(0, 0)`。
  StockCostSnapshot returnedFlow({
    required String refDocId,
    required String productId,
    required DocType returnType,
  }) {
    final Row row = _raw
        .select(
          '''
          SELECT COALESCE(SUM(sl.total_cost), 0) AS c,
                 COALESCE(SUM(sl.quantity), 0)   AS q
          FROM ${Schema.stockLedger} sl
          JOIN ${Schema.documents} d ON d.id = sl.document_id
          WHERE d.ref_doc_id = ? AND d.doc_type = ? AND sl.product_id = ?
          ''',
          <Object?>[refDocId, returnType.wire, productId],
        )
        .first;
    return StockCostSnapshot(
      totalCost: row['c']! as int,
      quantity: row['q']! as int,
    );
  }

  List<StockLedger> ofProduct(String productId) => _raw
      .select(
        'SELECT * FROM ${Schema.stockLedger} WHERE product_id = ? ORDER BY seq_no',
        <Object?>[productId],
      )
      .map(StockLedger.fromRow)
      .toList(growable: false);
}

/// 往来流水 DAO。**不开事务**（`Agents.md` 纪律 1）。
class PartyLedgerDao {
  PartyLedgerDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  void insert(PartyLedger entry) {
    final Map<String, Object?> row = entry.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.partyLedger} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
  }

  /// 往来余额 = `SUM(amount)`。**正数 = 对方欠我，负数 = 我欠对方**
  /// （`docs/data_model.md` §五 不变量 3）
  int balanceOf(String partyId) {
    final Row row = _raw
        .select(
          'SELECT COALESCE(SUM(amount), 0) AS s FROM ${Schema.partyLedger} '
          'WHERE party_id = ?',
          <Object?>[partyId],
        )
        .first;
    return row['s']! as int;
  }

  List<PartyLedger> ofParty(String partyId) => _raw
      .select(
        'SELECT * FROM ${Schema.partyLedger} WHERE party_id = ? ORDER BY seq_no',
        <Object?>[partyId],
      )
      .map(PartyLedger.fromRow)
      .toList(growable: false);
}

/// 资金流水 DAO。**不开事务**（`Agents.md` 纪律 1）。
class MoneyLedgerDao {
  MoneyLedgerDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  /// ⚠️ `entry.documentId` **必须指向 `receipt` / `payment` 单**
  /// （`Agents.md` 纪律 11）。主单直接写本表属于违约，
  /// 外键只能拦住"单据不存在"，拦不住"指向了主单"。
  void insert(MoneyLedger entry) {
    final Map<String, Object?> row = entry.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.moneyLedger} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
  }

  /// 账户余额 = `initial_balance + SUM(amount)`（`docs/data_model.md` §五 不变量）
  int balanceOf(String accountId) {
    final Row row = _raw
        .select(
          'SELECT COALESCE(SUM(amount), 0) AS s FROM ${Schema.moneyLedger} '
          'WHERE account_id = ?',
          <Object?>[accountId],
        )
        .first;
    return row['s']! as int;
  }

  List<MoneyLedger> ofAccount(String accountId) => _raw
      .select(
        'SELECT * FROM ${Schema.moneyLedger} WHERE account_id = ? ORDER BY seq_no',
        <Object?>[accountId],
      )
      .map(MoneyLedger.fromRow)
      .toList(growable: false);

  List<MoneyLedger> ofDocument(String documentId) => _raw
      .select(
        'SELECT * FROM ${Schema.moneyLedger} WHERE document_id = ? ORDER BY seq_no',
        <Object?>[documentId],
      )
      .map(MoneyLedger.fromRow)
      .toList(growable: false);
}
