/// 库存查询页（RULE-006，纯聚合读 —— `docs/reply_review.md` §AA 二）。
///
/// ## 裁定落点（§AA）
///
/// - **AA-2**：主列 = **在店可售**（账面 − 在途），字大加粗；账面 / 在途常规
/// - **AA-3 三档颜色**：在店可售 **< 0 红色**（超卖，账对不上）；
///   **0 ≤ x ≤ safety_stock（safety > 0）橙色**（该补货）；
///   正常无色。`safety_stock = 0` 就是「不需要告警」，不触发
/// - **AA-4**：「成本（均价）」列 + ⓘ tooltip 说明口径（历史加权平均，
///   进价变过时与最近一次进价不同）；**负值红色**（与负库存联动）。
///   **业务审查 §4.2（用户裁定 ③乙）**：主数字是**均价**（余值 ÷ 在店可售，
///   round-half-up），总额「共 ¥X」作小字 —— 旧显示把余值（总额）当均价，
///   10 件 × ¥3.50 显示「¥35.00」，用户会以为一件 35 元而**错定价**。
///   没货 / 负库存时均价无意义，只显示总额
/// - **遗漏 4**：默认按在店可售降序（库存页是浏览不是查找）
/// - **遗漏 5**：默认只显示**有流水**的商品；「显示全部」开关查没进过货的
/// - **遗漏 7**：盘点入口 v1 不放（§AA 七：不放比放禁用按钮好）
/// - **§AD 遗漏 2**：右上角入口文案区分**首次 / 再次** —— 没有任何库存流水
///   时是「录入现有货物」（开店建账），有流水后是「重新清点」；否则用户
///   录完 100 件回来看到同一个按钮会想「我不是录过了吗？」
/// - **§AD 遗漏 1**：成本列三态 —— 从未入库「未进货」；期初录入过（有正
///   数量流水但成本余值为 0）「待校准」灰色；正常显示金额。**「¥0.00」会
///   让首次使用的用户以为软件坏了**（AB-2 的产品级落点）
/// - **§AD-6**：空态两段式 —— 第一段给「开店」场景，第二段给「日常」场景
///
/// ## ⚠️ 临时埋点（2026-11-09，用户裁定「甲」）
///
/// `SSZ_PAGE_COST_TRACE` 打开时，本页会记「一次进入重建了几次、两条全表聚合
/// 各花多久」，离开页面时落一行到 `<数据目录>/日志/page-cost.jsonl`
/// （收集器在 `shensuanzi_app` 的 `page_cost_trace.dart`）。
///
/// **它在判定完就得删**：用来回答「库存页的读放大是不是来自一次进入的多次
/// 重建」（`docs/20261109-新版本虚拟机复测-判读.md` §四）。结论落台账之后，
/// 本文件里的 `_pageCost` 三处调用与这个开关一起移除。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'document_detail_page.dart';
import 'export_button.dart';
import 'list_scaffold.dart';
import 'low_stock_card.dart';
import 'opening_stock_page.dart';
import 'scaled.dart';
import 'shortage.dart';
import 'stock_top.dart';
import 'product_form_dialog.dart';
import 'search_field_chips.dart';
import 'stock_flow_page.dart';
import 'card_rows_sliver.dart';

// 在店可售的公式**只在 core 一处**：`shensuanzi_core/lib/src/util/in_store.dart`
// 的 `effectiveInStoreOf`（2026-11-13 提案 61 决策 61-⑦ 下沉）。
// ⚠️ 本文件**不许**再写一份 —— 机械保证：`test/in_store_single_source_test.dart`。

/// 库存查询页。
class StockPage extends StatefulWidget {
  const StockPage({
    super.key,
    required this.engine,
    required this.products,
    required this.queries,
    this.exports,
    this.stockDelta,
    this.mobileShell = false,
    this.pendingMarks,
    this.onStorageFailure,
    this.stockFlow,
    this.settlements,
    this.deliveries,
    this.masterDataSink,
    this.documentSink,
    this.canWrite = true,
    this.canCreateProducts = false,
  });

  /// 规则引擎（期初录入「重新清点」入口用 —— RULE-009 经 `StocktakeService`）
  final RuleEngine engine;

  final ProductService products;
  final QueryDao queries;

  /// 导出服务（`null` = 不显示导出按钮）
  final ExportSink? exports;

  /// 库存叠加（C2·§CC 裁定七：权威 + 未同步 + 拆解）。
  /// 手机端注入（镜像队列）；桌面 `null` = 现状零变化。
  final StockDelta? stockDelta;

  /// **#31（2026-10-16 裁定②）**：「期初 N 件待同步」提示的数据源。
  /// `null` = 桌面 / 测试缺省（不显示提示）。
  final PendingMarks? pendingMarks;

  /// **#43**：期初保存失败的原始异常出口（透传给 `OpeningStockPage`）。
  final void Function(Object error, StackTrace stack)? onStorageFailure;

  /// **#27 批 2**：商品流水查询（手机壳 = 镜像实例化；桌面 = 主库 ——
  /// app.dart 装配，Db 不出服务层）。`null` = 行不可点开流水。
  final StockLedgerDao? stockFlow;

  /// **#27 批 2**：流水行跳单据详情所需（`null` ⇒ 行不可点）。
  final SettlementService? settlements;

  /// **签收服务**（2026-11-11 第六次真机补）：从流水点进**送货单**详情时，
  /// 「签收」按钮要它。
  ///
  /// ⚠️ 原来这里没有这个参数 —— `stock_page.dart` 构造 `DocumentDetailPage` 时
  /// 只传了 `documentId` / `settlements` / `products`，漏了 `deliveries`，
  /// 于是详情页走进「`deliveries == null`」的降级分支，显示
  /// 「签收入口暂时用不了（数据还没就绪）」。**同款构造点共 4 处，只有这一处漏**
  /// （`account_page` / `documents_page` / `document_detail_page` 都传了）。
  /// 真机截图见 `tool/testResult/第六次真机测试/送货页面问题.png`。
  final DeliveryService? deliveries;

  /// **#27 批 2**：「新建商品」提交出口（手机壳 = 队列出口）。`null` = 无按钮。
  final MasterDataSink? masterDataSink;

  /// **盘点单的提交出口**（2026-10-20 放开手机「重新清点」，§CV·七十八）。
  ///
  /// 手机 = `QueueSink`；桌面 = `ServiceSink`（两支都由桌面/手机各自的
  /// 装配传入）。`null` = 未装配（摆放层测试）⇒ 期初页退回 `StocktakeService`。
  final DocumentSink? documentSink;

  /// 能不能写（2026-11-01）：只读降级时 `false` ⇒ 不给「期初录入 / 重新清点」入口。
  final bool canWrite;

  /// **#27 批 2**：本机能不能建商品（门控）—— 按钮显隐用。
  final bool canCreateProducts;

