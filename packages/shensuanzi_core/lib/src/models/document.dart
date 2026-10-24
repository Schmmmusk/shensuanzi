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

  /// 允许 UPDATE 的列 —— 唯一白名单（`Agents.md` 纪律 3）
  static const Set<String> updatableColumns = <String>{
    'status',
    'paid_amount',
    'updated_at',
  };

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
  /// [updatableColumns] 白名单里）。用途：客户端离线开的单只有临时展示号，
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
