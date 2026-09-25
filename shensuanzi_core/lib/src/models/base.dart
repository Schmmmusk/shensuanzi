/// 实体基类：把「不可变」与「主数据可变」的区分**落实到类型系统**。
///
/// 见 `docs/data_model.md` §二 / §三 与 `Agents.md` 纪律 2、3。
///
/// 这不是命名约定，而是**编译期防线**：DAO 只对 [MutableEntity] 暴露 `update*`，
/// 不可变实体连方法都不存在 —— 想 UPDATE 都写不出来。
library;

/// 业务数据：**只插入，不更新，不删除**。
///
/// 对应表：`documents` / `document_lines` / `stock_ledger` /
/// `money_ledger` / `party_ledger` / `settlements`。
abstract class ImmutableEntity {
  const ImmutableEntity();

  String get id;

  /// 供 `INSERT` 使用。列名必须是 `docs/data_model.md` 里的字段名。
  Map<String, Object?> toRow();
}

/// 主数据：允许 UPDATE，受 `sync_version` 乐观锁保护。
///
/// 对应表：`products` / `parties` / `accounts`。
abstract class MutableEntity extends ImmutableEntity {
  const MutableEntity();

  /// 乐观锁版本。成功 UPDATE 后 +1（由 SyncServer 统一处理，见 `docs/sync_protocol.md` §四）。
  int get syncVersion;

  /// 用新的 `sync_version` 复制一份（字段不可变，故返回新实例）。
  MutableEntity withSyncVersion(int version);
}

/// `bool` → SQLite 的 `INTEGER`（0/1）
int boolToInt(bool value) => value ? 1 : 0;

/// 行读取辅助：把类型转换集中在一处，避免每个 `fromRow` 各写一遍。
///
/// 方法名刻意区分 `required*` 与 `optional*` —— 对应 `docs/data_model.md` 里
/// 列是否可空，读错会在运行期立刻炸而不是静默变成 `null`。
extension RowReader on Map<String, Object?> {
  String requiredString(String column) => this[column]! as String;

  String? optionalString(String column) => this[column] as String?;

  int requiredInt(String column) => this[column]! as int;

  int? optionalInt(String column) => this[column] as int?;

  bool requiredBool(String column) => (this[column]! as int) != 0;
}
