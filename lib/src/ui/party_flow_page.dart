/// 往来方流水页（§AA 三 / AA-6）：某往来方的每一笔往来（人可读版）。
///
/// - 每行：**单号 + 单据类型 + 金额 + 日期**（`ofParty` JOIN documents 带回）
/// - 金额口径：正 = 对方欠你增加（应收方向），负 = 减少
/// - **流水行不可点**（遗漏 6）：单据详情页不存在 —— 底部灰字**明说**，
///   避免用户点不动以为是 bug
///
/// ## 窄屏适配（C3·真机反馈，§CH 提案 B1′ 裁定）
///
/// 窄屏（`< 600`）三件事：**整页限幅 `maxScaleFactor: 1.15`**（页内全是单号 /
/// 数字，放大收益低、挤爆布局代价高；1.0 太硬 —— 与其它页的视觉落差会
/// 让用户以为「这页坏了」，保留少量余量）+ **流水行重排**（两行：
/// 类型标签 + 金额 / 单号 + 日期，docNo 不再与金额抢宽 —— 治「单号中间
/// 硬折行」）+ 导出按钮收窄为「导出流水」。宽屏（桌面）保持现状。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'export_button.dart';

/// 某往来方的流水页。
class PartyFlowPage extends StatelessWidget {
  const PartyFlowPage({
    super.key,
    required this.party,
    required this.service,
    this.exports,
  });

  final Party party;
  final PartyService service;

  /// 导出服务（`null` = 不显示导出按钮）
  final ExportSink? exports;

  @override
  Widget build(BuildContext context) {
    final List<PartyFlowEntry> flow = service.flowsOf(party.id);

    // C3·真机反馈 ③：窄屏（< 600）限幅 + 行重排；宽屏（桌面）现状零变化。
    // 限幅值 1.15 —— 1.0 会与其它页产生突兀的视觉落差（裁定 §二 1）。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool narrow = constraints.maxWidth < 600;
        final Widget page = Scaffold(
          appBar: AppBar(
            title: Text('${party.name} 的流水'),
            actions: <Widget>[
              if (exports != null)
                ExportButton(
                  key: const Key('export-party-flow'),
                  // C3·真机反馈 ③：原「导出该往来方的全部流水」在窄屏把
                  // 标题挤成「平⋯」。改四字按钮 —— 语义仍完整（本页只有
                  // 这一个人的流水）；Tooltip 不做兜底（悬浮提示不可用，
                  // ui_principles §1.1：那是隐藏入口）
                  label: '导出流水',
                  export: () => exports!.write(
                    partyFlowExportTable(flow: flow),
                    // AF-7：文件名带往来方名 —— 否则导三个客户的文件名一模一样
                    extra: party.name,
                  ),
                ),
            ],
          ),
          body: SafeArea(
            child: flow.isEmpty
                ? Center(
                    child: Text(
                      '还没有往来流水。',
                      style: TextStyle(height: 1.8, color: Theme.of(context).hintColor),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    itemCount: flow.length + 1, // 末尾多一行灰字说明
                    itemBuilder: (BuildContext context, int index) {
                      if (index == flow.length) {
                        return _footerNote(context, narrow);
                      }
                      final PartyFlowEntry entry = flow[index];
                      return narrow
                          ? _NarrowFlowCard(entry: entry)
                          : _WideFlowTile(entry: entry);
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

/// 需要主题的底部说明（窄宽共用）—— 流水行不可点（遗漏 6），明说。
///
/// 文案两版（C3·Windows 反馈：旧文案「（功能开发中）」已过时 —— 单据页 /
/// 详情页早已实现）：桌面指路「单据」页；手机端无单据页入口 ⇒ 引导到电脑。
Widget _footerNote(BuildContext context, bool narrow) {
  final ThemeData theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(
      narrow
          ? '想查看单据详情？到电脑上打开「单据」页就能看到 —— '
              '手机开单会自动同步过去。'
          : '想查看单据详情？在「单据」页找到对应单号。',
      textAlign: TextAlign.center,
      style: TextStyle(height: 1.6, color: theme.hintColor),
    ),
  );
}

/// 窄屏流水卡片（B1′ 行重排）：行 1 = 类型标签 + 金额（右对齐大字）；
/// 行 2 = 单号（独占整行，不再与金额抢宽 —— 治「单号中间硬折」）+ 日期。
class _NarrowFlowCard extends StatelessWidget {
  const _NarrowFlowCard({required this.entry});

  final PartyFlowEntry entry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool receivable = entry.amount > 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                  // 正 = 对方欠你增加（应收方向）；金额是流水页最关键的信息
                  // —— 放大加粗，避免被略过（用户反馈）
                  '${receivable ? '欠款 +' : '还款 -'}'
                  '¥${Money.formatGrouped(entry.amount.abs())}',
                  style: TextStyle(
                    height: 1.6,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: receivable
                        ? theme.colorScheme.onSurface
                        : theme.hintColor,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    entry.docNo,
                    style: const TextStyle(
                      height: 1.6,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  PartyFlowPage._fmtDate(entry.occurredAt),
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 宽屏（桌面）流水行 —— 现状 `ListTile`，零变化。
class _WideFlowTile extends StatelessWidget {
  const _WideFlowTile({required this.entry});

  final PartyFlowEntry entry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool receivable = entry.amount > 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        dense: true,
        title: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                entry.docNo,
                style: const TextStyle(
                  height: 1.6,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              entry.docType.label,
              style: TextStyle(
                height: 1.6,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
          ],
        ),
        subtitle: Text(
          PartyFlowPage._fmtDate(entry.occurredAt),
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
        trailing: Text(
          '${receivable ? '欠款 +' : '还款 -'}'
          '¥${Money.formatGrouped(entry.amount.abs())}',
          style: TextStyle(
            height: 1.6,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: receivable ? theme.colorScheme.onSurface : theme.hintColor,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
