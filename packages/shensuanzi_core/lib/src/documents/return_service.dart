/// 退货服务 —— RULE-007/008 的**表单门槛**（与 `SaleService` 同构）。
///
/// ## 三件事
///
/// 1. [quotasFor]：各商品的可退额度（原量 / 已退 / 可退）—— 表单预填与
///    **超额前置拦截**的依据（裁定：保存才炸会让用户困惑）。
/// 2. [create]：校验 → 组装 `sale_return` / `purchase_return` 单 → 引擎
///    （RULE-007/008 已实现：库存回退、往来冲减、立即退款、成本 R-11 比例回退）。
/// 3. 拒收收口：原 `delivery` 未签收 ⇒ 引擎在同一事务内置 `cancelled`
///    （见 `rule_engine.dart` `_return` —— 不是本类的事）。
///
/// ## 与其他服务的一个差别
///
/// 退货**没有「改日期」**—— 它冲减的是一笔已发生的交易，发生时刻就是现在
/// （补录历史的冲减没有业务意义；`occurred_at` 只用于展示，排序用 `seq_no`）。
library;

import '../dao/account_dao.dart';
import '../dao/document_dao.dart';
import '../dao/ledger_dao.dart' show StockCostSnapshot, StockLedgerDao;
import '../dao/product_dao.dart';
import '../dao/query_dao.dart';
import '../models/account.dart';
import '../models/document.dart';
import '../models/document_line.dart';
import '../models/product.dart';
import '../rules/payment_entry.dart';
import '../rules/rule_engine.dart';
import '../util/ids.dart';
import 'return_draft.dart';

/// 一个商品的**可退额度快照**（表单预填与超额前置拦截的依据）。
class ReturnQuota {
  const ReturnQuota({
    required this.productId,
    required this.productName,
    required this.originalQuantity,
    required this.originalAmountCents,
    required this.returnedQuantity,
    required this.returnedAmountCents,
    this.entryUnit,
    this.baseUnit,
    this.packageUnit,
    this.packageSize,
  });

  final String productId;
  final String productName;

  /// 原单行数量（最小单位）
  final int originalQuantity;

  // ---- 单位上下文（退货行沿用原单行 —— 裁定 3：不允许切换单位）----

  /// 原单行的录入单位（`null` = 原单按最小单位录的）
  final String? entryUnit;
  final String? baseUnit;
  final String? packageUnit;
  final int? packageSize;

  /// 原单行金额（分，**含让价**）
  final int originalAmountCents;

  /// 已退数量（最小单位；从 stock_ledger 聚合，与成本分摊同源）
  final int returnedQuantity;

  /// 已退金额（分；Σ 此前退货单行的 amount）
  final int returnedAmountCents;

  int get remainingQuantity => originalQuantity - returnedQuantity;
  int get remainingAmountCents => originalAmountCents - returnedAmountCents;
}

/// 保存成功后给 UI 的结果。
class ReturnSaved {
  const ReturnSaved({
    required this.docNo,
    required this.returnType,
    required this.totalCents,
    required this.refundedCents,
    required this.originalDocNo,
  });

  final String docNo;
  final DocType returnType;

  /// 退货单金额（分）—— 冲减欠款的数
  final int totalCents;

  /// 实际立即退款的金额（分；`SUM(immediate_payments)`，封顶后的）
  final int refundedCents;

  /// 原单号（SnackBar 提示「对原单 XX 退了货」）
  final String originalDocNo;
}

class ReturnDraftInvalid implements Exception {
  ReturnDraftInvalid(this.fieldErrors, this.lineErrors, this.refundErrors);

  final Map<ReturnField, String> fieldErrors;
  final List<Map<ReturnLineField, String>> lineErrors;
  final List<Map<ReturnRefundField, String>> refundErrors;

  /// 拼成一句话（日志 / 汇总提示用）
  String get summary => <String>[
    ...fieldErrors.values,
    for (final Map<ReturnLineField, String> e in lineErrors) ...e.values,
    for (final Map<ReturnRefundField, String> e in refundErrors) ...e.values,
  ].join('；');

