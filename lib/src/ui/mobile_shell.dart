/// 移动端壳（§AH-5 / §BH B1a）—— Android 的形态：底部导航 5 入口
/// （概览 / 开单 / 库存 / 往来 / 我的）。
///
/// ## 分工（铁律：两套壳不许各写一份装配）
///
/// 每个页面的构建（含服务的可空兜底）**只在 `appShellPage` 一处**
/// （`app_shell.dart`）——本文件只做「tab 切换 + 推整屏导航」的摆放。
/// [shell] 就是一个已配置好的 `AppShell` 参数对象：app.dart 组装一次，
/// 两套壳共享同一份依赖注入，`appShellPage` 按 id 取页面。
///
/// ## B1a 的刻意留白（§BH：B3 再细化）
///
/// - 「开单」tab 是**三个入口按钮**（销售 / 采购 / 送货），各自推整屏
///   现有页面 —— 复用桌面页在手机上可滚可用；提交走 `QueueSink`（B3b·§CA）。
/// - 推入的页面套一层 `Scaffold + AppBar`（带返回键）—— 桌面页自身
///   不带返回导航，直接推会「进去出不来」。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'app_shell.dart';
import 'local_db_banner.dart';
import 'notice.dart';
import 'price_lookup_page.dart';
import 'read_failure_banner.dart';

/// 底部导航的 5 个入口（§AH-5 裁定的入口名，不许增减改名）。
class _MobileTab {
  const _MobileTab(this.id, this.label, this.icon);

  /// 对应 `AppNavigation` 的 destination id（`billing`/`mine` 是本壳的
  /// 聚合 tab，没有单页对应，见 [_MobileShellState] 的分支）。
  final String id;
  final String label;
  final IconData icon;
}

const List<_MobileTab> _tabs = <_MobileTab>[
  _MobileTab('overview', '概览', Icons.home_outlined),
  _MobileTab('billing', '开单', Icons.point_of_sale_outlined),
  _MobileTab('stock', '库存', Icons.inventory_2_outlined),
  _MobileTab('parties', '往来', Icons.groups_outlined),
  _MobileTab('mine', '我的', Icons.person_outline),
];

class MobileShell extends StatefulWidget {
  const MobileShell({super.key, required this.shell});

  /// 已配置好的桌面壳参数对象 —— 页面装配共用一份（见文件头）。
  final AppShell shell;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  int _tab = 0;

