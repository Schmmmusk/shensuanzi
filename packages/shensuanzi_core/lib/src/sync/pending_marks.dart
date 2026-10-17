/// 镜像主数据行的「主机还没确认」标记（`data_model.md §4.4` 第 3 条，D2b）。
///
/// ## 为什么要有它
///
/// 乐观写让「刚建的行**立刻可见**」，本类回答它的**对偶问题**：
/// 「哪几行**主机还没确认**」。
///
/// ⚠️ **少了它，乐观写就是一句谎话** —— 用户以为「建好了」，其实是本地臆想。
/// `data_model.md §4.4` 第 3 条把这条钉死：
///
/// > 乐观行必须可分辨 …… UI 对 `isPending` 的行加一行浅灰小字「待同步」——
/// > 「我有的」与「主机确认的」必须一眼可分。
///
/// ## 判定单一来源
///
/// [ids] 只**转调** [SyncQueueDao.unconfirmedEntityIds]（`pending` + `sent`；
/// `failed` **不算** —— 它要人工处理，混进来会让「待同步」常亮）。
/// 本类**不自己判**「哪些算未确认」：判据只应有一处，否则会长出第二份定义
/// （与 `resolvePreferredCode` / `ProductCodeGenerator` 同一条纪律）。
///
/// ## 与 [StockDelta] 同构
///
/// 两者都只依赖**镜像库 + 队列**，**不碰传输**（不需要 Transport / Token），
/// 因此可以在没有同步客户端的环境里直接给 UI 用。
library;

import '../dao/sync_dao.dart';
import '../db/schema.dart';
import '../models/sync_queue_entry.dart';
import 'sync_operation.dart';

/// 镜像主数据行的派生 `isPending` 判定。
class PendingMarks {
  PendingMarks(this._queue);

  final SyncQueueDao _queue;

  /// 当前「未确认」的实体 id **快照**（每次访问都查一次库）。
  ///
  /// ⚠️ 调用方**一次 build 取一次**，然后逐行 `contains` ——
  /// 逐行调用本 getter 会变成 N 次 SQL（它本来是一次查询能给出的集合）。
  Set<String> get ids => _queue.unconfirmedEntityIds();

  /// **#32（2026-10-17 裁定④）**：未确认的**条目数**（pending + sent）——
  /// 手机壳概览页「有 N 条未同步」的数据源（诚实口径：镜像里没有的
  /// 数字就是没有，不假装算得出来）。
  int unconfirmedCount() =>
      _queue.withStatus(SyncQueueStatus.pending).length +
      _queue.withStatus(SyncQueueStatus.sent).length;

  /// #31（2026-10-16 裁定②）：**待同步的「建档期初」数量**，按商品 id。
  ///
  /// 手机「新建商品 + 当前库存」走**一条**队列条目（`createMasterData` 带
  /// 可选 `opening_quantity`，host 建档同事务落账）—— 但 stocktake 的 diff
  /// 在主机端算，客户端 `StockDelta.deltaOf` 对它恒为 0 ⇒ 同步前库存页只显示
  /// 权威值，**用户刚填的期初量从数字上消失**。本 getter 把它找回来：
  /// UI 在商品行下补一行「期初 N 件待同步」（**只作提示，不参与库存计算**
  /// —— 与「未同步影响必须可见」的 §CV 一贯口径一致）。
  ///
  /// 与 [ids] 同一「未确认」口径（`pending` + `sent`；`failed` 死信不算）。
  /// ⚠️ 调用方**一次 build 取一次**（逐行调用 = N 次 SQL）。
  Map<String, int> openingQuantityByProduct() => <String, int>{
    for (final SyncQueueEntry entry in <SyncQueueEntry>[
      ..._queue.withStatus(SyncQueueStatus.pending),
      ..._queue.withStatus(SyncQueueStatus.sent),
    ])
      if (entry.entity == Schema.products &&
          entry.operation == SyncOpType.createMasterData &&
          entry.payload['opening_quantity'] is int)
        entry.entityId: entry.payload['opening_quantity']! as int,
  };
}
