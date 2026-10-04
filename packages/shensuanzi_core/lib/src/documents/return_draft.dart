/// 退货开单的**表单草稿**（原文 + 纯函数校验）—— §BI / reply.md 2026-10-04 裁定。
///
/// 与 `SaleDraft` 同构：字段保留**用户敲的原文**，校验与解析分开。
/// 规则本体在 `RuleEngine` 的 RULE-007/008（**已实现**，本文件只做「表单门槛」）。
///
/// ## 口径（reply.md 2026-10-04 裁定，五处补强全在此落）
///
/// - **entry_\* 沿用原单行**：退货是针对原交易的冲减，按原交易的单位退
///   （**不允许切换单位**）。`entry_quantity` = 本次退货数量（按原单位），
///   `quantity` = `toBaseQuantity(...)`（原单行 `entry_unit` 为空 ⇒ 按最小单位原样）。
/// - **金额默认 = 累计比例法**（与 R-11 成本分摊同哲学，裁定明令弃用
///   「派生单价 × 数量」——`unit_price` 是 `round(amount/quantity)`，乘回去有舍入差）：
///   `本次应退 = round_half_up(原单行金额 × (已退量 + 本次量) / 原单行量) − 已退金额`
///   —— 多次退货之和**精确等于**应退总额，且天然处理原单行的让价
///   （比例按 `amount` 算，不按单价）。默认值可手改；上限 = 原单行金额 − 已退金额。
/// - **`discount_amount` 恒 0**：「退货让价」= 直接把金额改小（amount 是真相，
///   v3 口径）——让价额不再单列一列，避免两处金额打架。
/// - **立即退款封顶**：与 `SaleDraft.recordedPaymentCents` 同构（`Overpay.clamp`），
///   超出合计的部分按找零口径不落库。
library;

import '../models/document.dart';
import 'overpay.dart';
import 'quantity_conversion.dart';
import '../util/money.dart';

/// 字段级错误定位的键（界面据此标红对应栏）
enum ReturnField { lines, refunds }

enum ReturnLineField { quantity, amount }

enum ReturnRefundField { account, amount }

/// 一行退货的草稿。
///
/// ⚠️ [entryUnit] / [baseUnit] / [packageUnit] / [packageSize] / 四个 original*
/// / prior* 字段都是**来自原单的上下文**（UI 从 [ReturnService.quotasFor] 与
/// 原单行预填），不是用户输入 —— 退货不允许改商品、改单位。
class ReturnLineDraft {
  const ReturnLineDraft({
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.amount,
    this.entryUnit,
    this.baseUnit,
    this.packageUnit,
    this.packageSize,
    required this.originalQuantity,
    required this.originalAmountCents,
    this.priorReturnedQuantity = 0,
    this.priorReturnedAmountCents = 0,
  });

  final String productId;
  final String productName;

  /// 用户敲的原文：**本次退货数量**（按原单行的录入单位）
  final String quantity;

  /// 用户敲的原文：**本次退货金额**（元；UI 预填累计比例法的默认值，可手改）
  final String amount;

  // ---- 原单行上下文（只读，不进校验的用户输入面）----

  /// 原单行的录入单位（`null` = 原单按最小单位录的 ⇒ 本次数量就是最小单位）
  final String? entryUnit;
  final String? baseUnit;
  final String? packageUnit;
  final int? packageSize;

  /// 原单行数量（最小单位）
  final int originalQuantity;

  /// 原单行金额（分；**含让价** —— 比例按它算，天然回退让价部分）
  final int originalAmountCents;

  /// 此前已退数量（最小单位；从 stock_ledger 聚合）
  final int priorReturnedQuantity;

  /// 此前已退金额（分；Σ 此前退货单行的 amount）
  final int priorReturnedAmountCents;

  /// 可退余量（最小单位）
  int get remainingQuantity => originalQuantity - priorReturnedQuantity;

  /// 可退金额余量（分）
  int get remainingAmountCents =>
      originalAmountCents - priorReturnedAmountCents;

  /// 数量框 label 上显示的单位（原单行的录入单位；空 ⇒ 最小单位）
  // 注：不提供「entryUnitDisplay」之类的录入单位展示 getter ——
  // 配额数字全是**最小单位**，缀录入单位会误导（§BI·二·补 3），展示归 UI。

  /// **录入数量**取值；非法 / ≤0 时 `null`（调用方应先 `validate`）
  int? get entryQuantityValue {
    final int? qty = int.tryParse(quantity.trim());
    return (qty == null || qty <= 0) ? null : qty;
  }

