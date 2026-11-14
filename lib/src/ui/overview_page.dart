/// 概览页 —— 回答三个问题：**我的数据在哪**、**现在能不能用**、**数据安全吗**。
///
/// 这是落地页（左侧导航第一项）。刻意不塞业务数字：等核心闭环做完，
/// 这里才放「今日销售 / 库存告急 / 欠款」这类聚合（RULE-006 的查询已就绪）。
///
/// ## 裁定落点（`docs/reply_review.md` §AE-3 / §AE-5）
///
/// - **橙卡**（AE-3 的「两层机制」上层）：单次备份失败**静默**，但
///   「超过 3 天没成功备份」必须在**用户不会主动打开设置页**的地方说出来 ——
///   概览页原本就是启动落地页，它有这个位置优势。
/// - **文案与判定都来自纯 Dart**（`backupReminderText`）：这里只负责摆，
///   不造句、不算天数（`docs/ui_principles.md` §二）。
/// - **按钮防抖**（遗漏 11）：点下去立刻禁用 +「备份中…」—— 用户要确信
///   「我的操作被接受了」；服务侧的单飞是兜底，不是替代。
library;

import 'dart:io' show Process;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'balance_bars.dart';
import 'gross_margin_chart.dart';
import 'low_stock_card.dart';
import 'month_compare.dart';
import 'notice.dart';
import 'revenue_chart.dart';
import 'shortage.dart';
import 'stock_top.dart';
import 'paint_first.dart';

/// 概览页一次算好的全部数字（`_OverviewPageState._load` 产出、缓存复用）。
class _OverviewData {
  const _OverviewData({
    required this.today,
    required this.receivables,
    required this.payables,
    required this.stockTop,
    required this.revenueRows,
    required this.marginRows,
    required this.monthCompare,
    required this.fromDay,
    required this.toDay,
  });

  final OverviewSummary today;
  final ReceivablesSummary receivables;
  final PayablesSummary payables;
  final StockTopSummary stockTop;

  /// 按日营收（**可能含 30 天窗口外的天** —— 月度对比要上月同期；
  /// 营收卡自己按窗口裁）
  final List<RevenueDay> revenueRows;

  /// 按日毛利分项（N-a）。**只查 30 天窗口**，不像营收那样查宽 ——
  /// 毛利没有「月度对比」的需求，多查是白扫表。
  final List<GrossMarginDay> marginRows;

  /// 本月至今 vs 上月同期
  final MonthCompare monthCompare;

  final int fromDay;
  final int toDay;
}

/// 提醒橙 —— **不用错误红**（可以不拦人的提醒一律橙色，
/// `docs/ui_principles.md` §1.3；与 `product_form_dialog.dart` 的内联提示同色）
const Color _noticeColor = Color(0xFFB45309);
const Color _noticeBackground = Color(0xFFFFF7ED);

class OverviewPage extends StatefulWidget {
  const OverviewPage({
    super.key,
    required this.dataDirectory,
    this.remoteVersion = 0,
    required this.backupDirectory,
    required this.schemaVersion,
    required this.databaseReady,
    this.shopName,
    this.backupReminder,
    this.onBackupNow,
    this.locationNote,
    this.mobileShell = false,
    this.queries,
    this.products,
    this.stockDelta,
    this.pendingMarks,
    this.onNavigate,
    this.onPriceLookup,
    this.monthComparePercent = false,
  });

  /// 数据目录（用户选的，数据库就放在这里）
  final String dataDirectory;

  /// 备份目录（数据目录的**兄弟目录**，见 `docs/data_directory.md` §八）
  final String backupDirectory;

  final int schemaVersion;

  /// 数据库是否已成功打开
  final bool databaseReady;

  /// 主机落库版本号（手机推上来单据 ⇒ 变了就重算，见 `app_shell.dart`）
  final int remoteVersion;

  /// 店名（设置页采集；空则显示「概览」，SC-2）
  final String? shopName;

