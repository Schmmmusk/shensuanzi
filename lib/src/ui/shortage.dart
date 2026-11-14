/// 缺货榜的计算（提案 61 —— `docs/proposals/61-缺货榜-落地方案.md`）。
///
/// ## 这个文件为什么存在（而不是写在页面里）
///
/// 缺货榜的判定有四条容易写错的边界，全部在**纯 Dart**里，可以脱离 Flutter 单测：
///
/// | 规则 | 写错的后果 |
/// |---|---|
/// | 用「在店可售」（`effectiveInStoreOf`），不用账面 | 在途 100、账面 0 的商品库存页报橙、榜里没有 |
/// | **超卖与安全库存解耦**（在店可售 < 0 一律进超卖段） | 「没设安全库存但已卖穿」的最严重异常看不见 |
/// | `gapQty = max(0, safety − inStore)` | 超卖时按「补回 0」算钱，少算一半 |
/// | 金额用 `products.cost_price`（参考进价），不用流水均价 | 无货/超卖时均价除零或为负 |
///
/// ## 不新增 SQL
///
/// 候选集是**全量商品**，与 `stockAggregates()` / `inTransitByProduct()` /
/// `StockDelta.unsyncedDelta()` 这三个 `Map<productId, …>` 在 Dart 里 join
/// （缺失键按 0 = 等价 `LEFT JOIN`）。`stockTop` 的 `INNER JOIN` **不能复用** ——
/// 它会把「从没进过货但设了安全库存」的商品整类丢掉（提案 §三 洞 1）。
library;

import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 缺货榜的一行（**派生视图行**，不是查询模型 —— 提案 §五 取消 `ShortageCandidate`）。
class ShortageRow {
  const ShortageRow({
    required this.product,
    required this.inStore,
    required this.gapQty,
    required this.everInbound,
  });

  final Product product;

  /// 在店可售（`effectiveInStoreOf`：账面 + 未同步 − 在途）。
  ///
  /// 超卖段里显示的就是它（**负数** —— 告诉用户已经卖穿多少）。
  final int inStore;

  /// 缺口件数 = `max(0, 安全库存 − 在店可售)`。
  ///
  /// ⚠️ **不是** `max(0, −inStore)`：超卖时要补到安全库存，不是补回 0。
  /// 安全库存 5、在店可售 −3 ⇒ 缺口 8（补 3 件只到 0）。
  final int gapQty;

  /// 是否**发生过正数量入库**（`StockAgg.hasInbound`）。
  ///
  /// ⚠️ 不等于「有没有流水」：只有过一笔出库的（含超卖）算「从没进过货」。
  final bool everInbound;

  String get id => product.id;
  String get name => product.name;
  String get unit => product.unit;

  /// 参考进价是否没填（`cost_price == 0`）⇒ 只报件数、不进金额排序。
  bool get priceUnset => product.costPrice == 0;

  /// 预计补货金额（分）= 缺口 × 参考进价。`priceUnset` 时为 0（且不参与排序）。
  int get gapCents => priceUnset ? 0 : gapQty * product.costPrice;

  /// 缺口为 0（刚好等于安全库存，边界 `≤`）—— 只提示、不报金额。
  bool get gapIsZero => gapQty == 0;
}

/// 缺货榜一次算好的全部结果。
class ShortageSummary {
  const ShortageSummary({
    required this.oversold,
    required this.restock,
    required this.oversoldCount,
    required this.restockCount,
    required this.activeCount,
    required this.unsetSafetyCount,
    required this.priceUnsetCount,
    required this.neverInboundCount,
    required this.limit,
  });

  /// 没设安全库存、也没有商品时的空结果（整张卡不显示）。
  static const ShortageSummary none = ShortageSummary(
    oversold: <ShortageRow>[],
    restock: <ShortageRow>[],
    oversoldCount: 0,
    restockCount: 0,
    activeCount: 0,
    unsetSafetyCount: 0,
    priceUnsetCount: 0,
    neverInboundCount: 0,
    limit: 0,
  );

  /// **已超卖**段（在店可售 < 0，红色置顶）。已按金额降序，截断到 [limit]。
  final List<ShortageRow> oversold;

  /// **该补货**段（`0 ≤ 在店可售 ≤ 安全库存` 且安全库存 > 0）。同样截断。
  final List<ShortageRow> restock;

  /// 超卖段的**全量**条数（[oversold] 被截断时它仍然准确）。
  final int oversoldCount;

  /// 该补货段的全量条数。
  final int restockCount;

  /// 启用中的商品总数（引导卡判据的分母）。
  final int activeCount;

  /// `safety_stock == 0` 的商品数（**从全量商品数**，不从筛选后的子集猜）。
  final int unsetSafetyCount;

  /// 缺货/超卖商品里「参考进价没填」的个数（只报件数，不进金额榜）。
  final int priceUnsetCount;

  /// 缺货/超卖商品里「从没进过货」的个数（与「待校准」不是一回事）。
  final int neverInboundCount;

  /// 本结果每段保留的行数上限（用于 [limitTo] 重算；0 = 空结果）。
  final int limit;

  /// 有商品缺货（任一一段非空）。
  bool get hasAny => oversoldCount > 0 || restockCount > 0;

