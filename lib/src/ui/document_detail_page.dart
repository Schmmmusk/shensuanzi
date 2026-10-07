/// 单据详情页（批次 1a，`docs/reply_review.md` §AM·二 / §AO）。
///
/// **无导航入口** —— 从单据列表的行点击 `push` 进来（1a 把「行点击 = 复制单号」
/// 改成「行点击 = 打开详情」；复制单号挪到本页）。
///
/// ## 显示什么
///
/// 单号 / 类型 / 对方 / 时间 / 金额 / 已收付 / 未收 / 状态 / 明细行 / **核销去向**
///
/// ## 操作按钮（按类型与状态动态，见 §AL·二 的分支清单）
///
/// | 单据 | 条件 | 按钮 |
/// |---|---|---|
/// | `sale` 系（有客户） | 未收 > 0 | **[收款]**（RULE-004） |
/// | `purchase` 系（有供应商） | 未付 > 0 | **[付款]**（RULE-005） |
/// | `delivery` | `in_transit` | **[签收]**（1b）+ **[客户拒收（整单退回）]**（§BI） |
/// | `sale` / `purchase` / 已签收 `delivery` | 服务已接 | **[退货]**（RULE-007/008，§BI） |
/// | `sale_return` / `purchase_return` | **未退款 > 0** | **[退款给客户 / 收供应商退款]**（2026-10-07，`docs/reply.md` §2：走同一套核销流程，生成独立收付款单） |
/// | `receipt` / `payment` | — | 只读 + **核销去向** |
/// | 全部 | — | **[复制单号]** |
///
/// 逻辑全在 core（`SettlementService`），本页只摆放（`Agents.md` 铁律）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'settlement_dialog.dart';
import 'return_page.dart';

class DocumentDetailPage extends StatefulWidget {
  const DocumentDetailPage({
    super.key,
    required this.documentId,
    required this.settlements,
    this.deliveries,
    this.products,
    this.returnService,
    this.onChanged,
  });

  final String documentId;

  /// 核销服务（读详情 + 执行核销）
  final SettlementService settlements;

  /// 送货服务（批次 1b：`in_transit` 的送货单要显示 **[签收]**）。
  /// `null` = 签收入口不可用（与其余可选服务同款判定）。
  final DeliveryService? deliveries;

  /// 明细行要显示商品名；`null` = 只显示数量与单价
  final ProductService? products;

  /// 退货服务（§BI R2：`sale` / `delivery` / `purchase` 详情的 **[退货]** 与
  /// **[客户拒收]** 入口）。`null` = 入口不可用（与其他可选服务同款判定）。
  final ReturnService? returnService;

  /// 核销成功后回调（列表页据此刷新）
  final VoidCallback? onChanged;

  @override
  State<DocumentDetailPage> createState() => _DocumentDetailPageState();
}

class _DocumentDetailPageState extends State<DocumentDetailPage> {
  DocumentSummary? _summary;
  List<DocumentLine> _lines = const <DocumentLine>[];
  List<SettlementView> _links = const <SettlementView>[];

  /// 这张单被退过什么（§审查 2026-10-05）—— 「为什么 60 的单收 40 就结清了」
  List<DocumentSummary> _returns = const <DocumentSummary>[];

