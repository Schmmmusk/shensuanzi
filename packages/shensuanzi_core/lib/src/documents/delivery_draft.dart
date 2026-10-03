/// 送货开单的**表单草稿**（原文 + 纯函数校验）。
///
/// ## 与 `SaleDraft` 的关系：**刻意逐字段对齐，但不共用基类（暂）**
///
/// 这是**第三个**同形草稿（`PurchaseDraft` / `SaleDraft` / 本文件）。
/// `sale_draft.dart` 的文件头写过「**等第三个单据（`DeliveryDraft`）出现时再抽
/// `DocumentDraft` 基类**」—— 那个触发点**到了**。
///
/// **但本批次（1b）不抽**：§AP 把 1b 的范围钉成「**与 1a 完全同构**」，
/// 而抽基类要同时动两个已被 200+ 用例钉住的稳定模块 —— 那是**独立批次**的事
/// （混进功能批次会让 review 变难）。⇒ 本文件**照抄销售**，把三处差异写在下面，
/// 让将来的合并依旧是机械搬运。
///
/// ## 与销售的三处差异（**仅这些**）
///
/// | 项 | 销售 | 送货 |
/// |---|---|---|
/// | **收款区** | 有（立即收款 + 找零辅助） | **完全没有** —— 送货单本身就是赊销 |
/// | **客户** | 可空 = **散客** | **必选** —— 货已离店、欠款必须有人挂着 |
/// | 规则 | RULE-002（负库存允许） | RULE-003（货离店即扣库存，`status` 强制 `in_transit`） |
///
/// ### 为什么客户必选（不是散客）
///
/// 散客的语义是「不记往来、当场结清」。而送货单**创建即扣库存**、
/// 货款**必然**挂在某人名下（`PartyLedger.amount = +total_amount`）——
/// 没有客户就没有地方挂这笔欠款。规则层也会拦：
/// `RuleEngine._requirePayee` 在「未结清且 `party_id == null`」时直接拒绝。
///
/// **客户当场付款怎么办**：送完去单据详情页点「收款」（1a 已就绪）——
/// 那是核销（RULE-004），与开单是两件事。
///
/// ## 校验口径（与销售一致）
///
/// - 明细 ≥ 1 行；每行商品必选、数量**正整数**、单价 ≥ 0 且最多两位小数
/// - **预填售价是默认值不是约束**（与销售同款：改的是这一单，不回写商品档）
/// - 日期 `YYYY-MM-DD`
library;

import '../models/product.dart';
import '../util/money.dart';

/// 主单级字段（错误定位的键 —— 界面据此知道该标红哪一栏）
enum DeliveryField { party, date, lines, remark }

/// 明细行字段
enum DeliveryLineField { product, quantity, unitPrice }

/// 一行明细的草稿（与 `SaleLineDraft` 逐字段对齐）。
///
/// [unitPrice] 的**预填依据是 `products.sell_price`** —— 送货送的是卖出去的货。
class DeliveryLineDraft {
  const DeliveryLineDraft({
    this.productId = '',
    this.productName = '',
    this.quantity = '',
    this.unitPrice = '',
  });

