import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../db/read_failures.dart';
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

  /// 本地时区相对 UTC 的偏移（毫秒，东八区 = +28 800 000）。
  ///
  /// 只给 [_summaries] 的「按日分桶」排序用。**刻意不在 SQL 里用 `'localtime'`
  /// 修饰符** —— 本仓打包的 SQLite 带了 `SQLITE_OMIT_LOCALTIME`，那会返回 `NULL`
  /// 让排序静默退化（2026-10-18 实测，见该处注释）。
  int get _localOffsetMillis => DateTime.now().timeZoneOffset.inMilliseconds;

  /// `LIKE` 的转义（配合 SQL 里的 `ESCAPE '\'`）。
  ///
  /// **顺序不能反**：先转义反斜杠本身，再转义 `%` / `_` —— 否则会把刚加上的
  /// 转义符再转一遍，用户搜「50\%」就永远命中不到。
  ///
  /// 不转义会怎样（真实场景）：用户搜「50%」⇒ `%` 变通配符 ⇒ **全表命中**；
  /// 搜「_」⇒ 命中**所有**单据（`_` = 任意一个字符）。
  static String _escapeLike(String raw) => raw
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

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
      returnedAgainstMany(<String>[refDocId])[refDocId]?.sum ?? 0;

  /// 批量版：列表页 200 行**一次查完**（不许 N+1）。
  /// 返回只含「有退货的」单据；没退货的不在 map 里（取值用 [ReturnAgg.zero]）。
  ///
  /// #26 批 3：返回值从「金额」扩成 [ReturnAgg]（**次数 + 金额**）——
  /// 列表行要显示「已退 **2** 次 ¥240.00」，光有金额说不出次数。
  Map<String, ReturnAgg> returnedAgainstMany(Iterable<String> refDocIds) {
    final List<String> ids = refDocIds.toList(growable: false);
    if (ids.isEmpty) return const <String, ReturnAgg>{};
    final String placeholders = List<String>.filled(ids.length, '?').join(',');
    final ResultSet rows = _raw.select(
      '''
      SELECT ref_doc_id AS ref, COUNT(*) AS n, COALESCE(SUM(total_amount), 0) AS sum
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
    return <String, ReturnAgg>{
      for (final Row row in rows)
        row['ref']! as String: ReturnAgg(
          count: row['n']! as int,
          sum: row['sum']! as int,
        ),
    };
  }

  /// 批量：每张单被**核销了几笔**（列表行摘要「已收 N 笔」用）。
  ///
  /// ⚠️ **一次 `IN (…) + GROUP BY`**，绝不逐行调 [settledAmountOf] ——
  /// 200 行 = 200 次 SQL，正是审查盲点 ④ 要防的 N+1。
  /// `idx_settle_target` 让这是索引内聚合（`schema.dart`）。
  Map<String, int> settlementCountsMany(Iterable<String> targetDocIds) {
    final List<String> ids = targetDocIds.toList(growable: false);
    if (ids.isEmpty) return const <String, int>{};
    final String placeholders = List<String>.filled(ids.length, '?').join(',');
    final ResultSet rows = _raw.select(
      'SELECT target_doc_id AS t, COUNT(*) AS n FROM ${Schema.settlements} '
      'WHERE target_doc_id IN ($placeholders) GROUP BY target_doc_id',
      ids,
    );
    return <String, int>{
      for (final Row row in rows) row['t']! as String: row['n']! as int,
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
    String? query,
    bool rootsOnly = false,
  }) => _summaries(
    types: types,
    statusViews: statusViews,
    sinceMillis: sinceMillis,
    untilMillis: untilMillis,
    limit: limit,
    includeDerived: includeDerived,
    query: query,
    rootsOnly: rootsOnly,
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
    String? query,
  }) => _summaries(
    types: types,
    statusViews: statusViews,
    sinceMillis: sinceMillis,
    untilMillis: untilMillis,
    limit: null,
    includeDerived: includeDerived,
    query: query,
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
    // #42 甲 · L1：坏行 ⇒ 跳过 + 计数（不再让单据详情页整页变灰）
    final ReturnAgg returns = returnedAgainstMany(<String>[id])[id] ?? ReturnAgg.zero;
    final List<DocumentSummary> found = decodeRows(
      rows,
      (Map<String, Object?> row) => DocumentSummary(
        document: Document.fromRow(row, failures: db.readFailures),
        partyName: row['party_name'] as String?,
        returnedCents: returns.sum,
        returnedCount: returns.count,
        settlementCount: settlementCountsMany(<String>[id])[id] ?? 0,
      ),
      table: Schema.documents,
      failures: db.readFailures,
    );
    return found.isEmpty ? null : found.first;
  }

  List<DocumentSummary> _summaries({
    Set<DocType> types = const <DocType>{},
    Set<DocumentStatusView> statusViews = const <DocumentStatusView>{},
    int? sinceMillis,
    int? untilMillis,
    String? refDocId,
    required int? limit,
    bool includeDerived = false,
    String? query,
    bool rootsOnly = false,
  }) {
    final List<Object?> args = <Object?>[];
    final List<String> conditions = <String>[];

    if (rootsOnly) {
      // **生命周期聚合**（#26 批 3 甲案）：只列「根」—— 一笔生意一行。
      //
      // 根 = ① `ref_doc_id IS NULL` 的单据（主单 + 收付款单）
      //      ② **但**「只核销了一张单」的收付款单不算根 —— 它是那笔生意的「已收/已付」。
      //
      // ⚠️ 为什么必须有 ②（2026-10-18 用户复跑抓出的缺口）：
      // `SettlementService.settle`（详情页点 [收款]）生成的收款单 **`ref_doc_id` 是 NULL**
      // —— 它与被核销单的关联只存在 `settlements.receipt_doc_id → target_doc_id`。
      // 只看 `ref_doc_id` 的话，赊账销售 + 手记收款仍然是**两行**，
      // 用户还得自己去找「这张单的收款单」—— 正是 #26③ 要消灭的东西。
      //
      // 边界（都保留为根，不硬塞）：
      // - **0 个核销目标**：客户直接给钱、没对应单据 ⇒ 它本身就是一笔生意；
      // - **≥2 个核销目标**：一张收款结清多张单 ⇒ 归不到任何一笔，硬塞就是撒谎。
      //
      // 子 = 自动收付款 / 退货（`ref_doc_id = 根`），孙 = 退款（挂退货单）。
      //
      // ⚠️ 这一行**取代**了下面那段「折叠派生单据」的复杂条件（`NOT (... EXISTS ...)`）：
      // 派生单据必有 `ref_doc_id`，所以「只列根」自动把它们全折进去 ——
      // 包括 2026-10-05 裁定要**独立显示**的正常部分退货单。
      // ⇒ **那条裁定被本批推翻**（`docs/reply.md` 2026-10-18：甲案 + 强制补偿），
      //   补偿 = 行内「已退 N 次」加粗 + 详情页「退货记录」上移。
      conditions.add(
        'd.ref_doc_id IS NULL AND NOT ('
        "d.doc_type IN ('${DocType.receipt.wire}', '${DocType.payment.wire}') AND ("
        'SELECT COUNT(DISTINCT s.target_doc_id) FROM ${Schema.settlements} s '
        'WHERE s.receipt_doc_id = d.id AND s.target_doc_id IS NOT NULL'
        ') = 1)',
      );
    }
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
    if (query != null && query.trim().isNotEmpty) {
      // **按内容找单**（#26「搜索」，§CV·六十二 批 2）。四路匹配，任一命中即可：
      //  ① 本单号      ② 对方名      ③ **子单号**      ④ **明细里的商品名**
      //
      // ③④ 是为了「聚合后仍能找到那笔生意」：用户手里可能只有一张退货单的号，
      // 或只记得「退过苹果」。只看本单的话，这两个入口都断了。
      //
      // ⚠️ `ESCAPE '\'` **必须显式写**：SQLite 没有默认转义符，不写的话用户
      // 搜「50%」会变成通配符、搜「_」会命中所有单（`_` 在 LIKE 里是「任意一个字符」）。
      final String pattern = '%${_escapeLike(query.trim())}%';
      conditions.add(
        '('
        "d.doc_no LIKE ? ESCAPE '\\' "
        "OR pa.name LIKE ? ESCAPE '\\' "
        'OR EXISTS (SELECT 1 FROM ${Schema.documents} c '
        "WHERE c.ref_doc_id = d.id AND c.doc_no LIKE ? ESCAPE '\\') "
        'OR EXISTS (SELECT 1 FROM ${Schema.documentLines} l '
        'JOIN ${Schema.products} p ON p.id = l.product_id '
        'JOIN ${Schema.documents} cd ON cd.id = l.document_id '
        "WHERE (cd.id = d.id OR cd.ref_doc_id = d.id) AND p.name LIKE ? ESCAPE '\\')"
        ')',
      );
      args.addAll(<Object?>[pattern, pattern, pattern, pattern]);
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
    if (!includeDerived && !rootsOnly) {
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
      // ⚠️ **本段在 `rootsOnly` 下整段不执行**（#26 批 3）：那种模式下
      // 「只列根」已经把**所有**派生单据折进去了，包括这里说的「正常部分退货」。
      // 那条 2026-10-05 裁定已被推翻（见上面的注释与 `docs/reply.md` 2026-10-18）。
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
    // ⚠️ ORDER BY 里那个 `?` 的参数（本地时区偏移）—— **必须排在 LIMIT 之前**，
    // 占位符是按出现顺序绑定的。
    args.add(_localOffsetMillis);
    final String tail = limit == null ? '' : 'LIMIT ?';
    if (limit != null) args.add(limit);

    // `r` = 按原单汇总的退货额。列表行要显示「已退 ¥x」（§审查 BUG-04），
    // 状态筛选「未结清」也要用它 —— 一起 JOIN 掉，**避免 N+1**。
    final List<Map<String, Object?>> rows = _raw.select(
      'SELECT d.*, pa.name AS party_name, '
      'COALESCE(r.rsum, 0) AS returned_sum, '
      'COALESCE(r.rcnt, 0) AS returned_count '
      'FROM ${Schema.documents} d '
      'LEFT JOIN ${Schema.parties} pa ON pa.id = d.party_id '
      'LEFT JOIN ('
      'SELECT ref_doc_id AS ref, SUM(total_amount) AS rsum, COUNT(*) AS rcnt '
      'FROM ${Schema.documents} '
      'WHERE ref_doc_id IS NOT NULL AND '
      "doc_type IN ('${DocType.saleReturn.wire}', "
      "'${DocType.purchaseReturn.wire}') "
      'GROUP BY ref_doc_id'
      ') r ON r.ref = d.id '
      '$where'
      // ⚠️ **按「日」分桶，日内按录入时刻倒序**（#26①，2026-10-18 裁定甲）。
      //
      // 为什么不能直接 `ORDER BY d.occurred_at DESC`：这一列**存着两套口径** ——
      // 主单是**当天 00:00**（开单页只能选到日，`sale_draft.dart` 的 `occurredAt`），
      // 退货 / 手记收付款是**精确时刻**（`return_service` / `settlement_service`）。
      // 直接比大小 ⇒ 同一天的派生单全 > 主单的 00:00，`created_at` 那段兜底**永不生效**，
      // 21:11 录的主单会被排到 16:48 的退货单后面（用户实证，§CV·六十二）。
      //
      // 为什么是整数分桶而不是 `date(occurred_at/1000,'unixepoch','localtime')`：
      // **本仓打包的 SQLite 编译时带了 `SQLITE_OMIT_LOCALTIME`**，带 `'localtime'`
      // 修饰符会**返回 NULL**（2026-10-18 实测 `bucket=null`）⇒ 排序会静默退化。
      // 改成「加本地偏移后整除一天」：纯整数运算，不依赖 TZ 数据库，也不依赖修饰符。
      //
      // ⚠️ 前提是**单一时区**（个体户单机，`Agents.md` §一）。跨时区同步已在 #32 登记待办；
      // 有夏令时的时区里，「零点前 1 小时」的单可能被分到相邻一天 —— 中国无夏令时。
      'ORDER BY ((d.occurred_at + ?) / 86400000) DESC, '
      'd.created_at DESC '
      '$tail',
      args,
    );
    // #42 甲 · L1：逐行保护（单据列表 —— 一条坏行不再让整页打不开）
    final List<DocumentSummary> found = decodeRows(
      rows,
      (Map<String, Object?> row) => DocumentSummary(
        document: Document.fromRow(row, failures: db.readFailures),
        partyName: row['party_name'] as String?,
        returnedCents: (row['returned_sum'] as int?) ?? 0,
        returnedCount: (row['returned_count'] as int?) ?? 0,
      ),
      table: Schema.documents,
      failures: db.readFailures,
    );
    if (found.isEmpty) return found;
    // 核销笔数：**一次** `IN (…) + GROUP BY`，不是逐行（审查盲点 ④）
    final Map<String, int> settled = settlementCountsMany(
      found.map((DocumentSummary e) => e.document.id),
    );
    return <DocumentSummary>[
      for (final DocumentSummary e in found)
        DocumentSummary(
          document: e.document,
          partyName: e.partyName,
          returnedCents: e.returnedCents,
          returnedCount: e.returnedCount,
          settlementCount: settled[e.document.id] ?? 0,
        ),
    ];
  }

  Document? findById(String id) {
    final List<Document> found = decodeRows(
      _raw.select(
        'SELECT * FROM ${Schema.documents} WHERE id = ?',
        <Object?>[id],
      ),
      (Map<String, Object?> row) =>
          Document.fromRow(row, failures: db.readFailures),
      table: Schema.documents,
      failures: db.readFailures,
    );
    return found.isEmpty ? null : found.first;
  }

  List<DocumentLine> linesOf(String documentId) => decodeRows(
    _raw.select(
      'SELECT * FROM ${Schema.documentLines} WHERE document_id = ? ORDER BY rowid',
      <Object?>[documentId],
    ),
    DocumentLine.fromRow,
    table: Schema.documentLines,
    failures: db.readFailures,
  );

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
    this.returnedCount = 0,
    this.settlementCount = 0,
  });

  final Document document;

  /// 对方名；散客 / 散采（无对方）为 `null` —— UI 显示「散客」/「散采」
  final String? partyName;

  /// 该单**已发生的退货冲减额**（分）—— 真实未收的第三项（§审查 BUG-04）。
  ///
  /// 列表由 [_summaries] 一次 JOIN 带出（200 行不做 N+1）；
  /// 详情由 [summaryById] 单独查一次。
  final int returnedCents;

  /// 该单被退过**几次**（#26 批 3：行内「已退 N 次」）。
  ///
  /// 与 [returnedCents] 同一个 JOIN 带出 —— 光有金额说不出「几次」，
  /// 而「几次」是用户判断「这笔生意折腾了几轮」的信号。
  final int returnedCount;

  /// 该单被**核销过几笔**（行内「已收 N 笔 / 已付 N 笔」）。
  ///
  /// 由 [DocumentDao.settlementCountsMany] **一次批量**带出（审查盲点 ④：
  /// 绝不逐行查）。
  final int settlementCount;
}

/// 一张单被退货的**次数与金额**（#26 批 3）。
///
/// 为什么单独成类而不是返回 `Map<String, int>`：列表行要同时显示
/// 「已退 **2** 次 ¥240.00」—— 两个数同源同查，分开取必然漂。
class ReturnAgg {
  const ReturnAgg({required this.count, required this.sum});

  /// 没退过货（map 里查不到时用它，免得处处 `?? 0` 两遍）
  static const ReturnAgg zero = ReturnAgg(count: 0, sum: 0);

  final int count;
  final int sum;
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
