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

/// 镜像主数据行的派生 `isPending` 判定。
class PendingMarks {
  PendingMarks(this._queue);

  final SyncQueueDao _queue;

  /// 当前「未确认」的实体 id **快照**（每次访问都查一次库）。
  ///
  /// ⚠️ 调用方**一次 build 取一次**，然后逐行 `contains` ——
  /// 逐行调用本 getter 会变成 N 次 SQL（它本来是一次查询能给出的集合）。
  Set<String> get ids => _queue.unconfirmedEntityIds();
}
