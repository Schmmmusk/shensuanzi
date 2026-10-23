/// 商品流水页（#27 批 2，2026-10-17 裁定）：某商品的每一笔出入库（人可读版）。
///
/// 照 [AccountFlowPage] / [PartyFlowPage] 模板（批 1 验证过的流水页骨架），
/// 差异三处（裁定 §CV·五十一）：
///
/// - **成本列**：桌面显示 `total_cost`（成本真相）；手机**不显示成本**
///   （诚实口径，与 `stockViewOf` 同族）—— 构造拿 `mobileShell` 区分
/// - **库**：手机壳用**镜像**实例化 `StockLedgerDao`（app.dart 装配，与
///   `stock_page` 的 products / queries 同源）
/// - **行可点**：桌面 tap ⇒ 跳单据详情（stocktake 单详情页有专门分支，
///   `document_detail_page.dart:109`）；手机不可点 + 底部灰字明说
///
/// 日期口径：行 = `occurred_at`（业务日期）；`time_estimated` 标「离线」。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'scaled.dart';

import 'export_button.dart';

/// 某商品的流水页。
class StockFlowPage extends StatelessWidget {
  const StockFlowPage({
    super.key,
    required this.product,
    required this.flowDao,
    this.exports,
    required this.mobileShell,
    this.onOpenDocument,
  });

  final Product product;

  /// 流水查询（手机壳 = 镜像实例化；桌面 = 主库 —— app.dart 装配）
  final StockLedgerDao flowDao;

  /// 导出服务（`null` = 不显示导出按钮）
  final ExportSink? exports;

  /// **手机壳** ⇒ 不显示成本列 + 行不可点 + 底部灰字
  final bool mobileShell;

  /// 桌面：流水行 tap ⇒ 跳对应单据详情。`null`（或手机壳）= 行不可点。
  final void Function(BuildContext context, String documentId)? onOpenDocument;

  @override
  Widget build(BuildContext context) {
    final List<StockFlowEntry> flow = flowDao.ofProductReadable(product.id);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 批 3 第 13 条：断点随缩放派生（2.0 下 600 逻辑像素装不下 2 倍大的字）
        final bool narrow = isNarrowOf(
          context,
          constraints.maxWidth,
          base: flowNarrowBase,
        );
        final Widget page = Scaffold(
          appBar: AppBar(
            title: Text('${product.name} 的流水'),
            actions: <Widget>[
              if (exports != null)
                ExportButton(
                  key: const Key('export-stock-flow'),
                  // 与「导出库存」（库存页）/「导出流水」（往来方 / 账户）同款四字按钮
                  label: '导出流水',
                  export: () => exports!.write(
                    stockFlowExportTable(flow: flow),
                    // AF-7：文件名带商品名 —— 否则导几个商品的文件名一模一样
                    extra: product.name,
                  ),
                ),
            ],
          ),
          body: SafeArea(
            child: flow.isEmpty
                ? Center(
                    child: Text(
                      '还没有出入库流水。',
                      style: TextStyle(
                        height: 1.8,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    itemCount: flow.length + 1, // 末尾多一行灰字说明
                    itemBuilder: (BuildContext context, int index) {
                      if (index == flow.length) {
                        return _footerNote(
                          context,
                          narrow,
                          mobileShell,
                          onOpenDocument != null,
                        );
                      }
                      final StockFlowEntry entry = flow[index];
                      final Widget row = narrow
                          ? _NarrowFlowCard(
                              entry: entry,
                              showCost: !mobileShell,
                            )
                          : _WideFlowTile(entry: entry, showCost: !mobileShell);
                      final bool canTap =
                          !mobileShell && onOpenDocument != null;
                      return InkWell(
                        key: Key('stock-flow-row-${entry.documentId}'),
                        onTap: canTap
                            ? () => onOpenDocument!(context, entry.documentId)
                            : null,
                        child: row,
                      );
                    },
                  ),
          ),
        );
        // 2026-10-21（§CV·八十 Q1）：**不再夹字号**（原 1.15 会静默压掉用户的超大档）。
        // 窄屏靠 `_NarrowFlowCard` 重排（类型/数量用 Wrap，单号+日期单独一行）。
        return page;
      },
    );
  }

  static String _fmtDate(int millis) {
    final DateTime date = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}

/// 底部说明（三态）：桌面 = 「能点」；手机 = 灰字双句（详情去电脑 + 成本在电脑）。
Widget _footerNote(
  BuildContext context,
  bool narrow,
  bool mobileShell,
  bool canOpen,
) {
  final ThemeData theme = Theme.of(context);
  final String text;
  if (canOpen) {
    text = '点流水行可以打开对应单据。';
  } else if (mobileShell) {
    text =
        '手机不显示成本 —— 成本只在电脑上显示。\n'
        '想查看单据详情？到电脑上打开「单据」页就能看到。';
  } else {
    text = '想查看单据详情？在「单据」页找到对应单号。';
  }
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(height: 1.6, color: theme.hintColor),
    ),
  );
}

/// 窄屏流水卡片：行 1 = 类型 + ±数量（右对齐大字）；
/// 行 2 = 单号 + 日期（+ 离线标）；桌面窄窗加成本。
class _NarrowFlowCard extends StatelessWidget {
  const _NarrowFlowCard({required this.entry, required this.showCost});

  final StockFlowEntry entry;
  final bool showCost;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 2026-10-21（§CV·八十 Q1）：`Row + Spacer` → `Wrap`。
          // 剩余宽度为 0 时 `Spacer` 帮不上忙，数量会被推出卡片
          //（与往来流水 #34⑦ 同一处病）。放不下就换行。
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 2,
            children: <Widget>[
              Text(
                entry.docType.label,
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              Text(
                '${entry.quantity}',
                style: const TextStyle(
                  height: 1.6,
                  fontWeight: FontWeight.w700,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Text(
            '${entry.docNo}'
            '${entry.timeEstimated ? ' · 离线' : ''}'
            ' · ${StockFlowPage._fmtDate(entry.occurredAt)}',
            style: TextStyle(
              height: 1.6,
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
          if (showCost)
            Text(
              '成本 ¥${Money.format(entry.totalCost)}'
              '（每件 ¥${Money.format(entry.unitCost)}）',
              style: TextStyle(
                height: 1.6,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
        ],
      ),
    );
  }
}

/// 宽窗流水行：单号 + 类型（+ 离线标）｜ ±数量 ｜（桌面：成本）｜ 日期。
class _WideFlowTile extends StatelessWidget {
  const _WideFlowTile({required this.entry, required this.showCost});

  final StockFlowEntry entry;
  final bool showCost;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.docNo,
                  style: const TextStyle(
                    height: 1.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${entry.docType.label}'
                  '${entry.timeEstimated ? ' · 离线' : ''}',
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${entry.quantity}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 16),
          if (showCost)
            Text(
              '¥${Money.format(entry.totalCost)}',
              style: TextStyle(
                height: 1.6,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
          if (showCost) const SizedBox(width: 16),
          Text(
            StockFlowPage._fmtDate(entry.occurredAt),
            style: TextStyle(
              height: 1.6,
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
    );
  }
}
