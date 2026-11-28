/// **单据行的编辑模型**（2026-11-26 抽离；原 `sale_page` / `purchase_page` /
/// `delivery_page` 各有一份 `_RowCtl`，逐字复制 —— 纪律 18 点名的同构高发区）。
///
/// ## 为什么是"模型"而不是"组件"
///
/// 三个页面的**行卡 UI** 差异是真实存在的（销售有让价、采购有进价、送货只有数量
/// + 签收提示），共用一份卡片会把差异挤成布尔开关；而**编辑状态**是同构的：
/// 选商品、换算上下文、切单位换价、录入原文 vs 最小单位、手改标记。
/// 所以先抽状态，UI 仍留在各自页面 —— 这一步不改变任何行为。
///
/// ## 这是**超集**
///
/// 三个原件的字段/方法在这里全部保留（含只有销售用的 `discountCents` /
/// `discountCentsForDisplay`）。采购 / 送货用不到的字段留在类里无害，
/// 好处是三个页面可以共用一个类型，不会再出现"改了这边漏了那边"。
///
/// ⚠️ **行为不变**：本文件是逐字搬家（原 `sale_page` 的 `_RowCtl`，它本身就是
/// 另外两份的超集，且共享方法体实测逐字相同）。改行为请单独一批。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

class LineRowModel {
  LineRowModel({
    String quantity = '',
    String unitPrice = '',
    String productName = '',
  }) : quantity = TextEditingController(text: quantity),
       unitPrice = TextEditingController(text: unitPrice),
       name = TextEditingController(text: productName);

  /// 商品名输入框的焦点（自动补全要用；**每行一个**，不能共用）。
  final FocusNode nameFocus = FocusNode();
  final FocusNode quantityFocus = FocusNode();
  final FocusNode priceFocus = FocusNode();
  final FocusNode unitFocus = FocusNode();

  /// 明细行上的**商品名**（② 无缝建档，2026-10-25，§CV·一百零五）。
  ///
  /// 这是**显示与提交的唯一来源**：`product` 非空时它等于商品名；
  /// 用户手打一个新名字时 [product] 会被解绑（`null`），保存时由服务层
  /// 「先精确匹配、匹配不到才建档」。
  final TextEditingController name;

  /// 名字被手改 ⇒ **解绑商品**（名字变了就不再是那个商品）。
  ///
  /// 换算上下文一并对齐清空：新名字可能是个新商品（单位「件」），
  /// 沿用旧商品的「箱 = 48 瓶」会算错数量。
  ///
  /// ⚠️ 用户只是误触（改成同名）⇒ 不解绑（`trim` 后相等就放过）。
  void setName(String text) {
    if (product == null) return;
    if (text.trim() == product!.name.trim()) return;
    product = null;
    baseUnit = null;
    packageUnit = null;
    packageSize = null;
    entryUnit = '';
    entryPriceKept = false;
  }

  /// 商品选择结果 —— 只能由「选商品」动作写入（`_pickProduct`）。
  Product? product;

  // ---- v3 换算上下文（选商品时由 [attachProduct] 写入）----
  String? baseUnit;
  String? packageUnit;
  int? packageSize;

  /// **录入单位**：'' = 最小单位（没切）；切到包装 = [packageUnit] 原文
  String entryUnit = '';

  /// 切单位时价格没换成（除不尽，保留原值）⇒ `true`：橙色告知，不拦提交
  /// （§BG 方案 A ②）—— 与采购 / 送货**逐字段同构**，改一边必须扫另两边
  bool entryPriceKept = false;

  /// 本行让价（分）—— 由整单让价分摊写入（`_syncSpread`），行卡只读展示
  int discountCents = 0;

  /// 成对启用 ⇒ 行卡显示单位切换（§BD·三 第 3 条）
  bool get canSwitchPackage =>
      packageUnit != null && packageUnit!.isNotEmpty && (packageSize ?? 0) > 0;

  /// 数量框 label 上显示的单位
  String get entryUnitDisplay =>
      entryUnit.isNotEmpty ? entryUnit : (baseUnit ?? '');

  /// 单价框 label（§BG 方案 A ②：标注「这个数现在按什么单位计」——
  /// 否则切到箱后，瓶价会被悄悄当成箱价，真机踩过）
  String get priceLabel {
    final String unit = entryUnitDisplay;
    return unit.isEmpty ? '单价（元）' : '单价（元/$unit）';
  }