  /// 月度对比用百分数（`+595%`）而不是倍数（`6.9 倍`）——
  /// 设置页可切，默认倍数
  final bool monthComparePercent;

  /// 备份提醒文案（`null` = 不需要提醒 → 不显示橙卡）。
  /// 由 `shensuanzi_app` 的 `backupReminderText` 给出 —— 与设置页红字同源
  final String? backupReminder;

  /// 「立即备份」；`null` = 备份不可用（库还没打开）→ 不显示按钮
  final Future<BackupOutcome> Function()? onBackupNow;

  /// **#32（2026-10-17 裁定甲）**：聚合查询（手机壳 = 镜像实例化，与
  /// stock_page 同源 —— app.dart 装配）。`null` = 不显示经营卡（库未开）。
  final QueryDao? queries;

  /// **提案 61**：缺货榜的商品全集（`listForExport(active: true)`）。
  ///
  /// ⚠️ 必须**不分页**：概览页要算出「第 201 个商品也缺货」，
  /// `findAll()` 默认 `limit: 200` 会让它静默消失（2026-10-27 同源事故）。
  /// `null` = 不显示缺货榜（库未开 / 测试不传）。
  final ProductService? products;

  /// **提案 61 决策 61-⑥**：本地未同步影响（手机壳才有；桌面 `null`）。
  ///
  /// 库存页早就在用它（「在店可售」），概览页从前没有 ⇒ 同一台手机上
  /// 「库存页说缺货、概览页说不缺」，同一个指标两套公式。
  final StockDelta? stockDelta;

  /// **#32（裁定④）**：手机壳「有 N 条未同步」的数据源（诚实口径 ——
  /// 镜像算不出未同步的金额，只如实报条数）。`null` = 不显示该行。
  final PendingMarks? pendingMarks;

  /// **#32（裁定③：快捷入口 = 高频动作）**：跳转回调（销售开单 / 采购入库 /
  /// 送货）。`null` = 不显示入口卡（测试/独立预览）。
  final void Function(String destinationId)? onNavigate;

  /// **查价**入口（真实诉求批 ③，2026-10-24，§CV·一百零四）。
  ///
  /// 家人（和替班看店的人）只需要「输入名字/扫码 → 看到大字售价」，
  /// 而库存页是为盘点对账设计的（四列信息）。所以单开一页，入口放这里。
  ///
  /// `null` = 不显示按钮（测试不传 ⇒ 既有用例逐字不变）。
  final VoidCallback? onPriceLookup;

  /// 「你的数据在」的显示文案（§BH·五 B1b 裁定 2：Android 私有目录用户
  /// 打不开，显示友好文案而非具体路径；路径挪到帮助页「关于」小字）。
  /// `null` = 显示真实路径（桌面行为，零变化）。
  final String? locationNote;

  /// 手机壳（底部导航）—— 只影响「从这里开始」那句指路文案
  /// （M05：手机上不能写「左边的功能列表」）。默认 `false` = 桌面。
  final bool mobileShell;

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  bool _busy = false;

  /// 图表窗口：近 30 天（提案 54）
  static const int _chartDays = 30;

  /// **整页查询结果算一次就缓存**（用户审查 2026-10-30）。
  ///
  /// 从前这些查询直接写在 `build()` 里 —— 点一下「立即备份」会 `setState`
  /// 改 `_busy`、页面重建、于是**全历史聚合又跑一遍**（`stockTop` 是对整个
  /// `stock_ledger` 按商品分组再排序，`receivables/payables` 也是全历史）。
  ///
  /// 现在的时机：进入概览（`initState`）算一次；`queries` 换了（换库/重连）
  /// 重算。离开再回来会重建 State ⇒ 自动刷新 —— 壳用的是「按 destination
  /// 现建页面」，不是 `IndexedStack`（`app_shell.dart` 的 `appShellPage`）。
  _OverviewData? _data;

