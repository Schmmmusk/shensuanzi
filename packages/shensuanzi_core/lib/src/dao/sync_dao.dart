/// 客户端同步状态的三个 DAO（`docs/data_model.md` §四）。
///
/// 三张表都是**仅客户端**的（[Schema.clientTables]）：主机不应创建它们。
///
/// ⚠️ **不开事务** —— 事务由调用方（`SyncClient`）统一开（`Agents.md` 纪律 1）。
/// 这条对 `pull` 尤其关键：**行与游标必须同事务**，
/// 否则「存了游标但没应用行」会**静默丢数据**（R-14 §4.3）。
library;

import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/schema.dart';
import '../models/sync_queue_entry.dart';

/// 拉取游标（`docs/data_model.md` §4.3，R-14 方案 A）。
///
/// **只存不解析**：值就是主机返回的 `next_cursors` 原值（`"<时间戳>|<id>"` 或
/// 整数字符串）。客户端从不解读它的语义，只负责原样回传 ——
/// 这样主机将来换游标编码**不需要客户端升级**。
///
/// ⚠️ **`entity` 列存的是 `sync_protocol.md` §8.2 的键名**
/// （`stock_since` / `doc_since` / `products_since` …），不是表名。
/// 理由：不变量 B8 要求本表与 `next_cursors` **逐字段一致** ——
/// 存键名时这就是两个 map 的**直接相等**，不需要任何映射层
/// （与「wire 值 = `toRow()` 形态」同一条原则）。键的单一出处是 [SyncCursorKeys.all]。
class SyncCursorDao {
  SyncCursorDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  /// 全部游标：**键 = `§8.2` 的键名**，值 = 主机返回的原值。
  ///
  /// 空表 → 空 map，表示「从头拉」——**没有行就是正确的默认**，
  /// 不需要额外的「是否已初始化」标志（R-14 §4.1）。
  Map<String, String> getAll() => <String, String>{
    for (final Row row in _raw.select(
      'SELECT entity, cursor FROM ${Schema.syncCursor}',
    ))
      row['entity']! as String: row['cursor']! as String,
  };

  /// 整批写入（`pull` 成功后调用）。已存在的键**直接覆盖**。
  void upsertAll(Map<String, String> cursors, {required int now}) {
    for (final MapEntry<String, String> entry in cursors.entries) {
      _raw.execute(
        'INSERT INTO ${Schema.syncCursor} (entity, cursor, updated_at) '
        'VALUES (?, ?, ?) '
        'ON CONFLICT(entity) DO UPDATE SET '
        'cursor = excluded.cursor, updated_at = excluded.updated_at',
        <Object?>[entry.key, entry.value, now],
      );
    }
  }

  void clear() => _raw.execute('DELETE FROM ${Schema.syncCursor}');
}

