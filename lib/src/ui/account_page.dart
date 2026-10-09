/// 账户页：列表（余额）+ 新建 / 编辑 + 停用恢复。
///
/// ## 裁定落点（`docs/reply_review.md` §Z）
///
/// - **Z-3 方案 A**：期初余额**新建时可填，编辑时只读** —— 修改它会重算
///   全部历史余额（`data_model.md` §2.3）；编辑框里明说「填错了请新建一个
///   账户再停用这个」。服务层也兜底（草稿值被忽略），双保险
/// - **必填红星**（§Z 遗漏 7）：名称、类型必填
/// - 余额列 = 期初 + 全部流水（`QueryDao.accountBalances` 的口径）
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart'
    show MasterDataPolicy, MobileGuideTopic, mirrorEmptyMessage;
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'mobile_guidance_dialog.dart';

/// 账户类型的界面文案（wire 值是英文，界面上必须说人话）
const Map<AccountType, String> kAccountTypeLabels = <AccountType, String>{
  AccountType.cash: '现金',
  AccountType.wechat: '微信',
  AccountType.alipay: '支付宝',
  AccountType.bank: '银行卡',
  AccountType.other: '其他',
};

/// 账户页。
class AccountsPage extends StatefulWidget {
  const AccountsPage({
    super.key,
    required this.service,
    required this.masterDataPolicy,
  });

  final AccountService service;