  /// 缺货榜（提案 61）。**不进 `_load()`**：那张榜不依赖任何单据
  /// （判据是商品档案 + 库存流水 + 安全库存），而 `_load()` 在
  /// `hasAnyDocument() == false` 时整块返回 `null` —— 缺货榜若挂在里面，
  /// 「刚装上软件、建了商品、设了安全库存」的店就永远看不到它
  /// （那恰好是决策 4 引导卡要照顾的人）。
  ShortageSummary _lowStock = ShortageSummary.none;

  @override
  void initState() {
    super.initState();
    _data = _load();
    _loadLowStock();
  }

  /// 概览页缺货榜的数据源（提案 61 §六 决策 甲：复用现有查询，约 +130 ms）。
  ///
  /// 与 `_load()` 分开的理由见 [_lowStock] 的注释；刷新时机与 `_data` 一致
  /// （`initState` 一次 + `queries` / 库版本 / 未同步队列变化时重算）。
  ///
  /// ⚠️ 回退判据（写死在这里，防止将来「感觉慢就撤功能」）：概览页首帧
  /// **连续 3 次冷启动** > 600 ms，或这两条聚合计时**连续 3 次** > 200 ms
  /// ⇒ 才按提案 §六 的「丙」（只显示缺货数量 + 跳转）调整，
  /// 且**标题、说明、交互要一起改**（只隐藏明细会让用户找不到那 N 个是什么）。
  void _loadLowStock() {
    final QueryDao? q = widget.queries;
    final ProductService? products = widget.products;
    if (q == null || products == null) {
      _lowStock = ShortageSummary.none;
      return;
    }
    // ⚠️ `listForExport`（不分页）而不是 `findAll()`（默认 limit 200）
    _lowStock = computeShortage(
      products: products.listForExport(active: true),
      agg: q.stockAggregates(),
      inTransit: q.inTransitByProduct(),
      unsynced: widget.stockDelta?.unsyncedDelta() ?? const <String, int>{},
    );
  }

  @override
  void didUpdateWidget(OverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换库（桌面 ↔ 手机镜像、重连）必须重算；其余重建复用缓存。
    // 2026-11-01：主机**落库了**手机推上来的数据也要重算 —— 否则「今日 / 应收 / 应付」
    // 停在旧数字，用户会以为没同步（真机报的就是这个）。
    if (oldWidget.queries != widget.queries ||
        oldWidget.remoteVersion != widget.remoteVersion ||
        oldWidget.products != widget.products ||
        oldWidget.stockDelta != widget.stockDelta) {
      _data = _load();
      _loadLowStock();
    }
  }

  /// 一次把概览要的数字都算出来。
  ///
  /// 空库（`hasAnyDocument() == false`）⇒ `null`：整块经营区不显示。
  _OverviewData? _load() {
    final QueryDao? q = widget.queries;
    if (q == null || !q.hasAnyDocument()) return null;

    // 业务日按**本地日**算 —— 与 `documents.business_day` 同一口径
    final int toDay = businessDayOf(DateTime.now().millisecondsSinceEpoch);
    final int fromDay = toDay - (_chartDays - 1);

    // 月度对比的「上月同期」可能比 30 天更早（今天 31 日 ⇒ 要回到上月初），
    // 所以**一次查够两个窗口**，比查两次省一趟扫表。
    final MonthCompareWindow window = monthCompareWindow(toDay);
    final List<RevenueDay> wide = q.dailyRevenue(
      fromDay: window.priorFrom < fromDay ? window.priorFrom : fromDay,
      toDay: toDay,
    );

    return _OverviewData(
      today: q.todaySummary(_dayStart()),
      receivables: q.receivablesSummary(),
      payables: q.payablesSummary(),
      stockTop: q.stockTop(),
      // 传的是**宽数据**（含上月同期，月度对比要用）——
      // 营收卡自己按 `fromDay..toDay` 裁，这样「平均每个有生意的日子」
      // 不会把上月的天算进去，也不依赖调用方记得裁。
      revenueRows: wide,
      // 毛利只查 30 天窗口（毛利卡没有「上月同期」需求 ⇒ 跟着宽窗口查是白扫表）
      marginRows: q.dailyGrossMargin(fromDay: fromDay, toDay: toDay),
      monthCompare: buildMonthCompare(rows: wide, window: window),
      fromDay: fromDay,
      toDay: toDay,
    );
  }

