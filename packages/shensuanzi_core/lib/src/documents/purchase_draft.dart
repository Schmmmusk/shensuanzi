/// 采购开单的**表单草稿**（原文 + 纯函数校验）。
///
/// 与 `ProductDraft` 同构：字段保留**用户敲的原文**，校验与解析分开 ——
/// 字段不合法时原文还在，用户改一个字就行；校验是纯函数，`dart test` 钉得住。
///
/// ## 对应的 core 规则（本类**不重复实现**，只做「表单门槛」）
///
/// | 能力 | 归属 |
/// |---|---|
/// | 库存 / 往来 / 立即付款的落库 | `RuleEngine`（RULE-001，215 用例覆盖） |
/// | 正式单号 | `RuleEngine._prepare`（主机生成） |
/// | **散采现结**（无供应商 + 全款） | 合法（`immediate_payment_test.dart:331`） |
/// | **赊购必须有供应商** | `_requirePayee` —— 本类在表单层提前拦，文案说「怎么办」 |
///
/// ## 校验口径
///
/// - 明细 ≥ 1 行；每行商品必选、数量**正整数**、单价 ≥ 0 且最多两位小数
/// - 付款行：**金额留空 = 没有这笔付款**（默认「全赊」就是这么表达的）；
///   金额填了 ⇒ 账户必选且 > 0
/// - **散采**（未选供应商）且有欠款 ⇒ 报「散采要当场结清，或选一个供应商」
///   —— 这是 R-12 在 UI 层的表达，报出的错用户**照着做就能过**
///
/// 金额一律复用 `Money.tryParseYuan`（不走 double，最多两位小数）。
library;

import '../models/product.dart';
import '../util/money.dart';

/// 主单级字段（错误定位的键 —— 界面据此知道该标红哪一栏）
enum PurchaseField { party, date, lines, payments, remark }

/// 明细行字段
enum PurchaseLineField { product, quantity, unitPrice }

/// 立即付款行字段
enum PurchasePaymentField { account, amount }

/// 一行明细的草稿。
///
/// [unitPrice] 的**预填依据是 `products.cost_price`**（用户主动填的参考进价，
/// 见 `PurchaseLineDraft.fromProduct`），不做历史推算 —— 推算会引入用户
/// 没有预期过的值。
class PurchaseLineDraft {
  const PurchaseLineDraft({
    this.productId = '',
    this.productName = '',
    this.quantity = '',
    this.unitPrice = '',
  });

  /// 从商品带入：**单价预填进价**，数量留空待填。
  factory PurchaseLineDraft.fromProduct(Product product, {String quantity = ''}) =>
    PurchaseLineDraft(
      productId: product.id,
      productName: product.name,
      quantity: quantity,
      unitPrice: Money.format(product.costPrice),
    );

  final String productId;
  final String productName;

  /// 用户敲的原文
  final String quantity;
  final String unitPrice;

  PurchaseLineDraft copyWith({
    String? productId,
    String? productName,
    String? quantity,
    String? unitPrice,
  }) => PurchaseLineDraft(
    productId: productId ?? this.productId,
    productName: productName ?? this.productName,
    quantity: quantity ?? this.quantity,
    unitPrice: unitPrice ?? this.unitPrice,
  );

  /// 空行 = 三个字段都没填（UI「加一行」后还没填的状态）。
  /// **空行会照常报行级错误**（加了一行就得填或删）——
  /// [isEmpty] 只供服务层做防御性跳过，不参与校验。
  bool get isEmpty =>
      productId.isEmpty && quantity.trim().isEmpty && unitPrice.trim().isEmpty;

