/// 往来方页：列表（应收 / 应付 / 已结清）+ 汇总 + 完整新建 / 编辑 / 停用 + 流水。
///
/// ## 裁定落点（`docs/reply_review.md` §AA）
///
/// - **AA-5**：按 \|余额\| 降序、**精确 0** 沉底（1 分欠款和没欠款是两回事）
/// - **遗漏 2**：余额用**文字 + 颜色 + 绝对值**三重表达 —— 「应收 ¥5,000」（不用负号）
/// - **遗漏 3**：顶部**总应收 / 总应付**汇总行
/// - **遗漏 1**：完整新建 + 编辑（名称 / 电话 / 地址 / **角色**）+ 停用
///   （不影响历史流水）
/// - **§审查 OBS-05 后半**：角色**可随时编辑**（不再需要「停用 + 重建」——
///   那会造出第二条同名把往来账分流）；停用前若还有余额会**二次确认**；
///   **停用但余额 ≠ 0 的往来方仍然显示**（否则那笔应收 / 应付会变成看不见的
///   「幽灵账」，用户催款时漏掉、永远对不上）
/// - **AA-6 / 遗漏 6**：点行进流水页（`ofParty` JOIN 单号）；流水行不可点，
///   底部灰字说明「单据详情开发中」
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'export_button.dart';
import 'mobile_guidance_dialog.dart';
import 'party_flow_page.dart';

/// 往来方页。
class PartiesPage extends StatefulWidget {
  const PartiesPage({
    super.key,
    required this.service,
    this.exports,
    this.readOnlyMasterData = false,
  });

  final PartyService service;

  /// 导出服务（`null` = 不显示导出按钮；同时透传给流水页）
  final ExportSink? exports;

  /// 手机端**主数据禁建**（C2·§CC）：`true` 时「新建 / 编辑 / 停用」入口
  /// **保留但点击后弹引导对话框**（不隐藏 —— Agents.md 4.3）。
  /// 停用/启用同为主数据写（`updateMasterData`），一并引导。
  /// 桌面缺省 `false` = 现状零变化。
  final bool readOnlyMasterData;

  @override
  State<PartiesPage> createState() => _PartiesPageState();
}

class _PartiesPageState extends State<PartiesPage> {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // §审查 OBS-05 后半：**停用但余额 ≠ 0 的也要显示** —— 停用只是
    //「不再出现在开单选择器里」，不是从账上消失（口径见 `listVisible`）
    final List<Party> parties = widget.service.listVisible();
    final Map<String, int> balances = widget.service.partyBalances();

    // AA-5：按 |余额| 降序，精确 0 沉底
    final List<Party> sorted = parties.toList()
      ..sort((Party a, Party b) {
        final int ba = (balances[a.id] ?? 0).abs();
        final int bb = (balances[b.id] ?? 0).abs();
        return bb.compareTo(ba);
      });

