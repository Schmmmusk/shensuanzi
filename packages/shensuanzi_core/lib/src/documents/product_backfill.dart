/// 开单页「无缝建档」：草稿里**手打的商品名** → 真实商品（真实诉求批 ②，§CV·一百零五）。
///
/// ## 为什么需要这一层
///
/// 家人拿着进货单直接录，不知道（也不愿意）先去商品页建档。允许在明细行手打名字，
/// 保存时补上档案 —— 否则他会觉得「这软件不让我卖这个货」。
///
/// ## 落点为什么在**服务层**
///
/// | 位置 | 能不能做 | 原因 |
/// |---|---|---|
/// | UI | ❌ | 违反纪律 9「同步落库必须走 RuleEngine」——界面直接建库会让手机端只写镜像 |
/// | `RuleEngine` | ❌ | 引擎拿到的是 `List<DocumentLine>`，`productId` 已是主键；它不知道「名字」 |
/// | **`SaleService.create` 等三个服务** | ✅ | 它们把 draft 变成 `DocumentLine`，建商品与建单在**同一个事务**里 |
///
/// ## 两条不能错的纪律
///
/// 1. **先精确匹配、再新建**（④甲裁定的核心）。用户手打的名字很可能与已有商品
///    **一字不差**（他只是没从选择器点）—— 不匹配就建档 ⇒ 商品列表出现两个
///    「蒙牛纯牛奶」、库存被拆成两半。匹配用 `TRIM(name) = ?`（reply §二-3：
///    复制粘贴常带空格）。
/// 2. **整段在一个事务里**（`Db.transaction` 可重入 ⇒ `ProductService.create`
///    自己的事务会加入外层）。所以校验失败抛异常时，**刚建出来的商品会一起回滚** ——
///    一次打错数量不会在主数据里留下垃圾商品。
///
/// ## 停用的同名商品也会被绑定
///
/// 按名字认，不按启用状态认：名字一样就是同一个东西。若按启用状态过滤，
/// 用户手打一个「停产汽水」就会**又建一个同名商品**，正是 ④甲 要避免的形态。
library;

import '../dao/product_dao.dart';
import '../db/database.dart';
import '../master_data/product_draft.dart';
import '../master_data/product_service.dart';
import '../models/product.dart';
import '../util/money.dart';
import 'delivery_draft.dart';
import 'purchase_draft.dart';
import 'sale_draft.dart';

/// 「缺档行」的解析器：名字 → 商品（命中就绑定，没命中就建档）。
///
/// ⚠️ **只在事务内调用** [ensure] —— 它可能写 `products` 表。
class ProductBackfill {
  ProductBackfill(Db db)
    : _products = ProductDao(db),
      _service = ProductService(db);

  final ProductDao _products;
  final ProductService _service;

  /// 按名字精确匹配（两侧 `TRIM`，**不过滤 `is_active`** —— 见文件头）。
  ///
  /// 纯读，不写库：UI 想「保存前先告诉用户哪些要建档」也用它。
  Product? findByName(String name) => _products.findByExactName(name);

  /// 匹配不到就建档。**必须在事务内调用。**
  ///
  /// 建出来的商品只有 6 个字段里的 4 个（名称 / 单位 / 其中一个价格 / 条码空）：
  /// 单子里知道的只有名字和一个单价，其余填不了 —— 所以对话框必须说清
  /// 「价格以后再改」，否则用户会以为系统记住了他的进价（其实那只是这一单的）。
  Product ensure(
    String name, {
    int sellPriceCents = 0,
    int costPriceCents = 0,
    int? now,
  }) {
    final String trimmed = name.trim();
    final Product? existing = _products.findByExactName(trimmed);
    if (existing != null) return existing;
    return _service.create(
      ProductDraft(
        name: trimmed,
        // `ProductDraft` 的默认单位就是「件」（不是这里新造的值）
        unit: '件',
        // ⚠️ `sellPrice` 在 `ProductDraft` 里是 **mustFill**（空串会被判非法），
        // 所以两边都传格式化值 —— `0` 传 `'0.00'`，而不是空串。
        sellPrice: Money.format(sellPriceCents),
        costPrice: Money.format(costPriceCents),
      ),
      now: now,
    );
  }
}

