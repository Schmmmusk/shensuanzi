/// 开单的「提交出口」抽象（B3a，2026-10-06 裁定：方案 B）。
///
/// ## 为什么需要它
///
/// 三个开单页（销售 / 采购 / 送货）此前**直连** `SaleService` 等服务 ——
/// 那条路会跑 `RuleEngine`。但手机客户端**不实现规则**（`sync_protocol.md` §一），
/// 它的提交出口是「入队，等主机跑」。
///
/// | 实现 | 谁用 | 做什么 |
/// |---|---|---|
/// | [ServiceSink] | 主机（Windows 桌面壳） | 落库 + 跑规则（**与 B3 之前逐字同行为**） |
/// | [QueueSink] | 客户端（手机壳） | `Draft` 校验 → 本地 id + 占位单号 → 写 `sync_queue`（**不落库、不跑规则**） |
///
/// 页面对 [DocumentSink] 编程 —— **UI 层不出现「是不是客户端」的分支**
/// （裁定 ①：分支跑到 UI 层，方案 B 的意义就没了一半）。
///
/// ## 统一返回类型（裁定 ①）
///
/// [DocumentSubmitResult] 统一两端的返回。⚠️ 它比裁定书里的最小形状
/// （`finalDocNo` / `isQueued` / `error`）**多带了展示字段**
/// （`totalCents` / `paidCents` / `dueCents` / `changeCents` / `partyDueCents`
/// / `status`）—— 这是刻意的：桌面 SnackBar 现在就报
/// 「本单记账 ¥93（找零 ¥7）；李姐累计欠款 ¥120」，抽了 Sink 之后**不能丢**
/// （丢了 = 桌面回归）。客户端入队时这些值来自**草稿本地的算术**
/// （与主机构造同源的钳制口径），唯独 [DocumentSubmitResult.partyDueCents]
/// 是 `null` —— 累计欠款依赖完整流水，客户端算不出，**诚实地说不知道**，
/// UI（B3b）对 `null` 省略那一段。
library;

import '../dao/sync_dao.dart';
import '../db/schema.dart';
import '../models/document.dart';
import '../models/document_line.dart';
import '../models/sync_queue_entry.dart';
import '../rules/payment_entry.dart';
import '../sync/sync_operation.dart';
import 'delivery_draft.dart';
import 'delivery_service.dart';
import 'document_build.dart';
import 'draft_invalid.dart';
import 'purchase_draft.dart';
import 'purchase_service.dart';
import 'sale_draft.dart';
import 'sale_service.dart';

/// 一次提交的统一结果（两端同形 —— 裁定 ①）。
class DocumentSubmitResult {
  /// 成功（已落库或已入队）。
  const DocumentSubmitResult({
    required this.finalDocNo,
    required this.isQueued,
    required this.totalCents,
    this.paidCents = 0,
    this.dueCents = 0,
    this.partyDueCents,
    this.changeCents = 0,
    this.status,
    this.documentId,
  }) : error = null;

  /// 校验失败（**不入库、不入队** —— 裁定 ⑥）。
  ///
  /// 带着原始的 `*DraftInvalid`（字段级原因都在），页面照旧按类型取
  /// `fieldErrors` / `lineErrors` 标红输入框 —— 信息零损失。
  const DocumentSubmitResult.failure(DraftInvalidException this.error)
    : finalDocNo = '',
      isQueued = false,
      totalCents = 0,
      paidCents = 0,
      dueCents = 0,
      partyDueCents = null,
      changeCents = 0,
      status = null,
      documentId = null;

  /// 最终单号：主机 = 正式单号（`XS2026…`）；客户端 = 占位单号
  /// （`待同步-…`，主机落地时换正式号 —— §4.2 既有裁定）。
  final String finalDocNo;

  /// `false` = 已落库（主机）；`true` = 已入队待同步（客户端）。
  /// UI 按它选 SnackBar 文案（裁定 ②）。
  final bool isQueued;

  /// 本单合计（分）。客户端入队时 = 草稿合计（与主机构造同源）。
  final int totalCents;

  /// 已收/已付（分，落库口径 = 钳制后）。入队时 = 钳制后收付款之和。
  final int paidCents;

  /// 本单欠款 = 合计 − 已收（≥ 0）。入队时 = 同一算术的本地值。
  final int dueCents;

  /// 往来方**累计**欠款。
  /// ⚠️ **入队时恒为 `null`** —— 累计欠款依赖完整流水，客户端算不出；
  /// UI 对 `null` 省略「累计欠款」段（不猜、不显示 0 冒充真相）。
  final int? partyDueCents;

