import '../dao/document_dao.dart';
import '../dao/ledger_dao.dart';
import '../dao/settlement_dao.dart';
import '../db/database.dart';
import '../models/document.dart';
import '../models/document_line.dart';
import '../models/money_ledger.dart';
import '../models/party_ledger.dart';
import '../models/settlement.dart';
import '../models/stock_ledger.dart';
import '../util/ids.dart';
import 'cost_policy.dart';
import 'doc_no_generator.dart';
import 'payment_entry.dart';
import 'seq_counter.dart';

/// 规则执行结果。状态取值与 `docs/sync_protocol.md` §8.1 的响应一一对应。
enum RuleStatus {
  /// 已落库
  applied,

  /// 幂等命中：单据已存在，未修改任何数据
  alreadyExists,

  /// 拒绝（无对应规则 / 校验失败 / 事务回滚）
  rejected,
}

/// 一次规则执行的结果
class RuleOutcome {
  const RuleOutcome(this.status, {this.reason, this.document});

  final RuleStatus status;

  /// 仅 [RuleStatus.rejected] 时非空
  final String? reason;

  /// 落库后的**最终主单**（含主机分配的正式单号）
  final Document? document;

  bool get applied => status == RuleStatus.applied;

  @override
  String toString() =>
      'RuleOutcome(${status.name}${reason == null ? '' : ', $reason'})';
}

/// 业务规则引擎（`docs/rules.md`）。
///
/// ## 边界（`Agents.md` 纪律 1 / 9 / 11）
///
/// - **规则实现只此一份**，在主机侧；客户端不实现（只推 `Document`）
/// - **事务在这里统一开**：DAO 不开事务，[dispatch] 内部开一个可重入事务，
///   任一校验失败**整单回滚**
/// - **没有对应规则的 `doc_type` 一律 `rejected`**（如 v1 的 `transfer`）
/// - **任何资金流必须挂在收付款单下**：立即收付款由主机自动生成
///   `receipt` / `payment` 单，主单不直接写 `money_ledger`
///
/// ## 已实现
///
/// | 规则 | 状态 |
/// |---|---|
/// | RULE-001 采购入库（含立即付款） | ✅ |
/// | RULE-002 店内销售（含立即收款） | ✅ |
/// | RULE-003 送货 | ✅ 创建路径 + 主机本地签收 [markDelivered]（离线签收待 R-3） |
/// | RULE-004 收款核销 | ✅ |
/// | RULE-005 付款核销 | ✅ |
/// | RULE-007 销售退货 | ✅ |
/// | RULE-008 采购退货 | ✅ |
/// | RULE-009 盘点 | ✅ |
/// | `transfer` 调拨 | v1 一律 `rejected` |
///
/// ## 未实现（有意）
///
/// **离线签收**（`documentAction: mark_delivered`）需要「动作」这一抽象的
/// **幂等判定与存储**，属待裁定项 **R-3**，随 `SyncServer` 落地（见 `docs/reply.md`）。
/// v1 的替代路径是主机本地的 [markDelivered]（司机回店后手动改状态）。
class RuleEngine {
  RuleEngine(this.db)
    : _docs = DocumentDao(db),
      _stock = StockLedgerDao(db),
      _partyLedger = PartyLedgerDao(db),
      _moneyLedger = MoneyLedgerDao(db),
      _settlements = SettlementDao(db),
      _seq = SeqCounter(db),
      _docNo = DocNoGenerator(db) {
    _cost = CostPolicy(_stock);
  }

  final Db db;
  final DocumentDao _docs;
  final StockLedgerDao _stock;
  final PartyLedgerDao _partyLedger;
  final MoneyLedgerDao _moneyLedger;
  final SettlementDao _settlements;
  final SeqCounter _seq;
  final DocNoGenerator _docNo;
  late final CostPolicy _cost;

  /// 可作为核销目标的单据类型（`docs/data_model.md` §3.6）
  static const Set<DocType> allocatableTargetTypes = <DocType>{
    DocType.sale,
    DocType.purchase,
    DocType.saleReturn,
    DocType.purchaseReturn,
    DocType.delivery,
  };

