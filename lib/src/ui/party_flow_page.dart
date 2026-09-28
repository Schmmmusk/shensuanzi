/// 往来方流水页（§AA 三 / AA-6）：某往来方的每一笔往来（人可读版）。
///
/// - 每行：**单号 + 单据类型 + 金额 + 日期**（`ofParty` JOIN documents 带回）
/// - 金额口径：正 = 对方欠你增加（应收方向），负 = 减少
/// - **流水行不可点**（遗漏 6）：单据详情页不存在 —— 底部灰字**明说**，
///   避免用户点不动以为是 bug
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 某往来方的流水页。
class PartyFlowPage extends StatelessWidget {
  const PartyFlowPage({super.key, required this.party, required this.service});

  final Party party;
  final PartyService service;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<PartyFlowEntry> flow = service.flowsOf(party.id);

    return Scaffold(
      appBar: AppBar(title: Text('${party.name} 的流水')),
      body: SafeArea(
        child: flow.isEmpty
            ? Center(
                child: Text(
                  '还没有往来流水。',
                  style: TextStyle(height: 1.8, color: theme.hintColor),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                itemCount: flow.length + 1, // 末尾多一行灰字说明
                itemBuilder: (BuildContext context, int index) {
                  if (index == flow.length) {
                    // 遗漏 6：流水行不可点 —— 明说「能力还没做」
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        '想查看单据详情？在「单据」页找到对应单号（功能开发中）。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          height: 1.6,
                          color: theme.hintColor,
                        ),
                      ),
                    );
                  }
                  final PartyFlowEntry entry = flow[index];
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
                        _fmtDate(entry.occurredAt),
                        style: TextStyle(
                          height: 1.6,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                      trailing: Text(
                        // 正 = 对方欠你增加（应收方向）；不用负号，用方向字。
                        // 金额是流水页最关键的信息 —— 放大加粗，避免被略过（用户反馈）
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
                    ),
                  );
                },
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
