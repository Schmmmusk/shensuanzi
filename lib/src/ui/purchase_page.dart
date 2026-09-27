/// 采购入库开单页（沉浸模式 —— 无面包屑，左侧导航仍在）。
///
/// ## 分工
///
/// - **校验与落库全在 core**（`PurchaseDraft` + `PurchaseService`，`dart test` 覆盖）。
///   本文件只做：摆放输入框、把错误标到对应栏、调 `create`、保存后的反馈。
/// - **状态以控制器为真相**：数量 / 单价 / 金额的 `TextEditingController`
///   由页面 State 持有（`_RowCtl` / `_PayCtl`），保存时**合成** `PurchaseDraft`。
///   预填进价、清空表单都是直接操作控制器，简单直接。
///
/// ## 裁定落点（`docs/reply_review.md` §X 六）
///
/// | 裁定 | 落点 |
/// |---|---|
/// | P-2 常驻付款区 + 「全款」替换 + 多账户 + 默认账户 | `_paymentSection()` |
/// | P-3 保存后**保留供应商与日期**，只清明细与付款 | `_afterSaved()` |
/// | P-4 搜索列表 + 最近使用 + 扫码枪 + 「＋新建商品」 | `_showProductPicker()` |
/// | P-5 → P-7 最小供应商新建（名称必填、电话可选） | `_showPartyPicker()` |
/// | 遗漏 1 日期默认今天可改 | `_pickDate()` |
/// | 遗漏 2 取消：空表单直接清，有内容先确认 | `_cancel()` |
/// | 遗漏 3/4 键盘 + 数字键盘 | `CallbackShortcuts` + `numberWithOptions` |
/// | 遗漏 5 合计大字 + 右对齐 + 千分位 | `_totalBar()` |
/// | 遗漏 6 预填依据 = `cost_price` | `PurchaseLineDraft.fromProduct` |
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'product_form_dialog.dart';

/// 采购入库开单页。
///
/// [service] 为 `null` 时显示「数据未就绪」（数据库没打开成功）。
class PurchasePage extends StatefulWidget {
  const PurchasePage({
    super.key,
    required this.service,
    required this.productService,
  });

  final PurchaseService service;

  /// 商品搜索与「＋新建商品」复用商品建档。
  final ProductService productService;

  @override
  State<PurchasePage> createState() => _PurchasePageState();
}

/// 一行明细的控制器（商品选择结果 + 数量 / 单价原文）
class _RowCtl {
  _RowCtl({String quantity = '', String unitPrice = ''})
    : quantity = TextEditingController(text: quantity),
      unitPrice = TextEditingController(text: unitPrice);

  /// 商品选择结果 —— 只能由「选商品」动作写入（`_pickProduct`），
  /// 不走构造参数，避免「构造时商品还没选」这种半初始化状态。
  Product? product;

  /// 单价预填进价：**只在刚选中商品时填**，用户之后改了不再覆盖
  bool pricePrefilled = false;

  final TextEditingController quantity;
  final TextEditingController unitPrice;

  bool get isEmpty =>
      product == null &&
      quantity.text.trim().isEmpty &&
      unitPrice.text.trim().isEmpty;

  /// 本行小计（分）；字段没填全 ⇒ `null`（合计按 0 处理，校验会拦）
  int? get amountCents {
    final int? qty = int.tryParse(quantity.text.trim());
    final int? price = Money.tryParseYuan(unitPrice.text.trim());
    if (qty == null || qty <= 0 || price == null || price < 0) return null;
    return qty * price;
  }

  void dispose() {
    quantity.dispose();
    unitPrice.dispose();
  }
}

/// 一条立即付款的控制器
class _PayCtl {
  _PayCtl({this.account, String amount = ''})
    : amount = TextEditingController(text: amount);

  Account? account;
  final TextEditingController amount;

  bool get isBlank => amount.text.trim().isEmpty;

  void dispose() {
    amount.dispose();
  }
}

class _PurchasePageState extends State<PurchasePage> {
  List<Account> _accounts = <Account>[];

  // ---- 表单状态 ----
  String? _partyId;
  String? _partyName;
  DateTime _date = DateTime.now();
  final TextEditingController _remark = TextEditingController();
  final List<_RowCtl> _rows = <_RowCtl>[];
  final List<_PayCtl> _pays = <_PayCtl>[];

