import '../db/read_failures.dart';
import '../db/schema.dart';
import 'base.dart';

/// 单据类型，见 `docs/data_model.md` §3.1
enum DocType {
  purchase('purchase', '采购入库'),
  sale('sale', '店内销售'),
  delivery('delivery', '送货'),
  saleReturn('sale_return', '销售退货'),
  purchaseReturn('purchase_return', '采购退货'),
  stocktake('stocktake', '盘点'),
  receipt('receipt', '收款'),
  payment('payment', '付款'),
  transfer('transfer', '调拨');

  const DocType(this.wire, this.label);

  /// 落库值
  final String wire;

  /// 中文名（仅用于日志与调试；UI 文案走 i18n）
  final String label;

  /// 严格版：**不认识就抛**。用于 **wire 报文校验**（畸形请求要拒绝）。
  static DocType fromWire(String value) => DocType.values.firstWhere(
    (DocType type) => type.wire == value,
    orElse: () => throw ArgumentError('未知单据类型：$value'),
  );

  /// **读库用**（#42 甲 · L2）：未知值 ⇒ `null`，**不抛**。
  /// ⚠️ 调用方（[Document.fromRow]）遇到 `null` **只能跳过该行** ——
  /// **单据类型决定一切**（金额符号、成本口径、列表分组），猜错比看不见更坏。
  static DocType? fromWireOrNull(String value) {
    for (final DocType type in DocType.values) {
      if (type.wire == value) return type;
    }
    return null;
  }
}

/// 当前版本**规则层已实现**的单据类型。
///
/// `transfer`（调拨）在枚举里存在（为将来预留、老库也可能有），但
/// `RuleEngine.dispatch()` 明确拒绝它（v1 不实现调拨）。
///
/// 所以消费方遇到它时，正确做法是**明说不支持**，而不是按「某种普通单据」
/// 硬套一套规则 —— 抢救器尤其如此：把一张本版本根本不支持的单据导进新库，
/// 等于给用户造了一张谁也看不懂、也没法继续操作的账（用户审查 2026-10-30）。
bool isSupportedDocType(DocType type) => type != DocType.transfer;

/// 单据状态
enum DocStatus {
  draft('draft'),
  confirmed('confirmed'),
  inTransit('in_transit'),
  delivered('delivered'),
  settled('settled'),
  cancelled('cancelled');

  const DocStatus(this.wire);

  final String wire;

  /// 严格版：**不认识就抛**。用于 **wire 报文校验**（畸形请求要拒绝）。
  static DocStatus fromWire(String value) => DocStatus.values.firstWhere(
    (DocStatus status) => status.wire == value,
    orElse: () => throw ArgumentError('未知单据状态：$value'),
  );

  /// **读库用**（#42 甲 · L2）：未知值 ⇒ `null`，**不抛**。
  ///
  /// 调用方兜底为 [confirmed]（**不是 `draft`**）—— 见 [Document.fromRow] 的说明。
  static DocStatus? fromWireOrNull(String value) {
    for (final DocStatus status in DocStatus.values) {
      if (status.wire == value) return status;
    }
    return null;
  }
}

/// **业务日**：把「发生时刻」折算成本地日的序号（自 1970-01-01 起的第几天）。
///
/// 公式与旧查询里的 `(occurred_at + 本地偏移) / 86400000` **逐字等价**，
/// 只是从「每次查询现算」变成「写入时算一次存下来」（v6 / 2026-10-29）。
///
/// ## 为什么要固化
///
/// 1. **性能**：旧写法是表达式排序，任何索引都用不上，26 万单上 `TEMP B-TREE`
///    要 **136.8 ms**；固化后 `ORDER BY business_day DESC, created_at DESC`
///    正好命中 `idx_docs_bday_created`，实测 **0.1 ms**。
/// 2. **时区不漂移**：旧写法依赖**查询时**的系统时区 —— 用户换了电脑或跨时区用一次，
///    全部历史单据的排序会跟着变。固化后历史永远不变（这比性能更值钱）。
///
/// ⚠️ 语义仍是「**本地日**」：主单 `occurred_at` 是当天 00:00，派生单是精确时刻，
/// 两者折到同一天就同一天（#26① 的口径没变）。
///
/// ⚠️ 负数（1970 年之前）行为与 SQLite 的整数除法略有差异（Dart 用 `floor`、
/// SQLite 向零截断）—— 本系统不会有 1970 前的单据，不做兼容。
int businessDayOf(int occurredAtMillis, {int? offsetMillis}) {
  final int offset =
      offsetMillis ??
      DateTime.fromMillisecondsSinceEpoch(
        occurredAtMillis,
      ).timeZoneOffset.inMilliseconds;
  return ((occurredAtMillis + offset) / 86400000).floor();
}

/// 单据主表（业务数据）。
///
/// ⚠️ **例外**：`documents` 是唯一的「部分可变」业务表 ——
/// 只允许 UPDATE `status` / `paid_amount` / `updated_at` 三列（`Agents.md` 纪律 3）。
/// 因此它实现 [ImmutableEntity] 但**没有** `sync_version`；
/// 唯一的写入口是 `DocumentDao.updateStatusAndPaid`。
class Document extends ImmutableEntity {
  const Document({
    required this.id,
    required this.docNo,
    required this.docType,
    required this.status,
    this.partyId,
    this.accountId,
    this.totalAmount = 0,
    this.paidAmount = 0,
    this.refDocId,
    required this.occurredAt,
    this.timeEstimated = false,
    required this.createdAt,
    required this.updatedAt,
    this.remark,
  });

