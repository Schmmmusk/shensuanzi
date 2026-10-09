/// 主数据建档 / 编辑的「提交出口」抽象（**D2**，2026-10-08）。
///
/// ## 为什么与 `DocumentSink` 同构
///
/// 三个开单页早已按 [DocumentSink] 编程（B3a/B3b）：主机转调 `*Service`
/// （落库 + 跑规则），客户端只**入队**。主数据要的正是同一件事 ——
/// 手机**离线建档**（`reply_review.md` §CH 提案 A：真机刚需「急着开单 /
/// 电脑不在身边」），所以分成同一对实现：
///
/// | 实现 | 谁用 | 做什么 |
/// |---|---|---|
/// | [ServiceMasterSink] | 主机（Windows 桌面壳） | 转调 `ProductService`（**与接线前逐字同行为**） |
/// | [QueueMasterSink] | 客户端（手机壳） | 校验 → 本地 id + 编码 → **乐观写镜像** → 入队 `createMasterData` / `updateMasterData` |
///
/// ## 客户端这一侧的三条契约（都是裁定过的）
///
/// 1. **不改 `code`**：`code` 系统生成、用户不填。客户端**从镜像 `max(code)+1`
///    生成**（§CH §3），但 `updateMasterData` 的 payload **不带 `code`**
///    （§CS·五；`sync_protocol.md §8.1` 端责任表）。
/// 2. **乐观写镜像**（§CH §4）：主数据行**客户端全知**（用户填什么就是什么），
///    与单据本质不同（金额 / 状态由主机规则算出）—— 所以入队的同时把行写进镜像，
///    用户立刻能在列表里看到自己刚建的商品。主机若**改派了编码**，靠 pull 按
///    **同一个 id** 覆盖回来（`SyncClient._upsertRow` 是 UPSERT）。
/// 3. **`id` 是幂等键**（§CH §2）：客户端生成 UUIDv7，重推无害。
///
/// ⚠️ **期初录入仍不做**（§CH §7）：盘点 delta 客户端算不出，诚实地说不知道 ——
/// 那条例外留在 UI 的引导对话框里。
library;

import '../dao/product_dao.dart';
import '../dao/sync_dao.dart';
import '../db/database.dart';
import '../db/schema.dart';
import '../models/product.dart';
import '../models/sync_queue_entry.dart';
import '../rules/product_code_generator.dart';
import '../sync/sync_operation.dart';
import '../sync/whitelist.dart';
import '../util/ids.dart';
import 'product_draft.dart';
import 'product_service.dart';

/// 一次主数据提交的统一结果（两端同形 —— 与 `DocumentSubmitResult` 同一套路）。
class MasterDataSubmitResult {
  /// 主机：已落库（[product] 是**落库后的成品**，含主机分配的编码）。
  const MasterDataSubmitResult.saved(Product this.product)
    : isQueued = false,
      error = null;

  /// 客户端：已入队 + 已乐观写镜像（[product] 是**镜像里的那一行**）。
  const MasterDataSubmitResult.queued(Product this.product)
    : isQueued = true,
      error = null;

  /// 校验失败（**不入库、不入队、不写镜像** —— 库与队列都不留半条）。
  const MasterDataSubmitResult.failure(ProductDraftInvalid this.error)
    : product = null,
      isQueued = false;

  /// 落库后 / 镜像里的那一行；失败时为 `null`。
  final Product? product;

  /// `false` = 已落库（主机）；`true` = 已入队待同步（客户端）。
  final bool isQueued;

  /// 校验失败的原因（字段级）；成功为 `null`。
  final ProductDraftInvalid? error;

  bool get isFailure => error != null;

  /// 入队成功的**用户告知**（判定与文案在 core，UI 不造句）。
  /// 主机路径为 `null`（桌面按既有文案，零变化）。
  String? get queuedNotice => isQueued
      ? '已记入待同步（编码 ${product!.code}）。主机下次联网时会收到。'
      : null;

  @override
  String toString() => isFailure
      ? 'MasterDataSubmitResult(failure: $error)'
      : 'MasterDataSubmitResult(${isQueued ? 'queued' : 'saved'} '
            '${product?.code})';
}

/// 主数据提交出口。表单页只认这个接口（**UI 层不出现「是不是客户端」的分支**）。
///
/// v1 只开商品（[ProductDraft]）—— 往来方 / 账户同构，等真要它们离线建档时
/// 按同一份模式加（`docs/reply_review.md` §CH §8 的「三页与往来页」）。
abstract class MasterDataSink {
  /// 建档。[now] 只为让单测可复现（主机侧原样转给 `ProductService`）。
  MasterDataSubmitResult createProduct(ProductDraft draft, {int? now});

