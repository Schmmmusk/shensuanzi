/// 店内销售开单的**表单草稿**（原文 + 纯函数校验）。
///
/// ## ⚠️ 与 `PurchaseDraft` 约 80% 同构 —— 抽象的时机
///
/// 两者的字段结构几乎一样（对方、明细、立即收付款、日期），但**第一处重复
/// 不急着抽基类**：`PurchaseDraft` 已被 200+ 用例钉住，现在抽 `DocumentDraft`
/// 要同时动两个稳定模块。**等第三个单据（`DeliveryDraft`，送货）出现时**
/// 再抽 —— 三处重复足以看清抽象的正确形状（`docs/reply_review.md` §Z 三）。
/// 在那之前，本文件刻意与采购**逐字段对齐**（枚举名、getter 名、校验顺序），
/// 让将来的合并是机械搬运而不是重新设计。
///
/// ## 与采购的差异（仅这些）
///
/// | 项 | 采购 | 销售 |
/// |---|---|---|
/// | 对方 | 供应商（可空 = 散采） | 客户（可空 = **散客**） |
/// | 单价预填 | 进价 `costPrice` | **售价** `sellPrice` |
/// | 散客文案 | 「散采要当场结清…」 | 「散客要当场结清…」 |
/// | 规则 | RULE-001 | RULE-002（负库存允许，UI 红色告警 —— 在界面层） |
///
/// ## 校验口径（与采购一致）
///
/// - 明细 ≥ 1 行；每行商品必选、数量**正整数**、单价 ≥ 0 且最多两位小数
/// - **预填售价是默认值不是约束**：用户改过的单价就是这一行的真相，
///   **不回写** `products.sell_price`（这次卖便宜了不代表下次也便宜）
/// - 收款行：**金额留空 = 没有这笔收款**（默认「全赊」靠这个表达）；
///   金额填了 ⇒ 账户必选且 > 0
/// - **散客**（未选客户）且有欠款 ⇒ 报「散客要当场结清，或选一个客户」
library;

import '../models/product.dart';
import 'quantity_conversion.dart';
import '../util/money.dart';
import 'overpay.dart';

/// 主单级字段（错误定位的键 —— 界面据此知道该标红哪一栏）
enum SaleField { party, date, lines, payments, remark }

/// 明细行字段
enum SaleLineField { product, quantity, unitPrice, entryUnit, discount }

/// 立即收款行字段
enum SalePaymentField { account, amount }

