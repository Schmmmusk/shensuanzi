/// 库存查询页（RULE-006，纯聚合读 —— `docs/reply_review.md` §AA 二）。
///
/// ## 裁定落点（§AA）
///
/// - **AA-2**：主列 = **在店可售**（账面 − 在途），字大加粗；账面 / 在途常规
/// - **AA-3 三档颜色**：在店可售 **< 0 红色**（超卖，账对不上）；
///   **0 ≤ x ≤ safety_stock（safety > 0）橙色**（该补货）；
///   正常无色。`safety_stock = 0` 就是「不需要告警」，不触发
/// - **AA-4**：「成本（均价）」列 + ⓘ tooltip 说明口径（历史加权平均，
///   进价变过时与最近一次进价不同）；**负值红色**（与负库存联动）
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
library;

import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'document_detail_page.dart';
import 'export_button.dart';
import 'opening_stock_page.dart';
import 'product_form_dialog.dart';
import 'stock_flow_page.dart';

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
    this.masterDataSink,
    this.documentSink,
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

  /// **#27 批 2**：「新建商品」提交出口（手机壳 = 队列出口）。`null` = 无按钮。
  final MasterDataSink? masterDataSink;

  /// **盘点单的提交出口**（2026-10-20 放开手机「重新清点」，§CV·七十八）。
  ///
  /// 手机 = `QueueSink`；桌面 = `ServiceSink`（两支都由桌面/手机各自的
  /// 装配传入）。`null` = 未装配（摆放层测试）⇒ 期初页退回 `StocktakeService`。
  final DocumentSink? documentSink;

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
  bool _showOpening = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
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
    setState(() {}); // 新行可见（零流水也显示 —— openingPending 在场）
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
                      ),
                    ),
                  );
                  if (mounted) setState(() {}); // 回来库存可能变过（签收等）
                },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // 聚合读一次（RULE-006：没有余额表，每次从流水算）
    final Map<String, int> book = widget.queries.stockByProduct();
    final Map<String, int> inTransit = widget.queries.inTransitByProduct();
    final Map<String, int> cost = widget.queries.costByProduct();
    final Set<String> inbound = widget.queries.inboundProductIds();
    final bool hasAnyLedger = widget.queries.hasAnyStockLedger();

    // §AD 遗漏 2：期初录入入口（就地打开，完成后 setState 刷新数字）
    if (_showOpening) {
      // ⚠️ 期初录入当前**只在主机开放**（§CV·七 缺口 2，2026-10-09）。
      //
      // 2026-10-20（§CV·七十八）：**手机上也能清点了** —— 裁定「走 stocktake 单据」
      // （§CV·七 缺口 2 的 A 案）：清点单走**单据队列**，差额由主机算，客户端零规则。
      //
      // ⇒ 这道门改为拦「**手机壳但没装配 documentSink**」：那意味着写进镜像就到不了电脑。
      assert(
        !(widget.mobileShell && widget.documentSink == null),
        '手机壳开放清点必须装配 documentSink（QueueSink）——'
        '否则清点单只写镜像、到不了电脑',
      );
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
        onDone: () => setState(() => _showOpening = false),
        onStorageFailure: widget.onStorageFailure,
      );
    }

    // 商品全集（含停用的？—— 不，库存页只看启用中的商品）
    final List<Product> all = widget.products.list();

    // C2·§CC 裁定七：库存叠加 —— 一次遍历队列算全部未同步影响，
    // 行内只查 map；点开拆解才逐商品取 contributors（IO 不进常驻路径）
    final Map<String, int> unsyncedByProduct =
        widget.stockDelta?.unsyncedDelta() ?? const <String, int>{};
    // #31（裁定②）：一次 build 取一次（PendingMarks 文档的 N 次 SQL 警告）
    final Map<String, int> openingPending =
        widget.pendingMarks?.openingQuantityByProduct() ??
        const <String, int>{};
    // 搜索：名称 / 编码 / 条码
    final List<Product> matched = _searchText.isEmpty
        ? all
        : all
              .where(
                (Product product) =>
                    product.name.contains(_searchText) ||
                    product.code.contains(_searchText) ||
                    (product.barcode ?? '').contains(_searchText),
              )
              .toList();

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
    int inStore(Product product) =>
        (book[product.id] ?? 0) - (inTransit[product.id] ?? 0);
    shown.sort((Product a, Product b) => inStore(b).compareTo(inStore(a)));

    final int hiddenCount = matched.length - shown.length;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
                  TextButton.icon(
                    key: const Key('stock-open-entry'),
                    // 2026-10-20（§CV·七十八）：手机端**也能清点** —— 清点单走
                    // 单据通道入队，差额由主机算（客户端零规则）。原引导删除。
                    onPressed: () => setState(() => _showOpening = true),
                    icon: const Icon(Icons.inventory_2_outlined, size: 18),
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
              const SizedBox(height: 4),
              Text(
                '「在店可售」= 账面库存 − 送货在途；低库存按它判断。',
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('stock-search'),
                controller: _query,
                onChanged: (String text) =>
                    setState(() => _searchText = text.trim()),
                decoration: const InputDecoration(
                  labelText: '商品名 / 编码 / 条码（可扫码）',
                  border: OutlineInputBorder(),
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                ),
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
                            : '没有匹配的商品。',
                        textAlign: TextAlign.center,
                        style: TextStyle(height: 1.8, color: theme.hintColor),
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
                                    color: theme.textTheme.bodySmall?.color,
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
                )
              else
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < shown.length; i++) ...<Widget>[
                        if (i > 0) const Divider(height: 1),
                        _StockRow(
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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // ⚠️ 局部变量才能提升非空（public 字段判空不提升 —— analyze 实测）
    final StockDelta? delta = this.delta;
    final int inStore = book - inTransit;

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
                Text(
                  '$inStore',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: mainColor,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
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
                // AA-4：成本（均价）+ 口径说明；负值红色（与负库存联动）
                Tooltip(
                  message: '按历史加权平均成本计算。\n进价变化时可能与最近一次进价不同。',
                  triggerMode: TooltipTriggerMode.tap,
                  showDuration: const Duration(seconds: 4),
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
                const SizedBox(width: 4),
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
                else
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
  });

  final StockDelta delta;
  final String productId;
  final int book;
  final int unsynced;

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
    final int estimated = widget.book + widget.unsynced;
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
                '≈ 台账 ${widget.book} + 未同步 ${_signed(widget.unsynced)} '
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