  /// 编辑。⚠️ **`code` 不变** —— 与 `ProductService.update` 同一口径。
  MasterDataSubmitResult updateProduct(String id, ProductDraft draft, {int? now});

  /// 停用 / 恢复（软删，`Agents.md` 纪律 2）。
  MasterDataSubmitResult setProductActive(String id, bool active, {int? now});
}

/// 主机出口：把 `ProductService` 包成 [MasterDataSink]。
///
/// ⚠️ **逐字同行为**：内部就是转调 `ProductService`（校验、编码生成、异常语义
/// 全部原样）；唯一新增是把 `ProductDraftInvalid` 从「抛出」改成「装进结果」，
/// 与 [ServiceSink]（单据）同款。
class ServiceMasterSink implements MasterDataSink {
  ServiceMasterSink(this._products);

  final ProductService _products;

  @override
  MasterDataSubmitResult createProduct(ProductDraft draft, {int? now}) {
    try {
      return MasterDataSubmitResult.saved(_products.create(draft, now: now));
    } on ProductDraftInvalid catch (error) {
      return MasterDataSubmitResult.failure(error);
    }
  }

  @override
  MasterDataSubmitResult updateProduct(
    String id,
    ProductDraft draft, {
    int? now,
  }) {
    try {
      return MasterDataSubmitResult.saved(
        _products.update(id, draft, now: now),
      );
    } on ProductDraftInvalid catch (error) {
      return MasterDataSubmitResult.failure(error);
    }
  }

  @override
  MasterDataSubmitResult setProductActive(
    String id,
    bool active, {
    int? now,
  }) {
    // 先取一份用于返回（`setActive` 只回 void）—— 找不到就让它抛，与现状一致
    _products.setActive(id, active, now: now);
    return MasterDataSubmitResult.saved(_products.byId(id)!);
  }
}

/// `createMasterData` 的 wire payload（`sync_protocol.md §8.1`）。
///
/// = `toRow()` **去掉主机专属列**（`created_at` / `updated_at` / `sync_version`
/// 由主机写，纪律 10）。`code` **保留** —— 建档时它是客户端的**建议**
/// （主机可改派，§CH §3）。
Map<String, Object?> masterDataCreatePayload(Map<String, Object?> row) =>
    <String, Object?>{
      for (final MapEntry<String, Object?> e in row.entries)
        if (!SyncWhitelist.hostOnlyColumns.contains(e.key)) e.key: e.value,
    };

/// `updateMasterData` 的 wire payload（`sync_protocol.md §8.1`）。
///
/// ⚠️ **`code` 与主机专属列都去掉**（§CS·五 裁定 ①）：
/// 系统生成的字段客户端不该发，发了主机也一律丢弃 —— 契约在文档里
/// （`sync_protocol.md §8.1` 的端责任表），这里从**源头**堵住。
Map<String, Object?> masterDataUpdatePayload(Map<String, Object?> row) =>
    <String, Object?>{
      for (final MapEntry<String, Object?> e in row.entries)
        if (!SyncWhitelist.hostOnlyColumns.contains(e.key) && e.key != 'code')
          e.key: e.value,
    };

/// 客户端出口：校验 → 本地 id + 编码 → **乐观写镜像** → 入队。
///
/// ## 镜像与队列在**同一个库**
///
/// 手机上 `SyncQueueDao` 就挂在镜像库上（B2 起如此），所以这里只收一个
/// [mirror]：队列条目与乐观行**同库同事务**写 —— 不会出现「行写了、条目没写」
/// 这种静默丢数据的中间态。
class QueueMasterSink implements MasterDataSink {
  QueueMasterSink({
    required Db mirror,
    required SyncQueueDao queue,
    int Function()? clock,
  }) : _mirror = mirror,
       _products = ProductDao(mirror),
       _queue = queue,
       _clock = clock ?? _systemClock;

  final Db _mirror;
  final ProductDao _products;
  final SyncQueueDao _queue;
  final int Function() _clock;

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;

