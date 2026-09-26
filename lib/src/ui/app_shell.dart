/// 应用外壳：**左侧常驻导航 + 右侧内容区**（`docs/ui_principles.md` §八）。
///
/// ## 为什么是左侧常驻导航
///
/// 核心页面全是**表格**（商品、库存、单据、往来方）—— 表格要的是**高度**。
/// 顶部标签页会吃掉最贵的垂直空间，而且一旦超过 6 项就折叠成「更多」菜单，
/// 等于**隐藏入口** —— 恰好踩中中老年用户最大的使用障碍。
///
/// ## 判断都在 `shensuanzi_app`
///
/// 有哪些入口、分几组、顺序如何、哪个是沉浸模式、导航多宽 ——
/// 全在 `AppNavigation`（纯 Dart，`dart test` 覆盖）。
/// **本文件只做两件事**：把 `iconKey` 换成 `IconData`、把控件摆出来。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

import 'nav_icons.dart';
import 'overview_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.dataDirectory,
    required this.backupDirectory,
    required this.schemaVersion,
    required this.databaseReady,
    this.initialDestinationId,
  });

  final String dataDirectory;
  final String backupDirectory;
  final int schemaVersion;
  final bool databaseReady;

  /// 从哪个入口开始（不传 = 概览）
  final String? initialDestinationId;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late NavDestination _current;

  @override
  void initState() {
    super.initState();
    // 用 initState 而不是 late 字段初始化表达式：后者读 `widget` 是合法但
    // 容易看错，显式写出来读代码的人不用再确认一次时序
    _current = AppNavigation.initial(widget.initialDestinationId);
  }

  void _select(NavDestination destination) {
    if (destination.id == _current.id) return;
    setState(() => _current = destination);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _NavColumn(current: _current, onSelect: _select),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _content() {
    final NavDestination current = _current;

    final Widget page = current.id == 'overview'
        ? OverviewPage(
            dataDirectory: widget.dataDirectory,
            backupDirectory: widget.backupDirectory,
            schemaVersion: widget.schemaVersion,
            databaseReady: widget.databaseReady,
          )
        : _PendingPage(destination: current);

    // 沉浸模式：开单是**连续的动作流程**，不显示面包屑与工具栏
    // （`docs/reply.md` §三）。左侧导航仍在 —— 用户可以随时跳去建商品。
    if (current.immersive) return page;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Breadcrumb(current: current),
        const Divider(height: 1),
        Expanded(child: page),
      ],
    );
  }
}

/// 左侧导航列
class _NavColumn extends StatelessWidget {
  const _NavColumn({required this.current, required this.onSelect});

  final NavDestination current;
  final ValueChanged<NavDestination> onSelect;

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = <Widget>[];

    for (final NavSection section in NavSection.values) {
      // 用**分隔线 + 间距**分组，不做嵌套折叠（中老年用户不会展开）
      if (children.isNotEmpty) {
        children.add(
          const Divider(height: 1, indent: 12, endIndent: 12),
        );
      }
      for (final NavDestination destination in AppNavigation.of(section)) {
        children.add(
          _NavItem(
            key: ValueKey<String>('nav-${destination.id}'),
            destination: destination,
            selected: destination.id == current.id,
            onTap: () => onSelect(destination),
          ),
        );
      }
    }

    // 滚动兜底：窗口很矮时也能看到全部入口（入口**不能藏**）
    return SizedBox(
      width: AppNavigation.expandedWidth,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// 一个导航项。选中时给**三重信号**：背景变色 + 左侧竖条 + 文字加粗。
///
/// 只变颜色不够 —— 色觉异常的比例不低，而中老年用户对「我在哪里」感知弱。
class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final NavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color background = selected
        ? theme.colorScheme.primaryContainer
        : Colors.transparent;
    final Color foreground = selected
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    return InkWell(
      onTap: onTap,
      child: Container(
        height: AppNavigation.itemHeight,
        color: background,
        child: Row(
          children: <Widget>[
            // 信号之二：左侧竖条
            Container(
              width: AppNavigation.indicatorWidth,
              height: double.infinity,
              color: selected ? theme.colorScheme.primary : Colors.transparent,
            ),
            const SizedBox(width: 13),
            // 图标 + 文字**必须成对**：只有图标的入口对中老年用户等于不存在
            Icon(navIcon(destination.iconKey), size: 20, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                destination.label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  color: foreground,
                  height: 1.6,
                  // 信号之三：文字加粗
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 面包屑：告诉用户「我在哪」。
///
/// 现在只有一层（页面名）。开单页保存后会变成 `销售开单 > 已保存` 这类两段。
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.current});

  final NavDestination current;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
    child: Text(
      current.label,
      style: TextStyle(
        height: 1.6,
        color: Theme.of(context).textTheme.bodySmall?.color,
      ),
    ),
  );
}

/// 尚未实现的功能页占位。
///
/// 刻意**把功能名写出来**（而不是一片空白）：用户点进来要能确认
/// 「我点对了，只是还没做」，而不是以为软件坏了。
class _PendingPage extends StatelessWidget {
  const _PendingPage({required this.destination});

  final NavDestination destination;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          navIcon(destination.iconKey),
          size: 40,
          color: Theme.of(context).textTheme.bodySmall?.color,
        ),
        const SizedBox(height: 12),
        Text('${destination.label}：正在开发', style: const TextStyle(height: 1.6)),
        const SizedBox(height: 8),
        Text(
          '这个功能还没做完，先用左边的其他功能。',
          style: TextStyle(
            height: 1.6,
            color: Theme.of(context).textTheme.bodySmall?.color,
          ),
        ),
      ],
    ),
  );
}
