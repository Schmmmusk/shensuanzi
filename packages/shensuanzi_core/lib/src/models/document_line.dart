import '../db/schema.dart';
import '../util/ids.dart';
import '../util/money.dart';
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
    this.discountAmount = 0,
    this.entryQuantity,
    this.entryUnit,
    this.remark,
  });

  /// 多形态工厂（v3）—— `amount` 是**真相**（这一行真正发生多少钱，
  /// 让价已含；`docs/data_model.md` §3.2 第 5/6 条），`unit_price` 是派生展示。
  ///
  /// | 给什么 | 得到什么 | 用途 |
  /// |---|---|---|
  /// | 只给 `quantity + unitPrice` | `amount = qty × price`（v2 等价形态） | 无让价 / 既有调用 |
  /// | 给 `amount`（`unitPrice` 缺省） | `unitPrice = round(amount / quantity)` | 让价行 / 按箱录入 |
  /// | 给 `entryQuantity` / `entryUnit` | 原样落库 | 记录入原文 |
  ///
  /// 两者都缺 ⇒ `ArgumentError`（总得给一个算钱的依据）。
  /// `entryQuantity` 缺省 = [quantity]（没切单位时录入原文就是最小单位数量，
  /// §BD·三 第 2 条）；**旧行**（v2 迁移来）两列在库里是 `NULL`，不经此工厂。
  factory DocumentLine.create({
    required String documentId,
    required String productId,
    required int quantity,
    int? unitPrice,
    int? amount,
    int? entryQuantity,
    String? entryUnit,
    int discountAmount = 0,
    String? remark,
  }) {
    if (unitPrice == null && amount == null) {
      throw ArgumentError('unitPrice 与 amount 至少给一个（总得有算钱的依据）');
    }
    final int resolvedAmount = amount ?? quantity * unitPrice!;
    final int resolvedUnitPrice = unitPrice ??
        (quantity > 0
            ? Money.divideRoundHalfUp(resolvedAmount, quantity)
            : resolvedAmount);
    return DocumentLine(
      id: newId(),
      documentId: documentId,
      productId: productId,
      quantity: quantity,
      unitPrice: resolvedUnitPrice,
      amount: resolvedAmount,
      discountAmount: discountAmount,
      entryQuantity: entryQuantity ?? quantity,
      entryUnit: entryUnit,
      remark: remark,
    );
  }

  factory DocumentLine.fromRow(Map<String, Object?> row) => DocumentLine(
    id: row.requiredString('id'),
    documentId: row.requiredString('document_id'),
    productId: row.requiredString('product_id'),
    quantity: row.requiredInt('quantity'),
    unitPrice: row.requiredInt('unit_price'),
    amount: row.requiredInt('amount'),
    discountAmount: row.optionalInt('discount_amount') ?? 0,
    entryQuantity: row.optionalInt('entry_quantity'),
    entryUnit: row.optionalString('entry_unit'),
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

  /// **让价**（分、正数、默认 0）—— 这一行让掉多少，`amount` 已减它
  /// （`docs/data_model.md` §3.2 第 6 条）。v3 新增；旧行 `NULL` ⇒ 0。
  final int discountAmount;

  /// **录入原文数量**（§BD·三 第 2 条）—— 输入框里那个数字。
  /// 新行恒填（没切单位 = [quantity]）；**旧行**（v2 迁移）为 `NULL`。
  /// 落库后不参与派生计算，但它是展示反推（原始报价）的来源。
  final int? entryQuantity;

  /// **录入原文单位**（三态：`null` / `products.unit` / `products.package_unit`，
  /// 取包装单位前提 = 成对启用）—— 落库后不参与派生计算，
  /// 但落库当时它是 `toBaseQuantity` 的输入。**旧行**为 `NULL`。v3 新增。
  final String? entryUnit;
  final String? remark;

  @override
  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'document_id': documentId,
    'product_id': productId,
    'quantity': quantity,
    'unit_price': unitPrice,
    'amount': amount,
    'discount_amount': discountAmount,
    'entry_quantity': entryQuantity,
    'entry_unit': entryUnit,
    'remark': remark,
  };
}

/// `document_lines.amount` 之和。
///
/// ⚠️ **对 `receipt` / `payment` / `stocktake` 不适用** ——
/// 它们的 `lines` 为空（收付款单的核销分配不在明细里）或语义不同，
/// 见 `docs/data_model.md` §五 不变量 5。
///
/// ⚠️ **v3 起本不变量只守列级 `Σ amount = total_amount`，不守行级
/// `amount = quantity × unit_price`** —— 让价（`discount_amount`）使行级乘积
/// 不再成立（`data_model.md` §3.2 第 5 条 / §AY·一 解除严格约束）。
/// 消费端**不许**用 `unit_price` 重算金额（导出取 `amount`，见 §BD·四）。
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