  @override
  MasterDataSubmitResult createProduct(ProductDraft draft, {int? now}) {
    final Map<ProductField, String> errors = draft.validate();
    if (errors.isNotEmpty) {
      return MasterDataSubmitResult.failure(ProductDraftInvalid(errors));
    }

    final int stamp = now ?? _clock();
    final Product row = _mirror.transaction<Product>(() {
      final Product product = Product(
        id: newId(),
        // ⚠️ 与主机**同一份**生成器：镜像里的商品已经含有主机下发的编码，
        // 所以「镜像 max+1」与「主机 max+1」在稳态下一致（不一致时主机改派，
        // D1 已落地）。生成必须在事务内（`products.code` 是 UNIQUE）。
        code: ProductCodeGenerator(_mirror).next(),
        name: draft.normalizedName,
        barcode: draft.normalizedBarcode,
        unit: draft.normalizedUnit,
        costPrice: draft.costPriceCents,
        sellPrice: draft.sellPriceCents,
        safetyStock: draft.safetyStockValue,
        packageNote: draft.normalizedPackageNote,
        packageUnit: draft.normalizedPackageUnit,
        packageSize: draft.normalizedPackageSize,
        createdAt: stamp,
        updatedAt: stamp,
      );
      _products.insert(product); // 乐观写：用户立刻能在列表里看到
      _queue.enqueue(
        SyncQueueEntry.create(
          SyncOperation(
            entity: Schema.products,
            entityId: product.id,
            operation: SyncOpType.createMasterData,
            payload: masterDataCreatePayload(product.toRow()),
          ),
          now: stamp,
        ),
      );
      return product;
    });

    return MasterDataSubmitResult.queued(row);
  }

  @override
  MasterDataSubmitResult updateProduct(
    String id,
    ProductDraft draft, {
    int? now,
  }) {
    final Product? existing = _products.findById(id);
    if (existing == null) throw StateError('镜像里没有这个商品：$id');

    final Map<ProductField, String> errors = draft.validate();
    if (errors.isNotEmpty) {
      return MasterDataSubmitResult.failure(ProductDraftInvalid(errors));
    }

    final int stamp = now ?? _clock();
    final Product row = _mirror.transaction<Product>(() {
      final Product updated = Product(
        id: existing.id,
        // `code` / `created_at` 不改；表单没有的列保持原值
        // —— 与 `ProductService.update` **逐字同一口径**
        code: existing.code,
        name: draft.normalizedName,
        barcode: draft.normalizedBarcode,
        unit: draft.normalizedUnit,
        costPrice: draft.costPriceCents,
        sellPrice: draft.sellPriceCents,
        safetyStock: draft.safetyStockValue,
        packageNote: draft.normalizedPackageNote,
        packageUnit: draft.normalizedPackageUnit,
        packageSize: draft.normalizedPackageSize,
        category: existing.category,
        isActive: existing.isActive,
        remark: existing.remark,
        createdAt: existing.createdAt,
        updatedAt: stamp,
        syncVersion: existing.syncVersion + 1, // 乐观锁：主机收到后自会校正
      );
      _products.update(updated);
      _queue.enqueue(
        SyncQueueEntry.create(
          SyncOperation(
            entity: Schema.products,
            entityId: updated.id,
            operation: SyncOpType.updateMasterData,
            // base_version = 镜像行的版本（§CH §6：镜像行自带 sync_version）
            baseVersion: existing.syncVersion,
            payload: masterDataUpdatePayload(updated.toRow()),
          ),
          now: stamp,
        ),
      );
      return updated;
    });

    return MasterDataSubmitResult.queued(row);
  }

  @override
  MasterDataSubmitResult setProductActive(
    String id,
    bool active, {
    int? now,
  }) {
    final Product? existing = _products.findById(id);
    if (existing == null) throw StateError('镜像里没有这个商品：$id');

    final int stamp = now ?? _clock();
    final Product row = _mirror.transaction<Product>(() {
      final Product updated = Product(
        id: existing.id,
        code: existing.code,
        name: existing.name,
        barcode: existing.barcode,
        unit: existing.unit,
        costPrice: existing.costPrice,
        sellPrice: existing.sellPrice,
        safetyStock: existing.safetyStock,
        packageNote: existing.packageNote,
        packageUnit: existing.packageUnit,
        packageSize: existing.packageSize,
        category: existing.category,
        isActive: active,
        remark: existing.remark,
        createdAt: existing.createdAt,
        updatedAt: stamp,
        syncVersion: existing.syncVersion + 1,
      );
      _products.update(updated);
      // ⚠️ 「停用 / 启用」走 `updateMasterData`（带 `is_active`）而**不是**
      // `deleteMasterData`：主机侧两条路等价（都是软删 + `sync_version + 1`），
      // 但 update 这条路**能双向**（停用与恢复同一条），少一个分支。
      _queue.enqueue(
        SyncQueueEntry.create(
          SyncOperation(
            entity: Schema.products,
            entityId: updated.id,
            operation: SyncOpType.updateMasterData,
            baseVersion: existing.syncVersion,
            payload: masterDataUpdatePayload(updated.toRow()),
          ),
          now: stamp,
        ),
      );
      return updated;
    });

    return MasterDataSubmitResult.queued(row);
  }
}
