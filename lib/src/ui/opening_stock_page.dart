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

import 'app_dialog.dart';
import 'product_form_dialog.dart';
import 'notice.dart';

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
    this.onStorageFailure,
    this.documentSink,
  });

  /// **盘点单的提交出口**（2026-10-20 放开手机「重新清点」，§CV·七十八）。
  ///
  /// `null`（桌面 / 未装配）⇒ 走 [service]（`StocktakeService` 直连主库）。
  /// 手机 ⇒ `QueueSink`：把「实际数量」打进一条 stocktake 单据入队，
  /// **差额由主机算**（`RuleEngine._stocktake`）—— 客户端零规则。
  final DocumentSink? documentSink;

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

  /// **#43（2026-10-16）**：保存失败的**原始异常**出口（M15 同款两通道：
  /// 界面只给 `storageFailureNote` 的分类文案，异常全文进宿主日志）。
  final void Function(Object error, StackTrace stack)? onStorageFailure;

  @override
  State<OpeningStockPage> createState() => _OpeningStockPageState();
}

/// 一行的编辑状态（遗漏 6 的已知限制：每行一个控制器）
class _RowCtl {
  Product? product;
  final TextEditingController quantity = TextEditingController();

  /// **录入单位**（2026-11-24 多单位）：`null` = 按最小单位填；
  /// 等于商品的 `packageUnit` 时按包装填（换算由 core 的 `toBaseQuantity` 做）。
  ///
  /// ⚠️ 只改 UI 状态，**不改 core**：落库的 `document_lines.quantity` 仍是
  /// 「最小单位实际数量」这一条不变式（`data_model.md` §3.2）。
  String? entryUnit;

  void dispose() => quantity.dispose();
}

class _OpeningStockPageState extends State<OpeningStockPage> {
  List<_RowCtl> _rows = <_RowCtl>[_RowCtl()];

  /// 整页级错误（遗漏 4：失败不清输入，只显示这里）
  String? _topError;

  /// 行级错误（键 = 行下标；校验失败时按行标红）
  Map<int, String> _lineErrors = const <int, String>{};

  bool _busy = false;

  String get _pageTitle => widget.isFirstTime ? '录入现有货物' : '重新清点';

