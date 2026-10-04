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
///   现有页面 —— 复用桌面页在手机上可滚可用；B3 做「只进队列」时再整体重设计。
/// - 推入的页面套一层 `Scaffold + AppBar`（带返回键）—— 桌面页自身
///   不带返回导航，直接推会「进去出不来」。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

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
  void _openFull(NavDestination destination) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => Scaffold(
          appBar: AppBar(title: Text(destination.label)),
          body: appShellPage(widget.shell, destination),
        ),
      ),
    );
  }

  /// 「开单」tab：三个入口（§BH B3 扩展前的过渡形态）。
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
        '先在手机上试开单 —— 当前版本在手机本机记账；'
        '与电脑的自动同步在后续版本开放。',
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
      body: SafeArea(bottom: false, child: body),
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
