import '../db/schema.dart';
import '../util/ids.dart';
import 'base.dart';
import 'document.dart';

/// 单据明细（业务数据，不可变）
///
/// ⚠️ `quantity` 的语义**按 `doc_type` 分支**（见 `docs/data_model.md` §3.2）：
/// - 一般单据：交易数量（正数）
/// - `stocktake`：**盘点后的实际数量**，不是差额
///
/// 消费端必须按 `doc_type` 分支处理，否则会误算。
class DocumentLine extends ImmutableEntity {
  const DocumentLine({
    required this.id,
    required this.documentId,
    required this.productId,
    required this.quantity,
    required this.unitPrice,
    required this.amount,
    this.remark,
  });

  /// 由数量与单价算出 `amount`（`docs/rules.md`：`amount = quantity × unit_price`）
  factory DocumentLine.create({
    required String documentId,
    required String productId,
    required int quantity,
    required int unitPrice,
    String? remark,
  }) => DocumentLine(
    id: newId(),
    documentId: documentId,
    productId: productId,
    quantity: quantity,
    unitPrice: unitPrice,
    amount: quantity * unitPrice,
    remark: remark,
  );

  factory DocumentLine.fromRow(Map<String, Object?> row) => DocumentLine(
    id: row.requiredString('id'),
    documentId: row.requiredString('document_id'),
    productId: row.requiredString('product_id'),
    quantity: row.requiredInt('quantity'),
    unitPrice: row.requiredInt('unit_price'),
    amount: row.requiredInt('amount'),
    remark: row.optionalString('remark'),
  );

  static const String table = Schema.documentLines;

  @override
  final String id;
  final String documentId;
  final String productId;
  final int quantity;
  final int unitPrice;
  final int amount;
  final String? remark;

  @override
  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'document_id': documentId,
    'product_id': productId,
    'quantity': quantity,
    'unit_price': unitPrice,
    'amount': amount,
    'remark': remark,
  };
}

/// `document_lines.amount` 之和。
///
/// ⚠️ **对 `receipt` / `payment` / `stocktake` 不适用** ——
/// 它们的 `lines` 为空（收付款单的核销分配不在明细里）或语义不同，
/// 见 `docs/data_model.md` §五 不变量 5。
bool linesAmountMatchesTotal(Document doc, int linesAmount) {
  switch (doc.docType) {
    case DocType.stocktake:
    case DocType.receipt:
    case DocType.payment:
      return true;
    default:
      return linesAmount == doc.totalAmount;
  }
}