  /// **是不是手机壳**（`ShellKind.mobile`）。本页用它管两件事，**都与主数据权限无关**：
  ///
  /// 1. **期初录入入口**：手机端「保留入口 + 引导」（§CH §7 —— 盘点 `delta`
  ///    客户端**算不出**，宁可诚实地说不知道，也不给一个错的数）；
  /// 2. **空态文案**：手机端读面是**镜像**，库存数字可能还没拉下来 ⇒ 用 `mirrorEmptyMessage`。
  ///
  /// ⚠️ 旧名 `readOnlyMasterData` 已被 §CV·七 ① 拆走（主数据门控现在按**能力**
  /// 走 `MasterDataPolicy`）—— 本页这两件事**不是主数据权限**，是「客户端能力 / 壳形态」，
  /// 所以改用 `mobileShell`（当前取值与旧 flag 逐字一致）。
  final bool mobileShell;

  @override
  State<StockPage> createState() => _StockPageState();
}

class _StockPageState extends State<StockPage> {
  final TextEditingController _query = TextEditingController();
  bool _showAll = false;
  String _searchText = '';

  /// 搜索时**在哪个字段里找**（2026-11-11 用户裁定：做成可选过滤项）。
  ///
  /// [StockSearchField.all] 是三路一起找 —— 与加这个开关之前的行为**完全一致**，
  /// 老用户不会因为升级而「搜不到了」（默认收紧最容易造成「软件坏了」的错觉）。
  ///
  /// 起因：真机测试里搜「6」命中了**全部 300 个商品**。不是匹配逻辑错，
  /// 是造数库的条码全是 `6900001000000…` 开头，三路匹配里条码那一路把所有人捞进来。
  /// 用户看到「搜一个数字出来一屏」，分不清是自己搜错还是软件坏了。
  String _searchField = StockSearchField.all;
  bool _showOpening = false;

  /// 压货榜（2026-11-01，用户裁定 A1：从概览页搬过来）。
  ///
  /// **在 `initState` 算一次**，不在 `build` 里现算：它是**全历史聚合**
  /// （`QueryDao.stockTop` 要扫所有流水），26 万单下 ~35 ms ——
  /// 放在 build 里会变成「每敲一个搜索字符重算一次全库」。
  ///
  /// 刷新时机：两壳切页都会**重建**本页（`appShellPage` / `_pageFor` 每次
  /// build 新建 widget），所以 `initState` 会跟着重跑 —— 切走再切回来就是最新值。
  late StockTopSummary _stockTop;

  /// 压货榜是否展开（默认收起 —— 见 build 里那段注释）
  bool _showTopAll = false;

  /// 缺货榜是否展开（提案 61）。**默认收起**，理由与压货榜逐字相同：
  /// 展开的榜有半屏高，会把搜索框挤出第一屏 —— 而库存页 95% 的用法是
  /// 「搜一个商品看还有多少」。
  ///
  /// ⚠️ 但**引导卡与「暂时都不缺」不受它影响**（那两种形态只有两三行，
  /// 而且正是新用户需要看见的）。
  bool _showLowAll = false;

  /// 库存聚合的原始 map（账面 / 成本余值 / 是否进过货）。
  ///
  /// 缺货榜要用 `hasInbound`（判「从没进过货」），而 `_book` / `_cost` /
  /// `_inbound` 是有损拆分 ⇒ 直接留一份原表，避免再扫一次库。
  late Map<String, StockAgg> _agg;

  /// **临时埋点（2026-11-09「甲」）**：本次进入的重建 / 聚合成本账。
  ///
  /// 恒 `null` 除非编了 `--dart-define=SSZ_PAGE_COST_TRACE=true`
  /// （`kPageCostTrace` 是编译期常量 ⇒ 正式包里这三处调用会被整段折叠掉）。
  /// 判定完就删 —— 见文件头「临时埋点」那段。
  PageCostTrace? _pageCost;

  /// **账面数量 / 成本 / 是否进过货 / 在途**（2026-11-11 裁定「乙」）。
  ///
  /// **必须与 [\_stockTop] 同一个口径：在 `initState` 算一次，不进 `build`。**
  ///
  /// ## 为什么改（数据，不是估计）
  ///
  /// 0.7.7 的 `frame-cost.jsonl` 实测：`build` 的 **p99 = 100–378 ms**，
  /// 而 `raster` p99 只有 5–55 ms，`build` p50 仅 0.2 ms
  /// ⇒ **卡帧源是少数几次 `build`，不是 GPU**。
  /// `page-cost.jsonl` 对得上：`perBuild:[[59, 65, 115]]`
  /// （重建时聚合 65 ms + 在途 115 ms = 180 ms）。
  ///
  /// ⚠️ 2026-11-10 曾用「聚合累计占停留时间 1.1%」否掉这个改法 ——
  /// **那个算法是错的**：体感看单帧峰值，不看时间占比。
  ///
  /// ## 为什么安全
  ///
  /// 与 [\_stockTop] 同一条刷新链：两壳切页都会重建本页
  /// （`appShellPage` / `_pageFor` 每次 build 新建 widget）⇒ `initState` 重跑
  /// ⇒ 切走再切回来就是最新值。
  ///
  /// ⚠️ **但本页有四处 `setState` 是「数据可能变了」的刷新点**
  /// （期初完成后 / 从流水页返回 / 从单据详情返回），它们原本靠「每次 build 重算」
  /// 生效。改成 `initState` 后**必须显式调 [\_loadAggregates]**，
  /// 否则数字会停在上一次的值 —— 见那四处的注释。
  late Map<String, int> _book;
  late Map<String, int> _cost;
  late Set<String> _inbound;
  late Map<String, int> _inTransit;
  late bool _hasAnyLedger;

  /// 重算账面 / 成本 / 是否进过货 / 在途（**同步**，与 `stockTop` 同口径）。
  ///
  /// `initState` 调一次；四个「数据可能变了」的刷新点各调一次。
  /// **不进 `build`** —— 那是 2026-11-11 裁定「乙」要解决的事（见字段注释）。
  void _loadAggregates() {
    // RULE-006：没有余额表，账面只能每次从流水算。
    // 4c-2（2026-10-24，§5.2 #3）：账面 / 成本 / 是否进过货 **一次扫完**
    // （从前是三次全表聚合：30 万行 × 3）。
    // ⚠️ 埋点的 Stopwatch 只在开关打开时才建（编译期常量，关着时整段被折叠）。
    final Stopwatch? aggWatch = kPageCostTrace ? (Stopwatch()..start()) : null;
    final Map<String, StockAgg> agg = widget.queries.stockAggregates();
    aggWatch?.stop();
    _pageCost?.aggregates(aggWatch?.elapsedMicroseconds ?? 0);
    _agg = agg;
    _book = <String, int>{
      for (final MapEntry<String, StockAgg> e in agg.entries)
        e.key: e.value.quantity,
    };
    _cost = <String, int>{
      for (final MapEntry<String, StockAgg> e in agg.entries)
        e.key: e.value.cost,
    };
    _inbound = <String>{
      for (final MapEntry<String, StockAgg> e in agg.entries)
        if (e.value.hasInbound) e.key,
    };
    final Stopwatch? transitWatch = kPageCostTrace
        ? (Stopwatch()..start())
        : null;
    _inTransit = widget.queries.inTransitByProduct();
    transitWatch?.stop();
    _pageCost?.inTransit(transitWatch?.elapsedMicroseconds ?? 0);
    _hasAnyLedger = agg.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    // ⚠️ 必须早于 `stockTop()`：体感的起点是「点下导航」，不是第一次 build。
    _pageCost = kPageCostTrace
        ? PageCostTrace(
            page: 'stock',
            file: PageCostTrace.fileFor(widget.queries.db.path),
          )
        : null;
    _stockTop = widget.queries.stockTop();
    _loadAggregates();
  }

