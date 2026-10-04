/// 往来方页：列表（应收 / 应付 / 已结清）+ 汇总 + 完整新建 / 编辑 / 停用 + 流水。
///
/// ## 裁定落点（`docs/reply_review.md` §AA）
///
/// - **AA-5**：按 \|余额\| 降序、**精确 0** 沉底（1 分欠款和没欠款是两回事）
/// - **遗漏 2**：余额用**文字 + 颜色 + 绝对值**三重表达 —— 「应收 ¥5,000」（不用负号）
/// - **遗漏 3**：顶部**总应收 / 总应付**汇总行
/// - **遗漏 1**：完整新建（角色在新建时定，编辑**不改角色**属 v1.1）+
///   行内编辑（只改名称/电话/地址）+ 停用（不影响历史流水）
/// - **AA-6 / 遗漏 6**：点行进流水页（`ofParty` JOIN 单号）；流水行不可点，
///   底部灰字说明「单据详情开发中」
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'export_button.dart';
import 'party_flow_page.dart';

/// 往来方页。
class PartiesPage extends StatefulWidget {
  const PartiesPage({super.key, required this.service, this.exports});

  final PartyService service;

  /// 导出服务（`null` = 不显示导出按钮；同时透传给流水页）
  final ExportSink? exports;

  @override
  State<PartiesPage> createState() => _PartiesPageState();
}

class _PartiesPageState extends State<PartiesPage> {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Party> parties = widget.service.list();
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
                '点一个往来方看流水。正数是对方欠你（应收），负数是你欠对方（应付）。',
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
                    '还没有往来方。开单时选客户/供应商会自动建，'
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
                          onToggleActive: () {
                            widget.service.setActive(
                              sorted[i].id,
                              active: !sorted[i].isActive,
                            );
                            setState(() {});
                          },
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

  /// 新建（[existing] 为 null）或编辑
  Future<void> _editParty(BuildContext context, {Party? existing}) async {
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
      onTap: party.isActive ? onOpen : null,
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
                      Flexible(
                        child: Text(
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
                      ),
                      const SizedBox(width: 8),
                      Text(
                        roleLabels,
                        style: TextStyle(
                          height: 1.6,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                      if (!party.isActive)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            '已停用',
                            style: TextStyle(height: 1.6, color: theme.hintColor),
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

/// 新建 / 编辑对话框。新建时选角色（至少一个）；**编辑只改资料不改角色**（v1.1）。
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
    // 新建时必须选角色；编辑不改角色，空角色允许保存（提示了「不会出现在开单选择器」）
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
            if (!isEditing) ...<Widget>[
              const SizedBox(height: 8),
              // 新建时定角色；编辑不改角色（v1.1）
              CheckboxListTile(
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
            ],
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