  Map<PurchaseLineField, String> validate() {
    final Map<PurchaseLineField, String> errors = <PurchaseLineField, String>{};

    if (productId.isEmpty) {
      errors[PurchaseLineField.product] = '请选一个商品';
    }

    final String qtyText = quantity.trim();
    if (qtyText.isEmpty) {
      errors[PurchaseLineField.quantity] = '请填数量，比如 10';
    } else {
      final int? qty = int.tryParse(qtyText);
      if (qty == null || qty <= 0) {
        errors[PurchaseLineField.quantity] = '数量要填正整数，比如 10';
      }
    }

    final String priceText = unitPrice.trim();
    if (priceText.isEmpty) {
      errors[PurchaseLineField.unitPrice] = '请填单价，比如 3.50';
    } else {
      final int? cents = Money.tryParseYuan(priceText);
      if (cents == null) {
        errors[PurchaseLineField.unitPrice] =
            '单价只能填数字，最多两位小数，比如 3.50';
      } else if (cents < 0) {
        errors[PurchaseLineField.unitPrice] = '单价不能是负数';
      }
    }
    return errors;
  }

  /// 数量取值；非法时 `null`（调用方应先 `validate`）
  int? get quantityValue {
    final int? qty = int.tryParse(quantity.trim());
    return (qty == null || qty <= 0) ? null : qty;
  }

  /// 单价取值（分）；非法时 `null`
  int? get unitPriceCents => Money.tryParseYuan(unitPrice.trim());

  /// 本行小计（分）；任一字段非法 ⇒ `null`
  int? get amountCents {
    final int? qty = quantityValue;
    final int? price = unitPriceCents;
    if (qty == null || price == null) return null;
    return qty * price;
  }

  @override
  String toString() =>
      'PurchaseLineDraft($productName, qty=$quantity, price=$unitPrice)';
}

/// 一条立即付款的草稿。
///
/// **金额留空 = 没有这笔付款**（UI 默认「全赊」就是靠这个表达），
/// 所以 [validate] 对空金额返回空 map；金额填了 ⇒ 账户必选且 > 0。
class PurchasePaymentDraft {
  const PurchasePaymentDraft({
    this.accountId = '',
    this.accountName = '',
    this.amount = '',
  });

  final String accountId;
  final String accountName;

  /// 用户敲的原文（元）
  final String amount;

  PurchasePaymentDraft copyWith({
    String? accountId,
    String? accountName,
    String? amount,
  }) => PurchasePaymentDraft(
    accountId: accountId ?? this.accountId,
    accountName: accountName ?? this.accountName,
    amount: amount ?? this.amount,
  );

  /// 金额留空 ⇒ 这一行**不参与**（默认「全赊」）
  bool get isBlank => amount.trim().isEmpty;

  Map<PurchasePaymentField, String> validate() {
    final Map<PurchasePaymentField, String> errors = <PurchasePaymentField, String>{};
    final String text = amount.trim();
    if (text.isEmpty) return errors; // 空行跳过，不报错

    if (accountId.isEmpty) {
      errors[PurchasePaymentField.account] = '请选一个资金账户';
    }
    final int? cents = Money.tryParseYuan(text);
    if (cents == null) {
      errors[PurchasePaymentField.amount] =
          '金额只能填数字，最多两位小数，比如 500';
    } else if (cents <= 0) {
      errors[PurchasePaymentField.amount] = '付款金额要大于 0';
    }
    return errors;
  }

  /// 金额取值（分）；留空或非法 ⇒ `null`
  int? get amountCents {
    final int? cents = Money.tryParseYuan(amount.trim());
    if (cents == null || cents <= 0) return null;
    return cents;
  }

  @override
  String toString() => 'PurchasePaymentDraft($accountName, $amount)';
}

/// 采购开单草稿（主单）。
class PurchaseDraft {
  const PurchaseDraft({
    this.partyId,
    this.partyName = '',
    this.date = '',
    this.remark = '',
    this.lines = const <PurchaseLineDraft>[],
    this.payments = const <PurchasePaymentDraft>[],
  });

  /// `null` = **散采**（不记往来）—— 只有当场结清才允许。
  final String? partyId;

  /// 供应商显示名（选择器带回；SnackBar 与标红提示用）
  final String partyName;

  /// 业务日期，原文 `YYYY-MM-DD`（默认今天，可改 —— 补录昨天的单是常态）
  final String date;

  final String remark;
  final List<PurchaseLineDraft> lines;
  final List<PurchasePaymentDraft> payments;

