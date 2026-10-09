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
    this.documentSink,
    this.onDocumentSubmitted,
    this.onStorageFailure,
    this.stockDelta,
    required this.masterDataPolicy,
    this.masterDataSink,
    this.mobileShell = false,
    this.returns,
    this.onMigrateData,
    this.mobileSync,
    this.onScanPair,
    this.onSyncNow,
    this.accounts,
    this.parties,
    this.queries,
    this.documents,
    this.settlements,
    this.engine,
    this.uiScale = UiScale.standard,
    this.shopName,
    this.dataLocationNote,
    this.dataPathsNote,
    this.hostSyncNote,
    this.onExportBackup,
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

  /// 开单**提交出口**（B3b·§CA）：三个开单页只对它编程，
  /// **不出现「是不是客户端」的分支**。桌面 = `ServiceSink`（落库+规则，
  /// 与直连逐字同行为）；手机 = `QueueSink`（校验 → 入队）。
  /// `null` 时开单页显示占位（库未就绪）。
  final DocumentSink? documentSink;

  /// 提交成功回调（B3b）。手机端注入 = 刷新三态条 + 触发自动推送
  /// （裁定 ③，app.dart 实现）；桌面不注入 —— `ServiceSink` 恒
  /// `isQueued=false`，没有队列这回事。
  final void Function(DocumentSubmitResult result)? onDocumentSubmitted;

  /// 开单保存失败时把**原始异常**交给宿主记日志（M15，2026-10-08）。
  /// 界面只显示 `storageFailureNote` 的分类文案；`null` = 不记（测试）。
  final void Function(Object error, StackTrace stack)? onStorageFailure;

  /// 库存叠加（C2·§CC 裁定七：权威 + 未同步 + 拆解）。
  /// 手机端注入（镜像队列）；桌面 `null` = 现状零变化。
  final StockDelta? stockDelta;

  /// **主数据门控**（§CV·七 ① 乙，2026-10-09）：三族各自能不能在**本机**建档。
  /// 桌面 = `MasterDataPolicy.desktop()`；手机 v1 = `MasterDataPolicy.mobile()`
  /// （只开商品）。
  ///
  /// ⚠️ **required** —— 旧版 `readOnlyMasterData` 带默认 `false`，默默漏装就是
  /// 「手机上一切都能建」；手机端的 `PartyService` / `ProductService` 建在**镜像**上，
  /// 写进去永远到不了电脑（静默丢数据）。宁可编不过。
  final MasterDataPolicy masterDataPolicy;

  /// 主数据提交**出口**（§CV·七 ① 乙）。
  ///
  /// 桌面 `ServiceMasterSink`（落库）/ 手机 `QueueMasterSink`（乐观写镜像 + 入队）。
  /// `null` = 装配没给（摆放层测试）⇒ 相关页面退回 `_PendingPage`（与
  /// [documentSink] **同一惯用法**：宁可显示「数据未就绪」，也不给一条写不通的路径）。
  final MasterDataSink? masterDataSink;

  /// **是不是手机壳**（M05 / M07，2026-10-08）。
  ///
  /// 与 [masterDataPolicy] **不同源**（M05 当年与旧的「禁建」flag 同源，§CV·七 ①
  /// 拆分后彻底分开）：这个说的是「界面形态」（顶部三态条 / 底部导航 / 没有单据详情页），
  /// 那个说的是「能不能在本机建**主数据**」。两者取值当前仍一致（都跟 `ShellKind`），
  /// 但**语义无关** —— 将来手机放开主数据建档，本 flag 一个字都不用改。
  ///
  /// 用途：同一份页面代码里，**按壳给不同的指引文案** ——
  /// 例如送货页原来叫用户「到「单据」详情页点收款」，而手机**没有**那个页面。
  final bool mobileShell;

  /// 退货服务（§BI R2：单据详情页的退货 / 拒收入口；`null` = 入口不可用）
  final ReturnService? returns;

  /// 「更改数据位置」完整流程（§BK·三，宿主 app.dart 实现）；`null` = 不显示按钮
  final Future<void> Function()? onMigrateData;

  /// 手机端同步服务（§BL·三；`null` = 桌面 —— 桌面是主机，用 hostService 面板）
  final MobileSyncService? mobileSync;

  /// 「扫码连接主机」（app.dart：推扫码页 + 完成后重建页面）
  final Future<void> Function()? onScanPair;

  /// 「立即同步」（app.dart：遮罩 + syncNow + 完成后重建页面 —— 裁定 ⑦）
  final Future<void> Function()? onSyncNow;

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

  /// 概览页「你的数据在」的显示文案（§BH·五 B1b 裁定 2：Android 私有目录
  /// 用户打不开，显示友好文案而非具体路径；路径挪到帮助页「关于」小字）。
  /// `null` = 显示真实路径（桌面行为，零变化）。
  final String? dataLocationNote;

  /// 设置页数据区的替代文案（§BH·六 B1c：Android 隐藏两行路径与无效的
  /// 「打开」按钮）。`null` = 桌面（零变化）。
  final String? dataPathsNote;

  /// 设置页多设备同步区的替代文案（§BH·六 B1c：Android 是客户端，不做
  /// 主机 —— 真机反馈 2026-10-04）。`null` = 桌面（hostService 面板）。
  final String? hostSyncNote;

  /// 设置页「导出本机数据文件」（原「导出备份到手机文件」；**2026-10-07 按
  /// `docs/reply.md` §4 的 B 方案改口径** —— 手机端**不叫备份**：权威数据在
  /// 主机上，叫备份会让用户以为「电脑坏了也没事」。仅移动端注入）。
  /// `null` = 不显示入口（桌面零变化）。
  final Future<String> Function()? onExportBackup;

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