  /// 保存失败的字段级原因（用户改任何输入后清掉）
  PurchaseDraftInvalid? _invalid;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _accounts = widget.service.activeAccounts();
    // 默认账户：第一个启用中的（一般是现金）—— 用户不用每次都选
    if (_accounts.isNotEmpty) {
      _pays.add(_PayCtl(account: _accounts.first));
    }
    _addRow();
  }

  @override
  void dispose() {
    _remark.dispose();
    for (final _RowCtl row in _rows) {
      row.dispose();
    }
    for (final _PayCtl pay in _pays) {
      pay.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------ 草稿合成

  /// 从控制器合成草稿。**控制器是真相**，草稿按需构造。
  PurchaseDraft get _draft => PurchaseDraft(
    partyId: _partyId,
    partyName: _partyName ?? '',
    date: _fmtDate(_date),
    remark: _remark.text,
    lines: <PurchaseLineDraft>[
      for (final _RowCtl row in _rows)
        PurchaseLineDraft(
          productId: row.product?.id ?? '',
          productName: row.product?.name ?? '',
          quantity: row.quantity.text,
          unitPrice: row.unitPrice.text,
        ),
    ],
    payments: <PurchasePaymentDraft>[
      for (final _PayCtl pay in _pays)
        PurchasePaymentDraft(
          accountId: pay.account?.id ?? '',
          accountName: pay.account?.name ?? '',
          amount: pay.amount.text,
        ),
    ],
  );

  static String _fmtDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  // ------------------------------------------------------------ 动作

  void _addRow() {
    setState(() {
      _rows.add(_RowCtl());
      _invalid = null;
    });
  }

  void _removeRow(int index) {
    setState(() {
      _rows[index].dispose();
      _rows.removeAt(index);
      if (_rows.isEmpty) _addRow();
      _invalid = null;
    });
  }

  void _addPayment() {
    setState(() {
      _pays.add(
        _PayCtl(account: _accounts.isEmpty ? null : _accounts.first),
      );
      _invalid = null;
    });
  }

  void _removePayment(int index) {
    setState(() {
      _pays[index].dispose();
      _pays.removeAt(index);
      _invalid = null;
    });
  }

  /// 「全款」：**替换**语义 —— 清掉已有多条付款，填入一条等额
  /// （点全款意味着「我不打算部分付了」）。
  void _fillFullPayment() {
    final int total = _draft.totalCents;
    setState(() {
      for (final _PayCtl pay in _pays) {
        pay.dispose();
      }
      _pays
        ..clear()
        ..add(
          _PayCtl(
            account: _accounts.isEmpty ? null : _accounts.first,
            amount: Money.format(total),
          ),
        );
      _invalid = null;
    });
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: _date.subtract(const Duration(days: 730)),
      lastDate: _date.add(const Duration(days: 365)),
      helpText: '选择采购日期',
    );
    if (picked == null) return;
    setState(() => _date = picked);
  }

  /// 选供应商：底部弹层（搜索 + 新建）。返回后刷新供应商列表。
  Future<void> _pickParty() async {
    final Party? picked = await _showPartyPicker(context, widget.service);
    if (picked == null) return;
    setState(() {
      _partyId = picked.id;
      _partyName = picked.name;
      _invalid = null;
    });
  }

  /// 清除供应商 = 改为散采（当场结清）
  void _clearParty() {
    setState(() {
      _partyId = null;
      _partyName = null;
      _invalid = null;
    });
  }

  /// `create` 是**同步**的（库操作进程内完成，无 IO 等待）——
  /// 不需要 async/await；try/catch 直接接同步异常。
  void _save() {
    if (_saving) return;
    final PurchaseDraft draft = _draft;
    setState(() => _saving = true);
    try {
      final PurchaseSaved saved = widget.service.create(draft);
      _afterSaved(saved);
    } on PurchaseDraftInvalid catch (error) {
      setState(() {
        _invalid = error;
        _saving = false;
      });
    } catch (error) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '没能保存（$error）。'
            '请检查内容后重试；如果一直这样，请把这句话告诉技术支持。',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  /// 保存成功：**保留供应商与日期**（连续给同一供应商录多笔 / 补录同一天是常态），
  /// 只清明细与付款 —— 每次开单不多两步（§X 六 / P-3）。
  void _afterSaved(PurchaseSaved saved) {
    setState(() {
      for (final _RowCtl row in _rows) {
        row.dispose();
      }
      _rows.clear();
      _addRow();
      for (final _PayCtl pay in _pays) {
        pay.dispose();
      }
      _pays.clear();
      if (_accounts.isNotEmpty) {
        _pays.add(_PayCtl(account: _accounts.first));
      }
      _invalid = null;
      _saving = false;
    });

    final String due = saved.dueCents > 0
        ? '，欠款 ¥${Money.formatGrouped(saved.dueCents)}'
        : '（已结清）';
    final String partyDue = saved.partyDueCents > 0
        ? '；$_partyName 累计欠款 ¥${Money.formatGrouped(saved.partyDueCents)}'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '单号 ${saved.docNo} 已保存 ¥${Money.formatGrouped(saved.totalCents)}$due$partyDue',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// 取消：空表单直接清；有内容先确认「确定要放弃吗」
  /// （`ui_principles.md` §1.2「给『我错了也能补救』的信心」）。
  ///
  /// 本页是导航内容区的一部分（不是独立路由），「离开」即回到初始状态。
  Future<void> _cancel() async {
    final bool hasContent =
        _partyId != null ||
        _rows.any(( _RowCtl row) => !row.isEmpty) ||
        _pays.any((_PayCtl pay) => !pay.isBlank);
    if (hasContent) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('放弃这次开单？'),
          content: const Text(
            '已填写的内容会被清空，且不会保存。',
            style: TextStyle(height: 1.6),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('继续填'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('放弃'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!mounted) return;
    setState(() {
      _partyId = null;
      _partyName = null;
      _date = DateTime.now();
      _remark.clear();
      for (final _RowCtl row in _rows) {
        row.dispose();
      }
      _rows.clear();
      _addRow();
      for (final _PayCtl pay in _pays) {
        pay.dispose();
      }
      _pays.clear();
      if (_accounts.isNotEmpty) {
        _pays.add(_PayCtl(account: _accounts.first));
      }
      _invalid = null;
    });
  }

  // ------------------------------------------------------------ 选择器

  /// 商品选择器：搜索 + 最近使用 + 扫码枪回车 + 「＋新建商品」
  Future<void> _pickProduct(int rowIndex) async {
    final Product? picked = await _showProductPicker(context);
    if (picked == null || rowIndex >= _rows.length) return;
    final _RowCtl row = _rows[rowIndex];
    row.product = picked;
    // 单价预填进价 —— 只在「刚选中」时填一次，用户之后改了不再覆盖
    if (!row.pricePrefilled) {
      row.unitPrice.text = Money.format(picked.costPrice);
      row.pricePrefilled = true;
    }
    setState(() => _invalid = null);
  }

  /// 选供应商 + 最小新建
  Future<Party?> _showPartyPicker(BuildContext context, PurchaseService service) {
    return showModalBottomSheet<Party>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _PartyPickerSheet(service: service),
    );
  }

  /// 商品选择器
  ///
  /// 「最近采购」查的是 `document_lines`（采购数据，不是主数据），
  /// 所以在 `PurchaseService` 上 —— 由页面查好**当参数传入**；
  /// 搜索与新建仍走 `ProductService`。
  Future<Product?> _showProductPicker(BuildContext context) {
    return showModalBottomSheet<Product>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _ProductPickerSheet(
        service: widget.productService,
        recentProducts: widget.service.recentlyPurchased(),
      ),
    );
  }

  // ------------------------------------------------------------ 摆放

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _headerRow(theme),
                  const Divider(height: 24),
                  _linesSection(theme),
                  _totalBar(theme),
                  const Divider(height: 24),
                  _paymentSection(theme),
                  const SizedBox(height: 16),
                  _remarkField(),
                  const SizedBox(height: 24),
                  _actions(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 供应商 + 日期
  Widget _headerRow(ThemeData theme) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Expanded(
        flex: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('供应商', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            InkWell(
              onTap: _pickParty,
              child: InputDecorator(
                isEmpty: _partyName == null,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  isDense: true,
                  errorText: _invalid?.fieldErrors[PurchaseField.party],
                ),
                child: Text(
                  _partyName ?? '散采（不记往来）',
                  style: TextStyle(height: 1.6, color: theme.colorScheme.onSurface),
                ),
              ),
            ),
            if (_partyName != null)
              TextButton(
                onPressed: _clearParty,
                child: const Text('改为散采'),
              ),
          ],
        ),
      ),
      const SizedBox(width: 16),
      Expanded(
        flex: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('日期', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            InkWell(
              onTap: _pickDate,
              child: InputDecorator(
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  isDense: true,
                  errorText: _invalid?.fieldErrors[PurchaseField.date],
                ),
                child: Text(
                  _fmtDate(_date),
                  style: TextStyle(height: 1.6, color: theme.colorScheme.onSurface),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _linesSection(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: Text('商品明细', style: theme.textTheme.titleMedium),
          ),
        ],
      ),
      if (_invalid?.fieldErrors[PurchaseField.lines] != null) ...<Widget>[
        const SizedBox(height: 4),
        Text(
          _invalid!.fieldErrors[PurchaseField.lines]!,
          style: TextStyle(color: theme.colorScheme.error, height: 1.6),
        ),
      ],
      const SizedBox(height: 8),
      for (int i = 0; i < _rows.length; i++)
        _LineCard(
          key: ValueKey<int>(i),
          row: _rows[i],
          index: i,
          errors: _invalid == null || i >= _invalid!.lineErrors.length
              ? null
              : _invalid!.lineErrors[i],
          enabled: !_saving,
          onPickProduct: () => _pickProduct(i),
          onChanged: () => setState(() => _invalid = null),
          onRemove: _rows.length > 1 ? () => _removeRow(i) : null,
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _saving ? null : _addRow,
          icon: const Icon(Icons.add),
          label: const Text('加一行'),
        ),
      ),
    ],
  );

  /// 合计：**大字 + 右对齐 + 千分位**（用户最关心的数字）
  Widget _totalBar(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: <Widget>[
        Text('合计', style: theme.textTheme.titleMedium),
        const Spacer(),
        Text(
          '¥ ${Money.formatGrouped(_draft.totalCents)}',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );

  Widget _paymentSection(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Row(
        children: <Widget>[
          Expanded(child: Text('本次付款', style: theme.textTheme.titleMedium)),
          TextButton(
            // 没有账户时「全款」只会造出一条解不开的错（账户下拉是空的），
            // 禁用而不是让它点 —— 报错必须「能照做」才能出现。
            onPressed: (_saving || _accounts.isEmpty) ? null : _fillFullPayment,
            child: const Text('全款'),
          ),
        ],
      ),
      if (_invalid?.fieldErrors[PurchaseField.payments] != null) ...<Widget>[
        const SizedBox(height: 4),
        Text(
          _invalid!.fieldErrors[PurchaseField.payments]!,
          style: TextStyle(color: theme.colorScheme.error, height: 1.6),
        ),
      ],
      const SizedBox(height: 8),
      Text(
        '留空 = 全部赊账；有供应商时欠款记到名下。',
        style: TextStyle(height: 1.6, color: theme.textTheme.bodySmall?.color),
      ),
      if (_accounts.isEmpty)
        // 死局预防：没有账户时付款行永远解不开「请选一个资金账户」。
        // 给一条**能照做**的内联提示（橙色，§1.3），而不是摆一个必错的输入区。
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '还没有资金账户，先到「账户」页新建一个再付款；在那之前只能全赊（需选供应商）。',
            style: TextStyle(height: 1.6, color: const Color(0xFFB45309)),
          ),
        )
      else ...<Widget>[
        const SizedBox(height: 8),
        for (int i = 0; i < _pays.length; i++)
          _PayCard(
            key: ValueKey<int>(i),
            pay: _pays[i],
            accounts: _accounts,
            index: i,
            errors: _invalid == null || i >= _invalid!.paymentErrors.length
                ? null
                : _invalid!.paymentErrors[i],
            enabled: !_saving,
            onAccountChanged: (Account? account) =>
                setState(() => _pays[i].account = account),
            onChanged: () => setState(() => _invalid = null),
            onRemove: _pays.length > 1 ? () => _removePayment(i) : null,
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _saving ? null : _addPayment,
            icon: const Icon(Icons.add),
            label: const Text('添加账户'),
          ),
        ),
      ],
    ],
  );

  Widget _remarkField() => TextField(
    controller: _remark,
    enabled: !_saving,
    maxLines: 2,
    decoration: const InputDecoration(
      labelText: '备注（可选）',
      border: OutlineInputBorder(),
    ),
  );

  Widget _actions(ThemeData theme) => Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: <Widget>[
      TextButton(
        onPressed: _saving ? null : _cancel,
        child: const Text('取消 (Esc)'),
      ),
      const SizedBox(width: 16),
      FilledButton.icon(
        onPressed: _saving ? null : _save,
        icon: _saving
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save_outlined),
        label: const Text('保存 (Ctrl+S)'),
      ),
    ],
  );
}

