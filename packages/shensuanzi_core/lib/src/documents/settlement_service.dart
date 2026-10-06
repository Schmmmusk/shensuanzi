/// 核销（收款 / 付款）—— 从**被核销单**发起，创建独立收付款单（RULE-004 / RULE-005）。
///
/// ## 为什么在 core 而不是 UI
///
/// 「未收额是多少、这单能不能核销、超了怎么提示、提交后还欠多少」都是**规则**，
/// 不是摆放。放纯 Dart 就能 `dart test` 钉住；UI 只负责把结论摆出来
/// （`Agents.md` 铁律：**判断放纯 Dart，Flutter 只摆放**）。
///
/// ## 与「立即收付款」的区别（`docs/rules.md` §零）
///
/// | | 谁生成收付款单 | `ref_doc_id` |
/// |---|---|---|
/// | 开单时的立即收付款（RULE-001/002） | 主机**自动生成** | 指向来源主单 |
/// | 本服务（事后核销） | 用户**手动发起** | `null`（因此**会**出现在单据列表里） |
///
/// ## 方向判定（`docs/rules.md` RULE-004 / RULE-005）
///
/// `sale` / `sale_return` / `delivery` = **对方欠我** → 收款（`receipt`）；
/// `purchase` / `purchase_return` = **我欠对方** → 付款（`payment`）。
/// 其余类型（盘点 / 收付款单自身 / 调拨）不能核销。
library;

import '../dao/document_dao.dart';
import '../dao/settlement_dao.dart';
import '../dao/account_dao.dart';
import '../db/database.dart';
import '../models/account.dart';
import '../models/document.dart';
import '../models/document_line.dart';
import '../models/settlement.dart';
import '../rules/payment_entry.dart';
import '../rules/rule_engine.dart';
import '../util/ids.dart';
import '../util/money.dart';
import 'overpay.dart';