  /// 退货单 → 它**可以**指向的原单类型（`docs/rules.md`）
  ///
  /// `sale_return` 有两个合法来源：
  /// - `sale` —— 普通销售退货
  /// - `delivery` —— **客户拒收**（`docs/rules.md` RULE-003 状态流转）
  ///
  /// 两者在成本口径上同构：`stock_ledger` 都是「货已离店」的负数流水，
  /// 所以 [CostPolicy.returnCost] 的原单比例回退对两者一致。
  static const Map<DocType, Set<DocType>> returnOriginalTypes =
      <DocType, Set<DocType>>{
        DocType.saleReturn: <DocType>{DocType.sale, DocType.delivery},
        DocType.purchaseReturn: <DocType>{DocType.purchase},
      };

  /// 按 `doc_type` 分派到具体规则。
  ///
  /// [now] = 主机当前时间（毫秒）。**必须由调用方传入**，不在内部取
  /// —— 单测因此可复现，也让"主机时钟为准"成为显式约定。
  ///
  /// [immediatePayments] 与 [allocations] **互斥**（`docs/sync_protocol.md` §8.1）：
  /// 前者说明这是主单，后者说明这是用户手动创建的独立收付款单。
  RuleOutcome dispatch({
    required Document document,
    required int now,
    List<DocumentLine> lines = const <DocumentLine>[],
    Map<String, int>? stocktakeActual,
    List<PaymentEntry> immediatePayments = const <PaymentEntry>[],
    List<Allocation> allocations = const <Allocation>[],
  }) {
    if (immediatePayments.isNotEmpty && allocations.isNotEmpty) {
      return const RuleOutcome(
        RuleStatus.rejected,
        reason: 'immediate_payments 与 allocations 互斥，不能同时非空',
      );
    }

    try {
      return db.transaction(() {
        // 幂等：单据已存在 → already_exists，不修改任何数据
        final Document? existing = _docs.findById(document.id);
        if (existing != null) {
          return RuleOutcome(RuleStatus.alreadyExists, document: existing);
        }

        final Document prepared = _prepare(document, now: now);
        switch (prepared.docType) {
          case DocType.purchase:
            return _purchaseInbound(prepared, lines, immediatePayments, now);
          case DocType.sale:
            return _sale(prepared, lines, immediatePayments, now);
          case DocType.delivery:
            return _delivery(prepared, lines, immediatePayments, now);
          case DocType.saleReturn:
          case DocType.purchaseReturn:
            return _return(prepared, lines, immediatePayments, now);
          case DocType.receipt:
            if (allocations.isEmpty && prepared.totalAmount <= 0) {
              throw StateError('收款单的金额必须为正数');
            }
            return _settle(prepared, allocations, moneyOut: false, now: now);
          case DocType.payment:
            if (allocations.isEmpty && prepared.totalAmount <= 0) {
              throw StateError('付款单的金额必须为正数');
            }
            return _settle(prepared, allocations, moneyOut: true, now: now);
          case DocType.stocktake:
            return _stocktake(
              prepared,
              stocktakeActual ?? _actualFromLines(lines),
              now,
            );
          default:
            // 到这里只剩 `transfer`（调拨）—— v1 有意不实现
            return RuleOutcome(
              RuleStatus.rejected,
              reason: 'v1 尚未实现 ${prepared.docType.wire}（调拨）的规则',
            );
        }
      });
    } catch (error) {
      // 事务已回滚（Db.transaction 负责），这里只把错误转成可上报的结果
      return RuleOutcome(RuleStatus.rejected, reason: '规则执行失败，整单回滚：$error');
    }
  }

  // ------------------------------------------------------------ RULE-001

