/// 期初录入的**提交服务**：草稿 → `RuleEngine`（RULE-009）→ 给 UI 的结果。
///
/// ## 为什么这一层存在（与 `PurchaseService` 同理）
///
/// - **草稿校验不能假设调用方做过** —— 同步层 / 将来的其他入口可能直接调它
/// - **把「构造 Document（totalAmount = 0、无对方、无账户）」这些形状转换
///   收在这里**，界面只调一个 `create(draft)`
/// - `RuleOutcome` 的 `rejected` 在这里转成**异常**，界面走统一的兜底分支
///
/// ## 不做的事
///
/// - **不重复 RULE-009 的规则判断** —— 差额流水 / 盘盈成本都在引擎里；
///   本层校验被绕过的唯一后果是 `dispatch` 返回 `rejected`，整单回滚，库不会脏
/// - **不生成正式单号** —— 主机在 `_prepare` 里生成（`PD` 前缀）；这里只带回
///
/// ## 裁定落点（`docs/reply_review.md` §AD）
///
/// - **AD-4**：`occurred_at` 用**主机时钟**（`now ?? DateTime.now()`）——
///   期初录入只能在主机（Windows）上做，没有离线估算场景
/// - **遗漏 1/2 的数据口径**：`changedCount` / `unchangedCount` 按 dispatch
///   **前**的账面数计算，给 SnackBar 的「其中 N 件无变化」用（建议 2：
///   全无变化时 UI 要给诚实的反馈，不能假装改了什么）
library;

import '../dao/document_dao.dart';
import '../dao/query_dao.dart';
import '../models/document.dart';
import '../rules/rule_engine.dart';
import '../rules/rule_rejection.dart';
import '../util/ids.dart';
import 'document_sink.dart';
import 'stocktake_draft.dart';

/// 保存成功后给 UI 的结果。
class StocktakeResult {
  const StocktakeResult({
    required this.documentId,
    required this.docNo,
    required this.changedCount,
    required this.unchangedCount,
  });

  /// 盘点单 id（单据列表里能查到这张 `PD` 单）
  final String documentId;

  /// 正式单号（主机生成，如 `PD20260928-001`）
  final String docNo;

  /// 数量有变化的行数（diff ≠ 0，产生了流水）
  final int changedCount;

  /// 录入但**无变化**的行数（diff = 0）——用户重复录入时的诚实反馈依据
  final int unchangedCount;
}

/// 草稿校验失败：主单级一句话 + 行级错误，界面直接标红对应输入框。
class StocktakeDraftInvalid implements Exception {
  StocktakeDraftInvalid(this.validation);

  final StocktakeValidation validation;

  /// 拼成一句话（日志 / 汇总提示用）
  String get summary => <String>[
    if (validation.topError != null) validation.topError!,
    ...validation.lineErrors.values,
  ].join('；');

  @override
  String toString() => 'StocktakeDraftInvalid($summary)';
}

/// 期初录入服务。**不注入 `AppEnvironment` 之类的东西** —— 它只关心库与规则。
class StocktakeService {
  StocktakeService({required RuleEngine engine, required QueryDao queries})
    : _engine = engine,
      _queries = queries,
      _sink = null,
      _clock = _systemClock;

  /// **手机端队列版**（2026-10-20 放开「重新清点」，§CV·七十八）。
  ///
  /// 与主机版的区别只有一件：`create()` 不 dispatch、不写库，而是把
  /// 盘点单**入队**（`createDocument`），由主机 `RuleEngine` 落账。
  ///
  /// ⚠️ 为什么主机零改动：`RuleEngine._stocktake(prepared, actual)` 的
  /// actual 取 `stocktakeActual ?? _actualFromLines(lines)` —— 客户端把
  /// **实际数量写进行里**，主机照自己的账面算差额。语义天然正确。
  ///
  /// ⚠️「账面数」由宿主页面从**镜像**查（可能略旧）⇒ 行内差额只是参考，
  /// 真相以主机落账为准（主机永远赢）。
  StocktakeService.queue({
    required DocumentSink sink,
    required QueryDao queries,
    int Function()? clock,
  }) : _sink = sink,
       _queries = queries,
       _clock = clock ?? _systemClock,
       _engine = null;

