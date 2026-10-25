/// 店内销售开单的**提交服务**：草稿 → `RuleEngine` → 给 UI 的结果。
///
/// 与 `PurchaseService` 同构（差异见 `sale_draft.dart` 文件头的差异表）；
/// 规则本体在 RULE-002（`RuleEngine._sale`），本层只做「表单门槛 + 形状转换」。
///
/// ## 给 UI 的两个关键约定
///
/// - **`create` 是同步的** —— 库操作进程内完成，界面不用 async/await
/// - ⚠️ **`outcome.document` 带回的是主单刷新前**的样子 —— 立即收款对
///   `paid_amount` 的刷新发生在 outcome 构造**之后**；真相在库，
///   所以这里按 id 读回落库后的最终状态（`docs/testing.md` §N）
library;

import '../dao/account_dao.dart';
import '../dao/document_dao.dart';
import '../dao/party_dao.dart';
import '../dao/query_dao.dart';
import '../master_data/party_service.dart';
import '../models/account.dart';
import '../models/document.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../rules/rule_engine.dart';
import '../rules/rule_rejection.dart';
import 'document_build.dart';
import 'product_backfill.dart';
import 'outstanding.dart';
import 'draft_invalid.dart';
import 'sale_draft.dart';

/// 草稿校验失败：**带三组字段级原因**，界面直接标红对应输入框。
class SaleDraftInvalid implements DraftInvalidException {
  SaleDraftInvalid(this.fieldErrors, this.lineErrors, this.paymentErrors);

  final Map<SaleField, String> fieldErrors;
  final List<Map<SaleLineField, String>> lineErrors;
  final List<Map<SalePaymentField, String>> paymentErrors;

  /// 拼成一句话（日志 / 汇总提示用）
  @override
  String get summary => <String>[
    ...fieldErrors.values,
    for (final Map<SaleLineField, String> e in lineErrors) ...e.values,
    for (final Map<SalePaymentField, String> e in paymentErrors) ...e.values,
  ].join('；');

  @override
  String toString() => 'SaleDraftInvalid($summary)';
}

/// 三组校验跑一遍；**有失败 → 聚成异常返回，全过 → `null`**。
///
/// `SaleService.create` 与 `QueueSink`（B3 客户端入队）**共用这一份**
/// —— 两处各写一遍必然漂移（裁定 ⑥：客户端不跑规则，但**不等于不校验**）。
SaleDraftInvalid? saleDraftFailure(SaleDraft draft) {
  final Map<SaleField, String> fieldErrors = draft.validate();
  final List<Map<SaleLineField, String>> lineErrors = draft.validateLines();
  final List<Map<SalePaymentField, String>> paymentErrors = draft
      .validatePayments();
  if (fieldErrors.isNotEmpty ||
      lineErrors.any((Map<SaleLineField, String> e) => e.isNotEmpty) ||
      paymentErrors.any((Map<SalePaymentField, String> e) => e.isNotEmpty)) {
    return SaleDraftInvalid(fieldErrors, lineErrors, paymentErrors);
  }
  return null;
}

/// 保存成功后给 UI 的结果（与 `PurchaseSaved` 同构 —— 将来抽 `DocumentSaved`）。
class SaleSaved {
  const SaleSaved({
    required this.docNo,
    required this.totalCents,
    required this.paidCents,
    required this.dueCents,
    required this.partyDueCents,
    this.changeCents = 0,
  });

  /// 正式单号（主机生成，如 `XS20260927-001`）
  final String docNo;
  final int totalCents;
  final int paidCents;

  /// 本单欠款 = 合计 − 立即收款（≥ 0）
  final int dueCents;

  /// 该客户**累计**欠款（客户欠我，≥ 0）；散客恒为 0。
  /// 语义取自 `QueryDao.partyBalances`：正 = 对方欠我。
  final int partyDueCents;

  /// **找零**（分）—— 用户填的超过应收的部分（§AX·一）。`0` = 没有找零。
  ///
  /// SnackBar 用它说清「本单记账 ¥93（找零 ¥7）」——
  /// 这是裁定的**第二处告知**（第一处是提交前的内联提示与按钮文字）。
  final int changeCents;
}

/// 店内销售开单服务。**不注入 `AppEnvironment` 之类的东西** —— 它只关心库与规则。
class SaleService {
  SaleService({required RuleEngine engine, required QueryDao queries})
    : _engine = engine,
      _queries = queries;

  final RuleEngine _engine;
  final QueryDao _queries;

  // ------------------------------------------------------------ 开单页需要的查询

  /// 启用中的客户（客户选择器）
  List<Party> activeCustomers() =>
      PartyDao(_queries.db).findAll(role: PartyRole.customer, active: true);

  /// 启用中的资金账户（立即收款区；默认账户 = 第一个）
  List<Account> activeAccounts() =>
      AccountDao(_queries.db).findAll(active: true);

  /// 最近卖过的商品（商品选择器**空查询时**显示的「最近使用」）。
  /// 实现在 `QueryDao.recentProducts`（采购/销售共用一处 SQL，§Z 五）。
  List<Product> recentlySold({int limit = 20}) => _queries.recentProducts(
    docTypes: const <DocType>[DocType.sale],
    limit: limit,
  );