  /// **父级重建时重算**（切页回来 / 壳层刷新）。
  ///
  /// ## 为什么是 `didUpdateWidget` 而不是 `build`
  ///
  /// Flutter 的两条路径必须分开看：
  ///
  /// | 触发 | 走哪 | 数据会不会变 |
  /// |---|---|---|
  /// | 本页 `setState`（搜索 / 展开压货榜 / 切换筛选） | **只走 `build`** | **不会** |
  /// | 父级重建（切页回来 / 壳层换 widget） | `didUpdateWidget` **再** `build` | **会** |
  ///
  /// 所以放在这里：`setState` 那十几次重建**一次都不重算**（这正是 2026-11-11 裁定「乙」
  /// 要省掉的部分 —— `page-cost.jsonl` 实测一次进入重建 1–11 次、每次聚合 ~180 ms），
  /// 而切页回来照样拿到最新数字。
  ///
  /// ⚠️ **只放 `initState` 是不够的**：`initState` 只在 State **首次插入**时执行，
  /// 后续重建不会重跑。2026-11-11 第一版就是只放了 `initState`，
  /// 被 `test/stock_page_test.dart` 的两条用例当场抓住
  /// （「期初录入过 → 成本列待校准」/「三档颜色」——它们用 `pumpWidget` 重建来模拟切页）。
  @override
  void didUpdateWidget(StockPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadAggregates();
  }

  /// 一个商品是否匹配当前搜索词 —— **按 `_searchField` 决定在哪儿找**。
  ///
  /// 抽成方法而不是内联进 `build`：字段一多，内联的那串 `||` 就没法读了，
  /// 而且 `_searchField` 的分支散在表达式里很难看清「全部」到底包含哪几路。
  bool _matchesSearch(Product p) {
    final String q = _searchText;
    return switch (_searchField) {
      StockSearchField.name => p.name.contains(q),
      StockSearchField.code => p.code.contains(q),
      StockSearchField.barcode => (p.barcode ?? '').contains(q),
      // 「全部」= 与加这个开关之前**逐字一致**的三路
      _ =>
        p.name.contains(q) ||
            p.code.contains(q) ||
            (p.barcode ?? '').contains(q),
    };
  }

  /// 当前「在哪儿找」的中文名（给空态文案用）。
  String _searchFieldLabel() => switch (_searchField) {
    StockSearchField.name => '商品名',
    StockSearchField.code => '编码',
    StockSearchField.barcode => '条码',
    _ => '全部',
  };

  /// 搜索框下面那一排「在哪儿找」。**搜索词为空时不显示** ——
  /// 日常不搜索时它不该占地方（中老年用户的屏幕本来就不宽裕）。
  Widget? _searchFieldChips() {
    if (_searchText.isEmpty) return null;
    return SearchFieldChips(
      keyPrefix: 'stock-search-field',
      options: const <SearchFieldOption>[
        SearchFieldOption(StockSearchField.all, '全部'),
        SearchFieldOption(StockSearchField.name, '商品名'),
        SearchFieldOption(StockSearchField.code, '编码'),
        SearchFieldOption(StockSearchField.barcode, '条码'),
      ],
      selectedId: _searchField,
      onChanged: (String id) => setState(() => _searchField = id),
    );
  }

  @override
  void dispose() {
    _query.dispose();
    // 埋点只在**退出时**落盘：计数期间不碰磁盘，免得给被测量的那段加 I/O 噪声
    final PageCostTrace? trace = _pageCost;
    if (trace != null) unawaited(trace.finish());
    super.dispose();
  }

