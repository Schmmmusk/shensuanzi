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
  ///
  /// ⚠️ 排序用 `(created_at, id)` 而不是 `code`：编码虽然是补零的，
  /// 但**定宽总会在某个位数上断掉**（`P10000` 的字典序小于 `P9999`），
  /// 一旦断掉列表顺序就会诡异地跳动。`(created_at, id)` 是真正的建档顺序，
  /// 也与 `sync_protocol.md` §七 的排序约定一致。
  List<Product> findAll({String? query, bool? active, int limit = 200}) =>
      _select(query: query, active: active, limit: limit);

  /// **导出用**：不分页（§AF-5）。
  ///
  /// ⚠️ `active` 默认 `null` = **含停用** —— 与页面列表（默认只看启用）**不同**：
  /// 导出是「把数据带走」，**偷偷少东西是不可接受的**（AF-12）。
  List<Product> findAllForExport({String? query, bool? active}) =>
      _select(query: query, active: active, limit: null);

  List<Product> _select({String? query, bool? active, required int? limit}) {
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
    final String tail = limit == null ? '' : ' LIMIT ?';
    if (limit != null) args.add(limit);
    return _raw
        .select(
          'SELECT * FROM ${Schema.products}$where '
          'ORDER BY created_at, id$tail',
          args,
        )
        .map(Product.fromRow)
        .toList(growable: false);
  }

  /// 当前最大的商品编码（`P0001` 里的 `P` 前缀 + 数字）。
  ///
  /// ⚠️ **排序必须 `LENGTH(code) DESC, code DESC`，不能只按 `code DESC`**：
  /// 编码是**定宽补零**的，4 位之后（`P10000`）字典序小于 `P9999`，
  /// 只按 `code DESC` 会取回 `P9999` ⇒ 生成器算出 `P10000` ⇒ **撞 UNIQUE**。
  /// 先比长度再比字典序，等价于「数值最大」。
  ///
  /// 只认 `P` 前缀，用户手工写过的其它编码不参与（也不会被覆盖）。
  String? latestCode() {
    final ResultSet rows = _raw.select(
      "SELECT code FROM ${Schema.products} WHERE code LIKE 'P%' "
      'ORDER BY LENGTH(code) DESC, code DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    return rows.first['code']! as String;
  }

  /// 按条码找商品（建档查重 / 扫码开单要用）。返回**全部**匹配项，按建档顺序。
  ///
  /// ⚠️ **不要改回「取最早一条」**（`docs/reply.md` R-15 裁定）：
  /// 条码允许重复（同箱拆卖、同款不同批次），静默挑一条会让用户
  /// 「扫 A 得到 B」，直接判软件坏了。调用方按匹配数分流：
  /// 0 条 → 提示没找到；1 条 → 直接用；**≥2 条 → 让用户自己选**。
  ///
  /// 不加 `LIMIT`，也不过滤 `is_active`：停用只是「不再卖」，
  /// 条码该显示的归属还是它（不然用户会觉得条码凭空消失了）。
  List<Product> findByBarcode(String barcode) {
    if (barcode.isEmpty) return const <Product>[];
    return _raw
        .select(
          'SELECT * FROM ${Schema.products} WHERE barcode = ? '
          'ORDER BY created_at, id',
          <Object?>[barcode],
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
        category = ?, is_active = ?, remark = ?, package_note = ?,
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
        product.packageNote,
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

  /// 恢复启用（与 [softDelete] 对称，`sync_version` 同样 +1）
  void activate(String id, {required int updatedAt}) {
    _raw.execute(
      'UPDATE ${Schema.products} SET is_active = 1, sync_version = sync_version + 1, '
      'updated_at = ? WHERE id = ?',
      <Object?>[updatedAt, id],
    );
  }
}

/// `bool` → SQLite `INTEGER`（DAO 内部用；与 `models/base.dart` 的同名函数重复是为了
/// 让 DAO 层不依赖模型层）
int boolToIntSql(bool value) => value ? 1 : 0;