  PurchaseDraft copyWith({
    String? partyId,
    bool clearParty = false,
    String? partyName,
    String? date,
    String? remark,
    List<PurchaseLineDraft>? lines,
    List<PurchasePaymentDraft>? payments,
  }) => PurchaseDraft(
    partyId: clearParty ? null : (partyId ?? this.partyId),
    partyName: partyName ?? this.partyName,
    date: date ?? this.date,
    remark: remark ?? this.remark,
    lines: lines ?? this.lines,
    payments: payments ?? this.payments,
  );

  // ------------------------------------------------------------ 校验

  /// 主单级校验。**空 map = 通过**；否则 `字段 → 给用户看的一句话`。
  ///
  /// 行级与付款行级错误分别在 [validateLines] / [validatePayments] ——
  /// 界面按行标红，主单级只管「整单是不是成立」。
  Map<PurchaseField, String> validate() {
    final Map<PurchaseField, String> errors = <PurchaseField, String>{};

    final String dateText = date.trim();
    if (dateText.isEmpty) {
      errors[PurchaseField.date] = '请填日期';
    } else if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dateText) ||
        DateTime.tryParse(dateText) == null) {
      errors[PurchaseField.date] = '日期格式不对，应为 2026-09-27 这样的完整日期';
    }

    // 至少要有一行 —— 空行自身会报行级错误（用户加了一行就得填），
    // 这里只拦「一行都没有」。
    if (lines.isEmpty) {
      errors[PurchaseField.lines] = '至少要有一行商品，点「加一行」或扫商品条码';
    }

    // 付款合计 ≤ 本单合计（RULE-001 约束；规则层还有一道闸，这里先给出友好文案）
    if (paymentsOk && paidCents > totalCents) {
      errors[PurchaseField.payments] =
          '付款合计（¥${Money.format(paidCents)}）超过了本单合计'
          '（¥${Money.format(totalCents)}），请检查付款金额';
    }

    // 散采（未选供应商）必须当场结清 —— R-12 的 UI 表达。
    // 只在行与付款本身都合法时才判（否则先报更基础的错，一次一个重点）。
    if (partyId == null && linesOk && paymentsOk && dueCents > 0) {
      errors[PurchaseField.party] =
          '散采要当场结清，或选一个供应商把欠款记到名下';
    }
    return errors;
  }

  /// 行级校验，结果与 [lines] **按位置对齐**。
  List<Map<PurchaseLineField, String>> validateLines() =>
      lines.map((PurchaseLineDraft line) => line.validate()).toList();

  /// 付款行级校验，结果与 [payments] **按位置对齐**。
  List<Map<PurchasePaymentField, String>> validatePayments() =>
      payments.map((PurchasePaymentDraft p) => p.validate()).toList();

  bool get linesOk =>
      validateLines().every((Map<PurchaseLineField, String> e) => e.isEmpty);

  bool get paymentsOk => validatePayments().every(
    (Map<PurchasePaymentField, String> e) => e.isEmpty,
  );

  bool get isValid =>
      validate().isEmpty && linesOk && paymentsOk;

  // ------------------------------------------------------------ 取值（校验通过后）

  /// 合计（分）= Σ(数量 × 单价)。非法行按 0 处理（此时校验必不通过）。
  int get totalCents {
    int sum = 0;
    for (final PurchaseLineDraft line in lines) {
      sum += line.amountCents ?? 0;
    }
    return sum;
  }

  /// 已付（分）= Σ 付款金额（空行跳过）
  int get paidCents {
    int sum = 0;
    for (final PurchasePaymentDraft payment in payments) {
      sum += payment.amountCents ?? 0;
    }
    return sum;
  }

  /// 欠款（分）= 合计 − 已付。校验通过时 ≥ 0。
  int get dueCents => totalCents - paidCents;

  /// 业务发生时间（毫秒）：当天 00:00（本地时区）
  int get occurredAt => DateTime.parse(date.trim()).millisecondsSinceEpoch;

  @override
  String toString() =>
      'PurchaseDraft(party=$partyName, date=$date, lines=${lines.length}, '
      'paid=$paidCents, total=$totalCents)';
}
