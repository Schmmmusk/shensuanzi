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
import 'app_colors.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'scaled.dart';

import 'disable_action.dart';
import 'list_scaffold.dart';
import 'export_button.dart';
import 'mobile_guidance_dialog.dart';
import 'party_flow_page.dart';
import 'notice.dart';

/// 往来方页。
class PartiesPage extends StatefulWidget {
  const PartiesPage({
    super.key,
    required this.service,
    this.exports,
    required this.masterDataPolicy,
    this.pendingMarks,
    this.partySink,
    this.mobileShell = false,
  });

  final PartyService service;

  /// **主机还没确认**的主数据行（D2b —— `data_model.md §4.4` 第 3 条）。
  /// `null` = 一律不显示「待同步」小字（桌面 / 测试默认）。
  final PendingMarks? pendingMarks;

  /// 导出服务（`null` = 不显示导出按钮；同时透传给流水页）
  final ExportSink? exports;

  /// **主数据门控**（§CV·七 ① 乙，2026-10-09）—— 本页只看 `canCreateParties`：
  /// `false` 时「新建 / 编辑 / 停用」入口**保留但点击后弹引导**（不隐藏 —— Agents.md 4.3。
  /// 停用/启用同为主数据写 `updateMasterData`，一并引导）。
  ///
  /// ⚠️ **required**：缺省 `false` 那版默默漏装就是「手机上能建往来」——
  /// 而手机端的 `PartyService` 建在**镜像**上，写进去永远到不了电脑（静默丢数据）。
  final MasterDataPolicy masterDataPolicy;

  /// **往来方写入口的队列出口**（2026-10-20 放开手机往来方，§CV·七十七）。
  ///
  /// 手机 = `QueuePartySink`（写镜像 + 入队 + 立即推）；桌面 / 未装配 = `null`
  /// ⇒ 所有写走 [service]（`PartyService` 直连主库）—— **桌面零变化**。
  /// ⚠️ 三者（新建 / 编辑 / 停用）**必须同进同退**：只放新建会留下
  /// 「编辑只写镜像、不到电脑」的半身（手机 `service` 建在镜像上）。
  final QueuePartySink? partySink;

  /// 手机壳？（与 `StockPage` / `OverviewPage` 同一个壳级事实。）
  /// 只为「门控开了但出口没装」的守卫用 —— 见 `_PartiesPageState._canWriteParties`。
  final bool mobileShell;

  @override
  State<PartiesPage> createState() => _PartiesPageState();
}

class _PartiesPageState extends State<PartiesPage> {
  /// **能不能在本机写往来方**：门控放开 **且** 出口齐备。
  ///
  /// ⚠️ 为什么多判一个出口：手机上的 `widget.service`（`PartyService`）
  /// 建在**镜像**上，直接写会「只进镜像、不到电脑」—— 静默丢数据。
  /// 桌面没有这个问题（`service` 直连主库）⇒ 只在**手机壳**上要求出口非空。
  bool get _canWriteParties =>
      widget.masterDataPolicy.canCreateParties &&
      (!widget.mobileShell || widget.partySink != null);

  /// #40②（2026-10-18 裁定甲）：勾上 ⇒ 连「停用且不欠钱」的也列出来。
  ///
  /// 默认 `false`：**停用但还有余额的本来就显示**（OBS-05 幽灵账防线），
  /// 这个开关只决定「不欠钱的停用档要不要也占屏幕」。
  bool _showInactiveWithoutBalance = false;

  /// 列表搜索（批 3 第 16 条：往来方页原先**完全没有**搜索）
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // ⚠️ 一次 build 取一次快照，再逐行 contains —— `ids` 每次访问都查库
    final Set<String> pending = widget.pendingMarks?.ids ?? const <String>{};
    // §审查 OBS-05 后半：**停用但余额 ≠ 0 的也要显示** —— 停用只是
    //「不再出现在开单选择器里」，不是从账上消失（口径见 `listVisible`）
    final List<Party> parties = widget.service.listVisible(
      includeInactiveWithoutBalance: _showInactiveWithoutBalance,
    );
    final Map<String, int> balances = widget.service.partyBalances();