  /// 最近**往来过**的客户（客户选择器空查询时显示的「最近往来」，§Z 遗漏 3）。
  /// 客户群稳定 —— 一开店就能点到常客，不用每次敲搜索词。
  List<Party> recentCustomers({int limit = 20}) => _queries.recentParties(
    docTypes: const <DocType>[DocType.sale],
    limit: limit,
  );

  /// **打开本页时**的库存快照（每商品账面库存）。
  ///
  /// ⚠️ Z-2 裁定：负库存提示用的是**快照** —— 页面加载时查一次，输入时
  /// 只对照快照判断，**不重查**。因为它只是提示不是校验（负库存本来就
  /// 允许，保存必然放行）；UI 文案要标明「打开本页时」（`docs/reply_review.md` §Z 二）。
  Map<String, int> stockSnapshot() => _queries.stockByProduct();

  // ------------------------------------------------------------ 提交

  /// 提交草稿。校验不通过抛 [SaleDraftInvalid]；规则拒绝抛 [StateError]
  /// （此时库已整单回滚，界面走「意外失败」兜底文案）。
  SaleSaved create(SaleDraft draft, {int? now}) {
    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;

    // ② 开单页「无缝建档」（2026-10-25，§CV·一百零五）：整个 create 包在一个
    // 事务里，因为中途可能要**建商品**（`ProductService.create` 自己开事务，
    // `Db.transaction` 可重入 ⇒ 会加入这一层）。
    //
    // 顺序是刻意的：**先补缺档、再校验**。
    // - 校验必须看得到补全后的商品 id（否则手打名字的行永远报「请选一个商品」）；
    // - 校验失败时抛异常 ⇒ **整段回滚** ⇒ 刚建出来的商品也一起没了
    //   （一次打错数量不会在主数据里留下垃圾商品）。
    return _queries.db.transaction(() {
      final SaleDraft full = backfillSaleProducts(
        _queries.db,
        draft,
        now: stamp,
      );
      final SaleDraftInvalid? failure = saleDraftFailure(full);
      if (failure != null) throw failure;
      return _persist(full, stamp);
    });
  }

  /// 真正落库的那一半 —— **必须在 [create] 的事务内调用**（它自己不 BEGIN）。
  SaleSaved _persist(SaleDraft draft, int stamp) {
    // B3a：构造抽到 `document_build.dart`（与 QueueSink 共用一份，行为零变化）
    final DocumentBuild build = buildSaleDocument(draft, now: stamp);

    final RuleOutcome outcome = _engine.dispatch(
      document: build.document,
      lines: build.lines,
      immediatePayments: build.payments,
      now: stamp,
    );

    final Document? applied = outcome.document;
    if (outcome.status != RuleStatus.applied || applied == null) {
      // #23 补丁：只有**业务拒绝**（用户能改）才带类型抛出；协议违反 /
      // 内部 bug（target_missing / rule_internal_error 等）保持既有
      // StateError 真错误语义（UI「请再试一次」+ 日志，M15）。
      final RuleRejected? business = outcome.businessRejection;
      if (business != null) throw business;
      throw StateError(outcome.reason ?? '销售单被拒绝（${outcome.status.name}）');
    }

    // ⚠️ 按 id 读库取最终状态（outcome 缓存的是刷新前的主单，见文件头）
    final Document? stored = DocumentDao(_queries.db).findById(applied.id);
    if (stored == null) {
      throw StateError('销售单 ${applied.docNo} 已保存但读不回来，请检查数据库');
    }

    // 客户累计欠款：正值 = 对方欠我。散客（无客户）恒为 0。
    // 5b：**点查**（从前为这一句扫全表 `party_ledger` —— 每单固定成本）。
    final String? partyId = stored.partyId;
    final int balance = partyId == null ? 0 : _queries.partyBalanceOf(partyId);

    return SaleSaved(
      docNo: stored.docNo,
      totalCents: stored.totalAmount,
      paidCents: stored.paidAmount,
      // 3a（2026-10-24）：未结金额走**唯一口径**（新建时不可能有退货 ⇒ 冲减 0）
      dueCents: outstandingCentsOf(
        docType: stored.docType,
        status: stored.status,
        totalAmount: stored.totalAmount,
        paidAmount: stored.paidAmount,
        returnedAmount: 0,
      ),
      partyDueCents: balance > 0 ? balance : 0,
      changeCents: draft.changeCents,
    );
  }

  /// 最小客户建档（同 P-7 供应商：名称 + 电话可选）。
  ///
  /// 委托 `PartyService.ensureParty`（Z-4）：同名启用往来方已存在时
  /// **追加 customer role 或直接返回**，不造第二条同名 party。
  Party createCustomer(String name, {String? phone, int? now}) =>
      PartyService(PartyDao(_queries.db))
          .ensureParty(
            name: name,
            role: PartyRole.customer,
            phone: phone,
            now: now,
          )
          .party;
}