/// 核销失败（文案已说清「怎么办」，UI 直接显示）。
class SettlementInvalid implements Exception {
  const SettlementInvalid(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 核销成功的结果
class SettlementSaved {
  const SettlementSaved({
    required this.docId,
    required this.docNo,
    required this.amountCents,
    required this.inbound,
    required this.targetUnsettledAfterCents,
    this.changeCents = 0,
  });

  /// 新建的收付款单 id（详情页可据此跳转）
  final String docId;

  /// 新建的收付款单号（主机已分配正式号）
  final String docNo;

  /// **实际入账**金额（分）—— 用户填的超过未收额时**已封顶**（§AX·一）
  final int amountCents;

  /// `true` = 收款（`receipt`）；`false` = 付款（`payment`）
  final bool inbound;

  /// 核销后**被核销单**还差多少（0 = 已结清）
  final int targetUnsettledAfterCents;

  /// **找零**（分）—— 用户填的超出未收额的部分。`0` = 没有找零。
  ///
  /// UI 用它在 SnackBar 里说清「已收 ¥93（找零 ¥7）」——
  /// 裁定的**第二处告知**（第一处是提交前的内联提示与按钮文字，§AX·一）。
  final int changeCents;
}

class SettlementService {
  SettlementService({required Db db, required RuleEngine engine})
    : _db = db,
      _engine = engine;

  final Db _db;
  final RuleEngine _engine;

  // ------------------------------------------------------------ 读（详情页）

  /// 启用中的账户（收付款下拉）
  List<Account> activeAccounts() => AccountDao(_db).findAll(active: true);

  /// 单据一行（含对方名）
  DocumentSummary? summaryOf(String documentId) =>
      DocumentDao(_db).summaryById(documentId);

  /// 明细行
  List<DocumentLine> linesOf(String documentId) =>
      DocumentDao(_db).linesOf(documentId);

  /// 这笔钱核销了哪些单（对收款 / 付款单）
  List<SettlementView> allocationsOf(String receiptDocId) =>
      SettlementDao(_db).settlementsOfReceipt(receiptDocId);

  /// 这单被哪些收付款核销过（对被核销单）
  List<SettlementView> settledBy(String targetDocId) =>
      SettlementDao(_db).settlementsOfTarget(targetDocId);

  /// 未收 / 未付额 = `total_amount − SUM(settlements.amount)`
  /// 该单**真实未收付额** = 单据金额 − 已核销 − **已发生的退货冲减**。
  ///
  /// ⚠️ 第三项是 §审查 BUG-04 的修复：退货走 `party_ledger` 冲减往来，
  /// 原单的 `paid_amount` 只累计 `settlements` —— 不减退货的话，
  /// 「未收」永远比真相多、单据永远结不清，用户会**多收/多付**。
  /// 退货额用派生查询（`DocumentDao.returnedAgainst`），不动 `documents` 表。
  int unsettledCentsOf(String documentId) {
    final DocumentDao documents = DocumentDao(_db);
    final Document? doc = documents.findById(documentId);
    if (doc == null) return 0;
    return doc.totalAmount -
        SettlementDao(_db).settledAmountOf(documentId) -
        documents.returnedAgainst(documentId);
  }

  /// 该单**发生过哪些退货**（§审查 2026-10-05）—— 详情页「退货记录」区块。
  ///
  /// 转 `DocumentDao`：详情页只拿得到服务（拿不到 DAO），这里是它唯一的查询面
  /// —— 与 [summaryOf] / [linesOf] / [settledBy] 同款。
  List<DocumentSummary> returnsAgainst(String documentId) =>
      DocumentDao(_db).returnsAgainst(documentId);

  /// 该单产生的**库存流水差额**（商品 → 带符号数量）—— 盘点单详情页算
  /// 「账面 / 差额」用（§审查 OBS-09②）。同样是详情页的查询面转发。
  Map<String, int> stockFlowOf(String documentId) =>
      DocumentDao(_db).stockFlowByProductOf(documentId);

  /// 展示态（**只用于界面**，不改库）：已确认且真实未收付 ≤ 0 ⇒ 显示「已结清」。
  ///
  /// 状态列是引擎写的缓存（依据 `paid_amount`），退货冲减后它不会自己变 ——
  /// §审查 BUG-04 要求界面用「真实未收」判断，且**只在 `confirmed` 上做这一层
  /// 覆盖**：`cancelled` / `in_transit` / `delivered` 各有自己的语义，不许被改写。
  static DocStatus displayStatus(Document doc, int trueUnsettledCents) =>
      doc.status == DocStatus.confirmed && trueUnsettledCents <= 0
      ? DocStatus.settled
      : doc.status;

  /// 这单核销时是「收款」还是「付款」；`null` = **不能核销**
  static bool? isInbound(DocType type) => switch (type) {
    DocType.sale || DocType.saleReturn || DocType.delivery => true,
    DocType.purchase || DocType.purchaseReturn => false,
    _ => null,
  };

  // ------------------------------------------------------------ 文案（纯函数，可测）

  /// 金额输入的**内联提示**（UI 每帧调用；`null` = 没问题）。
  ///
  /// 内联而不是弹窗（reply.md 六个待审查项 · 2 / `ui_principles.md` §1.3）：
  /// 「可以不拦人的提醒一律内联，弹窗只留给重大 / 危险 / 不可逆操作」。
  ///
  /// **硬错误**（必须拦住）：填了但不是数字 / ≤ 0。
  ///
  /// ⚠️ **超收不在此列**（§AX·一，2026-10-02 裁定）—— 填的超过未收额
  /// 是**找零**，不是错误。它走 [changeNotice] / [actionLabel] 的**告知**路径。
  static String? amountError({
    required String rawAmount,
    required int unsettledCents,
  }) {
    final String text = rawAmount.trim();
    if (text.isEmpty) return null; // 还没填 —— 不打扰
    final int? cents = Money.tryParseYuan(text);
    if (cents == null) {
      return '只能填数字，比如 ${Money.format(unsettledCents)}';
    }
    if (cents <= 0) return '金额要大于 0';
    return null;
  }

  /// **超收告知**（橙色，**不是错误**）：`实收 ¥100，其中 ¥93 入账、找零 ¥7`。
  /// 未超收 ⇒ `null`（不打扰）。文案在 [Overpay]，与开单页**同源**。
  static String? changeNotice({
    required String rawAmount,
    required int unsettledCents,
    required bool inbound,
  }) {
    final int? cents = Money.tryParseYuan(rawAmount.trim());
    if (cents == null) return null;
    return Overpay(
      givenCents: cents,
      dueCents: unsettledCents,
    ).notice(paidVerb: inbound ? '收' : '付');
  }

  /// **提交按钮文字**：超收 ⇒ `记 ¥93 并找零 ¥7`；否则 `null`（调用方用默认文字）。
  static String? actionLabel({
    required String rawAmount,
    required int unsettledCents,
  }) {
    final int? cents = Money.tryParseYuan(rawAmount.trim());
    if (cents == null) return null;
    return Overpay(
      givenCents: cents,
      dueCents: unsettledCents,
    ).actionLabel;
  }

  /// 提交前的结论句：「…… 后这张单就结清了」/「…… 后还欠 ¥Y」。
  ///
  /// ⚠️ 按**入账金额**（封顶后）算 —— 超收时 `amountCents` 大于未收额，
  /// 直接拿它减会得到负数（§AX·一）。
  static String resultLine({
    required int amountCents,
    required int unsettledCents,
    required bool inbound,
  }) {
    final String verb = inbound ? '收' : '付';
    final int recorded = Overpay(
      givenCents: amountCents,
      dueCents: unsettledCents,
    ).recordedCents;
    final int after = unsettledCents - recorded;
    return after <= 0
        ? '$verb ¥${Money.format(recorded)} 后这张单就结清了'
        : '$verb ¥${Money.format(recorded)} 后还欠 ¥${Money.format(after)}';
  }

  // ------------------------------------------------------------ 写（核销）

  /// 执行核销（**创建独立的收付款单 + 核销关系**，RULE-004 / RULE-005）。
  ///
  /// 校验不过抛 [SettlementInvalid]（文案已说清怎么办）。
  /// ⚠️ 服务层**自己校验一遍**，不假设调用方校验过（与 `ProductService` 同款）；
  /// 界面上的内联提示只是**提前告知**，不是唯一防线。
  SettlementSaved settle({
    required String targetDocId,
    required String accountId,
    required int amountCents,
    int? now,
  }) {
    final Document? target = DocumentDao(_db).findById(targetDocId);
    if (target == null) {
      throw const SettlementInvalid('找不到这张单，可能已经被删掉了。');
    }
    final bool? inbound = isInbound(target.docType);
    if (inbound == null) {
      throw SettlementInvalid('「${target.docType.label}」这类单据不能核销。');
    }

    // ⚠️ **必须与 `unsettledCentsOf` 同一口径**（金额 − 已核销 − 退货冲减）：
    // 界面上的「收款 ¥45」按钮与这里封顶用的数必须是同一个，否则会出现
    // 「按钮说 45、输入 60 也照收」的分叉（§审查 BUG-04 的收尾）。
    final int unsettled = unsettledCentsOf(targetDocId);
    if (amountCents <= 0) {
      throw const SettlementInvalid('金额要大于 0。');
    }
    // §AX·一（3甲）：超收**不再抛** —— 按未收额**封顶**，多出的是**找零**
    // （现金箱内部的物理流动，不落库）。老板不必心算改回应收额。
    //
    // 但「这张单已经结清了」仍要拦：那时封顶后是 0，落一张 0 元的收付款单
    // 没有意义（规则层也会拒），而且它**不是**超收语义。
    if (unsettled <= 0) {
      throw const SettlementInvalid('这张单已经结清了，不用再收付。');
    }
    final Overpay over = Overpay(givenCents: amountCents, dueCents: unsettled);
    final int recorded = over.recordedCents;

    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;
    final Document receipt = Document(
      id: newId(),
      // 占位号：`dispatch` 会换成正式单号（SK… / FK…）
      docNo: '${Document.pendingDocNoPrefix}${newId().substring(0, 8)}',
      docType: inbound ? DocType.receipt : DocType.payment,
      // 收付款单创建即终态（RULE-004 输出 1）
      status: DocStatus.settled,
      partyId: target.partyId,
      accountId: accountId,
      totalAmount: recorded,
      occurredAt: stamp,
      createdAt: stamp,
      updatedAt: stamp,
    );

    final RuleOutcome outcome = _engine.dispatch(
      document: receipt,
      allocations: <Allocation>[
        Allocation(targetDocId: targetDocId, amount: recorded),
      ],
      now: stamp,
    );
    final Document? applied = outcome.document;
    if (outcome.status != RuleStatus.applied || applied == null) {
      throw SettlementInvalid(outcome.reason ?? '没能记账（${outcome.status.name}）');
    }

    // ⚠️ 按 id **重读**（outcome 里的对象是刷新前的，见 SaleService 同款注）
    final Document? stored = DocumentDao(_db).findById(applied.id);

    return SettlementSaved(
      docId: stored?.id ?? applied.id,
      docNo: stored?.docNo ?? applied.docNo,
      amountCents: recorded,
      inbound: inbound,
      // 与守卫同一个函数 —— 「收完后还欠多少」不可能与「收之前欠多少」分叉
      targetUnsettledAfterCents: unsettledCentsOf(targetDocId),
      changeCents: over.changeCents,
    );
  }
}
