/// 商品建档表单（`docs/reply.md` 裁定的 **6 个字段**）。
///
/// ```
/// 商品名称   [                                ]
/// 单位       [ 件 ▾ ]      售价 [       ] 元
/// 进价       [       ] 元   安全库存 [     ]
/// 条码       [                                ]   ← 扫码枪可直接扫
/// ```
///
/// ## 为什么是「原文 + 校验」而不是「已解析的值」
///
/// 表单里用户看到的永远是**他自己敲的字符串**（`12.5` / `12.50` / `１２`）。
/// 本类保留原文，校验与解析分开做 —— 这样：
///
/// - 字段不合法时**原文还在**，用户改一个字就行，不用重填
/// - 校验逻辑是纯函数，能 `dart test` 钉住（界面只负责显示哪一栏红了）
///
/// ## 为什么字段是这几个（裁定书 §一）
///
/// | 字段 | 理由 |
/// |---|---|
/// | `name` / `unit` / `sell_price` | 开单必需：叫得出名字、说得出单位、算得出钱 |
/// | `cost_price` / `safety_stock` | **隐藏了用户就不知道有这回事** —— 进价不显示则毛利永远是 0，安全库存不显示则低库存告警永远不触发 |
/// | `barcode` | **补录成本远高于首次录入** —— 首次录入时用户手上正好有货，顺手就扫了；没有条码字段的用户大概率永远不会有条码 |
///
/// `code` 由 [ProductCodeGenerator] 生成；`category` / `remark` / `is_active`
/// 都不是建档时填的（`is_active` 是列表页的「停用」操作）。
library;

import '../models/product.dart';
import '../util/money.dart';

/// 表单字段（同时用作**错误定位的键** —— 界面据此知道该标红哪一栏）
enum ProductField {
  name('商品名称'),
  unit('单位'),
  sellPrice('售价'),
  costPrice('进价'),
  barcode('条码'),
  safetyStock('安全库存');

  const ProductField(this.label);

  final String label;
}

class ProductDraft {
  const ProductDraft({
    this.name = '',
    this.unit = '件',
    this.sellPrice = '',
    this.costPrice = '',
    this.barcode = '',
    this.safetyStock = '',
  });

  /// 从已有商品回填（编辑用）。金额按「分 → 元」展示，用户看到的就是库里存的值。
  factory ProductDraft.of(Product product) => ProductDraft(
    name: product.name,
    unit: product.unit,
    sellPrice: Money.format(product.sellPrice),
    costPrice: Money.format(product.costPrice),
    barcode: product.barcode ?? '',
    safetyStock: product.safetyStock.toString(),
  );

  /// 名称上限（表单护栏，不是 schema 约束）：防止误把一整段话粘进来
  static const int maxNameLength = 60;

  /// 条码上限：常见条码 ≤ 48 位，留些余量
  static const int maxBarcodeLength = 64;

  /// 商品名称（原文）
  final String name;

  /// 单位（原文，默认「件」）
  final String unit;

  /// 售价（**用户输入的「元」原文**）
  final String sellPrice;

  /// 进价（元原文；空 = 0）
  final String costPrice;

  /// 条码（原文；空 = 没有条码）
  final String barcode;

  /// 安全库存（原文；空 = 0）
  final String safetyStock;

  ProductDraft copyWith({
    String? name,
    String? unit,
    String? sellPrice,
    String? costPrice,
    String? barcode,
    String? safetyStock,
  }) => ProductDraft(
    name: name ?? this.name,
    unit: unit ?? this.unit,
    sellPrice: sellPrice ?? this.sellPrice,
    costPrice: costPrice ?? this.costPrice,
    barcode: barcode ?? this.barcode,
    safetyStock: safetyStock ?? this.safetyStock,
  );

  /// 校验。**空 map = 通过**；否则 `字段 → 给用户看的一句话`。
  ///
  /// 消息按 `docs/ui_principles.md` §五：**说「怎么办」，不说「哪里错了」**，
  /// 而且尽量带上例子（中老年用户靠例子理解，不靠抽象规则）。
  Map<ProductField, String> validate() {
    final Map<ProductField, String> errors = <ProductField, String>{};

    final String trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      errors[ProductField.name] = '请填商品名称，比如「红富士苹果」';
    } else if (trimmedName.length > maxNameLength) {
      errors[ProductField.name] = '名称太长了，请删到 $maxNameLength 个字以内';
    }

    if (unit.trim().isEmpty) {
      errors[ProductField.unit] = '请填单位，比如「件」「斤」「箱」';
    }

    _checkMoney(errors, ProductField.sellPrice, sellPrice, mustFill: true);
    _checkMoney(errors, ProductField.costPrice, costPrice, mustFill: false);
    _checkStock(errors);
    _checkBarcode(errors);

    return errors;
  }

  bool get isValid => validate().isEmpty;

  // ------------------------------------------------------------ 取值（校验通过后）
  String get normalizedName => name.trim();
  String get normalizedUnit => unit.trim();
  int get sellPriceCents => Money.tryParseYuan(sellPrice) ?? 0;
  int get costPriceCents => Money.tryParseYuan(costPrice) ?? 0;
  int get safetyStockValue => int.tryParse(safetyStock.trim()) ?? 0;

  /// 条码：空白一律归一成 `null`（**不要存空串** —— `NULL` 与 `''` 在查询与
  /// 唯一性判断里语义不同，混用迟早出问题）
  String? get normalizedBarcode {
    final String trimmed = barcode.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  // ------------------------------------------------------------ 断言细节
  void _checkMoney(
    Map<ProductField, String> errors,
    ProductField field,
    String raw, {
    required bool mustFill,
  }) {
    final String text = raw.trim();
    if (text.isEmpty) {
      if (mustFill) errors[field] = '请填${field.label}';
      return;
    }
    final int? cents = Money.tryParseYuan(text);
    if (cents == null) {
      errors[field] = '${field.label}只能填数字，最多两位小数，比如 12.50';
      return;
    }
    if (cents < 0) {
      errors[field] = '${field.label}不能是负数';
    }
  }

  void _checkStock(Map<ProductField, String> errors) {
    final String text = safetyStock.trim();
    if (text.isEmpty) return; // 空 = 0，不拦人
    final int? value = int.tryParse(text);
    if (value == null) {
      errors[ProductField.safetyStock] = '安全库存只能填整数，比如 10';
      return;
    }
    if (value < 0) {
      errors[ProductField.safetyStock] = '安全库存不能是负数';
    }
  }

  void _checkBarcode(Map<ProductField, String> errors) {
    final String text = barcode.trim();
    if (text.isEmpty) return; // 没有条码也能建档（见类文档）
    if (text.length > maxBarcodeLength) {
      errors[ProductField.barcode] = '条码太长了，请检查是不是贴错了别的内容';
    }
  }

  @override
  String toString() =>
      'ProductDraft(name=$name, unit=$unit, sell=$sellPrice, cost=$costPrice, '
      'barcode=${barcode.isEmpty ? '（无）' : barcode}, safety=$safetyStock)';
}
