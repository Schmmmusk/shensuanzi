/// 退货页 —— 从单据详情发起（`sale` / `delivery` / `purchase` 详情 →「退货」，
/// 送货单另有「客户拒收（整单退回）」）。§BI / reply.md 2026-10-04 裁定。
///
/// ## 分工
///
/// - **规则全在 core**：超额 / 类型不符由 `ReturnDraft.validate` +
///   `RuleEngine`（RULE-007/008，含 R-11 成本比例回退）负责；本页只摆放。
/// - **金额默认 = 累计比例法**（裁定 1）：数量一填，金额自动预填；用户改过
///   （`amountTouched`，与 B1a 价格框同一显式布尔套路）就不再覆盖。
/// - **确认对话框**（裁定 4）：退货是**重大且难逆转**的操作 —— 保存前弹窗
///   写清「退哪些、退多少、退到哪」，确认才提交（弹窗只留给危险操作，§1.3）。
/// - **拒收**（`fullReturn`）：预填全部可退量，用户确认即可。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

class ReturnPage extends StatefulWidget {
  const ReturnPage({
    super.key,
    required this.original,
    required this.service,
    this.fullReturn = false,
  });

  /// 原单（详情页带来的 Document，含类型 / 单号 / 往来方）
  final Document original;

  final ReturnService service;

  /// 拒收模式：预填全部可退量（整单退回）
  final bool fullReturn;

  @override
  State<ReturnPage> createState() => _ReturnPageState();
}

class _ReturnPageState extends State<ReturnPage> {
  final TextEditingController _remark = TextEditingController();
  final TextEditingController _refundAmount = TextEditingController();

  /// 立即退款的账户（`null` = 挂账冲减，不立即退钱）
  Account? _refundAccount;

  /// 退款金额被手改过（§BG 同款显式布尔：编辑非空 = true / 清空 = false；
  /// 没手改时**自动按退货金额合计填入**——真机反馈 §BI·二·补 4）
  bool _refundAmountTouched = false;

  /// 资金账户列表 —— **`initState` 查一次、之后只读缓存**。
  /// ⚠️ 不能在 build 里调 `activeAccounts()`：每次重建都会查库产出**新实例**，
  /// 而用户选中的 `_refundAccount` 是上一次列表里的旧实例 ——
  /// `DropdownButton` 按 `==`（对象同一性）匹配 value 与 items ⇒ 永远匹配不上，
  /// 断言炸、整页卡死（真机踩过：2026-10-04 §BI·二·补 2）。
  List<Account> _accounts = const <Account>[];

  /// 每行的控制器与「金额被手改过」标记（§BG 方案 A 同款套路）
  final Map<String, TextEditingController> _qty = <String, TextEditingController>{};
  final Map<String, TextEditingController> _amount = <String, TextEditingController>{};
  final Set<String> _amountTouched = <String>{};

  Map<String, ReturnQuota> _quotas = const <String, ReturnQuota>{};
  List<String> _productIds = const <String>[];
  ReturnDraftInvalid? _invalid;
  bool _saving = false;

  late final DocType _returnType;

  @override
  void initState() {
    super.initState();
    _returnType = ReturnService.returnTypeFor(widget.original.docType);
    _accounts = widget.service.activeAccounts();
    _quotas = widget.service.quotasFor(
      refDocId: widget.original.id,
      returnType: _returnType,
    );
    _productIds = _quotas.keys.toList(growable: false);
    for (final String pid in _productIds) {
      final ReturnQuota quota = _quotas[pid]!;
      _qty[pid] = TextEditingController(text: widget.fullReturn ? '${quota.remainingQuantity}' : '');
      final int? defaultAmount = widget.fullReturn
          ? quota.remainingAmountCents
          : null;
      _amount[pid] = TextEditingController(
        text: defaultAmount == null ? '' : Money.format(defaultAmount),
      );
      if (widget.fullReturn && defaultAmount != null) _amountTouched.add(pid);
    }
    _syncRefundAmount();
  }