    // 遗漏 3：总应收 / 总应付
    int totalReceivable = 0;
    int totalPayable = 0;
    for (final Party party in parties) {
      final int balance = balances[party.id] ?? 0;
      if (balance > 0) {
        totalReceivable += balance;
      } else if (balance < 0) {
        totalPayable += -balance;
      }
    }

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
                  Text('往来方', style: theme.textTheme.titleLarge),
                  if (widget.exports != null)
                    ExportButton(
                      key: const Key('export-parties'),
                      // AF-2：全量（**含停用** —— 停用但还欠钱的客户不能少）
                      label: '导出往来方',
                      export: () => widget.exports!.write(
                        partyExportTable(
                          parties: widget.service.listForExport(),
                          balances: balances,
                        ),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: () => _editParty(context),
                    icon: const Icon(Icons.add),
                    label: const Text('新建往来方'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 遗漏 3：总应收 / 总应付 —— 一打开就能看到全貌
              Card(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '总应收 ¥${Money.formatGrouped(totalReceivable)}',
                          style: TextStyle(
                            height: 1.6,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '总应付 ¥${Money.formatGrouped(totalPayable)}',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            height: 1.6,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '点一个往来方看流水。正数是对方欠你（应收），负数是你欠对方（应付）。'
                '停用过的往来方，只要还有账没结清，也会留在这张表里提醒你。',
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              const SizedBox(height: 8),
              if (sorted.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    widget.readOnlyMasterData
                        ? mirrorEmptyMessage('往来方列表')
                        : '还没有往来方。开单时选客户/供应商会自动建，'
                        '也可以点右上角「新建往来方」。',
                    textAlign: TextAlign.center,
                    style: TextStyle(height: 1.8, color: theme.hintColor),
                  ),
                )
              else
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < sorted.length; i++) ...<Widget>[
                        if (i > 0) const Divider(height: 1),
                        _PartyRow(
                          key: Key('party-row-${sorted[i].id}'),
                          party: sorted[i],
                          balanceCents: balances[sorted[i].id] ?? 0,
                          onOpen: () => _openFlow(context, sorted[i]),
                          onEdit: () => _editParty(context, existing: sorted[i]),
                          onToggleActive: () => _toggleActive(sorted[i]),
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

  /// 打开某往来方的流水页
  Future<void> _openFlow(BuildContext context, Party party) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PartyFlowPage(
          party: party,
          service: widget.service,
          exports: widget.exports,
        ),
      ),
    );
    if (mounted) setState(() {}); // 返回后余额可能已变，防御性刷新
  }

  /// 停用 / 恢复（§审查 OBS-05 后半）。
  ///
  /// **停用前先看余额**：还有没结清的账时二次确认。为什么必须有这一步 ——
  /// 停用后该往来方不再出现在开单选择器里，但余额仍在账上；用户以为
  /// 「停用 = 结清了」，那笔应收就会在催款时被漏掉。
  Future<void> _toggleActive(Party party) async {
    // C2·§CC：停用/启用同为主数据写（updateMasterData）—— 一并引导
    if (widget.readOnlyMasterData) {
      await showMobileGuideDialog(context, MobileGuideTopic.editParty);
      return;
    }
    if (party.isActive) {
      final int balance = widget.service.balanceOf(party.id);
      if (balance != 0) {
        final bool? sure = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: const Text('这个往来方还有没结清的账'),
            content: Text(
              '${party.name} 现在还有'
              '${balance > 0 ? '应收' : '应付'} '
              '¥${Money.formatGrouped(balance.abs())} 没结清。\n\n'
              '停用后他不会再出现在开单的客户 / 供应商选择器里；'
              '但因为还欠着钱，往来方页上仍然会显示他（标着「已停用」），'
              '想接着和他做生意，点「恢复启用」就行。',
              style: const TextStyle(height: 1.8),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('还是停用'),
              ),
            ],
          ),
        );
        if (sure != true || !mounted) return;
      }
    }
    widget.service.setActive(party.id, active: !party.isActive);
    if (mounted) setState(() {});
  }

  /// 新建（[existing] 为 null）或编辑。
  /// C2·§CC：手机端主数据禁建 —— 入口保留，点击后弹引导（不进表单）。
  Future<void> _editParty(BuildContext context, {Party? existing}) async {
    if (widget.readOnlyMasterData) {
      await showMobileGuideDialog(
        context,
        existing == null ? MobileGuideTopic.newParty : MobileGuideTopic.editParty,
      );
      return;
    }
    final bool? changed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _PartyFormDialog(service: widget.service, existing: existing),
    );
    if (changed != true) return;
    if (!mounted) return;
    setState(() {});
  }
}

/// 列表里的一行
class _PartyRow extends StatelessWidget {
  const _PartyRow({
    super.key,
    required this.party,
    required this.balanceCents,
    required this.onOpen,
    required this.onEdit,
    required this.onToggleActive,
  });

  final Party party;
  final int balanceCents;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // 遗漏 2：文字 + 颜色 + 绝对值 三重表达，不用负号
    final String roleLabels = party.roles
        .map(
          (PartyRole role) => switch (role) {
            PartyRole.supplier => '供应商',
            PartyRole.customer => '客户',
            PartyRole.carrier => '承运',
          },
        )
        .join(' / ');
    final String balanceText;
    final Color balanceColor;
    if (balanceCents > 0) {
      balanceText = '应收 ¥${Money.formatGrouped(balanceCents)}';
      balanceColor = theme.colorScheme.onSurface;
    } else if (balanceCents < 0) {
      balanceText = '应付 ¥${Money.formatGrouped(-balanceCents)}';
      balanceColor = theme.colorScheme.error;
    } else {
      balanceText = '已结清';
      balanceColor = theme.hintColor;
    }