/// 一行明细的摆放。控制器由页面持有，本组件**无状态**。
class _LineCard extends StatelessWidget {
  const _LineCard({
    super.key,
    required this.row,
    required this.index,
    required this.errors,
    required this.enabled,
    required this.onPickProduct,
    required this.onChanged,
    required this.onRemove,
  });

  final _RowCtl row;
  final int index;
  final Map<PurchaseLineField, String>? errors;
  final bool enabled;
  final VoidCallback onPickProduct;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  flex: 5,
                  child: InkWell(
                    onTap: enabled ? onPickProduct : null,
                    child: InputDecorator(
                      isEmpty: row.product == null,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        isDense: true,
                        errorText: errors?[PurchaseLineField.product],
                      ),
                      child: Text(
                        row.product?.name ?? '点此选商品',
                        style: TextStyle(
                          height: 1.6,
                          color: row.product == null
                              ? theme.hintColor
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (onRemove != null)
                  IconButton(
                    tooltip: '删除这一行',
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('purchase-qty'),
                    controller: row.quantity,
                    enabled: enabled,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.next,
                    // P-6：Enter 到下一格（桌面端没有虚拟键盘，要显式切焦点）
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    onChanged: (_) => onChanged(),
                    decoration: InputDecoration(
                      labelText: '数量',
                      isDense: true,
                      errorText: errors?[PurchaseLineField.quantity],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: const Key('purchase-price'),
                    controller: row.unitPrice,
                    enabled: enabled,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    onChanged: (_) => onChanged(),
                    decoration: InputDecoration(
                      labelText: '单价（元）',
                      isDense: true,
                      errorText: errors?[PurchaseLineField.unitPrice],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 96,
                  child: Text(
                    row.product == null ? '' : '¥ ${Money.formatGrouped(row.amountCents ?? 0)}',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      height: 1.6,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条立即付款的摆放。控制器由页面持有。
class _PayCard extends StatelessWidget {
  const _PayCard({
    super.key,
    required this.pay,
    required this.accounts,
    required this.index,
    required this.errors,
    required this.enabled,
    required this.onAccountChanged,
    required this.onChanged,
    required this.onRemove,
  });

  final _PayCtl pay;
  final List<Account> accounts;
  final int index;
  final Map<PurchasePaymentField, String>? errors;
  final bool enabled;
  final ValueChanged<Account?> onAccountChanged;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: <Widget>[
        Expanded(
          flex: 3,
          // 用**完全受控**的 DropdownButton 而不是 DropdownButtonFormField：
          // ① 后者的 `value:` 已废弃、`initialValue:` 只在首帧生效 ——
          //    而本页用 ValueKey 复用卡片（删行 / 清空后下标会挪），FormField
          //    的内部状态会跟控制器错位，显示一个已不存在的选择；
          // ② 控制器（`pay.account`）是真相，受控组件才与「控制器为真相」一致。
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: '账户',
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: errors?[PurchasePaymentField.account],
            ),
            child: DropdownButton<Account>(
              value: pay.account,
              isDense: true,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: <DropdownMenuItem<Account>>[
                for (final Account account in accounts)
                  DropdownMenuItem<Account>(
                    value: account,
                    child: Text(account.name, style: const TextStyle(height: 1.6)),
                  ),
              ],
              onChanged: enabled ? onAccountChanged : null,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextField(
            key: const Key('purchase-pay-amount'),
            controller: pay.amount,
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              labelText: '金额（元）',
              isDense: true,
              errorText: errors?[PurchasePaymentField.amount],
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (onRemove != null)
          IconButton(
            tooltip: '删除这一笔',
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline),
          )
        else
          const SizedBox(width: 48),
      ],
    ),
  );
}

/// 供应商选择器（搜索 + 最小新建）。
///
/// 空查询列出全部启用中的供应商；搜索按名称过滤（客户端过滤，量级足够）。
class _PartyPickerSheet extends StatefulWidget {
  const _PartyPickerSheet({required this.service});

  final PurchaseService service;

  @override
  State<_PartyPickerSheet> createState() => _PartyPickerSheetState();
}

class _PartyPickerSheetState extends State<_PartyPickerSheet> {
  final TextEditingController _query = TextEditingController();
  late List<Party> _items = widget.service.activeSuppliers();
  String? _newNameError;
  bool _creating = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search(String text) {
    final String q = text.trim();
    setState(() {
      // ⚠️ 不能 `activeSuppliers()..removeWhere(...)` —— DAO 返回的是**定长列表**
      // （sqlite3 的结果行不是 growable），removeWhere 直接抛
      // `Cannot remove from a fixed-length list`，而且 onChanged 里每敲一个字崩一次。
      // 用 where().toList() 生成新列表，不碰原对象。
      _items = widget.service
          .activeSuppliers()
          .where((Party party) => q.isEmpty || party.name.contains(q))
          .toList();
    });
  }

  Future<void> _create() async {
    // 搜索框里已有的文字就是供应商名称（少一步复制粘贴）；空名必须拦 ——
    // 「名称必填」是 P-7 的约定，默默造一个「供应商」会让列表长出垃圾数据。
    final String name = _query.text.trim();
    setState(() => _creating = true);
    try {
      final Party party = widget.service.createSupplier(name);
      if (!mounted) return;
      Navigator.of(context).pop(party);
    } on StateError {
      if (!mounted) return;
      setState(() {
        _newNameError = '请先在上面输入供应商名称';
        _creating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('选择供应商', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            key: const Key('picker-search'),
            controller: _query,
            autofocus: true,
            onChanged: _search,
            onSubmitted: _search,
            decoration: InputDecoration(
              labelText: '搜索 / 输入新供应商名称',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: _newNameError,
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _items.length,
              itemBuilder: (BuildContext context, int index) => ListTile(
                dense: true,
                title: Text(_items[index].name, style: const TextStyle(height: 1.6)),
                subtitle: _items[index].phone == null
                    ? null
                    : Text(_items[index].phone!),
                onTap: () => Navigator.of(context).pop(_items[index]),
              ),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: _creating ? null : _create,
            icon: const Icon(Icons.person_add_alt),
            label: const Text('新建供应商（用上面的名称）'),
          ),
        ],
      ),
    ),
  );
}

/// 商品选择器：搜索 + 最近使用 + 「＋新建商品」（复用商品建档对话框）。
class _ProductPickerSheet extends StatefulWidget {
  const _ProductPickerSheet({
    required this.service,
    required this.recentProducts,
  });

  final ProductService service;

  /// 空查询时展示的「最近采购」列表 —— 由页面查好传入
  /// （查询在 `PurchaseService` 上，本组件只拿 `ProductService` 做搜索与新建）。
  final List<Product> recentProducts;

  @override
  State<_ProductPickerSheet> createState() => _ProductPickerSheetState();
}

class _ProductPickerSheetState extends State<_ProductPickerSheet> {
  final TextEditingController _query = TextEditingController();
  late List<Product> _items = List<Product>.of(widget.recentProducts);
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
          ? List<Product>.of(widget.recentProducts)
          : widget.service.list(query: q, limit: 50);
    });
  }

  Future<void> _createProduct() async {
    // 复用商品建档对话框（§X P-4：搜不到就建，不打断录入）
    final Product? created = await showProductFormDialog(
      context,
      service: widget.service,
    );
    if (created == null || !mounted) return;
    Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('选择商品', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            key: const Key('picker-search'),
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
            _searched ? '搜索结果' : '最近采购',
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
                      _searched ? '没有匹配的商品，可以点下面新建。' : '还没有采购记录，直接搜索或新建。',
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
                        '${_items[index].code}  ·  进价 ¥${Money.format(_items[index].costPrice)}',
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