  /// **RULE-001 采购入库**（`docs/rules.md`）
  ///
  /// - `StockLedger`：每 line `quantity = +qty`，`total_cost = line.amount`
  ///   （v3 口径：`amount` 是真相、含让价；`unit_price` 是派生展示）
  /// - `PartyLedger`：主单 `amount = -total_amount`（我欠供应商）
  /// - **不直接写** `MoneyLedger`；立即付款由 [PaymentEntry] 触发自动 payment 单
  RuleOutcome _purchaseInbound(
    Document doc,
    List<DocumentLine> lines,
    List<PaymentEntry> immediatePayments,
    int now,
  ) {
    _requireLinesTotalMatches(doc, lines);
    _requirePayee(doc, immediatePayments);

    if (!_docs.insertIfAbsent(doc, lines)) {
      return RuleOutcome(RuleStatus.alreadyExists, document: doc);
    }

    for (final DocumentLine line in lines) {
      if (line.quantity <= 0) {
        throw StateError('采购入库的 line 数量必须为正数，实际 ${line.quantity}');
      }
      _insertStock(
        productId: line.productId,
        documentId: doc.id,
        quantity: line.quantity,
        // v3 口径：入库成本 = 该行 amount（含让价），不再 qty × unit_price
        totalCost: _cost.inboundCost(line),
        doc: doc,
        now: now,
      );
    }

    _insertPartyLedger(doc: doc, amount: -doc.totalAmount, now: now);

    // 立即付款 → 自动生成 payment 单（moneyOut = true）
    _applyImmediateSettlement(
      doc,
      immediatePayments,
      moneyOut: true,
      now: now,
    );

    return RuleOutcome(RuleStatus.applied, document: doc);
  }

  // ------------------------------------------------------------ RULE-002

  /// **RULE-002 店内销售**
  ///
  /// - `StockLedger`：每 line `quantity = -qty`，成本按出库时点加权平均
  /// - `PartyLedger`：主单 `amount = +total_amount`（客户欠我）
  /// - **负库存允许**（`docs/threat_model.md` §3.4）
  /// - 立即收款 → 自动生成 receipt 单
  RuleOutcome _sale(
    Document doc,
    List<DocumentLine> lines,
    List<PaymentEntry> immediatePayments,
    int now,
  ) {
    _requireLinesTotalMatches(doc, lines);
    _requirePayee(doc, immediatePayments);

    if (!_docs.insertIfAbsent(doc, lines)) {
      return RuleOutcome(RuleStatus.alreadyExists, document: doc);
    }

    for (final DocumentLine line in lines) {
      if (line.quantity <= 0) {
        throw StateError('销售的 line 数量必须为正数，实际 ${line.quantity}');
      }
      final int outbound = -line.quantity;
      _insertStock(
        productId: line.productId,
        documentId: doc.id,
        quantity: outbound,
        totalCost: _cost.outboundCost(
          productId: line.productId,
          quantity: outbound,
        ),
        doc: doc,
        now: now,
      );
    }

    _insertPartyLedger(doc: doc, amount: doc.totalAmount, now: now);

    // 立即收款 → 自动生成 receipt 单（moneyOut = false）
    _applyImmediateSettlement(
      doc,
      immediatePayments,
      moneyOut: false,
      now: now,
    );

    return RuleOutcome(RuleStatus.applied, document: doc);
  }

  // ------------------------------------------------------------ RULE-003

  /// **RULE-003 送货**（`docs/rules.md`）
  ///
  /// - `StockLedger`：每 line `quantity = -qty`（**货离店即扣库存**）
  /// - `PartyLedger`：主单 `amount = +total_amount`
  /// - 创建时主机**强制** `status = in_transit`
  ///
  /// ⚠️ 送货的 `status` 由送货状态机驱动，**不由 `paid_amount` 推导**（R-10）。
  /// `in_transit → delivered` 需 `documentAction: mark_delivered`（R-3），
  /// 随 `SyncServer` 落地；本规则只覆盖创建路径。
  RuleOutcome _delivery(
    Document doc,
    List<DocumentLine> lines,
    List<PaymentEntry> immediatePayments,
    int now,
  ) {
    _requireLinesTotalMatches(doc, lines);
    _requirePayee(doc, immediatePayments);

    // 状态由主机决定：送货单一律以 in_transit 起步（覆盖调用方传入的状态）
    final Document created = doc.copyWithAllowed(
      status: DocStatus.inTransit,
      updatedAt: now,
    );

    if (!_docs.insertIfAbsent(created, lines)) {
      return RuleOutcome(RuleStatus.alreadyExists, document: created);
    }

    for (final DocumentLine line in lines) {
      if (line.quantity <= 0) {
        throw StateError('送货的 line 数量必须为正数，实际 ${line.quantity}');
      }
      final int outbound = -line.quantity;
      _insertStock(
        productId: line.productId,
        documentId: created.id,
        quantity: outbound,
        totalCost: _cost.outboundCost(
          productId: line.productId,
          quantity: outbound,
        ),
        doc: created,
        now: now,
      );
    }

    _insertPartyLedger(doc: created, amount: created.totalAmount, now: now);

    // 送货收款 → 自动生成 receipt 单（moneyOut = false）
    _applyImmediateSettlement(
      created,
      immediatePayments,
      moneyOut: false,
      now: now,
    );

    return RuleOutcome(RuleStatus.applied, document: created);
  }