  /// 这张单产生的**库存流水差额**（商品 → 带符号数量）。
  /// 只有盘点单用：账面 = 实盘 − 差额（§审查 OBS-09②）。
  Map<String, int> _stockFlow = const <String, int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final DocumentSummary? summary = widget.settlements.summaryOf(
      widget.documentId,
    );
    _summary = summary;
    if (summary == null) {
      _lines = const <DocumentLine>[];
      _links = const <SettlementView>[];
      _returns = const <DocumentSummary>[];
      _stockFlow = const <String, int>{};
      return;
    }
    _lines = widget.settlements.linesOf(widget.documentId);
    _returns = widget.settlements.returnsAgainst(widget.documentId);
    // §审查 OBS-09②：盘点单的行是**实盘数**，光看行看不出「盘之前是多少」——
    // 差额只能从该单的库存流水反推
    _stockFlow = summary.document.docType == DocType.stocktake
        ? widget.settlements.stockFlowOf(widget.documentId)
        : const <String, int>{};
    // 收款 / 付款单 → 这笔钱核销了哪些单；被核销单 → 被哪些收款核销过
    final bool isMoneyDoc =
        summary.document.docType == DocType.receipt ||
        summary.document.docType == DocType.payment;
    _links = isMoneyDoc
        ? widget.settlements.allocationsOf(widget.documentId)
        : widget.settlements.settledBy(widget.documentId);
  }

  String get _partyLabel => documentPartyLabel(
    _summary?.partyName,
    _summary?.document.docType ?? DocType.sale,
  );

  Future<void> _settle() async {
    final DocumentSummary? summary = _summary;
    if (summary == null) return;
    final bool? inbound = SettlementService.isInbound(summary.document.docType);
    if (inbound == null) return;

    final int unsettled = widget.settlements.unsettledCentsOf(
      widget.documentId,
    );
    // 退货单走同一套流程，只把词换成「退款」——
    // 「付款 / 未付」对着退货单读会让人懵（2026-10-07，`docs/reply.md` §2）
    final bool isReturn = SettlementService.isReturnType(
      summary.document.docType,
    );
    final SettlementSaved? saved = await showSettlementDialog(
      context,
      service: widget.settlements,
      targetDocId: widget.documentId,
      unsettledCents: unsettled,
      inbound: inbound,
      partyLabel: _partyLabel,
      verbOverride: isReturn
          ? SettlementVerb(
              action: _refundVerb(summary.document),
              unsettledLabel: '未退款',
              partyLabel: '客户',
            )
          : null,
    );
    if (!mounted || saved == null) return;

    setState(_load);
    widget.onChanged?.call();

    final String tail = saved.targetUnsettledAfterCents <= 0
        ? (isReturn ? '这张退货单退清了。' : '这张单已结清。')
        : (isReturn
              ? '还差 ¥${Money.formatGrouped(saved.targetUnsettledAfterCents)} 没退。'
              : '还欠 ¥${Money.formatGrouped(saved.targetUnsettledAfterCents)}。');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${isReturn ? '已退' : '已${saved.inbound ? '收' : '付'}'} '
          '¥${Money.formatGrouped(saved.amountCents)}（${saved.docNo}）。$tail',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 打开另一张单（「退货记录」点进去看那张退货单）。
  ///
  /// 复用同一个页面与同一批服务 —— 退货单的详情页结构与本页完全一样。
  Future<void> _openDoc(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => DocumentDetailPage(
          documentId: id,
          settlements: widget.settlements,
          deliveries: widget.deliveries,
          products: widget.products,
          returnService: widget.returnService,
        ),
      ),
    );
    if (!mounted) return;
    setState(_load);
    widget.onChanged?.call();
  }

  void _copyDocNo() {
    final String? docNo = _summary?.document.docNo;
    if (docNo == null) return;
    // 剪贴板写入**不等待**（与单据列表同款：平台通道的 Future 在测试里永不完成）
    unawaited(Clipboard.setData(ClipboardData(text: docNo)));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制单号 $docNo'), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DocumentSummary? summary = _summary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('单据详情'),
        actions: <Widget>[
          if (summary != null)
            TextButton.icon(
              key: const Key('copy-doc-no'),
              onPressed: _copyDocNo,
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('复制单号'),
            ),
        ],
      ),
      body: SafeArea(
        child: summary == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    '找不到这张单。\n可能已经被删掉，或者数据目录换过了。',
                    textAlign: TextAlign.center,
                    style: TextStyle(height: 1.8, color: theme.hintColor),
                  ),
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _header(theme, summary),
                    const SizedBox(height: 16),
                    _amountCard(theme, summary),
                    const SizedBox(height: 16),
                    _actionRow(theme, summary),
                    const SizedBox(height: 20),
                    if (_lines.isNotEmpty) ...<Widget>[
                      _sectionTitle(theme, '明细'),
                      const SizedBox(height: 6),
                      _linesTable(theme),
                      const SizedBox(height: 20),
                    ],
                    // §审查 2026-10-05：退过货才显示（没退过的单不该多一块空白）
                    if (_returns.isNotEmpty) ...<Widget>[
                      _returnsSection(theme),
                      const SizedBox(height: 20),
                    ],
                    _linksSection(theme, summary),
                  ],
                ),
              ),
      ),
    );
  }

  // ---------------------------------------------------------------- 区块

  Widget _header(ThemeData theme, DocumentSummary summary) {
    final Document doc = summary.document;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                doc.docNo,
                style: const TextStyle(
                  height: 1.6,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            ),
            Text(doc.docType.label, style: const TextStyle(height: 1.6)),
          ],
        ),
        // §BG 方案甲：`occurred_at` 是**业务日期**（天粒度，可补录改日期），
        // 套带时分的格式会印出误导性的「00:00」（真机踩过）⇒ 只显示到日；
        // 真实录入时刻在 `created_at`（各司其职），另起一行小字。
        Text(
          '$_partyLabel · ${formatDate(doc.occurredAt)}',
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
        Text(
          '录入于 ${formatDateTime(doc.createdAt)}',
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
      ],
    );
  }

  Widget _amountCard(ThemeData theme, DocumentSummary summary) {
    final Document doc = summary.document;
    // §审查 BUG-04：真实未收 = 金额 − 已核销 − 该单累计退货冲减
    final int unsettled = widget.settlements.unsettledCentsOf(widget.documentId);
    final bool isCancelled = doc.status == DocStatus.cancelled;
    final bool isMoneyDoc =
        doc.docType == DocType.receipt || doc.docType == DocType.payment;
    // 退货单：金额/未结清两行的口径是「该退的钱 / 还没退的钱」
    final bool isReturnDoc = SettlementService.isReturnType(doc.docType);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _kv(
              theme,
              isReturnDoc ? '应退金额' : '金额',
              '¥${Money.formatGrouped(doc.totalAmount)}',
              big: true,
            ),
            // 收付款单自身没有「已收/未收」（它**就是**那笔钱），只对被核销单显示。
            // 退货单上这一行读作「已退款」（`docs/reply.md` §2 的口径）
            if (!isMoneyDoc && doc.paidAmount != 0)
              _kv(
                theme,
                isReturnDoc ? '已退款' : '已${_moneyVerb(doc)}',
                '¥${Money.formatGrouped(doc.paidAmount)}',
              ),
            // §审查 2026-10-05：退过货就把冲减额摆出来 —— 否则用户会问
            // 「单子明明 60，为什么给 40 就说结清了」。作废单也显示（它是事实）。
            if (!isMoneyDoc && summary.returnedCents != 0)
              _kv(
                theme,
                '已退货',
                '−¥${Money.formatGrouped(summary.returnedCents)}',
              ),
            // §审查 BUG-05：已作废的单不显示「未收」——避免对着废单收款的诱导
            if (!isMoneyDoc && !isCancelled && unsettled != 0)
              _kv(
                theme,
                isReturnDoc ? '未退款' : '未${_moneyVerb(doc)}',
                '¥${Money.formatGrouped(unsettled)}',
              ),
            // §审查 BUG-04：状态展示用真实未收判定（已确认且结清 ⇒ 显示已结清）
            _kv(
              theme,
              '状态',
              docStatusLabel(SettlementService.displayStatus(doc, unsettled)),
            ),
          ],
        ),
      ),
    );
  }

  /// 「已收 / 未收」用词按方向（销售类 = 收，采购类 = 付）
  String _moneyVerb(Document doc) =>
      SettlementService.isInbound(doc.docType) == false ? '付' : '收';

  /// 退货单的动词（2026-10-07，`docs/reply.md` §2）。
  ///
  /// 销售退货 = 我方**退钱给客户**；采购退货 = 我方**收供应商退回来的钱**。
  /// 方向与 [_moneyVerb] 同源（`isInbound`），只是动词不同 —— 用「收款 / 付款」
  /// 会让用户对着退货单发懵（真机反馈的同一类问题）。
  String _refundVerb(Document doc) =>
      doc.docType == DocType.saleReturn ? '退款给客户' : '收供应商退款';

  Widget _actionRow(ThemeData theme, DocumentSummary summary) {
    final Document doc = summary.document;
    final bool? inbound = SettlementService.isInbound(doc.docType);
    final int unsettled = widget.settlements.unsettledCentsOf(widget.documentId);
    final bool isDelivery = doc.docType == DocType.delivery;

    final List<Widget> children = <Widget>[];

    // ---- 送货单：**签收**（批次 1b / RULE-003）----
    // 放在收款之前：货送到了才谈得上收钱（状态机：in_transit → delivered → settled）
    if (isDelivery) {
      children.add(_deliverRow(theme, doc));
      children.add(const SizedBox(height: 12));
    }

    // §审查 BUG-05：已作废（如客户拒收）不得保留收款 / 付款入口
    final bool disabled = doc.status == DocStatus.cancelled;
    // §审查 OBS-07：**退货单是冲减方**，不该有「未收 / 未付」概念，
    // 也不给收款 / 付款入口（该退的钱在退货那一刻就记过了 —— 会生成退款单）
    final bool isReturnDoc =
        doc.docType == DocType.saleReturn ||
        doc.docType == DocType.purchaseReturn;
    if (inbound != null && unsettled > 0 && !disabled && !isReturnDoc) {
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('settle-button'),
            onPressed: _settle,
            icon: const Icon(Icons.payments_outlined),
            label: Text(
              '${inbound ? '收款' : '付款'} ¥${Money.formatGrouped(unsettled)}',
            ),
          ),
        ),
      );
    } else if (isReturnDoc && !disabled) {
      // 2026-10-07（`docs/reply.md` §2）：退货**该退的钱**必须能付出去 ——
      // 从前这里只有一句「不用收付款」，于是「开退货时没填立即退款」的单
      // 永远没有退款入口，客户的钱挂在账上无从结清。
      // 处置：同一套核销流程（选账户 + 填金额）生成独立的收付款单
      // —— 守住「任何资金流动都挂在一张收付款单下」（纪律 11）。
      if (unsettled > 0) {
        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('refund-button'),
              onPressed: _settle,
              icon: const Icon(Icons.payments_outlined),
              label: Text(
                '${_refundVerb(doc)} ¥${Money.formatGrouped(unsettled)}',
              ),
            ),
          ),
        );
        children.add(const SizedBox(height: 8));
      }
      children.add(
        Text(
          unsettled > 0
              ? '这张退货单还有 ¥${Money.formatGrouped(unsettled)} 没退 —— '
                    '点上面的按钮，钱从哪个账户出去就在这里选。'
              : '这张退货单的钱已经退清了。',
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
      );
    } else if (!disabled) {
      children.add(
        Text(
          inbound == null ? '这类单据不需要收付款。' : '这张单已经结清了。',
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
      );
    }
    // ⚠️ 作废单**不再补一句「不用收付款」**（§审查 2026-10-05）：
    // 送货单的作废原因由 `_deliverRow` 说（「已作废（客户拒收，货已退回）」），
    // 非送货的作废单才需要在这里说一句。旧代码是「三行并列」——
    // 已作废 + 不用收付款 + 已签收，同一屏上自相矛盾（真机截图）。
    if (disabled && !isDelivery) {
      children.add(
        Text(
          '这张单已作废，不用收付款。',
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
      );
    }

    // ---- 送货单：**拒收的出口**（§BI R2 —— 手册承诺兑现，不再是开发中占位）----
    // 拒收 = 全量 `sale_return` ref delivery（预填全部可退量），原送货单
    // 同事务置 cancelled（裁定 2）。已签收的送货单走普通退货。
    if (isDelivery &&
        widget.returnService != null &&
        doc.status != DocStatus.cancelled) {
      children.add(const SizedBox(height: 8));
      if (doc.status == DocStatus.inTransit) {
        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('reject-button'),
              onPressed: () => _startReturn(doc, fullReturn: true),
              icon: const Icon(Icons.assignment_return_outlined),
              label: const Text('客户拒收（整单退回）'),
            ),
          ),
        );
      } else {
        children.add(
          const Text(
            '这张送货单已签收 —— 要退货请走下面的「退货」。',
            style: TextStyle(height: 1.6, color: Color(0xFFB45309)),
          ),
        );
      }
    }

    // ---- 退货入口（§BI R2）：原单类型可退 且 服务已接 ----
    // §审查 OBS-07：退货单**不能再退**（只列可退的原单类型）
    if (widget.returnService != null &&
        !isReturnDoc &&
        (doc.docType == DocType.sale ||
            doc.docType == DocType.purchase ||
            (isDelivery && doc.status != DocStatus.inTransit)) &&
        doc.status != DocStatus.cancelled) {
      children.add(const SizedBox(height: 8));
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('return-button'),
            onPressed: () => _startReturn(doc, fullReturn: false),
            icon: const Icon(Icons.undo_outlined),
            label: const Text('退货'),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  /// 打开退货页；回来后刷新详情（状态可能变过 —— 拒收会 cancel 原送货单）。
  Future<void> _startReturn(Document doc, {required bool fullReturn}) async {
    final ReturnService? service = widget.returnService;
    if (service == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ReturnPage(
          original: doc,
          service: service,
          fullReturn: fullReturn,
        ),
      ),
    );
    if (mounted) {
      setState(_load);
      widget.onChanged?.call();
    }
  }

  /// 送货单的「签收」行（`in_transit` 才有按钮）。
  Widget _deliverRow(ThemeData theme, Document doc) {
    // §审查 BUG-05：客户拒收 ⇒ 已作废，不能说「已签收」
    if (doc.status == DocStatus.cancelled) {
      return Text(
        '这张送货单已作废（客户拒收，货已退回）。',
        style: TextStyle(height: 1.6, color: theme.colorScheme.error),
      );
    }
    if (doc.status != DocStatus.inTransit) {
      return Text(
        '这张送货单已签收。',
        style: TextStyle(height: 1.6, color: theme.textTheme.bodySmall?.color),
      );
    }
    if (widget.deliveries == null) {
      return Text(
        '签收入口暂时用不了（数据还没就绪）。',
        style: TextStyle(height: 1.6, color: theme.textTheme.bodySmall?.color),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        key: const Key('mark-delivered-button'),
        onPressed: _markDelivered,
        icon: const Icon(Icons.local_shipping_outlined),
        label: const Text('签收'),
      ),
    );
  }

  /// 签收（RULE-003）。**重复点是 no-op**（core 返回 `alreadyDone`，
  /// 文案已说清「这次什么都没变」）—— 中老年用户多点一次不该看到报错。
  Future<void> _markDelivered() async {
    final DeliveryService? deliveries = widget.deliveries;
    if (deliveries == null) return;
    try {
      final DeliverySigned signed = deliveries.markDelivered(widget.documentId);
      if (!mounted) return;
      setState(_load);
      widget.onChanged?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(signed.message),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '没能签收（$error）。'
            '先关掉这一页再试一次；如果一直这样，请把这句话告诉技术支持。',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Widget _linesTable(ThemeData theme) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          for (int i = 0; i < _lines.length; i++) ...<Widget>[
            if (i > 0) const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _productLabel(_lines[i]),
                          style: const TextStyle(height: 1.6),
                        ),
                      ),
                  Text(
                    '× ${_lines[i].quantity}',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                  const SizedBox(width: 12),
                      Text(
                        '¥${Money.formatGrouped(_lines[i].amount)}',
                        style: const TextStyle(
                          height: 1.6,
                          fontWeight: FontWeight.w600,
                          fontFeatures: <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // §审查 OBS-09②：盘点单要看得见「盘之前是多少、差多少」——
                  // 只有实盘数的话，用户没法判断这次盘点动了什么
                  if (_stockFlow.isNotEmpty) _stocktakeDiffLine(theme, i),
                  // v3：有让价的行显示一行小字 —— 原始报价与让价额都可追溯
                  //（amount 是真相；原始报价 = (amount + discount) / entry_quantity）
                  if (_lines[i].discountAmount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '让价 -¥${Money.format(_lines[i].discountAmount)}'
                        '（折前 ¥${Money.format(_lines[i].amount + _lines[i].discountAmount)}）',
                        style: TextStyle(
                          height: 1.6,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 盘点单某一行的「账面 / 差额」小字（§审查 OBS-09②）。
  ///
  /// 账面 = 实盘 − 差额。差额来自该单的 `stock_ledger` 流水（引擎在事务内写的
  /// ±数量），**不是**从行上读的 —— 行的 `quantity` 是盘点后的**实际数量**。
  Widget _stocktakeDiffLine(ThemeData theme, int index) {
    final DocumentLine line = _lines[index];
    final int diff = _stockFlow[line.productId] ?? 0;
    final int actual = line.quantity;
    final int book = actual - diff;
    // 盘亏取绝对值 —— 否则印出「盘亏 -3」两个负号
    final String diffText = diff == 0
        ? '无变化'
        : diff > 0
              ? '盘盈 +${Money.formatGrouped(diff)}'
              : '盘亏 ${Money.formatGrouped(diff.abs())}';
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '账面 ${Money.formatGrouped(book)} → 实盘 ${Money.formatGrouped(actual)}'
        '（$diffText）',
        style: TextStyle(
          height: 1.6,
          color: theme.textTheme.bodySmall?.color,
        ),
      ),
    );
  }

  String _productLabel(DocumentLine line) {
    final Product? product = widget.products?.byId(line.productId);
    return product?.name ?? '商品 ${line.productId.substring(0, 8)}';
  }

  /// 「退货记录」区块（§审查 2026-10-05）。
  ///
  /// 为什么要有它：这张单退过货之后，「未收」会比「金额」小 —— 用户会问
  /// 「单子要 60，怎么后来给 40 就结清了」。把每一次退货摆出来就自洽了。
  /// 整单拒收的退货单**不在列表里单独出现**（见 `DocumentDao._summaries`），
  /// 但在这里一定看得到 —— 它是原单的一部分历史，不是另一个入口。
  Widget _returnsSection(ThemeData theme) {
    final int total = _returns.fold<int>(
      0,
      (int sum, DocumentSummary e) => sum + e.document.totalAmount,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionTitle(theme, '退货记录'),
        const SizedBox(height: 6),
        Text(
          '这张单退过 ${_returns.length} 次，共 ¥${Money.formatGrouped(total)}。'
          '收款 / 付款按扣掉退货后的金额算。',
          style: TextStyle(
            height: 1.8,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
        const SizedBox(height: 6),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: <Widget>[
              for (int i = 0; i < _returns.length; i++) ...<Widget>[
                if (i > 0) const Divider(height: 1),
                InkWell(
                  key: Key('return-row-${_returns[i].document.id}'),
                  onTap: () => _openDoc(_returns[i].document.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                _returns[i].document.docNo,
                                style: const TextStyle(height: 1.6),
                              ),
                              Text(
                                '${_returns[i].document.docType.label} · '
                                '${formatDate(_returns[i].document.occurredAt)}',
                                style: TextStyle(
                                  height: 1.6,
                                  color: theme.textTheme.bodySmall?.color,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '−¥${Money.formatGrouped(_returns[i].document.totalAmount)}',
                          style: const TextStyle(
                            height: 1.6,
                            fontWeight: FontWeight.w600,
                            fontFeatures: <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _linksSection(ThemeData theme, DocumentSummary summary) {
    final bool isMoneyDoc =
        summary.document.docType == DocType.receipt ||
        summary.document.docType == DocType.payment;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionTitle(theme, isMoneyDoc ? '这笔钱核销到了' : '这单被哪些收付款核销过'),
        const SizedBox(height: 6),
        if (_links.isEmpty)
          Text(
            isMoneyDoc ? '还没有核销到具体单据（预收 / 预付）。' : '还没有被核销过。',
            style: TextStyle(
              height: 1.8,
              color: theme.textTheme.bodySmall?.color,
            ),
          )
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (int i = 0; i < _links.length; i++) ...<Widget>[
                  if (i > 0) const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            _links[i].docNo ?? '预收 / 预付（未指定单据）',
                            style: const TextStyle(height: 1.6),
                          ),
                        ),
                        Text(
                          '¥${Money.formatGrouped(_links[i].amount)}',
                          style: const TextStyle(
                            height: 1.6,
                            fontWeight: FontWeight.w600,
                            fontFeatures: <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) => Text(
    text,
    style: theme.textTheme.titleMedium,
  );

  Widget _kv(ThemeData theme, String key, String value, {bool big = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 72,
              child: Text(
                key,
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                height: 1.6,
                fontSize: big ? 20 : null,
                fontWeight: big ? FontWeight.w700 : null,
              ),
            ),
          ],
        ),
      );
}
