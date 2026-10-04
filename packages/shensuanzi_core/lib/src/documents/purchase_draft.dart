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
import 'quantity_conversion.dart';
import '../util/money.dart';
import 'overpay.dart';

/// 主单级字段（错误定位的键 —— 界面据此知道该标红哪一栏）
enum PurchaseField { party, date, lines, payments, remark }

/// 明细行字段
enum PurchaseLineField { product, quantity, unitPrice, entryUnit, discount }

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
    this.entryUnit = '',
    this.discountAmount = '',
    this.baseUnit,
    this.packageUnit,
    this.packageSize,
  });

  /// 从商品带入：**单价预填进价**，数量留空待填。
  factory PurchaseLineDraft.fromProduct(Product product, {String quantity = ''}) =>
    PurchaseLineDraft(
      productId: product.id,
      productName: product.name,
      quantity: quantity,
      unitPrice: Money.format(product.costPrice),
      baseUnit: product.unit,
      packageUnit: product.packageUnit,
      packageSize: product.packageSize,
    );

  final String productId;
  final String productName;

  /// 用户敲的原文 —— v3 语义：`quantity` 就是**录入原文数量**
  /// （落 `entry_quantity`），`unitPrice` 就是**录入单位报价**（不落库，
  /// 派生展示）；**换算后的最小单位数量**见 [baseQuantityValue]。
  final String quantity;
  final String unitPrice;

  // ---- 换算上下文（来自商品档案；[fromProduct] 自动带入，UI 不用管换算）----
  /// ⚠️ 三者都为 `null`（直构旧形态）⇒ 不换算，行为与 v2 完全一致。
  final String? baseUnit;
  final String? packageUnit;
  final int? packageSize;

  /// **录入单位原文**（§BD·三 第 2 条三态）：'' = 没切单位（落库 `null`）；
  /// 只能是 `baseUnit` 或 `packageUnit`，取包装单位的前提 = **成对启用**。
  final String entryUnit;

  /// **让价原文**（元字符串；'' = 无让价）—— 整单议价分摊到行
  /// （§BD·九 #3：差额超最后一行折前金额时 UI 向前分摊）。
  final String discountAmount;

  PurchaseLineDraft copyWith({
    String? productId,
    String? productName,
    String? quantity,
    String? unitPrice,
    String? entryUnit,
    String? discountAmount,
    String? baseUnit,
    String? packageUnit,
    int? packageSize,
  }) => PurchaseLineDraft(
    productId: productId ?? this.productId,
    productName: productName ?? this.productName,
    quantity: quantity ?? this.quantity,
    unitPrice: unitPrice ?? this.unitPrice,
    entryUnit: entryUnit ?? this.entryUnit,
    discountAmount: discountAmount ?? this.discountAmount,
    baseUnit: baseUnit ?? this.baseUnit,
    packageUnit: packageUnit ?? this.packageUnit,
    packageSize: packageSize ?? this.packageSize,
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

    // ---- v3：录入单位（三态）与换算（§BD·三 第 3/4 条）----
    final String? unit = entryUnitValue;
    if (unit != null) {
      final bool isBase = baseUnit != null && unit == baseUnit;
      // ⚠️ public field 不提升 —— 先落局部变量（dartAnalyzer: non-promo-public-field）
      final String? pkg = packageUnit;
      final bool isPackage = pkg != null && pkg.isNotEmpty && unit == pkg;
      if (!isBase && !isPackage) {
        errors[PurchaseLineField.entryUnit] = conversionFailureMessage(ConversionFailureReason.unknownUnit);
      } else {
        // 换算失败（没设 / ≤0）在这里拦 —— 文案三种分开（§BD·九）
        final QuantityConversion c = conversion;
        if (c is ConversionFailed) {
          errors[PurchaseLineField.entryUnit] = conversionFailureMessage(c.reason);
        }
      }
    }

    // ---- v3：让价（§BD·三 第 6 条）—— [0, entry_qty × entry_price] ----
    final String discText = discountAmount.trim();
    if (discText.isNotEmpty) {
      final int? disc = Money.tryParseYuan(discText);
      if (disc == null) {
        errors[PurchaseLineField.discount] = '让价只能填数字，最多两位小数，比如 0.50';
      } else if (disc < 0) {
        errors[PurchaseLineField.discount] = '让价不能是负数';
      } else {
        final int? qty = entryQuantityValue;
        final int? price = entryUnitPriceCents;
        if (qty != null && price != null && disc > qty * price) {
          errors[PurchaseLineField.discount] =
              '让价不能超过本行金额 ¥${Money.format(qty * price)}';
        }
      }
    }
    return errors;
  }

  /// **录入原文数量**取值；非法时 `null`（调用方应先 `validate`）
  int? get entryQuantityValue {
    final int? qty = int.tryParse(quantity.trim());
    return (qty == null || qty <= 0) ? null : qty;
  }

  /// **录入原文单位**落库值：'' ⇒ `null`（没切单位）
  String? get entryUnitValue => entryUnit.trim().isEmpty ? null : entryUnit.trim();

  /// **录入单位报价**（分）—— 用户按 [entryUnit] 报的价（不落库，
  /// 派生展示见 §BD·三 第 5 条）；非法时 `null`
  int? get entryUnitPriceCents => Money.tryParseYuan(unitPrice.trim());

  /// 让价取值（分）：'' ⇒ 0（无让价）；解析失败 ⇒ `null`（validate 先拦）
  int? get discountCents {
    final String text = discountAmount.trim();
    if (text.isEmpty) return 0;
    final int? cents = Money.tryParseYuan(text);
    if (cents == null || cents < 0) return null;
    return cents;
  }

  /// 换算结果（§BD·三 第 4 条：唯一落点 = [toBaseQuantity]）。
  /// 上下文缺失（直构旧形态）且未切单位 ⇒ 成功原样。
  QuantityConversion get conversion => toBaseQuantity(
    entryQuantity: entryQuantityValue ?? 0,
    entryUnit: entryUnitValue,
    baseUnit: baseUnit ?? '',
    packageUnit: packageUnit,
    packageSize: packageSize,
  );

  /// **换算后的最小单位数量**（`document_lines.quantity` 的值）；
  /// 换算失败 ⇒ `null`（validate 会带文案拦住）
  int? get baseQuantityValue => conversion.baseQuantityOrNull;

  /// 本行小计（分）= **`entry_quantity × entry_unit_price − discount_amount`**
  /// （v3 真相口径，§BD·三 第 6 条）；任一字段非法/让价越界 ⇒ `null`
  int? get amountCents {
    final int? qty = entryQuantityValue;
    final int? price = entryUnitPriceCents;
    if (qty == null || price == null) return null;
    final int? discount = discountCents;
    if (discount == null) return null;
    final int gross = qty * price;
    if (discount > gross) return null; // 越界由 validate 报文案；这里防御
    return gross - discount;
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

    // 付款 > 本单合计：**不再报错**（§AY·四，2026-10-02 裁定：与 `SaleDraft`
    // **同构**）。多付的部分是**找回**，不是支出 —— 落库金额 = 应付（RULE-001）。
    //
    // ⚠️ 两份草稿的文档写明**刻意逐字段同构**（§Z 三）—— 只改销售不改采购
    // 会让它们分叉，所以这一处必须一起改。

    // 散采（未选供应商）必须当场结清 —— R-12 的 UI 表达。
    // 只在行与付款本身都合法时才判（否则先报更基础的错，一次一个重点）。
    //
    // ⚠️ 欠款按**落库金额**算（`recordedPaidCents`）：填超时落库是应付，
    // 欠款 0 ⇒ 散采**允许**（多出的部分是找回，不是欠款）。
    if (partyId == null && linesOk && paymentsOk && recordedDueCents > 0) {
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

  /// 欠款（分）= 合计 − 已付。
  ///
  /// ⚠️ **可能为负**（多付 = 找回，§AY·四）—— 这是常态，不是错误。
  /// 要「入账后欠多少」请用 [recordedDueCents]。
  int get dueCents => totalCents - paidCents;

  // --------------------------------------- §AY·四：多付（找回）——与销售同构

  /// **落库的付款金额**（分，与 [payments] **按位置对齐**）。
  ///
  /// 多付的部分**不落库**（它是找回）：按 [totalCents] 逐行顺次封顶 ⇒
  /// `SUM(immediate_payments) ≤ total_amount`（RULE-001）由构造保证。
  /// 例：填 `[100]` + 应付 93 ⇒ `[93]`。
  List<int> get recordedPaymentCents => Overpay.clamp(
    <int>[for (final PurchasePaymentDraft p in payments) p.amountCents ?? 0],
    totalCents,
  );

  /// 落库后**实际支出**的付款合计（分）= `min(已填, 应付)`。
  int get recordedPaidCents {
    int sum = 0;
    for (final int cents in recordedPaymentCents) {
      sum += cents;
    }
    return sum;
  }

  /// **找回**（分）= 付的 − 应付；未多付 ⇒ `0`。
  int get changeCents =>
      Overpay(givenCents: paidCents, dueCents: totalCents).changeCents;

  /// 按**落库金额**算的欠款（分）—— **散采判定的依据**
  /// （多付时 `dueCents` 是负的，不能拿它判定「还没结清」）。
  int get recordedDueCents => totalCents - recordedPaidCents;

  /// 付款框填得超过应付 ⇒ **内联橙色告知**；否则 `null`。
  /// 文案在 [Overpay]，与销售开单页、与核销对话框**同源**。
  ///
  /// ⚠️ 采购方向用「实**付**」（销售是「实收」）—— 只有第一个字不同。
  String? get overpayNotice =>
      Overpay(givenCents: paidCents, dueCents: totalCents).notice(paidVerb: '付');

  /// **提交按钮文字** —— §AY·四：与销售 `SaleDraft.saveActionLabel` 同构。
  /// 未多付 ⇒ `保存`；多付 ⇒ `记 ¥93 并找零 ¥7`。
  String saveActionLabel({int? givenCents}) =>
      Overpay(
        givenCents: givenCents ?? paidCents,
        dueCents: totalCents,
      ).actionLabel ??
      '保存';

  /// 业务发生时间（毫秒）：当天 00:00（本地时区）
  int get occurredAt => DateTime.parse(date.trim()).millisecondsSinceEpoch;

  @override
  String toString() =>
      'PurchaseDraft(party=$partyName, date=$date, lines=${lines.length}, '
      'paid=$paidCents, total=$totalCents)';
}