  // ------------------------------------------------------------ RULE-007 / 008

  /// **RULE-007 销售退货 / RULE-008 采购退货**（`docs/rules.md`）
  ///
  /// 两条规则的差异只有两处符号，因此共用一个实现：
  ///
  /// | | `sale_return` | `purchase_return` |
  /// |---|---|---|
  /// | 原单类型 | `sale` **或 `delivery`**（拒收） | `purchase` |
  /// | `stock_ledger.quantity` | 正（货回库） | 负（货出库） |
  /// | `stock_ledger.total_cost` | 正 | 负 |
  /// | 主单 `PartyLedger` | `-total`（客户欠款减少） | `+total`（我欠供应商减少） |
  /// | 立即结算生成的单据 | `payment`（退款给客户） | `receipt`（供应商退钱） |
  ///
  /// `total_cost` 由 [CostPolicy.returnCost] 按**原单比例精确回退**（R-11 方案 A）。
  RuleOutcome _return(
    Document doc,
    List<DocumentLine> lines,
    List<PaymentEntry> immediatePayments,
    int now,
  ) {
    _requireLinesTotalMatches(doc, lines);
    _requirePayee(doc, immediatePayments);

    final Set<DocType> allowedOriginals = returnOriginalTypes[doc.docType]!;
    final String? refDocId = doc.refDocId;
    if (refDocId == null) {
      throw StateError('${doc.docType.wire} 必须带 ref_doc_id 指向原单');
    }
    final Document? original = _docs.findById(refDocId);
    if (original == null) {
      throw StateError('原单不存在：$refDocId');
    }
    if (!allowedOriginals.contains(original.docType)) {
      throw StateError(
        '${doc.docType.wire} 的原单类型必须是 '
        '${allowedOriginals.map((DocType t) => t.wire).join(' 或 ')}，'
        '实际为 ${original.docType.wire}（原单 ${original.docNo}）',
      );
    }

    if (!_docs.insertIfAbsent(doc, lines)) {
      return RuleOutcome(RuleStatus.alreadyExists, document: doc);
    }

    // 货回库（销售退货）还是货出库（采购退货）
    final bool inbound = doc.docType == DocType.saleReturn;

    for (final DocumentLine line in lines) {
      if (line.quantity <= 0) {
        throw StateError('退货的 line 数量必须为正数，实际 ${line.quantity}');
      }
      _insertStock(
        productId: line.productId,
        documentId: doc.id,
        quantity: inbound ? line.quantity : -line.quantity,
        totalCost: _cost.returnCost(
          refDocId: refDocId,
          productId: line.productId,
          returnQuantity: line.quantity,
          returnType: doc.docType,
        ),
        doc: doc,
        now: now,
      );
    }

    // 退货冲销原单方向的欠款
    //   sale_return（我方应收）    → -total
    //   purchase_return（我方应付） → +total
    _insertPartyLedger(
      doc: doc,
      amount: inbound ? -doc.totalAmount : doc.totalAmount,
      now: now,
    );

    // 立即退款（sale_return → payment 单）/ 立即收退款（purchase_return → receipt 单）
    _applyImmediateSettlement(doc, immediatePayments, moneyOut: inbound, now: now);

    // §BH·七（reply.md 2026-10-04 裁定）：**拒收收口** —— 原单是送货单且
    // 还没签收（in_transit）⇒ 同一事务内置为 `cancelled`。否则在途视图会
    // 永远把拒收的货算进去，低库存告警失真。这是 RULE-007 的**副作用**
    // （规则内部的状态转变，不走 `documentAction` —— R-3 只定义了
    // mark_delivered）；已签收（delivered）的原单不在此列 —— 货确实送到过，
    // 之后的退货不改变「送过货」这个事实（状态机不允许 delivered → cancelled）。
    if (original.docType == DocType.delivery &&
        original.status == DocStatus.inTransit) {
      _docs.updateStatusAndPaid(
        id: refDocId,
        status: DocStatus.cancelled,
        updatedAt: now,
      );
    }

    return RuleOutcome(RuleStatus.applied, document: doc);
  }

