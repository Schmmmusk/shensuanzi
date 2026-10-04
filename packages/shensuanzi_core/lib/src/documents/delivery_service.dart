/// 送货开单的**提交服务**：草稿 → `RuleEngine` → 给 UI 的结果。
///
/// 与 `SaleService` 同构（差异见 `delivery_draft.dart` 文件头）；
/// 规则本体在 RULE-003（`RuleEngine._delivery` / `markDelivered`），
/// 本层只做「表单门槛 + 形状转换」。**本批次不动数据层**（§AP）。
///
/// ## 与销售服务的两处差异
///
/// | 项 | 销售 | 送货 |
/// |---|---|---|
/// | 立即收付款 | 有（含找零折算 §AX·一） | **没有** —— 永传空列表 |
/// | 签收 | 无此动作 | [markDelivered]（1b 的第二个入口） |
library;

import '../dao/document_dao.dart';
import '../dao/party_dao.dart';
import '../dao/query_dao.dart';
import '../models/document.dart';
import '../models/document_line.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../rules/payment_entry.dart';
import '../rules/rule_engine.dart';
import '../util/ids.dart';
import 'delivery_draft.dart';

/// 草稿校验失败：**带两组字段级原因**，界面直接标红对应输入框。
///
/// ⚠️ 比 `SaleDraftInvalid` **少一组** `paymentErrors` —— 送货单没有收款区。
class DeliveryDraftInvalid implements Exception {
  DeliveryDraftInvalid(this.fieldErrors, this.lineErrors);

  final Map<DeliveryField, String> fieldErrors;
  final List<Map<DeliveryLineField, String>> lineErrors;

  /// 拼成一句话（日志 / 汇总提示用）
  String get summary => <String>[
    ...fieldErrors.values,
    for (final Map<DeliveryLineField, String> e in lineErrors) ...e.values,
  ].join('；');

  @override
  String toString() => 'DeliveryDraftInvalid($summary)';
}

/// 保存成功后给 UI 的结果（与 `SaleSaved` 同构，去掉收款相关的字段）。
class DeliverySaved {
  const DeliverySaved({
    required this.docNo,
    required this.totalCents,
    required this.partyDueCents,
    required this.status,
  });

  /// 正式单号（主机生成，如 `SH20260927-001`）
  final String docNo;

  final int totalCents;

  /// 该客户**累计**欠款（客户欠我，≥ 0）。
  /// 语义取自 `QueryDao.partyBalances`：正 = 对方欠我。
  final int partyDueCents;

  /// 落库后的状态 —— 送货单**必定**是 `in_transit`（RULE-003 强制），
  /// 带出来只是为了让 UI 不用猜。
  final DocStatus status;
}

/// 签收的结果。
class DeliverySigned {
  const DeliverySigned({
    required this.docNo,
    required this.alreadyDone,
    required this.status,
  });

  final String docNo;

  /// `true` = 这张单**之前就已经签收过**（重复点是 no-op，**不是错误**）。
  final bool alreadyDone;

  /// 签收后的状态（已收满款时同一事务内直接到 `settled`）。
  final DocStatus status;

  /// 给用户看的一句话 —— **判断与文案都在 core**（UI 只取值，铁律）。
  String get message => alreadyDone
      ? '$docNo 早就签收过了，这次什么都没变。'
      : '$docNo 已签收。';
}

/// 送货服务。**不注入 `AppEnvironment` 之类的东西** —— 它只关心库与规则。
class DeliveryService {
  DeliveryService({required RuleEngine engine, required QueryDao queries})
    : _engine = engine,
      _queries = queries;

  final RuleEngine _engine;
  final QueryDao _queries;

  DocumentDao get _docs => DocumentDao(_queries.db);

  // ------------------------------------------------------------ 开单页需要的查询

  /// 启用中的客户（客户选择器）—— 送货的客户**必选**，也没有「散客」这一档。
  List<Party> activeCustomers() =>
      PartyDao(_queries.db).findAll(role: PartyRole.customer, active: true);

  /// 最近**送过货**的商品（商品选择器空查询时的「最近使用」）。
  /// 与销售分开：一个店常送的货和常零售的货未必是同一批。
  List<Product> recentlyDelivered({int limit = 20}) => _queries.recentProducts(
    docTypes: const <DocType>[DocType.delivery],
    limit: limit,
  );

  /// 最近往来过的客户（客户选择器空查询时的「最近往来」）。
  List<Party> recentCustomers({int limit = 20}) => _queries.recentParties(
    docTypes: const <DocType>[DocType.delivery],
    limit: limit,
  );

  /// **打开本页时**的库存快照（每商品账面库存）。语义同销售（Z-2：只是提示）。
  Map<String, int> stockSnapshot() => _queries.stockByProduct();

  // ------------------------------------------------------------ 签收

