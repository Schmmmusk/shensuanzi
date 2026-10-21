/// 账户流水页（#27 批 1，2026-10-17 裁定）：某账户的每一笔资金流水（人可读版）。
///
/// 照 [PartyFlowPage] 模板（裁定「批 1 验证流水页模板，批 2 复用」）：
///
/// - 每行：**单号 + 单据类型 + 金额 + 日期**（`ofAccountReadable` JOIN documents 带回）
/// - 金额口径：正 = 进账（余额增加），负 = 出账 —— `money_ledger.amount` 原口径
/// - **桌面行可点** ⇒ 跳对应单据详情（`DocumentDetailPage` 通用页；
///   receipt / payment 都有专门分支）；回调缺省时行不可点，底部灰字**明说**
/// - ⚠️ **手机壳不可达**（账户页不在手机 5 tab 里 —— 登记为设计，不是遗漏）；
///   但窄窗（< 600）限幅 1.15 + 行重排照抄模板，桌面窄窗不破版
///
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'export_button.dart';

/// 某账户的流水页。
class AccountFlowPage extends StatelessWidget {
  const AccountFlowPage({
    super.key,
    required this.account,
    required this.service,
    this.exports,
    this.onOpenDocument,
  });

  final Account account;
  final AccountService service;

  /// 导出服务（`null` = 不显示导出按钮）
  final ExportSink? exports;

  /// **#27 裁定**：桌面流水行 tap ⇒ 跳对应单据详情。`null` = 行不可点
  ///（底部灰字明说，照 party_flow 的「不可点要说清」纪律）。
  final void Function(BuildContext context, String documentId)? onOpenDocument;

  @override
  Widget build(BuildContext context) {
    final List<MoneyFlowEntry> flow = service.flowsOf(account.id);

    // 窄窗（< 600）限幅 + 行重排照抄 party_flow 模板（桌面窄窗不破版）。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool narrow = constraints.maxWidth < 600;
        final Widget page = Scaffold(
          appBar: AppBar(
            title: Text('${account.name} 的流水'),
            actions: <Widget>[
              if (exports != null)
                ExportButton(
                  key: const Key('export-account-flow'),
                  // 与「导出库存」（库存页）/「导出流水」（往来方）同款四字按钮
                  label: '导出流水',
                  export: () => exports!.write(
                    accountFlowExportTable(flow: flow),
                    // AF-7：文件名带账户名 —— 否则导几个账户的文件名一模一样
                    extra: account.name,
                  ),
                ),
            ],
          ),
          body: SafeArea(
            child: flow.isEmpty
                ? Center(
                    child: Text(
                      '还没有资金流水。',
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
                          onOpenDocument != null,
                        );
                      }
                      final MoneyFlowEntry entry = flow[index];
                      final Widget row = narrow
                          ? _NarrowFlowCard(entry: entry)
                          : _WideFlowTile(entry: entry);
                      // #27 裁定：桌面行 tap ⇒ 跳对应单据详情（receipt / payment
                      // 在详情页都有专门分支）。
                      return InkWell(
                        key: Key('account-flow-row-${entry.documentId}'),
                        onTap: onOpenDocument == null
                            ? null
                            : () => onOpenDocument!(context, entry.documentId),
                        child: row,
                      );
                    },
                  ),
          ),
        );
        if (!narrow) return page;
        return MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.15,
          child: page,
        );
      },
    );
  }

  static String _fmtDate(int millis) {
    final DateTime date = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}

/// 底部说明。回调在场 ⇒ 告诉用户「能点」；不在场 ⇒ 照 party_flow 纪律明说
/// 「不可点」，不让用户点了白点。
Widget _footerNote(BuildContext context, bool narrow, bool canOpen) {
  final ThemeData theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(
      canOpen
          ? '点流水行可以打开对应单据。'
          : narrow
          ? '想查看单据详情？到电脑上打开「单据」页就能看到 —— '
                '手机开单会自动同步过去。'
          : '想查看单据详情？在「单据」页找到对应单号。',
      textAlign: TextAlign.center,
      style: TextStyle(height: 1.6, color: theme.hintColor),
    ),
  );
}

/// 窄窗流水卡片（照 party_flow 行重排）：行 1 = 类型标签 + 金额（右对齐大字）；
/// 行 2 = 单号（独占整行）+ 日期（+ 离线标）。
class _NarrowFlowCard extends StatelessWidget {
  const _NarrowFlowCard({required this.entry});

  final MoneyFlowEntry entry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                entry.docType.label,
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              const Spacer(),
              Text(
                '¥${Money.format(entry.amount)}',
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
            ' · ${AccountFlowPage._fmtDate(entry.occurredAt)}',
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

/// 宽窗流水行（照 party_flow）：单号 + 类型 +（离线标）｜ 金额 ｜ 日期。
class _WideFlowTile extends StatelessWidget {
  const _WideFlowTile({required this.entry});

  final MoneyFlowEntry entry;

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
            '¥${Money.format(entry.amount)}',
            style: const TextStyle(
              height: 1.6,
              fontWeight: FontWeight.w700,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 16),
          Text(
            AccountFlowPage._fmtDate(entry.occurredAt),
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