  /// **所有启用商品都没设安全库存** ⇒ 出引导卡（决策 4 乙）。
  ///
  /// 判定规则刻意写成「全部都没设」：只要有一个设了，就正常出榜 ——
  /// 哪怕榜是空的，那是「设了但都还够」的好消息，不该被引导卡盖掉。
  bool get showGuide => activeCount > 0 && unsetSafetyCount == activeCount;

  /// 整张卡是否有话可说（没有商品 ⇒ 不显示）。
  bool get isVisible => activeCount > 0;

  /// 两段合计（未截断）。
  int get totalCount => oversoldCount + restockCount;

  /// 概览页只显示前 N 行：**只截行，不动计数**（「查看全部 N 个」要用真数）。
  ShortageSummary limitTo(int maxRowsPerSection) {
    if (maxRowsPerSection >= limit) return this;
    return ShortageSummary(
      oversold: oversold.take(maxRowsPerSection).toList(growable: false),
      restock: restock.take(maxRowsPerSection).toList(growable: false),
      oversoldCount: oversoldCount,
      restockCount: restockCount,
      activeCount: activeCount,
      unsetSafetyCount: unsetSafetyCount,
      priceUnsetCount: priceUnsetCount,
      neverInboundCount: neverInboundCount,
      limit: maxRowsPerSection,
    );
  }
}

/// 算缺货榜。
///
/// [products] 必须是**全量启用商品**（`ProductService.listForExport(active: true)`）——
/// 用 `findAll()` 默认 `limit: 200` 会让第 201 个之后的商品静默消失，
/// 而「缺货」正是最不能少的那一类（2026-10-27 现实用户暴雷同源）。
///
/// [agg] 来自 `QueryDao.stockAggregates()`；[inTransit] 来自
/// `QueryDao.inTransitByProduct()`；[unsynced] 来自 `StockDelta.unsyncedDelta()`
/// （桌面端没有 `StockDelta` ⇒ 传空表 ⇒ 与旧口径逐字相同）。
///
/// [limit] 是**每段**保留的行数（与压货榜的 `stockTop(limit: 10)` 同口径），
/// 计数不受它影响。
ShortageSummary computeShortage({
  required List<Product> products,
  required Map<String, StockAgg> agg,
  required Map<String, int> inTransit,
  Map<String, int> unsynced = const <String, int>{},
  int limit = 10,
}) {
  int unsetSafety = 0;
  int priceUnset = 0;
  int neverInbound = 0;
  final List<ShortageRow> oversold = <ShortageRow>[];
  final List<ShortageRow> restock = <ShortageRow>[];

  for (final Product product in products) {
    if (product.safetyStock == 0) unsetSafety++;

    final StockAgg? a = agg[product.id];
    final int book = a?.quantity ?? 0;
    final int inStore = effectiveInStoreOf(
      book: book,
      unsynced: unsynced[product.id] ?? 0,
      inTransit: inTransit[product.id] ?? 0,
    );

    // 决策 2 的修正点：两个判定**彻底拆开**，候选集不按安全库存过滤。
    final bool isOversold = inStore < 0;
    final bool needsRestock =
        product.safetyStock > 0 &&
        inStore <= product.safetyStock &&
        inStore >= 0; // 已进超卖段的不重复计入
    if (!isOversold && !needsRestock) continue;

    final int gap = product.safetyStock - inStore;
    final ShortageRow row = ShortageRow(
      product: product,
      inStore: inStore,
      gapQty: gap < 0 ? 0 : gap,
      everInbound: a?.hasInbound ?? false,
    );
    if (row.priceUnset) priceUnset++;
    if (!row.everInbound) neverInbound++;
    (isOversold ? oversold : restock).add(row);
  }

  oversold.sort(_byUrgency);
  restock.sort(_byUrgency);

  return ShortageSummary(
    oversold: oversold.take(limit).toList(growable: false),
    restock: restock.take(limit).toList(growable: false),
    oversoldCount: oversold.length,
    restockCount: restock.length,
    activeCount: products.length,
    unsetSafetyCount: unsetSafety,
    priceUnsetCount: priceUnset,
    neverInboundCount: neverInbound,
    limit: limit,
  );
}

/// 排序：**预计补货金额降序**（决策 1 乙），并列时用稳定次级键。
///
/// 次级键存在的理由很实际：金额相同的商品若每次刷新顺序不同，用户会以为
/// 「榜单在乱跳」。所以依次比 **缺口件数 → 名称 → id**，保证同一份数据
/// 两次渲染顺序一致。
///
/// 「没填参考进价」的排在有金额的**后面**（它们没有可比金额，但仍要看见）。
int _byUrgency(ShortageRow a, ShortageRow b) {
  if (a.priceUnset != b.priceUnset) return a.priceUnset ? 1 : -1;
  final int byCents = b.gapCents.compareTo(a.gapCents);
  if (byCents != 0) return byCents;
  final int byGap = b.gapQty.compareTo(a.gapQty);
  if (byGap != 0) return byGap;
  final int byName = a.name.compareTo(b.name);
  if (byName != 0) return byName;
  return a.id.compareTo(b.id);
}
