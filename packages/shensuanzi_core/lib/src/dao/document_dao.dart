import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/schema.dart';
import '../models/document.dart';
import '../models/document_line.dart';

/// 单据 DAO。**不开事务**（`Agents.md` 纪律 1）。
///
/// ⚠️ 本 DAO **只提供两个写入口**：
/// - [insert] / [insertIfAbsent]：新建单据（业务数据只插入）
/// - [updateStatusAndPaid]：**唯一**允许的 UPDATE，且只碰白名单三列
///
/// 其余任何 UPDATE 都必须在这里加方法并同步 `docs/data_model.md`。
class DocumentDao {
  DocumentDao(this.db);

  final Db db;

  Database get _raw => db.raw;

  /// 幂等插入（同步路径的核心）：单据已存在返回 `false` 且**不修改任何数据**。
  /// 客户端重试因此不会产生重复单据（`docs/sync_protocol.md` §二）。
  bool insertIfAbsent(Document document, List<DocumentLine> lines) {
    if (exists(document.id)) return false;
    insert(document, lines);
    return true;
  }

  /// 该单**已发生的退货冲减额**（分）—— 「真实未收」的第三项（§审查 BUG-04）。
  ///
  /// 口径：`sale_return` / `purchase_return` 里 `ref_doc_id = 原单` 的
  /// `total_amount` 之和。为什么不在 `documents` 加列：不改已冻结的
  /// `paid_amount` 口径、不引新的状态分歧 —— **派生态用派生查询**。
  int returnedAgainst(String refDocId) =>
      returnedAgainstMany(<String>[refDocId])[refDocId] ?? 0;

  /// 批量版：列表页 200 行**一次查完**（不许 N+1）。
  /// 返回只含「有退货的」单据；没退货的不在 map 里（取值用 `?? 0`）。
  Map<String, int> returnedAgainstMany(Iterable<String> refDocIds) {
    final List<String> ids = refDocIds.toList(growable: false);
    if (ids.isEmpty) return const <String, int>{};
    final String placeholders = List<String>.filled(ids.length, '?').join(',');
    final ResultSet rows = _raw.select(
      '''
      SELECT ref_doc_id AS ref, COALESCE(SUM(total_amount), 0) AS sum
      FROM ${Schema.documents}
      WHERE doc_type IN (?, ?) AND ref_doc_id IN ($placeholders)
      GROUP BY ref_doc_id
      ''',
      <Object?>[
        DocType.saleReturn.wire,
        DocType.purchaseReturn.wire,
        ...ids,
      ],
    );
    return <String, int>{
      for (final Row row in rows)
        row['ref']! as String: row['sum']! as int,
    };
  }

  void insert(Document document, List<DocumentLine> lines) {
    insertRow(document);
    for (final DocumentLine line in lines) {
      insertLine(line);
    }
  }