  // ------------------------------------------------------------ RULE-004/005

  /// **RULE-004 收款核销 / RULE-005 付款核销**
  ///
  /// [allocations] 来自同步 payload（R-1 裁定）；`target_doc_id = null` 表示预收/预付。
  /// 收付款单**创建即 `status = settled`**，此后不再变更。
  RuleOutcome _settle(
    Document doc,
    List<Allocation> allocations, {
    required bool moneyOut,
    required int now,
  }) {
    if (doc.accountId == null) {
      throw StateError('收付款单必须指定 account_id');
    }
    if (doc.partyId == null) {
      throw StateError('收付款单必须指定 party_id');
    }

    int requested = 0;
    for (final Allocation allocation in allocations) {
      if (allocation.amount <= 0) {
        throw StateError('核销金额必须为正数，实际 ${allocation.amount}');
      }
      requested += allocation.amount;

      final String? targetId = allocation.targetDocId;
      if (targetId == null) continue; // 预收 / 预付

      final Document? target = _docs.findById(targetId);
      if (target == null) {
        throw StateError('被核销单不存在：$targetId');
      }
      if (!allocatableTargetTypes.contains(target.docType)) {
        throw StateError('${target.docType.wire} 不可作为核销目标');
      }
      final int already = _settlements.settledAmountOf(targetId);
      if (already + allocation.amount > target.totalAmount) {
        throw StateError(
          '核销额超过被核销单未收金额：${target.docNo} 已收 $already / 总额 ${target.totalAmount}，'
          '本次请求 ${allocation.amount}',
        );
      }
    }
    if (requested > doc.totalAmount) {
      throw StateError('核销总额 $requested 超过收付款单金额 ${doc.totalAmount}');
    }

    // 收付款单创建即终态
    final Document settled = doc.copyWithAllowed(
      status: DocStatus.settled,
      paidAmount: 0,
      updatedAt: now,
    );
    _docs.insertRow(settled);

    _moneyLedger.insert(
      MoneyLedger(
        id: newId(),
        accountId: doc.accountId!,
        documentId: doc.id,
        amount: moneyOut ? -doc.totalAmount : doc.totalAmount,
        seqNo: _seq.nextMoney(),
        occurredAt: doc.occurredAt,
        timeEstimated: doc.timeEstimated,
        createdAt: now,
      ),
    );

    _insertPartyLedger(
      doc: doc,
      amount: moneyOut ? doc.totalAmount : -doc.totalAmount,
      now: now,
      requireParty: true,
    );

    for (final Allocation allocation in allocations) {
      _settlements.insert(
        Settlement(
          id: newId(),
          receiptDocId: doc.id,
          targetDocId: allocation.targetDocId,
          amount: allocation.amount,
          seqNo: _seq.nextSettlement(),
          timeEstimated: doc.timeEstimated,
          createdAt: now,
        ),
      );
    }

    for (final Allocation allocation in allocations) {
      final String? targetId = allocation.targetDocId;
      if (targetId != null) _refreshPaidAmount(targetId, now);
    }

    return RuleOutcome(RuleStatus.applied, document: settled);
  }

  // ------------------------------------------------------------ RULE-009

