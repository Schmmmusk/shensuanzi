/// 期初录入页（§AB / §AD：「把店里已有的货一次记进来」）。
///
/// ## 裁定落点（`docs/reply_review.md` §AD）
///
/// - **语义**：一次 RULE-009 盘点单 —— 本页只摆放，判断全在 core 的
///   `StocktakeDraft` / `StocktakeService`
/// - **遗漏 2**：标题由宿主传入的 [isFirstTime] 决定 —— 首次「录入现有货物」，
///   再次「重新清点」（页面相同，只有文案不同）
/// - **AB-2 / AB-3**：顶部说明**实际数量语义**与「成本按 0 记」；行内显示
///   **当前账面数 + 实时差额**（建议 1：差额是理解「实际数量」的唯一途径）
/// - **AD-5**：确认弹窗用**用户语言**（「记下之后不能取消」，不是「不可撤销」）
///   + 摘要（「即将记录 N 件商品」—— 给用户最后核对的机会）
/// - **遗漏 4**：提交失败（校验 / 规则拒绝 / 异常）时**页面状态完整保留**
///   —— 只显示错误，不清任何输入（没有「撤销」余地，状态保留更关键）
/// - **遗漏 6（记录在案）**：每行一个 `TextEditingController`，500 行级别的
///   商品量会慢 —— v1 接受此限制，待重构阶段换懒加载行
/// - **AD-2（附条件）**：商品选择器复制第三份（采购 / 销售 / 本页）——
///   ⚠️ **第四处出现时强制抽共享；在此之前任何一份的修复必须同步三处**。
///   与采购页的**真实差异**：空查询显示**全部商品**（首次录入没有「最近」）
///   —— 不能靠复制出这个差异，见 `_OpeningProductPickerSheet`
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'product_form_dialog.dart';

/// 期初录入页。
class OpeningStockPage extends StatefulWidget {
  const OpeningStockPage({
    super.key,
    required this.service,
    required this.productService,
    required this.masterDataSink,
    required this.isFirstTime,
    required this.bookQuantities,
    required this.onDone,
  });

  final StocktakeService service;
  final ProductService productService;

  /// 期初里「新建商品」的**提交出口**（本页在手机端被引导接管 ⇒ 能进来的只有
  /// 桌面 == 主机，宿主传的是 `ServiceMasterSink`；见 `stock_page.dart` 的说明）。
  final MasterDataSink masterDataSink;

  /// `true` = 库存无任何流水（首次）→「录入现有货物」；`false` →「重新清点」
  final bool isFirstTime;

  /// 各商品的**当前账面数**（§AD 建议 1：页面持有一份快照，行内显示与
  /// 差额都从它算）。宿主（库存页）在打开本页时查好。
  final Map<String, int> bookQuantities;

  /// 完成（提交成功 / 用户放弃）→ 宿主关闭本页并刷新数字
  final VoidCallback onDone;

  @override
  State<OpeningStockPage> createState() => _OpeningStockPageState();
}

/// 一行的编辑状态（遗漏 6 的已知限制：每行一个控制器）
class _RowCtl {
  Product? product;
  final TextEditingController quantity = TextEditingController();

  void dispose() => quantity.dispose();
}

class _OpeningStockPageState extends State<OpeningStockPage> {
  List<_RowCtl> _rows = <_RowCtl>[_RowCtl()];

  /// 整页级错误（遗漏 4：失败不清输入，只显示这里）
  String? _topError;

  /// 行级错误（键 = 行下标；校验失败时按行标红）
  Map<int, String> _lineErrors = const <int, String>{};

  bool _busy = false;

  String get _pageTitle =>
      widget.isFirstTime ? '录入现有货物' : '重新清点';

  @override
  void dispose() {
    for (final _RowCtl row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  StocktakeDraft _draft() => StocktakeDraft(
    // §审查 OBS-09①：备注要说清是「期初建账」还是「重新清点」——
    // 原来写死成「期初录入」，重新清点出来的单据也跟着这么写
    isOpening: widget.isFirstTime,
    lines: <StocktakeLineDraft>[
      for (final _RowCtl row in _rows)
        StocktakeLineDraft(
          productId: row.product?.id ?? '',
          productName: row.product?.name ?? '',
          quantity: row.quantity.text,
        ),
    ],
  );

  // ------------------------------------------------------------ 动作

  void _addRow() => setState(() {
    _rows = <_RowCtl>[..._rows, _RowCtl()];
    _lineErrors = const <int, String>{};
  });

  void _removeRow(int index) => setState(() {
    final List<_RowCtl> rows = <_RowCtl>[..._rows];
    rows.removeAt(index).dispose();
    _rows = rows;
    _lineErrors = const <int, String>{};
    _topError = null;
  });

  Future<void> _pickProduct(int index) async {
    final Product? picked = await showModalBottomSheet<Product>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) =>
          _OpeningProductPickerSheet(
            service: widget.productService,
            sink: widget.masterDataSink,
          ),
    );
    if (picked == null || index >= _rows.length) return;
    setState(() {
      _rows[index].product = picked;
      _lineErrors = const <int, String>{};
      _topError = null;
    });
  }

