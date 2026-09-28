/// 期初录入的**表单草稿**（原文 + 纯函数校验）。
///
/// 与 `PurchaseDraft` 同构：字段保留**用户敲的原文**，校验与解析分开 ——
/// 字段不合法时原文还在，用户改一个字就行；校验是纯函数，`dart test` 钉得住。
///
/// ## 对应的 core 规则（本类**不重复实现**，只做「表单门槛」）
///
/// | 能力 | 归属 |
/// |---|---|
/// | 差额流水 / 盘盈成本 / 落库 | `RuleEngine._stocktake`（RULE-009，规则层覆盖） |
/// | 正式单号（`PD` 前缀） | `RuleEngine._prepare`（主机生成） |
/// | 成本口径（无历史 → 0） | `CostPolicy.surplusCost`（AB-2 裁定） |
///
/// ## 校验口径（§AD 裁定）
///
/// - **空行忽略**：商品和数量都没填的行不参与本次盘点（UI「加一行」后没填
///   不算错 —— 与采购页「空行报错」刻意不同：这里多加行是常态，删行的
///   操作成本反而高）
/// - 选了商品 ⇒ 数量必填**正整数**；填了数量 ⇒ 商品必选
/// - **同商品不重复**（AD-3）：盘点语义下「同一商品的两次实际数量」无法合并
///   —— 与采购的成本累加语义本质不同
///
/// ## 「实际有多少」语义（AB-3）
///
/// 数量是**实际数量**，不是新进数量。已录过的商品再录一遍，效果是把库存
/// **改回去**（diff = 0 无变化），不是累加 —— UI 必须显示账面数与差额。
library;

import '../models/product.dart';

/// 期初录入一行明细的草稿。
class StocktakeLineDraft {
  const StocktakeLineDraft({
    this.productId = '',
    this.productName = '',
    this.quantity = '',
  });

  /// 从商品带入：数量留空待填（期初没有「参考进价」可预填 —— 成本按 0，AB-2）
  factory StocktakeLineDraft.fromProduct(Product product) => StocktakeLineDraft(
    productId: product.id,
    productName: product.name,
  );

  final String productId;
  final String productName;

  /// 用户敲的原文。**空 = 该行不参与本次盘点**（裁定：填了才算）
  final String quantity;

  StocktakeLineDraft copyWith({
    String? productId,
    String? productName,
    String? quantity,
  }) => StocktakeLineDraft(
    productId: productId ?? this.productId,
    productName: productName ?? this.productName,
    quantity: quantity ?? this.quantity,
  );

  /// 空行 = 商品和数量都没填。**空行不报错、不参与盘点**（见类注释校验口径）。
  bool get isEmpty => productId.isEmpty && quantity.trim().isEmpty;

  /// 行内校验。`null` = 通过（含空行）；非 `null` = 给用户看的一句话。
  ///
  /// 同商品重复是**跨行**约束，在 [StocktakeDraft.validate] 里查。
  String? validate() {
    if (isEmpty) return null;
    if (productId.isEmpty) return '请选一个商品';
    final String qtyText = quantity.trim();
    if (qtyText.isEmpty) return '请填数量，填店里实际有多少';
    final int? qty = int.tryParse(qtyText);
    if (qty == null || qty <= 0) return '数量要填正整数，比如 10';
    return null;
  }

  /// 数量取值；非法或未填时 `null`（调用方应先 [StocktakeDraft.validate]）
  int? get quantityValue {
    final int? qty = int.tryParse(quantity.trim());
    return (qty == null || qty <= 0) ? null : qty;
  }

  @override
  String toString() =>
      'StocktakeLineDraft($productName, qty=${quantity.isEmpty ? '（未填）' : quantity})';
}

/// 校验结果：主单级一句话 + **行下标 → 错误**（界面按行标红）。
class StocktakeValidation {
  const StocktakeValidation({
    this.topError,
    this.lineErrors = const <int, String>{},
  });

  /// 整页级错误（如「一行都没填」）；`null` = 无
  final String? topError;

  /// 行级错误，键 = [StocktakeDraft.lines] 的下标
  final Map<int, String> lineErrors;

  bool get isValid => topError == null && lineErrors.isEmpty;
}

/// 期初录入草稿（主单）。
class StocktakeDraft {
  const StocktakeDraft({this.lines = const <StocktakeLineDraft>[]});

  final List<StocktakeLineDraft> lines;

  StocktakeDraft copyWith({List<StocktakeLineDraft>? lines}) =>
      StocktakeDraft(lines: lines ?? this.lines);

  /// 参与盘点的行（非空行）。空行忽略 —— 只增行的录入方式里，「删干净」
  /// 不应该是提交的前置动作。
  List<StocktakeLineDraft> get filledLines =>
      lines.where((StocktakeLineDraft line) => !line.isEmpty).toList();

  // ------------------------------------------------------------ 校验

  /// 校验。**通过后** [toActualQuantities] 才有定义。
  StocktakeValidation validate() {
    final List<StocktakeLineDraft> filled = filledLines;

    // 一行都没填（或全是空行）→ 整页级拦截
    if (filled.isEmpty) {
      return const StocktakeValidation(
        topError: '至少要填一行：选商品，填店里实际有多少',
      );
    }

    final Map<int, String> lineErrors = <int, String>{};
    final Set<String> seen = <String>{};
    for (int i = 0; i < lines.length; i++) {
      final StocktakeLineDraft line = lines[i];
      if (line.isEmpty) continue; // 空行忽略，不占错误位

      final String? error = line.validate();
      if (error != null) {
        lineErrors[i] = error;
        continue; // 行本身不合法时不参与重复判定
      }

      // AD-3：同商品只允许一行 —— 文案说「怎么办」（ui_principles.md §5）
      if (!seen.add(line.productId)) {
        lineErrors[i] = '这个商品已经在上面了，改上面那一行就行';
      }
    }

    return StocktakeValidation(topError: null, lineErrors: lineErrors);
  }

  bool get isValid => validate().isValid;

  // ------------------------------------------------------------ 取值（校验通过后）

  /// 「填了数量的行」→ `商品 → 实际数量`，即 RULE-009 的 `stocktakeActual`。
  /// 未填的行不参与本次盘点（裁定原文）。
  Map<String, int> toActualQuantities() => <String, int>{
    for (final StocktakeLineDraft line in filledLines)
      if (line.quantityValue != null) line.productId: line.quantityValue!,
  };

  /// 参与盘点的商品数（确认弹窗「即将记录 N 件商品」，§AD-5 裁定）
  int get filledCount => filledLines.length;

  @override
  String toString() => 'StocktakeDraft(${lines.length} 行，'
      '其中 ${filledLines.length} 行参与盘点)';
}