  /// [failures] 记录「哪一列被兜底了」（不传 = 只兜底不记录）。
  ///
  /// **#42 的两个处置**（2026-10-14 裁定 §三）：
  ///
  /// | 列 | 认不出时 | 为什么 |
  /// |---|---|---|
  /// | `doc_type` | **抛 [RowDecodeException] ⇒ 跳过该行** | **类型决定一切**（金额符号 / 成本口径 / 列表分组），猜成 `sale` 会让报表口径错 —— 那比「看不见」更坏 |
  /// | `status` | **兜底 [DocStatus.confirmed]** | ⚠️ **不是 `draft`**：`draft` 在项目语义里是「未提交」（可能被筛掉、可能被当成草稿允许改）⇒ 兜底成它会让一张**真实存在的单看起来像没保存**。`confirmed` = 「已保存、未结清」才是安全的保守值 |
  factory Document.fromRow(
    Map<String, Object?> row, {
    ReadFailureLog? failures,
  }) {
    final String rawType = row.requiredString('doc_type');
    final DocType? docType = DocType.fromWireOrNull(rawType);
    if (docType == null) {
      throw RowDecodeException(
        column: 'doc_type',
        reason: '认不出的单据类型',
        value: rawType,
      );
    }
    final String rawStatus = row.requiredString('status');
    final DocStatus? status = DocStatus.fromWireOrNull(rawStatus);
    if (status == null) {
      failures?.record(
        table: Schema.documents,
        column: 'status',
        reason: '认不出的单据状态',
        value: rawStatus,
      );
    }
    return Document(
      id: row.requiredString('id'),
      docNo: row.requiredString('doc_no'),
      docType: docType,
      status: status ?? DocStatus.confirmed,
      partyId: row.optionalString('party_id'),
      accountId: row.optionalString('account_id'),
      totalAmount: row.requiredInt('total_amount'),
      paidAmount: row.requiredInt('paid_amount'),
      refDocId: row.optionalString('ref_doc_id'),
      occurredAt: row.requiredInt('occurred_at'),
      timeEstimated: row.requiredBool('time_estimated'),
      createdAt: row.requiredInt('created_at'),
      updatedAt: row.requiredInt('updated_at'),
      remark: row.optionalString('remark'),
    );
  }

  static const String table = Schema.documents;

  /// 客户端离线期的**临时展示号前缀**。
  /// 正式单号由主机生成（`Agents.md` 裁定表），客户端本地只能先占位。
  static const String pendingDocNoPrefix = '待同步-';

  /// 判断是否为临时展示号
  static bool isPendingDocNo(String docNo) =>
      docNo.isEmpty || docNo.startsWith(pendingDocNoPrefix);

  @override
  final String id;

  /// 正式单号，**由主机生成**（客户端离线期用 `待同步-XXXXXX` 临时展示号）
  final String docNo;
  final DocType docType;
  final DocStatus status;
  final String? partyId;
  final String? accountId;
  final int totalAmount;

  /// 已核销额（分）。**缓存字段**，真相是 `SUM(settlements.amount)`。
  final int paidAmount;
  final String? refDocId;
  final int occurredAt;

  /// `true` = 时间由客户端离线估算（审计用途，主机保留该标记）
  final bool timeEstimated;
  final int createdAt;
  final int updatedAt;
  final String? remark;

  @override
  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'doc_no': docNo,
    'doc_type': docType.wire,
    'status': status.wire,
    'party_id': partyId,
    'account_id': accountId,
    'total_amount': totalAmount,
    'paid_amount': paidAmount,
    'ref_doc_id': refDocId,
    'occurred_at': occurredAt,
    'time_estimated': boolToInt(timeEstimated),
    'created_at': createdAt,
    'updated_at': updatedAt,
    'remark': remark,
    // v6：业务日固化（见 [businessDayOf] 的说明）。
    // ⚠️ 这里**每次都重算**（而不是从实体取）：`Document` 不持有该字段，
    // 它是由 `occurred_at` 派生的 —— 多存一份在实体里就多一个能不一致的来源。
    'business_day': businessDayOf(occurredAt),
  };

  /// 复制并替换**白名单内**的字段（`updated_at` 由调用方给，避免隐式取当前时间）
  Document copyWithAllowed({
    DocStatus? status,
    int? paidAmount,
    int? updatedAt,
  }) => Document(
    id: id,
    docNo: docNo,
    docType: docType,
    status: status ?? this.status,
    partyId: partyId,
    accountId: accountId,
    totalAmount: totalAmount,
    paidAmount: paidAmount ?? this.paidAmount,
    refDocId: refDocId,
    occurredAt: occurredAt,
    timeEstimated: timeEstimated,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    remark: remark,
  );

  /// 主机落库前重写「只有主机能决定的字段」。
  ///
  /// ⚠️ 这**不是** UPDATE —— 它是 `INSERT` 前的一次性赋值（`doc_no` 根本不在
  /// 白名单三列里，见 `Agents.md` 纪律 3）。用途：客户端离线开的单只有临时展示号，
  /// 主机在事务内分配正式单号与主机时钟后写入。
  Document withHostAssigned({
    required String docNo,
    required int createdAt,
    required int updatedAt,
    int? occurredAt,
    DocStatus? status,
  }) => Document(
    id: id,
    docNo: docNo,
    docType: docType,
    status: status ?? this.status,
    partyId: partyId,
    accountId: accountId,
    totalAmount: totalAmount,
    paidAmount: paidAmount,
    refDocId: refDocId,
    occurredAt: occurredAt ?? this.occurredAt,
    timeEstimated: timeEstimated,
    createdAt: createdAt,
    updatedAt: updatedAt,
    remark: remark,
  );
}