  @override
  void dispose() {
    _remark.dispose();
    _refundAmount.dispose();
    for (final TextEditingController c in _qty.values) {
      c.dispose();
    }
    for (final TextEditingController c in _amount.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------- 草稿合成

  /// 已填了数量的行才进草稿（空行 = 不退这件）。
  ReturnDraft? _draftOrNull() {
    final List<ReturnLineDraft> lines = <ReturnLineDraft>[
      for (final String pid in _productIds)
        if (_qty[pid]!.text.trim().isNotEmpty)
          ReturnLineDraft(
            productId: pid,
            productName: _quotas[pid]!.productName,
            quantity: _qty[pid]!.text,
            amount: _amount[pid]!.text,
            entryUnit: _quotas[pid]!.entryUnit,
            baseUnit: _quotas[pid]!.baseUnit,
            packageUnit: _quotas[pid]!.packageUnit,
            packageSize: _quotas[pid]!.packageSize,
            originalQuantity: _quotas[pid]!.originalQuantity,
            originalAmountCents: _quotas[pid]!.originalAmountCents,
            priorReturnedQuantity: _quotas[pid]!.returnedQuantity,
            priorReturnedAmountCents: _quotas[pid]!.returnedAmountCents,
          ),
    ];
    if (lines.isEmpty) return null;
    return ReturnDraft(
      refDocId: widget.original.id,
      originalDocType: widget.original.docType,
      partyId: widget.original.partyId,
      partyName: '',
      lines: lines,
      refunds: _refundAccount == null || _refundAmount.text.trim().isEmpty
          ? const <ReturnRefundDraft>[]
          : <ReturnRefundDraft>[
              ReturnRefundDraft(
                accountId: _refundAccount!.id,
                accountName: _refundAccount!.name,
                amount: _refundAmount.text,
              ),
            ],
      remark: _remark.text,
    );
  }

  // ---------------------------------------------------------- 动作

  void _onQtyChanged(String pid, String text) {
    // 数量一填：金额自动预填累计比例法的默认值（裁定 1）；
    // 用户手改过（touched）就不再覆盖 —— 与 B1a 价格框同款
    final ReturnQuota? quota = _quotas[pid];
    if (quota == null) return;
    final ReturnLineDraft probe = ReturnLineDraft(
      productId: pid,
      productName: quota.productName,
      quantity: text,
      amount: _amount[pid]!.text,
      entryUnit: quota.entryUnit,
      baseUnit: quota.baseUnit,
      packageUnit: quota.packageUnit,
      packageSize: quota.packageSize,
      originalQuantity: quota.originalQuantity,
      originalAmountCents: quota.originalAmountCents,
      priorReturnedQuantity: quota.returnedQuantity,
      priorReturnedAmountCents: quota.returnedAmountCents,
    );
    final int? defaultAmount = probe.defaultAmountCents;
    if (!_amountTouched.contains(pid) && defaultAmount != null) {
      _amount[pid]!.text = Money.format(defaultAmount);
    }
    _syncRefundAmount();
    setState(() => _invalid = null);
  }

  void _onAmountChanged(String pid, String text) {
    if (text.trim().isNotEmpty) _amountTouched.add(pid);
    _syncRefundAmount();
    setState(() => _invalid = null);
  }

  /// 退款金额 = 上面各行退货金额的合计（**只在没手改过时自动填**；
  /// 手改过就不覆盖，清空恢复自动 —— 与行金额的 `amountTouched` 同款）。
  /// 行金额非法 / 空的行跳过；合计为 0（还没填）⇒ 清空。
  void _syncRefundAmount() {
    if (_refundAmountTouched) return;
    int total = 0;
    for (final TextEditingController c in _amount.values) {
      final int? cents = Money.tryParseYuan(c.text.trim());
      if (cents != null) total += cents;
    }
    _refundAmount.text = total > 0 ? Money.format(total) : '';
  }

  /// 保存：确认对话框（裁定 4 —— 退货是重大且难逆转的操作）→ 引擎。
  Future<void> _save() async {
    if (_saving) return;
    final ReturnDraft? draft = _draftOrNull();
    if (draft == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填至少一行的退货数量')),
      );
      return;
    }
    if (draft.totalCents <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('退货金额合计要大于 0')),
      );
      return;
    }

