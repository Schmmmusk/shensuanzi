/// 镜像库的「身份标记」—— **这份镜像是哪台主机的**（F14，2026-10-25 裁定）。
///
/// ## 为什么必须写在镜像自己身上
///
/// 判定「换主机」原本只看 `pairing.json` 的 `hostId`。但「忘记这台主机」会
/// **删掉** `pairing.json`（那是正常路径，不是异常）⇒ 再扫码时 `previous == null`
/// ⇒ 重建镜像被跳过 ⇒ 旧主机的 `P0001` 还在镜像里，新主机推同编码的商品
/// 直接 `UNIQUE constraint failed: products.code`，**每次重试都必失败**。
///
/// ⇒ 身份必须跟着**镜像库**走：`pairing.json` 可以丢，镜像不会。
///
/// ## 为什么不进 `applyOrder`
///
/// [SyncClient.rebuildMirror] 按 `applyOrder` 逐表 `DROP TABLE` —— 这张表
/// **不在** `applyOrder` 里，所以重建镜像时**不会被删**；重建完再由调用方
/// 写入新的 `host_id`（见 `MobileSyncService.pairFromCode`）。
///
/// ## 老镜像没有这张表怎么办
///
/// 0.6.5 及更早的镜像里没有 `mirror_meta` ⇒ [hostId] 返回 `null`。
/// 此时**不能**当成"全新手机"：要用 [hasAnyData] 区分
/// 「空镜像（首次配对）」与「有数据但不知道属于谁（老版本升级上来的）」，
/// 后者按换主机处理（安全侧：宁可归档重建，也不把旧店的货混进新店）。
library;

import '../db/database.dart';

class MirrorMeta {
  MirrorMeta(this._db);

  final Db _db;

  /// 表名（`rebuildMirror` 不碰它 —— 见文件头）
  static const String table = 'mirror_meta';

  /// 建表（幂等）。读写前都会调用。
  void ensureTable() => _db.raw.execute(
    'CREATE TABLE IF NOT EXISTS $table (k TEXT PRIMARY KEY, v TEXT NOT NULL)',
  );

  /// 这份镜像属于哪台主机。`null` = 没有标记（空镜像 / 0.6.5 及更早的老镜像）。
  String? get hostId => _read('host_id');

  void writeHostId(String hostId) => _write('host_id', hostId);

  /// 清掉身份（**只在测试与"彻底重置"里用**；换主机是写新值，不是清空）。
  void clearHostId() {
    try {
      ensureTable();
      _db.raw.execute('DELETE FROM $table WHERE k = ?', <Object?>['host_id']);
    } catch (_) {
      // 删不掉不影响结论
    }
  }

  /// 镜像里**有没有任何数据**（九表或队列任一非空）。
  ///
  /// 用途：区分「全新手机首次扫码」（什么都不做，直接建库）与
  /// 「老版本升级上来、镜像里有货但没有身份标记」（按换主机处理）。
  bool hasAnyData() {
    for (final String table in _dataTables) {
      try {
        if (_db.raw.select('SELECT 1 AS x FROM $table LIMIT 1').isNotEmpty) {
          return true;
        }
      } catch (_) {
        // 表还不存在（全新库）⇒ 跳过
      }
    }
    return false;
  }

  /// 九张镜像表 + 队列（顺序无关；`sync_queue` 也算数据 —— 离线单不能丢）
  static const List<String> _dataTables = <String>[
    'products',
    'parties',
    'accounts',
    'documents',
    'document_lines',
    'stock_ledger',
    'money_ledger',
    'party_ledger',
    'settlements',
    'sync_queue',
  ];

  String? _read(String key) {
    try {
      final List<Map<String, Object?>> rows = _db.raw.select(
        'SELECT v FROM $table WHERE k = ?',
        <Object?>[key],
      );
      if (rows.isEmpty) return null;
      final Object? value = rows.first['v'];
      return value is String && value.isNotEmpty ? value : null;
    } catch (_) {
      // 表不存在 / 库读不了 ⇒ 当作"没有身份"（调用方会按老镜像处理）
      return null;
    }
  }

  void _write(String key, String value) {
    ensureTable();
    _db.raw.execute(
      'INSERT INTO $table (k, v) VALUES (?, ?) '
      'ON CONFLICT(k) DO UPDATE SET v = excluded.v',
      <Object?>[key, value],
    );
  }
}
