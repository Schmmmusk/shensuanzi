import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/read_failures.dart';
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

  /// **#27 批 2（2026-10-17 裁定）**：某商品的**人可读**库存流水 —— 照
  /// [PartyLedgerDao.ofParty] / [MoneyLedgerDao.ofAccountReadable] 先例
  /// （JOIN documents 带回单号 / 类型）。
  ///
  /// - [StockFlowEntry.quantity]：**正 = 入库，负 = 出库**（含盘点 diff）
  /// - [StockFlowEntry.totalCost]：成本真相（`docs/data_model.md` §3.3）——
  ///   **桌面显示**；手机端不显示成本（诚实口径，§CV·五十一）
  /// - #42 甲 · L1 + L2：单据类型认不出 ⇒ **跳过该行 + 计数**
  List<StockFlowEntry> ofProductReadable(String productId) {
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT sl.seq_no AS seq_no, sl.document_id AS document_id, '
      '       d.doc_no AS doc_no, d.doc_type AS doc_type, '
      '       sl.quantity AS quantity, sl.unit_cost AS unit_cost, '
      '       sl.total_cost AS total_cost, sl.occurred_at AS occurred_at, '
      '       sl.time_estimated AS time_estimated '
      'FROM ${Schema.stockLedger} sl '
      'JOIN ${Schema.documents} d ON d.id = sl.document_id '
      'WHERE sl.product_id = ? '
      'ORDER BY sl.seq_no',
      <Object?>[productId],
    );
    return decodeRows(
      rows,
      (Map<String, Object?> row) {
        final String rawType = row['doc_type']! as String;
        final DocType? type = DocType.fromWireOrNull(rawType);
        if (type == null) {
          throw RowDecodeException(
            column: 'doc_type',
            reason: '认不出的单据类型',
            value: rawType,
          );
        }
        return StockFlowEntry(
          seqNo: row['seq_no']! as int,
          documentId: row['document_id']! as String,
          docNo: row['doc_no']! as String,
          docType: type,
          quantity: row['quantity']! as int,
          unitCost: row['unit_cost']! as int,
          totalCost: row['total_cost']! as int,
          occurredAt: row['occurred_at']! as int,
          timeEstimated: (row['time_estimated']! as int) == 1,
        );
      },
      table: Schema.stockLedger,
      failures: db.readFailures,
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

  /// 某原单**已被退货的金额**（分，按商品聚合）—— Σ 此前退货**单行**的
  /// `amount`。与 [returnedFlow]（数量/成本，走 stock_ledger）**不同源**：
  /// 退款冲减的是单据金额，在 `document_lines` 上（§BH·七 B1c 的可退额度）。
  Map<String, int> returnedAmountsByProduct({
    required String refDocId,
    required DocType returnType,
  }) {
    final ResultSet rows = _raw.select(
      '''
      SELECT l.product_id AS pid, COALESCE(SUM(l.amount), 0) AS s
      FROM ${Schema.documentLines} l
      JOIN ${Schema.documents} d ON d.id = l.document_id
      WHERE d.ref_doc_id = ? AND d.doc_type = ?
      GROUP BY l.product_id
      ''',
      <Object?>[refDocId, returnType.wire],
    );
    return <String, int>{
      for (final Row row in rows) row['pid']! as String: row['s']! as int,
    };
  }

  /// #42 甲 · L1：逐行保护（商品流水）。
  List<StockLedger> ofProduct(String productId) => decodeRows(
    _raw.select(
      'SELECT * FROM ${Schema.stockLedger} WHERE product_id = ? ORDER BY seq_no',
      <Object?>[productId],
    ),
    StockLedger.fromRow,
    table: Schema.stockLedger,
    failures: db.readFailures,
  );
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

  /// 某往来方的**流水视图**（人可读版，§AA 六 / AA-6）。
  ///
  /// ⚠️ JOIN `documents` 带回 `doc_no`（单号，用户认的是它不是 UUID）与
  /// `doc_type`（区分「采购单还是收款单」）。**正数 = 对方欠我增加**。
  /// 不设平行方法 —— 裸流水若有别的需求在此方法上扩展。
  List<PartyFlowEntry> ofParty(String partyId) {
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT pl.seq_no AS seq_no, pl.document_id AS document_id, '
      '       d.doc_no AS doc_no, d.doc_type AS doc_type, '
      '       pl.amount AS amount, pl.occurred_at AS occurred_at, '
      '       pl.time_estimated AS time_estimated '
      'FROM ${Schema.partyLedger} pl '
      'JOIN ${Schema.documents} d ON d.id = pl.document_id '
      'WHERE pl.party_id = ? '
      'ORDER BY pl.seq_no',
      <Object?>[partyId],
    );
    // #42 甲 · L1 + L2：单据类型认不出 ⇒ **跳过该行 + 计数**（往来流水页不再整页变灰）
    return decodeRows(
      rows,
      (Map<String, Object?> row) {
        final String rawType = row['doc_type']! as String;
        final DocType? type = DocType.fromWireOrNull(rawType);
        if (type == null) {
          throw RowDecodeException(
            column: 'doc_type',
            reason: '认不出的单据类型',
            value: rawType,
          );
        }
        return PartyFlowEntry(
          seqNo: row['seq_no']! as int,
          documentId: row['document_id']! as String,
          docNo: row['doc_no']! as String,
          docType: type,
          amount: row['amount']! as int,
          occurredAt: row['occurred_at']! as int,
          timeEstimated: (row['time_estimated']! as int) == 1,
        );
      },
      table: Schema.partyLedger,
      failures: db.readFailures,
    );
  }
}