  /// 取消（§X-3 同构）：空表单直接退；有内容先确认
  Future<void> _cancel() async {
    if (_busy) return;
    if (_draft().filledCount == 0) {
      widget.onDone();
      return;
    }
    final bool? abandon = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('放弃这次录入吗？'),
        content: const Text('已填的内容会清空。', style: TextStyle(height: 1.6)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('留在本页'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (abandon ?? false) widget.onDone();
  }

  /// 保存前确认（AD-5 裁定文案：摘要 + 用户语言）。
  ///
  /// ⚠️ **校验先于确认**：不可能通过的内容（行级错 / 重复商品）就地报错，
  /// 不该先问用户「确认吗」再失败 —— 确认弹窗只在草稿整体合法时出现。
  Future<void> _save() async {
    if (_busy) return;

    if (_draft().filledCount == 0) {
      setState(() {
        _topError = '至少要填一行：选商品，填店里实际有多少';
        _lineErrors = const <int, String>{};
      });
      return;
    }

    final StocktakeValidation validation = _draft().validate();
    if (!validation.isValid) {
      setState(() {
        _topError = validation.topError;
        _lineErrors = validation.lineErrors;
      });
      return;
    }

    final int count = _draft().filledCount;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('确认录入'),
        content: Text(
          '即将记录 $count 件商品的实际数量。\n\n'
          '记下之后不能取消。如果数错了，'
          '重新点「$_pageTitle」再录一次就行。',
          style: const TextStyle(height: 1.6),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('opening-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认录入'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await _submit();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _topError = null;
      _lineErrors = const <int, String>{};
    });

    final StocktakeResult result;
    try {
      // ⚠️ 遗漏 4：失败路径**一律不清输入** —— 没有撤销余地，改完重交
      result = widget.service.create(_draft());
    } on StocktakeDraftInvalid catch (error) {
      setState(() {
        _busy = false;
        _topError = error.summary;
        _lineErrors = error.validation.lineErrors;
      });
      return;
    } on StateError catch (error) {
      setState(() {
        _busy = false;
        _topError = '保存失败：${error.message}\n你填的内容都还在，'
            '改好后重新点「记入库存」试试。';
      });
      return;
    } catch (error) {
      setState(() {
        _busy = false;
        _topError = '保存失败（$error）。\n你填的内容都还在，'
            '改好后重新点「记入库存」试试。';
      });
      return;
    }

    // 成功（建议 2：全部无变化要给**诚实**的反馈，不能假装改了什么）
    final String message = result.changedCount == 0
        ? '已提交：${result.unchangedCount} 件商品都无变化，无需更新'
        : result.unchangedCount == 0
            ? '已录入 ${result.changedCount} 件商品'
            : '已录入 ${result.changedCount + result.unchangedCount} 件商品'
                '（其中 ${result.unchangedCount} 件无变化）';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
    widget.onDone();
  }

  // ------------------------------------------------------------ 摆放

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(_pageTitle, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              _explanation(theme),
              const SizedBox(height: 12),

              if (_topError != null) ...<Widget>[
                // 遗漏 4：错误放在顶部，输入原样保留在下面
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _topError!,
                      style: TextStyle(
                        height: 1.6,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              _linesCard(theme),

              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('opening-add-row'),
                  onPressed: _busy ? null : _addRow,
                  icon: const Icon(Icons.add),
                  label: const Text('加一行'),
                ),
              ),
              const SizedBox(height: 16),
              _actions(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _explanation(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        '开店时店里已经有的货，在这里一次记入。'
        '以后按采购 / 销售正常记，不用再管这一页。',
        style: TextStyle(height: 1.6, color: theme.textTheme.bodySmall?.color),
      ),
      const SizedBox(height: 4),
      Text(
        '下面填的是「实际有多少」，不是新进了多少；'
        '同一个商品再录一遍，就是把库存改成后来那个数。'
        '期初成本按 0 记，库存金额会偏低；下次采购时进价会校准成本。',
        style: TextStyle(height: 1.6, color: theme.textTheme.bodySmall?.color),
      ),
    ],
  );

  Widget _linesCard(ThemeData theme) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: <Widget>[
        for (int i = 0; i < _rows.length; i++) ...<Widget>[
          if (i > 0) const Divider(height: 1),
          _openingRow(theme, i),
        ],
      ],
    ),
  );

