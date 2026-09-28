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
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'export_button.dart';
import 'opening_stock_page.dart';

/// 库存查询页。
class StockPage extends StatefulWidget {
  const StockPage({
    super.key,
    required this.engine,
    required this.products,
    required this.queries,
    this.exports,
  });

  /// 规则引擎（期初录入「重新清点」入口用 —— RULE-009 经 `StocktakeService`）
  final RuleEngine engine;

  final ProductService products;
  final QueryDao queries;

  /// 导出服务（`null` = 不显示导出按钮）
  final ExportSink? exports;

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
      return OpeningStockPage(
        service: StocktakeService(engine: widget.engine, queries: widget.queries),
        productService: widget.products,
        isFirstTime: !hasAnyLedger,
        bookQuantities: book,
        onDone: () => setState(() => _showOpening = false),
      );
    }

    // 商品全集（含停用的？—— 不，库存页只看启用中的商品）
    final List<Product> all = widget.products.list();
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

    /// 有流水 = 账面不为 0 或在途不为 0（遗漏 5 的「有意义的数字」）
    bool hasFlow(Product product) =>
        (book[product.id] ?? 0) != 0 || (inTransit[product.id] ?? 0) != 0;

    final List<Product> shown = _showAll
        ? matched
        : matched.where(hasFlow).toList();
    // 遗漏 4：按在店可售降序（浏览页，不是查找页）
    int inStore(Product product) =>
        (book[product.id] ?? 0) - (inTransit[product.id] ?? 0);
    shown.sort(
      (Product a, Product b) => inStore(b).compareTo(inStore(a)),
    );

    final int hiddenCount = matched.length - shown.length;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
          // §AD 遗漏 2：入口按钮（文案按首次 / 再次区分）
          Row(
            children: <Widget>[
              Expanded(child: Text('库存', style: theme.textTheme.titleLarge)),
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
                onPressed: () => setState(() => _showOpening = true),
                icon: const Icon(Icons.inventory_2_outlined, size: 18),
                label: Text(hasAnyLedger ? '重新清点' : '录入现有货物'),
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
                        _searchText.isEmpty ? '还没有库存记录' : '没有匹配的商品。',
                        textAlign: TextAlign.center,
                        style: TextStyle(height: 1.8, color: theme.hintColor),
                      ),
                      // §AD-6：空态两段式 —— 首段给「开店」场景，次段给「日常」场景
                      if (_searchText.isEmpty) ...<Widget>[
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
  });

  final Product product;
  final int book;
  final int inTransit;
  final int costCents;

  /// 是否有过正数量入库（§AD 遗漏 1：成本列三态的判断依据）
  final bool everInbound;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int inStore = book - inTransit;

    // AA-3 三档：负红 / 低橙 / 正常无色。safety_stock = 0 = 不需要告警。
    final int safety = product.safetyStock;
    final bool negative = inStore < 0;
    final bool low = !negative && safety > 0 && inStore <= safety;
    final Color mainColor = negative
        ? theme.colorScheme.error
        : low
            ? const Color(0xFFB45309)
            : theme.colorScheme.onSurface;
    final String? notice = negative
        ? '已超卖，尽快补货或核对账目'
        : low
            ? '低于安全库存 $safety，该补货了'
            : null;

    return Padding(
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
                      product.name,
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
                  ],
                ),
              ),
              // AA-2：主列大字加粗
              Text(
                '$inStore',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: mainColor,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Text(
                '账面 $book · 在途 $inTransit',
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              const Spacer(),
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
        ],
      ),
    );
  }
}
