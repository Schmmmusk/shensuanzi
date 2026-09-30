/// 收款 / 付款对话框（批次 1a，`docs/rules.md` RULE-004 / RULE-005）。
///
/// **本文件只摆放**：金额边界、提示文案、方向判定全在 core 的
/// `SettlementService`（可 `dart test` 钉住）；这里负责把结论摆出来
/// （`Agents.md` 铁律：判断放纯 Dart）。
///
/// ## 交互要点（reply.md 六个待审查项 · 1 / 2）
///
/// - 金额**预填未收额**，可改小（部分收款）
/// - 超出未收额 → **内联橙色提示**（`errorText`），**不弹窗**
/// - 提交后：SnackBar 说「已收 ¥X，还欠 ¥Y」/「就结清了」
/// - 「顾客给了多少」不在本对话框 —— 那是开单页的现金找零辅助（§AJ·AI-4）
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 打开核销对话框。用户取消 / 直接关闭 → 返回 `null`。
Future<SettlementSaved?> showSettlementDialog(
  BuildContext context, {
  required SettlementService service,
  required String targetDocId,
  required int unsettledCents,
  required bool inbound,
  required String partyLabel,
}) => showDialog<SettlementSaved>(
  context: context,
  builder: (BuildContext dialogContext) => _SettlementDialog(
    service: service,
    targetDocId: targetDocId,
    unsettledCents: unsettledCents,
    inbound: inbound,
    partyLabel: partyLabel,
  ),
);

class _SettlementDialog extends StatefulWidget {
  const _SettlementDialog({
    required this.service,
    required this.targetDocId,
    required this.unsettledCents,
    required this.inbound,
    required this.partyLabel,
  });

  final SettlementService service;
  final String targetDocId;

  /// 未收 / 未付额（分）
  final int unsettledCents;

  /// `true` = 收款（对 sale 系）；`false` = 付款（对 purchase 系）
  final bool inbound;

  /// 对方名（散客 / 散采已由 `documentPartyLabel` 转成文字）
  final String partyLabel;

  @override
  State<_SettlementDialog> createState() => _SettlementDialogState();
}

class _SettlementDialogState extends State<_SettlementDialog> {
  late final TextEditingController _amount = TextEditingController(
    text: Money.format(widget.unsettledCents),
  );

  late final List<Account> _accounts = widget.service.activeAccounts();
  Account? _account;

  bool _saving = false;

  /// 意外失败（规则拒绝 / 数据库错误）——与内联提示分开：它是「提交后」才知道的
  String? _failure;

  @override
  void initState() {
    super.initState();
    _account = _accounts.isEmpty ? null : _accounts.first;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  String get _verb => widget.inbound ? '收款' : '付款';

  /// 内联提示（每帧算一次；逻辑在 core）
  String? get _notice => SettlementService.amountNotice(
    rawAmount: _amount.text,
    unsettledCents: widget.unsettledCents,
    inbound: widget.inbound,
  );

  /// 金额合法时的结论句（「就结清了」/「还欠 ¥Y」）
  String? get _resultLine {
    if (_notice != null) return null;
    final int? cents = Money.tryParseYuan(_amount.text.trim());
    if (cents == null) return null;
    return SettlementService.resultLine(
      amountCents: cents,
      unsettledCents: widget.unsettledCents,
      inbound: widget.inbound,
    );
  }

  Future<void> _confirm() async {
    if (_notice != null) return; // 内联提示已经在屏幕上，用户看得见
    final Account? account = _account;
    if (account == null) {
      setState(() => _failure = '还没有资金账户。先到「账户」页新建一个，再回来$_verb。');
      return;
    }
    final int cents = Money.tryParseYuan(_amount.text.trim())!;

    setState(() {
      _saving = true;
      _failure = null;
    });
    try {
      final SettlementSaved saved = widget.service.settle(
        targetDocId: widget.targetDocId,
        accountId: account.id,
        amountCents: cents,
      );
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } on SettlementInvalid catch (error) {
      setState(() {
        _failure = error.message;
        _saving = false;
      });
    } catch (error) {
      setState(() {
        _failure = '没能记账（$error）。'
            '先关掉这个窗口再试一次；如果一直这样，请把这句话告诉技术支持。';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? notice = _notice;

    return AlertDialog(
      title: Text(_verb),
      content: SizedBox(
        width: 420,
        // ⚠️ 项目铁律：内容一律可滚动（缩放最高档 200%，固定高度会把主按钮顶出屏幕）
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${widget.inbound ? '客户' : '供应商'}：${widget.partyLabel}',
                style: const TextStyle(height: 1.6),
              ),
              const SizedBox(height: 4),
              Text(
                '未${widget.inbound ? '收' : '付'}：'
                '¥${Money.formatGrouped(widget.unsettledCents)}',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 12),

              if (_failure != null) ...<Widget>[
                _failureBox(theme),
                const SizedBox(height: 12),
              ],

              TextField(
                key: const Key('settle-amount'),
                controller: _amount,
                enabled: !_saving,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '本次$_verb金额',
                  suffixText: '元',
                  // 内联提示走 errorText（挂在输入框下面，不弹窗）
                  errorText: notice,
                  helperText: _resultLine ?? '可以只收一部分，剩下的下次再收。',
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),

              Text('进哪个账户', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              if (_accounts.isEmpty)
                Text(
                  '还没有资金账户，先到「账户」页新建一个。',
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                )
              else
                DropdownButton<Account>(
                  key: const Key('settle-account'),
                  value: _account,
                  isExpanded: true,
                  onChanged: _saving
                      ? null
                      : (Account? account) => setState(() => _account = account),
                  items: <DropdownMenuItem<Account>>[
                    for (final Account account in _accounts)
                      DropdownMenuItem<Account>(
                        value: account,
                        child: Text(account.name, style: const TextStyle(height: 1.6)),
                      ),
                  ],
                ),

              const SizedBox(height: 8),
              Text(
                widget.inbound
                    ? '记 1 张收款单：这笔钱进账户，客户的欠款相应减少。'
                    : '记 1 张付款单：这笔钱出账户，欠供应商的款相应减少。',
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _confirm,
          child: Text(_saving ? '记账中…' : '确认$_verb'),
        ),
      ],
    );
  }

  /// 意外失败：说「怎么办」，不把异常原文丢给用户（与建档对话框同款）
  Widget _failureBox(ThemeData theme) {
    final Color color = theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_failure!, style: TextStyle(height: 1.6, color: color)),
          ),
        ],
      ),
    );
  }
}