/// 一行明细的草稿。
///
/// [unitPrice] 的**预填依据是 `products.sell_price`**（默认值不是约束 ——
/// 议价是常态，见 `SaleLineDraft.fromProduct`）。
class SaleLineDraft {
  const SaleLineDraft({
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

  /// 从商品带入：**单价预填售价**（可改，改后不回写商品档），数量留空待填。
  factory SaleLineDraft.fromProduct(Product product, {String quantity = ''}) =>
    SaleLineDraft(
      productId: product.id,
      productName: product.name,
      quantity: quantity,
      unitPrice: Money.format(product.sellPrice),
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

  SaleLineDraft copyWith({
    String? productId,
    String? productName,
    String? quantity,
    String? unitPrice,
    String? entryUnit,
    String? discountAmount,
    String? baseUnit,
    String? packageUnit,
    int? packageSize,
  }) => SaleLineDraft(
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

  Map<SaleLineField, String> validate() {
    final Map<SaleLineField, String> errors = <SaleLineField, String>{};

    if (productId.isEmpty) {
      errors[SaleLineField.product] = '请选一个商品';
    }

    final String qtyText = quantity.trim();
    if (qtyText.isEmpty) {
      errors[SaleLineField.quantity] = '请填数量，比如 10';
    } else {
      final int? qty = int.tryParse(qtyText);
      if (qty == null || qty <= 0) {
        errors[SaleLineField.quantity] = '数量要填正整数，比如 10';
      }
    }

    final String priceText = unitPrice.trim();
    if (priceText.isEmpty) {
      errors[SaleLineField.unitPrice] = '请填单价，比如 3.50';
    } else {
      final int? cents = Money.tryParseYuan(priceText);
      if (cents == null) {
        errors[SaleLineField.unitPrice] =
            '单价只能填数字，最多两位小数，比如 3.50';
      } else if (cents < 0) {
        errors[SaleLineField.unitPrice] = '单价不能是负数';
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
        errors[SaleLineField.entryUnit] = conversionFailureMessage(ConversionFailureReason.unknownUnit);
      } else {
        // 换算失败（没设 / ≤0）在这里拦 —— 文案三种分开（§BD·九）
        final QuantityConversion c = conversion;
        if (c is ConversionFailed) {
          errors[SaleLineField.entryUnit] = conversionFailureMessage(c.reason);
        }
      }
    }

    // ---- v3：让价（§BD·三 第 6 条）—— [0, entry_qty × entry_price] ----
    final String discText = discountAmount.trim();
    if (discText.isNotEmpty) {
      final int? disc = Money.tryParseYuan(discText);
      if (disc == null) {
        errors[SaleLineField.discount] = '让价只能填数字，最多两位小数，比如 0.50';
      } else if (disc < 0) {
        errors[SaleLineField.discount] = '让价不能是负数';
      } else {
        final int? qty = entryQuantityValue;
        final int? price = entryUnitPriceCents;
        if (qty != null && price != null && disc > qty * price) {
          errors[SaleLineField.discount] =
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
      'SaleLineDraft($productName, qty=$quantity, price=$unitPrice)';
}

/// 一条立即收款的草稿。
///
/// **金额留空 = 没有这笔收款**（UI 默认「全赊」就是靠这个表达），
/// 所以 [validate] 对空金额返回空 map；金额填了 ⇒ 账户必选且 > 0。
class SalePaymentDraft {
  const SalePaymentDraft({
    this.accountId = '',
    this.accountName = '',
    this.amount = '',
  });

  final String accountId;
  final String accountName;

  /// 用户敲的原文（元）
  final String amount;

  SalePaymentDraft copyWith({
    String? accountId,
    String? accountName,
    String? amount,
  }) => SalePaymentDraft(
    accountId: accountId ?? this.accountId,
    accountName: accountName ?? this.accountName,
    amount: amount ?? this.amount,
  );

  /// 金额留空 ⇒ 这一行**不参与**（默认「全赊」）
  bool get isBlank => amount.trim().isEmpty;

  Map<SalePaymentField, String> validate() {
    final Map<SalePaymentField, String> errors = <SalePaymentField, String>{};
    final String text = amount.trim();
    if (text.isEmpty) return errors; // 空行跳过，不报错

    if (accountId.isEmpty) {
      errors[SalePaymentField.account] = '请选一个资金账户';
    }
    final int? cents = Money.tryParseYuan(text);
    if (cents == null) {
      errors[SalePaymentField.amount] =
          '金额只能填数字，最多两位小数，比如 500';
    } else if (cents <= 0) {
      errors[SalePaymentField.amount] = '收款金额要大于 0';
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
  String toString() => 'SalePaymentDraft($accountName, $amount)';
}

/// 店内销售开单草稿（主单）。
class SaleDraft {
  const SaleDraft({
    this.partyId,
    this.partyName = '',
    this.date = '',
    this.remark = '',
    this.lines = const <SaleLineDraft>[],
    this.payments = const <SalePaymentDraft>[],
  });

  /// `null` = **散客**（不记往来）—— 只有当场结清才允许。
  final String? partyId;

  /// 客户显示名（选择器带回；SnackBar 与标红提示用）
  final String partyName;

  /// 业务日期，原文 `YYYY-MM-DD`（默认今天，可改 —— 补录昨天的单是常态）
  final String date;

  final String remark;
  final List<SaleLineDraft> lines;
  final List<SalePaymentDraft> payments;

  SaleDraft copyWith({
    String? partyId,
    bool clearParty = false,
    String? partyName,
    String? date,
    String? remark,
    List<SaleLineDraft>? lines,
    List<SalePaymentDraft>? payments,
  }) => SaleDraft(
    partyId: clearParty ? null : (partyId ?? this.partyId),
    partyName: partyName ?? this.partyName,
    date: date ?? this.date,
    remark: remark ?? this.remark,
    lines: lines ?? this.lines,
    payments: payments ?? this.payments,
  );

  // ------------------------------------------------------------ 校验

  /// 主单级校验。**空 map = 通过**；否则 `字段 → 给用户看的一句话`。
  Map<SaleField, String> validate() {
    final Map<SaleField, String> errors = <SaleField, String>{};

    final String dateText = date.trim();
    if (dateText.isEmpty) {
      errors[SaleField.date] = '请填日期';
    } else if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dateText) ||
        DateTime.tryParse(dateText) == null) {
      errors[SaleField.date] = '日期格式不对，应为 2026-09-27 这样的完整日期';
    }

    // 至少要有一行 —— 空行自身会报行级错误（用户加了一行就得填），
    // 这里只拦「一行都没有」。
    if (lines.isEmpty) {
      errors[SaleField.lines] = '至少要有一行商品，点「加一行」或扫商品条码';
    }

    // 收款 > 应收：**不再报错**（§AX·一，2026-10-02 裁定「方案 3甲」）。
    //
    // 旧行为是拦下来 + 一条友好文案（§AJ·AI-4）。裁定复核后**维持核心判断**
    // ——「落库金额永远 = 应收，找零不持久化」—— 但把「拦」改成
    // 「**按应收折算 + 两处提前告知**」：老板不必心算改回 93，
    // 而「记了多少」由内联提示与[按钮文字][saveActionLabel]在**提交前**说清。
    //
    // ⚠️ 折算**不是**「草稿里改掉用户填的数」：草稿保留原文，
    // 落库金额由 [recordedPaymentCents] 派生（`SaleService` 消费它）。
    // 这样 UI 能显示「实收 100 / 入账 93 / 找零 7」三件事。

    // 散客（未选客户）必须当场结清 —— 与散采同一约束的 UI 表达。
    // 只在行与收款本身都合法时才判（否则先报更基础的错，一次一个重点）。
    //
    // ⚠️ 欠款按**落库金额**算（`recordedPaidCents`）：用户填 100 时
    // 落库是 93 ⇒ 欠款 0 ⇒ 散客**允许**（那 7 元是找零，不是欠款）。
    if (partyId == null && linesOk && paymentsOk && recordedDueCents > 0) {
      errors[SaleField.party] =
          '散客要当场结清，或选一个客户把欠款记到名下';
    }
    return errors;
  }

  /// 行级校验，结果与 [lines] **按位置对齐**。
  List<Map<SaleLineField, String>> validateLines() =>
      lines.map((SaleLineDraft line) => line.validate()).toList();

  /// 收款行级校验，结果与 [payments] **按位置对齐**。
  List<Map<SalePaymentField, String>> validatePayments() =>
      payments.map((SalePaymentDraft p) => p.validate()).toList();

  bool get linesOk =>
      validateLines().every((Map<SaleLineField, String> e) => e.isEmpty);

  bool get paymentsOk => validatePayments().every(
    (Map<SalePaymentField, String> e) => e.isEmpty,
  );

  bool get isValid =>
      validate().isEmpty && linesOk && paymentsOk;

  // ------------------------------------------------------------ 取值（校验通过后）

  /// 合计（分）= Σ(数量 × 单价)。非法行按 0 处理（此时校验必不通过）。
  int get totalCents {
    int sum = 0;
    for (final SaleLineDraft line in lines) {
      sum += line.amountCents ?? 0;
    }
    return sum;
  }

  /// 已收（分）= Σ 收款金额（空行跳过）
  int get paidCents {
    int sum = 0;
    for (final SalePaymentDraft payment in payments) {
      sum += payment.amountCents ?? 0;
    }
    return sum;
  }

  /// 欠款（分）= 合计 − 已收。
  ///
  /// ⚠️ **可能为负**（用户填的超过应收 = 超收/找零）—— 这是常态，不是错误
  /// （§AX·一）。要「入账后欠多少」请用 [recordedDueCents]。
  int get dueCents => totalCents - paidCents;

  // ------------------------------------------- §AX·一：超收（找零，方案 3甲）

  /// **落库的收款金额**（分，与 [payments] **按位置对齐**）。
  ///
  /// 超收部分**不落库**（它是找零）：按 [totalCents] 逐行顺次钳制 ⇒
  /// 「合计 ≤ 应收」由构造保证（RULE-002 的约束仍然成立）。
  /// 例：填 `[100]` + 应收 93 ⇒ `[93]`；填 `[50, 50]` + 应收 93 ⇒ `[50, 43]`。
  List<int> get recordedPaymentCents => Overpay.clamp(
    <int>[for (final SalePaymentDraft p in payments) p.amountCents ?? 0],
    totalCents,
  );

  /// 落库后**实际入账**的收款合计（分）= `min(已填, 应收)`。
  int get recordedPaidCents {
    int sum = 0;
    for (final int cents in recordedPaymentCents) {
      sum += cents;
    }
    return sum;
  }

  /// **找零**（分）= 填的 − 应收；未超收 ⇒ `0`。
  int get changeCents =>
      Overpay(givenCents: paidCents, dueCents: totalCents).changeCents;

  /// 按**落库金额**算的欠款（分）= 应收 − 入账 —— **散客判定的依据**
  /// （超收时 `dueCents` 是负的，不能拿它判定「还没结清」）。
  int get recordedDueCents => totalCents - recordedPaidCents;

  /// 收款框填得超过应收 ⇒ **内联橙色告知**；否则 `null`。
  ///
  /// > 实收 ¥100，其中 ¥93 入账、找零 ¥7
  ///
  /// 与 [saveActionLabel] **同源**（文案都在 [Overpay]），但**触发条件不同**：
  /// 本 getter 只看草稿里的收款行；按钮文字还要看「顾客给了」
  /// （它在开单页的辅助框里，**不进草稿**）。
  String? get overpayNotice =>
      Overpay(givenCents: paidCents, dueCents: totalCents).notice();

  /// **提交按钮文字** —— §AX·一 裁定：*按钮文字是用户动作的最终确认*。
  ///
  /// [givenCents] = 开单页「顾客给了」那个辅助框的值。它**不进草稿**
  /// （找零不持久化），只用来算按钮文字；不传 ⇒ 只看收款框。
  ///
  /// | 情况 | 按钮 |
  /// |---|---|
  /// | 未填 / 填得不够 / 刚好结清 | `保存` |
  /// | **超收** | `记 ¥93 并找零 ¥7` |
  ///
  /// 文案在 [Overpay] 里，**不在这里造句** —— 与核销对话框**同源**
  /// （§AX·一：两处措辞必须一致，见 `Overpay` 的文件头）。
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
      'SaleDraft(party=$partyName, date=$date, lines=${lines.length}, '
      'paid=$paidCents, total=$totalCents)';
}