/// [PartyLedgerDao.ofParty] 的一行：**人可读**的往来流水
/// （单号 / 单据类型 / 金额 / 日期 —— 裸流水只有 UUID，用户认不出）。
class PartyFlowEntry {
  const PartyFlowEntry({
    required this.seqNo,
    required this.documentId,
    required this.docNo,
    required this.docType,
    required this.amount,
    required this.occurredAt,
    required this.timeEstimated,
  });

  final int seqNo;
  final String documentId;

  /// 正式单号（主机生成；用户在界面上认的是它）
  final String docNo;
  final DocType docType;

  /// 正 = 对方欠我增加，负 = 减少（`party_ledger.amount` 原口径）
  final int amount;
  final int occurredAt;
  final bool timeEstimated;
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

  /// #42 甲 · L1：逐行保护（资金流水 —— 账户页 / 详情页都不再被一条坏行带塌）。
  List<MoneyLedger> ofAccount(String accountId) => decodeRows(
    _raw.select(
      'SELECT * FROM ${Schema.moneyLedger} WHERE account_id = ? ORDER BY seq_no',
      <Object?>[accountId],
    ),
    MoneyLedger.fromRow,
    table: Schema.moneyLedger,
    failures: db.readFailures,
  );

  List<MoneyLedger> ofDocument(String documentId) => decodeRows(
    _raw.select(
      'SELECT * FROM ${Schema.moneyLedger} WHERE document_id = ? ORDER BY seq_no',
      <Object?>[documentId],
    ),
    MoneyLedger.fromRow,
    table: Schema.moneyLedger,
    failures: db.readFailures,
  );

  /// **#27（2026-10-17 裁定批 1）**：某账户的**人可读**资金流水 —— 照
  /// [PartyLedgerDao.ofParty] 先例（JOIN documents 带回单号 / 类型；
  /// 裸流水只有 UUID，用户认不出）。
  ///
  /// #42 甲 · L1 + L2：单据类型认不出 ⇒ **跳过该行 + 计数**（流水页不整页变灰）。
  List<MoneyFlowEntry> ofAccountReadable(String accountId) {
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT ml.seq_no AS seq_no, ml.document_id AS document_id, '
      '       d.doc_no AS doc_no, d.doc_type AS doc_type, '
      '       ml.amount AS amount, ml.occurred_at AS occurred_at, '
      '       ml.time_estimated AS time_estimated '
      'FROM ${Schema.moneyLedger} ml '
      'JOIN ${Schema.documents} d ON d.id = ml.document_id '
      'WHERE ml.account_id = ? '
      'ORDER BY ml.seq_no',
      <Object?>[accountId],
    );
    return decodeRows(
      rows,
      (Map<String, Object?> row) {
        final String rawType = row['doc_type']! as String;
        final DocType? type = DocType.fromWireOrNull(rawType);
        if (type == null) {
          throw RowDecodeException(
            column: 'doc_type',
            reason: '认不出的单据类型',
            value: rawType,
          );
        }
        return MoneyFlowEntry(
          seqNo: row['seq_no']! as int,
          documentId: row['document_id']! as String,
          docNo: row['doc_no']! as String,
          docType: type,
          amount: row['amount']! as int,
          occurredAt: row['occurred_at']! as int,
          timeEstimated: (row['time_estimated']! as int) == 1,
        );
      },
      table: Schema.moneyLedger,
      failures: db.readFailures,
    );
  }
}

/// [MoneyLedgerDao.ofAccountReadable] 的一行：**人可读**的账户资金流水
/// （单号 / 单据类型 / 金额 / 日期 —— 照 [PartyFlowEntry] 先例）。
class MoneyFlowEntry {
  const MoneyFlowEntry({
    required this.seqNo,
    required this.documentId,
    required this.docNo,
    required this.docType,
    required this.amount,
    required this.occurredAt,
    required this.timeEstimated,
  });

  final int seqNo;
  final String documentId;

  /// 正式单号（主机生成；用户在界面上认的是它）
  final String docNo;
  final DocType docType;

  /// 正 = 进账（余额增加），负 = 出账（`money_ledger.amount` 原口径：
  /// `balanceOf` = 期初 + SUM(amount)）
  final int amount;
  final int occurredAt;
  final bool timeEstimated;
}

/// [StockLedgerDao.ofProductReadable] 的一行：**人可读**的商品库存流水
/// （单号 / 单据类型 / ±数量 / 成本 / 日期）。
class StockFlowEntry {
  const StockFlowEntry({
    required this.seqNo,
    required this.documentId,
    required this.docNo,
    required this.docType,
    required this.quantity,
    required this.unitCost,
    required this.totalCost,
    required this.occurredAt,
    required this.timeEstimated,
  });

  final int seqNo;
  final String documentId;

  /// 正式单号（主机生成；用户在界面上认的是它）
  final String docNo;
  final DocType docType;

  /// 正 = 入库，负 = 出库（含盘点 diff —— 盘点的库存影响就是这一行）
  final int quantity;

  /// 派生展示字段 = `round_half_up(totalCost / quantity)`（`stock_ledger` 原口径）
  final int unitCost;

  /// **成本真相**（§3.3）：入库 = 数量 × 进价；出库 = 按库存总成本摊出
  final int totalCost;
  final int occurredAt;
  final bool timeEstimated;
}
