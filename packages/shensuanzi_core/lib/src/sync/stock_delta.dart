/// 「权威镜像 + 未同步影响」的库存计算（C1·§CC 自 `SyncClient` 抽出，
/// **行为逐字同搬运**）。
///
/// ## 为什么独立
///
/// 手机端的库存页（B3 视图）在没有 Transport / Token 的环境里也要算叠加 ——
/// 而 [SyncClient] 构造函数要求 transport。这份计算实际只依赖
/// **镜像库 + 队列**，与传输无关；抽出来后 UI 直接用，
/// 不必为了算个库存造一个同步客户端。
///
/// ⚠️ [SyncClient.deltaOf] / [SyncClient.unsyncedDelta] / [SyncClient.stockViewOf]
/// 现在只是**转调**这里 —— 行为零变化，`sync_client_test` 是回归守卫。
library;

import '../dao/query_dao.dart';
import '../dao/sync_dao.dart';
import '../db/database.dart';
import '../models/sync_queue_entry.dart';
import 'sync_client.dart';
import 'sync_operation.dart';

/// 镜像库存的「权威 + 未同步」计算器。
class StockDelta {
  StockDelta({required Db db, required SyncQueueDao queue})
    : _queries = QueryDao(db),
      _queue = queue;

  final QueryDao _queries;
  final SyncQueueDao _queue;

  /// 一条队列条目对**库存数量**的影响（纯函数，`sync_protocol.md` §一）。
  ///
  /// 只做 `±quantity` 累加：**不算成本、不算往来、不算盘点**。
  ///
  /// | `doc_type` | 符号 | 为什么 |
  /// |---|---|---|
  /// | `purchase` / `sale_return` | **+** | 货进店 |
  /// | `sale` / `delivery` / `purchase_return` | **−** | 货离店 |
  /// | `stocktake` | `0` | 它的影响是「实际数量 − 账面数量」，而账面数量依赖完整流水 —— **客户端算不出**，所以诚实地贡献 0。盘点是低频操作，用户不会期望中途看到估算 |
  /// | `receipt` / `payment` | `0` | 资金单据，不影响库存 |
  ///
  /// 不做任何校验（负库存允许，`threat_model.md` §3.4），UI 标红即可。
  static Map<String, int> deltaOf(SyncQueueEntry entry) {
    if (entry.operation != SyncOpType.createDocument) {
      return const <String, int>{}; // 主数据与动作不影响库存数量
    }
    final Object? rawDocument = entry.payload['document'];
    if (rawDocument is! Map) return const <String, int>{};
    final Object? rawType = rawDocument['doc_type'];
    if (rawType is! String) return const <String, int>{};

    final int sign = switch (rawType) {
      'purchase' || 'sale_return' => 1,
      'sale' || 'delivery' || 'purchase_return' => -1,
      _ => 0, // 含 stocktake / receipt / payment
    };
    if (sign == 0) return const <String, int>{};

    final Object? rawLines = entry.payload['lines'];
    if (rawLines is! List) return const <String, int>{};

    final Map<String, int> delta = <String, int>{};
    for (final Object? rawLine in rawLines) {
      if (rawLine is! Map) continue;
      final Object? productId = rawLine['product_id'];
      final Object? quantity = rawLine['quantity'];
      if (productId is! String || quantity is! int) continue;
      delta[productId] = (delta[productId] ?? 0) + sign * quantity;
    }
    return delta;
  }

  /// 全部「已发生、但权威状态还没包含」的库存影响之和（`pending` + `sent` +
  /// `failed` 都算）。UI 的表达式是：
  ///
  /// ```
  /// 显示库存 = 权威镜像 + delta   ← 用 [stockViewOf] 一次算好
  /// ```
  Map<String, int> unsyncedDelta() {
    final Map<String, int> total = <String, int>{};
    for (final SyncQueueEntry entry in _queue.all()) {
      deltaOf(entry).forEach((String productId, int value) {
        total[productId] = (total[productId] ?? 0) + value;
      });
    }
    return total;
  }

  /// 给 UI 用：`权威库存 + 未同步影响`，并给出拆解。
  ///
  /// 「权威镜像 10、未同步 −3」这样的拆解要能点开看到是哪几张单 ——
  /// 所以返回结构里带 [StockView.contributors]。
  StockView stockViewOf(String productId) {
    final int authoritative = _queries.stockByProduct()[productId] ?? 0;
    final List<SyncQueueEntry> contributors = <SyncQueueEntry>[
      for (final SyncQueueEntry entry in _queue.all())
        if (deltaOf(entry).containsKey(productId)) entry,
    ];
    final int delta = contributors.fold<int>(
      0,
      (int sum, SyncQueueEntry entry) => sum + (deltaOf(entry)[productId] ?? 0),
    );
    return StockView(
      productId: productId,
      authoritative: authoritative,
      unsynced: delta,
      contributors: contributors,
    );
  }
}
