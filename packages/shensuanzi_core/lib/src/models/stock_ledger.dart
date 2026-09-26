import '../db/schema.dart';
import '../util/money.dart';
import 'base.dart';

/// 库存流水（业务数据，**不可变**）
///
/// ## 成本口径（`docs/data_model.md` §3.3 / §六）
///
/// - [totalCost] 是**成本真相**（精确，无累积误差）
/// - [unitCost] 是**派生展示字段** = `round_half_up(totalCost / quantity)`
/// - `totalCost` 取值：入库 = `quantity × unit_price`；出库 = `round_half_up(库存总成本 × 出库数量 / 库存数量)`
/// - 毛利 = `SUM(销售额) - SUM(出库 totalCost)`
///
/// ## seq_no
///
/// **每表独立单调递增**，由主机在事务内分配（`Agents.md` 纪律 5）。
/// 客户端**不持久化、不引用**它。
class StockLedger extends ImmutableEntity {
  const StockLedger({
    required this.id,
    required this.productId,
    required this.documentId,
    required this.quantity,
    required this.totalCost,
    required this.seqNo,
    required this.occurredAt,
    this.timeEstimated = false,
    required this.createdAt,
    this.unitCost,
  });

  factory StockLedger.fromRow(Map<String, Object?> row) => StockLedger(
    id: row.requiredString('id'),
    productId: row.requiredString('product_id'),
    documentId: row.requiredString('document_id'),
    quantity: row.requiredInt('quantity'),
    unitCost: row.requiredInt('unit_cost'),
    totalCost: row.requiredInt('total_cost'),
    seqNo: row.requiredInt('seq_no'),
    occurredAt: row.requiredInt('occurred_at'),
    timeEstimated: row.requiredBool('time_estimated'),
    createdAt: row.requiredInt('created_at'),
  );

  static const String table = Schema.stockLedger;

  @override
  final String id;
  final String productId;
  final String documentId;

  /// 正数入库，负数出库
  final int quantity;

  /// 派生展示值。构造时省略则按 [totalCost] / [quantity] 计算。
  final int? unitCost;

  /// 精确成本（分）—— **真相**
  final int totalCost;
  final int seqNo;
  final int occurredAt;
  final bool timeEstimated;
  final int createdAt;

  /// 实际落库的 `unit_cost`
  int get unitCostValue =>
      unitCost ?? (quantity == 0 ? 0 : Money.divideRoundHalfUp(totalCost, quantity));

  @override
  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'product_id': productId,
    'document_id': documentId,
    'quantity': quantity,
    'unit_cost': unitCostValue,
    'total_cost': totalCost,
    'seq_no': seqNo,
    'occurred_at': occurredAt,
    'time_estimated': boolToInt(timeEstimated),
    'created_at': createdAt,
  };
}
