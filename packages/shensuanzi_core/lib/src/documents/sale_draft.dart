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
import '../util/money.dart';

/// 主单级字段（错误定位的键 —— 界面据此知道该标红哪一栏）
enum SaleField { party, date, lines, payments, remark }

/// 明细行字段
enum SaleLineField { product, quantity, unitPrice }

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
  });

  /// 从商品带入：**单价预填售价**（可改，改后不回写商品档），数量留空待填。
  factory SaleLineDraft.fromProduct(Product product, {String quantity = ''}) =>
    SaleLineDraft(
      productId: product.id,
      productName: product.name,
      quantity: quantity,
      unitPrice: Money.format(product.sellPrice),
    );

  final String productId;
  final String productName;

  /// 用户敲的原文
  final String quantity;
  final String unitPrice;

  SaleLineDraft copyWith({
    String? productId,
    String? productName,
    String? quantity,
    String? unitPrice,
  }) => SaleLineDraft(
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

    // 收款合计 ≤ 本单合计（RULE-002 约束；规则层还有一道闸，这里先给出友好文案）
    if (paymentsOk && paidCents > totalCents) {
      errors[SaleField.payments] =
          '收款合计（¥${Money.format(paidCents)}）超过了本单合计'
          '（¥${Money.format(totalCents)}），请检查收款金额';
    }

    // 散客（未选客户）必须当场结清 —— 与散采同一约束的 UI 表达。
    // 只在行与收款本身都合法时才判（否则先报更基础的错，一次一个重点）。
    if (partyId == null && linesOk && paymentsOk && dueCents > 0) {
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

  /// 欠款（分）= 合计 − 已收。校验通过时 ≥ 0。
  int get dueCents => totalCents - paidCents;

  /// 业务发生时间（毫秒）：当天 00:00（本地时区）
  int get occurredAt => DateTime.parse(date.trim()).millisecondsSinceEpoch;

  @override
  String toString() =>
      'SaleDraft(party=$partyName, date=$date, lines=${lines.length}, '
      'paid=$paidCents, total=$totalCents)';
}