    // AA-5：按 |余额| 降序，精确 0 沉底
    final List<Party> sorted = parties.toList()
      ..sort((Party a, Party b) {
        final int ba = (balances[a.id] ?? 0).abs();
        final int bb = (balances[b.id] ?? 0).abs();
        return bb.compareTo(ba);
      });

    // 搜索：按姓名 / 电话包含（往来方数量有限，在已取回的列表上过一遍）
    final List<Party> visible = _query.isEmpty
        ? sorted
        : sorted
              .where(
                (Party p) =>
                    p.name.contains(_query) || (p.phone ?? '').contains(_query),
              )
              .toList(growable: false);

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
              // 批 3 第 16 条：常驻搜索 + 计数（原来往来方页没有搜索）
              ListHeader(
                searchKey: const Key('parties-search'),
                controller: _search,
                hintText: '搜姓名 / 电话',
                onQueryChanged: (String q) => setState(() => _query = q.trim()),
                countText: _query.isEmpty
                    ? '共 ${visible.length} 个'
                    : '找到 ${visible.length} 个',
              ),
              const SizedBox(height: 4),
              // #40②：照抄商品页的形态（Checkbox + **文字标签**，中老年不看纯图标）
              Row(
                children: <Widget>[
                  Checkbox(
                    key: const Key('parties-show-inactive'),
                    value: _showInactiveWithoutBalance,
                    onChanged: (bool? value) => setState(
                      () => _showInactiveWithoutBalance = value ?? false,
                    ),
                  ),
                  // 措辞按 `docs/reply.md` 2026-10-18 的建议
                  const Text('显示全部（含无欠款的停用档）'),
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
              if (visible.isEmpty && _query.isNotEmpty)
                ListEmptyState(
                  icon: Icons.search_off,
                  title: '没有叫「$_query」的往来方',
                  hint: '换个词试试，或点搜索框右边的 × 清空，看全部往来方。',
                  actionLabel: '清空搜索',
                  onAction: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                )
              else if (sorted.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    !widget.masterDataPolicy.canCreateParties
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
                      for (int i = 0; i < visible.length; i++) ...<Widget>[
                        if (i > 0) const Divider(height: 1),
                        _PartyRow(
                          key: Key('party-row-${visible[i].id}'),
                          party: visible[i],
                          isPending: pending.contains(visible[i].id),
                          balanceCents: balances[visible[i].id] ?? 0,
                          onOpen: () => _openFlow(context, visible[i]),
                          onEdit: () =>
                              _editParty(context, existing: visible[i]),
                          onToggleActive: () => _toggleActive(visible[i]),
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
    // 停用/启用同为主数据写（updateMasterData）—— 不能写就一并引导
    if (!_canWriteParties) {
      await showMobileGuideDialog(context, MobileGuideTopic.editParty);
      return;
    }
    final bool wasActive = party.isActive;
    // §CV·八十三：有余额才确认，否则直接执行 + 撤销（三页同一套）
    if (wasActive) {
      final int balance = widget.service.balanceOf(party.id);
      final bool go = await confirmDisableWithBalance(
        context,
        name: party.name,
        subject: '往来方',
        title: '这个往来方还有没结清的账',
        balanceCents: balance,
        balanceLabel: balance > 0 ? '应收' : '应付',
      );
      if (!go || !mounted) return;
    }

    void write(bool active) {
      final QueuePartySink? sink = widget.partySink;
      if (sink == null) {
        widget.service.setActive(party.id, active: active);
      } else {
        // 手机：写镜像 + 入队 + 立即推（与「开单后」同一触发路径）
        sink.setActive(party.id, active: active);
      }
      if (mounted) setState(() {});
    }

    write(!wasActive);
    if (!mounted) return;
    showDisableUndoBar(
      context,
      message: wasActive ? '已停用「${party.name}」' : '已恢复「${party.name}」',
      onUndo: () {
        if (!mounted) return;
        write(wasActive);
      },
    );
  }

  /// 新建（[existing] 为 null）或编辑。
  /// 本机不能建 ⇒ 入口保留，点击后弹引导（不进表单）。
  Future<void> _editParty(BuildContext context, {Party? existing}) async {
    if (!_canWriteParties) {
      await showMobileGuideDialog(
        context,
        existing == null
            ? MobileGuideTopic.newParty
            : MobileGuideTopic.editParty,
      );
      return;
    }
    // #40①：新建时返回 `PartyMutation`（编辑返回 `null`）—— 页面要说出
    // 「新建了 / 追加了身份 / 复活了停用档」；以前只回 bool，这些信息全丢了
    final PartyMutation? mutation = await showDialog<PartyMutation>(
      context: context,
      builder: (BuildContext dialogContext) => _PartyFormDialog(
        service: widget.service,
        existing: existing,
        sink: widget.partySink,
      ),
    );
    if (mutation == null) return;
    // `context.mounted`（不是 `mounted`）：analyze 要求与 `context` 绑定的守卫
    if (!context.mounted) return;
    final String? notice = partyMutationNotice(mutation);
    if (notice != null) {
      showSnack(
        context,
        SnackBar(content: Text(notice), duration: const Duration(seconds: 4)),
      );
    }
    setState(() {});
  }
}

/// 列表里的一行
class _PartyRow extends StatelessWidget {
  const _PartyRow({
    super.key,
    required this.party,
    required this.isPending,
    required this.balanceCents,
    required this.onOpen,
    required this.onEdit,
    required this.onToggleActive,
  });

  final Party party;

  /// 主机还没确认（乐观行）⇒ 名下列一行浅灰「待同步」
  final bool isPending;
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
            // 术语统一（§CV·八十 Q3 / 附录 A）：词汇表与导出 CSV 都是「司机」
            PartyRole.carrier => '司机',
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
        // 2026-10-22（§CV·八十三）：行尾两个文字按钮在**窄屏 + 超大档**放不下
        // （实测 280 宽 / 2.0 溢出），断点随字号放大，窄了换两行。
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final bool narrow = isNarrowOf(context, c.maxWidth);
            final Widget info = Column(
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
                // ⚠️ **角色独占一行**（2026-10-19 用户实测溢出）：
                // 原来是 `Row[Flexible(角色), 已停用标签]` —— 超大档（2.0）下
                // 左侧列只有 ~200px，`Flexible` 把「客户 / 供应商」压到
                // **一个字一行竖排**（截图：往来方页「鸿磐」那行），
                // 非弹性的标签再把整行撑爆（黄黑条纹）。
                //
                // 处置：角色单独一行（`maxLines: 1` + 省略），停用标记**下移
                // 到第三行** —— 与账户页/商品页同一思路（标签不与主字段抢宽）。
                Text(
                  roleLabels,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
                if (!party.isActive)
                  // §审查 OBS-05 后半：停用**且有余额**要显眼 ——
                  // 它出现在列表里的唯一理由就是「这笔账还没结清」，
                  // 不能和「干干净净停用掉的」长得一样
                  Text(
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
                Text(
                  party.phone ?? '',
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
                    key: Key('pending-party-${party.id}'),
                    style: TextStyle(height: 1.6, color: theme.hintColor),
                  ),
                ],
              ],
            );
            final Widget balance = Text(
              balanceText,
              style: TextStyle(
                height: 1.6,
                fontWeight: FontWeight.w700,
                color: balanceColor,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            );
            // 2026-10-22（§CV·八十三 批 2 第 9 条 / 报告 §2.2 漂移 5）：
            // `⋮` → 两个**文字按钮**。`ui_principles.md` §1.1：悬停/点开才知道
            // 是什么 = 对目标用户不存在。商品页早就是文字按钮，这里对齐。
            final List<Widget> actions = <Widget>[
              TextButton(
                key: Key('party-edit-${party.id}'),
                onPressed: onEdit,
                child: const Text('编辑'),
              ),
              TextButton(
                key: Key('party-toggle-${party.id}'),
                onPressed: onToggleActive,
                // 术语统一（§CV·八十 Q3）：用「恢复」，不用「恢复启用」
                child: Text(party.isActive ? '停用' : '恢复'),
              ),
            ];
            if (!narrow) {
              return Row(
                children: <Widget>[
                  Expanded(child: info),
                  balance,
                  ...actions,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: info),
                    balance,
                  ],
                ),
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

/// 新建 / 编辑对话框。新建时**至少要选一个角色**；**编辑也能改角色**
/// （§审查 OBS-05 后半：角色只是属性，不参与任何流水计算，随时可改 ——
/// 这正是「想给老王加供应商角色」的正路，不必再「停用 + 重建」）。
/// 编辑时若把角色全部取消，保存后会提示「不会出现在开单选择器里」。
class _PartyFormDialog extends StatefulWidget {
  const _PartyFormDialog({required this.service, this.existing, this.sink});

  final PartyService service;

  /// 被编辑的行（`null` = 新建）
  final Party? existing;

  /// **手机队列出口**（`null` = 桌面 / 未装配 ⇒ 走 [service]）。
  ///
  /// 新建/编辑都改走它：手机上的 `service` 建在**镜像**上，直接写会「只进镜像、
  /// 不到电脑」——2026-10-20 放开手机往来方建档时补的（§CV·七十七）。
  final QueuePartySink? sink;

  @override
  State<_PartyFormDialog> createState() => _PartyFormDialogState();
}

class _PartyFormDialogState extends State<_PartyFormDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _phone = TextEditingController(
    text: widget.existing?.phone ?? '',
  );
  late final TextEditingController _address = TextEditingController(
    text: widget.existing?.address ?? '',
  );
  // ⚠️ 初始化器里不能读 `widget`（implicit_this_reference_in_initializer）；
  // 后续要 add/remove，也不能 final —— 回填挪到 initState
  Set<PartyRole> _roles = <PartyRole>{};
  String? _error;
  bool _saving = false;

  /// #40①：名称框**失焦**时查同名（不在 `onChanged` 查 —— 每键一次库 + setState）
  final FocusNode _nameFocus = FocusNode();
  String? _sameNameHint;

  @override
  void initState() {
    super.initState();
    _roles = <PartyRole>{...?widget.existing?.roles};
    _nameFocus.addListener(_onNameFocusChanged);
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _nameFocus.removeListener(_onNameFocusChanged);
    _nameFocus.dispose();
    super.dispose();
  }

  /// 名称框失焦 ⇒ 查同名并出内联提醒（#40①，不拦人）
  void _onNameFocusChanged() {
    if (_nameFocus.hasFocus) return;
    final String name = _name.text.trim();
    final Party? existing = name.isEmpty
        ? null
        : widget.service.findByNameIncludingInactive(name);
    final String? hint = partySameNameHint(existing, adding: _roles.toList());
    if (hint != _sameNameHint) setState(() => _sameNameHint = hint);
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
      final PartyMutation result;
      final QueuePartySink? sink = widget.sink;
      if (widget.existing == null) {
        result = sink == null
            ? widget.service.createFull(
                name: _name.text,
                roles: _roles.toList(),
                phone: _phone.text,
                address: _address.text,
              )
            : sink.createFull(
                name: _name.text,
                roles: _roles.toList(),
                phone: _phone.text,
                address: _address.text,
              );
      } else {
        final Party updated = (sink == null
            ? widget.service.updateProfile(
                widget.existing!.id,
                name: _name.text,
                // §审查 OBS-05 后半：编辑**连角色一起保存**（`_roles` 由现有角色
                // 起步，只被两个开关增删 ⇒ 不认识的旧角色不会被静默丢掉）
                roles: _roles.toList(),
                phone: _phone.text,
                address: _address.text,
              )
            : sink
                  .updateProfile(
                    widget.existing!.id,
                    name: _name.text,
                    roles: _roles.toList(),
                    phone: _phone.text,
                    address: _address.text,
                  )
                  .party);
        // 编辑 = 用户明确改了一条档，没有「复用 / 复活」要解释
        result = PartyMutation(
          party: updated,
          action: PartyMutationAction.existing,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(result);
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
              focusNode: _nameFocus,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: '名称 *',
                hintText: '比如「王老板」',
                errorText: _error,
              ),
            ),
            // #40① 内联提醒（不拦人）：说清「保存后会发生什么」
            if (_sameNameHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _sameNameHint!,
                  key: const Key('party-same-name-hint'),
                  style: const TextStyle(
                    height: 1.6,
                    color: AppColors.warningOrange,
                  ),
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
                  style: TextStyle(height: 1.6, color: AppColors.warningOrange),
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