  /// **RULE-009 盘点**
  ///
  /// - `document_lines.quantity` = **盘点后的实际数量**（不是差额）
  /// - 主机在事务内算 `diff = 实际数量 - 账面数量`，`diff == 0` 不产生流水
  /// - **不生成** `PartyLedger` / `MoneyLedger`
  /// - 盘点单 `total_amount` 必须为 0
  RuleOutcome _stocktake(
    Document doc,
    Map<String, int> actualByProduct,
    int now,
  ) {
    if (doc.totalAmount != 0) {
      throw StateError('盘点单的 total_amount 必须为 0，实际 ${doc.totalAmount}');
    }

    final List<DocumentLine> lines = <DocumentLine>[
      for (final MapEntry<String, int> entry in actualByProduct.entries)
        DocumentLine(
          id: newId(),
          documentId: doc.id,
          productId: entry.key,
          quantity: entry.value, // 实际数量
          unitPrice: 0,
          amount: 0,
        ),
    ];

    if (!_docs.insertIfAbsent(doc, lines)) {
      return RuleOutcome(RuleStatus.alreadyExists, document: doc);
    }

    for (final MapEntry<String, int> entry in actualByProduct.entries) {
      final String productId = entry.key;
      final int actual = entry.value;
      if (actual < 0) {
        throw StateError('盘点数量不得为负：$productId = $actual');
      }

      final int book = _stock.stockOf(productId);
      final int diff = actual - book;
      if (diff == 0) continue; // 无差异 → 不产生流水

      _insertStock(
        productId: productId,
        documentId: doc.id,
        quantity: diff,
        totalCost: diff > 0
            ? _cost.surplusCost(productId: productId, quantity: diff)
            : _cost.outboundCost(productId: productId, quantity: diff),
        doc: doc,
        now: now,
      );
    }

    return RuleOutcome(RuleStatus.applied, document: doc);
  }

  // ------------------------------------------------------------ 自动收付款

  /// 把 [entries] 逐条落地为**自动生成的收付款单**（`docs/rules.md` §零）。
  ///
  /// [moneyOut] = `true` 时生成 `payment` 单（我方付钱），
  /// `false` 时生成 `receipt` 单（我方收钱）。
  ///
  /// 每张自动单据写三本账：
  /// - `MoneyLedger`：`moneyOut ? -amount : +amount`
  /// - `PartyLedger`：`moneyOut ? +amount : -amount`（欠款减少 / 增加）
  /// - `Settlement`：`receipt_doc_id = 自动单`、`target_doc_id = 主单`
  void _applyImmediateSettlement(
    Document mainDoc,
    List<PaymentEntry> entries, {
    required bool moneyOut,
    required int now,
  }) {
    if (entries.isEmpty) return;

    int requested = 0;
    for (final PaymentEntry entry in entries) {
      if (entry.amount <= 0) {
        throw StateError('立即收付款金额必须为正数，实际 ${entry.amount}');
      }
      requested += entry.amount;
    }
    if (requested > mainDoc.totalAmount) {
      throw StateError('立即收付款总额 $requested 超过单据总额 ${mainDoc.totalAmount}');
    }

    final DocType type = moneyOut ? DocType.payment : DocType.receipt;

    for (final PaymentEntry entry in entries) {
      final Document auto = Document(
        id: newId(),
        docNo: _docNo.next(type, occurredAtMs: mainDoc.occurredAt),
        docType: type,
        status: DocStatus.settled, // 收付款单创建即终态
        partyId: mainDoc.partyId,
        accountId: entry.accountId,
        totalAmount: entry.amount,
        paidAmount: 0, // B4'：收付款单本身不出现在 target_doc_id
        refDocId: mainDoc.id,
        occurredAt: mainDoc.occurredAt,
        timeEstimated: mainDoc.timeEstimated, // 继承主单
        createdAt: now,
        updatedAt: now,
        remark: '由 ${mainDoc.docType.wire} ${mainDoc.docNo} 自动生成',
      );
      _docs.insertRow(auto);

      _moneyLedger.insert(
        MoneyLedger(
          id: newId(),
          accountId: entry.accountId,
          documentId: auto.id,
          amount: moneyOut ? -entry.amount : entry.amount,
          seqNo: _seq.nextMoney(),
          occurredAt: mainDoc.occurredAt,
          timeEstimated: mainDoc.timeEstimated,
          createdAt: now,
        ),
      );

      if (mainDoc.partyId != null) {
        _partyLedger.insert(
          PartyLedger(
            id: newId(),
            partyId: mainDoc.partyId!,
            documentId: auto.id,
            amount: moneyOut ? entry.amount : -entry.amount,
            seqNo: _seq.nextParty(),
            occurredAt: mainDoc.occurredAt,
            timeEstimated: mainDoc.timeEstimated,
            createdAt: now,
          ),
        );
      }

      _settlements.insert(
        Settlement(
          id: newId(),
          receiptDocId: auto.id,
          targetDocId: mainDoc.id,
          amount: entry.amount,
          seqNo: _seq.nextSettlement(),
          timeEstimated: mainDoc.timeEstimated,
          createdAt: now,
        ),
      );
    }

    _refreshPaidAmount(mainDoc.id, now);
  }

