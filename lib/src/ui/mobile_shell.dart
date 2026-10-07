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

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'app_shell.dart';

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
              _SyncStatusBar(sync: widget.shell.mobileSync, version: widget.shell),
              Expanded(child: appShellPage(widget.shell, destination)),
            ],
          ),
        ),
      ),
    );
  }

  /// 「开单」tab：三个入口（B3 已接入 `QueueSink`：开单入队 → 自动推给电脑）。
  Widget _billingTab(ThemeData theme) => ListView(
    padding: const EdgeInsets.all(16),
    children: <Widget>[
      for (final String id in <String>['sale', 'purchase', 'delivery'])
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            // 文字标签必须有（UI 基线），图标只作辅助
            title: Text(
              AppNavigation.byId(id)?.label ?? id,
              style: const TextStyle(height: 1.6, fontSize: 18),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final NavDestination? destination = AppNavigation.byId(id);
              if (destination != null) _openFull(destination);
            },
          ),
        ),
      Text(
        // 2026-10-07 裁定（`docs/reply.md` §一）：自动补传 = 开单后 + **回前台**
        // + 手动按钮。**不许再承诺「联网自动补传」** —— 那是暗行为，
        // 而且（没有网络监听时）根本不成立（M02 报告的问题）。
        '开单后会自动推送到电脑；断网时先记在待同步队列，'
        '回到这个界面时再自动试一次，也可以点「立即同步」——'
        '先到「我的 → 设置」扫码连接电脑。',
        style: TextStyle(height: 1.6, color: theme.textTheme.bodySmall?.color),
      ),
    ],
  );

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
        title: Text(
          '版本与反馈',
          style: const TextStyle(height: 1.6),
        ),
        subtitle: Text(
          AppVersion.display,
          style: const TextStyle(height: 1.6),
        ),
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
          style: TextStyle(height: 1.6, color: theme.textTheme.bodySmall?.color),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget body = switch (_tabs[_tab].id) {
      'overview' => appShellPage(widget.shell, AppNavigation.byId('overview')!),
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
            _SyncStatusBar(sync: widget.shell.mobileSync, version: widget.shell),
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
      // 首次会建空镜像库 —— 空队列 =「已同步」，诚实
      setState(() => _triage = SyncQueueDao(sync.openMirror()).counts());
    } catch (_) {
      // 镜像打不开就不显示这一行 —— 三态条是辅助信息，不能把壳挡死
      setState(() => _triage = null);
    }
  }

  Future<void> _showDetail() async {
    final SyncQueueTriage? triage = _triage;
    final MobileSyncService? sync = widget.sync;
    if (triage == null || triage.isSynced || sync == null) return;
    final SyncQueueDao dao = SyncQueueDao(sync.openMirror());
    final List<SyncQueueEntry> pending = dao.withStatus(SyncQueueStatus.pending);
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
            for (final SyncQueueEntry entry in pending)
              ListTile(
                leading: const Icon(Icons.schedule_outlined),
                title: Text(_docLabel(entry), style: const TextStyle(height: 1.4)),
                subtitle: const Text(
                  '待同步 —— 联网后自动推给电脑',
                  style: TextStyle(height: 1.4),
                ),
              ),
            for (final SyncQueueEntry entry in failed)
              ListTile(
                leading: Icon(
                  Icons.error_outline,
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
                title: Text(_docLabel(entry), style: const TextStyle(height: 1.4)),
                subtitle: Text(
                  '推送没成功（${entry.lastError ?? '原因不明'}）—— '
                  '到「我的 → 设置」点「立即同步」再试',
                  style: const TextStyle(height: 1.4),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final SyncQueueTriage? triage = _triage;
    if (triage == null) return const SizedBox.shrink();

    final ColorScheme colors = Theme.of(context).colorScheme;
    final String label = triage.isSynced
        ? '已同步'
        : <String>[
            if (triage.pendingCount > 0) '待同步 ${triage.pendingCount} 条',
            if (triage.failedCount > 0) '失败 ${triage.failedCount} 条',
          ].join(' · ');
    // 红色只留给错误（ui_principles §二）；待同步用主色，已同步用弱化色
    final Color color = triage.failedCount > 0
        ? colors.error
        : triage.pendingCount > 0
        ? colors.primary
        : colors.outline;

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
