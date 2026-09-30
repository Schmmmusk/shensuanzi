/// 单据列表页（§AC 四 / SC-3、SC-4、SC-6：只读 + 时间范围 + 类型筛选 + 复制单号）。
///
/// ## 裁定落点
///
/// - **SC-3**：默认**最近 30 天**（不是 limit 200 硬切 —— 200 条只覆盖 10 天）；
///   时间 chips：今天 / 本周 / 本月 / 最近 30 天（默认）/ 全部；「全部」档
///   提示「只显示最近 200 条」
/// - **SC-4**：行**整行可点 = 复制单号**（SnackBar 反馈）—— 把「死路」变成
///   有副作用的动作；底部灰字说明详情开发中
/// - **SC-6**：对方名列（`listDocuments` JOIN parties）；散客/散采显示文字而非空白
/// - 付款核销 / 退货入口**不在本阶段**（§Z 七：随核销阶段）
library;

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
    this.products,
  });

  final DocumentDao dao;

  /// 导出服务（`null` = 不显示导出按钮，与其他可选服务同款判定）
  final ExportSink? exports;

  /// 核销服务（`null` = 行不可点进详情 —— 与其他可选服务同款判定）
  final SettlementService? settlements;

  /// 商品服务（详情页的明细行显示商品名）
  final ProductService? products;

  @override
  State<DocumentsPage> createState() => _DocumentsPageState();
}

class _DocumentsPageState extends State<DocumentsPage> {
  _TimeRange _range = _TimeRange.last30;
  DocType? _typeFilter;

  /// 各档位的起始时间（毫秒）；「全部」返回 `null`
  int? _sinceMillis(_TimeRange range) {
    final DateTime now = DateTime.now();
    final DateTime startOfToday = DateTime(now.year, now.month, now.day);
    return switch (range) {
      _TimeRange.today => startOfToday.millisecondsSinceEpoch,
      _TimeRange.thisWeek => startOfToday
          .subtract(Duration(days: now.weekday - 1))
          .millisecondsSinceEpoch,
      _TimeRange.thisMonth => DateTime(now.year, now.month, 1).millisecondsSinceEpoch,
      _TimeRange.last30 => startOfToday
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch,
      _TimeRange.all => null,
    };
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
          products: widget.products,
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
    final int? since = _sinceMillis(_range);
    final List<DocumentSummary> rows = widget.dao.listDocuments(
      type: _typeFilter,
      sinceMillis: since,
      limit: 200,
    );

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text('单据', style: theme.textTheme.titleLarge),
                  ),
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
                            type: _typeFilter,
                            sinceMillis: since,
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
                '点一行看单据详情；收款、付款、复制单号都在详情页里。',
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              const SizedBox(height: 12),

              // 时间范围 chips（SC-3）
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final _TimeRange range in _TimeRange.values)
                    ChoiceChip(
                      label: Text(range.label),
                      selected: _range == range,
                      onSelected: (bool selected) {
                        if (!selected) return;
                        setState(() => _range = range);
                      },
                    ),
                ],
              ),
              // 类型 chips
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final DocType type in const <DocType>[
                    DocType.purchase,
                    DocType.sale,
                    DocType.receipt,
                    DocType.payment,
                  ])
                    ChoiceChip(
                      label: Text(type.label),
                      selected: _typeFilter == type,
                      onSelected: (bool selected) => setState(() {
                        _typeFilter = selected ? type : null;
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
  const _DocumentRow({super.key, required this.entry, this.onTap});

  final DocumentSummary entry;

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
    final int unsettled = doc.totalAmount - doc.paidAmount;
    final bool showUnsettled = unsettled > 0 &&
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
                  docStatusLabel(doc.status),
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