  /// 把某个 destination 推成**整屏页**（带 AppBar 与返回键）。
  ///
  /// ⚠️ 三态条也挂在整屏页上 —— 用户是在**这里**开单的（裁定 ②：
  /// 保存后三态条要**立即**可见地更新），只在 tab 底下挂会看不见。
  void _openFull(NavDestination destination) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => Scaffold(
          appBar: AppBar(title: Text(destination.label)),
          body: Column(
            children: <Widget>[
              _SyncStatusBar(
                sync: widget.shell.mobileSync,
                version: widget.shell,
              ),
              Expanded(
                child: appShellPage(
                  widget.shell,
                  destination,
                  // #32：手机 = 推整屏（与「开单」tab 的入口同一通道）
                  onNavigate: (String id) {
                    final NavDestination? d = AppNavigation.byId(id);
                    if (d != null) _openFull(d);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「开单」tab：三个入口（B3 已接入 `QueueSink`：开单入队 → 自动推给电脑）。
  ///
  /// ## 降级只读（2026-10-31 用户裁定 A 第一阶段）
  ///
  /// `shell.readOnlyReason != null` 时三个入口**画成不可点**，并把原因写在上面。
  /// 为什么要在**这一层**画灰而不是只把 sink 置空：置空后页面会掉进
  /// `_PendingPage`（「销售开单：正在开发」）—— 那是在骗用户，看起来像功能没做。
  /// 真正的原因是「本机账本打不开」，必须原话说出来。
  Widget _billingTab(ThemeData theme) {
    final String? readOnly = widget.shell.readOnlyReason;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (readOnly != null) ...<Widget>[
          Card(
            color: theme.colorScheme.errorContainer,
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.lock_outline,
                    size: 20,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      readOnly,
                      style: TextStyle(
                        height: 1.6,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        for (final String id in <String>['sale', 'purchase', 'delivery'])
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              // 文字标签必须有（UI 基线），图标只作辅助
              title: Text(
                AppNavigation.byId(id)?.label ?? id,
                style: TextStyle(
                  height: 1.6,
                  fontSize: 18,
                  // 只读 ⇒ 明确「不可点」：颜色 + 无箭头，点了也不推页
                  color: readOnly == null
                      ? null
                      : theme.textTheme.bodySmall?.color,
                ),
              ),
              trailing: readOnly == null
                  ? const Icon(Icons.chevron_right)
                  : const Icon(Icons.lock_outline, size: 18),
              enabled: readOnly == null,
              onTap: readOnly != null
                  ? null
                  : () {
                      final NavDestination? destination = AppNavigation.byId(id);
                      if (destination != null) _openFull(destination);
                    },
            ),
          ),
        Text(
          readOnly != null
              ? '等本机账本的问题解决后（见顶部提示条里的「怎么办」），'
                    '这三个入口会自己恢复。现在先把单据记在纸上、或直接在电脑上开单。'
              // 2026-10-07 裁定（`docs/reply.md` §一）：自动补传 = 开单后 + **回前台**
              // + 手动按钮。**不许再承诺「联网自动补传」** —— 那是暗行为，
              // 而且（没有网络监听时）根本不成立（M02 报告的问题）。
              : '开单后会自动推送到电脑；断网时先记在待同步队列，'
                    '回到这个界面时再自动试一次，也可以点「立即同步」——'
                    '先到「我的 → 设置」扫码连接电脑。',
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
      ],
    );
  }

  /// 「我的」tab：设置 / 帮助 / 版本（§BH B1 待确认 1 的默认形态）。
  Widget _mineTab(ThemeData theme) => ListView(
    children: <Widget>[
      const SizedBox(height: 8),
      ListTile(
        leading: const Icon(Icons.settings_outlined),
        title: const Text('设置', style: TextStyle(height: 1.6)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          final NavDestination? destination = AppNavigation.byId('settings');
          if (destination != null) _openFull(destination);
        },
      ),
      ListTile(
        leading: const Icon(Icons.help_outline),
        title: const Text('帮助', style: TextStyle(height: 1.6)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          final NavDestination? destination = AppNavigation.byId('help');
          if (destination != null) _openFull(destination);
        },
      ),
      ListTile(
        leading: const Icon(Icons.info_outline),
        title: Text('版本与反馈', style: const TextStyle(height: 1.6)),
        subtitle: Text(AppVersion.display, style: const TextStyle(height: 1.6)),
        trailing: const Icon(Icons.chevron_right),
        // 反馈方式（GitHub / 邮箱）与版本说明都在帮助页最后一章
        onTap: () {
          final NavDestination? destination = AppNavigation.byId('help');
          if (destination != null) _openFull(destination);
        },
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '数据保存在手机的应用私有目录里；卸载应用会删除全部数据。',
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget body = switch (_tabs[_tab].id) {
      'overview' => appShellPage(
        widget.shell,
        AppNavigation.byId('overview')!,
        onNavigate: (String id) {
          final NavDestination? d = AppNavigation.byId(id);
          if (d != null) _openFull(d);
        },
        // ③ 查价（2026-10-24，§CV·一百零四）：手机上**更需要** ——
        // 顾客问「这个多少钱」时店员手里只有手机，扫码枪就是摄像头/键盘。
        onPriceLookup:
            widget.shell.products == null || widget.shell.queries == null
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => PriceLookupPage(
                    products: widget.shell.products!,
                    stockSnapshot: widget.shell.queries!.stockByProduct,
                  ),
                ),
              ),
      ),
      'stock' => appShellPage(widget.shell, AppNavigation.byId('stock')!),
      'parties' => appShellPage(widget.shell, AppNavigation.byId('parties')!),
      'billing' => _billingTab(theme),
      _ => _mineTab(theme),
    };
    return Scaffold(
      // SafeArea(top) —— §BH·六 B1c（真机反馈：全面屏状态栏压住内容）：
      // 桌面页没有 AppBar，直接摆会被状态栏盖住 ⇒ 统一让出顶部；
      // bottom 交给 NavigationBar 自己处理（避免双重内边距）
      body: SafeArea(
        bottom: false,
        // 三态条常驻所有 tab 顶部（裁定 ④「顶部常驻」）；明细见 [_SyncStatusBar]
        child: Column(
          children: <Widget>[
            _SyncStatusBar(
              sync: widget.shell.mobileSync,
              version: widget.shell,
            ),
            // 2026-10-31 联调 #0（用户裁定 A + B）：本机账本打不开时**不拦人**，
            // 顶部常驻一条说明 + 一个「修复本机账本」。放在三态条**下面** ——
            // 三态条已裁定「顶部常驻」，这条是异常提醒，不去挤那个位置
            // （与 `ReadFailureBanner` 同一摆放理由）。
            if (widget.shell.localDbNotice != null)
              LocalDbBanner(
                message: widget.shell.localDbNotice!,
                onAdvice: widget.shell.onLocalDbAdvice,
              ),
            // #42 甲 · L4（2026-10-14）：读数据不全的提示条 —— 与桌面壳**共用
            // 同一个 widget**（`read_failure_banner.dart`，照 `appShellPage` 的先例）。
            // 位置放在三态条**下面**：三态条是「同步进度」（常态），这条是「异常提醒」，
            // 不去挤已裁定「顶部常驻」的那个位置。计数为 0 时它自己收成 `SizedBox.shrink()`。
            ReadFailureBanner(log: widget.shell.readFailures),
            Expanded(child: body),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (int index) => setState(() => _tab = index),
        destinations: <Widget>[
          for (final _MobileTab tab in _tabs)
            NavigationDestination(icon: Icon(tab.icon), label: tab.label),
        ],
      ),
    );
  }
}

/// 同步**三态条**（B3b·裁定 ④⑤）—— 手机壳顶部常驻、可点开看明细。
///
/// ## 判定（core 的 `SyncQueueTriage`，UI 只取值不造句）
///
/// - **已同步** = 没有 `pending` 和 `failed`（`sent` 不显示 —— 主机已收下）；
/// - **待同步 N 条** = `pending` 数；**失败 M 条** = `failed` 数，两者**并列**。
///
/// ## 为什么桌面没有它
///
/// 桌面是主机（`ServiceSink` 永不产生队列条目）—— 不挂它是**减少视觉噪音**，
/// 不是功能差异。手机壳（本文件）只此一份 ⇒ 天然满足「`if (mobile) 渲染`」，
/// 不写「`if (桌面) 不渲染`」（前者不容易漏，裁定 ⑤）。
///
/// ## 数据什么时候刷新（IO 不进 build）
///
/// [version] 每次壳重建（app.dart `setState`）都换新 `AppShell` 实例，
/// 以**实例身份**当版本号：「提交成功 / 立即同步完成 / 自动推送结束」都会触发
/// app.dart 重建 ⇒ 这里 `didUpdateWidget` 重查一次队列计数。
class _SyncStatusBar extends StatefulWidget {
  const _SyncStatusBar({required this.sync, required this.version});

  /// 手机端同步服务（持镜像库）。`null` = 装配没给（摆放层测试）⇒ 不显示。
  final MobileSyncService? sync;

  /// 刷新版本号（用 `AppShell` 实例身份）。
  final Object version;

  @override
  State<_SyncStatusBar> createState() => _SyncStatusBarState();
}

class _SyncStatusBarState extends State<_SyncStatusBar> {
  SyncQueueTriage? _triage;

  /// M04（2026-10-08）：链接态（配对 / 首同步）——**队列之外的前置判定**。
  SyncLinkState _link = SyncLinkState.notPaired;

  /// 「立即重试」正在进行中（按钮转成「正在重试…」并禁用，防连点）
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_SyncStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.version, widget.version)) _load();
  }

  void _load() {
    final MobileSyncService? sync = widget.sync;
    if (sync == null) return;
    try {
      // M04（2026-10-08）：队列之外**先看配对与首同步** —— 没配对时队列
      // 天然是空的，只看队列会把「还没连上」显示成「已同步」（信任问题）
      final PairingInfo? pairing = sync.pairingStore.load();
      final SyncQueueTriage triage = SyncQueueDao(sync.openMirror()).counts();
      setState(() {
        _link = syncLinkStateOf(
          paired: pairing != null,
          everSynced: pairing?.lastSyncAt != null,
        );
        _triage = triage;
      });
    } catch (_) {
      // 镜像打不开就不显示这一行 —— 三态条是辅助信息，不能把壳挡死
      setState(() => _triage = null);
    }
  }

  /// 未连接 / 没同步过时点开三态条 —— **说清「怎么连上电脑」**，
  /// 不让「尚未连接电脑」变成一个点不动的死标签（M04）。
  Future<void> _showLinkHint() async {
    final bool notPaired = _link == SyncLinkState.notPaired;
    final String title = notPaired ? '这台手机还没连接电脑' : '还没有成功同步过';
    final String body = notPaired
        ? '到「我的 → 设置 → 多设备同步」扫描电脑上显示的二维码，'
              '就能把商品和客户同步到这台手机。\n\n'
              '在连上之前，你在手机上开的单会先存在本机，不会丢。'
        : '已经配对过，但还没有成功同步。请确认电脑上的「神算子」开着、'
              '手机和电脑连的是同一个 Wi-Fi，然后到「我的 → 设置」点「立即同步」。';
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(body, style: const TextStyle(height: 1.6)),
            ],
          ),
        ),
      ),
    );
  }