/// 按 destination 构建页面 —— **AppShell 与 MobileShell 共用的唯一装配**
/// （§BH B1a：两套壳各写一份必然漂移；摆放差异 —— 面包屑 / 底部导航 ——
/// 留在各自的壳里，这里只管「id → 页面」）。服务的可空兜底（`_PendingPage`）
/// 也在这里：调用方不必重复判空。
Widget appShellPage(AppShell shell, NavDestination destination) {
  final Widget page;
  if (destination.id == 'overview') {
    page = OverviewPage(
      shopName: shell.shopName,
      dataDirectory: shell.dataDirectory,
      backupDirectory: shell.backupDirectory,
      schemaVersion: shell.schemaVersion,
      databaseReady: shell.databaseReady,
      backupReminder: shell.backupReminder,
      onBackupNow: shell.onBackupNow,
      locationNote: shell.dataLocationNote,
      // M05：指路文案随壳走（桌面「左边」/ 手机「底部」）
      mobileShell: shell.mobileShell,
    );
    } else if (destination.id == 'products') {
      // 商品是核心闭环的第一块 —— 已实现，不再是占位页
      page = ProductsPage(service: shell.products, exports: shell.exports);
    } else if (destination.id == 'sale') {
      // 店内销售是核心闭环的第三块（RULE-002）；客户「新建」共用 PartyService
      page = shell.sales == null ||
              shell.products == null ||
              shell.parties == null ||
              shell.documentSink == null ||
              shell.masterDataSink == null
          ? _PendingPage(destination: destination)
          : SalePage(
              service: shell.sales!,
              productService: shell.products!,
              partyService: shell.parties!,
              // B3b：提交走 Sink（桌面/手机同一份页面代码，无分支）
              sink: shell.documentSink!,
              onSubmitted: shell.onDocumentSubmitted,
              onStorageFailure: shell.onStorageFailure,
              // M08：本地未同步影响（手机端才有；桌面 null）
              stockDelta: shell.stockDelta,
              // §CV·七 ① 乙：主数据门控按**能力**走（商品 v1 可建 / 往来仍引导）
              masterDataPolicy: shell.masterDataPolicy,
              masterDataSink: shell.masterDataSink!,
            );
    } else if (destination.id == 'delivery') {
      // 送货（批次 1b / RULE-003）：创建即扣库存、状态强制 in_transit，
      // 客户必选。**不能从销售单转** —— 转了会双扣（§AP）。
      page =
          shell.deliveries == null ||
              shell.products == null ||
              shell.parties == null ||
              shell.documentSink == null ||
              shell.masterDataSink == null
          ? _PendingPage(destination: destination)
          : DeliveryPage(
              service: shell.deliveries!,
              productService: shell.products!,
              partyService: shell.parties!,
              sink: shell.documentSink!,
              onSubmitted: shell.onDocumentSubmitted,
              onStorageFailure: shell.onStorageFailure,
              // M08：本地未同步影响（手机端才有；桌面 null）
              stockDelta: shell.stockDelta,
              masterDataPolicy: shell.masterDataPolicy,
              masterDataSink: shell.masterDataSink!,
              mobileShell: shell.mobileShell,
            );
    } else if (destination.id == 'stock') {
      // 库存查询是 RULE-006 的纯聚合读；期初录入入口（§AD）还要引擎
      page = shell.engine == null || shell.products == null || shell.queries == null
          ? _PendingPage(destination: destination)
          : StockPage(
              engine: shell.engine!,
              products: shell.products!,
              queries: shell.queries!,
              exports: shell.exports,
              stockDelta: shell.stockDelta,
              // 期初入口 + 镜像空态按**壳**走（不是主数据权限 —— 盘点 delta
              // 客户端算不出，见 `stock_page.dart`）
              mobileShell: shell.mobileShell,
            );
    } else if (destination.id == 'parties') {
      page = shell.parties == null
          ? _PendingPage(destination: destination)
          : PartiesPage(
              service: shell.parties!,
              exports: shell.exports,
              masterDataPolicy: shell.masterDataPolicy,
            );
    } else if (destination.id == 'documents') {
      page = shell.documents == null
          ? _PendingPage(destination: destination)
          : DocumentsPage(
              dao: shell.documents!,
              exports: shell.exports,
              settlements: shell.settlements,
              deliveries: shell.deliveries,
              products: shell.products,
              returnService: shell.returns,
            );
    } else if (destination.id == 'settings') {
      // §AI-1：configStore / onConfigChanged 已是 required —— 设置页是常驻
      // 入口（ui_principles），「占位页」分支整体删除（它曾把生产真机挡在外面）
    page = SettingsPage(
      config: shell.configStore.load(),
      configStore: shell.configStore,
      backupDirectory: shell.backupDirectory,
      backupStatusLine: shell.backupStatusLine,
      backupNeedsAttention: shell.backupNeedsAttention,
      onBackupNow: shell.onBackupNow,
      hostService: shell.hostService,
      dataPathsNote: shell.dataPathsNote,
      hostSyncNote: shell.hostSyncNote,
      onExportBackup: shell.onExportBackup,
      onChanged: shell.onConfigChanged,
      onMigrateData: shell.onMigrateData,
      mobileSync: shell.mobileSync,
      onScanPair: shell.onScanPair,
      onSyncNow: shell.onSyncNow,
    );
    } else if (destination.id == 'help') {
      // AE-6：恢复步骤要带**用户真实的两个文件夹**，否则他照做不下去
      page = HelpPage(
        dataDirectory: shell.dataDirectory,
        backupDirectory: shell.backupDirectory,
      );
    } else if (destination.id == 'accounts') {
      page = shell.accounts == null
          ? _PendingPage(destination: destination)
          : AccountsPage(
              service: shell.accounts!,
              masterDataPolicy: shell.masterDataPolicy,
            );
    } else if (destination.id == 'purchase') {
      // 采购入库是核心闭环的第二块 —— 库存与规则早就在 core 里（RULE-001）
      page = shell.purchases == null ||
              shell.products == null ||
              shell.documentSink == null ||
              shell.masterDataSink == null
          ? _PendingPage(destination: destination)
          : PurchasePage(
              service: shell.purchases!,
              productService: shell.products!,
              sink: shell.documentSink!,
              onSubmitted: shell.onDocumentSubmitted,
              onStorageFailure: shell.onStorageFailure,
              masterDataPolicy: shell.masterDataPolicy,
              masterDataSink: shell.masterDataSink!,
            );
    } else {
      page = _PendingPage(destination: destination);
    }
  return page;
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

    // 页面装配在 [appShellPage] —— 与 MobileShell **共用同一份**（§BH B1a），
    // 两套壳各写一份必然漂移；本方法只管「面包屑 / 工具栏」这层桌面摆设。
    final Widget page = appShellPage(widget, current);
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