  /// 还没签收的送货单（`status = in_transit`），新 → 旧。
  ///
  /// 直接在内存里筛：送货单是小批量单据，且 `listDocuments` 已有类型过滤
  /// —— 为它单开一条 SQL 不划算（多一处口径）。
  List<DocumentSummary> pendingDeliveries({int limit = 50}) => <DocumentSummary>[
    for (final DocumentSummary summary
        in _docs.listDocuments(type: DocType.delivery, limit: limit))
      if (summary.document.status == DocStatus.inTransit) summary,
  ];

  /// 某商品还有多少在途（送货单里未签收的数量合计）。
  /// 实现在 `QueryDao.inTransitByProduct`（「在店可售」的水位线）。
  Map<String, int> inTransitByProduct() => _queries.inTransitByProduct();

  // ------------------------------------------------------------ 提交

  /// 提交草稿。校验不通过抛 [DeliveryDraftInvalid]；规则拒绝抛 [StateError]
  /// （此时库已整单回滚，界面走「意外失败」兜底文案）。
  DeliverySaved create(DeliveryDraft draft, {int? now}) {
    final Map<DeliveryField, String> fieldErrors = draft.validate();
    final List<Map<DeliveryLineField, String>> lineErrors =
        draft.validateLines();
    if (fieldErrors.isNotEmpty ||
        lineErrors.any((Map<DeliveryLineField, String> e) => e.isNotEmpty)) {
      throw DeliveryDraftInvalid(fieldErrors, lineErrors);
    }

    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;

    final Document document = Document(
      id: newId(),
      // 占位号：`_prepare` 会换成正式单号（SH…）
      docNo: '${Document.pendingDocNoPrefix}${draft.hashCode}',
      docType: DocType.delivery,
      // 规则层会**强制覆盖**成 in_transit（RULE-003）；这里给一个合法初值
      status: DocStatus.inTransit,
      partyId: draft.partyId,
      totalAmount: draft.totalCents,
      occurredAt: draft.occurredAt,
      createdAt: stamp,
      updatedAt: stamp,
      remark: draft.remark.trim().isEmpty ? null : draft.remark.trim(),
    );

    final List<DocumentLine> lines = <DocumentLine>[
      for (final DeliveryLineDraft line in draft.lines)
        if (!line.isEmpty)
          // v3：quantity = 换算后的最小单位数量；amount = 真相（含让价）；
          // entry_* 记录入原文（§BD·三 第 1/2/6 条）
          DocumentLine.create(
            documentId: document.id,
            productId: line.productId,
            quantity: line.baseQuantityValue!,
            amount: line.amountCents!,
            entryQuantity: line.entryQuantityValue!,
            entryUnit: line.entryUnitValue,
            discountAmount: line.discountCents ?? 0,
          ),
    ];

    final RuleOutcome outcome = _engine.dispatch(
      document: document,
      lines: lines,
      // ⚠️ 送货单**没有收款区** ⇒ 永不带立即收付款（客户的payment 走 1a 的核销）
      immediatePayments: const <PaymentEntry>[],
      now: stamp,
    );

    final Document? applied = outcome.document;
    if (outcome.status != RuleStatus.applied || applied == null) {
      throw StateError(outcome.reason ?? '送货单被拒绝（${outcome.status.name}）');
    }

    // ⚠️ 按 id **重读**（outcome 里的对象是刷新前的，见 `SaleService` 同款注）
    final Document? stored = _docs.findById(applied.id);
    if (stored == null) {
      throw StateError('送货单 ${applied.docNo} 已保存但读不回来，请检查数据库');
    }

    // 客户**必选**（校验已保证）⇒ `partyId` 非空
    final int balance = _queries.partyBalances()[stored.partyId!] ?? 0;

    return DeliverySaved(
      docNo: stored.docNo,
      totalCents: stored.totalAmount,
      partyDueCents: balance > 0 ? balance : 0,
      status: stored.status,
    );
  }

  /// **签收**（RULE-003）：`in_transit → delivered`；已收满款则同一事务内到 `settled`。
  ///
  /// 重复签收是 **no-op**（返回 `alreadyDone == true`），**不抛** ——
  /// 中老年用户多点一次不该看到报错（`ui_principles.md` §1.3）。
  /// 真正的非法（单据不存在 / 不是送货单 / 已取消）才抛 [StateError]。
  DeliverySigned markDelivered(String documentId, {int? now}) {
    final RuleOutcome outcome = _engine.markDelivered(
      documentId: documentId,
      now: now ?? DateTime.now().millisecondsSinceEpoch,
    );

    switch (outcome.status) {
      case RuleStatus.applied:
      case RuleStatus.alreadyExists:
        final Document? doc = _docs.findById(documentId);
        if (doc == null) {
          throw StateError('签收后读不回单据 $documentId，请检查数据库');
        }
        return DeliverySigned(
          docNo: doc.docNo,
          alreadyDone: outcome.status == RuleStatus.alreadyExists,
          status: doc.status,
        );
      default:
        throw StateError(outcome.reason ?? '签收被拒绝（${outcome.status.name}）');
    }
  }
}