  /// 两张榜的摆放（提案 61 §四 决策 3 甲）。
  ///
  /// | 条件 | 布局 |
  /// |---|---|
  /// | 宽屏 | **并排**（缺货在前、压货在后），各占一半 |
  /// | 窄屏 / 大字号 | **上下叠**（缺货在上） |
  ///
  /// 断点**随缩放派生**（`scaled.dart` 的 `twoColumnBase`）：200% 字号下
  /// 1440 逻辑像素也只装得下一张卡；写死断点会让两张卡互相挤压
  /// （§CV·八十五 那批的教训）。
  Widget _boards(ThemeData theme, ShortageSummary lowStock) {
    final bool showLow = lowStock.isVisible;
    final bool showTop = !_stockTop.isEmpty;
    if (!showLow && !showTop) return const SizedBox.shrink();

    final Widget low = showLow
        ? _lowStockBlock(theme, lowStock)
        : const SizedBox.shrink();
    final Widget top = showTop
        ? _stockTopBlock(theme)
        : const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool twoUp = !isNarrowOf(
            context,
            constraints.maxWidth,
            base: twoColumnBase,
          );
          if (!showLow || !showTop) return showLow ? low : top;
          if (!twoUp) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[low, const SizedBox(height: 12), top],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: low),
              const SizedBox(width: 12),
              Expanded(child: top),
            ],
          );
        },
      ),
    );
  }

  /// 缺货榜的两种形态：**一行摘要（默认收起）** 或完整卡。
  ///
  /// ⚠️ 引导卡与「暂时都不缺」**永远展开** —— 它们只有两三行，不挤搜索框，
  /// 而且正是新用户（决策 4）需要看见的那句话；藏在一次点击后面等于没做。
  Widget _lowStockBlock(ThemeData theme, ShortageSummary summary) {
    final bool alwaysExpanded = summary.showGuide || !summary.hasAny;
    if (alwaysExpanded || _showLowAll) {
      return Column(
        key: const Key('low-stock-expanded'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LowStockCard(summary: summary, mobileShell: widget.mobileShell),
          if (summary.hasAny)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('low-stock-collapse'),
                onPressed: () => setState(() => _showLowAll = false),
                icon: const Icon(Icons.expand_less, size: 18),
                label: const Text('收起缺货榜'),
              ),
            ),
        ],
      );
    }
    return _lowStockSummaryRow(theme, summary);
  }

  /// 收起状态的缺货榜：**一行摘要 + 展开**（与压货榜同款，不画横条）。
  Widget _lowStockSummaryRow(ThemeData theme, ShortageSummary summary) {
    return OutlinedButton(
      key: const Key('low-stock-expand'),
      onPressed: () => setState(() => _showLowAll = true),
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.expand_more, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '缺货 / 超卖：${summary.totalCount} 个商品',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '超卖 ${summary.oversoldCount} 个 · 该补货 ${summary.restockCount} 个，点开看是哪些',
            style: TextStyle(
              height: 1.6,
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
    );
  }

  /// 压货榜的两种形态：**一行摘要（默认收起）** 或完整卡。
  ///
  /// 2026-11-01（用户裁定 A1）：完整压货榜从概览页搬到这里，放最上面是有意的 ——
  /// 概览那个「查看全部」按钮跳过来时，「跳到库存页顶部」就等于「定位到压货榜」。
  ///
  /// ⚠️ 但**默认收起**（2026-11-01 真机，用户当场指出）：10 行榜展开时有半屏高，
  /// 把**搜索框挤到了它下面** —— 而库存页 95% 的用法是「搜一个商品看还有多少」，
  /// 搜索框必须留在第一屏。收起后只剩一行摘要，「定位到压货榜」仍然成立
  ///（那一行就是榜），要细节点一下展开。
  Widget _stockTopBlock(ThemeData theme) {
    // ⚠️ `_stockTop.isEmpty` 是「行 + 待校准 + 负成本」三者皆空，
    // 所以「非空但一行都没有」（只有待校准/负成本计数）是可能的 ——
    // 那种情况收起状态没有第一名可写，直接展开完整卡。
    if (_showTopAll || _stockTop.rows.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          StockTopCard(summary: _stockTop, mobileShell: widget.mobileShell),
          if (_stockTop.rows.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('stock-top-collapse'),
                onPressed: () => setState(() => _showTopAll = false),
                icon: const Icon(Icons.expand_less, size: 18),
                label: const Text('收起压货榜'),
              ),
            ),
        ],
      );
    }
    return _stockTopSummaryRow(theme);
  }

  /// 收起状态的压货榜：**一行摘要 + 展开**。
  ///
  /// 只放数字与第一名，不画横条 —— 这不是「第二份图表渲染」（那种必然漂移），
  /// 只是一句摘要。完整榜仍然只有 `StockTopCard` 一份实现。
  Widget _stockTopSummaryRow(ThemeData theme) {
    final StockValueRow first = _stockTop.rows.first;
    final int count = _stockTop.rows.length;
    return OutlinedButton(
      key: const Key('stock-top-expand'),
      onPressed: () => setState(() => _showTopAll = true),
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.expand_more, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '压货最多的 $count 个商品',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              Text(
                '最多 ${_yuan(first.valueCents)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${first.name} · 按占用资金排，点开看全部',
            style: TextStyle(
              height: 1.6,
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
    );
  }

  /// 分 → `¥1,234.56`（与榜上的写法一致）
  static String _yuan(int cents) {
    final String sign = cents < 0 ? '-' : '';
    final int abs = cents.abs();
    return '$sign¥${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  }

  /// **#27 批 2（裁定乙）**：库存页快速建档 —— 手机壳走 `masterDataSink`
  /// （乐观写镜像 + 入队），对话框 `allowOpeningStock: true`（#31 建档带期初，
  /// 库存页正是「建完看数量」的场景）。桌面无此入口（商品页/期初页）。
  Future<void> _createProduct(BuildContext context) async {
    final Product? created = await showProductFormDialog(
      context,
      service: widget.products,
      sink: widget.masterDataSink!,
      allowOpeningStock: true,
    );
    if (created == null || !mounted) return;
    // ⚠️ 必须重算聚合：新商品可能带期初（`openingPending`），账面数字要跟着变。
    setState(_loadAggregates); // 新行可见（零流水也显示 —— openingPending 在场）
  }

  /// **#27 批 2**：打开某商品的流水页。桌面行可点 ⇒ 跳单据详情
  ///（settlements 缺省时降级不可点）；手机壳行不可点 + 灰字明说（裁定⑤）。
  Future<void> _openStockFlow(BuildContext context, Product product) async {
    final StockLedgerDao? flowDao = widget.stockFlow;
    if (flowDao == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => StockFlowPage(
          product: product,
          flowDao: flowDao,
          exports: widget.exports,
          mobileShell: widget.mobileShell,
          onOpenDocument: widget.mobileShell || widget.settlements == null
              ? null
              : (BuildContext context, String documentId) async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) => DocumentDetailPage(
                        documentId: documentId,
                        settlements: widget.settlements!,
                        products: widget.products,
                        // ⚠️ 2026-11-11 补：漏了这条，送货单在详情页里
                        // 就只有一个「签收入口暂时用不了」的灰字（真机截图为证）。
                        deliveries: widget.deliveries,
                      ),
                    ),
                  );
                  // ⚠️ 重算：签收 / 收款会改库存与在途，不能只重绘。
                  if (mounted) setState(_loadAggregates); // 回来库存可能变过（签收等）
                },
        ),
      ),
    );
    // ⚠️ 重算：流水页里可能做了签收 / 退货。
    if (mounted) setState(_loadAggregates);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // 临时埋点（甲）：数「一次进入重建了几次」。必须在任何聚合之前记。
    _pageCost?.build();

    // 账面 / 成本 / 是否进过货 / 在途 **都在 `initState` 算过了**
    // （2026-11-11 裁定「乙」，依据见字段注释：build p99 100–378 ms 的卡帧源）。
    // 这里只取别名 —— 本方法后面有十几处引用这几个名字，加 `_` 前缀纯属噪声。
    final Map<String, int> book = _book;
    final Map<String, int> cost = _cost;
    final Set<String> inbound = _inbound;
    final Map<String, int> inTransit = _inTransit;
    final bool hasAnyLedger = _hasAnyLedger;

    // 2026-10-31（裁定 A 第一阶段，降级只读）：手机壳**没有提交出口**时不给清点
    // 入口 —— 清点单走单据队列，没有 sink 就只会写进镜像、永远到不了电脑
    // （用户看到「清点成功」而主机上没有这张单，比没有入口糟得多）。
    // 2026-11-01：只读降级（低权限 / 本机账本打不开）时不给清点入口。
    //
    // 判据分两种壳：
    // - 手机壳：清点单走单据队列，**必须有 `documentSink`**（否则只写镜像、到不了电脑）；
    // - 桌面：走 `StocktakeService` 直接落库，本来不需要 sink ⇒ 看 `canWrite`。
    // 从前只判手机壳，桌面在只读态下会漏掉这条写入口。
    final bool canStocktake =
        widget.canWrite && (!widget.mobileShell || widget.documentSink != null);

    // §AD 遗漏 2：期初录入入口（就地打开，完成后 setState 刷新数字）
    if (_showOpening) {
      // ⚠️ 期初录入当前**只在主机开放**（§CV·七 缺口 2，2026-10-09）。
      //
      // 2026-10-20（§CV·七十八）：**手机上也能清点了** —— 裁定「走 stocktake 单据」
      // （§CV·七 缺口 2 的 A 案）：清点单走**单据队列**，差额由主机算，客户端零规则。
      //
      // ⇒ 这道门拦「**手机壳但没装配 documentSink**」：那意味着写进镜像就到不了电脑。
      //
      // 2026-10-31（裁定 A 第一阶段，降级只读）：这个组合**变成了合法状态**
      // —— 本机账本打不开时提交出口全部摘掉。所以原来的 `assert` 换成
      // 上面的 `canStocktake` 判据（入口直接不显示），不然调试包里点一下就抛。
      return OpeningStockPage(
        service: StocktakeService(
          engine: widget.engine,
          queries: widget.queries,
        ),
        productService: widget.products,
        // 期初里的「新建商品」：桌面走主机落库；手机壳本页被「重新清点」放开，
        // 所以这里两种壳都要给（§CV·七十八）——手机 = `QueueMasterSink`。
        masterDataSink:
            widget.masterDataSink ?? ServiceMasterSink(widget.products),
        // 2026-10-20（§CV·七十八）：**盘点单的出口**。手机 = `QueueSink`
        //（入队 + 立即推，差额由主机算）；桌面 / 未装配 = null ⇒ 走 [service]。
        documentSink: widget.documentSink,
        isFirstTime: !hasAnyLedger,
        bookQuantities: book,
        onDone: () => setState(() {
          _showOpening = false;
          // ⚠️ 期初录入 / 清点都会改流水 ⇒ 必须重算，否则数字停在录入前。
          _loadAggregates();
        }),
        onStorageFailure: widget.onStorageFailure,
      );
    }

    // 商品全集（含停用的？—— 不，库存页只看启用中的商品）
    // ⚠️ 必须用 `listForExport`（不分页）而不是 `list()`（默认 `limit: 200`）：
    // 库存页的**整个列表**都来自这里 —— 用 `list()` 时第 201 个商品在库存页
    // **根本不出现**（2026-10-27 现实用户暴雷，同源问题：商品过 200 个后
    // 「共 N 种」也停在 200）。库存页要的是「全部商品的库存」，不能有上限。
    final List<Product> all = widget.products.listForExport(active: true);

    // C2·§CC 裁定七：库存叠加 —— 一次遍历队列算全部未同步影响，
    // 行内只查 map；点开拆解才逐商品取 contributors（IO 不进常驻路径）
    final Map<String, int> unsyncedByProduct =
        widget.stockDelta?.unsyncedDelta() ?? const <String, int>{};
    // #31（裁定②）：一次 build 取一次（PendingMarks 文档的 N 次 SQL 警告）
    final Map<String, int> openingPending =
        widget.pendingMarks?.openingQuantityByProduct() ??
        const <String, int>{};

    // 缺货榜（提案 61 §五）：**零新增查询** —— 全量商品 + 三张现成 map
    // （`_agg` / 在途 / 未同步）在纯 Dart 里 join，缺失键按 0。
    //
    // ⚠️ 传入的是**全量 `all`**，不是下面那份 `shown` —— 后者已按 `hasFlow`
    // 过滤（只留有流水的），拿它算会把「刚建档、设了安全库存、还没进货」
    // 那类**最紧急**的商品整类漏掉（提案 §三 洞 1）。
    final ShortageSummary lowStock = computeShortage(
      products: all,
      agg: _agg,
      inTransit: inTransit,
      unsynced: unsyncedByProduct,
    );
    // 搜索：按 `_searchField` 决定在哪儿找（默认三路全找）
    final List<Product> matched = _searchText.isEmpty
        ? all
        : all.where((Product p) => _matchesSearch(p)).toList();

    /// 有流水 = 账面 / 在途 / **本地未同步影响** 任一不为 0（遗漏 5 的「有意义的数字」）。
    ///
    /// ⚠️ M14（2026-10-08）：**本地未同步影响也算流水**。手机上刚开的单还没推到
    /// 电脑，权威账面仍是 0 —— 只按权威过滤会把「已经卖了 1 件、估算 −1」的商品
    /// **默认藏起来**，负库存风险反而看不见（报告实测）。
    ///
    /// ⚠️ #31（裁定②，同一条原理）：**带了期初的待同步建档也算** —— 用户刚填了
    /// 「当前库存 10」，列表里却找不到这个商品，只会以为没建成。
    bool hasFlow(Product product) =>
        (book[product.id] ?? 0) != 0 ||
        (inTransit[product.id] ?? 0) != 0 ||
        (unsyncedByProduct[product.id] ?? 0) != 0 ||
        openingPending.containsKey(product.id);

    final List<Product> shown = _showAll
        ? matched
        : matched.where(hasFlow).toList();
    // 遗漏 4：按在店可售降序（浏览页，不是查找页）
    // F17-b 甲：排序必须与**大字**同口径 —— 否则「显示 3 的排在显示 5 的前面」
    int inStore(Product product) => effectiveInStoreOf(
      book: book[product.id] ?? 0,
      unsynced: unsyncedByProduct[product.id] ?? 0,
      inTransit: inTransit[product.id] ?? 0,
    );
    shown.sort((Product a, Product b) => inStore(b).compareTo(inStore(a)));

    final int hiddenCount = matched.length - shown.length;

    // ⚠️ **列表懒加载**（2026-11-09，与单据页同款）：从前
    // `SingleChildScrollView + Column(for … 全部商品)` 一次性 build 全部行。
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // §BH·六 B1c·补（2026-10-04 真机反馈：超大字号下标题被按钮挤成竖排）：
                    // 换 Wrap —— 宽屏 spaceBetween 与原右对齐一致，窄屏自动换行
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        // §AD 遗漏 2：入口按钮（文案按首次 / 再次区分）
                        Text('库存', style: theme.textTheme.titleLarge),
                        if (widget.exports != null)
                          ExportButton(
                            key: const Key('export-stock'),
                            // AF-2：说清导的是「有流水或有库存」的那批
                            label: '导出库存',
                            export: () => widget.exports!.write(
                              stockExportTable(
                                // AF-12：**含停用** —— 停用但有库存的商品也要能对账
                                //（页面上看不到它们，但导出的账里不能少）
                                products: widget.products.listForExport(),
                                book: book,
                                inTransit: inTransit,
                                cost: cost,
                              ),
                            ),
                          ),
                        if (canStocktake)
                          TextButton.icon(
                            key: const Key('stock-open-entry'),
                            // 2026-10-20（§CV·七十八）：手机端**也能清点** —— 清点单走
                            // 单据通道入队，差额由主机算（客户端零规则）。原引导删除。
                            //
                            // 2026-10-31：只读降级时**整个入口不显示**（见 `canStocktake`）
                            onPressed: () =>
                                setState(() => _showOpening = true),
                            icon: const Icon(
                              Icons.inventory_2_outlined,
                              size: 18,
                            ),
                            label: Text(hasAnyLedger ? '重新清点' : '录入现有货物'),
                          ),
                        // #27 批 2（2026-10-17 裁定乙）：库存页的「新建商品」= **补充
                        // 快速建档入口**（手机壳专属；桌面建档在「商品」页，期初在同页
                        // 「录入现有货物」）。手机壳 ⇒ 对话框带「当前库存」字段（#31
                        // stocktake 通路）。桌面不显示 ⇒ 不存在「桌面带库存走什么通路」。
                        if (widget.mobileShell &&
                            widget.canCreateProducts &&
                            widget.masterDataSink != null)
                          OutlinedButton.icon(
                            key: const Key('stock-create-product'),
                            onPressed: () => _createProduct(context),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('新建商品'),
                          ),
                      ],
                    ),

                    // 两张榜（提案 61 §四 决策 3 甲）：**缺货榜在前、压货榜在后**，
                    // 宽屏并排、窄屏（或大字号）上下叠。缺货要行动，压货只是知晓 ——
                    // 目标用户的注意力在上面。
                    _boards(theme, lowStock),
                    const SizedBox(height: 4),
                    Text(
                      '「在店可售」= 账面库存 − 送货在途；低库存按它判断。',
                      style: TextStyle(
                        height: 1.6,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 批 3 第 16 条：换成共用列表头（补 × 清空 + 真实总数 + 防抖）
                    ListHeader(
                      searchKey: const Key('stock-search'),
                      controller: _query,
                      hintText: '商品名 / 编码 / 条码（可扫码）',
                      onQueryChanged: (String q) => setState(() {
                        _searchText = q.trim();
                        // 搜索词清空 ⇒ 「在哪儿找」也回到「全部」。
                        // 否则下次搜索还停在「条码」上，用户会以为搜不到货。
                        if (_searchText.isEmpty) {
                          _searchField = StockSearchField.all;
                        }
                      }),
                      // 2026-11-11：搜索时可选「在哪儿找」（全部 / 商品名 / 编码 / 条码）
                      leading: _searchFieldChips(),
                      countText: _searchText.isEmpty
                          ? '共 ${all.length} 个商品'
                          : '找到 ${matched.length} 个 / 共 ${all.length} 个',
                    ),
                    const SizedBox(height: 4),
                    // 遗漏 5：默认隐藏零流水商品，开关让「建了还没进货」的也能看。
                    // 用 CheckboxListTile 而不是 Row(Checkbox+Text) —— **整行可点**：
                    // 用户（和测试）自然会点文字，点文字必须能切换。
                    CheckboxListTile(
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      title: const Text('显示全部（含没进过货的商品）'),
                      // ⚠️ CheckboxListTile 没有 `trailing` 参数（那是 ListTile 的，
                      // 尾部被 checkbox 占了）—— 计数放 subtitle
                      subtitle: hiddenCount > 0
                          ? Text(
                              '已隐藏 $hiddenCount 个',
                              style: TextStyle(
                                height: 1.6,
                                color: theme.textTheme.bodySmall?.color,
                              ),
                            )
                          : null,
                      value: _showAll,
                      onChanged: (bool? value) =>
                          setState(() => _showAll = value ?? false),
                    ),
                    const SizedBox(height: 8),
                    if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Column(
                          children: <Widget>[
                            Text(
                              widget.mobileShell && _searchText.isEmpty
                                  ? mirrorEmptyMessage('库存数字')
                                  : _searchText.isEmpty
                                  ? '还没有库存记录'
                                  // 选了具体字段又没结果 ⇒ 必须说「你只在哪儿找了」，
                                  // 否则用户会以为「店里没这个货」。
                                  // 2026-11-11 真机上就出现过：搜「6」命中全部，
                                  // 反倒是「搜不到」时要解释清楚才安全。
                                  : _searchField == StockSearchField.all
                                  ? '没有匹配的商品。'
                                  : '只在「${_searchFieldLabel()}」里找，没有匹配。'
                                        '\n可以点上面的「全部」再试一次。',
                              textAlign: TextAlign.center,
                              key: const Key('stock-search-empty'),
                              style: TextStyle(
                                height: 1.8,
                                color: theme.hintColor,
                              ),
                            ),
                            // §AD-6：空态两段式 —— 首段给「开店」场景，次段给「日常」场景
                            // （手机端期初录入被引导接管 ⇒ 不展示这段，裁定六的空态文案顶上）
                            if (_searchText.isEmpty &&
                                !widget.mobileShell) ...<Widget>[
                              const SizedBox(height: 8),
                              Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    children: <Widget>[
                                      const Text(
                                        '店里已经有货？',
                                        style: TextStyle(height: 1.8),
                                      ),
                                      Text(
                                        '点右上角的「录入现有货物」，一次记进来',
                                        style: TextStyle(
                                          height: 1.8,
                                          color:
                                              theme.textTheme.bodySmall?.color,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '以后新进的货，走「采购入库」',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  height: 1.8,
                                  color: theme.textTheme.bodySmall?.color,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (shown.isNotEmpty)
              cardRowsSliver(
                key: const Key('stock-rows'),
                itemCount: shown.length,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemBuilder: (BuildContext context, int i) => _StockRow(
                  product: shown[i],
                  book: book[shown[i].id] ?? 0,
                  inTransit: inTransit[shown[i].id] ?? 0,
                  costCents: cost[shown[i].id] ?? 0,
                  everInbound: inbound.contains(shown[i].id),
                  unsynced: unsyncedByProduct[shown[i].id] ?? 0,
                  openingPending: openingPending[shown[i].id],
                  onOpen: widget.stockFlow == null
                      ? null
                      : () => _openStockFlow(context, shown[i]),
                  delta: widget.stockDelta,
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }
}

/// 库存列表里的一行
class _StockRow extends StatelessWidget {
  const _StockRow({
    required this.product,
    required this.book,
    required this.inTransit,
    required this.costCents,
    required this.everInbound,
    this.unsynced = 0,
    this.delta,
    this.openingPending,
    this.onOpen,
  });

  final Product product;
  final int book;
  final int inTransit;
  final int costCents;

  /// 是否有过正数量入库（§AD 遗漏 1：成本列三态的判断依据）
  final bool everInbound;

  /// 未同步影响（C2·§CC 裁定七）。`0` = 不显示叠加行（桌面恒 0）。
  final int unsynced;

  /// 叠加计算器（点开拆解时取 contributors；`null` = 桌面）。
  final StockDelta? delta;

  /// **#31（2026-10-16 裁定②）**：本行的「建档期初待同步」数量。
  /// `null` = 没有期初在队列里（不显示提示行）。
  final int? openingPending;

  /// **#27 批 2**：行 tap = 打开本商品的流水页。`null` = 行不可点
  ///（手机壳 / 流水查询缺省 —— 由页面判定后传入）。
  final VoidCallback? onOpen;

  /// 行内大字（F17-b 甲）。估算态带 `≈` 前缀；挂 `Key` 让测试能按商品定位
  /// （原来只有裸 `Text`，只能按文本找，两个商品同数就分不清）。
  Widget _bigNumber(
    ThemeData theme,
    int value,
    bool approximate,
    Color color,
  ) => Text(
    approximate ? '≈ $value' : '$value',
    key: Key('stock-instore-${product.id}'),
    style: theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: color,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // ⚠️ 局部变量才能提升非空（public 字段判空不提升 —— analyze 实测）
    final StockDelta? delta = this.delta;
    // F17-b 甲：大字 / 判定 / 排序**同一个公式**（`effectiveInStoreOf`）
    final int inStore = effectiveInStoreOf(
      book: book,
      unsynced: unsynced,
      inTransit: inTransit,
    );
    // 这个数字是**估算**吗？两来源：本地有未同步单据（`unsynced`），
    // 或期初录入还没同步（`openingPending` —— stocktake 的 delta 客户端算不出，
    // 见 `stock_delta.dart:39`，所以它进不了 `inStore`，只能靠 `≈` 说明）。
    final bool approximate = unsynced != 0 || openingPending != null;

    // AA-3 三档：负红 / 低橙 / 正常无色。safety_stock = 0 = 不需要告警。
    final int safety = product.safetyStock;
    final bool negative = inStore < 0;
    final bool low = !negative && safety > 0 && inStore <= safety;
    final Color mainColor = negative
        ? theme.colorScheme.error
        : low
        ? AppColors.warningOrange
        : theme.colorScheme.onSurface;
    final String? notice = negative
        ? '已超卖，尽快补货或核对账目'
        : low
        ? '低于安全库存 $safety，该补货了'
        : null;

    // §审查 OBS-12：**没货了却还有成本** —— 这是「先卖后补」的结果
    //（卖的时候账上没货，出库成本按 0 记；后来进的货，进价没被摊出去，
    //  于是数量补回来了、成本还挂在那批卖掉的货上）。
    // 口径没错，但**不解释会被当成 bug**，所以在这里说清它是怎么来的。
    final String? costNotice = (book <= 0 && costCents != 0)
        ? '已无货，仍有成本 ¥${Money.format(costCents)} 没摊出去 —— '
              '先卖后补造成的：卖的时候账上没货，成本按 0 记过一次。'
              '下次进货的进价会把它校准回来。'
        : null;

    // #27 批 2：行 tap = 打开本商品的流水页（onOpen 由页面判定可点性 ——
    // 手机壳 / 流水查询缺省时为 null，行保持不可点）。
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        // §AJ·AI-5：有包装说明时附在名称后 —— 用户看着「144 瓶」
                        // 心算「是几箱」时靠它。纯展示，不参与计算
                        product.packageNote == null
                            ? product.name
                            : '${product.name}（${product.packageNote}）',
                        style: TextStyle(
                          height: 1.6,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${product.code}  ·  安全库存 ${product.safetyStock == 0 ? '未设' : product.safetyStock}',
                        style: TextStyle(
                          height: 1.6,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                      // #31（2026-10-16 裁定②）：同步前用户刚填的期初量在数字上
                      // 不出现（stocktake 的 delta 客户端算不出）⇒ 在这里说清，
                      // 否则「我刚填的 10 件呢？」（技术诚实 ≠ 用户体验）。
                      // ⚠️ 只作提示，**不参与库存计算**。
                      if (openingPending != null)
                        Text(
                          '期初 $openingPending（${product.unit}）待同步',
                          key: Key('opening-pending-${product.id}'),
                          style: TextStyle(height: 1.6, color: theme.hintColor),
                        ),
                    ],
                  ),
                ),
                // AA-2：主列大字加粗
                //
                // F17-b 甲（2026-10-26 裁定）：这个数字**含本地未同步影响**。
                // 手机上离线卖了一件、大字却还写着原来的数 —— 用户会照它继续卖，
                // 直接卖超。所以估算态必须带 `≈`：不标就是在说"这是确定值"。
                // 期初未同步（`openingPending`）也算估算态 —— 那一笔**进不了**
                // 这个数字（stocktake 的 delta 客户端算不出），更要标出来。
                if (openingPending != null)
                  Tooltip(
                    // 只说"为什么是估的、缺了什么"，不解释内部机制
                    message:
                        '期初录入还没传到电脑，这个数字还不含期初的 '
                        '$openingPending（${product.unit}）。',
                    triggerMode: TooltipTriggerMode.tap,
                    showDuration: const Duration(seconds: 4),
                    child: _bigNumber(theme, inStore, approximate, mainColor),
                  )
                else
                  _bigNumber(theme, inStore, approximate, mainColor),
                // 批 3 第 16 条（用户裁定 ③）：**只给「点了会跳走」的行**加箭头。
                // 库存行 tap = 打开流水页；手机壳 / 缺流水查询时 `onOpen` 为 null
                // ⇒ 那一态行不可点，也就不加箭头（箭头是承诺，不能撒谎）。
                if (onOpen != null) const RowChevron(),
              ],
            ),
            const SizedBox(height: 4),
            // C3·真机反馈：成本行原为 Row + Spacer —— 窄屏 / 大字档下
            // 「成本（均价）+ 金额」固定组溢出。改 Wrap + spaceBetween：
            // 宽屏两项两端对齐（视觉同旧）；放不下自动换行，永不溢出。
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              spacing: 8,
              runSpacing: 2,
              children: <Widget>[
                Text(
                  '账面 $book · 在途 $inTransit',
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
                // F6（2026-10-26 复跑）：**标签与它的金额必须是一组**。
                // 从前它们是外层 Wrap 的两个子项（中间还夹一个 `SizedBox(width: 4)`），
                // 而外层用 `spaceBetween` —— 空档被塞进每一对相邻子项之间，于是
                // 「成本（均价）」与「¥3.50」被拉到两端（实测间距 239.75 px），
                // 读起来像这个标签在管别的东西。
                // ⇒ 收成内层 `Wrap`：不撑满、放不下自动换行（超大档也不溢出）。
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 2,
                  children: <Widget>[
                    // AA-4：成本（均价）+ 口径说明；负值红色（与负库存联动）
                    Tooltip(
                      message: '按历史加权平均成本计算。\n进价变化时可能与最近一次进价不同。',
                      triggerMode: TooltipTriggerMode.tap,
                      showDuration: const Duration(seconds: 4),
                      // Q5 点击区（用户裁定 ③甲）：Tooltip 的触发面 = child 的边界。
                      // 原先裸 Row 只有约 22px 高（14px 图标 + 1.6 行高），点不中
                      // 就等于「口径说明不存在」。SizedBox(44) + Center：
                      // 视觉不变（行仍居中），点击区达标（`ui_principles.md` §二 44×44）。
                      child: SizedBox(
                        key: const Key('stock-cost-info'),
                        height: 44,
                        // ⚠️ `widthFactor: 1` 是 F6 的关键：裸 `Center` 会**撑满**
                        // 可用宽度（`Align` 无 widthFactor 时取最大约束），于是这个
                        // "44 高的点击区"实际占满整行 —— 标签被居中、金额被挤到
                        // 下一行，读起来就是「成本（均价）在管别的东西」。
                        // 加 widthFactor 后宽度 = 内容宽，44 的点击高度不变。
                        child: Center(
                          widthFactor: 1,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                '成本（均价）',
                                style: TextStyle(
                                  height: 1.6,
                                  color: theme.textTheme.bodySmall?.color,
                                ),
                              ),
                              const SizedBox(width: 2),
                              Icon(
                                Icons.info_outline,
                                size: 14,
                                color: theme.textTheme.bodySmall?.color,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // §AD 遗漏 1：成本三态 —— 「¥0.00」会让首次使用的用户
                    // 以为软件坏了；「待校准」说清了「为什么是 0、什么时候会变」
                    if (!everInbound)
                      Text(
                        '未进货',
                        style: TextStyle(
                          height: 1.6,
                          fontWeight: FontWeight.w600,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      )
                    else if (costCents == 0)
                      Tooltip(
                        message: '期初录入未记成本。\n下次采购时进价会校准成本。',
                        triggerMode: TooltipTriggerMode.tap,
                        showDuration: const Duration(seconds: 4),
                        child: Text(
                          '待校准',
                          style: TextStyle(
                            height: 1.6,
                            fontWeight: FontWeight.w600,
                            color: theme.textTheme.bodySmall?.color,
                          ),
                        ),
                      )
                    else if (book > 0)
                      // 业务审查 §4.2（用户裁定 ③乙）：主数字是**均价**。
                      // 旧显示把「成本余值」（总额）当均价 —— 10 件 × ¥3.50 的货
                      // 显示「¥35.00」，用户会以为一件成本 35 元，**直接误导定价**。
                      // 均价 = 余值 ÷ 在店可售（round-half-up，与成本分摊同口径）；
                      // 总额不丢，降为小字补充。
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            '¥ ${Money.format(Money.divideRoundHalfUp(costCents, book))}',
                            style: TextStyle(
                              height: 1.6,
                              fontWeight: FontWeight.w600,
                              color: costCents < 0
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            '共 ¥ ${Money.format(costCents)}',
                            style: TextStyle(
                              height: 1.6,
                              fontSize: 11,
                              color: theme.textTheme.bodySmall?.color,
                            ),
                          ),
                        ],
                      )
                    else
                      // 没货 / 负库存：均价无意义（除不动），只显示总额
                      // （下方 costNotice 会解释「已无货仍有成本」）
                      Text(
                        '¥ ${Money.format(costCents)}',
                        style: TextStyle(
                          height: 1.6,
                          fontWeight: FontWeight.w600,
                          color: costCents < 0
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            if (notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    notice,
                    style: TextStyle(height: 1.6, color: mainColor),
                  ),
                ),
              ),
            if (costNotice != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    costNotice,
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ),
              ),
            // C2·§CC 裁定七：未同步叠加 —— 橙「≈」/ 负数红 +「可能负库存」；
            // 行内展开拆解（不打断浏览 —— 裁定七之 2）
            if (unsynced != 0 && delta != null)
              _StockDeltaLine(
                delta: delta,
                productId: product.id,
                book: book,
                unsynced: unsynced,
                // F17-b 甲：这一行的合计必须**等于大字**（大字已含 − 在途）
                inTransit: inTransit,
              ),
          ],
        ),
      ),
    );
  }
}

/// 未同步叠加行（C2·§CC 裁定七）—— 「≈ 台账 + 未同步 = 合计」，
/// 点开**行内**展开是哪几张单贡献的（`contributors`，core 已备）。
///
/// 颜色（裁定七之 1）：合计 ≥ 0 橙（未同步估算的语义色）；
/// 合计 < 0 红 +「可能负库存」（与负库存告警同色 —— 两个语义叠加时取更严重的）。
class _StockDeltaLine extends StatefulWidget {
  const _StockDeltaLine({
    required this.delta,
    required this.productId,
    required this.book,
    required this.unsynced,
    required this.inTransit,
  });

  final StockDelta delta;
  final String productId;
  final int book;
  final int unsynced;

  /// **F17-b 甲**：这一行要写出**完整**算式。
  ///
  /// 旧文案是「台账 + 未同步 = 合计」，**没减在途** —— 而大字（甲之后）减了。
  /// 于是同一行里大字 34、叠加行算 36，两个数字对不上 —— 比不显示更糟。
  /// 所以这里必须与 [effectiveInStoreOf] 同口径。
  final int inTransit;

  @override
  State<_StockDeltaLine> createState() => _StockDeltaLineState();
}

class _StockDeltaLineState extends State<_StockDeltaLine> {
  bool _expanded = false;

  static String _signed(int value) => value >= 0 ? '+$value' : '$value';

  static String _docNoOf(SyncQueueEntry entry) {
    final Object? document = entry.payload['document'];
    if (document is Map) {
      final Object? docNo = document['doc_no'];
      if (docNo is String && docNo.isNotEmpty) return docNo;
    }
    return '待同步单据';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // F17-b 甲：与大字**同一个公式**（含 − 在途），否则同一行两个数字对不上
    final int estimated = effectiveInStoreOf(
      book: widget.book,
      unsynced: widget.unsynced,
      inTransit: widget.inTransit,
    );
    final Color color = estimated < 0
        ? theme.colorScheme.error
        : AppColors.warningOrange;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                // 完整算式（F17-b 甲）：有在途才写那一段，否则是噪音
                '≈ 台账 ${widget.book} + 未同步 ${_signed(widget.unsynced)}'
                '${widget.inTransit != 0 ? ' − 在途 ${widget.inTransit}' : ''} '
                '= ${_signed(estimated)}'
                '${estimated < 0 ? '（可能负库存）' : ''} —— 点看是哪几张单',
                style: TextStyle(height: 1.6, color: color),
              ),
              if (_expanded)
                for (final SyncQueueEntry entry
                    in widget.delta.stockViewOf(widget.productId).contributors)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, left: 8),
                    child: Text(
                      '${_docNoOf(entry)}   '
                      '${_signed(StockDelta.deltaOf(entry)[widget.productId] ?? 0)} 件',
                      style: TextStyle(
                        height: 1.6,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 库存页搜索的「在哪儿找」取值（2026-11-11 用户裁定：做成可选过滤项）。
///
/// 用 `const String` 而不是 `enum`：值与 [SearchFieldOption.id] 直接对应，
/// 省一层 `enum.name` 转换；而且这四个串会出现在测试的 Key 里
/// （`stock-search-field-name` 这种），用 enum 反而要多写转换。
class StockSearchField {
  const StockSearchField._();

  /// 三路一起找 —— **与加这个开关之前逐字一致**（默认值）。
  static const String all = 'all';
  static const String name = 'name';
  static const String code = 'code';
  static const String barcode = 'barcode';
}