  @override
  void dispose() {
    for (final _RowCtl row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  /// 该行换算后的**最小单位数量**（`null` = 没填 / 填了非法 / 没选商品）。
  ///
  /// 换算**不在这里自己算**：调 core 的纯函数 `toBaseQuantity`（三份开单草稿
  /// 用的是同一个）——「UI 不懂业务」这条不破。
  int? _baseQuantityOf(_RowCtl row) {
    final Product? product = row.product;
    if (product == null) return null;
    final int? typed = int.tryParse(row.quantity.text.trim());
    if (typed == null) return null;
    return toBaseQuantity(
      entryQuantity: typed,
      entryUnit: row.entryUnit,
      baseUnit: product.unit,
      packageUnit: product.packageUnit,
      packageSize: product.packageSize,
    ).baseQuantityOrNull;
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
          // 落库的永远是**最小单位数量**（按箱填的在这里就已经乘好了）
          quantity: switch (_baseQuantityOf(row)) {
            final int base => '$base',
            null => '',
          },
          // P1-1（2026-11-27）：**录入原文**一并交给草稿 —— 单据详情要能回看
          // 「2 箱」。没切单位时原文两列留空（不编造），见
          // `StocktakeLineDraft.entryQuantityValue` 的注释。
          entryQuantity: row.entryUnit == null ? '' : row.quantity.text.trim(),
          entryUnit: row.entryUnit,
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
      builder: (BuildContext sheetContext) => _OpeningProductPickerSheet(
        service: widget.productService,
        sink: widget.masterDataSink,
      ),
    );
    if (picked == null || index >= _rows.length) return;
    setState(() {
      _rows[index].product = picked;
      // 换了商品 ⇒ 录入单位必须归零：上一件的「箱」可能是这一件没配的包装单位
      _rows[index].entryUnit = null;
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
      builder: (BuildContext dialogContext) => AppDialog(
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
      builder: (BuildContext dialogContext) => AppDialog(
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

    final StocktakeDraft draft = _draft();
    // 手机：走队列出口（差额由主机算）—— 桌面 / 未装配：原路径零变化。
    //
    // ⚠️ 判据是**「这个出口能不能提交盘点单」**，不是「sink 非空」。
    // 2026-11-17 真实用户 P0：桌面壳的 `ServiceSink` 没装盘点服务，页面见非空就走它
    // ⇒ `Bad state: 这个出口没有装配盘点服务` ⇒ 填的数量一条都没落库，还弹了
    // 「未捕获异常」。能力位见 `DocumentSink.canSubmitStocktake`。
    final DocumentSink? sink = widget.documentSink;
    if (sink != null && sink.canSubmitStocktake) {
      final DocumentSubmitResult submitted;
      try {
        submitted = sink.submitStocktake(draft);
      } catch (error, stack) {
        // 出口自己炸了也不许把页面卡在 _busy、更不许抛到 zone（那会变成「未捕获异常」）
        widget.onStorageFailure?.call(error, stack);
        if (!mounted) return;
        setState(() {
          _busy = false;
          _topError =
              '保存失败：$error\n你填的内容都还在，'
              '改好后重新点「$_pageTitle」再试。';
        });
        return;
      }
      if (!mounted) return;
      final Object? error = submitted.error;
      if (error != null) {
        setState(() {
          _busy = false;
          _topError = error is DraftInvalidException
              ? error.summary
              : '没能记上：$error\n你填的内容都还在，改好后重试。';
        });
        return;
      }
      // ✅ 成功（入队 or 直落都算）—— 老写法把 `isQueued == false` 当失败，
      // 宿主出口一旦接上就会「明明记上了却报没记上」。
      showSnack(
        context,
        SnackBar(
          content: Text(
            submitted.isQueued
                ? '已记录 ${draft.filledCount} 件商品，等同步后电脑上的库存会按实际数量校正'
                : '已记入库存：${draft.filledCount} 件商品',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
      widget.onDone();
      return;
    }

    final StocktakeResult result;
    try {
      // ⚠️ 遗漏 4：失败路径**一律不清输入** —— 没有撤销余地，改完重交
      result = widget.service.create(draft);
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
        _topError =
            '保存失败：${error.message}\n你填的内容都还在，'
            '改好后重新点「记入库存」试试。';
      });
      return;
    } on RuleRejected catch (error) {
      // #23（裁定甲）：期初的业务拒绝（现无可达拒绝 —— 防御性分支，
      // 与 stocktake 服务的类型化配套）。文案照实显示，表单保留。
      setState(() {
        _busy = false;
        _topError = error.reason;
      });
      return;
    } catch (error, stack) {
      // #43：原始异常进日志，界面只给分类文案（M15 两通道）
      widget.onStorageFailure?.call(error, stack);
      setState(() {
        _busy = false;
        _topError = storageFailureNote(error);
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
    showSnack(
      context,
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

  /// 顶部说明（2026-11-24：两段长文 → **一张常驻说明卡**，三句话说完）。
  ///
  /// 语义一条不少（用户裁定「原来的语义设计很好，不要推翻」）：
  /// 实际数量 / 再录一遍是改写 / 0 合法 / 期初成本按 0。
  Widget _explanation(ThemeData theme) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '请填写店里现在实际有多少',
          style: const TextStyle(height: 1.6, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '不是新进了多少。同一种商品再清点一次，会把库存改成这次填的数量；'
          '卖光了填 0。期初成本按 0 记，之后正常采购会逐步校准。',
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
      ],
    ),
  );

  Widget _linesCard(ThemeData theme) => Column(
    children: <Widget>[
      for (int i = 0; i < _rows.length; i++) ...<Widget>[
        _openingCard(theme, i),
        const SizedBox(height: 12),
      ],
    ],
  );

  /// 一件商品一张卡片（2026-11-24 用户裁定：从"填一张表"变成"逐件核对"）。
  ///
  /// 卡片里必须**同时**有「当前账面 / 实际库存 / 盘点结果」——
  /// 让用户不用自己拿计算器减一遍（`docs/reply.md` 一·建议）。
  Widget _openingCard(ThemeData theme, int index) {
    final _RowCtl row = _rows[index];
    final Product? product = row.product;
    final String unit = product?.unit ?? '';
    final int book = product == null
        ? 0
        : (widget.bookQuantities[product.id] ?? 0);
    final int? base = _baseQuantityOf(row);
    final TextStyle labelStyle = TextStyle(
      fontSize: 12,
      height: 1.4,
      color: theme.textTheme.bodySmall?.color,
    );
    final TextStyle bigStyle = const TextStyle(
      fontSize: 18,
      height: 1.3,
      fontWeight: FontWeight.w700,
    );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                // 选商品：点开选择器（空查询显示全部商品 + 新建入口）
                Expanded(
                  child: InkWell(
                    key: Key('opening-product-$index'),
                    onTap: _busy ? null : () => _pickProduct(index),
                    child: InputDecorator(
                      isEmpty: product == null,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        isDense: true,
                        errorText: _lineErrors[index] != null && product == null
                            ? _lineErrors[index]
                            : null,
                      ),
                      child: Text(
                        product?.name ?? '选择商品',
                        style: TextStyle(
                          height: 1.6,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
                // 删除：**文字**，不是一个「×」（用户：别让中老年猜图标）
                TextButton.icon(
                  key: Key('opening-remove-$index'),
                  onPressed: _busy ? null : () => _removeRow(index),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('删除这一行'),
                ),
              ],
            ),

            if (product != null) ...<Widget>[
              if (product.code.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(product.code, style: labelStyle),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 28,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: <Widget>[
                  // 当前账面（大字：它是"跟什么比"的基准）
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('当前账面', style: labelStyle),
                      Text(
                        '$book ${unit.isEmpty ? '' : unit}',
                        style: bigStyle,
                      ),
                    ],
                  ),
                  // 实际库存（输入 + 单位）
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('实际库存', style: labelStyle),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          SizedBox(
                            width: 96,
                            child: TextField(
                              key: Key('opening-qty-$index'),
                              controller: row.quantity,
                              enabled: !_busy,
                              keyboardType: TextInputType.number,
                              inputFormatters: <TextInputFormatter>[
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              style: bigStyle,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _unitPicker(theme, index, product),
                        ],
                      ),
                    ],
                  ),
                  // 盘点结果（差额：正数黑、负数红、0 灰）
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('盘点结果', style: labelStyle),
                      Text(
                        _deltaText(base, book, unit),
                        key: Key('opening-delta-$index'),
                        style: base == null
                            ? labelStyle
                            : bigStyle.copyWith(
                                color: base < book
                                    ? theme.colorScheme.error
                                    : null,
                              ),
                      ),
                    ],
                  ),
                ],
              ),
              // 按包装填时，把换算结果读回来（「2 箱 = 48 瓶」）——
              // 填错一眼能看出，不用等到保存后看库存数
              if (row.entryUnit != null &&
                  row.entryUnit != product.unit &&
                  base != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${row.quantity.text.trim()} ${row.entryUnit} = $base ${product.unit}',
                    key: Key('opening-converted-$index'),
                    style: TextStyle(
                      height: 1.5,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ),
              if (_lineErrors[index] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _lineErrors[index]!,
                    style: TextStyle(
                      height: 1.5,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 盘点结果那一格的文案：`将增加 12 瓶` / `将减少 7 瓶` / `无变化` / `还没填`
  String _deltaText(int? base, int book, String unit) {
    if (base == null) return '还没填';
    final int delta = base - book;
    final String suffix = unit.isEmpty ? '' : ' $unit';
    if (delta > 0) return '将增加 $delta$suffix';
    if (delta < 0) return '将减少 ${-delta}$suffix';
    return '无变化';
  }

  /// 录入单位（只有配置了包装换算的商品才给下拉）。
  ///
  /// 没配置时不摆下拉、只显示一个单位标签 —— 摆一个只有一项的下拉，
  /// 用户会反复点它找"别的单位"。
  Widget _unitPicker(ThemeData theme, int index, Product product) {
    final String base = product.unit;
    final String? pkg = product.packageUnit;
    final int? size = product.packageSize;
    final bool hasPackage =
        pkg != null && pkg.isNotEmpty && size != null && size > 0;
    if (!hasPackage) {
      return Text(base, style: const TextStyle(height: 1.6));
    }
    final _RowCtl row = _rows[index];
    return DropdownButton<String>(
      key: Key('opening-unit-$index'),
      value: row.entryUnit ?? base,
      isDense: true,
      underline: const SizedBox.shrink(),
      onChanged: _busy
          ? null
          : (String? value) => setState(() => row.entryUnit = value),
      items: <DropdownMenuItem<String>>[
        DropdownMenuItem<String>(value: base, child: Text(base)),
        DropdownMenuItem<String>(
          value: pkg,
          child: Text('$pkg（= $size $base）'),
        ),
      ],
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
          child: const Text('核对并记入库存'),
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
  const _OpeningProductPickerSheet({required this.service, required this.sink});

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
                      _searched ? '没有匹配的商品，可以点下面新建。' : '还没有商品档案，点下面新建。',
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
