/// 商品建档 / 编辑 / 停用（主机侧）。
///
/// ## 这一层为什么存在
///
/// DAO 只做 SQL，`ProductDraft` 只做校验，两者拼起来还差三件事：
///
/// 1. **生成编码**（`P0001`）—— 必须与插入在**同一个事务**里
/// 2. **补上表单没有的列** —— `id` / 时间戳 / `sync_version` / 编辑时保持
///    `category` / `remark` / `is_active` 原值
/// 3. **服务层重新校验** —— 不能假设调用方（界面 / 同步层）校验过
///
/// 有这一层，Windows 界面与将来的 `SyncServer.createMasterData`
/// 走的是**同一条建档路径**，不会各写一套。
library;

import '../dao/product_dao.dart';
import '../db/database.dart';
import '../models/product.dart';
import '../rules/product_code_generator.dart';
import '../util/ids.dart';
import 'product_draft.dart';

/// 商品表单校验失败：**带字段级原因**，界面直接标红对应输入框。
class ProductDraftInvalid implements Exception {
  const ProductDraftInvalid(this.errors);

  final Map<ProductField, String> errors;

  /// 拼成一句话（用于日志 / 汇总提示）
  String get summary => errors.values.join('；');

  @override
  String toString() => 'ProductDraftInvalid($summary)';
}

class ProductService {
  ProductService(this.db)
    : _products = ProductDao(db),
      _codes = ProductCodeGenerator(db);

  final Db db;
  final ProductDao _products;
  final ProductCodeGenerator _codes;

  /// 列表。默认只看**启用中**的商品（停用的要显式要）。
  ///
  /// 排序由 DAO 负责（`(created_at, id)` = 建档顺序，见 `ProductDao.findAll`）。
  List<Product> list({String? query, bool? active = true, int limit = 200}) =>
      _products.findAll(query: query, active: active, limit: limit);

  /// **导出用**：不分页、**默认含停用**（§AF-5 / AF-12）。
  ///
  /// 页面拿不到「全部商品」是故意的（列表有 200 上限、默认只看启用），
  /// 但导出必须拿得到 —— 「带走数据」偷偷少东西是不可接受的。
  List<Product> listForExport({String? query, bool? active}) =>
      _products.findAllForExport(query: query, active: active);

  Product? byId(String id) => _products.findById(id);

  /// 这个条码现在挂在**哪些**商品上（建档查重 / 将来的扫码开单）。
  ///
  /// 条码**允许重复**（R-15 裁定）：同箱拆卖、同款不同批次都会撞条码，
  /// 拦下来会挡住合法操作。所以返回的是**列表**，本层**绝不静默挑一条** ——
  /// 谁调用谁负责按匹配数分流：
  ///
  /// | 匹配数 | 调用方该做什么 |
  /// |---|---|
  /// | 0 条 | 提示「没找到这个条码」 |
  /// | 1 条 | 直接用 |
  /// | ≥ 2 条 | **让用户自己选**（列表里显示名称 + 售价 + 建档时间） |
  ///
  /// [excludeId] 供**编辑**用：商品当然会命中自己的条码，
  /// 不排除的话编辑任何一条商品都会看到「这个条码已经给『它自己』用过了」。
  ///
  /// 不过滤 `is_active`：停用只是「不再卖」，条码的归属还是它 ——
  /// 过滤掉会让用户以为条码凭空消失了。
  List<Product> barcodeOwners(String barcode, {String? excludeId}) {
    final String trimmed = barcode.trim();
    if (trimmed.isEmpty) return const <Product>[];
    final List<Product> owners = _products.findByBarcode(trimmed);
    if (excludeId == null) return owners;
    return owners
        .where((Product product) => product.id != excludeId)
        .toList(growable: false);
  }

  /// 建档。**校验不通过直接抛 [ProductDraftInvalid]，库里不留半条记录。**
  ///
  /// 返回值是**落库后的成品**（含系统生成的 `code`）——
  /// 界面要拿它回显「已保存，编码 P0007」。
  Product create(ProductDraft draft, {int? now}) {
    final Map<ProductField, String> errors = draft.validate();
    if (errors.isNotEmpty) throw ProductDraftInvalid(errors);

    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;

    return db.transaction<Product>(() {
      final Product product = Product(
        id: newId(),
        code: _codes.next(), // 事务内生成，否则并发撞号
        name: draft.normalizedName,
        barcode: draft.normalizedBarcode,
        unit: draft.normalizedUnit,
        costPrice: draft.costPriceCents,
        sellPrice: draft.sellPriceCents,
        safetyStock: draft.safetyStockValue,
        packageNote: draft.normalizedPackageNote,
        createdAt: stamp,
        updatedAt: stamp,
      );
      _products.insert(product);
      return product;
    });
  }

  /// 编辑。
  ///
  /// - **`code` 不改**（它是系统生成的，改了会让用户以为商品变了）
  /// - **`created_at` 不改**（建档时间是事实）
  /// - 表单里没有的列（`category` / `remark` / `is_active`）**保持原值** ——
  ///   否则「编辑名称」会把用户后来设的分类、备注、停用状态一起抹掉
  /// - `sync_version + 1`（主数据乐观锁，与 `ProductDao.softDelete` 同口径）
  Product update(String id, ProductDraft draft, {int? now}) {
    final Map<ProductField, String> errors = draft.validate();
    if (errors.isNotEmpty) throw ProductDraftInvalid(errors);

    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;

    return db.transaction<Product>(() {
      final Product? existing = _products.findById(id);
      if (existing == null) throw StateError('商品不存在：$id');

      final Product updated = Product(
        id: existing.id,
        code: existing.code,
        name: draft.normalizedName,
        barcode: draft.normalizedBarcode,
        unit: draft.normalizedUnit,
        costPrice: draft.costPriceCents,
        sellPrice: draft.sellPriceCents,
        safetyStock: draft.safetyStockValue,
        packageNote: draft.normalizedPackageNote,
        category: existing.category,
        isActive: existing.isActive,
        remark: existing.remark,
        createdAt: existing.createdAt,
        updatedAt: stamp,
        syncVersion: existing.syncVersion + 1,
      );
      _products.update(updated);
      return updated;
    });
  }

  /// 停用 / 恢复。
  ///
  /// 主数据**软删**（`Agents.md` 纪律 2）：行还在，`is_active = 0`。
  /// 停用而不是删除，是因为历史单据还引用着它 —— 删了那些单据就成了无头账。
  void setActive(String id, bool active, {int? now}) {
    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;
    db.transaction<void>(() {
      if (_products.findById(id) == null) {
        throw StateError('商品不存在：$id');
      }
      if (active) {
        _products.activate(id, updatedAt: stamp);
      } else {
        _products.softDelete(id, updatedAt: stamp);
      }
    });
  }
}
