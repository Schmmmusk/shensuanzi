/// 采购开单的**提交服务**：草稿 → `RuleEngine` → 给 UI 的结果。
///
/// ## 为什么这一层存在（与 `ProductService` 同理）
///
/// - **草稿校验不能假设调用方做过** —— 同步层 / 将来的其他入口可能直接调它
/// - **把「构造 Document / lines / PaymentEntry」这些形状转换收在这里**，
///   界面只调一个 `create(draft)`，不必知道 `dispatch` 的参数形状
/// - `RuleOutcome` 的 `rejected` 在这里转成**异常**，界面走统一的兜底分支
///
/// ## 不做的事
///
/// - **不重复 RULE-001 的规则判断** —— 那是 `RuleEngine` 的职责（215 用例覆盖）；
///   本层校验被绕过的唯一后果是 `dispatch` 返回 `rejected`，整单回滚，库不会脏
/// - **不生成正式单号** —— 主机在 `_prepare` 里生成；这里只带回
///   `outcome.document!.docNo`
library;

import '../dao/account_dao.dart';
import '../dao/document_dao.dart';
import '../dao/party_dao.dart';
import '../dao/query_dao.dart';
import '../master_data/party_service.dart';
import '../models/account.dart';
import '../models/document.dart';
import '../models/document_line.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../rules/payment_entry.dart';
import '../rules/rule_engine.dart';
import '../util/ids.dart';
import 'purchase_draft.dart';

/// 草稿校验失败：**带三组字段级原因**，界面直接标红对应输入框。
class PurchaseDraftInvalid implements Exception {
  PurchaseDraftInvalid(this.fieldErrors, this.lineErrors, this.paymentErrors);

  final Map<PurchaseField, String> fieldErrors;
  final List<Map<PurchaseLineField, String>> lineErrors;
  final List<Map<PurchasePaymentField, String>> paymentErrors;

  /// 拼成一句话（日志 / 汇总提示用）
  String get summary => <String>[
    ...fieldErrors.values,
    for (final Map<PurchaseLineField, String> e in lineErrors) ...e.values,
    for (final Map<PurchasePaymentField, String> e in paymentErrors) ...e.values,
  ].join('；');

  @override
  String toString() => 'PurchaseDraftInvalid($summary)';
}

/// 保存成功后给 UI 的结果（SnackBar 要显示的三样东西都在这）。
class PurchaseSaved {
  const PurchaseSaved({
    required this.docNo,
    required this.totalCents,
    required this.paidCents,
    required this.dueCents,
    required this.partyDueCents,
    this.changeCents = 0,
  });

  /// 正式单号（主机生成，如 `XS20260927-001`；`doc_no` 前缀按 RULE 约定）
  final String docNo;
  final int totalCents;
  final int paidCents;

  /// 本单欠款 = 合计 − 立即付款（≥ 0）
  final int dueCents;

  /// **找回**（分）—— 付的超过应付的部分（§AY·四）。`0` = 没有找回。
  ///
  /// SnackBar 用它说清「本单记账 ¥93（找回 ¥7）」——
  /// 与销售 `SaleSaved.changeCents` **同构**。
  final int changeCents;

  /// 该供应商**累计**欠款（我欠对方，≥ 0）；散采恒为 0。
  /// 语义取自 `QueryDao.partyBalances`：负 = 我欠对方。
  final int partyDueCents;
}

/// 采购开单服务。**不注入 `AppEnvironment` 之类的东西** —— 它只关心库与规则。
class PurchaseService {
  PurchaseService({required RuleEngine engine, required QueryDao queries})
    : _engine = engine,
      _queries = queries;

  final RuleEngine _engine;
  final QueryDao _queries;

  // ------------------------------------------------------------ 开单页需要的查询

  /// 启用中的供应商（供应商选择器）
  List<Party> activeSuppliers() =>
      PartyDao(_queries.db).findAll(role: PartyRole.supplier, active: true);

  /// 启用中的资金账户（立即付款区；默认账户 = 第一个）
  List<Account> activeAccounts() => AccountDao(_queries.db).findAll(active: true);