  /// 选商品时写入换算上下文；**换商品重置单位**（不同商品上下文不同）
  void attachProduct(Product picked) {
    product = picked;
    name.text = picked.name;
    baseUnit = picked.unit;
    packageUnit = picked.packageUnit;
    packageSize = picked.packageSize;
    entryUnit = '';
    entryPriceKept = false;
    priceTouched = false;
  }

  /// 价格框被**用户手改过**（§BG 方案 A ①：裁定明令用**显式布尔**，
  /// 不靠「值变没变」猜）—— 预填 = false；用户编辑（非空）= true；
  /// 用户清空 = false；**程序换算不算手改**（换算后的价仍是「预填价」，
  /// 可继续跟随单位）。
  bool priceTouched = false;

  /// 切录入单位（§BG 方案 A）。**判断在 core**（`convertEntryPriceCents`），
  /// 这里只做状态变更：未被手改的价格跟着换到新单位；换算不出（除不尽）⇒
  /// 保留原值 + [entryPriceKept] 告知。与采购 / 送货**逐字段同构**。
  void switchEntryUnit(String toUnit) {
    final String fromUnit = entryUnit;
    final int? price = Money.tryParseYuan(unitPrice.text.trim());
    entryUnit = toUnit;
    entryPriceKept = false;
    if (priceTouched || price == null) return; // 手改过 / 空 ⇒ 数字是用户的，不动
    final int? converted = convertEntryPriceCents(
      priceCents: price,
      fromUnit: fromUnit,
      toUnit: toUnit,
      baseUnit: baseUnit ?? '',
      packageUnit: packageUnit,
      packageSize: packageSize,
    );
    if (converted == null) {
      entryPriceKept = true;
      return;
    }
    // 程序写入不触发 onChanged ⇒ priceTouched 保持 false（仍是「预填价」）
    unitPrice.text = Money.format(converted);
  }

  final TextEditingController quantity;
  final TextEditingController unitPrice;

  bool get isEmpty =>
      product == null &&
      name.text.trim().isEmpty &&
      quantity.text.trim().isEmpty &&
      unitPrice.text.trim().isEmpty;

  /// **录入原文数量**取值；非法时 `null`（调用方应先 `validate`）
  int? get quantityValue {
    final int? qty = int.tryParse(quantity.text.trim());
    return (qty == null || qty <= 0) ? null : qty;
  }

  /// 本行**折前**金额（分）= 录入原文数量 × 录入单位报价
  int? get grossCents {
    final int? qty = int.tryParse(quantity.text.trim());
    final int? price = Money.tryParseYuan(unitPrice.text.trim());
    if (qty == null || qty <= 0 || price == null || price < 0) return null;
    return qty * price;
  }

  /// 换算后的**最小单位数量**（`document_lines.quantity` 的值）。
  ///
  /// ⚠️ **数量没填 / 非法 ⇒ `null`**（**不换算、不兜底**）；换算失败也 `null`
  /// （validate 会带文案拦住）。
  ///
  /// #44（2026-10-14 裁定「甲」）：原来写 `entryQuantity: quantityValue ?? 0`
  /// —— 空框被 **0 兜底**，而 `toBaseQuantity` 对「没切单位」原样返回 `0`
  /// ⇒ 负库存判定退化成 `0 > estimated` ⇒ 快照为负时**空数量也报假告警**，
  /// 并挤掉「本地未同步」说明（M08 就是这么红的）。
  /// 判据：**「没有数量」是 `null`，不是 `0`** —— `null` 让调用方短路，
  /// `0` 会伪装成一个合法的比较值。
  int? get baseQuantityValue {
    final int? entry = quantityValue;
    if (entry == null) return null;
    return toBaseQuantity(
      entryQuantity: entry,
      entryUnit: entryUnit.isEmpty ? null : entryUnit,
      baseUnit: baseUnit ?? '',
      packageUnit: packageUnit,
      packageSize: packageSize,
    ).baseQuantityOrNull;
  }

  /// 本行小计（分）= 折前 − 让价（v3 真相口径）；字段没填全 ⇒ `null`
  int? get amountCents {
    final int? gross = grossCents;
    if (gross == null) return null;
    return gross - discountCents;
  }

  void dispose() {
    quantity.dispose();
    unitPrice.dispose();
    name.dispose();
    nameFocus.dispose();
    quantityFocus.dispose();
    priceFocus.dispose();
    unitFocus.dispose();
  }
}