  /// 刷新主单：`paid_amount` 与由它派生的 `status`（`docs/data_model.md` §3.1）
  void _refreshPaidAmount(String documentId, int now) {
    final Document? doc = _docs.findById(documentId);
    if (doc == null) return;
    final int paid = _settlements.settledAmountOf(documentId);

    // ⚠️ 送货单例外（R-10）：`status` 由**送货状态机**驱动
    // （`in_transit → delivered → settled`），不是通用的单条
    // `paid_amount >= total_amount` 公式。
    // 本阶段尚无离线签收（`documentAction`，R-3），签收走 [markDelivered]。
    if (doc.docType == DocType.delivery) {
      final DocStatus next;
      switch (doc.status) {
        // 未签收：钱到了但货还在路上，状态不动
        case DocStatus.draft:
        case DocStatus.confirmed:
        case DocStatus.inTransit:
          next = doc.status;
        // 已签收：付款是否付清决定终态
        case DocStatus.delivered:
          next = doc.totalAmount > 0 && paid >= doc.totalAmount
              ? DocStatus.settled
              : DocStatus.delivered;
        // 已结清 / 已取消：不回退
        case DocStatus.settled:
        case DocStatus.cancelled:
          next = doc.status;
      }
      _docs.updateStatusAndPaid(
        id: documentId,
        status: next,
        paidAmount: paid,
        updatedAt: now,
      );
      return;
    }

    final DocStatus status = doc.totalAmount > 0 && paid >= doc.totalAmount
        ? DocStatus.settled
        : DocStatus.confirmed;
    _docs.updateStatusAndPaid(
      id: documentId,
      status: status,
      paidAmount: paid,
      updatedAt: now,
    );
  }

  // ------------------------------------------------------------ 送货签收

  /// **主机本地**把送货单标记为已签收（`docs/rules.md` RULE-003）。
  ///
  /// 两条路径共用这里：
  /// ① 主机 UI 手动改状态；② 同步通道 `documentAction: mark_delivered`
  /// （`SyncServer._applyAction`，R-3 已于 2026-09-29 裁定：归约为状态判定、
  /// 不建 `document_actions` 表，回执分类见 `sync_protocol.md` §8.5）。
  ///
  /// **为何不直接让 UI 调 `DocumentDao.updateStatusAndPaid`**：那个方法按契约
  /// 「只在主机本地事务内由 RuleEngine 调用」，裸调用无法拦住
  /// `cancelled → delivered` 这类非法迁移。规则的实现只应有一处。
  ///
  /// **幂等判定基于状态**（R-3.1 已裁定：动作只做单向终态转变，反向用新建单据）：
  ///
  /// - `in_transit` → `delivered`；若已收满款，同一事务内直接落到 `settled`
  /// - 已是 `delivered` / `settled` → `alreadyExists`（重复签收是 no-op）
  /// - `cancelled` 等 → `rejected`（已取消的单不能签收）
  RuleOutcome markDelivered({required String documentId, required int now}) {
    try {
      return db.transaction(() {
        final Document? doc = _docs.findById(documentId);
        if (doc == null) {
          return RuleOutcome(
            RuleStatus.rejected,
            reason: '单据不存在：$documentId',
          );
        }
        if (doc.docType != DocType.delivery) {
          return RuleOutcome(
            RuleStatus.rejected,
            reason: '${doc.docType.wire} 不适用「签收」动作'
                '（docs/rules.md RULE-003）',
          );
        }

        switch (doc.status) {
          case DocStatus.inTransit:
            _docs.updateStatusAndPaid(
              id: documentId,
              status: DocStatus.delivered,
              updatedAt: now,
            );
            // 已收满款 → 同一事务内直接落到终态
            _refreshPaidAmount(documentId, now);
            return RuleOutcome(
              RuleStatus.applied,
              document: _docs.findById(documentId),
            );
          case DocStatus.delivered:
          case DocStatus.settled:
            return RuleOutcome(RuleStatus.alreadyExists, document: doc);
          default:
            return RuleOutcome(
              RuleStatus.rejected,
              reason: '${doc.status.wire} 状态的送货单不能签收',
            );
        }
      });
    } catch (error) {
      return RuleOutcome(RuleStatus.rejected, reason: '动作执行失败，已回滚：$error');
    }
  }