  final RuleEngine? _engine;
  final DocumentSink? _sink;
  final QueryDao _queries;
  final int Function() _clock;

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;

  /// 提交期初录入。
  ///
  /// [now] 供测试注入时钟；生产留空 = **主机当前时间**（AD-4：没有离线场景）。
  ///
  /// 成功返回 [StocktakeResult]；校验不过抛 [StocktakeDraftInvalid]；
  /// 规则层拒绝抛 [StateError]（此时库已整单回滚，界面走「意外失败」兜底，
  /// **页面输入状态必须完整保留** —— §AD 遗漏 4）。
  StocktakeResult create(StocktakeDraft draft, {int? now}) {
    final StocktakeValidation validation = draft.validate();
    if (!validation.isValid) {
      throw StocktakeDraftInvalid(validation);
    }

    final Map<String, int> actual = draft.toActualQuantities();
    final int stamp = now ?? _clock();

    // **手机队列模式**（2026-10-20 放开「重新清点」，§CV·七十八）：
    // 不 dispatch、不写库，把盘点单入队，由**主机** `RuleEngine` 落账。
    // 与主机版的差异只有「谁来应用规则」这一件。
    final DocumentSink? sink = _sink;
    if (sink != null) {
      final DocumentSubmitResult submitted = sink.submitStocktake(
        draft,
        now: stamp,
      );
      if (!submitted.isQueued) {
        // 出口配错（例如塞了主机的 ServiceSink）—— 宁可抛，不静默走错路
        throw StateError('盘点出口没有入队；主机侧请用 StocktakeService() 主构造');
      }
      // 客户端只知道 id 与占位号；正式单号与 changedCount 要等 pull 回来
      return StocktakeResult(
        documentId: submitted.documentId ?? '',
        docNo: submitted.finalDocNo,
        changedCount: actual.length,
        unchangedCount: 0,
      );
    }

    // 变化统计的基准：dispatch **前**的账面数（引擎在事务内算 diff，
    // 与这里的快照是同一口径：账面 = SUM(stock_ledger.quantity)）
    final Map<String, int> bookBefore = _queries.stockByProduct();

    final Document document = Document(
      id: newId(),
      // 占位号：主机路径由 `_prepare` 换成正式单号（PD 前缀）
      docNo: '${Document.pendingDocNoPrefix}${draft.hashCode}',
      docType: DocType.stocktake,
      status: DocStatus.confirmed,
      // RULE-009 硬约束：盘点单 total_amount 必须为 0（成本口径由
      // `CostPolicy.surplusCost` 决定 —— 无历史即 0，AB-2）
      totalAmount: 0,
      occurredAt: stamp,
      createdAt: stamp,
      updatedAt: stamp,
      // §审查 OBS-09①：备注由草稿给（期初录入 / 重新清点），不再写死
      remark: draft.remark,
    );

    final RuleOutcome outcome = _engine!.dispatch(
      document: document,
      stocktakeActual: actual,
      now: stamp,
    );
    if (outcome.status != RuleStatus.applied || outcome.document == null) {
      // #23（裁定④）：**防御性类型化** —— RULE-009 现无可达拒绝，本行
      // 无测试覆盖（登记在案）；类型化是为了与其它服务一致 + 将来规则
      // 收紧时 UI 兜底语义自动正确。同 #23 补丁：仅业务拒绝转类型。
      final RuleRejected? business = outcome.businessRejection;
      if (business != null) throw business;
      throw StateError(outcome.reason ?? '期初录入被拒绝（${outcome.status.name}）');
    }

    // 真相在库：按 id 读回落库后的最终状态（不信任 outcome 里的缓存值）
    final Document? stored = DocumentDao(
      _queries.db,
    ).findById(outcome.document!.id);
    if (stored == null) {
      throw StateError(
        '盘点单 ${outcome.document!.docNo} '
        '已保存但读不回来，请检查数据库',
      );
    }

    int changed = 0;
    int unchanged = 0;
    actual.forEach((String productId, int qty) {
      if (qty - (bookBefore[productId] ?? 0) == 0) {
        unchanged++;
      } else {
        changed++;
      }
    });

    return StocktakeResult(
      documentId: stored.id,
      docNo: stored.docNo,
      changedCount: changed,
      unchangedCount: unchanged,
    );
  }
}
