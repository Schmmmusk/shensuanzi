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
  });

  /// 新建的收付款单 id（详情页可据此跳转）
  final String docId;

  /// 新建的收付款单号（主机已分配正式号）
  final String docNo;

  final int amountCents;

  /// `true` = 收款（`receipt`）；`false` = 付款（`payment`）
  final bool inbound;

  /// 核销后**被核销单**还差多少（0 = 已结清）
  final int targetUnsettledAfterCents;
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
  int unsettledCentsOf(String documentId) {
    final Document? doc = DocumentDao(_db).findById(documentId);
    if (doc == null) return 0;
    return doc.totalAmount - SettlementDao(_db).settledAmountOf(documentId);
  }

  /// 这单核销时是「收款」还是「付款」；`null` = **不能核销**
  static bool? isInbound(DocType type) => switch (type) {
    DocType.sale || DocType.saleReturn || DocType.delivery => true,
    DocType.purchase || DocType.purchaseReturn => false,
    _ => null,
  };

  // ------------------------------------------------------------ 文案（纯函数，可测）

  /// 金额输入的内联提示（UI 每帧调用；`null` = 没问题）。
  ///
  /// 超收**内联提示**而不是弹窗（reply.md 六个待审查项 · 2 / `ui_principles.md` §1.3）：
  /// 「可以不拦人的提醒一律内联，弹窗只留给重大 / 危险 / 不可逆操作」。
  static String? amountNotice({
    required String rawAmount,
    required int unsettledCents,
    required bool inbound,
  }) {
    final String text = rawAmount.trim();
    if (text.isEmpty) return null; // 还没填 —— 不打扰
    final int? cents = Money.tryParseYuan(text);
    if (cents == null) {
      return '只能填数字，比如 ${Money.format(unsettledCents)}';
    }
    if (cents <= 0) return '金额要大于 0';
    if (cents > unsettledCents) {
      return '超过未${inbound ? '收' : '付'}金额 '
          '¥${Money.format(unsettledCents)}，请改小';
    }
    return null;
  }

  /// 提交前的结论句：「…… 后这张单就结清了」/「…… 后还欠 ¥Y」
  static String resultLine({
    required int amountCents,
    required int unsettledCents,
    required bool inbound,
  }) {
    final String verb = inbound ? '收' : '付';
    final int after = unsettledCents - amountCents;
    return after <= 0
        ? '$verb ¥${Money.format(amountCents)} 后这张单就结清了'
        : '$verb ¥${Money.format(amountCents)} 后还欠 ¥${Money.format(after)}';
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

    final int unsettled =
        target.totalAmount - SettlementDao(_db).settledAmountOf(targetDocId);
    if (amountCents <= 0) {
      throw const SettlementInvalid('金额要大于 0。');
    }
    if (amountCents > unsettled) {
      throw SettlementInvalid(
        '超过未${inbound ? '收' : '付'}金额 ¥${Money.format(unsettled)}，请改小。',
      );
    }

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
      totalAmount: amountCents,
      occurredAt: stamp,
      createdAt: stamp,
      updatedAt: stamp,
    );

    final RuleOutcome outcome = _engine.dispatch(
      document: receipt,
      allocations: <Allocation>[
        Allocation(targetDocId: targetDocId, amount: amountCents),
      ],
      now: stamp,
    );
    final Document? applied = outcome.document;
    if (outcome.status != RuleStatus.applied || applied == null) {
      throw SettlementInvalid(outcome.reason ?? '没能记账（${outcome.status.name}）');
    }

    // ⚠️ 按 id **重读**（outcome 里的对象是刷新前的，见 SaleService 同款注）
    final Document? stored = DocumentDao(_db).findById(applied.id);
    final Document? targetAfter = DocumentDao(_db).findById(targetDocId);

    return SettlementSaved(
      docId: stored?.id ?? applied.id,
      docNo: stored?.docNo ?? applied.docNo,
      amountCents: amountCents,
      inbound: inbound,
      targetUnsettledAfterCents: targetAfter == null
          ? 0
          : targetAfter.totalAmount -
                SettlementDao(_db).settledAmountOf(targetDocId),
    );
  }
}