  @override
  String toString() => 'ReturnDraftInvalid($summary)';
}

class ReturnService {
  ReturnService({required RuleEngine engine, required QueryDao queries})
    : _engine = engine,
      _queries = queries;

  final RuleEngine _engine;
  final QueryDao _queries;

  /// 各商品的可退额度（原量 / 已退 / 可退）。
  ///
  /// - 原单行 = `document_lines`（数量最小单位、金额**含让价**）
  /// - 已退数量 = `stock_ledger` 的退货流水（与成本分摊**同源** ——
  ///   `LedgerDao.returnedFlow`，RULE-007/008 算成本用的就是它）
  /// - 已退金额 = 此前退货**单行**的 `amount`（Σ；金额在单据行上，
  ///   不在 stock_ledger —— 两者口径不同，别混）
  ///
  /// 原单不存在 ⇒ 返回空 map（UI 显示「原单不存在」而不是崩）。
  Map<String, ReturnQuota> quotasFor({
    required String refDocId,
    required DocType returnType,
  }) {
    final DocumentDao documents = DocumentDao(_queries.db);
    final Document? original = documents.findById(refDocId);
    if (original == null) return const <String, ReturnQuota>{};

    final StockLedgerDao ledger = StockLedgerDao(_queries.db);
    final List<DocumentLine> lines = documents.linesOf(refDocId);

    final Map<String, int> returnedAmounts = ledger.returnedAmountsByProduct(
      refDocId: refDocId,
      returnType: returnType,
    );

    final Map<String, Product> productById = <String, Product>{
      for (final Product p in _productsFor(lines)) p.id: p,
    };

    return <String, ReturnQuota>{
      for (final DocumentLine line in lines)
        line.productId: _quotaFor(
          original: original,
          line: line,
          ledger: ledger,
          returnedAmountCents: returnedAmounts[line.productId] ?? 0,
          product: productById[line.productId],
        ),
    };
  }

  List<Product> _productsFor(List<DocumentLine> lines) {
    final ProductDao products = ProductDao(_queries.db);
    return <Product>[
      for (final String id in lines.map((DocumentLine l) => l.productId).toSet())
        if (products.findById(id) != null) products.findById(id)!,
    ];
  }

  ReturnQuota _quotaFor({
    required Document original,
    required DocumentLine line,
    required StockLedgerDao ledger,
    required int returnedAmountCents,
    Product? product,
  }) {
    final StockCostSnapshot returned = ledger.returnedFlow(
      refDocId: original.id,
      productId: line.productId,
      returnType: returnTypeFor(original.docType),
    );
    return ReturnQuota(
      productId: line.productId,
      productName: product?.name ?? line.productId,
      originalQuantity: line.quantity,
      originalAmountCents: line.amount,
      returnedQuantity: returned.quantity.abs(),
      returnedAmountCents: returnedAmountCents,
      entryUnit: line.entryUnit,
      baseUnit: product?.unit,
      packageUnit: product?.packageUnit,
      packageSize: product?.packageSize,
    );
  }

  /// 启用中的资金账户（「立即退款」下拉用；与其他服务同款一行转发）
  List<Account> activeAccounts() => AccountDao(_queries.db).findAll(active: true);

  /// 原单类型 ⇒ 退货类型（与 `RuleEngine.returnOriginalTypes` 互为反查）。
  ///
  /// 其它类型（收付款 / 盘点 / 退货本身）⇒ StateError —— 它们不在
  /// `returnOriginalTypes` 的任何集合里，UI 本就不该给入口。
  static DocType returnTypeFor(DocType originalType) => switch (originalType) {
    DocType.sale || DocType.delivery => DocType.saleReturn,
    DocType.purchase => DocType.purchaseReturn,
    _ => throw StateError('${originalType.wire} 不是可退货的单据类型'),
  };

