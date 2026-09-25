/// 拉取协议（`docs/sync_protocol.md` §8.2）—— **纯 DTO，无传输实现**。
///
/// 放在 core 而不是 host：客户端也要**解析游标、拼接下一页请求**，
/// 所以游标编解码必须两端共用同一份实现。
library;

import '../db/schema.dart';

/// 拉取游标的键（= §8.2 的查询参数名，也是 `next_cursors` 的键）。
///
/// ⚠️ **没有 `line_since`** —— `document_lines` 随主单同页返回，
/// 见 [SyncPullResult] 的文档。
///
/// 后三个是 **R-13 方案 A**（2026-09-25 裁定）加的：主数据也并入 `pull`，
/// 不再依赖 §8.3 那组**没有游标**的 REST 接口。
class SyncCursorKeys {
  SyncCursorKeys._();

  // ---- 业务数据：四张流水用 seq_no，documents 用 (created_at, id)
  static const String stock = 'stock_since';
  static const String money = 'money_since';
  static const String party = 'party_since';
  static const String settle = 'settle_since';
  static const String doc = 'doc_since';

  // ---- 主数据：一律 (updated_at, id)
  static const String products = 'products_since';
  static const String parties = 'parties_since';
  static const String accounts = 'accounts_since';

  /// 全部键（顺序与 §8.2 一致）
  static const List<String> all = <String>[
    stock,
    money,
    party,
    settle,
    doc,
    products,
    parties,
    accounts,
  ];
}

/// 复合游标：`"<时间戳>|<id>"`。
///
/// **为什么不能只用一个时间戳**：它**不唯一**。用 `>` 会丢掉同一毫秒里
/// 剩下的行；用 `>=` 又会在「同一毫秒的行数 > `limit`」时**永远取回同一页**
/// （死循环）。复合游标是唯一既**不丢行**又能**保证推进**的方案。
///
/// 时间戳那一半取自哪个列**由表决定**（[stamp] 只表示「游标列的值」）：
///
/// | 表 | 游标列 | 为什么 |
/// |---|---|---|
/// | `documents` | `created_at` | 单据不可变，创建即出现 |
/// | `products` / `parties` / `accounts` | `updated_at` | 主数据**会被改**，`created_at` 感知不到修改 |
///
/// 四张流水表相反：`seq_no` 本身唯一且单调，所以那些表的游标就是整数字符串。
/// 两者在 wire 上统一为**字符串**（HTTP 查询串本来就是字符串）。
class SyncCursor {
  const SyncCursor(this.stamp, this.id);

  /// 起始游标（游标缺省时用）
  static const SyncCursor start = SyncCursor(0, '');

  /// 游标列的值：`documents` 是 `created_at`，主数据是 `updated_at`
  final int stamp;
  final String id;

  static SyncCursor parse(String? raw) {
    if (raw == null || raw.isEmpty) return start;
    final int bar = raw.indexOf('|');
    if (bar < 0) {
      throw FormatException(
        '游标格式应为 "<时间戳>|<id>"（如 "1700000000000|0192…"），实际 "$raw"',
      );
    }
    return SyncCursor(int.parse(raw.substring(0, bar)), raw.substring(bar + 1));
  }

  String get wire => '$stamp|$id';

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

  /// 响应体里的 9 个实体（顺序即 §8.2 的字段顺序）。
  ///
  /// **单一定义**：host 据此拼响应，测试据此断言「恰好 9 个」——
  /// 加实体时只改这里一处，两边同时被推动（**加漏会立刻打穿断言**）。
  static const List<String> entityNames = <String>[
    Schema.documents,
    Schema.documentLines,
    Schema.stockLedger,
    Schema.moneyLedger,
    Schema.partyLedger,
    Schema.settlements,
    Schema.products,
    Schema.parties,
    Schema.accounts,
  ];

  /// 主数据实体（= [entityNames] 的后三个）
  static const Set<String> masterDataEntities = <String>{
    Schema.products,
    Schema.parties,
    Schema.accounts,
  };

  final Map<String, List<Map<String, Object?>>> entities;

  /// 下一页游标。**键是字符串**：流水表是整数字符串，
  /// `documents` 与主数据是 `"<时间戳>|<id>"` 复合游标。
  final Map<String, String> nextCursors;

  int countOf(String entity) => entities[entity]?.length ?? 0;

  Map<String, Object?> toJson() => <String, Object?>{
    ...entities,
    'next_cursors': nextCursors,
  };
}
