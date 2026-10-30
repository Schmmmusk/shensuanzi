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
import '../rules/rule_rejection.dart';
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
    this.originalEntryQuantity,
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

  /// 原单行的录入数量（B-4：退货换算按原单行比例，不用当前档案的 packageSize）
  final int? originalEntryQuantity;
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
      for (final String id
          in lines.map((DocumentLine l) => l.productId).toSet())
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
      // B-4：原单行的录入数量随额度一起交给 UI —— 退货换算按它反算
      originalEntryQuantity: line.entryQuantity,
      baseUnit: product?.unit,
      packageUnit: product?.packageUnit,
      packageSize: product?.packageSize,
    );
  }

  /// 启用中的资金账户（「立即退款」下拉用；与其他服务同款一行转发）
  List<Account> activeAccounts() =>
      AccountDao(_queries.db).findAll(active: true);

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

  /// 原单**真实收款**（走 `settlements`，不是 `paid_amount` 缓存）。
  ///
  /// `settlements.target_doc_id` 指向被核销的单，`amount` 是这次核销的金额 ——
  /// 两者相加就是这个原单实际收到（或付出）过多少钱。
  ///
  /// 给界面用：可退金额为 0 时，要靠它区分「一分没收过」与「收过的全退完了」
  /// （用户审查 2026-10-30，P2）—— 两种情形对用户的意思完全不同。
  int receivedCentsOf(String documentId) {
    final List<Map<String, Object?>> rows = _queries.db.raw.select(
      'SELECT COALESCE(SUM(amount), 0) AS s FROM settlements WHERE target_doc_id = ?',
      <Object?>[documentId],
    );
    final Object? value = rows.isEmpty ? null : rows.first['s'];
    return value is int ? value : 0;
  }

  /// 这张原单**已经退出去多少**（所有退货单被核销的金额之和）。
  ///
  /// ⚠️ 同样走 `settlements`：退货单的 `paid_amount` 是缓存，而这里要的是
  /// 「钱真的付出去了多少」。
  int _refundedCentsAgainst(String originalId) {
    final List<Map<String, Object?>> rows = _queries.db.raw.select(
      'SELECT COALESCE(SUM(s.amount), 0) AS s FROM settlements s '
      'JOIN documents r ON r.id = s.target_doc_id '
      "WHERE r.ref_doc_id = ? AND r.doc_type IN ('sale_return', 'purchase_return')",
      <Object?>[originalId],
    );
    final Object? value = rows.isEmpty ? null : rows.first['s'];
    return value is int ? value : 0;
  }

  /// 这张原单**现在最多还能退多少钱**（0 = 一分都不能退）。
  ///
  /// 给界面用：退款卡片按它决定「显示输入框」还是「显示一句说明」，
  /// 并把上限写出来。判据与 [create] 里的拦截**同源**（都是真实收款 − 已退），
  /// 所以不会出现「界面允许填、提交被拒」的割裂。
  ///
  /// ⚠️ 只读 `settlements`，不看 `paid_amount` 缓存。
  int refundableCentsOf(String originalId) {
    final int left =
        receivedCentsOf(originalId) - _refundedCentsAgainst(originalId);
    return left < 0 ? 0 : left;
  }

  ReturnSaved create(ReturnDraft draft, {int? now}) {
    final Map<ReturnField, String> fieldErrors = draft.validate();
    final List<Map<ReturnLineField, String>> lineErrors = draft.validateLines();
    final List<Map<ReturnRefundField, String>> refundErrors = draft
        .validateRefunds();
    if (fieldErrors.isNotEmpty ||
        lineErrors.any((Map<ReturnLineField, String> e) => e.isNotEmpty) ||
        refundErrors.any((Map<ReturnRefundField, String> e) => e.isNotEmpty)) {
      throw ReturnDraftInvalid(fieldErrors, lineErrors, refundErrors);
    }

    final DocumentDao documents = DocumentDao(_queries.db);
    final Document? original = documents.findById(draft.refDocId);
    if (original == null) {
      // #23（裁定④改判）：这不是内部 bug —— 手工改库 / 旧备份 / 多设备并发
      // 都可能让表单指向的单不在了，**用户需要知道原因**才能去确认。归入
      // 业务拒绝（refDocId 只进日志语义没有 —— 它本就在用户的表单上下文里）。
      throw const RuleRejected(
        '要退货的那张原单不在了。请回到单据列表确认这张单的状态，'
        '再重新发起退货；如果反复出现，请联系技术支持。',
      );
    }
    // 以**库里的原单**为准定退货类型（不信任表单带来的上下文）
    final DocType returnType = returnTypeFor(original.docType);

    // ⑥ 退款上限的**权威校验在 `RuleEngine._return`**（2026-10-30 用户审查：
    // `SyncServer` 直接调 `dispatch`，服务层的闸挡不住同步入口）。
    // 这里只保留 `refundableCentsOf()` 给界面算「最多能退多少」，不再做拦截。

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

    // 立即退款：**用用户填的原始金额**，不做钳制（2026-10-30 用户审查）。
    //
    // 从前这里是 `Overpay.clamp(..., totalCents)` —— 退 40 而应退 30 时，
    // 确认框显示「立即退款 ¥40」，实际只落库 ¥30，多出的 10 块没进流水。
    // 用户确认的金额 ≠ 实际付出的金额，比直接拒绝更糟。
    //
    // 现在超额会被 `RuleEngine._requireRefundWithinCap` 明确拒绝，
    // 用户看到「退款金额不能超过退货金额」，改一下再提交。
    final List<PaymentEntry> payments = <PaymentEntry>[
      for (final ReturnRefundDraft refund in draft.refunds)
        if (!refund.isBlank && (refund.amountCents ?? 0) > 0)
          PaymentEntry(
            accountId: refund.accountId!,
            amount: refund.amountCents!,
          ),
    ];

    final RuleOutcome outcome = _engine.dispatch(
      document: document,
      lines: lines,
      immediatePayments: payments,
      now: stamp,
    );

    final Document? applied = outcome.document;
    if (outcome.status != RuleStatus.applied || applied == null) {
      // #23 补丁：只有**业务拒绝**（用户能改）才带类型抛出；协议违反 /
      // 内部 bug（target_missing / rule_internal_error 等）保持既有
      // StateError 真错误语义（UI「请再试一次」+ 日志，M15）。
      final RuleRejected? business = outcome.businessRejection;
      if (business != null) throw business;
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
