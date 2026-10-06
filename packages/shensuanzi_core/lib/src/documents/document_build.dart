/// 草稿 → 「主单 + 明细 + 立即收付款」的**纯构造**（B3a，2026-10-06）。
///
/// ## 为什么单独抽出来
///
/// 在此之前这段构造**散在三个服务里**（`SaleService.create` /
/// `PurchaseService.create` / `DeliveryService.create`），和落库、跑引擎缠在一起。
/// B3 之后有**两条出口**要用同一份构造：
///
/// | 出口 | 拿它做什么 |
/// |---|---|
/// | 主机 `ServiceSink` | 落库 + 跑 `RuleEngine`（**与 B3 之前完全一样**） |
/// | 客户端 `QueueSink` | 拼 `createDocument` 的 wire payload → 入队（**不落库、不跑规则**） |
///
/// ⚠️ **行为零变化**：这里逐字搬的是三个服务原来的构造语句（连占位单号
/// `待同步-${draft.hashCode}` 都照搬）。抽出的前后，主机路径的落库结果必须
/// **完全一致** —— 现有 sale / purchase / delivery 测试就是这次的回归守卫。
///
/// ## 不含什么
///
/// 不落库、不开事务、不跑规则、不看库。**只把草稿翻译成实体**。
library;

import '../models/document.dart';
import '../models/document_line.dart';
import '../rules/payment_entry.dart';
import '../util/ids.dart';
import 'delivery_draft.dart';
import 'purchase_draft.dart';
import 'sale_draft.dart';

/// 一次「草稿 → 主单 + 明细 + 立即收付款」的构造结果。
class DocumentBuild {
  const DocumentBuild({
    required this.document,
    required this.lines,
    required this.payments,
  });

  /// 主单。`id` 已生成（UUIDv7，同步的**幂等键**）；
  /// `docNo` 是**占位号** —— 主机在 `RuleEngine._prepare` 里换成正式单号。
  final Document document;

  /// 明细（空行已跳过；`quantity` = **换算后的最小单位数量**）
  final List<DocumentLine> lines;

  /// 立即收付款（**已按应收钳制**，0 元行已跳过）。
  /// 送货单**没有收款区** ⇒ 恒为空列表。
  final List<PaymentEntry> payments;

  /// 落库 / 入队时用的 id —— 也是 `createDocument` 的 `entity_id`
  String get documentId => document.id;
}

/// 店内销售（RULE-002）草稿 → 实体。
DocumentBuild buildSaleDocument(SaleDraft draft, {required int now}) {
  final Document document = Document(
    id: newId(),
    // 占位号：主机路径由 `_prepare` 换成正式单号
    docNo: '${Document.pendingDocNoPrefix}${draft.hashCode}',
    docType: DocType.sale,
    status: DocStatus.confirmed,
    partyId: draft.partyId,
    totalAmount: draft.totalCents,
    occurredAt: draft.occurredAt,
    createdAt: now,
    updatedAt: now,
    remark: draft.remark.trim().isEmpty ? null : draft.remark.trim(),
  );

  final List<DocumentLine> lines = <DocumentLine>[
    for (final SaleLineDraft line in draft.lines)
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

  // §AX·一：落库按**钳制后**的金额走 —— 超收的部分是找零，不落库。
  // 逐行钳制（`recordedPaymentCents`），并跳过被钳成 0 的行：
  // 0 元的收付款单没有意义，规则层也会拒。
  final List<int> recorded = draft.recordedPaymentCents;
  final List<PaymentEntry> payments = <PaymentEntry>[
    for (int i = 0; i < draft.payments.length; i++)
      if (!draft.payments[i].isBlank && recorded[i] > 0)
        PaymentEntry(accountId: draft.payments[i].accountId, amount: recorded[i]),
  ];

  return DocumentBuild(document: document, lines: lines, payments: payments);
}

/// 采购入库（RULE-001）草稿 → 实体。
DocumentBuild buildPurchaseDocument(PurchaseDraft draft, {required int now}) {
  final Document document = Document(
    id: newId(),
    // 占位号：主机路径由 `_prepare` 换成正式单号
    docNo: '${Document.pendingDocNoPrefix}${draft.hashCode}',
    docType: DocType.purchase,
    status: DocStatus.confirmed,
    partyId: draft.partyId,
    totalAmount: draft.totalCents,
    occurredAt: draft.occurredAt,
    createdAt: now,
    updatedAt: now,
    remark: draft.remark.trim().isEmpty ? null : draft.remark.trim(),
  );

  final List<DocumentLine> lines = <DocumentLine>[
    for (final PurchaseLineDraft line in draft.lines)
      if (!line.isEmpty)
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
        PaymentEntry(accountId: draft.payments[i].accountId, amount: recorded[i]),
  ];

  return DocumentBuild(document: document, lines: lines, payments: payments);
}

/// 送货（RULE-003）草稿 → 实体。
///
/// ⚠️ 送货单**没有收款区** ⇒ [DocumentBuild.payments] 恒为空列表
/// （客户的付款走核销对话框，不走开单页）。
DocumentBuild buildDeliveryDocument(DeliveryDraft draft, {required int now}) {
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
    createdAt: now,
    updatedAt: now,
    remark: draft.remark.trim().isEmpty ? null : draft.remark.trim(),
  );

  final List<DocumentLine> lines = <DocumentLine>[
    for (final DeliveryLineDraft line in draft.lines)
      if (!line.isEmpty)
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

  return DocumentBuild(
    document: document,
    lines: lines,
    payments: const <PaymentEntry>[],
  );
}