  /// 最近采购过的商品（商品选择器**空查询时**显示的「最近使用」）。
  ///
  /// 实现在 `QueryDao.recentProducts`（采购/销售共用一处 SQL，§Z 五）；
  /// 这里只是采购语义的命名转发。没有采购历史时返回空列表，界面退化为纯搜索。
  List<Product> recentlyPurchased({int limit = 20}) =>
      _queries.recentProducts(docTypes: const <DocType>[DocType.purchase], limit: limit);

  // ------------------------------------------------------------ 提交

  /// 提交草稿。校验不通过抛 [PurchaseDraftInvalid]；规则拒绝抛 [StateError]
  /// （此时库已整单回滚，界面走「意外失败」兜底文案）。
  PurchaseSaved create(PurchaseDraft draft, {int? now}) {
    final Map<PurchaseField, String> fieldErrors = draft.validate();
    final List<Map<PurchaseLineField, String>> lineErrors = draft.validateLines();
    final List<Map<PurchasePaymentField, String>> paymentErrors =
        draft.validatePayments();
    if (fieldErrors.isNotEmpty ||
        lineErrors.any((Map<PurchaseLineField, String> e) => e.isNotEmpty) ||
        paymentErrors.any((Map<PurchasePaymentField, String> e) => e.isNotEmpty)) {
      throw PurchaseDraftInvalid(fieldErrors, lineErrors, paymentErrors);
    }

    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;

    final Document document = Document(
      id: newId(),
      // 占位号：主机路径由 `_prepare` 换成正式单号
      docNo: '${Document.pendingDocNoPrefix}${draft.hashCode}',
      docType: DocType.purchase,
      status: DocStatus.confirmed,
      partyId: draft.partyId,
      totalAmount: draft.totalCents,
      occurredAt: draft.occurredAt,
      createdAt: stamp,
      updatedAt: stamp,
      remark: draft.remark.trim().isEmpty ? null : draft.remark.trim(),
    );

    final List<DocumentLine> lines = <DocumentLine>[
      for (final PurchaseLineDraft line in draft.lines)
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

    // §AY·四（与销售同构）：落库走**封顶后**的金额 —— 多付的部分是找回，不落库。
    final List<int> recorded = draft.recordedPaymentCents;
    final List<PaymentEntry> payments = <PaymentEntry>[
      for (int i = 0; i < draft.payments.length; i++)
        if (!draft.payments[i].isBlank && recorded[i] > 0)
          PaymentEntry(
            accountId: draft.payments[i].accountId,
            amount: recorded[i],
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
      // 草稿已把表单能拦的都拦了；走到这里说明是规则层拒绝（整单已回滚）
      throw StateError(outcome.reason ?? '采购单被拒绝（${outcome.status.name}）');
    }

    // ⚠️ **`outcome.document` 带回的是主单刷新前**的样子（`paid_amount = 0`）——
    // 立即付款对 `paid_amount` 的刷新发生在它**之后**。真相在库，
    // 所以这里按 id 读回落库后的最终状态，不信任 outcome 里的缓存值。
    final Document? stored = DocumentDao(_queries.db).findById(applied.id);
    if (stored == null) {
      throw StateError('采购单 ${applied.docNo} 已保存但读不回来，请检查数据库');
    }

    // 累计欠款：`partyBalances` 负值 = 我欠对方。散采（无供应商）恒为 0。
    final String? partyId = stored.partyId;
    final int balance = partyId == null
        ? 0
        : (_queries.partyBalances()[partyId] ?? 0);

    return PurchaseSaved(
      docNo: stored.docNo,
      totalCents: stored.totalAmount,
      paidCents: stored.paidAmount,
      dueCents: stored.totalAmount - stored.paidAmount,
      partyDueCents: balance < 0 ? -balance : 0,
      changeCents: draft.changeCents,
    );
  }

  /// 最小供应商建档（P-7：只有名称 + 电话，免得用户在开单主路径上卡死）。
  ///
  /// ⚠️ Z-4 裁定后**不再直接新建**：委托 `PartyService.ensureParty` ——
  /// 同名启用往来方已存在时**追加 supplier role 或直接返回**，
  /// 不再造出第二条同名 party（往来账分流是对账灾难）。
  /// 完整的往来方建档页在「送货」阶段做。
  Party createSupplier(String name, {String? phone, int? now}) =>
      PartyService(PartyDao(_queries.db))
          .ensureParty(name: name, role: PartyRole.supplier, phone: phone, now: now)
          .party;
}