  /// **手动重试一次**（F16 丙，2026-10-27 用户裁定）。
  ///
  /// 为什么要有它：乙（推送后对账）只能救「响应丢了」；如果电脑上的服务真挂了、
  /// 或者局域网彻底断，对账也会失败 —— 那时用户需要一个**能戳一下的出口**，
  /// 而不是盯着「待同步 N 条」怀疑软件坏了。
  ///
  /// ⚠️ 用户点完**必须当场刷徽标**（`_load()`）—— F16 的原始观感就是
  /// 「要切走再回来才变」，这里不能重演。
  Future<void> _retryNow(BuildContext sheetContext) async {
    final MobileSyncService? sync = widget.sync;
    if (sync == null) return;
    setState(() => _retrying = true);
    final SyncOutcome outcome = await sync.reconcilePending();
    if (!mounted) return;
    setState(() => _retrying = false);
    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
    _load(); // 丙：立刻刷徽标，不等切走再回来
    // 统一走 `showNotice`（D4 甲：每次弹之前先清队列，默认 3 秒、长文案 6 秒）
    showNotice(
      context,
      outcome.message,
      long: outcome.kind != SyncOutcomeKind.ok,
    );
  }

  Future<void> _showDetail() async {
    final SyncQueueTriage? triage = _triage;
    final MobileSyncService? sync = widget.sync;
    if (triage == null || sync == null) return;
    // M04：没连上 / 没同步过时，点开要说清「怎么连上」
    if (_link != SyncLinkState.linked) {
      await _showLinkHint();
      return;
    }
    if (triage.isSynced) return;
    final SyncQueueDao dao = SyncQueueDao(sync.openMirror());
    final List<SyncQueueEntry> pending = dao.withStatus(
      SyncQueueStatus.pending,
    );
    final List<SyncQueueEntry> failed = dao.withStatus(SyncQueueStatus.failed);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '同步队列',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            // F16 丙：一个能戳的出口。只在**有待同步**时出现
            //（`failed` 的条目各自有「重试，发给现在这台电脑」，不在这里重复）。
            if (pending.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: FilledButton.icon(
                  key: const Key('sync-retry-now'),
                  onPressed: _retrying ? null : () => _retryNow(sheetContext),
                  icon: const Icon(Icons.sync, size: 18),
                  label: Text(_retrying ? '正在重试…' : '立即重试'),
                ),
              ),
            for (final SyncQueueEntry entry in pending)
              ListTile(
                leading: const Icon(Icons.schedule_outlined),
                title: Text(
                  _docLabel(entry),
                  style: const TextStyle(height: 1.4),
                ),
                // #53（外测 M02，二稿裁定 2026-10-16）：这里列的都是「没传上的」
                // —— 直说补救动作，不承诺「联网自动推」。
                subtitle: const Text(
                  '待同步 —— 没传上的，切回来或点「立即同步」会继续',
                  style: TextStyle(height: 1.4),
                ),
              ),
            for (final SyncQueueEntry entry in failed) ...<Widget>[
              ListTile(
                leading: Icon(
                  Icons.error_outline,
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
                title: Text(
                  _docLabel(entry),
                  style: const TextStyle(height: 1.4),
                ),
                subtitle: Text(
                  // #47 丁（2026-10-16 裁定）：换主机挂起（`markHeld`）与普通推送失败
                  // 共用 `failed` 状态；挂起的原因写在 `lastError`（机读标记 =
                  // 登记待办，与 #24 同族）。有 reason 就如实显示 —— 挂起的
                  // reason 本身就是写给用户看的一段话。
                  entry.lastError ?? '推送没成功（原因不明）',
                  style: const TextStyle(height: 1.4),
                ),
              ),
              // 双出口（裁定丁）：并列、不预设用户意图 ——
              // 「重试」把语义讲清（可能记到另一家店名下），「放弃」说清后果。
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextButton.icon(
                      onPressed: () => _confirmRetry(sheetContext, entry),
                      icon: const Icon(Icons.upload_outlined),
                      label: const Text('重试，发给现在这台电脑'),
                    ),
                  ),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: () => _confirmDiscard(sheetContext, entry),
                      icon: const Icon(Icons.block_outlined),
                      label: const Text('放弃，不发送'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// #47 丁（2026-10-16 裁定）· 出口 ①：**重试 = 发给现在这台电脑**。
  ///
  /// 两种场景数据上无法区分（同店换电脑 / 换了经营主体）——
  /// 所以不替用户判断，**把语义讲清让他自己选**（「二次确认」挡不住跨店错误，
  /// 理解语义才能）。确认 ⇒ `requeue` 放回队列 + 立即推一次。
  Future<void> _confirmRetry(
    BuildContext sheetContext,
    SyncQueueEntry entry,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: sheetContext,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('把这张单发给现在这台电脑？'),
        content: const Text(
          '如果现在的电脑是同一家店的另一台电脑，这张单会正确接上。\n\n'
          '如果它属于另一家店，这张单会记到那家店的名下。\n\n'
          '拿不准的话，选「先不发」。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('先不发'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('发给这台电脑'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final MobileSyncService? sync = widget.sync;
    if (sync == null) return;
    SyncQueueDao(sync.openMirror()).requeue(entry.id);
    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
    _load(); // 三态条跟着变（回到「待同步 N 条」）
    unawaited(sync.autoPush().then((_) => _load())); // 立即推，不等回前台
  }

  /// #47 丁 · 出口 ②：**放弃，不发送**。
  ///
  /// 裁定快路径 = **删除**（放弃后估算立刻恢复准确）；「标 `discarded` 可审计、
  /// 可撤销 + 机读标记」登记为待办（与 #24 同族，动 schema 时一起做）。
  /// 删除不可逆 ⇒ 必须确认，且文案写清后果（裁定原文：核对库存后手工校准）。
  Future<void> _confirmDiscard(
    BuildContext sheetContext,
    SyncQueueEntry entry,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: sheetContext,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('放弃这张单，不再发送？'),
        content: Text(
          '「${_docLabel(entry)}」放弃后就不再发给任何电脑，也找不回来。\n\n'
          '货和钱的实际变化请按实物核对，库存可在「库存」页手工校准。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('先不放弃'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final MobileSyncService? sync = widget.sync;
    if (sync == null) return;
    SyncQueueDao(sync.openMirror()).delete(entry.id);
    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final SyncQueueTriage? triage = _triage;
    if (triage == null) return const SizedBox.shrink();

    final ColorScheme colors = Theme.of(context).colorScheme;
    // M04：文案与色调都由纯 Dart 判定（`syncBarLabel` / `syncBarToneOf`）
    final String label = syncBarLabel(link: _link, triage: triage);
    final Color color = switch (syncBarToneOf(link: _link, triage: triage)) {
      SyncBarTone.error => colors.error,
      SyncBarTone.active => colors.primary,
      SyncBarTone.neutral => colors.outline,
    };

    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 8, 0),
        child: Material(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _showDetail,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(label, style: TextStyle(fontSize: 12, color: color)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 队列条目的展示名：wire payload 里的**占位单号**（`待同步-…`）；
/// 取不到再退回实体 id 前缀（不该发生，防御）。
String _docLabel(SyncQueueEntry entry) {
  final Object? document = entry.payload['document'];
  if (document is Map) {
    final Object? docNo = document['doc_no'];
    if (docNo is String && docNo.isNotEmpty) return docNo;
  }
  return '单据 ${entry.entityId.length > 8 ? entry.entityId.substring(0, 8) : entry.entityId}…';
}