  /// 遗漏 11：**视觉反馈优先于逻辑防护** —— 先禁用按钮，再谈并发。
  /// 结果文案（含完整路径）由领域层给（`backupOutcomeMessage`，遗漏 5）。
  Future<void> _backupNow() async {
    final Future<BackupOutcome> Function()? run = widget.onBackupNow;
    if (run == null || _busy) return;
    setState(() => _busy = true);
    // 同上：`wal_checkpoint` 与 `quick_check` 都在主线程上同步跑，
    // 不先画一帧的话「备份中…」永远看不到（2026-11-09）。
    await letBusyStatePaint();
    final BackupOutcome outcome = await run();
    // ⚠️ 同 `settings_page._backupNow`（2026-11-10 真机 P1）：这里**不许**用
    // `if (!mounted) return;` 掐掉通知 —— 切页后「备份成功」就永远看不到了。
    if (mounted) setState(() => _busy = false);
    showAppSnack(
      SnackBar(
        content: Text(backupOutcomeMessage(outcome)),
        duration: const Duration(seconds: 4),
      ),
      fallback: mounted ? context : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? reminder = widget.backupReminder;

    // 数据在 `_load()` 里算过一次并缓存 —— 这里**不再查库**
    final _OverviewData? data = _data;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        // ---- 数据安全橙卡（AE-3：用户不会主动查，所以要主动呈现）----
        if (reminder != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              margin: EdgeInsets.zero,
              color: _noticeBackground,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 22,
                      color: _noticeColor,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(reminder, style: const TextStyle(height: 1.6)),
                          const SizedBox(height: 10),
                          if (widget.onBackupNow != null)
                            FilledButton.icon(
                              key: const Key('overview-backup-now'),
                              onPressed: _busy ? null : _backupNow,
                              icon: const Icon(Icons.save_alt, size: 18),
                              label: Text(_busy ? '备份中…' : '立即备份'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        if (widget.shopName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              widget.shopName!,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('你的数据在', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                if (widget.locationNote != null)
                  Text(
                    widget.locationNote!,
                    style: const TextStyle(height: 1.6),
                  )
                else ...<Widget>[
                  SelectableText(
                    widget.dataDirectory,
                    style: const TextStyle(height: 1.6),
                  ),
                  const SizedBox(height: 4),
                  // 2026-10-22（§CV·八十三 批 2 第 12 条）：**把「打开文件夹」
                  // 搬到概览**。设置页早就有（`settings_page`），概览只给一条
                  // 只读路径 —— 用户想看数据在哪，还得跑去设置里翻。
                  // 手机端不显示（没有「文件管理器打开这个路径」的概念）。
                  if (!widget.mobileShell)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('overview-open-folder'),
                        onPressed: () => _openFolder(widget.dataDirectory),
                        icon: const Icon(Icons.folder_open_outlined, size: 18),
                        label: const Text('打开文件夹'),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '备份会放在旁边：${widget.backupDirectory}',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // `ui_principles.md` 要求的那句核心承诺 —— 页面上原先没有
                  Text(
                    '数据只在这台电脑上，不会上传到任何地方。',
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Icon(
                      widget.databaseReady
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 20,
                      color: widget.databaseReady
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.databaseReady
                            ? '数据文件已就绪（版本 ${widget.schemaVersion}）'
                            : '数据文件打不开，请到设置里换一个位置',
                        style: const TextStyle(height: 1.6),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('从这里开始', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          // M05（2026-10-08）：措辞随壳走 —— 桌面左侧列表 / 手机底部导航。
          // 文案在 `shensuanzi_app` 的 `overviewNavHint`（纯 Dart，`dart test` 钉得住）
          overviewNavHint(mobileShell: widget.mobileShell),
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
        // ---- #32 经营速览（空库 = hasAnyDocument()==false ⇒ 整块不显示，
        //      不干扰首次开张引导；裁定⑤空库判据 = documents 为空）----
        //
        // 2026-10-20（用户建议）：**从页首挪到「从这里开始」下方** ——
        // 概览页先回答「数据在哪、能不能用、从哪开始」，经营数字是**第二眼**的东西。
        // ⚠️ 必须带顶部间距：手机壳这里是 `Column` 竖排三卡，
        // 紧贴上一段文字会看起来「卡片边缘叠在一起」（用户 2026-10-20 报的现象）。
        if (data != null) ...<Widget>[
          const SizedBox(height: 20),
          _businessCards(theme, data),
          // 图表放在经营卡**下面**（用户 2026-10-30：中老年看不出营收，
          // 「真相在流水」里翻不出来）。间距必须显式给 —— `_bizCard` 是
          // `margin: EdgeInsets.zero`，紧贴会看起来像「两张卡叠在一起」
          // （用户 2026-10-20 报过的那个现象）。
          const SizedBox(height: 12),
          _charts(theme, data),
        ],
        // 2026-10-22（§CV·八十三 批 2 第 12 条）：**空库也要有入口**
        if (widget.onNavigate != null && data == null) ...<Widget>[
          const SizedBox(height: 12),
          _entriesCard(theme),
        ],
        // 提案 61 决策 4：**空库也要能看见缺货榜 / 引导卡**。
        // 这一条不依赖任何单据 —— 刚建了商品、设了安全库存还没开过单的店，
        // 正是「该补货」和「去设安全库存」这两句话最该出现的时候。
        if (data == null && _lowStock.isVisible) ...<Widget>[
          const SizedBox(height: 12),
          _lowStockCard(),
        ],
      ],
    );
  }

  /// 「要开工？」入口卡（§CV·八十三 批 2 第 12 条）。
  ///
  /// **空库也要显示** —— 它原来长在 `_businessCards` 里，被
  /// `hasAnyDocument()` 那道门一起关掉；而空库恰恰是最需要指路的时候。
  /// 用系统文件管理器打开数据文件夹（Windows；失败静默 —— 不打断用户）。
  /// 与 `settings_page` 同款实现。
  Future<void> _openFolder(String path) async {
    try {
      await Process.run('explorer', <String>[path]);
    } catch (_) {
      // explorer 打不开（路径失效等）不影响页面
    }
  }

  Widget _entriesCard(ThemeData theme) {
    if (widget.onNavigate == null) return const SizedBox.shrink();
    return _bizCard(
      theme,
      key: 'overview-card-entries',
      title: '要开工？',
      lines: <Widget>[
        // 裁定③：入口 = 高频动作（查询类导航已有，不重复）
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton.icon(
              key: const Key('overview-go-sale'),
              onPressed: () => widget.onNavigate!('sale'),
              icon: const Icon(Icons.point_of_sale_outlined, size: 18),
              label: const Text('销售开单'),
            ),
            OutlinedButton.icon(
              key: const Key('overview-go-purchase'),
              onPressed: () => widget.onNavigate!('purchase'),
              icon: const Icon(Icons.inventory_outlined, size: 18),
              label: const Text('采购入库'),
            ),
            OutlinedButton.icon(
              key: const Key('overview-go-delivery'),
              onPressed: () => widget.onNavigate!('delivery'),
              icon: const Icon(Icons.local_shipping_outlined, size: 18),
              label: const Text('送货'),
            ),
            if (widget.onPriceLookup != null)
              OutlinedButton.icon(
                key: const Key('overview-go-price'),
                onPressed: widget.onPriceLookup,
                icon: const Icon(Icons.price_check_outlined, size: 18),
                label: const Text('查价'),
              ),
          ],
        ),
      ],
    );
  }

  /// 「想看细节？」跳转卡（N-c 裁定乙：概览页补「近期单据 / 欠款」入口）。
  ///
  /// 为什么放在图表区末尾：概览页的阅读顺序是「今天干什么 → 卖得怎么样 →
  /// 赚了多少」，看完数字才想查明细。放在最前面等于挡路。
  ///
  /// ⚠️ 按钮**只导航、不带筛选**（裁定⑦同款判断：带筛选跳转超范围）。
  Widget _jumpCard(ThemeData theme) => _bizCard(
    theme,
    key: 'overview-card-jumps',
    title: '想看细节？',
    lines: <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          OutlinedButton.icon(
            key: const Key('overview-go-documents'),
            onPressed: () => widget.onNavigate!('documents'),
            icon: const Icon(Icons.receipt_long_outlined, size: 18),
            label: const Text('近期单据'),
          ),
          OutlinedButton.icon(
            key: const Key('overview-go-parties'),
            onPressed: () => widget.onNavigate!('parties'),
            icon: const Icon(Icons.people_outline, size: 18),
            label: const Text('谁还欠着钱'),
          ),
        ],
      ),
    ],
  );

  /// **#32**：经营速览三卡。桌面横排（各 1/3，裁定⑥）；手机紧凑竖排
  ///（padding 收窄 + 入口一行图标）。卡片**不可点**（裁定⑦：先做静态，
  /// 带筛选跳转超范围）。金额 `formatGrouped`（界面带千分位，裁定⑧）。
  Widget _businessCards(ThemeData theme, _OverviewData data) {
    // F13（2026-10-25 复跑）：从前「要留心」只看应收 —— 欠着供应商的钱一个字都不说，
    // 边界上还会显示「目前没有要留心的事」。应付（我欠人）与应收同权重，且**排在前面**：
    // 要还出去的钱比要收进来的更急。
    final ReceivablesSummary receivables = data.receivables;
    final PayablesSummary payables = data.payables;
    final OverviewSummary today = data.today;
    final QueryDao queries = widget.queries!;
    final int transitCount = queries.deliveryInTransitCount();
    final int negativeStock = queries
        .stockByProduct()
        .values
        .where((int q) => q < 0)
        .length;
    final int unsynced = widget.pendingMarks?.unconfirmedCount() ?? 0;

    final Widget todayCard = _bizCard(
      theme,
      key: 'overview-card-today',
      title: '今日销售（按单据日期）',
      lines: <Widget>[
        Text(
          '店内销售 ${today.saleCount} 笔 · ¥${Money.formatGrouped(today.saleCents)}',
          style: const TextStyle(height: 1.7, fontSize: 15),
        ),
        Text(
          '送货 ${today.deliveryCount} 笔 · '
          '¥${Money.formatGrouped(today.deliveryCents)}'
          '${transitCount > 0 ? '（未签收 $transitCount 张）' : ''}',
          style: const TextStyle(height: 1.7, fontSize: 15),
        ),
        // 裁定④：镜像可能滞后 —— 诚实口径（不假装算得出来，只报条数）
        if (widget.mobileShell && unsynced > 0)
          Text(
            '仅已同步 · 有 $unsynced 条未同步',
            style: const TextStyle(
              height: 1.6,
              fontSize: 12,
              color: _noticeColor,
            ),
          ),
      ],
    );

    final Widget careCard = _bizCard(
      theme,
      key: 'overview-card-care',
      title: '要留心',
      lines: <Widget>[
        if (payables.totalCents > 0) ...<Widget>[
          Text(
            '应付合计 ¥${Money.formatGrouped(payables.totalCents)}'
            '（${payables.partyCount} 家未结）',
            style: const TextStyle(height: 1.7, fontSize: 15),
          ),
          if (payables.topName != null)
            Text(
              '其中 ${payables.topName} ¥${Money.formatGrouped(payables.topCents)}'
              '${payables.topActive ? '' : '（已停用）'}',
              style: TextStyle(
                height: 1.6,
                fontSize: 13,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
        ],
        if (receivables.totalCents > 0) ...<Widget>[
          Text(
            '应收合计 ¥${Money.formatGrouped(receivables.totalCents)}'
            '（${receivables.partyCount} 家未结）',
            style: const TextStyle(height: 1.7, fontSize: 15),
          ),
          if (receivables.topName != null)
            Text(
              // 裁定⑨：停用的也显示（OBS-05「账未结清要能查到」），标注状态
              '其中 ${receivables.topName} ¥${Money.formatGrouped(receivables.topCents)}'
              '${receivables.topActive ? '' : '（已停用）'}',
              style: TextStyle(
                height: 1.6,
                fontSize: 13,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
        ],
        if (negativeStock > 0)
          Text(
            '负库存 $negativeStock 种 —— 可能是没录期初或超卖，点「库存」看看',
            // Q5 对比度（用户裁定 ①甲）：主题错误色，不再是写死的 Colors.red。
            // 实测（Flutter 3.11 探针）：colorScheme.error = #BA1A1A，对
            // scaffold 背景 #FAFAFA ≈ 6.19:1；Colors.red（#F44336）只有 ≈3.53:1，
            // 低于 `ui_principles.md` §二「次要文字 ≥ 4.5:1」。
            // 值不写死 —— SDK 基线色将来若变，这里跟着变，不会漂。
            style: TextStyle(
              height: 1.7,
              fontSize: 15,
              color: theme.colorScheme.error,
            ),
          ),
        if (receivables.totalCents <= 0 &&
            payables.totalCents <= 0 &&
            negativeStock == 0)
          const Text('目前没有要留心的事。', style: TextStyle(height: 1.7)),
      ],
    );

    if (widget.mobileShell) {
      // 手机：竖排紧凑（裁定⑥）
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          todayCard,
          const SizedBox(height: 10),
          careCard,
          if (widget.onNavigate != null) ...<Widget>[
            const SizedBox(height: 10),
            _entriesCard(theme),
          ],
        ],
      );
    }
    // 桌面：三卡横排（各 1/3）
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: todayCard),
        const SizedBox(width: 12),
        Expanded(child: careCard),
        const SizedBox(width: 12),
        Expanded(child: _entriesCard(theme)),
      ],
    );
  }

  /// 图表区（提案 54 第二批）：近 30 天柱状图 + 欠款横条。
  ///
  /// 两张卡之间**必须显式留间距**：两边的 `Card` 都是 `margin: EdgeInsets.zero`，
  /// 紧贴会看起来像「叠在一起」（用户 2026-10-20 报过）。
  Widget _charts(ThemeData theme, _OverviewData data) {
    final bool hasBalance =
        data.receivables.totalCents > 0 || data.payables.totalCents > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        RevenueChartCard(
          rows: data.revenueRows,
          fromDay: data.fromDay,
          toDay: data.toDay,
          mobileShell: widget.mobileShell,
        ),
        // 月度对比紧跟营收图：两张都在说「卖得怎么样」，放在一起好对照。
        // 间距显式给 —— 两张卡都是 `margin: EdgeInsets.zero`。
        if (!data.monthCompare.isEmpty) ...<Widget>[
          const SizedBox(height: 12),
          MonthCompareCard(
            compare: data.monthCompare,
            mobileShell: widget.mobileShell,
            usePercent: widget.monthComparePercent,
          ),
        ],
        // 毛利卡（N-a，2026-11-06）。排在月度对比**之后**：前两张回答
        // 「卖得怎么样」，这张回答「赚了多少」—— 是不同的问题，插进那两张
        // 中间会把同一类信息劈开。
        const SizedBox(height: 12),
        GrossMarginChartCard(
          rows: data.marginRows,
          fromDay: data.fromDay,
          toDay: data.toDay,
          mobileShell: widget.mobileShell,
        ),
        // N-c（裁定乙「顺带补近期单据 / 欠款两个入口」）：毛利明细里看到
        // 「哪天退货多了」之后，下一步就是去单据页查 —— 入口得在同一屏给。
        if (widget.onNavigate != null) ...<Widget>[
          const SizedBox(height: 12),
          _jumpCard(theme),
        ],
        if (hasBalance) ...<Widget>[
          const SizedBox(height: 12),
          BalanceBarsCard(
            receivables: data.receivables,
            payables: data.payables,
            mobileShell: widget.mobileShell,
          ),
        ],
        // 提案 61 决策 3 甲：**缺货榜在压货榜上面** —— 缺货要行动（补货），
        // 压货只是知晓（钱压着），中老年店主的注意力在上面。
        // 两张**独立**的卡（否决「合成一张卡」的丙案：一张卡两套颜色两套口径，
        // 读起来要来回切上下文）。概览这里只截前 3 行、不加收起按钮 ——
        // 收起省不了多少，而「查看全部」已经把出口给足了。
        if (_lowStock.isVisible) ...<Widget>[
          const SizedBox(height: 12),
          _lowStockCard(),
        ],
        // 2026-11-01（用户裁定 A1）：完整压货榜**搬到库存页**，概览只留前三名。
        //
        // 概览回答「今天要干什么」，压货榜回答「去库存看看」—— 后者本来就
        // 属于库存页。真机上这一屏要滚两三屏，砍掉 Top10 是最直接的减负。
        // 但前三名必须留：全撤掉的话用户根本不知道「有货压着」。
        if (!data.stockTop.isEmpty) ...<Widget>[
          const SizedBox(height: 12),
          // 复用**同一个** `StockTopCard`，只截前 3 行 + 给一个出口。
          // 不另写一份「精简版」渲染逻辑：两份渲染必然漂移
          // （数量/单位/待校准底注/横条 key 都要各维护一遍）。
          StockTopCard(
            summary: StockTopSummary(
              rows: data.stockTop.rows.take(3).toList(growable: false),
              uncalibratedCount: data.stockTop.uncalibratedCount,
              negativeCostCount: data.stockTop.negativeCostCount,
            ),
            mobileShell: widget.mobileShell,
            totalCount: data.stockTop.rows.length,
            // 压货榜就在库存页顶部 ⇒ 「跳到库存页」= 「定位到压货榜」，
            // 不需要额外的滚动锚点（用户裁定要求「直接定位到压货榜」）。
            onOpenAll: widget.onNavigate == null
                ? null
                : () => widget.onNavigate!('stock'),
          ),
        ],
      ],
    );
  }

  /// 概览页的缺货榜：**只显示前 3 行**（与压货榜同款），出口是库存页。
  ///
  /// 不另写「精简版」渲染 —— `LowStockCard` 只有一份实现，这里只截行
  /// （[ShortageSummary.limitTo] **只截行、不动计数**，按钮上要写真实的
  /// 「查看全部 N 个」）。
  Widget _lowStockCard() => LowStockCard(
    summary: _lowStock.limitTo(3),
    mobileShell: widget.mobileShell,
    onOpenAll: widget.onNavigate == null
        ? null
        : () => widget.onNavigate!('stock'),
  );

  Widget _bizCard(
    ThemeData theme, {
    required String key,
    required String title,
    required List<Widget> lines,
  }) => Card(
    key: Key(key),
    margin: EdgeInsets.zero,
    child: Padding(
      // 手机紧凑（裁定⑥）：14 vs 桌面 16
      padding: EdgeInsets.all(widget.mobileShell ? 14 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ...lines,
        ],
      ),
    ),
  );

  /// 本地时间零点（裁定③：UI 层算；测试传固定值 ⇒ core 可复现）。
  /// 多时区同步是登记在案的将来待办（个体户单机单时区，暂不考虑）。
  static DateTime _dayStart() {
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }
}
