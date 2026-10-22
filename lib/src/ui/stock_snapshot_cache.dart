/// **库存快照的「按需失效」缓存**（2026-10-22，§CV·八十一 批 2 第 7 条）。
///
/// ## 它同时修两个反向的病
///
/// 同一件事（「当前库存」快照）在两个开单页有两种错法：
///
/// | 页 | 原来 | 症状 |
/// |---|---|---|
/// | 销售 | `build()` 里直接 `stockSnapshot()` | 页内**任何输入框每敲一个键**都 `setState` ⇒ 每键一次 `GROUP BY` 全表聚合。数据攒到几千条流水后「打字卡半秒」 |
/// | 送货 | `late final`（只算一次） | `_afterSaved` 复用同一个 State ⇒ **第二张送货单**的「当前库存」还含上一单已扣的量 ⇒ **该报负库存时不报** |
///
/// 两个都源于「快照的生存期」没想清楚。正确口径只有一条：
///
/// > **一次编辑会话内保持不变；一次成功提交后立即失效。**
///
/// ⇒ 缓存 + 显式 [invalidate]：`build` 不再碰数据库，提交成功后调一次。
/// 提交后重算的那一次，拿到的才是**主机已落账**（桌面）或**镜像已入队**（手机）的数。
library;

/// 见文件头。`load` 由页面传入（`service.stockSnapshot` 或镜像版）。
class StockSnapshotCache {
  StockSnapshotCache(this._load);

  final Map<String, int> Function() _load;
  Map<String, int>? _value;

  /// 读快照（首次访问才查库；之后一直用缓存）
  Map<String, int> get value => _value ??= _load();

  /// 提交成功 / 数据可能变了 ⇒ 下次访问重查
  void invalidate() => _value = null;
}
