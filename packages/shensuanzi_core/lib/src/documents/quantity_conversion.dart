/// 数量换算 —— v3 包装换算的**唯一实现**
/// （`docs/data_model.md` §3.2 第 4 条 / `docs/rules.md` 零·乙）。
///
/// ⚠️ **不在 UI 里做**：三份草稿（采购 / 销售 / 送货）共用同一换算 · UI 不懂业务 ·
/// `dart test` 要能覆盖。这是 §BD·三 第 4 条的裁定。
///
/// ## 为什么失败不返回 `null`
///
/// 三种失败要**分开说**（§BD·九）：「没设换算」「换算无效」「单位不合法」
/// 是三种不同的用户指引，共用一句会让「档案没填」和「数据被改坏」混在一起。
/// 所以用 sealed result 而不是 `int?`。
library;

/// 一次换算的结果（成功 / 失败，失败带原因）。
sealed class QuantityConversion {
  const QuantityConversion();

  /// 换算成功时的**最小单位数量**；失败时 `null`。
  /// （只关心数字、不关心失败原因的场景用。）
  int? get baseQuantityOrNull => switch (this) {
    ConversionSuccess(:final baseQuantity) => baseQuantity,
    ConversionFailed() => null,
  };
}

/// 换算成功。[baseQuantity] 就是 `document_lines.quantity` 要落的值。
final class ConversionSuccess extends QuantityConversion {
  const ConversionSuccess(this.baseQuantity);

  final int baseQuantity;
}

/// 换算失败。[reason] 决定 UI 报哪句话（见 [conversionFailureMessage]）。
final class ConversionFailed extends QuantityConversion {
  const ConversionFailed(this.reason);

  final ConversionFailureReason reason;
}

/// 三种失败原因（§BD·九 定死，不许合并）。
enum ConversionFailureReason {
  /// 选了包装单位，但档案**没设** `package_size`
  packageSizeMissing,

  /// `package_size <= 0` —— 档案校验本应挡住，纯函数兜底防数据被外部改坏
  packageSizeInvalid,

  /// `entry_unit` 不是 `baseUnit` / `packageUnit` 中的任何一个
  /// （理论上不该发生：UI 只给两个选项；兜底必须与「没设换算」分开）
  unknownUnit,
}

/// 三种失败的**用户文案** —— 与 `Overpay` 同哲学：文案单一出处，UI 不造句。
String conversionFailureMessage(ConversionFailureReason reason) =>
    switch (reason) {
      ConversionFailureReason.packageSizeMissing => '这个商品没设包装换算',
      ConversionFailureReason.packageSizeInvalid => '包装换算无效',
      ConversionFailureReason.unknownUnit => '单位不合法',
    };

/// 把「录入原文」换算成**最小单位数量**。
///
/// 规则（§BD·三 第 4 条，逐条对应）：
///
/// | [entryUnit] | 条件 | 结果 |
/// |---|---|---|
/// | `null` / [baseUnit] | — | `entryQuantity`（原样） |
/// | [packageUnit] | `packageSize != null && > 0` | `entryQuantity × packageSize` |
/// | [packageUnit] | `packageSize == null` | 失败 `packageSizeMissing` |
/// | [packageUnit] | `packageSize <= 0` | 失败 `packageSizeInvalid` |
/// | 其它 | — | 失败 `unknownUnit` |
QuantityConversion toBaseQuantity({
  required int entryQuantity,
  required String? entryUnit,
  required String baseUnit,
  required String? packageUnit,
  required int? packageSize,
}) {
  // 没切单位（null / 空）或显式选了最小单位 ⇒ 原样，不乘
  if (entryUnit == null || entryUnit.isEmpty || entryUnit == baseUnit) {
    return ConversionSuccess(entryQuantity);
  }
  // 不是档案认得的包装单位（含「档案根本没设包装」）⇒ 不合法
  if (packageUnit == null || packageUnit.isEmpty || entryUnit != packageUnit) {
    return const ConversionFailed(ConversionFailureReason.unknownUnit);
  }
  if (packageSize == null) {
    return const ConversionFailed(ConversionFailureReason.packageSizeMissing);
  }
  if (packageSize <= 0) {
    return const ConversionFailed(ConversionFailureReason.packageSizeInvalid);
  }
  return ConversionSuccess(entryQuantity * packageSize);
}

// -------------------------------------------------- 单位切换 × 预填价（§BG 方案 A）

/// 把「按 [fromUnit] 报的价」换算成「按 [toUnit] 报的价」（分）。
///
/// **出处**：§BG 裁定方案 A —— 单价语义 = 按录入单位报价（§BD·三），
/// 切换录入单位时，若价格框还是**预填价**（未被手改，`priceTouched` 判定在 UI），
/// 价格要跟着换到新单位，否则「瓶价」会被当成「箱价」（真机踩过：1 箱 × ¥2.50 = ¥2.50）。
///
/// 返回 `null` = **换算不出**（除不尽 / 换算上下文无效）—— UI 处置单一：
/// 保留原值 + 用 [entryPriceKeptHint] 告知，不需要区分原因，所以这里用
/// `int?` 而不是 sealed result（与 [toBaseQuantity] 的三分失败**不同层**）。
///
/// 规则：
///
/// | from → to | 条件 | 结果 |
/// |---|---|---|
/// | 归一后相同 | — | 原样（没真切） |
/// | 最小 → 包装 | 成对启用 | `priceCents × packageSize`（必整除） |
/// | 包装 → 最小 | 成对且整除 | `priceCents ~/ packageSize` |
/// | 包装 → 最小 | 除不尽 | `null`（保留原值 + 提示） |
/// | 上下文无效 | 没设包装 / size ≤ 0 / 单位不认得 | `null` |
int? convertEntryPriceCents({
  required int priceCents,
  required String fromUnit,
  required String toUnit,
  required String baseUnit,
  required String? packageUnit,
  required int? packageSize,
}) {
  // 空串 = 最小单位（与 toBaseQuantity 的「没切单位」同口径）
  final String from = fromUnit.trim().isEmpty ? baseUnit : fromUnit.trim();
  final String to = toUnit.trim().isEmpty ? baseUnit : toUnit.trim();
  if (from == to) return priceCents;

  final bool pairOk =
      packageUnit != null &&
      packageUnit.isNotEmpty &&
      packageSize != null &&
      packageSize > 0;
  if (!pairOk) return null;

  if (from == baseUnit && to == packageUnit) {
    return priceCents * packageSize; // 乘法必整除
  }
  if (from == packageUnit && to == baseUnit) {
    // 整数分除不尽 ⇒ 新单位下表达不出这个价（两位小数放不下）
    return priceCents % packageSize == 0 ? priceCents ~/ packageSize : null;
  }
  return null; // 单位对不上（理论上 UI 给不出第三个选项）
}

/// 「按包装录入」的辅助说明 —— §BG 裁定 ③：**只在切到包装单位时显示**
/// （常驻会让每行多一行字）。措辞单一出处，UI 不造句。
String packageEntryHint({
  required String baseUnit,
  required String packageUnit,
  required int packageSize,
}) => '1 $packageUnit = $packageSize $baseUnit，入库按 $packageSize $baseUnit记。';

/// 切单位但**价格没换成**（除不尽，保留原值）时的告知 —— §BG 裁定 ②：
/// 让用户一眼看出「这个数字现在被解释成什么单位」。橙色告知，不拦提交。
String entryPriceKeptHint({
  required String keptUnit,
  required String otherUnit,
}) =>
    '单价折算除不尽：这个数现在按「$keptUnit」计；'
    '想按「$otherUnit」计请重新输入单价。';
