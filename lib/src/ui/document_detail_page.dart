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
/// | `delivery` | `in_transit` | 1b 做（送货批次），本页只显示状态 |
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

class DocumentDetailPage extends StatefulWidget {
  const DocumentDetailPage({
    super.key,
    required this.documentId,
    required this.settlements,
    this.products,
    this.onChanged,
  });

  final String documentId;

  /// 核销服务（读详情 + 执行核销）
  final SettlementService settlements;

  /// 明细行要显示商品名；`null` = 只显示数量与单价
  final ProductService? products;

  /// 核销成功后回调（列表页据此刷新）
  final VoidCallback? onChanged;

  @override
  State<DocumentDetailPage> createState() => _DocumentDetailPageState();
}

class _DocumentDetailPageState extends State<DocumentDetailPage> {
  DocumentSummary? _summary;
  List<DocumentLine> _lines = const <DocumentLine>[];
  List<SettlementView> _links = const <SettlementView>[];

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
      return;
    }
    _lines = widget.settlements.linesOf(widget.documentId);
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
    final SettlementSaved? saved = await showSettlementDialog(
      context,
      service: widget.settlements,
      targetDocId: widget.documentId,
      unsettledCents: unsettled,
      inbound: inbound,
      partyLabel: _partyLabel,
    );
    if (!mounted || saved == null) return;

    setState(_load);
    widget.onChanged?.call();

    final String tail = saved.targetUnsettledAfterCents <= 0
        ? '这张单已结清。'
        : '还欠 ¥${Money.formatGrouped(saved.targetUnsettledAfterCents)}。';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已${saved.inbound ? '收' : '付'} '
          '¥${Money.formatGrouped(saved.amountCents)}（${saved.docNo}）。$tail',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
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
        Text(
          '$_partyLabel · ${formatDateTime(doc.occurredAt)}',
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
    final int unsettled = doc.totalAmount - doc.paidAmount;
    final bool isMoneyDoc =
        doc.docType == DocType.receipt || doc.docType == DocType.payment;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _kv(theme, '金额', '¥${Money.formatGrouped(doc.totalAmount)}', big: true),
            // 收付款单自身没有「已收/未收」（它**就是**那笔钱），只对被核销单显示
            if (!isMoneyDoc && doc.paidAmount != 0)
              _kv(theme, '已${_moneyVerb(doc)}', '¥${Money.formatGrouped(doc.paidAmount)}'),
            if (!isMoneyDoc && unsettled != 0)
              _kv(theme, '未${_moneyVerb(doc)}', '¥${Money.formatGrouped(unsettled)}'),
            _kv(theme, '状态', docStatusLabel(doc.status)),
          ],
        ),
      ),
    );
  }

  /// 「已收 / 未收」用词按方向（销售类 = 收，采购类 = 付）
  String _moneyVerb(Document doc) =>
      SettlementService.isInbound(doc.docType) == false ? '付' : '收';

  Widget _actionRow(ThemeData theme, DocumentSummary summary) {
    final Document doc = summary.document;
    final bool? inbound = SettlementService.isInbound(doc.docType);
    final int unsettled = widget.settlements.unsettledCentsOf(widget.documentId);

    if (inbound == null || unsettled <= 0) {
      return Text(
        inbound == null
            ? '这类单据不需要收付款。'
            : '这张单已经结清了。',
        style: TextStyle(
          height: 1.6,
          color: theme.textTheme.bodySmall?.color,
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        key: const Key('settle-button'),
        onPressed: _settle,
        icon: const Icon(Icons.payments_outlined),
        label: Text(
          '${inbound ? '收款' : '付款'} ¥${Money.formatGrouped(unsettled)}',
        ),
      ),
    );
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
              child: Row(
                children: <Widget>[
                  Expanded(child: Text(_productLabel(_lines[i]), style: const TextStyle(height: 1.6))),
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
                      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
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

  String _productLabel(DocumentLine line) {
    final Product? product = widget.products?.byId(line.productId);
    return product?.name ?? '商品 ${line.productId.substring(0, 8)}';
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