/// 一行缺档？= 「没有商品 id」但「有名字」。
///
/// 两个都空 ⇒ **不是缺档**，是空行/没填 —— 交给既有校验报「请选一个商品」。
bool _isMissing(String productId, String productName) =>
    productId.isEmpty && productName.trim().isNotEmpty;

/// 把命中/新建到的商品贴回一行（换算上下文一并对齐 —— 新商品单位是「件」）。
SaleLineDraft _bindSale(SaleLineDraft line, Product product) => line.copyWith(
  productId: product.id,
  productName: product.name,
  baseUnit: product.unit,
  packageUnit: product.packageUnit,
  packageSize: product.packageSize,
);

PurchaseLineDraft _bindPurchase(PurchaseLineDraft line, Product product) =>
    line.copyWith(
      productId: product.id,
      productName: product.name,
      baseUnit: product.unit,
      packageUnit: product.packageUnit,
      packageSize: product.packageSize,
    );

DeliveryLineDraft _bindDelivery(DeliveryLineDraft line, Product product) =>
    line.copyWith(
      productId: product.id,
      productName: product.name,
      baseUnit: product.unit,
      packageUnit: product.packageUnit,
      packageSize: product.packageSize,
    );

/// 销售草稿的缺档补全。**单价 = 售价**（销售单填的就是卖价）。
SaleDraft backfillSaleProducts(Db db, SaleDraft draft, {required int now}) {
  final ProductBackfill backfill = ProductBackfill(db);
  final List<SaleLineDraft> lines = <SaleLineDraft>[];
  bool changed = false;
  for (final SaleLineDraft line in draft.lines) {
    if (!_isMissing(line.productId, line.productName)) {
      lines.add(line);
      continue;
    }
    changed = true;
    lines.add(
      _bindSale(
        line,
        backfill.ensure(
          line.productName,
          sellPriceCents: Money.tryParseYuan(line.unitPrice.trim()) ?? 0,
          now: now,
        ),
      ),
    );
  }
  return changed ? draft.copyWith(lines: lines) : draft;
}

/// 采购草稿的缺档补全。**单价 = 进价**。
PurchaseDraft backfillPurchaseProducts(
  Db db,
  PurchaseDraft draft, {
  required int now,
}) {
  final ProductBackfill backfill = ProductBackfill(db);
  final List<PurchaseLineDraft> lines = <PurchaseLineDraft>[];
  bool changed = false;
  for (final PurchaseLineDraft line in draft.lines) {
    if (!_isMissing(line.productId, line.productName)) {
      lines.add(line);
      continue;
    }
    changed = true;
    lines.add(
      _bindPurchase(
        line,
        backfill.ensure(
          line.productName,
          costPriceCents: Money.tryParseYuan(line.unitPrice.trim()) ?? 0,
          now: now,
        ),
      ),
    );
  }
  return changed ? draft.copyWith(lines: lines) : draft;
}

/// 送货草稿的缺档补全。送货单的单价是**卖价**（收货方按售价结算）。
DeliveryDraft backfillDeliveryProducts(
  Db db,
  DeliveryDraft draft, {
  required int now,
}) {
  final ProductBackfill backfill = ProductBackfill(db);
  final List<DeliveryLineDraft> lines = <DeliveryLineDraft>[];
  bool changed = false;
  for (final DeliveryLineDraft line in draft.lines) {
    if (!_isMissing(line.productId, line.productName)) {
      lines.add(line);
      continue;
    }
    changed = true;
    lines.add(
      _bindDelivery(
        line,
        backfill.ensure(
          line.productName,
          sellPriceCents: Money.tryParseYuan(line.unitPrice.trim()) ?? 0,
          now: now,
        ),
      ),
    );
  }
  return changed ? draft.copyWith(lines: lines) : draft;
}