  /// **换算后的最小单位数量**（`document_lines.quantity` 要落的值）；
  /// 换算失败 ⇒ `null`（validate 会带文案拦住）
  int? get quantityValue => toBaseQuantity(
    entryQuantity: entryQuantityValue ?? 0,
    entryUnit: entryUnit,
    baseUnit: baseUnit ?? '',
    packageUnit: packageUnit,
    packageSize: packageSize,
  ).baseQuantityOrNull;

  /// **累计比例法的默认金额**（分）—— UI 预填依据（裁定 3：不用派生单价）。
  ///
  /// `round_half_up(原单行金额 × (已退量 + 本次量) / 原单行量) − 已退金额`；
  /// 数量非法 / 原单量为 0 ⇒ `null`（校验会拦）。
  int? get defaultAmountCents {
    final int? base = quantityValue;
    if (base == null || originalQuantity <= 0) return null;
    final int cumulative = priorReturnedQuantity + base;
    final int cumulativeAmount = Money.divideRoundHalfUp(
      originalAmountCents * cumulative,
      originalQuantity,
    );
    return cumulativeAmount - priorReturnedAmountCents;
  }

  /// 用户填写的金额取值（分）；非法 / 负 ⇒ `null`（validate 先拦）
  int? get amountCents {
    final int? cents = Money.tryParseYuan(amount.trim());
    if (cents == null || cents < 0) return null;
    return cents;
  }

  Map<ReturnLineField, String> validate() {
    final Map<ReturnLineField, String> errors = <ReturnLineField, String>{};

    final String qtyText = quantity.trim();
    if (qtyText.isEmpty) {
      errors[ReturnLineField.quantity] = '请填退货数量，比如 3';
    } else {
      final int? qty = int.tryParse(qtyText);
      if (qty == null || qty <= 0) {
        errors[ReturnLineField.quantity] = '退货数量要填正整数，比如 3';
      } else {
        final int? base = quantityValue;
        if (base == null) {
          // 换算失败（原单行的单位上下文坏了）—— 文案与开单页同源
          errors[ReturnLineField.quantity] = '退货数量换算失败，请检查商品档案的包装换算';
        } else if (base > remainingQuantity) {
          // ⚠️ 这三个数都是**最小单位**（瓶）—— 不能缀录入单位（箱）：
          // 「原量 120 箱」会把用户骗去填 120（实际只能填 10 箱），
          // 真机踩过（§BI·二·补 3）。数字缀**基本单位**；录入单位是包装
          // 且整除时附「= N 箱」换算（余数场景由页面提示行说清）。
          final String bu = baseUnit ?? '';
          final String baseSuffix = bu.isEmpty ? '' : ' $bu';
          String message =
              '超过可退数量：原量 $originalQuantity$baseSuffix、'
              '已退 $priorReturnedQuantity，最多可退 $remainingQuantity$baseSuffix';
          final String? pkg = entryUnit;
          final int? size = packageSize;
          if (pkg != null &&
              pkg.isNotEmpty &&
              pkg != bu &&
              size != null &&
              size > 0 &&
              remainingQuantity % size == 0) {
            message = '$message（= ${remainingQuantity ~/ size} $pkg）';
          }
          errors[ReturnLineField.quantity] = message;
        }
      }
    }

    final String amountTextTrim = amount.trim();
    if (amountTextTrim.isEmpty) {
      errors[ReturnLineField.amount] = '请填退货金额';
    } else {
      final int? cents = Money.tryParseYuan(amountTextTrim);
      if (cents == null || cents < 0) {
        errors[ReturnLineField.amount] = '金额只能填数字，最多两位小数，比如 62.50';
      } else if (cents > remainingAmountCents) {
        errors[ReturnLineField.amount] =
            '退货金额不能超过 ¥${Money.format(remainingAmountCents)}'
            '（原单行金额减去已退金额）';
      }
    }
    return errors;
  }

  @override
  String toString() =>
      'ReturnLineDraft($productName, qty=$quantity, amount=$amount)';
}

/// 一条立即退款的草稿（sale_return → 退款给客户；purchase_return → 收供应商退款）。
class ReturnRefundDraft {
  const ReturnRefundDraft({
    this.accountId,
    this.accountName = '',
    this.amount = '',
  });

  final String? accountId;
  final String accountName;

  /// 用户敲的原文（元）
  final String amount;

  bool get isBlank => amount.trim().isEmpty;