/// 同步队列（`docs/data_model.md` §4.1）。
class SyncQueueDao {
  SyncQueueDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  /// 入队（`status = pending`，`next_retry_at = 0` 立即到期）
  SyncQueueEntry enqueue(SyncQueueEntry entry) {
    final Map<String, Object?> row = entry.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.syncQueue} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
    return entry;
  }

  /// 本轮可推送的条目：`pending` 且退避已到期。
  ///
  /// ⚠️ **只取 `pending`** —— 不取 `sent`（已推送成功，只等 pull 确认），
  /// 也**不取 `failed`**：`retry_count > 10` 之后条目转死信，
  /// 按 `sync_protocol.md` §六 要「UI 提示人工处理」，
  /// **必须退出自动重试循环**（否则就是无限重试，只是越来越慢）。
  /// 人工处理完用 [requeue] 放回队列。
  List<SyncQueueEntry> due(int now, {int limit = 200}) => _raw
      .select(
        'SELECT * FROM ${Schema.syncQueue} '
        "WHERE status = '${SyncQueueStatus.pending.wire}' AND next_retry_at <= ? "
        'ORDER BY created_at, id LIMIT ?',
        <Object?>[now, limit],
      )
      .map(SyncQueueEntry.fromRow)
      .toList(growable: false);

  /// 把死信放回队列（人工处理之后调用）：重试计数清零、退避归零、清掉错误。
  void requeue(String id) => _raw.execute(
    'UPDATE ${Schema.syncQueue} SET status = ?, retry_count = 0, '
    'last_error = NULL, next_retry_at = 0 WHERE id = ?',
    <Object?>[SyncQueueStatus.pending.wire, id],
  );

  /// **挂起**（换主机时对「原本要发给别的主机」的条目，2026-10-07 裁定）：
  /// 转到 `failed`（UI 显示为「失败 M 条」）+ 写清原因 + 重试计数顶格
  /// （`maxRetries` 之上）⇒ **不再自动推送**，等用户自己决定要不要发给新主机
  /// （`requeue` 就放回队列）。
  ///
  /// 为什么不直接删：队列里是**用户刚开的单**，是手机端唯一真正会丢的数据
  /// （`docs/reply.md` §4）；推到**错的主机**才是真事故 —— 所以既不推也不删。
  void markHeld(String id, {required String reason}) => _raw.execute(
    'UPDATE ${Schema.syncQueue} SET status = ?, retry_count = 99, '
    'last_error = ?, next_retry_at = 0 WHERE id = ?',
    <Object?>[SyncQueueStatus.failed.wire, reason, id],
  );

  /// 全部**还没被主机收下**的条目（`pending` + `failed`）—— 换主机时要逐个挂起。
  List<SyncQueueEntry> unsent() => _raw
      .select(
        'SELECT * FROM ${Schema.syncQueue} WHERE status != ? '
        'ORDER BY created_at, id',
        <Object?>[SyncQueueStatus.sent.wire],
      )
      .map(SyncQueueEntry.fromRow)
      .toList(growable: false);

  SyncQueueEntry? findById(String id) {
    final ResultSet rows = _raw.select(
      'SELECT * FROM ${Schema.syncQueue} WHERE id = ?',
      <Object?>[id],
    );
    return rows.isEmpty ? null : SyncQueueEntry.fromRow(rows.first);
  }

  List<SyncQueueEntry> all() => _raw
      .select('SELECT * FROM ${Schema.syncQueue} ORDER BY created_at, id')
      .map(SyncQueueEntry.fromRow)
      .toList(growable: false);

  List<SyncQueueEntry> withStatus(SyncQueueStatus status) => _raw
      .select(
        'SELECT * FROM ${Schema.syncQueue} WHERE status = ? '
        'ORDER BY created_at, id',
        <Object?>[status.wire],
      )
      .map(SyncQueueEntry.fromRow)
      .toList(growable: false);

  /// **尚未被 pull 确认**的实体 id 集合（`pending` + `sent`）—— D2b 的 `isPending` 判定。
  ///
  /// 语义：`sent` 是「**主机已收下、但 pull 还没见到**」（见 [SyncQueueStatus.sent]），
  /// 所以它与 `pending` 一样属于「**未确认**」；`sent` 条目**只有在 pull 真的见到
  /// 该 id 后**才删（[clearConfirmed]）。
  ///
  /// ⚠️ `failed`（死信）**不算** —— 它要人工处理，混进来会让「待同步」常亮。
  ///
  /// 用途：镜像里的主数据行据此加一个**派生**的 `isPending` 标记 ——
  /// 界面要能区分「我有的」与「主机确认的」（`data_model.md §4.4` 第 3 条）。
  Set<String> unconfirmedEntityIds() => <String>{
    for (final SyncQueueEntry entry in <SyncQueueEntry>[
      ...withStatus(SyncQueueStatus.pending),
      ...withStatus(SyncQueueStatus.sent),
    ])
      entry.entityId,
  };

  /// **推送成功** → `sent`（⚠️ **不删除**，理由见 [SyncQueueStatus.sent]）
  void markSent(String id) => _raw.execute(
    'UPDATE ${Schema.syncQueue} SET status = ? WHERE id = ?',
    <Object?>[SyncQueueStatus.sent.wire, id],
  );

  /// 推送失败 → 记失败、累加重试、排下次退避时间。
  ///
  /// [dead] 为 `true` 时状态置 `failed`（死信，需人工处理）。
  void markFailed(
    String id, {
    required String error,
    required int retryCount,
    required int nextRetryAt,
    required bool dead,
  }) => _raw.execute(
    'UPDATE ${Schema.syncQueue} SET status = ?, retry_count = ?, '
    'last_error = ?, next_retry_at = ? WHERE id = ?',
    <Object?>[
      (dead ? SyncQueueStatus.failed : SyncQueueStatus.pending).wire,
      retryCount,
      error,
      nextRetryAt,
      id,
    ],
  );

  void delete(String id) =>
      _raw.execute('DELETE FROM ${Schema.syncQueue} WHERE id = ?', <Object?>[id]);

  /// **拉取确认**后清除已推送条目（R-14 附带问题 3）。
  ///
  /// [confirmedEntityIds] 是**本次 pull 实际见到的 id** ——
  /// 只清除「主机已交回」的那些，而不是清掉所有 `sent`。
  ///
  /// **为什么不是「pull 成功就清掉全部 `sent`」**：`pull` 是**分页**的。
  /// 刚 push 的那张单可能落在**本页之外**（seq_no 更大），
  /// 一刀切会把「主机已收下但我还没在权威状态里见到」的 delta 提前归零 ——
  /// 用户就会看到界面把刚卖掉的货又加回来。
  /// 按 id 确认则天然正确：没见到就留着，下次 pull 见到再清。
  ///
  /// 返回删除条数。
  int clearConfirmed(Set<String> confirmedEntityIds) {
    if (confirmedEntityIds.isEmpty) return 0;
    const int batch = 500; // IN 占位符数量受 SQLITE_MAX_VARIABLE_NUMBER 限制
    final List<String> ids = confirmedEntityIds.toList(growable: false);
    int removed = 0;
    for (int start = 0; start < ids.length; start += batch) {
      final int end = start + batch > ids.length ? ids.length : start + batch;
      final List<String> chunk = ids.sublist(start, end);
      _raw.execute(
        'DELETE FROM ${Schema.syncQueue} '
        "WHERE status = '${SyncQueueStatus.sent.wire}' AND entity_id IN "
        '(${List<String>.filled(chunk.length, '?').join(', ')})',
        chunk,
      );
      removed += _raw.updatedRows;
    }
    return removed;
  }

  int count() =>
      _raw.select('SELECT COUNT(*) AS n FROM ${Schema.syncQueue}').first['n']!
          as int;

  /// 三态条的判定依据（B3a，裁定 ④）。
  ///
  /// ⚠️ **「已同步」≠「队列为空」**：`sent` 条目还在队列里（等 pull 确认），
  /// 但主机**已经收下** —— 用户不该看到「待同步」。
  /// 所以判定是「没有 `pending` 和 `failed`」，`sent` **不显示**。
  SyncQueueTriage counts() {
    final ResultSet rows = _raw.select(
      'SELECT status, COUNT(*) AS n FROM ${Schema.syncQueue} '
      "WHERE status != '${SyncQueueStatus.sent.wire}' GROUP BY status",
    );
    int pending = 0;
    int failed = 0;
    for (final Row row in rows) {
      switch (SyncQueueStatus.fromWire(row['status']! as String)) {
        case SyncQueueStatus.pending:
          pending = row['n']! as int;
        case SyncQueueStatus.failed:
          failed = row['n']! as int;
        case SyncQueueStatus.sent:
          break; // WHERE 已排除；留着是穷举完整性
      }
    }
    return SyncQueueTriage(pendingCount: pending, failedCount: failed);
  }
}