    return InkWell(
      // §审查 OBS-05 后半：停用的也能点开看流水 —— 它出现在列表里，
      // 正是因为「还有账没结清」，那就得让人查得到那笔账
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // C3·真机反馈：名字与角色标签同行时，标签把名字挤到强制折行
                  // —— 名字独占一行，标签 / 停用标记下移（任何缩放档不折名字）
                  Text(
                    party.name,
                    style: TextStyle(
                      height: 1.6,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: party.isActive
                          ? theme.colorScheme.onSurface
                          : theme.hintColor,
                    ),
                  ),
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          roleLabels,
                          style: TextStyle(
                            height: 1.6,
                            color: theme.textTheme.bodySmall?.color,
                          ),
                        ),
                      ),
                      if (!party.isActive)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          // §审查 OBS-05 后半：停用**且有余额**要显眼 ——
                          // 它出现在列表里的唯一理由就是「这笔账还没结清」，
                          // 不能和「干干净净停用掉的」长得一样
                          child: Text(
                            balanceCents != 0 ? '已停用 · 账未结清' : '已停用',
                            style: TextStyle(
                              height: 1.6,
                              fontWeight: balanceCents != 0
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: balanceCents != 0
                                  ? theme.colorScheme.error
                                  : theme.hintColor,
                            ),
                          ),
                        ),
                    ],
                  ),
                  Text(
                    party.phone ?? '',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              balanceText,
              style: TextStyle(
                height: 1.6,
                fontWeight: FontWeight.w700,
                color: balanceColor,
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
                  child: Text('编辑资料'),
                ),
                PopupMenuItem<String>(
                  value: 'toggle',
                  child: Text(party.isActive ? '停用' : '恢复启用'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 新建 / 编辑对话框。新建时**至少要选一个角色**；**编辑也能改角色**
/// （§审查 OBS-05 后半：角色只是属性，不参与任何流水计算，随时可改 ——
/// 这正是「想给老王加供应商角色」的正路，不必再「停用 + 重建」）。
/// 编辑时若把角色全部取消，保存后会提示「不会出现在开单选择器里」。
class _PartyFormDialog extends StatefulWidget {
  const _PartyFormDialog({required this.service, this.existing});

  final PartyService service;
  final Party? existing;

  @override
  State<_PartyFormDialog> createState() => _PartyFormDialogState();
}

class _PartyFormDialogState extends State<_PartyFormDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _phone =
      TextEditingController(text: widget.existing?.phone ?? '');
  late final TextEditingController _address =
      TextEditingController(text: widget.existing?.address ?? '');
  // ⚠️ 初始化器里不能读 `widget`（implicit_this_reference_in_initializer）；
  // 后续要 add/remove，也不能 final —— 回填挪到 initState
  Set<PartyRole> _roles = <PartyRole>{};
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _roles = <PartyRole>{...?widget.existing?.roles};
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    // 新建时必须选角色；编辑允许清空（下面有「不会出现在开单选择器」的提示）
    if (widget.existing == null && _roles.isEmpty) {
      setState(() => _error = '至少要选一个角色（供应商 / 客户）');
      return;
    }
    setState(() => _saving = true);
    try {
      if (widget.existing == null) {
        widget.service.createFull(
          name: _name.text,
          roles: _roles.toList(),
          phone: _phone.text,
          address: _address.text,
        );
      } else {
        widget.service.updateProfile(
          widget.existing!.id,
          name: _name.text,
          // §审查 OBS-05 后半：编辑**连角色一起保存**（`_roles` 由现有角色
          // 起步，只被两个开关增删 ⇒ 不认识的旧角色不会被静默丢掉）
          roles: _roles.toList(),
          phone: _phone.text,
          address: _address.text,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on StateError catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? '编辑往来方' : '新建往来方'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              key: const Key('party-name'),
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: '名称 *',
                hintText: '比如「王老板」',
                errorText: _error,
              ),
            ),
            const SizedBox(height: 8),
            // §审查 OBS-05 后半：**新建与编辑都能改角色** —— 原来编辑不给碰，
            // 用户想加一个角色只能「停用 + 重建」，而那会造出第二条同名
            // 把往来账分流。角色只是属性，不参与流水计算，随时可改。
            CheckboxListTile(
              key: const Key('party-role-supplier'),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('供应商（我从他进货）'),
              value: _roles.contains(PartyRole.supplier),
              onChanged: (bool? value) => setState(() {
                if (value ?? false) {
                  _roles.add(PartyRole.supplier);
                } else {
                  _roles.remove(PartyRole.supplier);
                }
              }),
            ),
            CheckboxListTile(
              key: const Key('party-role-customer'),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('客户（我卖给他）'),
              value: _roles.contains(PartyRole.customer),
              onChanged: (bool? value) => setState(() {
                if (value ?? false) {
                  _roles.add(PartyRole.customer);
                } else {
                  _roles.remove(PartyRole.customer);
                }
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _phone,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: '电话（可选）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _address,
              decoration: const InputDecoration(labelText: '地址（可选）'),
            ),
            if (isEditing && _roles.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '该往来方没有角色（不会出现在开单选择器里）。',
                  style: TextStyle(height: 1.6, color: const Color(0xFFB45309)),
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