  void insertRow(Document document) {
    final Map<String, Object?> row = document.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.documents} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
  }

  void insertLine(DocumentLine line) {
    final Map<String, Object?> row = line.toRow();
    _raw.execute(
      'INSERT INTO ${Schema.documentLines} (${row.keys.join(', ')}) '
      'VALUES (${List<String>.filled(row.length, '?').join(', ')})',
      row.values.toList(),
    );
  }

  bool exists(String id) => _raw
      .select('SELECT 1 FROM ${Schema.documents} WHERE id = ? LIMIT 1', <Object?>[
        id,
      ])
      .isNotEmpty;

  /// 单据列表查询（§AC：单据页，只读）。
  ///
  /// - [type] 筛选单据类型；`null` = 全部
  /// - [sinceMillis] 只返回 `occurred_at >=` 该时间的（时间范围筛选）
  /// - JOIN parties 带回**对方名**（散客/散采的 `party_id` 为空 ⇒ `partyName` 为
  ///   `null`，UI 显示「散客」/「散采」而不是空白，§AA 六同款处理）
  /// - 按 `occurred_at` 降序、`created_at` 降序兜底
  /// 列表（默认过滤掉**自动生成的收付款单**，见 [_summaries]）
  List<DocumentSummary> listDocuments({
    Set<DocType> types = const <DocType>{},
    Set<DocumentStatusView> statusViews = const <DocumentStatusView>{},
    int? sinceMillis,
    int? untilMillis,
    int limit = 200,
    bool includeDerived = false,
  }) => _summaries(
    types: types,
    statusViews: statusViews,
    sinceMillis: sinceMillis,
    untilMillis: untilMillis,
    limit: limit,
    includeDerived: includeDerived,
  );

  /// 该单产生的**库存流水差额**（商品 → 带符号数量）。
  ///
  /// 盘点单详情页用（§审查 OBS-09②）：**账面 = 实盘 − 差额**。
  /// 为什么只能从这里反推：盘点单落库后账已经变了，只有流水记得**当时改了多少**
  /// —— `document_lines.quantity` 的语义是「盘点后的**实际**数量」（AB-3），
  /// 不是差额，所以光看行看不出「盘之前是多少」。
  ///
  /// 非盘点单也有意义（出库是负数），只是目前只有盘点单用它。
  Map<String, int> stockFlowByProductOf(String documentId) {
    final ResultSet rows = _raw.select(
      'SELECT product_id AS p, COALESCE(SUM(quantity), 0) AS q '
      'FROM ${Schema.stockLedger} '
      'WHERE document_id = ? GROUP BY product_id',
      <Object?>[documentId],
    );
    return <String, int>{
      for (final Row row in rows) row['p']! as String: row['q']! as int,
    };
  }

  /// 该单**发生过哪些退货**（§审查 2026-10-05：部分退货后详情页要能回答
  /// 「为什么 60 的单只收 40 就结清了」）。
  ///
  /// 按时间**倒序**；最近一次退货在最上面。
  List<DocumentSummary> returnsAgainst(String refDocId) => _summaries(
    types: const <DocType>{DocType.saleReturn, DocType.purchaseReturn},
    refDocId: refDocId,
    limit: null,
    includeDerived: true,
  );

  /// **导出用**：不分页（§AF-5）。
  ///
  /// 为什么另开一个入口而不是让调用方传 `limit: null`：导出跟列表的
  /// **失败代价完全不同** —— 列表少一行用户会翻页找，导出少一行
  /// **谁都不知道**（他拿去给会计了）。让「不分页」这件事在调用点
  /// 显式可读，比省一个方法重要。
  ///
  /// 过滤条件与 [listDocuments] **完全一致**（同一个 `_summaries`），
  /// 只是不设 `LIMIT`。个体户一年的单据几千条，一次读进内存无压力。
  List<DocumentSummary> listDocumentsForExport({
    Set<DocType> types = const <DocType>{},
    Set<DocumentStatusView> statusViews = const <DocumentStatusView>{},
    int? sinceMillis,
    int? untilMillis,
    bool includeDerived = false,
  }) => _summaries(
    types: types,
    statusViews: statusViews,
    sinceMillis: sinceMillis,
    untilMillis: untilMillis,
    limit: null,
    includeDerived: includeDerived,
  );

  /// 详情页用：按 id 取一行（含对方名）。不存在 → `null`。
  ///
  /// 与列表**同一份 JOIN**（`LEFT JOIN parties`），所以对方名的口径一致
  /// —— 散客 / 散采为 `null`，由 `documentPartyLabel` 统一成文字。
  DocumentSummary? summaryById(String id) {
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT d.*, pa.name AS party_name '
      'FROM ${Schema.documents} d '
      'LEFT JOIN ${Schema.parties} pa ON pa.id = d.party_id '
      'WHERE d.id = ? LIMIT 1',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    final Map<String, Object?> row = rows.first;
    return DocumentSummary(
      document: Document.fromRow(row),
      partyName: row['party_name'] as String?,
      returnedCents: returnedAgainst(id),
    );
  }

  List<DocumentSummary> _summaries({
    Set<DocType> types = const <DocType>{},
    Set<DocumentStatusView> statusViews = const <DocumentStatusView>{},
    int? sinceMillis,
    int? untilMillis,
    String? refDocId,
    required int? limit,
    bool includeDerived = false,
  }) {
    final List<Object?> args = <Object?>[];
    final List<String> conditions = <String>[];

    if (types.isNotEmpty) {
      conditions.add(
        'd.doc_type IN (${List<String>.filled(types.length, '?').join(', ')})',
      );
      args.addAll(types.map((DocType type) => type.wire));
    }
    if (refDocId != null) {
      conditions.add('d.ref_doc_id = ?');
      args.add(refDocId);
    }
    if (sinceMillis != null) {
      conditions.add('d.occurred_at >= ?');
      args.add(sinceMillis);
    }
    if (untilMillis != null) {
      // 上界**开区间**：自定义范围选到 10-05，含义是「到 10-05 当天结束」，
      // 调用方传的是次日 00:00（见 `documents_page`）
      conditions.add('d.occurred_at < ?');
      args.add(untilMillis);
    }
    if (statusViews.isNotEmpty) {
      final List<String> parts = <String>[];
      for (final DocumentStatusView view in statusViews) {
        switch (view) {
          case DocumentStatusView.unsettled:
            // 真实未收/未付 = 金额 − 已核销 − 该单累计退货冲减（§审查 BUG-04）。
            // 与 `SettlementService.unsettledCentsOf` 同一口径；作废单不算「欠钱」。
            //
            // ⚠️ 必须**限定「产生债权债务的主单」**：只有销售 / 采购 / 送货三种
            // 会留下欠款。退货单（`sale_return` / `purchase_return`）是**冲销**
            // 欠款的、本身不产生欠款；若一并算进来，「未结清」列表里会冒出
            // 一堆退货单（临时脚本 `_tmp_check.dart` 抓到过）。
            parts.add(
              '(d.doc_type IN ('
              "'${DocType.sale.wire}', '${DocType.purchase.wire}', "
              "'${DocType.delivery.wire}') "
              "AND d.status <> '${DocStatus.cancelled.wire}' AND "
              '(d.total_amount - d.paid_amount - COALESCE(r.rsum, 0)) > 0)',
            );
          case DocumentStatusView.cancelled:
            parts.add("d.status = '${DocStatus.cancelled.wire}'");
          case DocumentStatusView.awaitingSignature:
            parts.add("d.status = '${DocStatus.inTransit.wire}'");
        }
      }
      conditions.add('(${parts.join(' OR ')})');
    }
    if (!includeDerived) {
      // **派生单据不进默认列表**（§AN·二 / `docs/data_model.md` §3.6）：
      //
      // ① 自动生成的收付款单：销售时主机自动生成收款单，若也列出来，用户看到
      //    「一笔交易两条记录」会以为系统记重了。手动创建的收款单
      //    （`ref_doc_id IS NULL`）**要显示**。
      //
      // ② **原单已作废的全额退货单**（§审查 2026-10-05：拒收）：客户拒收后
      //    原送货单置 `cancelled`，同时生成一张**整单退回**的 `sale_return`。
      //    两张单内容一模一样，列表里并排出现等于「同一笔生意两个入口」。
      //    ⇒ 只在原单已作废时折叠（用 `EXISTS` 精确判定），**正常部分退货
      //    仍然必须显示** —— 它是独立交易（见 `settlement_view_test`）。
      //
      // ⚠️ 两个条件都必须**同时**限定 `doc_type` —— 只判 `ref_doc_id IS NOT NULL`
      // 会把退货单一起滤掉，退货凭空消失在列表里。
      conditions.add(
        'NOT (d.ref_doc_id IS NOT NULL AND ('
        "d.doc_type IN ('${DocType.receipt.wire}', '${DocType.payment.wire}') "
        'OR ('
        "d.doc_type IN ('${DocType.saleReturn.wire}', "
        "'${DocType.purchaseReturn.wire}') "
        'AND EXISTS (SELECT 1 FROM ${Schema.documents} o '
        "WHERE o.id = d.ref_doc_id AND o.status = '${DocStatus.cancelled.wire}')"
        ')))',
      );
    }
    final String where = conditions.isEmpty
        ? ''
        : 'WHERE ${conditions.join(' AND ')} ';
    final String tail = limit == null ? '' : 'LIMIT ?';
    if (limit != null) args.add(limit);

    // `r` = 按原单汇总的退货额。列表行要显示「已退 ¥x」（§审查 BUG-04），
    // 状态筛选「未结清」也要用它 —— 一起 JOIN 掉，**避免 N+1**。
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT d.*, pa.name AS party_name, '
      'COALESCE(r.rsum, 0) AS returned_sum '
      'FROM ${Schema.documents} d '
      'LEFT JOIN ${Schema.parties} pa ON pa.id = d.party_id '
      'LEFT JOIN ('
      'SELECT ref_doc_id AS ref, SUM(total_amount) AS rsum '
      'FROM ${Schema.documents} '
      'WHERE ref_doc_id IS NOT NULL AND '
      "doc_type IN ('${DocType.saleReturn.wire}', "
      "'${DocType.purchaseReturn.wire}') "
      'GROUP BY ref_doc_id'
      ') r ON r.ref = d.id '
      '$where'
      'ORDER BY d.occurred_at DESC, d.created_at DESC '
      '$tail',
      args,
    );
    return <DocumentSummary>[
      for (final Map<String, Object?> row in rows)
        DocumentSummary(
          document: Document.fromRow(row),
          partyName: row['party_name'] as String?,
          returnedCents: (row['returned_sum'] as int?) ?? 0,
        ),
    ];
  }

  Document? findById(String id) {
    final ResultSet rows = _raw.select(
      'SELECT * FROM ${Schema.documents} WHERE id = ?',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return Document.fromRow(rows.first);
  }

  List<DocumentLine> linesOf(String documentId) => _raw
      .select(
        'SELECT * FROM ${Schema.documentLines} WHERE document_id = ? ORDER BY rowid',
        <Object?>[documentId],
      )
      .map(DocumentLine.fromRow)
      .toList(growable: false);

  /// **唯一允许的 UPDATE 入口**。只写 `status` / `paid_amount` / `updated_at`。
  ///
  /// 只在**主机本地事务内**被调用（`RuleEngine`），客户端无法直接触发
  /// （`docs/sync_protocol.md` §三：状态变更走 `documentAction`）。
  void updateStatusAndPaid({
    required String id,
    required int updatedAt,
    DocStatus? status,
    int? paidAmount,
  }) {
    final List<String> sets = <String>[];
    final List<Object?> args = <Object?>[];
    if (status != null) {
      sets.add('status = ?');
      args.add(status.wire);
    }
    if (paidAmount != null) {
      sets.add('paid_amount = ?');
      args.add(paidAmount);
    }
    sets.add('updated_at = ?');
    args.add(updatedAt);
    args.add(id);
    _raw.execute(
      'UPDATE ${Schema.documents} SET ${sets.join(', ')} WHERE id = ?',
      args,
    );
  }

  /// 同前缀下已存在的最大单号（供 `DocNoGenerator` 解析序号）。
  /// [prefixWithDate] 形如 `XS20260925-`。
  String? latestDocNo(String prefixWithDate) {
    final ResultSet rows = _raw.select(
      'SELECT doc_no FROM ${Schema.documents} WHERE doc_no LIKE ? '
      'ORDER BY doc_no DESC LIMIT 1',
      <Object?>['$prefixWithDate%'],
    );
    if (rows.isEmpty) return null;
    return rows.first['doc_no']! as String;
  }

  /// 已核销额（真相口径）——`SUM(settlements.amount)`，
  /// 用于校验 `paid_amount` 缓存（`docs/data_model.md` §五 不变量 4）。
  int settledAmountOf(String targetDocId) {
    final Row row = _raw
        .select(
          'SELECT COALESCE(SUM(amount), 0) AS s FROM ${Schema.settlements} '
          'WHERE target_doc_id = ?',
          <Object?>[targetDocId],
        )
        .first;
    return row['s']! as int;
  }
}

/// [DocumentDao.listDocuments] 的一行：单据 + 对方名（LEFT JOIN，散客为 null）。
class DocumentSummary {
  const DocumentSummary({
    required this.document,
    required this.partyName,
    this.returnedCents = 0,
  });

  final Document document;

  /// 对方名；散客 / 散采（无对方）为 `null` —— UI 显示「散客」/「散采」
  final String? partyName;

  /// 该单**已发生的退货冲减额**（分）—— 真实未收的第三项（§审查 BUG-04）。
  ///
  /// 列表由 [_summaries] 一次 JOIN 带出（200 行不做 N+1）；
  /// 详情由 [summaryById] 单独查一次。
  final int returnedCents;
}

/// 列表的**状态视图**筛选（§审查 2026-10-05）。
///
/// 刻意**不是** `DocStatus`：`unsettled` 是派生的（金额 − 已核销 − 退货冲减），
/// 库里没有这个状态；`awaitingSignature` 则是「送货单还在途」的业务说法。
/// 放在 core 里，是为了让**导出与列表同一口径**（AF-5）。
enum DocumentStatusView {
  unsettled('未结清'),
  cancelled('已作废'),
  awaitingSignature('待签收');

  const DocumentStatusView(this.label);

  final String label;
}
