/// 拉取协议（`docs/sync_protocol.md` §8.2）—— **纯 DTO，无传输实现**。
///
/// 放在 core 而不是 host：客户端也要**解析游标、拼接下一页请求**，
/// 所以游标编解码必须两端共用同一份实现。
library;

/// 拉取游标的键（= §8.2 的查询参数名，也是 `next_cursors` 的键）。
///
/// ⚠️ **没有 `line_since`** —— `document_lines` 随主单同页返回，
/// 见 [SyncPullResult] 的文档。
class SyncCursorKeys {
  SyncCursorKeys._();

  static const String stock = 'stock_since';
  static const String money = 'money_since';
  static const String party = 'party_since';
  static const String settle = 'settle_since';
  static const String doc = 'doc_since';

  /// 全部键（顺序与 §8.2 一致）
  static const List<String> all = <String>[stock, money, party, settle, doc];
}

/// `documents` 的拉取游标：`"<created_at>|<id>"`。
///
/// **为什么不只用一个 `created_at`**：它**不唯一**。用 `>` 会丢掉同一毫秒里
/// 剩下的行；用 `>=` 又会在「同一毫秒的行数 > `limit`」时**永远取回同一页**
/// （死循环）。复合游标是唯一既**不丢行**又能**保证推进**的方案，
/// 而且与 `sync_protocol.md` §七「客户端按 `(created_at, id)` 排序」一致。
///
/// 四张流水表相反：`seq_no` 本身唯一且单调，所以那些表的游标就是整数字符串。
/// 两者在 wire 上统一为**字符串**（HTTP 查询串本来就是字符串）。
class SyncCursor {
  const SyncCursor(this.createdAt, this.id);

  /// 起始游标（`doc_since` 缺省时用）
  static const SyncCursor start = SyncCursor(0, '');

  final int createdAt;
  final String id;

  static SyncCursor parse(String? raw) {
    if (raw == null || raw.isEmpty) return start;
    final int bar = raw.indexOf('|');
    if (bar < 0) {
      throw FormatException(
        '游标格式应为 "<created_at>|<id>"（如 "1700000000000|0192…"），实际 "$raw"',
      );
    }
    return SyncCursor(int.parse(raw.substring(0, bar)), raw.substring(bar + 1));
  }

  String get wire => '$createdAt|$id';

  @override
  String toString() => wire;
}

/// 一次拉取的结果（§8.2 的响应体）。
///
/// [entities] 的键就是**表名**（与 §8.2 的响应字段一一对应）；
/// [nextCursors] 的键见 [SyncCursorKeys]。
///
/// ⚠️ **`document_lines` 没有独立游标** —— 它随「本页 `documents`」返回。
/// 理由：明细没有时间列（`data_model.md` §3.2），且与主单在同一事务里写入、
/// 永不单独存在。这正是 §8.2 只给了 `doc_since` 的原因。
class SyncPullResult {
  const SyncPullResult({required this.entities, required this.nextCursors});

  final Map<String, List<Map<String, Object?>>> entities;

  /// 下一页游标。**键是字符串**：流水表是整数字符串，`documents` 是复合游标。
  final Map<String, String> nextCursors;

  int countOf(String entity) => entities[entity]?.length ?? 0;

  Map<String, Object?> toJson() => <String, Object?>{
    ...entities,
    'next_cursors': nextCursors,
  };
}