  // ------------------------------------------------------------ 内部

  /// 主机落库前的字段重写：分配正式单号、用主机时钟写 `created_at` / `updated_at`
  Document _prepare(Document document, {required int now}) {
    final String docNo = Document.isPendingDocNo(document.docNo)
        ? _docNo.next(document.docType, occurredAtMs: document.occurredAt)
        : document.docNo;
    return document.withHostAssigned(
      docNo: docNo,
      createdAt: now,
      updatedAt: now,
    );
  }

  void _insertStock({
    required String productId,
    required String documentId,
    required int quantity,
    required int totalCost,
    required Document doc,
    required int now,
  }) {
    _stock.insert(
      StockLedger(
        id: newId(),
        productId: productId,
        documentId: documentId,
        quantity: quantity,
        totalCost: totalCost,
        seqNo: _seq.nextStock(),
        occurredAt: doc.occurredAt,
        timeEstimated: doc.timeEstimated,
        createdAt: now,
      ),
    );
  }

  /// 写主单的往来流水。`party_id` 为空时**跳过**（零售散客场景：
  /// 无往来方即无债权，与"立即全额收款"配合时净额本就为 0）
  void _insertPartyLedger({
    required Document doc,
    required int amount,
    required int now,
    bool requireParty = false,
  }) {
    if (doc.partyId == null) {
      if (requireParty) {
        throw StateError('单据 ${doc.docNo} 必须指定 party_id 才能记往来流水');
      }
      return;
    }
    _partyLedger.insert(
      PartyLedger(
        id: newId(),
        partyId: doc.partyId!,
        documentId: doc.id,
        amount: amount,
        seqNo: _seq.nextParty(),
        occurredAt: doc.occurredAt,
        timeEstimated: doc.timeEstimated,
        createdAt: now,
      ),
    );
  }

  /// 主单记账的前置校验：有欠款就必须有往来方。
  ///
  /// 理由：主单写 `PartyLedger = ±total_amount`，若 `party_id` 为空则该条目被跳过，
  /// **欠款会凭空消失**。所以「未立即结清」的单据必须有 `party_id`。
  /// 金额未结清 = `SUM(immediatePayments) < total_amount`。
  void _requirePayee(Document doc, List<PaymentEntry> immediatePayments) {
    final int settled = immediatePayments.fold<int>(
      0,
      (int acc, PaymentEntry entry) => acc + entry.amount,
    );
    if (settled < doc.totalAmount && doc.partyId == null) {
      throw StateError(
        '存在未结清金额（${doc.totalAmount - settled}）时必须有 party_id，'
        '否则欠款无处记录',
      );
    }
  }

  /// 从盘点的 lines 取出 `productId → 实际数量`
  Map<String, int> _actualFromLines(List<DocumentLine> lines) =>
      <String, int>{
        for (final DocumentLine line in lines) line.productId: line.quantity,
      };

  /// 不变量 B5：`SUM(document_lines.amount) = document.total_amount`
  /// （`stocktake` / `receipt` / `payment` 除外，见 `docs/data_model.md` §五）
  void _requireLinesTotalMatches(Document doc, List<DocumentLine> lines) {
    for (final DocumentLine line in lines) {
      if (line.documentId != doc.id) {
        throw StateError(
          '明细的 document_id（${line.documentId}）与单据 id（${doc.id}）不一致',
        );
      }
    }
    final int sum = lines.fold<int>(
      0,
      (int acc, DocumentLine line) => acc + line.amount,
    );
    if (!linesAmountMatchesTotal(doc, sum)) {
      throw StateError(
        '明细金额之和（$sum）与单据总额（${doc.totalAmount}）不符'
        '（docs/data_model.md §五 不变量 B5）',
      );
    }
  }
}
