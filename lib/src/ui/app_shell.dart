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
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

import 'nav_icons.dart';
import 'overview_page.dart';
import 'products_page.dart';
import 'account_page.dart';
import 'documents_page.dart';
import 'help_page.dart';
import 'settings_page.dart';
import 'parties_page.dart';
import 'purchase_page.dart';
import 'sale_page.dart';
import 'delivery_page.dart';
import 'stock_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.dataDirectory,
    required this.backupDirectory,
    required this.schemaVersion,
    required this.databaseReady,
    this.products,
    this.purchases,
    this.sales,
    this.deliveries,
    this.accounts,
    this.parties,
    this.queries,
    this.documents,
    this.settlements,
    this.engine,
    this.uiScale = UiScale.standard,
    this.shopName,
    this.backupStatusLine,
    this.backupNeedsAttention = false,
    this.backupReminder,
    this.onBackupNow,
    this.exports,
    this.hostService,
    required this.configStore,
    required this.onConfigChanged,
    this.initialDestinationId,
  });

  final String dataDirectory;
  final String backupDirectory;
  final int schemaVersion;
  final bool databaseReady;

  /// 商品建档服务（数据库打开成功才有；为 `null` 时商品页显示「数据文件还没就绪」）
  final ProductService? products;

  /// 采购开单服务（同一数据库；为 `null` 时采购页显示占位）
  final PurchaseService? purchases;

  /// 店内销售开单服务（同一数据库；为 `null` 时销售页显示占位）
  final SaleService? sales;

  /// 送货服务（同一数据库；为 `null` 时送货页显示占位）。
  /// 批次 1b —— 规则早就在 core 里（RULE-003），本批次只补入口。
  final DeliveryService? deliveries;

  /// 账户建档服务（同一数据库；为 `null` 时账户页显示「数据文件还没就绪」）
  final AccountService? accounts;

  /// 往来方最小建档服务（销售页客户「新建」用）
  final PartyService? parties;

  /// 聚合查询（RULE-006；库存页用）
  final QueryDao? queries;

  /// 单据 DAO（单据列表页用）
  final DocumentDao? documents;

  /// 主机同步服务（§AH · AH-A；库打开成功才有）。
  /// `null` 时设置页那一段显示「暂时用不了」，而不是装作能用。
  final HostServiceController? hostService;

  /// 核销服务（单据详情页的收款 / 付款；`null` = 列表行不可点）
  final SettlementService? settlements;

  /// 规则引擎（库存页的期初录入「重新清点」入口用；`null` = 入口不可用，
  /// 库存页显示占位）
  final RuleEngine? engine;

  /// 界面缩放（设置页可改；导航宽度随它缩放）
  final UiScale uiScale;

  /// 店名（概览页顶部显示；可空）
  final String? shopName;

  /// 「上次备份：时间（来源）」文案（§AE-5）。
  ///
  /// ⚠️ **文案在 `shensuanzi_app` 里造句**（`backupStatusLine`），
  /// 这里只是搬运 —— 概览橙卡与设置页红字必须**同一个判定**，不许各算一遍。
  final String? backupStatusLine;

  /// 超 3 天没备份（AE-5：设置页红字）
  final bool backupNeedsAttention;

  /// 概览页橙卡文案（AE-3；`null` = 不用提醒）
  final String? backupReminder;

  /// 「立即备份」（设置页按钮 / 概览橙卡**共用同一条路径**）
  final Future<BackupOutcome> Function()? onBackupNow;

  /// 导出服务（§AF）。`null` = 不显示导出按钮（库没打开时）
  final ExportSink? exports;

  /// 配置读写入口（设置页用）。
  ///
  /// ⚠️ **必传**（2026-09-29 台账 §AI-1）：曾经「可选 + 为 null 就显示占位页」，
  /// 而生产入口 `runApp(const ShensuanziApp())` 恰好不注入 → AppShell 拿到
  /// null → 真机上设置页**永远停在「正在开发」占位页**；且所有测试都注入了
  /// 沙箱 store，这条生产路径零覆盖、门禁全绿照过。改成 required 后
  /// 「忘了接」直接编译不过 —— 让这个 bug 不可表示。
  final AppConfigStore configStore;

  /// 设置页修改配置后的回调（宿主热应用缩放/店名）
  final void Function(AppConfig config) onConfigChanged;

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
          _NavColumn(
            current: _current,
            onSelect: _select,
            scaleFactor: widget.uiScale.factor,
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _content() {
    final NavDestination current = _current;

    final Widget page;
    if (current.id == 'overview') {
      page = OverviewPage(
        shopName: widget.shopName,
        dataDirectory: widget.dataDirectory,
        backupDirectory: widget.backupDirectory,
        schemaVersion: widget.schemaVersion,
        databaseReady: widget.databaseReady,
        backupReminder: widget.backupReminder,
        onBackupNow: widget.onBackupNow,
      );
    } else if (current.id == 'products') {
      // 商品是核心闭环的第一块 —— 已实现，不再是占位页
      page = ProductsPage(service: widget.products, exports: widget.exports);
    } else if (current.id == 'sale') {
      // 店内销售是核心闭环的第三块（RULE-002）；客户「新建」共用 PartyService
      page = widget.sales == null || widget.products == null || widget.parties == null
          ? _PendingPage(destination: current)
          : SalePage(
              service: widget.sales!,
              productService: widget.products!,
              partyService: widget.parties!,
            );
    } else if (current.id == 'delivery') {
      // 送货（批次 1b / RULE-003）：创建即扣库存、状态强制 in_transit，
      // 客户必选。**不能从销售单转** —— 转了会双扣（§AP）。
      page =
          widget.deliveries == null ||
              widget.products == null ||
              widget.parties == null
          ? _PendingPage(destination: current)
          : DeliveryPage(
              service: widget.deliveries!,
              productService: widget.products!,
              partyService: widget.parties!,
            );
    } else if (current.id == 'stock') {
      // 库存查询是 RULE-006 的纯聚合读；期初录入入口（§AD）还要引擎
      page = widget.engine == null || widget.products == null || widget.queries == null
          ? _PendingPage(destination: current)
          : StockPage(
              engine: widget.engine!,
              products: widget.products!,
              queries: widget.queries!,
              exports: widget.exports,
            );
    } else if (current.id == 'parties') {
      page = widget.parties == null
          ? _PendingPage(destination: current)
          : PartiesPage(service: widget.parties!, exports: widget.exports);
    } else if (current.id == 'documents') {
      page = widget.documents == null
          ? _PendingPage(destination: current)
          : DocumentsPage(
              dao: widget.documents!,
              exports: widget.exports,
              settlements: widget.settlements,
              deliveries: widget.deliveries,
              products: widget.products,
            );
    } else if (current.id == 'settings') {
      // §AI-1：configStore / onConfigChanged 已是 required —— 设置页是常驻
      // 入口（ui_principles），「占位页」分支整体删除（它曾把生产真机挡在外面）
      page = SettingsPage(
        config: widget.configStore.load(),
        configStore: widget.configStore,
        backupDirectory: widget.backupDirectory,
        backupStatusLine: widget.backupStatusLine,
        backupNeedsAttention: widget.backupNeedsAttention,
        onBackupNow: widget.onBackupNow,
        hostService: widget.hostService,
        onChanged: widget.onConfigChanged,
      );
    } else if (current.id == 'help') {
      // AE-6：恢复步骤要带**用户真实的两个文件夹**，否则他照做不下去
      page = HelpPage(
        dataDirectory: widget.dataDirectory,
        backupDirectory: widget.backupDirectory,
      );
    } else if (current.id == 'accounts') {
      page = widget.accounts == null
          ? _PendingPage(destination: current)
          : AccountsPage(service: widget.accounts!);
    } else if (current.id == 'purchase') {
      // 采购入库是核心闭环的第二块 —— 库存与规则早就在 core 里（RULE-001）
      page = widget.purchases == null || widget.products == null
          ? _PendingPage(destination: current)
          : PurchasePage(
              service: widget.purchases!,
              productService: widget.products!,
            );
    } else {
      page = _PendingPage(destination: current);
    }

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
  const _NavColumn({
    required this.current,
    required this.onSelect,
    required this.scaleFactor,
  });

  final NavDestination current;
  final ValueChanged<NavDestination> onSelect;

  /// 界面缩放系数（设置页的档位；导航宽度随它缩放）
  final double scaleFactor;

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
      width: AppNavigation.widthFor(scale: scaleFactor),
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
