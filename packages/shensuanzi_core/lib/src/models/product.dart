import '../db/schema.dart';
import 'base.dart';

/// 商品（主数据，见 `docs/data_model.md` §2.1）
class Product extends MutableEntity {
  const Product({
    required this.id,
    required this.code,
    required this.name,
    this.barcode,
    this.unit = '件',
    this.costPrice = 0,
    this.sellPrice = 0,
    this.safetyStock = 0,
    this.category,
    this.isActive = true,
    this.remark,
    this.packageNote,
    required this.createdAt,
    required this.updatedAt,
    this.syncVersion = 0,
  });

  factory Product.fromRow(Map<String, Object?> row) => Product(
    id: row.requiredString('id'),
    code: row.requiredString('code'),
    name: row.requiredString('name'),
    barcode: row.optionalString('barcode'),
    unit: row.requiredString('unit'),
    costPrice: row.requiredInt('cost_price'),
    sellPrice: row.requiredInt('sell_price'),
    safetyStock: row.requiredInt('safety_stock'),
    category: row.optionalString('category'),
    isActive: row.requiredBool('is_active'),
    remark: row.optionalString('remark'),
    packageNote: row.optionalString('package_note'),
    createdAt: row.requiredInt('created_at'),
    updatedAt: row.requiredInt('updated_at'),
    syncVersion: row.requiredInt('sync_version'),
  );

  static const String table = Schema.products;

  @override
  final String id;
  final String code;
  final String name;
  final String? barcode;
  final String unit;

  /// 参考进价（分）。**不是成本真相** —— 成本真相在 `stock_ledger.total_cost`。
  final int costPrice;
  final int sellPrice;
  final int safetyStock;
  final String? category;
  final bool isActive;
  final String? remark;

  /// 包装说明（§AJ·AI-5）：如「1 箱 = 48 瓶」。**纯备注 —— 不参与任何
  /// 计算**，库存页展示用。用户按最小销售单位记账，看着库存数心算「几箱」时
  /// 靠它。可空（建档可不填）。
  final String? packageNote;
  final int createdAt;
  final int updatedAt;

  @override
  final int syncVersion;

  @override
  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'code': code,
    'name': name,
    'barcode': barcode,
    'unit': unit,
    'cost_price': costPrice,
    'sell_price': sellPrice,
    'safety_stock': safetyStock,
    'category': category,
    'is_active': boolToInt(isActive),
    'remark': remark,
    'package_note': packageNote,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'sync_version': syncVersion,
  };

  @override
  Product withSyncVersion(int version) => copyWith(syncVersion: version);

  Product copyWith({
    String? code,
    String? name,
    String? barcode,
    String? unit,
    int? costPrice,
    int? sellPrice,
    int? safetyStock,
    String? category,
    bool? isActive,
    String? remark,
    String? packageNote,
    int? updatedAt,
    int? syncVersion,
  }) => Product(
    id: id,
    code: code ?? this.code,
    name: name ?? this.name,
    barcode: barcode ?? this.barcode,
    unit: unit ?? this.unit,
    costPrice: costPrice ?? this.costPrice,
    sellPrice: sellPrice ?? this.sellPrice,
    safetyStock: safetyStock ?? this.safetyStock,
    category: category ?? this.category,
    isActive: isActive ?? this.isActive,
    remark: remark ?? this.remark,
    packageNote: packageNote ?? this.packageNote,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    syncVersion: syncVersion ?? this.syncVersion,
  );
}
