import '../dao/ledger_dao.dart';
import '../models/document.dart';
import '../util/money.dart';

/// 库存成本口径（`docs/data_model.md` §3.3 / §六）。
///
/// 核心结论：**`total_cost` 是真相，`unit_cost` 只是派生展示值。**
/// 这样出库成本精确、无累积误差，毛利 = `SUM(销售额) - SUM(出库 total_cost)` 可重放。
///
/// 提取为独立类的理由：RULE-002 / 003 / 007 / 008 / 009 都要用它，
/// 口径只允许有一处实现。
class CostPolicy {
  CostPolicy(this._stock);

  final StockLedgerDao _stock;

  /// **入库成本**：`quantity × unit_price`（精确，不涉及舍入）
  int inboundCost({required int quantity, required int unitPrice}) =>
      quantity * unitPrice;

  /// **出库成本**（也用于盘亏）。[quantity] 为**负数**。
  ///
  /// - 账面数量 > 0：时点加权平均 →
  ///   `round_half_up(库存总成本 × 出库数量 / 库存数量)`
  /// - 账面数量 ≤ 0（负库存出库）：`最近一次入库 unit_cost × 出库数量`；
  ///   无入库历史时记 0
  int outboundCost({required String productId, required int quantity}) {
    if (quantity == 0) return 0;
    final StockCostSnapshot snapshot = _stock.costSnapshotOf(productId);
    if (snapshot.quantity > 0) {
      return Money.divideRoundHalfUp(
        snapshot.totalCost * quantity,
        snapshot.quantity,
      );
    }
    return (_stock.lastInboundUnitCost(productId) ?? 0) * quantity;
  }

  /// **盘盈成本**（同入库口径，用当前加权均价）。[quantity] 为**正数**。
  ///
  /// ⚠️ 账面数量 ≤ 0 且无入库历史时，加权均价无定义，按 0 处理 ——
  /// 这是 `docs/data_model.md` 未覆盖的边界，已在 `docs/reply_review.md` R-8 记录待裁定。
  int surplusCost({required String productId, required int quantity}) {
    if (quantity == 0) return 0;
    final StockCostSnapshot snapshot = _stock.costSnapshotOf(productId);
    if (snapshot.quantity > 0) {
      final int unit = Money.divideRoundHalfUp(
        snapshot.totalCost,
        snapshot.quantity,
      );
      return unit * quantity;
    }
    return (_stock.lastInboundUnitCost(productId) ?? 0) * quantity;
  }

  /// **退货成本** —— 原单比例**精确回退**（R-11 裁定 · 方案 A）。
  ///
  /// 算法与约束见 `docs/data_model.md` §3.3「退货的成本分摊」。三个要点：
  ///
  /// 1. 分子分母都取自**原单**该商品的流水聚合，比值按**累计退货量**计算
  /// 2. 本次 = `累计分摊 − 已分摊`，**不是**「本次单独分摊」——
  ///    这样多次退货之和精确等于应分摊总额（余数由最后一次自动吸收）
  /// 3. 分子分母一律取**绝对值**，最后由 [returnType] 决定符号 ——
  ///    因为原单为 `sale` 时其流水为负、为 `purchase` 时为正，
  ///    取绝对值能让同一段代码对两者都成立（符号见 §3.3「符号约定」）
  ///
  /// [returnQuantity] 为本次退货量（**正数**）。返回值符号与 `stock_ledger.quantity`
  /// 一致：`sale_return` 为正（货回库），`purchase_return` 为负（货出库）。
  ///
  /// **累计退货量超过原单量**时抛 `StateError`（错误码 `return_exceeds_original`），
  /// 由 `RuleEngine` 捕获后整单拒绝。
  int returnCost({
    required String refDocId,
    required String productId,
    required int returnQuantity,
    required DocType returnType,
  }) {
    if (returnQuantity <= 0) {
      throw StateError('退货量必须为正数，实际 $returnQuantity');
    }

    final StockCostSnapshot? original = _stock.documentProductFlow(
      documentId: refDocId,
      productId: productId,
    );
    if (original == null) {
      throw StateError('原单 $refDocId 没有商品 $productId 的库存流水，无法分摊退货成本');
    }
    final int originalQty = original.quantity.abs();
    final int originalCost = original.totalCost.abs();
    if (originalQty == 0) {
      throw StateError('原单 $refDocId 的商品 $productId 数量为 0，无法分摊退货成本');
    }

    final StockCostSnapshot prior = _stock.returnedFlow(
      refDocId: refDocId,
      productId: productId,
      returnType: returnType,
    );
    final int priorQty = prior.quantity.abs();
    final int priorCost = prior.totalCost.abs();

    final int cumulativeQty = priorQty + returnQuantity;
    if (cumulativeQty > originalQty) {
      throw StateError(
        'return_exceeds_original: 累计退货量 $cumulativeQty 超过原单量 $originalQty'
        '（原单 $refDocId，商品 $productId）',
      );
    }

    final int cumulativeShare = Money.divideRoundHalfUp(
      originalCost * cumulativeQty,
      originalQty,
    );
    final int magnitude = cumulativeShare - priorCost;
    return returnType == DocType.saleReturn ? magnitude : -magnitude;
  }
}
