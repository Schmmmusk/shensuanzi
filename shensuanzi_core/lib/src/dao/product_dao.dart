import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/schema.dart';
import '../models/product.dart';

/// 商品 DAO。
///
/// ⚠️ **不开事务** —— 事务由 `RuleEngine` / `SyncServer` 统一开（`Agents.md` 纪律 1）。
class ProductDao {
  ProductDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  /// 幂等插入（同步路径）：已存在返回 `false` 且**不修改任何数据**。
  bool insertIfAbsent(Product product) {
    if (exists(product.id)) return false;
    insert(product);
    return true;
  }

  void insert(Product product) {
    final Map<String, Object?> row = product.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.products} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
  }

  bool exists(String id) => _raw
      .select('SELECT 1 FROM ${Schema.products} WHERE id = ? LIMIT 1', <Object?>[
        id,
      ])
      .isNotEmpty;

  Product? findById(String id) {
    final ResultSet rows = _raw.select(
      'SELECT * FROM ${Schema.products} WHERE id = ?',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return Product.fromRow(rows.first);
  }

  /// 列表查询。[query] 模糊匹配 `code` / `name` / `barcode`。
  List<Product> findAll({String? query, bool? active, int limit = 200}) {
    final List<String> conditions = <String>[];
    final List<Object?> args = <Object?>[];
    if (active != null) {
      conditions.add('is_active = ?');
      args.add(boolToIntSql(active));
    }
    if (query != null && query.isNotEmpty) {
      conditions.add('(code LIKE ? OR name LIKE ? OR barcode LIKE ?)');
      final String like = '%$query%';
      args.addAll(<Object?>[like, like, like]);
    }
    final String where = conditions.isEmpty
        ? ''
        : ' WHERE ${conditions.join(' AND ')}';
    args.add(limit);
    return _raw
        .select(
          'SELECT * FROM ${Schema.products}$where ORDER BY code LIMIT ?',
          args,
        )
        .map(Product.fromRow)
        .toList(growable: false);
  }

  /// 主数据允许 UPDATE。`sync_version` 由调用方（`SyncServer`）决定新值。
  void update(Product product) {
    _raw.execute(
      '''
      UPDATE ${Schema.products} SET
        code = ?, name = ?, barcode = ?, unit = ?,
        cost_price = ?, sell_price = ?, safety_stock = ?,
        category = ?, is_active = ?, remark = ?,
        updated_at = ?, sync_version = ?
      WHERE id = ?
      ''',
      <Object?>[
        product.code,
        product.name,
        product.barcode,
        product.unit,
        product.costPrice,
        product.sellPrice,
        product.safetyStock,
        product.category,
        product.isActive ? 1 : 0,
        product.remark,
        product.updatedAt,
        product.syncVersion,
        product.id,
      ],
    );
  }

  /// 软删除（`Agents.md` 纪律 2：主数据软删，业务数据不删）
  void softDelete(String id, {required int updatedAt}) {
    _raw.execute(
      'UPDATE ${Schema.products} SET is_active = 0, sync_version = sync_version + 1, '
      'updated_at = ? WHERE id = ?',
      <Object?>[updatedAt, id],
    );
  }
}

/// `bool` → SQLite `INTEGER`（DAO 内部用；与 `models/base.dart` 的同名函数重复是为了
/// 让 DAO 层不依赖模型层）
int boolToIntSql(bool value) => value ? 1 : 0;
