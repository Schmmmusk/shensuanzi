import '../db/schema.dart';

/// **表名 / 列名白名单**（`docs/sync_protocol.md` §8.4、`Agents.md` 纪律 10）。
///
/// > 服务端拼 SQL **必须先过表名 / 列名白名单**。`op.entity` 与 `op.payload.keys`
/// > 一律校验。**拒绝一切不在白名单内的输入。**
///
/// 本类是那张白名单的**唯一实现**。任何新表 / 新列要允许客户端写，
/// 必须在这里加，并同步 `docs/sync_protocol.md` §8.4。
class SyncWhitelist {
  SyncWhitelist._();

  /// 客户端可以 create / update / delete 的表（主数据）
  static const Set<String> writableTables = <String>{
    Schema.products,
    Schema.parties,
    Schema.accounts,
    Schema.documents,
  };

  /// **主机专属列** —— 客户端永远不能写。出现即 `rejected`。
  ///
  /// | 列 | 为什么 |
  /// |---|---|
  /// | `created_at` / `updated_at` | 主机时钟（`sync_protocol.md` §七） |
  /// | `sync_version` | 主机乐观锁计数，由 `base_version + 1` 推出 |
  /// | `seq_no` | 主机在事务内分配（`Agents.md` 纪律 5） |
  /// | `paid_amount` | 派生缓存，真相是 `SUM(settlements.amount)` |
  static const Set<String> hostOnlyColumns = <String>{
    'created_at',
    'updated_at',
    'sync_version',
    'seq_no',
    'paid_amount',
  };

  /// 每张表客户端**可写**的列。
  ///
  /// 不含 [hostOnlyColumns]；`documents` 不含 `paid_amount`。
  static const Map<String, Set<String>> columns = <String, Set<String>>{
    Schema.products: <String>{
      'id',
      'code',
      'name',
      'barcode',
      'unit',
      'cost_price',
      'sell_price',
      'safety_stock',
      'category',
      'is_active',
      'remark',
      'package_note',
    },
    Schema.parties: <String>{
      'id',
      'name',
      'phone',
      'address',
      'roles',
      'credit_limit',
      'is_active',
      'remark',
    },
    Schema.accounts: <String>{'id', 'name', 'type', 'initial_balance', 'is_active'},
    Schema.documents: <String>{
      'id',
      'doc_no',
      'doc_type',
      'status',
      'party_id',
      'account_id',
      'total_amount',
      'ref_doc_id',
      'occurred_at',
      'time_estimated',
      'remark',
    },
    Schema.documentLines: <String>{
      'id',
      'document_id',
      'product_id',
      'quantity',
      'unit_price',
      'amount',
      'remark',
    },
  };

  /// 主数据表（`createMasterData` / `updateMasterData` / `deleteMasterData` 的目标）
  static const Set<String> masterDataTables = <String>{
    Schema.products,
    Schema.parties,
    Schema.accounts,
  };

  static bool isMasterData(String table) => masterDataTables.contains(table);

  static bool isWritableTable(String table) => writableTables.contains(table);

  static bool isAllowedColumn(String table, String column) =>
      columns[table]?.contains(column) ?? false;

  /// 找出 [keys] 中所有**不允许写入**的列；全合法时返回空列表。
  ///
  /// 返回值把「主机专属列」和「未知列」分开报，方便定位问题。
  static List<String> offendingColumns(
    String table,
    Iterable<String> keys, {
    bool includeHostOnly = true,
  }) {
    final Set<String>? allowed = columns[table];
    if (allowed == null) return keys.toList(growable: false);
    return <String>[
      for (final String key in keys)
        if (!allowed.contains(key) &&
            (includeHostOnly || !hostOnlyColumns.contains(key)))
          key,
    ];
  }
}

/// wire 值的**类型规整**。
///
/// wire 约定是「值 = `toRow()` 的形态」（整数分 / 毫秒 / `0|1`），
/// 但客户端是手写 JSON 的，可能塞进 `double`、`bool` 或嵌套对象。
/// **在拼 SQL 之前规整 / 拦住**，否则 SQLite 会以晦涩的绑定错误拒绝。
///
/// - `null` / `int` / `String` → 原样
/// - `double` 且**是整数值**（如 `3000.0`）→ 转 `int`（JSON 没有整数/小数之分）
/// - 其余（含 `bool`）→ 抛 [FormatException]，由 `SyncServer` 转成 `rejected`
///
/// 为什么不接受 `bool`：wire 约定布尔用 `1` / `0`。收下 `true` 等于让
/// 客户端**以为自己写对了**，而 `PARTIES.roles` 这类文本列会静默存成 `"true"`。
class SyncValueCheck {
  SyncValueCheck._();

  static Map<String, Object?> normalize(Map<String, Object?> raw) {
    final Map<String, Object?> out = <String, Object?>{};
    raw.forEach((String key, Object? value) {
      if (value == null || value is int || value is String) {
        out[key] = value;
        return;
      }
      if (value is double && value == value.roundToDouble()) {
        out[key] = value.toInt();
        return;
      }
      throw FormatException(
        '列 `$key` 的值类型不合法：${value.runtimeType}。'
        'wire 约定「值 = toRow() 的形态」：金额 / 数量 / 时间用整数，'
        '布尔用 1 / 0（不要用 true / false）',
      );
    });
    return out;
  }
}