  Widget _openingRow(ThemeData theme, int index) {
    final _RowCtl row = _rows[index];
    final Product? product = row.product;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 选商品：点开选择器（空查询显示全部商品 + 新建入口）。
              // ⚠️ 刻意**不带 labelText**：label 与子级占位「选择商品」会叠画
              // （真机 2026-09-28）；采购页同款写法已真机验证
              Expanded(
                child: InkWell(
                  key: Key('opening-product-$index'),
                  onTap: _busy ? null : () => _pickProduct(index),
                  child: InputDecorator(
                    isEmpty: product == null,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText: _lineErrors[index] != null &&
                              product == null
                          ? _lineErrors[index]
                          : null,
                    ),
                    child: Text(
                      product?.name ?? '选择商品',
                      style: TextStyle(
                        height: 1.6,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 110,
                child: TextField(
                  key: Key('opening-qty-$index'),
                  controller: row.quantity,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: InputDecoration(
                    // ⚠️ 用短标签「数量」：110px 放不下「实际有多少」会截断
                    // （真机 2026-09-28）；语义由顶部说明 + 差额行承担
                    labelText: '数量',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: product != null ? _lineErrors[index] : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: Key('opening-remove-$index'),
                tooltip: '删掉这一行',
                onPressed: _busy ? null : () => _removeRow(index),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (product != null) _diffText(theme, index),
        ],
      ),
    );
  }

  /// 当前账面 + 实时差额（建议 1：差额是理解「实际数量」的唯一途径）
  Widget _diffText(ThemeData theme, int index) {
    final _RowCtl row = _rows[index];
    final int? qty = int.tryParse(row.quantity.text.trim());
    final int book = widget.bookQuantities[row.product!.id] ?? 0;
    final TextStyle grey = TextStyle(
      height: 1.6,
      color: theme.textTheme.bodySmall?.color,
    );

    final Widget diff;
    if (qty == null || qty <= 0) {
      diff = Text('当前账面 $book', style: grey);
    } else {
      final int delta = qty - book;
      diff = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('当前账面 $book  ·  ', style: grey),
          if (delta > 0)
            Text('将增加 $delta', style: TextStyle(height: 1.6)),
          if (delta < 0)
            Text(
              '将减少 ${-delta}',
              style: TextStyle(height: 1.6, color: theme.colorScheme.error),
            ),
          if (delta == 0) Text('无变化', style: grey),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: diff,
    );
  }

  Widget _actions(ThemeData theme) => Row(
    children: <Widget>[
      Expanded(
        child: OutlinedButton(
          key: const Key('opening-cancel'),
          onPressed: _busy ? null : _cancel,
          child: const Text('取消'),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        flex: 2,
        child: FilledButton(
          key: const Key('opening-save'),
          onPressed: _busy ? null : _save,
          child: const Text('记入库存'),
        ),
      ),
    ],
  );
}

/// 商品选择器（期初录入版）。
///
/// ⚠️ 与采购页 `_ProductPickerSheet` 的**真实差异**（AD-2 裁定点名）：
/// 空查询显示**全部商品** —— 期初录入的用户可能一件都没采购过，
/// 没有「最近使用」可显示。新建入口共用 `showProductFormDialog`（遗漏 3）。
class _OpeningProductPickerSheet extends StatefulWidget {
  const _OpeningProductPickerSheet({
    required this.service,
    required this.sink,
  });

  final ProductService service;

  /// 建档 / 编辑的**提交出口**（占位用户可能连一种商品都没有，这里也要能建）。
  final MasterDataSink sink;

  @override
  State<_OpeningProductPickerSheet> createState() =>
      _OpeningProductPickerSheetState();
}

class _OpeningProductPickerSheetState
    extends State<_OpeningProductPickerSheet> {
  final TextEditingController _query = TextEditingController();
  late List<Product> _items = widget.service.list(limit: 200);
  bool _searched = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search(String text) {
    final String q = text.trim();
    setState(() {
      _searched = q.isNotEmpty;
      _items = q.isEmpty
          ? widget.service.list(limit: 200) // 空查询 = 全部商品（与采购页的差异）
          : widget.service.list(query: q, limit: 50);
    });
  }

  Future<void> _createProduct() async {
    final Product? created = await showProductFormDialog(
      context,
      service: widget.service,
      sink: widget.sink,
    );
    if (created == null || !mounted) return;
    Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('选择商品', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _query,
            autofocus: true,
            onChanged: _search,
            onSubmitted: _search,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              labelText: '商品名 / 编码 / 条码（可扫码）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _searched ? '搜索结果' : '全部商品',
            style: TextStyle(
              height: 1.6,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
          Flexible(
            child: _items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      _searched
                          ? '没有匹配的商品，可以点下面新建。'
                          : '还没有商品档案，点下面新建。',
                      textAlign: TextAlign.center,
                      style: const TextStyle(height: 1.6),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _items.length,
                    itemBuilder: (BuildContext context, int index) => ListTile(
                      dense: true,
                      title: Text(
                        _items[index].name,
                        style: const TextStyle(height: 1.6),
                      ),
                      subtitle: Text(
                        _items[index].code,
                        style: TextStyle(
                          height: 1.6,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                      onTap: () => Navigator.of(context).pop(_items[index]),
                    ),
                  ),
          ),
          FilledButton.tonalIcon(
            onPressed: _createProduct,
            icon: const Icon(Icons.add),
            label: const Text('新建商品'),
          ),
        ],
      ),
    ),
  );
}