    final bool confirmed = await _confirm(draft);
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    try {
      final ReturnSaved saved = widget.service.create(draft);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '退货单 ${saved.docNo} 已保存，冲减 '
            '¥${Money.formatGrouped(saved.totalCents)}'
            '（原单 ${saved.originalDocNo}）。',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
      Navigator.of(context).pop();
    } on ReturnDraftInvalid catch (error) {
      setState(() {
        _invalid = error;
        _saving = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('没能保存（$error）。请检查后重试；一直这样请把这句话告诉技术支持。'),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  /// 确认对话框（裁定 4）：写清「退什么、退多少、退款到哪」。
  Future<bool> _confirm(ReturnDraft draft) async {
    final int lineCount = draft.lines.length;
    final String refundText = draft.refunds.isEmpty
        ? '不立即退钱，冲减欠款'
        : '立即退款 ¥${Money.formatGrouped(draft.refundedCents)}'
            '（${draft.refunds.first.accountName}）';
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('确认退货？'),
        content: Text(
          '将退 $lineCount 行商品，金额合计 '
          '¥${Money.formatGrouped(draft.totalCents)}。\n'
          '$refundText。\n\n'
          '退货会冲减这笔交易，保存后不能撤销。',
          style: const TextStyle(height: 1.7),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('再想想'),
          ),
          FilledButton(
            key: const Key('return-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认退货'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  // ---------------------------------------------------------- 摆放

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('退货 · ${widget.original.docNo}')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '对原单 ${widget.original.docNo}（${widget.original.docType.label}）退货。'
                '每行填「本次退货数量」，金额会按原单比例自动算好，可以改。',
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              const SizedBox(height: 16),
              if (_invalid != null) ...<Widget>[
                Text(
                  _invalid!.summary,
                  style: TextStyle(height: 1.6, color: theme.colorScheme.error),
                ),
                const SizedBox(height: 12),
              ],
              for (final String pid in _productIds) _lineCard(theme, pid),
              const SizedBox(height: 16),
              _refundSection(theme),
              const SizedBox(height: 16),
              _remarkField(),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('return-save'),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.undo_outlined),
                label: Text(_saving ? '保存中…' : '保存退货单'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lineCard(ThemeData theme, String pid) {
    final ReturnQuota quota = _quotas[pid]!;
    final String unit = quota.entryUnit ?? quota.baseUnit ?? '';
    final String baseUnit = quota.baseUnit ?? '';
    final String baseSuffix = baseUnit.isEmpty ? '' : ' $baseUnit';
    // 录入单位是包装（≠ 基本单位）⇒ 输入按「箱」、配额数字按「瓶」——
    // 两者必须分开说清（§BI·二·补 3：曾把瓶数缀「箱」，用户被误导填 120）。
    final bool byPackage =
        unit.isNotEmpty && baseUnit.isNotEmpty && unit != baseUnit;
    final int? size =
        (byPackage && quota.packageSize != null && quota.packageSize! > 0)
        ? quota.packageSize
        : null;
    String? boxGuide;
    if (byPackage) {
      final String pkg = unit;
      if (size == null) {
        boxGuide = '退货数量按「$pkg」填写。';
      } else {
        final int whole = quota.remainingQuantity ~/ size;
        final int rest = quota.remainingQuantity % size;
        boxGuide = rest == 0
            ? '退货数量按「$pkg」填写：1 $pkg = $size$baseSuffix，'
                  '最多可退 $whole $pkg。'
            : '退货数量按「$pkg」填写：1 $pkg = $size$baseSuffix，'
                  '最多可退 $whole $pkg（余 $rest$baseSuffix 不足一箱）。';
      }
    }
    final Map<ReturnLineField, String>? errors = _invalid == null
        ? null
        : _invalid!.lineErrors[_productIds.indexOf(pid)];
    // 超额提示：**实时**内联橙色（裁定 R2 细节 2：不拦人，保存时校验兜底）
    final int? liveQty = int.tryParse(_qty[pid]!.text.trim());
    final int? liveBase = liveQty == null
        ? null
        : toBaseQuantity(
            entryQuantity: liveQty,
            entryUnit: quota.entryUnit,
            baseUnit: quota.baseUnit ?? '',
            packageUnit: quota.packageUnit,
            packageSize: quota.packageSize,
          ).baseQuantityOrNull;
    final bool overQty = liveBase != null && liveBase > quota.remainingQuantity;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              quota.productName,
              style: const TextStyle(height: 1.6, fontWeight: FontWeight.w600),
            ),
            Text(
              '原量 ${quota.originalQuantity}$baseSuffix / '
              '已退 ${quota.returnedQuantity}$baseSuffix / '
              '可退 ${quota.remainingQuantity}$baseSuffix',
              style: TextStyle(
                height: 1.6,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
            if (boxGuide != null) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                boxGuide,
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: Key('return-qty-$pid'),
                    controller: _qty[pid],
                    keyboardType: const TextInputType.numberWithOptions(),
                    onChanged: (String text) => _onQtyChanged(pid, text),
                    decoration: InputDecoration(
                      labelText: unit.isEmpty ? '退货数量' : '退货数量（$unit）',
                      isDense: true,
                      errorText: errors?[ReturnLineField.quantity],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: Key('return-amount-$pid'),
                    controller: _amount[pid],
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (String text) => _onAmountChanged(pid, text),
                    decoration: InputDecoration(
                      labelText: '退货金额（元）',
                      isDense: true,
                      errorText: errors?[ReturnLineField.amount],
                    ),
                  ),
                ),
              ],
            ),
            // 实时换算：按箱填时把瓶数亮出来（金额与库存口径都以瓶为准，
            // 用户不再需要心算 —— §BI·二·补 3）
            if (byPackage && liveBase != null) ...<Widget>[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '填 $liveQty $unit = $liveBase$baseSuffix',
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              ),
            ],
            // 超额提示：内联橙色不拦人（裁定 R2 细节 2），保存时校验兜底
            if (overQty && errors?[ReturnLineField.quantity] == null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                '超过可退数量：最多可退 ${quota.remainingQuantity}$baseSuffix',
                style: const TextStyle(height: 1.6, color: Color(0xFFB45309)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _refundSection(ThemeData theme) {
    final List<Account> accounts = _accounts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('立即退款（可选）', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (accounts.isEmpty)
          Text(
            '没有可用资金账户 —— 退款先挂账冲减，之后可以在收款 / 付款里处理。',
            style: TextStyle(
              height: 1.6,
              color: theme.textTheme.bodySmall?.color,
            ),
          )
        else
          Row(
            children: <Widget>[
              Expanded(
                flex: 3,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '退款账户',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  child: DropdownButton<Account>(
                    value: _refundAccount,
                    isDense: true,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    hint: const Text('不退钱（挂账冲减）'),
                    items: <DropdownMenuItem<Account>>[
                      for (final Account account in accounts)
                        DropdownMenuItem<Account>(
                          value: account,
                          child: Text(account.name, style: const TextStyle(height: 1.6)),
                        ),
                    ],
                    onChanged: (Account? account) =>
                        setState(() => _refundAccount = account),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  key: const Key('return-refund-amount'),
                  controller: _refundAmount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (String text) => setState(
                    () => _refundAmountTouched = text.trim().isNotEmpty,
                  ),
                  decoration: const InputDecoration(
                    labelText: '退款金额（元）',
                    helperText: '不填 = 挂账；自动按退货金额合计填入',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _remarkField() => TextField(
    key: const Key('return-remark'),
    controller: _remark,
    maxLines: 2,
    decoration: const InputDecoration(
      labelText: '备注（可选）',
      border: OutlineInputBorder(),
    ),
  );
}
