/// 商品建档表单（`docs/reply.md` 裁定的 6 个字段 + §AJ·AI-5 的包装说明）。
///
/// ```
/// 商品名称   [                                ]
/// 单位       [ 件 ▾ ]      售价 [       ] 元
///            ↑ 最小销售单位（个/瓶/斤），不是进货的箱子单位
/// 包装说明   [ 1 箱 = 48 瓶 ]   ← 可选，纯备注不参与计算（§AJ·AI-5）
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
  safetyStock('安全库存'),
  packageNote('包装说明'),
  packageUnit('包装单位'),
  packageSize('包装换算');

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
    this.packageNote = '',
    this.packageUnit = '',
    this.packageSize = '',
  });

  /// 从已有商品回填（编辑用）。金额按「分 → 元」展示，用户看到的就是库里存的值。
  factory ProductDraft.of(Product product) => ProductDraft(
    name: product.name,
    unit: product.unit,
    sellPrice: Money.format(product.sellPrice),
    costPrice: Money.format(product.costPrice),
    barcode: product.barcode ?? '',
    safetyStock: product.safetyStock.toString(),
    packageNote: product.packageNote ?? '',
    packageUnit: product.packageUnit ?? '',
    packageSize: product.packageSize?.toString() ?? '',
  );

  /// 名称上限（表单护栏，不是 schema 约束）：防止误把一整段话粘进来
  static const int maxNameLength = 60;

  /// 条码上限：常见条码 ≤ 48 位，留些余量
  static const int maxBarcodeLength = 64;

  /// 包装说明上限（与名称同款护栏；正常就写「1 箱 = 48 瓶」这种一句话）
  static const int maxPackageNoteLength = 60;

  /// 商品名称（原文）
  final String name;

  /// 单位（原文，默认「件」）
  ///
  /// ⚠️ **单位 = 最小销售单位**（§AJ·AI-5 裁定）：库存、成本、流水全部按它记。
  /// 按箱进、按个卖的商品，这里填「个」，装箱关系写进 [packageNote]。
  final String unit;

  /// 售价（**用户输入的「元」原文**）
  final String sellPrice;

  /// 进价（元原文；空 = 0）
  final String costPrice;

  /// 条码（原文；空 = 没有条码）
  final String barcode;

  /// 安全库存（原文；空 = 0）
  final String safetyStock;

  /// 包装说明（原文；空 = 没填）。**纯备注，不参与任何计算**（§AJ·AI-5）
  final String packageNote;

  /// **包装单位名**（如「箱」）—— v3。与 [packageSize] **成对**：
  /// 两列同时有值才启用包装换算，任一为空 ⇒ 与 v2 行为一致
  /// （`docs/data_model.md` §2.1）。'' = 不启用。
  final String packageUnit;

  /// **1 包 = 多少最小单位**（正整数原文）—— v3，与 [packageUnit] 成对。
  /// '' = 不启用。
  final String packageSize;

  ProductDraft copyWith({
    String? name,
    String? unit,
    String? sellPrice,
    String? costPrice,
    String? barcode,
    String? safetyStock,
    String? packageNote,
    String? packageUnit,
    String? packageSize,
  }) => ProductDraft(
    name: name ?? this.name,
    unit: unit ?? this.unit,
    sellPrice: sellPrice ?? this.sellPrice,
    costPrice: costPrice ?? this.costPrice,
    barcode: barcode ?? this.barcode,
    safetyStock: safetyStock ?? this.safetyStock,
    packageNote: packageNote ?? this.packageNote,
    packageUnit: packageUnit ?? this.packageUnit,
    packageSize: packageSize ?? this.packageSize,
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
    _checkPackageNote(errors);
    _checkPackageConversion(errors);

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

  /// 包装说明：空白归一成 `null`（与条码同理，不存空串）
  String? get normalizedPackageNote {
    final String trimmed = packageNote.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 包装单位名：空白归一成 `null`（不启用 = `NULL`，不是 `''` ——
  /// 「成对启用」的判定依赖"非空"，空串会制造半配置）
  String? get normalizedPackageUnit {
    final String trimmed = packageUnit.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 包装换算数量：空白归一成 `null`；非数字/≤0 ⇒ `null`（validate 会拦）
  int? get normalizedPackageSize {
    final String trimmed = packageSize.trim();
    if (trimmed.isEmpty) return null;
    final int? size = int.tryParse(trimmed);
    return (size == null || size <= 0) ? null : size;
  }

  /// **包装换算两列的成对校验**（§BD·四 #2）：
  /// ① 成对 —— 只填一个 ⇒ 报没填的那个；② `packageSize > 0`；
  /// ③ 包装单位不能与最小单位相同（同名会让"选箱"走最小单位分支、
  /// `package_size` 被静默忽略 ⇒ 换算语义错乱）。
  void _checkPackageConversion(Map<ProductField, String> errors) {
    final String unitName = packageUnit.trim();
    final String sizeText = packageSize.trim();
    if (unitName.isEmpty && sizeText.isEmpty) return; // 都没填 = 不启用

    if (unitName.isEmpty) {
      errors[ProductField.packageUnit] =
          '填了「1 包 = 多少个」，就要给包装起个名字，比如「箱」';
    }
    if (sizeText.isEmpty) {
      errors[ProductField.packageSize] = '填了包装单位，就要填 1 包 = 多少个，比如 12';
    }
    if (unitName.isEmpty || sizeText.isEmpty) return; // 成对缺一，上面已报

    final int? size = int.tryParse(sizeText);
    if (size == null || size <= 0) {
      errors[ProductField.packageSize] = '包装换算数量要填正整数，比如 12';
    }
    if (unitName == unit.trim()) {
      errors[ProductField.packageUnit] =
          '包装单位不能和最小单位（${unit.trim()}）一样 —— '
          '一样的话「按箱换算」就失去意义了';
    }
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

  /// 包装说明**只拦超长**（防误粘一整段话），内容不管 —— 它是纯备注，
  /// 写「1 箱 = 48 瓶」还是「一箱 24 袋」都行，系统不读它（§AJ·AI-5）
  void _checkPackageNote(Map<ProductField, String> errors) {
    final String text = packageNote.trim();
    if (text.length > maxPackageNoteLength) {
      errors[ProductField.packageNote] =
          '包装说明太长了，写一句话就好，比如「1 箱 = 48 瓶」';
    }
  }

  @override
  String toString() =>
      'ProductDraft(name=$name, unit=$unit, sell=$sellPrice, cost=$costPrice, '
      'barcode=${barcode.isEmpty ? '（无）' : barcode}, safety=$safetyStock, '
      'packageNote=${packageNote.isEmpty ? '（无）' : packageNote})';

  // ------------------------------------------------------------ 条码重复提示（R-15）
  /// 条码已经被别人用过了吗 —— 有就返回给用户看的一句话，没有返回 `null`。
  ///
  /// ## 为什么是「提示」而不是「拦」
  ///
  /// 条码重复是**真实世界的常态**（同箱拆卖、同款不同批次），拦下来会挡住
  /// 合法操作；中老年用户被拦住的第一反应是「软件坏了」（`docs/reply.md` R-15）。
  /// 所以建档照旧放行，只在表单里**内联**提示一句。
  ///
  /// ## 为什么第二句不能省
  ///
  /// 「已经给谁用过」只说清了现状，用户接下来会担心「那我以后扫码怎么办」。
  /// 第二句把**下一步会发生什么**讲明白，用户才不会以为软件坏了 ——
  /// 这也与 `docs/ui_principles.md` §五「说『怎么办』」一致。
  ///
  /// [owners] 是 `ProductService.barcodeOwners` 的结果（**调用方负责排除自己**，
  /// 编辑时用 `excludeId`）；空列表 = 没人用过 = 不显示任何东西。
  static String? barcodeNotice(List<Product> owners) {
    if (owners.isEmpty) return null;

    final String names = owners.length <= 2
        ? owners.map((Product product) => '「${product.name}」').join()
        : '「${owners.first.name}」等 ${owners.length} 种商品';
    final String count = _countLabel(owners.length + 1);

    return '⚠️ 这个条码已经给$names用过了。\n保存后扫码会显示$count条商品供选择。';
  }

  /// 中文小数字：2~9 用「两/三/…」（「两条」比「2 条」更像人话），
  /// 10 以上退回阿拉伯数字（「十二条商品」反而难读）
  static String _countLabel(int value) {
    const List<String> chinese = <String>[
      '', '', '两', '三', '四', '五', '六', '七', '八', '九',
    ];
    if (value >= 2 && value < chinese.length) return chinese[value];
    return '$value';
  }
}
