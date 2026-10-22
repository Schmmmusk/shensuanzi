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
    show ExportSink, MasterDataPolicy, MobileGuideTopic, mirrorEmptyMessage;
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'disable_action.dart';
import 'account_flow_page.dart';
import 'document_detail_page.dart';
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
    this.pendingMarks,
    this.exports,
    this.settlements,
    this.deliveries,
    this.products,
  });

  final AccountService service;

  /// **主机还没确认**的主数据行（D2b —— `data_model.md §4.4` 第 3 条）。
  /// `null` = 一律不显示「待同步」小字（桌面 / 测试默认）。
  final PendingMarks? pendingMarks;

  /// **主数据门控**（§CV·九·五 裁定「甲」，2026-10-09）—— 本页只看
  /// `canCreateAccounts`（新建 / 编辑 / 停用恢复三处写面，与往来页同构）。
  ///
  /// ⚠️ **required，不许给默认值**：本页原先是全项目**唯一没接门控**的页面
  /// （旧的 `bool readOnlyMasterData` 也从未传进来过）。而手机端的
  /// `AccountService` 建在**镜像**上 —— 写进去永远到不了电脑。
  /// 带默认值 = 忘了传就「手机上账户能建」且**看不出来**（M15 教训）⇒ 宁可编不过。
  final MasterDataPolicy masterDataPolicy;

  /// **#27（2026-10-17 批 1）**：导出服务（`null` = 流水页不显示导出按钮）
  final ExportSink? exports;

  /// **#27**：流水行跳单据详情所需的服务（照 DocumentsPage 的传法）。
  /// `settlements` 为 `null` ⇒ 流水行不可点（底部灰字明说）。
  final SettlementService? settlements;
  final DeliveryService? deliveries;
  final ProductService? products;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  /// #40②（2026-10-18 裁定甲）：勾上 ⇒ **所有**停用账户都列（含余额为 0 的）。
  ///
  /// 默认 `false` 也**已经包含「停用但还有钱」的账户**（`listVisible` 的口径）——
  /// 钱不会因为停用消失，藏起来就是「幽灵账」。
  bool _showInactiveWithoutBalance = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Account> accounts = widget.service.listVisible(
      includeInactiveWithoutBalance: _showInactiveWithoutBalance,
    );
    final Map<String, int> balances = widget.service.balances();
    // ⚠️ 一次 build 取一次快照，再逐行 contains —— `ids` 每次访问都查库
    final Set<String> pending = widget.pendingMarks?.ids ?? const <String>{};

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
              const SizedBox(height: 4),
              // #40②：照抄商品页（Checkbox + 文字标签）
              Row(
                children: <Widget>[
                  Checkbox(
                    key: const Key('accounts-show-inactive'),
                    value: _showInactiveWithoutBalance,
                    onChanged: (bool? value) => setState(
                      () => _showInactiveWithoutBalance = value ?? false,
                    ),
                  ),
                  const Text('显示已停用的账户'),
                ],
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
                          isPending: pending.contains(accounts[i].id),
                          balanceCents: balances[accounts[i].id] ?? 0,
                          onOpenFlow: () =>
                              _openAccountFlow(context, accounts[i]),
                          onEdit: () =>
                              _editAccount(context, existing: accounts[i]),
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
    final bool wasActive = account.isActive;
    // §CV·八十三（报告 §2.2 漂移 4）：原来账户**既不确认也不撤销** ——
    // 哪怕里面有几千块也能一键停用、且没有退路。现在与往来方同一套：
    // 有余额先确认，余额为 0 直接执行 + 撤销。
    if (wasActive) {
      final int balance = widget.service.balances()[account.id] ?? 0;
      final bool go = await confirmDisableWithBalance(
        context,
        name: account.name,
        subject: '账户',
        title: '这个账户里还有钱',
        balanceCents: balance,
        balanceLabel: balance > 0 ? '余额' : '欠款',
      );
      if (!go || !mounted) return;
    }

    void write(bool active) {
      widget.service.setActive(account.id, active: active);
      if (mounted) setState(() {});
    }

    write(!wasActive);
    if (!mounted) return;
    showDisableUndoBar(
      context,
      message: wasActive ? '已停用「${account.name}」' : '已恢复「${account.name}」',
      onUndo: () {
        if (!mounted) return;
        write(wasActive);
      },
    );
  }

  /// **#27（2026-10-17 批 1）**：打开某账户的流水页（照往来页 `_openFlow` 先例）。
  ///
  /// 同构依据（§CV·五十一③）：parties 行 tap = 流水（OBS-05「查得到那笔账」），
  /// 账户行照此对齐 —— 编辑/停用本就收在行尾「更多操作」菜单里，不抢 tap。
  Future<void> _openAccountFlow(BuildContext context, Account account) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => AccountFlowPage(
          account: account,
          service: widget.service,
          exports: widget.exports,
          // 桌面行可点 ⇒ 跳单据详情（settlements 缺省时流水页自己降级为不可点）
          onOpenDocument: widget.settlements == null
              ? null
              : (BuildContext context, String documentId) async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => DocumentDetailPage(
                        documentId: documentId,
                        settlements: widget.settlements!,
                        deliveries: widget.deliveries,
                        products: widget.products,
                      ),
                    ),
                  );
                  if (mounted) setState(() {}); // 详情里可能核销过，回来刷新余额
                },
        ),
      ),
    );
    if (mounted) setState(() {}); // 返回后余额可能已变，防御性刷新
  }
}

