/// 单据列表页（§AC 四 / SC-3、SC-6、§审查 2026-10-05）。
///
/// ## 三排筛选键（都可以组合）
///
/// 1. **时间**（单选）：今天 / 本周 / 本月 / 最近 30 天（默认）/ 自定义 / 全部。
///    「自定义」弹日期范围选择器；「全部」档提示「只显示最近 200 条」（SC-3）
/// 2. **类型**（**多选**，空 = 全部）：采购入库 / 店内销售 / 送货 / 销售退货 /
///    采购退货 / 收款 / 付款。⚠️ **只列已实现**的类型 —— 盘点 / 调拨 v1 不做，
///    摆出来点了没数据会让用户以为「软件坏了」
/// 3. **状态**（**多选**，空 = 不限）：未结清 / 已作废 / 待签收。
///    「未结清」= 金额 − 已核销 − 退货冲减 > 0（与详情页「未收」同一口径）
///
/// - **SC-6**：对方名列（`listDocuments` JOIN parties）；散客/散采显示文字而非空白
/// - 行**整行可点 = 打开详情**（1a 起；复制单号已挪到详情页右上角）
/// - **派生单据**（自动生成的收付款单、拒收产生的整单退货单）默认不进列表；
///   用户明确按这些类目筛时才放开 —— 见 `DocumentDao._summaries`
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'document_detail_page.dart';
import 'export_button.dart';

/// 时间范围档位
enum _TimeRange {
  today('今天'),
  thisWeek('本周'),
  thisMonth('本月'),
  last30('最近 30 天'),
  custom('自定义'),
  all('全部');

  const _TimeRange(this.label);
  final String label;
}

/// 单据列表页。
class DocumentsPage extends StatefulWidget {
  const DocumentsPage({
    super.key,
    required this.dao,
    this.exports,
    this.settlements,
    this.deliveries,
    this.products,
    this.returnService,
  });

  final DocumentDao dao;

  /// 导出服务（`null` = 不显示导出按钮，与其他可选服务同款判定）
  final ExportSink? exports;

  /// 核销服务（`null` = 行不可点进详情 —— 与其他可选服务同款判定）
  final SettlementService? settlements;

  /// 送货服务（详情页的 **[签收]** 按钮用；`null` = 签收入口不可用）
  final DeliveryService? deliveries;

  /// 商品服务（详情页的明细行显示商品名）
  final ProductService? products;

  /// 退货服务（详情页的 **[退货]** / **[客户拒收]** 入口；§BI R2）
  final ReturnService? returnService;

  @override
  State<DocumentsPage> createState() => _DocumentsPageState();
}

class _DocumentsPageState extends State<DocumentsPage> {
  _TimeRange _range = _TimeRange.last30;

  /// 自定义时间范围（只在 `_range == _TimeRange.custom` 且选过之后有效）
  DateTimeRange? _customRange;

  /// 类型筛选 —— **多选**（空 = 全部）。可同时看「送货 + 退货」。
  final Set<DocType> _types = <DocType>{};

  /// 状态视图筛选 —— **多选**（空 = 不限）：未结清 / 已作废 / 待签收。
  final Set<DocumentStatusView> _statusViews = <DocumentStatusView>{};

  /// 类型 chips 的顺序与范围（§审查 2026-10-05）。
  ///
  /// 只列**已实现**的类型：盘点 / 调拨 v1 不做，摆出来点了没数据会让用户
  /// 以为「软件坏了」（`docs/ui_principles.md` §二）。
  static const List<DocType> _typeChoices = <DocType>[
    DocType.purchase,
    DocType.sale,
    DocType.delivery,
    DocType.saleReturn,
    DocType.purchaseReturn,
    DocType.receipt,
    DocType.payment,
  ];

  /// **派生单据**的类目：自动生成的收付款单、拒收产生的整单退货单。
  /// 默认不进列表（否则「一笔生意两条记录」）；用户**明确按这些类目筛选**
  /// 时才放开 —— 否则选了「销售退货」会是一片空白。
  static const Set<DocType> _derivedCategories = <DocType>{
    DocType.receipt,
    DocType.payment,
    DocType.saleReturn,
    DocType.purchaseReturn,
  };

  bool get _includeDerived => _types.any(_derivedCategories.contains);

  /// 时间起点（毫秒）；「全部」/ 自定义但没选过 → `null`
  int? get _sinceMillis {
    final DateTime now = DateTime.now();
    final DateTime startOfToday = DateTime(now.year, now.month, now.day);
    return switch (_range) {
      _TimeRange.today => startOfToday.millisecondsSinceEpoch,
      _TimeRange.thisWeek => startOfToday
          .subtract(Duration(days: now.weekday - 1))
          .millisecondsSinceEpoch,
      _TimeRange.thisMonth =>
        DateTime(now.year, now.month, 1).millisecondsSinceEpoch,
      _TimeRange.last30 =>
        startOfToday.subtract(const Duration(days: 30)).millisecondsSinceEpoch,
      _TimeRange.custom => _customRange == null
          ? null
          : DateTime(
              _customRange!.start.year,
              _customRange!.start.month,
              _customRange!.start.day,
            ).millisecondsSinceEpoch,
      _TimeRange.all => null,
    };
  }