  /// 从商品带入：**单价预填售价**（可改，改后不回写商品档），数量留空待填。
  factory DeliveryLineDraft.fromProduct(
    Product product, {
    String quantity = '',
  }) => DeliveryLineDraft(
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

  DeliveryLineDraft copyWith({
    String? productId,
    String? productName,
    String? quantity,
    String? unitPrice,
  }) => DeliveryLineDraft(
    productId: productId ?? this.productId,
    productName: productName ?? this.productName,
    quantity: quantity ?? this.quantity,
    unitPrice: unitPrice ?? this.unitPrice,
  );

  /// 空行 = 三个字段都没填。[isEmpty] 只供服务层做防御性跳过，不参与校验。
  bool get isEmpty =>
      productId.isEmpty && quantity.trim().isEmpty && unitPrice.trim().isEmpty;

  Map<DeliveryLineField, String> validate() {
    final Map<DeliveryLineField, String> errors = <DeliveryLineField, String>{};

    if (productId.isEmpty) {
      errors[DeliveryLineField.product] = '请选一个商品';
    }

    final String qtyText = quantity.trim();
    if (qtyText.isEmpty) {
      errors[DeliveryLineField.quantity] = '请填数量，比如 10';
    } else {
      final int? qty = int.tryParse(qtyText);
      if (qty == null || qty <= 0) {
        errors[DeliveryLineField.quantity] = '数量要填正整数，比如 10';
      }
    }

    final String priceText = unitPrice.trim();
    if (priceText.isEmpty) {
      errors[DeliveryLineField.unitPrice] = '请填单价，比如 3.50';
    } else {
      final int? cents = Money.tryParseYuan(priceText);
      if (cents == null) {
        errors[DeliveryLineField.unitPrice] =
            '单价只能填数字，最多两位小数，比如 3.50';
      } else if (cents < 0) {
        errors[DeliveryLineField.unitPrice] = '单价不能是负数';
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
      'DeliveryLineDraft($productName, qty=$quantity, price=$unitPrice)';
}

/// 送货开单草稿（主单）。
///
/// ⚠️ **没有收款区** —— `SaleDraft.payments` 在这里**不存在**，
/// 所以也不会有「找零 / 折算」那一套（§AX·一 与本单据无关）。
class DeliveryDraft {
  const DeliveryDraft({
    this.partyId,
    this.partyName = '',
    this.date = '',
    this.remark = '',
    this.lines = const <DeliveryLineDraft>[],
  });

  /// **必选**（不是散客）—— 见文件头「为什么客户必选」。
  final String? partyId;

  /// 客户显示名（选择器带回；SnackBar 与标红提示用）
  final String partyName;

  /// 业务日期，原文 `YYYY-MM-DD`（默认今天，可改 —— 补录昨天的送货是常态）
  final String date;

  final String remark;
  final List<DeliveryLineDraft> lines;

  DeliveryDraft copyWith({
    String? partyId,
    bool clearParty = false,
    String? partyName,
    String? date,
    String? remark,
    List<DeliveryLineDraft>? lines,
  }) => DeliveryDraft(
    partyId: clearParty ? null : (partyId ?? this.partyId),
    partyName: partyName ?? this.partyName,
    date: date ?? this.date,
    remark: remark ?? this.remark,
    lines: lines ?? this.lines,
  );

  // ------------------------------------------------------------ 校验

  /// 主单级校验。**空 map = 通过**；否则 `字段 → 给用户看的一句话`。
  Map<DeliveryField, String> validate() {
    final Map<DeliveryField, String> errors = <DeliveryField, String>{};

    // 客户**必选** —— 文案说清「为什么」（中老年用户被拦会以为软件坏了，
    // 所以要告诉他「货已经出门了，欠款得有人挂着」）
    if (partyId == null || partyId!.isEmpty) {
      errors[DeliveryField.party] =
          '送货要选一个客户 —— 货出了门，这笔欠款要挂在客户名下';
    }

    final String dateText = date.trim();
    if (dateText.isEmpty) {
      errors[DeliveryField.date] = '请填日期';
    } else if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dateText) ||
        DateTime.tryParse(dateText) == null) {
      errors[DeliveryField.date] = '日期格式不对，应为 2026-09-27 这样的完整日期';
    }

    if (lines.isEmpty) {
      errors[DeliveryField.lines] = '至少要有一行商品，点「加一行」或扫商品条码';
    }
    return errors;
  }

  /// 行级校验，结果与 [lines] **按位置对齐**。
  List<Map<DeliveryLineField, String>> validateLines() =>
      lines.map((DeliveryLineDraft line) => line.validate()).toList();

  bool get linesOk =>
      validateLines().every((Map<DeliveryLineField, String> e) => e.isEmpty);

  bool get isValid => validate().isEmpty && linesOk;

  // ------------------------------------------------------------ 取值（校验通过后）

  /// 合计（分）= Σ(数量 × 单价)。非法行按 0 处理（此时校验必不通过）。
  int get totalCents {
    int sum = 0;
    for (final DeliveryLineDraft line in lines) {
      sum += line.amountCents ?? 0;
    }
    return sum;
  }

  /// 业务发生时间（毫秒）：当天 00:00（本地时区）
  ///
  /// ⚠️ §AP 待确认项的**默认处置**：送货单**没有独立的 `delivered_at`**
  /// （R-3.3 已裁定不引入）⇒ 「送货日期」沿用 `occurred_at`。
  int get occurredAt => DateTime.parse(date.trim()).millisecondsSinceEpoch;

  @override
  String toString() =>
      'DeliveryDraft(party=$partyName, date=$date, lines=${lines.length}, '
      'total=$totalCents)';
}
