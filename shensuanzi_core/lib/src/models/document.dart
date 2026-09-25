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

  static DocType fromWire(String value) => DocType.values.firstWhere(
    (DocType type) => type.wire == value,
    orElse: () => throw ArgumentError('未知单据类型：$value'),
  );
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

  static DocStatus fromWire(String value) => DocStatus.values.firstWhere(
    (DocStatus status) => status.wire == value,
    orElse: () => throw ArgumentError('未知单据状态：$value'),
  );
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

  factory Document.fromRow(Map<String, Object?> row) => Document(
    id: row.requiredString('id'),
    docNo: row.requiredString('doc_no'),
    docType: DocType.fromWire(row.requiredString('doc_type')),
    status: DocStatus.fromWire(row.requiredString('status')),
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
  }) => Document(
    id: id,
    docNo: docNo,
    docType: docType,
    status: status,
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
