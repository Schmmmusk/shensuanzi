/// 手机端「镜像只读视图」（C1·§CC 方案 1，2026-10-06 裁定）。
///
/// 把「镜像库」包成手机壳各页面要用的**查询面**：商品 / 往来方 / 账户 /
/// 聚合查询 / 库存叠加（[StockDelta]）。C2 接线后，手机端的读面从
/// 本机主库切到这里 —— **镜像库成为手机端唯一数据源**。
///
/// ## 写权限边界（§CC 裁定：谁可以写，谁不可以）
///
/// | 写入方 | 允许？ | 说明 |
/// |---|---|---|
/// | 用户通过 UI 写 | ❌ | 「只读」的本意 —— 手机端不发起任何业务写入 |
/// | `SyncClient` 经 pull 写九张业务表 | ✅ | 镜像必须能被 pull 更新 |
/// | `SyncQueueDao` 写 `sync_queue` | ✅ | **队列在镜像库是 B2 起的既有事实**（`Db.open` 建全部表，含 `Schema.clientTables` 三张）。所以「镜像只读」精确说是：**九张业务表只读（pull 除外）**；`sync_queue` / `clock_offset` / `sync_cursor` 是**客户端传输区**（`data_model.md` §四：不是业务数据，本来就该被反复改写） |
/// | 用户的迁移 / 备份 | ❌ | 镜像不是用户数据，是派生数据；坏了就重建（`schema_migration.md` §六） |
///
/// ## 主库的去向（§CC·裁定：废弃但保留）
///
/// C2 接线后，手机端**不再读、不再写**本机主库（`<私有>/data`）——
/// 开单走队列、主数据禁建（保留入口 + 引导）、读面全在镜像。
/// **文件保留不删**（保守），`v1 Android 未发布 ⇒ 无真实用户主库数据，不做迁移`。
library;

import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'mobile_sync_service.dart';

/// 镜像只读视图。
///
/// ⚠️ **边界取「硬约束」形态**：暴露的是 **DAO**（只有查询方法），
/// 而不是带写方法的 `ProductService` / `PartyService` —— 想写也没有入口。
/// 九张业务表的唯一写入方是 pull（`SyncClient`）。
class MirrorView {
  MirrorView({required Db mirror, required SyncQueueDao queue})
    : products = ProductDao(mirror),
      parties = PartyDao(mirror),
      accounts = AccountDao(mirror),
      queries = QueryDao(mirror),
      stock = StockDelta(db: mirror, queue: queue);

  /// 从手机同步服务取镜像库（`openMirror` 幂等，首次会建空库）
  factory MirrorView.of(MobileSyncService sync) {
    final Db mirror = sync.openMirror();
    return MirrorView(mirror: mirror, queue: SyncQueueDao(mirror));
  }

  /// 商品查询（选择器 / 库存页）。**只有查询方法**。
  final ProductDao products;

  /// 往来方查询（选择器 / 往来页）。**只有查询方法**。
  final PartyDao parties;

  /// 账户查询（开单收款区）。**只有查询方法**。
  final AccountDao accounts;

  /// 聚合查询（库存页列表）。**只有查询方法**。
  final QueryDao queries;

  /// 库存叠加（权威 + 未同步 + 拆解）。
  final StockDelta stock;
}