  /// **主数据门控**（§CV·九·五 裁定「甲」，2026-10-09）—— 本页只看
  /// `canCreateAccounts`（新建 / 编辑 / 停用恢复三处写面，与往来页同构）。
  ///
  /// ⚠️ **required，不许给默认值**：本页原先是全项目**唯一没接门控**的页面
  /// （旧的 `bool readOnlyMasterData` 也从未传进来过）。而手机端的
  /// `AccountService` 建在**镜像**上 —— 写进去永远到不了电脑。
  /// 带默认值 = 忘了传就「手机上账户能建」且**看不出来**（M15 教训）⇒ 宁可编不过。
  final MasterDataPolicy masterDataPolicy;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Account> accounts = widget.service.list();
    final Map<String, int> balances = widget.service.balances();

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
                  Text('资金账户', style: theme.textTheme.titleLarge),
                  FilledButton.icon(
                    onPressed: () => _editAccount(context),
                    icon: const Icon(Icons.add),
                    label: const Text('新建账户'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '开单时从这里选「钱从哪进出」。余额 = 期初 + 每一笔收付。',
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              const SizedBox(height: 12),
              if (accounts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    // 本机不能建 ⇒ 空列表更可能是「镜像还没拉到」，别让用户
                    // 以为数据丢了（与往来页同款处置）
                    !widget.masterDataPolicy.canCreateAccounts
                        ? mirrorEmptyMessage('账户列表')
                        : '还没有资金账户。点右上角「新建账户」建一个，'
                              '比如「现金」或「微信收款」—— '
                              '有了账户才能在开单时当场收付款。',
                    textAlign: TextAlign.center,
                    style: TextStyle(height: 1.8, color: theme.hintColor),
                  ),
                )
              else
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < accounts.length; i++) ...<Widget>[
                        if (i > 0) const Divider(height: 1),
                        _AccountRow(
                          account: accounts[i],
                          balanceCents: balances[accounts[i].id] ?? 0,
                          onEdit: () => _editAccount(context, existing: accounts[i]),
                          onToggleActive: () => _toggleActive(accounts[i]),
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

  /// 新建（[existing] 为 null）或编辑。
  /// 本机不能建 ⇒ 入口保留，点击后弹引导（不进表单）。
  Future<void> _editAccount(BuildContext context, {Account? existing}) async {
    if (!widget.masterDataPolicy.canCreateAccounts) {
      await showMobileGuideDialog(
        context,
        existing == null
            ? MobileGuideTopic.newAccount
            : MobileGuideTopic.editAccount,
      );
      return;
    }
    final Account? result = await showDialog<Account>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _AccountFormDialog(service: widget.service, existing: existing),
    );
    if (result == null) return;
    if (!mounted) return;
    setState(() {}); // 列表与余额都从服务重读
  }

  /// 停用 / 恢复启用。
  /// 停用/恢复同为主数据写（`updateMasterData`）—— 本机不能建就一并引导。
  Future<void> _toggleActive(Account account) async {
    if (!widget.masterDataPolicy.canCreateAccounts) {
      await showMobileGuideDialog(context, MobileGuideTopic.editAccount);
      return;
    }
    widget.service.setActive(account.id, active: !account.isActive);
    if (mounted) setState(() {});
  }
}

/// 列表里的一行
class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.balanceCents,
    required this.onEdit,
    required this.onToggleActive,
  });

  final Account account;
  final int balanceCents;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      // ⚠️ 测试用 Key 定位行 —— 账户名文字会与下拉选中项等重复（歧义）
      key: Key('account-row-${account.id}'),
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        account.name,
                        style: TextStyle(
                          height: 1.6,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: account.isActive
                              ? theme.colorScheme.onSurface
                              : theme.hintColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        kAccountTypeLabels[account.type] ?? account.type.wire,
                        style: TextStyle(
                          height: 1.6,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                      if (!account.isActive)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            '已停用',
                            style: TextStyle(
                              height: 1.6,
                              color: theme.hintColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                  Text(
                    account.isActive
                        ? '期初 ¥${Money.format(account.initialBalance)}'
                        : '停用的账户不参与开单，可随时恢复',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '¥ ${Money.formatGrouped(balanceCents)}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '更多操作',
              onSelected: (String action) {
                if (action == 'edit') {
                  onEdit();
                } else if (action == 'toggle') {
                  onToggleActive();
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'edit',
                  child: Text('编辑'),
                ),
                PopupMenuItem<String>(
                  value: 'toggle',
                  child: Text(account.isActive ? '停用' : '恢复启用'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 新建 / 编辑对话框
class _AccountFormDialog extends StatefulWidget {
  const _AccountFormDialog({required this.service, this.existing});

  final AccountService service;
  final Account? existing;

  @override
  State<_AccountFormDialog> createState() => _AccountFormDialogState();
}

class _AccountFormDialogState extends State<_AccountFormDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  /// 账户类型：**可变**（下拉要改它），回填挪到 `initState` ——
  /// 字段初始化器里不能读 `widget`，而 `late final` 又挡住了 `onChanged` 写入；
  /// 「initState 里读 widget」是标准解法，两个约束都满足。
  AccountType? _type;

  /// 编辑路径上的期初余额原文（**只读展示**，Z-3 方案 A）
  late final String _initialBalanceReadOnly =
      widget.existing == null ? '' : Money.format(widget.existing!.initialBalance);

  Map<AccountField, String>? _errors;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _type = widget.existing?.type;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final AccountDraft draft = AccountDraft(
      name: _name.text,
      type: _type,
      // 编辑路径上服务层会忽略这个值（以库里原值为准）；新建时对话框里另有输入框
      initialBalance: widget.existing == null
          ? _initialBalanceController.text
          : '',
    );
    try {
      final Account saved = widget.existing == null
          ? widget.service.create(draft)
          : widget.service.update(widget.existing!.id, draft);
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } on AccountDraftInvalid catch (error) {
      if (!mounted) return;
      setState(() {
        _errors = error.fieldErrors;
        _saving = false;
      });
    }
  }

  /// 期初余额输入（**只在新建时出现**）
  late final TextEditingController _initialBalanceController =
      TextEditingController();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? '编辑账户' : '新建账户'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              key: const Key('account-name'),
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: '账户名称 *',
                hintText: '比如「现金」或「微信收款」',
                errorText: _errors?[AccountField.name],
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<AccountType>(
              key: const Key('account-type'),
              initialValue: _type,
              items: <DropdownMenuItem<AccountType>>[
                for (final AccountType type in AccountType.values)
                  DropdownMenuItem<AccountType>(
                    value: type,
                    child: Text(
                      kAccountTypeLabels[type] ?? type.wire,
                      style: const TextStyle(height: 1.6),
                    ),
                  ),
              ],
              onChanged: (AccountType? value) => setState(() => _type = value),
              decoration: InputDecoration(
                labelText: '账户类型 *',
                errorText: _errors?[AccountField.type],
              ),
            ),
            const SizedBox(height: 12),
            if (isEditing)
              // Z-3 方案 A：编辑时只读 + 说清「怎么办」
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '期初余额：¥ $_initialBalanceReadOnly（建账后不可改）',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                  Text(
                    '改期初会重算全部历史余额。真填错了：新建一个账户，'
                    '再停用这个。',
                    style: TextStyle(
                      height: 1.6,
                      color: const Color(0xFFB45309),
                    ),
                  ),
                ],
              )
            else
              TextField(
                key: const Key('account-initial'),
                controller: _initialBalanceController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: '期初余额（元，可空）',
                  helperText: '建这个账户时手头已有多少钱',
                  errorText: _errors?[AccountField.initialBalance],
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(isEditing ? '保存' : '创建'),
        ),
      ],
    );
  }
}