/// 列表里的一行
class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.isPending,
    required this.balanceCents,
    required this.onOpenFlow,
    required this.onEdit,
    required this.onToggleActive,
  });

  final Account account;

  /// 主机还没确认（乐观行）⇒ 名下列一行浅灰「待同步」
  final bool isPending;
  final int balanceCents;

  /// **#27**：行 tap = 打开流水（照 parties 行同构；编辑/停用在行尾菜单里）
  final VoidCallback onOpenFlow;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      // ⚠️ 测试用 Key 定位行 —— 账户名文字会与下拉选中项等重复（歧义）
      key: Key('account-row-${account.id}'),
      // #27（§CV·五十一③）：tap = 流水（与 parties 行同构 —— 「点行查账」）；
      // 编辑/停用照旧行尾「更多操作」菜单。
      onTap: onOpenFlow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        // 2026-10-22（§CV·八十三）：行尾改成两个文字按钮后，**窄屏 + 超大档
        // 放不下一行**（实测 400 宽 / 2.0 溢出 82px）。断点**随字号放大**
        // （报告 §三·A2：`480 * scale`），窄了就换成两行：金额与按钮各占一行。
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final double scale = MediaQuery.textScalerOf(context).scale(1.0);
            final bool narrow = c.maxWidth < 480 * scale;
            final Widget info = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // ⚠️ **名字独占一行，类型标签下移**（2026-10-19 用户实测溢出）：
                  // 原来是 `Row[名字, 类型]` 且两个都不许收缩 —— 超大档（2.0）下
                  // 「微信收款账户 + 微信」比左侧列还宽 ⇒ 黄黑溢出条纹
                  // （截图：账户页，窗口与 VSCode 均分 960 宽）。
                  //
                  // 处置与**往来方行**（`parties_page.dart:378-380` 的 C3 裁定）
                  // 和**商品行**（`products_page.dart:257` 的 `Flexible + ellipsis`）
                  // 同一思路：名字不与标签抢宽，标签进第二行。
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
                  Text(
                    // 第二行 = 「类型 · 期初」/「类型 · 停用说明」——
                    // 单个 Text 会自然换行，**结构上不可能溢出**
                    '${kAccountTypeLabels[account.type] ?? account.type.wire} · '
                    '${account.isActive ? '期初 ¥${Money.format(account.initialBalance)}' : '停用的账户不参与开单，可随时恢复'}',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                  // 乐观行必须可分辨（`data_model.md §4.4` 第 3 条）
                  if (isPending) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      '待同步',
                      key: Key('pending-account-${account.id}'),
                      style: TextStyle(height: 1.6, color: theme.hintColor),
                    ),
                  ],
                ],
              );
            final Widget amount = Text(
              '¥ ${Money.formatGrouped(balanceCents)}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            );
            // 2026-10-22（§CV·八十三 批 2 第 9 条）：`⋮` → 文字按钮（同往来方）
            final List<Widget> actions = <Widget>[
              TextButton(
                key: Key('account-edit-${account.id}'),
                onPressed: onEdit,
                child: const Text('编辑'),
              ),
              TextButton(
                key: Key('account-toggle-${account.id}'),
                onPressed: onToggleActive,
                child: Text(account.isActive ? '停用' : '恢复'),
              ),
            ];
            if (!narrow) {
              return Row(
                children: <Widget>[Expanded(child: info), amount, ...actions],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(children: <Widget>[Expanded(child: info), amount]),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(children: actions),
                ),
              ],
            );
          },
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
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );

  /// 账户类型：**可变**（下拉要改它），回填挪到 `initState` ——
  /// 字段初始化器里不能读 `widget`，而 `late final` 又挡住了 `onChanged` 写入；
  /// 「initState 里读 widget」是标准解法，两个约束都满足。
  AccountType? _type;

  /// 编辑路径上的期初余额原文（**只读展示**，Z-3 方案 A）
  late final String _initialBalanceReadOnly = widget.existing == null
      ? ''
      : Money.format(widget.existing!.initialBalance);

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
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
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
