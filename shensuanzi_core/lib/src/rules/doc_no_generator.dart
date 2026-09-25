import '../dao/document_dao.dart';
import '../db/database.dart';
import '../models/document.dart';

/// 正式单号生成器（**主机侧**，`Agents.md` 裁定表）。
///
/// 格式：`<前缀><YYYYMMDD>-<三位序号>`，如 `XS20260925-001`。
/// 客户端离线期写的 `待同步-XXXXXX` 只是展示占位，**落库前由本类替换**。
///
/// ⚠️ 必须在事务内调用 —— 否则同日同前缀的并发生成会撞号
/// （`documents.doc_no` 是 `UNIQUE`）。
class DocNoGenerator {
  DocNoGenerator(this.db) : _docs = DocumentDao(db);

  final Db db;
  final DocumentDao _docs;

  /// 各单据类型的单号前缀
  static const Map<DocType, String> prefixes = <DocType, String>{
    DocType.purchase: 'CG',
    DocType.sale: 'XS',
    DocType.delivery: 'SH',
    DocType.saleReturn: 'XT',
    DocType.purchaseReturn: 'CT',
    DocType.stocktake: 'PD',
    DocType.receipt: 'SK',
    DocType.payment: 'FK',
    DocType.transfer: 'DB',
  };

  /// [occurredAtMs] 用**主机本地日期**决定日期段（业务日期，不是 UTC 日）
  String next(DocType type, {required int occurredAtMs}) {
    if (!db.inTransaction) {
      throw StateError('单号必须在事务内生成，否则并发会撞号');
    }
    final String prefix = _prefixWithDate(type, occurredAtMs);
    final String? latest = _docs.latestDocNo(prefix);
    int seq = 1;
    if (latest != null) {
      final int? parsed = int.tryParse(latest.substring(prefix.length));
      if (parsed == null) {
        throw StateError('已有单号格式异常，无法解析序号：$latest');
      }
      seq = parsed + 1;
    }
    return '$prefix${seq.toString().padLeft(3, '0')}';
  }

  String _prefixWithDate(DocType type, int occurredAtMs) {
    final String? prefix = prefixes[type];
    if (prefix == null) {
      throw ArgumentError('没有为 $type 定义单号前缀');
    }
    final DateTime local = DateTime.fromMillisecondsSinceEpoch(
      occurredAtMs,
    ).toLocal();
    final String date =
        '${local.year}'
        '${local.month.toString().padLeft(2, '0')}'
        '${local.day.toString().padLeft(2, '0')}';
    return '$prefix$date-';
  }
}
