/// 查价页（真实诉求批 ③，2026-10-24，§CV·一百零四）。
///
/// ## 为什么单开一页
///
/// 「库存」页是为**盘点与对账**设计的（账面 / 在途 / 成本 / 售价四列），
/// 而替班看店的人只需要一件事：**输入名字或扫码 → 看到大字的零售价**。
/// 把库存页改简单会毁掉它本来的用途，所以另开一页，库存页不动。
///
/// ## 三条交互决定
///
/// 1. **只显示 名称 / 售价 / 库存** —— 成本、编码、条码、预警值一概不出现
///    （对查价无用，还会把大字挤小）。
/// 2. **回车（扫码枪）打断防抖**：USB 扫码枪是「瞬间输入十几个字符 + 回车」，
///    等 300 ms 防抖会让人觉得卡。所以 `onSubmitted` 里**先按条码查**，
///    命中就直接出大卡；没命中再退回按名字模糊搜。
/// 3. **库存用账面**（`stockByProduct`），不是「在店可售」—— 查价的人问的是
///    「店里有几瓶」，在店可售是给低库存告警用的，对他是噪音。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

class PriceLookupPage extends StatefulWidget {
  const PriceLookupPage({
    super.key,
    required this.products,
    required this.stockSnapshot,
  });

  /// 商品查询（`list` / `barcodeOwners`）
  final ProductService products;

  /// 账面库存（`QueryDao.stockByProduct`）—— 只在进页时读一次
  final Map<String, int> Function() stockSnapshot;

  @override
  State<PriceLookupPage> createState() => _PriceLookupPageState();
}

class _PriceLookupPageState extends State<PriceLookupPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  Timer? _debounce;

  /// 当前列表（多个命中时）
  List<Product> _results = const <Product>[];

  /// 大卡上的那一个（唯一命中 / 扫码命中）
  Product? _highlight;

  /// 是否已经搜过（用于「没找到」文案，避免空输入就报没找到）
  bool _searched = false;

  /// 搜的词（「没找到「xxx」」用）
  String _query = '';

  /// 账面库存（进页读一次）
  late final Map<String, int> _stock = widget.stockSnapshot();

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(text));
  }

  /// 回车 = 扫码枪结束符（也可能是用户按了搜索键）。
  ///
  /// **先按条码查**：条码是精确匹配，比名字模糊搜快且准；命中就立刻出大卡，
  /// **不等防抖**（审查意见 §二-4）。
  void _onSubmitted(String text) {
    _debounce?.cancel();
    final String raw = text.trim();
    if (raw.isEmpty) return;
    final List<Product> byCode = widget.products.barcodeOwners(raw);
    if (byCode.isNotEmpty) {
      setState(() {
        _query = raw;
        _searched = true;
        _results = byCode;
        _highlight = byCode.first;
      });
      return;
    }
    _search(raw);
  }

  void _search(String text) {
    final String q = text.trim();
    setState(() {
      _query = q;
      if (q.isEmpty) {
        _searched = false;
        _results = const <Product>[];
        _highlight = null;
        return;
      }
      _searched = true;
      // `active: null` ⇒ **含停用**：下架的商品也可能还在货架上，查价要能查到
      _results = widget.products.list(query: q, active: null, limit: 50);
      _highlight = _results.length == 1 ? _results.first : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('查价')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                key: const Key('price-lookup-input'),
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onChanged,
                onSubmitted: _onSubmitted,
                style: const TextStyle(fontSize: 20),
                decoration: const InputDecoration(
                  hintText: '输入商品名，或扫码',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: false,
                ),
              ),
              const SizedBox(height: 20),
              if (_highlight != null)
                _bigCard(theme, _highlight!)
              else if (_results.isNotEmpty) ...<Widget>[
                Text(
                  '找到 ${_results.length} 个，点一个看价格',
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
                const SizedBox(height: 8),
                for (final Product product in _results)
                  _resultRow(theme, product),
              ] else if (_searched)
                _notFound(theme)
              else
                _hint(theme),
            ],
          ),
        ),
      ),
    );
  }

  /// 大卡：名称 + **大字售价** + 小字库存（家人/顾客只看那一个大数字）。
  Widget _bigCard(ThemeData theme, Product product) {
    final int stock = _stock[product.id] ?? 0;
    final bool outOfStock = stock <= 0;
    return Container(
      key: const Key('price-lookup-card'),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      decoration: BoxDecoration(
        // 大底色：一眼看到「就是这个」
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            product.name,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '售价',
            style: TextStyle(
              fontSize: 14,
              color: theme.colorScheme.onPrimaryContainer.withValues(
                alpha: 0.75,
              ),
            ),
          ),
          // 价格用 FittedBox 包住：200% 字号下也不会把「¥ 5.00」挤断行
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '¥ ${Money.format(product.sellPrice)}',
              key: const Key('price-lookup-price'),
              style: TextStyle(
                fontSize: 52,
                fontWeight: FontWeight.w700,
                height: 1.1,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Text(
                '库存 $stock ${product.unit}',
                key: const Key('price-lookup-stock'),
                style: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.onPrimaryContainer.withValues(
                    alpha: 0.8,
                  ),
                ),
              ),
              if (outOfStock) ...<Widget>[
                const SizedBox(width: 8),
                // 缺货/超卖要说出来 —— 顾客问到「还有吗」时这就是答案
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    stock < 0 ? '超卖' : '缺货',
                    key: const Key('price-lookup-out-of-stock'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 多个命中时的紧凑行（只给名字 + 售价，点了才出大卡）
  Widget _resultRow(ThemeData theme, Product product) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: Key('price-lookup-row-${product.id}'),
        title: Text(product.name),
        trailing: Text(
          '¥ ${Money.format(product.sellPrice)}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        onTap: () => setState(() => _highlight = product),
      ),
    );
  }

  Widget _notFound(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      '没找到「$_query」',
      key: const Key('price-lookup-not-found'),
      style: TextStyle(fontSize: 16, color: theme.textTheme.bodySmall?.color),
    ),
  );

  Widget _hint(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      '输入商品名或扫条码，就能看到售价',
      style: TextStyle(fontSize: 14, color: theme.textTheme.bodySmall?.color),
    ),
  );
}