  Map<ReturnRefundField, String> validate() {
    final Map<ReturnRefundField, String> errors = <ReturnRefundField, String>{};
    final String text = amount.trim();
    if (text.isEmpty) return errors; // 空行跳过，不报错

    if (accountId == null || accountId!.isEmpty) {
      errors[ReturnRefundField.account] = '请选一个资金账户';
    }
    final int? cents = Money.tryParseYuan(text);
    if (cents == null) {
      errors[ReturnRefundField.amount] = '金额只能填数字，最多两位小数，比如 50';
    } else if (cents <= 0) {
      errors[ReturnRefundField.amount] = '退款金额要大于 0';
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
  String toString() => 'ReturnRefundDraft($accountName, $amount)';
}

/// 退货开单草稿（主单）。原单（id / 类型 / 往来方）由 UI 从详情页带入，
/// 服务层会**以库里的原单为准**再核一遍（不信任表单带来的上下文）。
class ReturnDraft {
  const ReturnDraft({
    required this.refDocId,
    required this.originalDocType,
    required this.partyId,
    required this.partyName,
    required this.lines,
    this.refunds = const <ReturnRefundDraft>[],
    this.remark = '',
  });

  /// 原单 id（`documents.ref_doc_id` 要落的值）
  final String refDocId;

  /// 原单类型（`sale` / `delivery` / `purchase`）—— 服务层据此定退货类型
  final DocType originalDocType;

  /// 原单的往来方（自动继承；退货冲减的就是原单方向的欠款）
  final String? partyId;
  final String partyName;

  final List<ReturnLineDraft> lines;
  final List<ReturnRefundDraft> refunds;
  final String remark;

  ReturnDraft copyWith({
    String? refDocId,
    DocType? originalDocType,
    String? partyId,
    String? partyName,
    List<ReturnLineDraft>? lines,
    List<ReturnRefundDraft>? refunds,
    String? remark,
  }) => ReturnDraft(
    refDocId: refDocId ?? this.refDocId,
    originalDocType: originalDocType ?? this.originalDocType,
    partyId: partyId ?? this.partyId,
    partyName: partyName ?? this.partyName,
    lines: lines ?? this.lines,
    refunds: refunds ?? this.refunds,
    remark: remark ?? this.remark,
  );

  /// 合计（分）= Σ(行金额)。非法行按 0 处理（此时校验必不通过）。
  int get totalCents {
    int sum = 0;
    for (final ReturnLineDraft line in lines) {
      sum += line.amountCents ?? 0;
    }
    return sum;
  }

  /// 已填（分）= Σ 退款金额（空行跳过）
  int get refundedCents {
    int sum = 0;
    for (final ReturnRefundDraft refund in refunds) {
      sum += refund.amountCents ?? 0;
    }
    return sum;
  }

  /// **落库的退款金额**（分，与 [refunds] 按位置对齐）—— 与
  /// `SaleDraft.recordedPaymentCents` 同构：超出合计的部分是找零，不落库
  /// （裁定 5：草稿层保证 `SUM(immediate_payments) ≤ total_amount`）。
  List<int> get recordedRefundCents => Overpay.clamp(
    <int>[for (final ReturnRefundDraft refund in refunds) refund.amountCents ?? 0],
    totalCents,
  );

  Map<ReturnField, String> validate() {
    final Map<ReturnField, String> errors = <ReturnField, String>{};
    if (lines.isEmpty) {
      errors[ReturnField.lines] = '至少要有一行退货商品';
      return errors;
    }
    if (totalCents <= 0) {
      errors[ReturnField.lines] = '退货金额合计要大于 0';
    }
    return errors;
  }

  /// 行级校验，结果与 [lines] **按位置对齐**。
  List<Map<ReturnLineField, String>> validateLines() =>
      lines.map((ReturnLineDraft line) => line.validate()).toList();

  /// 退款行级校验，结果与 [refunds] **按位置对齐**。
  List<Map<ReturnRefundField, String>> validateRefunds() =>
      refunds.map((ReturnRefundDraft refund) => refund.validate()).toList();

  bool get linesOk =>
      validateLines().every((Map<ReturnLineField, String> e) => e.isEmpty);
  bool get refundsOk => validateRefunds().every(
    (Map<ReturnRefundField, String> e) => e.isEmpty,
  );
  bool get isValid => validate().isEmpty && linesOk && refundsOk;

  @override
  String toString() =>
      'ReturnDraft(ref=$refDocId, lines=${lines.length}, '
      'refunds=${refunds.length}, total=$totalCents)';
}
