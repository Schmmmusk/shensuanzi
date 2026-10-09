import '../dao/product_dao.dart';
import '../db/database.dart';

/// 商品编码生成器（**主机侧**）。
///
/// 格式：`P` + 序号，如 `P0001`（不足 4 位补零，超过 4 位自然增长）。
///
/// ## 为什么编码要系统生成（`docs/reply.md` 裁定）
///
/// 个体工商户**没有自己的编码体系**。让用户填「货号」，结果只有两种：
/// 空着，或者一人一个样（`1` / `A1` / `苹果`）。系统生成之后：
///
/// - 列表有一个稳定的引用依据（单据、条码之外的第三把钥匙）
/// - 用户**永远不需要维护它** —— 真想自定义，第二阶段加一个「编辑编码」入口即可
///
/// ## 与 `DocNoGenerator` 的差别
///
/// 单号带日期段（`XS20260926-001`），商品编码不带 —— 商品是**长期存在**的档案，
/// 跨日期还要能比较大小。
///
/// ⚠️ **必须在事务内调用**：与 `SeqCounter` / `DocNoGenerator` 同理，
/// 生成与写入之间被其它写入插入就会撞号（`products.code` 是 `UNIQUE`）。
class ProductCodeGenerator {
  ProductCodeGenerator(this.db) : _products = ProductDao(db);

  final Db db;
  final ProductDao _products;

  static const String prefix = 'P';

  /// 补零宽度：`P0001`。超过 4 位不再补零（`P10000`）——
  /// 取最大值的 SQL 已按「先长度后字典序」处理，位数变化不会取错（见 `latestCode`）。
  static const int padWidth = 4;

  /// **主机编码格式的唯一定义**：`P` + 数字（`P0001`；超 4 位自然增长，如 `P10000`）。
  ///
  /// [next] 按它解析序号；`ProductService.resolvePreferredCode` 按它**验收**
  /// 客户端建议的编码（§CV·七 温和收紧：不匹配 ⇒ 视同未提供）。
  /// —— 两处共用**同一个** pattern，将来改前缀只动这里。
  static final RegExp pattern = RegExp('^$prefix\\d+\$');

  String next() {
    if (!db.inTransaction) {
      throw StateError(
        '商品编码必须在事务内生成，否则并发会撞号（products.code 是 UNIQUE）。'
        '请把调用放进 ProductService 的事务里。',
      );
    }

    final String? latest = _products.latestCode();
    if (latest == null) {
      return '$prefix${1.toString().padLeft(padWidth, '0')}';
    }

    final int? parsed = int.tryParse(latest.substring(prefix.length));
    if (parsed == null) {
      throw StateError('已有商品编码格式异常，无法解析序号：$latest');
    }
    return '$prefix${(parsed + 1).toString().padLeft(padWidth, '0')}';
  }
}