  // ------------------------------------------------------------ 提交

  /// 提交草稿。校验不通过抛 [ReturnDraftInvalid]；规则拒绝抛 [StateError]
  /// （此时库已整单回滚，界面走「意外失败」兜底文案）。
  ReturnSaved create(ReturnDraft draft, {int? now}) {
    final Map<ReturnField, String> fieldErrors = draft.validate();
    final List<Map<ReturnLineField, String>> lineErrors = draft.validateLines();
    final List<Map<ReturnRefundField, String>> refundErrors =
        draft.validateRefunds();
    if (fieldErrors.isNotEmpty ||
        lineErrors.any((Map<ReturnLineField, String> e) => e.isNotEmpty) ||
        refundErrors.any((Map<ReturnRefundField, String> e) => e.isNotEmpty)) {
      throw ReturnDraftInvalid(fieldErrors, lineErrors, refundErrors);
    }

    final DocumentDao documents = DocumentDao(_queries.db);
    final Document? original = documents.findById(draft.refDocId);
    if (original == null) {
      throw StateError('原单不存在：${draft.refDocId}');
    }
    // 以**库里的原单**为准定退货类型（不信任表单带来的上下文）
    final DocType returnType = returnTypeFor(original.docType);

    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;

    final Document document = Document(
      id: newId(),
      // 占位号：主机路径由 `_prepare` 换成正式单号
      docNo: '${Document.pendingDocNoPrefix}${draft.hashCode}',
      docType: returnType,
      status: DocStatus.confirmed,
      partyId: original.partyId,
      refDocId: original.id,
      totalAmount: draft.totalCents,
      occurredAt: stamp,
      createdAt: stamp,
      updatedAt: stamp,
      remark: draft.remark.trim().isEmpty ? null : draft.remark.trim(),
    );

    final List<DocumentLine> lines = <DocumentLine>[
      for (final ReturnLineDraft line in draft.lines)
        // entry_* 沿用原单行（裁定 3：按原交易的单位退，不允许切换）；
        // quantity = 换算后的最小单位数量；amount = 真相（累计比例法默认，可手改）；
        // discount_amount 恒 0 —— 「退货让价」= 直接把金额改小
        DocumentLine.create(
          documentId: document.id,
          productId: line.productId,
          quantity: line.quantityValue!,
          amount: line.amountCents!,
          entryQuantity: line.entryQuantityValue!,
          entryUnit: line.entryUnit,
          discountAmount: 0,
        ),
    ];

    // 立即退款：按**钳制后**的金额走（§BH·六 裁定 5，与 SaleDraft 同构）——
    // 超出合计的部分是找零；被钳成 0 的行跳过（0 元的收付款单没有意义）
    final List<int> recorded = draft.recordedRefundCents;
    final List<PaymentEntry> payments = <PaymentEntry>[
      for (int i = 0; i < draft.refunds.length; i++)
        if (!draft.refunds[i].isBlank && recorded[i] > 0)
          PaymentEntry(accountId: draft.refunds[i].accountId!, amount: recorded[i]),
    ];

    final RuleOutcome outcome = _engine.dispatch(
      document: document,
      lines: lines,
      immediatePayments: payments,
      now: stamp,
    );

    final Document? applied = outcome.document;
    if (outcome.status != RuleStatus.applied || applied == null) {
      throw StateError(outcome.reason ?? '退货单被拒绝（${outcome.status.name}）');
    }

    // ⚠️ 按 id 读库取最终状态（outcome 缓存的是刷新前的主单）
    final Document? stored = documents.findById(applied.id);
    if (stored == null) {
      throw StateError('退货单 ${applied.docNo} 已保存但读不回来，请检查数据库');
    }

    return ReturnSaved(
      docNo: stored.docNo,
      returnType: stored.docType,
      totalCents: stored.totalAmount,
      refundedCents: stored.paidAmount,
      originalDocNo: original.docNo,
    );
  }
}
