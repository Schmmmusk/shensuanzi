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
import 'quantity_conversion.dart';
import '../util/money.dart';

/// 主单级字段（错误定位的键 —— 界面据此知道该标红哪一栏）
enum DeliveryField { party, date, lines, remark }

/// 明细行字段
enum DeliveryLineField { product, quantity, unitPrice, entryUnit, discount }

/// 一行明细的草稿（与 `SaleLineDraft` 逐字段对齐）。
///
/// [unitPrice] 的**预填依据是 `products.sell_price`** —— 送货送的是卖出去的货。
class DeliveryLineDraft {
  const DeliveryLineDraft({
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
  factory DeliveryLineDraft.fromProduct(
    Product product, {
    String quantity = '',
  }) => DeliveryLineDraft(
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

  DeliveryLineDraft copyWith({
    String? productId,
    String? productName,
    String? quantity,
    String? unitPrice,
    String? entryUnit,
    String? discountAmount,
    String? baseUnit,
    String? packageUnit,
    int? packageSize,
  }) => DeliveryLineDraft(
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

    // ---- v3：录入单位（三态）与换算（§BD·三 第 3/4 条）----
    final String? unit = entryUnitValue;
    if (unit != null) {
      final bool isBase = baseUnit != null && unit == baseUnit;
      // ⚠️ public field 不提升 —— 先落局部变量（dartAnalyzer: non-promo-public-field）
      final String? pkg = packageUnit;
      final bool isPackage = pkg != null && pkg.isNotEmpty && unit == pkg;
      if (!isBase && !isPackage) {
        errors[DeliveryLineField.entryUnit] = conversionFailureMessage(ConversionFailureReason.unknownUnit);
      } else {
        final QuantityConversion c = conversion;
        if (c is ConversionFailed) {
          errors[DeliveryLineField.entryUnit] = conversionFailureMessage(c.reason);
        }
      }
    }

    // ---- v3：让价（§BD·三 第 6 条）—— [0, entry_qty × entry_price] ----
    final String discText = discountAmount.trim();
    if (discText.isNotEmpty) {
      final int? disc = Money.tryParseYuan(discText);
      if (disc == null) {
        errors[DeliveryLineField.discount] = '让价只能填数字，最多两位小数，比如 0.50';
      } else if (disc < 0) {
        errors[DeliveryLineField.discount] = '让价不能是负数';
      } else {
        final int? qty = entryQuantityValue;
        final int? price = entryUnitPriceCents;
        if (qty != null && price != null && disc > qty * price) {
          errors[DeliveryLineField.discount] =
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