  /// 找零/找回（分）。入队时 = 草稿的找零（本地事实）。
  final int changeCents;

  /// 单据状态（主机 = 落库后的状态；入队 = 本地构造的初值）。
  final DocStatus? status;

  /// 单据 id（= 队列条目的 `entity_id`，幂等键）。**仅入队路径非空** ——
  /// 主机路径的 `*Saved` 不带 id，不为它扩服务返回面。
  final String? documentId;

  /// 校验失败的非空原因；成功为 `null`。
  final DraftInvalidException? error;

  bool get isFailure => error != null;

  /// 入队成功的**用户告知**（B3b·裁定 ② 的 SnackBar 文案 —— 判定与文案在
  /// core，UI 不造句，与 `DeliverySigned.message` 同一条铁律）。
  ///
  /// 仅 [isQueued] 时非空；**主机路径为 `null`** —— 桌面的 SnackBar 按展示
  /// 字段（合计 / 欠款 / 找零 / 累计欠款）拼装，是 B3 之前的既有行为，零变化。
  String? get queuedNotice => isQueued
      ? '已记入待同步（单号 $finalDocNo）。主机下次联网时会收到。'
      : null;

  @override
  String toString() => isFailure
      ? 'DocumentSubmitResult(failure: $error)'
      : 'DocumentSubmitResult(${isQueued ? 'queued' : 'saved'} $finalDocNo)';
}

/// 开单提交出口。三个开单页只认这个接口（B3b 改接线）。
abstract class DocumentSink {
  DocumentSubmitResult submitSale(SaleDraft draft, {int? now});

  DocumentSubmitResult submitPurchase(PurchaseDraft draft, {int? now});

  DocumentSubmitResult submitDelivery(DeliveryDraft draft, {int? now});
}

/// 主机出口：把三个服务包成 [DocumentSink]。
///
/// ⚠️ **逐字同行为**：内部就是转调 `*Service.create`（校验、规则、异常语义
/// 全部原样）；唯一的新增是把 `*DraftInvalid` 从「抛出」改成「装进结果」
/// （裁定 ①⑥），`StateError`（规则拒绝）**继续向外抛** —— 与现状一致。
class ServiceSink implements DocumentSink {
  ServiceSink({
    required SaleService sales,
    required PurchaseService purchases,
    required DeliveryService deliveries,
  }) : _sales = sales,
       _purchases = purchases,
       _deliveries = deliveries;

  final SaleService _sales;
  final PurchaseService _purchases;
  final DeliveryService _deliveries;

  @override
  DocumentSubmitResult submitSale(SaleDraft draft, {int? now}) {
    try {
      final SaleSaved saved = _sales.create(draft, now: now);
      return DocumentSubmitResult(
        finalDocNo: saved.docNo,
        isQueued: false,
        totalCents: saved.totalCents,
        paidCents: saved.paidCents,
        dueCents: saved.dueCents,
        partyDueCents: saved.partyDueCents,
        changeCents: saved.changeCents,
      );
    } on SaleDraftInvalid catch (error) {
      return DocumentSubmitResult.failure(error);
    }
  }

  @override
  DocumentSubmitResult submitPurchase(PurchaseDraft draft, {int? now}) {
    try {
      final PurchaseSaved saved = _purchases.create(draft, now: now);
      return DocumentSubmitResult(
        finalDocNo: saved.docNo,
        isQueued: false,
        totalCents: saved.totalCents,
        paidCents: saved.paidCents,
        dueCents: saved.dueCents,
        partyDueCents: saved.partyDueCents,
        changeCents: saved.changeCents,
      );
    } on PurchaseDraftInvalid catch (error) {
      return DocumentSubmitResult.failure(error);
    }
  }

  @override
  DocumentSubmitResult submitDelivery(DeliveryDraft draft, {int? now}) {
    try {
      final DeliverySaved saved = _deliveries.create(draft, now: now);
      return DocumentSubmitResult(
        finalDocNo: saved.docNo,
        isQueued: false,
        totalCents: saved.totalCents,
        partyDueCents: saved.partyDueCents,
        status: saved.status,
      );
    } on DeliveryDraftInvalid catch (error) {
      return DocumentSubmitResult.failure(error);
    }
  }
}