  /// 时间终点（毫秒，**开区间**）。只有自定义范围有上界 ——
  /// 选到 10-05 的含义是「到 10-05 当天结束」，所以传次日 00:00。
  int? get _untilMillis {
    if (_range != _TimeRange.custom || _customRange == null) return null;
    final DateTime end = _customRange!.end;
    return DateTime(
      end.year,
      end.month,
      end.day,
    ).add(const Duration(days: 1)).millisecondsSinceEpoch;
  }

  /// 选自定义范围（取消 ⇒ 保持原来的档位，不把用户丢进空列表）
  Future<void> _pickCustomRange() async {
    final DateTime now = DateTime.now();
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _customRange,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _customRange = picked;
      _range = _TimeRange.custom;
    });
  }

  /// 打开单据详情（1a 起：行点击 = 看详情；**复制单号挪到详情页**）。
  ///
  /// 没接核销服务（`settlements == null`）时行不可点 —— 与其他可选服务
  /// 同款判定（「没接就是不显示 / 不响应」）。
  Future<void> _openDetail(String documentId) async {
    final SettlementService? settlements = widget.settlements;
    if (settlements == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => DocumentDetailPage(
          documentId: documentId,
          settlements: settlements,
          deliveries: widget.deliveries,
          products: widget.products,
          returnService: widget.returnService,
        ),
      ),
    );
    // 详情里可能核销过 —— 回来重查列表（`build` 会重新查 dao）
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // ⚠️ 时间起点**只算一次**：列表与导出必须用同一个值，
    // 否则「列表显示 30 天、导出却从 30 天前那一秒算起」这类缝隙就出来了
    final int? since = _sinceMillis;
    final int? until = _untilMillis;
    // §审查 2026-10-05：退货冲减额由 `_summaries` 一次 JOIN 带出（`returnedCents`）
    // —— 不再单独发一条批量查询
    final List<DocumentSummary> rows = widget.dao.listDocuments(
      types: _types,
      statusViews: _statusViews,
      sinceMillis: since,
      untilMillis: until,
      limit: 200,
      // 明确按「退货 / 收付款」类目筛时，把派生单据放出来（否则一片空白）
      includeDerived: _includeDerived,
    );

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // §BH·六 B1c·补：超大字号下标题被按钮挤成竖排 ⇒ Wrap 自适应换行
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text('单据', style: theme.textTheme.titleLarge),
                  if (widget.exports != null)
                    ExportButton(
                      key: const Key('export-documents'),
                      // AF-2：说清导的是**当前筛选**，不是「这一屏 200 条」
                      label: '导出当前筛选的单据',
                      export: () => widget.exports!.write(
                        documentExportTable(
                          // AF-5：导出走**独立查询**（无 200 上限），
                          // 筛选条件与列表同一份（`since` 是同一个局部变量）
                          widget.dao.listDocumentsForExport(
                            types: _types,
                            statusViews: _statusViews,
                            sinceMillis: since,
                            untilMillis: until,
                            includeDerived: _includeDerived,
                          ),
                        ),
                        from: since == null
                            ? null
                            : DateTime.fromMillisecondsSinceEpoch(since),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                // §审查 OBS-10：排序规则原来只写在代码里 —— 用户看到
                // 「SK-005 排在 SH-002 前面」会以为软件乱排。说清楚就好。
                '点一行看单据详情；收款、付款、复制单号都在详情页里。\n'
                '最新的排在最上面：先按「单据日期」，同一天里按「录入时间」倒序。',
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              const SizedBox(height: 12),

              // 时间范围 chips（SC-3 + §审查 2026-10-05 的「自定义」）
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final _TimeRange range in _TimeRange.values)
                    ChoiceChip(
                      key: Key('doc-range-${range.name}'),
                      // 自定义选过之后，chip 上直接印出这段范围
                      label: Text(
                        range == _TimeRange.custom && _customRange != null
                            ? '${formatDate(_customRange!.start.millisecondsSinceEpoch)}'
                                  '~'
                                  '${formatDate(_customRange!.end.millisecondsSinceEpoch)}'
                            : range.label,
                      ),
                      selected: _range == range,
                      onSelected: (bool selected) {
                        if (!selected) return;
                        if (range == _TimeRange.custom) {
                          // 日期范围选择器要 await —— 不能在 setState 里做
                          unawaited(_pickCustomRange());
                        } else {
                          setState(() => _range = range);
                        }
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // 类型 chips —— **多选**（§审查 2026-10-05：4 类不够用，
              // 补上送货与两种退货；可同时选多个）
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final DocType type in _typeChoices)
                    FilterChip(
                      key: Key('doc-type-${type.wire}'),
                      label: Text(type.label),
                      selected: _types.contains(type),
                      onSelected: (bool selected) => setState(() {
                        if (selected) {
                          _types.add(type);
                        } else {
                          _types.remove(type);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // 状态 chips —— **多选**（空 = 不限）。「未结清」= 金额 − 已核销 −
              // 退货冲减 > 0，与详情页的「未收」同一个口径。
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final DocumentStatusView view
                      in DocumentStatusView.values)
                    FilterChip(
                      key: Key('doc-status-${view.name}'),
                      label: Text(view.label),
                      selected: _statusViews.contains(view),
                      onSelected: (bool selected) => setState(() {
                        if (selected) {
                          _statusViews.add(view);
                        } else {
                          _statusViews.remove(view);
                        }
                      }),
                    ),
                ],
              ),
              if (_range == _TimeRange.all)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '「全部」只显示最近 200 条；想看更早的请用时间范围筛选。',
                      style: TextStyle(
                        height: 1.6,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    '这个范围里没有单据。',
                    textAlign: TextAlign.center,
                    style: TextStyle(height: 1.8, color: theme.hintColor),
                  ),
                )
              else
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < rows.length; i++) ...<Widget>[
                        if (i > 0) const Divider(height: 1),
                        _DocumentRow(
                          key: Key('doc-row-${rows[i].document.id}'),
                          entry: rows[i],
                          returnedCents: rows[i].returnedCents,
                          onTap: widget.settlements == null
                              ? null
                              : () => _openDetail(rows[i].document.id),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单据列表里的一行（1a 起：整行可点 = **打开详情**；复制单号在详情页）
class _DocumentRow extends StatelessWidget {
  const _DocumentRow({
    super.key,
    required this.entry,
    required this.returnedCents,
    this.onTap,
  });

  final DocumentSummary entry;

  /// 该单**已发生的退货冲减额**（分）—— 真实未收的第三项（§审查 BUG-04）
  final int returnedCents;

  /// `null` = 不可点（没接核销服务 —— 与其他可选服务同款判定）
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Document doc = entry.document;
    // SC-6：散客 / 散采显示文字，不是空白
    // ⚠️ 措辞走**共用函数**（`documentPartyLabel`）—— 导出的「对方」列用的是
    //    同一句，两处各写一遍就会漂（§AF AF-9）
    final String party = documentPartyLabel(entry.partyName, doc.docType);
    // 赊账未结清 → 一眼看出「这张还欠钱」（比状态词直接）。
    // 收付款单自身不显示（它**就是**那笔钱）。
    // §审查 BUG-04：真实未收 = 金额 − 已核销 − 退货冲减
    final int unsettled = doc.totalAmount - doc.paidAmount - returnedCents;
    // §审查 BUG-05：已作废（拒收）不显示「未收」—— 不对着废单收款
    // §审查 OBS-07：**退货单是冲减方**，没有「未收」这个概念
    //（它天生"没收到钱"：退货就是把欠款冲掉，不是又欠了一笔）
    final bool isReturnDoc =
        doc.docType == DocType.saleReturn ||
        doc.docType == DocType.purchaseReturn;
    final bool showUnsettled = unsettled > 0 &&
        !isReturnDoc &&
        doc.status != DocStatus.cancelled &&
        doc.docType != DocType.receipt &&
        doc.docType != DocType.payment;
    final String unsettledVerb =
        SettlementService.isInbound(doc.docType) == false ? '未付' : '未收';

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          doc.docNo,
                          style: const TextStyle(
                            height: 1.6,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        doc.docType.label,
                        style: TextStyle(
                          height: 1.6,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '$party · ${_fmtDate(doc.occurredAt)}',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  '¥ ${Money.formatGrouped(doc.totalAmount)}',
                  style: TextStyle(
                    height: 1.6,
                    fontWeight: FontWeight.w700,
                    color: doc.totalAmount >= 0
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.error,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                Text(
                  // ⚠️ 走共用词汇表（`docStatusLabel`）：以前这里是内联三元，
                  //    非「已结清」非「在途」时**直接印英文 wire 值**（`confirmed`）
                  // §审查 BUG-04：状态展示用真实未收判定
                  docStatusLabel(
                    SettlementService.displayStatus(doc, unsettled),
                  ),
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
                if (showUnsettled)
                  Text(
                    '$unsettledVerb ¥${Money.formatGrouped(unsettled)}',
                    style: const TextStyle(
                      height: 1.6,
                      color: Color(0xFFB45309),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtDate(int millis) {
    final DateTime date = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}