/// 三态条的判定结果（B3a·裁定 ④）—— `SyncQueueDao.counts()` 的返回。
///
/// 明细列表用现成的 [SyncQueueDao.withStatus]（`pending` / `failed` 各一查）。
class SyncQueueTriage {
  const SyncQueueTriage({required this.pendingCount, required this.failedCount});

  /// `pending` 条数 = 「待同步 N 条」的 N。
  final int pendingCount;

  /// `failed`（死信）条数 = 「失败 M 条」的 M —— 与待同步**并列**，不互相覆盖。
  final int failedCount;

  /// 「已同步」= 没有 `pending` 和 `failed`（`sent` 不算 —— 主机已收下）。
  bool get isSynced => pendingCount == 0 && failedCount == 0;

  @override
  String toString() => 'SyncQueueTriage(pending: $pendingCount, failed: $failedCount)';
}

/// 时钟偏移（`docs/data_model.md` §4.2，单行表）。
///
/// `offset_ms = server_time - client_time`：离线期间用
/// `client_time + offset` **估算** `occurred_at`，并标记 `time_estimated = 1`
/// （`sync_protocol.md` §七）。
class ClockOffsetDao {
  ClockOffsetDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  /// 无记录时返回 `0`（= 尚未配对，按「时钟一致」处理）
  int get offsetMs {
    final ResultSet rows = _raw.select(
      'SELECT offset_ms FROM ${Schema.clockOffset} WHERE id = 1',
    );
    return rows.isEmpty ? 0 : rows.first['offset_ms']! as int;
  }

  void set(int offsetMs, {required int now}) => _raw.execute(
    'INSERT INTO ${Schema.clockOffset} (id, offset_ms, updated_at) '
    'VALUES (1, ?, ?) '
    'ON CONFLICT(id) DO UPDATE SET '
    'offset_ms = excluded.offset_ms, updated_at = excluded.updated_at',
    <Object?>[offsetMs, now],
  );
}