/// `createDocument` 的 wire payload（`sync_protocol.md` §8.1）。
///
/// - `document` = `toRow()` **去掉主机专属列**（`hostOnlyColumns`：
///   `paid_amount` / `created_at` / `updated_at` —— 主机自己填）
/// - `lines` = 完整 wire 行，**含客户端生成的 id**
/// - `immediate_payments` = 立即收付款；**空列表时省略键**（与既有
///   selfcheck / host 契约一致：缺键 = 没有）
Map<String, Object?> documentCreatePayload(
  Document document, {
  required List<DocumentLine> lines,
  List<PaymentEntry> immediatePayments = const <PaymentEntry>[],
}) => <String, Object?>{
  'document': document.toRow()
    ..remove('paid_amount')
    ..remove('created_at')
    ..remove('updated_at'),
  'lines': <Object?>[for (final DocumentLine line in lines) line.toRow()],
  if (immediatePayments.isNotEmpty)
    'immediate_payments': <Object?>[
      for (final PaymentEntry payment in immediatePayments) payment.toJson(),
    ],
};

/// 客户端出口：校验 → 入队。**不落库、不跑规则**（裁定 2）。
///
/// 流程（裁定 ③⑥）：`Draft` 校验（与主机共用同一份 `*DraftFailure`）
/// → 本地 UUIDv7 + 占位单号（来自与主机同一份纯构造 `document_build.dart`）
/// → `SyncQueueDao.enqueue`。之后**异步推送一次**是调用方的职责
/// （`MobileSyncService.autoPush`，裁定 ③ —— 本类不碰网络）。
class QueueSink implements DocumentSink {
  QueueSink({required SyncQueueDao queue, int Function()? clock})
    : _queue = queue,
      _clock = clock ?? _systemClock;

  final SyncQueueDao _queue;

  final int Function() _clock;

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;

  @override
  DocumentSubmitResult submitSale(SaleDraft draft, {int? now}) {
    final SaleDraftInvalid? failure = saleDraftFailure(draft);
    if (failure != null) return DocumentSubmitResult.failure(failure);

    final int stamp = now ?? _clock();
    final DocumentBuild build = buildSaleDocument(draft, now: stamp);
    _enqueue(build, immediatePayments: build.payments, now: stamp);

    // 客户端本地的算术 —— 与主机构造同一钳制口径（`build.payments` 已封顶），
    // 不是「臆想的权威值」；权威值等 pull（叠加显示由 `stockViewOf` 负责）。
    final int paid = build.payments.fold<int>(0, (int a, PaymentEntry p) => a + p.amount);
    return DocumentSubmitResult(
      finalDocNo: build.document.docNo,
      isQueued: true,
      totalCents: draft.totalCents,
      paidCents: paid,
      dueCents: draft.totalCents - paid,
      changeCents: draft.changeCents,
      status: build.document.status,
      documentId: build.documentId,
    );
  }

  @override
  DocumentSubmitResult submitPurchase(PurchaseDraft draft, {int? now}) {
    final PurchaseDraftInvalid? failure = purchaseDraftFailure(draft);
    if (failure != null) return DocumentSubmitResult.failure(failure);

    final int stamp = now ?? _clock();
    final DocumentBuild build = buildPurchaseDocument(draft, now: stamp);
    _enqueue(build, immediatePayments: build.payments, now: stamp);

    final int paid = build.payments.fold<int>(0, (int a, PaymentEntry p) => a + p.amount);
    return DocumentSubmitResult(
      finalDocNo: build.document.docNo,
      isQueued: true,
      totalCents: draft.totalCents,
      paidCents: paid,
      dueCents: draft.totalCents - paid,
      changeCents: draft.changeCents,
      status: build.document.status,
      documentId: build.documentId,
    );
  }

  @override
  DocumentSubmitResult submitDelivery(DeliveryDraft draft, {int? now}) {
    final DeliveryDraftInvalid? failure = deliveryDraftFailure(draft);
    if (failure != null) return DocumentSubmitResult.failure(failure);

    final int stamp = now ?? _clock();
    // ⚠️ 送货单没有收款区 ⇒ build.payments 恒空 ⇒ payload 不带
    // `immediate_payments` 键。
    final DocumentBuild build = buildDeliveryDocument(draft, now: stamp);
    _enqueue(build, now: stamp);

    return DocumentSubmitResult(
      finalDocNo: build.document.docNo,
      isQueued: true,
      totalCents: draft.totalCents,
      status: build.document.status,
      documentId: build.documentId,
    );
  }

  void _enqueue(
    DocumentBuild build, {
    List<PaymentEntry> immediatePayments = const <PaymentEntry>[],
    required int now,
  }) {
    final SyncOperation op = SyncOperation(
      entity: Schema.documents,
      entityId: build.documentId,
      operation: SyncOpType.createDocument,
      payload: documentCreatePayload(
        build.document,
        lines: build.lines,
        immediatePayments: immediatePayments,
      ),
    );
    _queue.enqueue(SyncQueueEntry.create(op, now: now));
  }
}
