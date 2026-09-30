/// 店内销售开单页（沉浸模式 —— 无面包屑，左侧导航仍在）。
///
/// 与 `purchase_page.dart` 同构（客户/售价/收款方向），差异与裁定落点：
///
/// | 项 | 落点 |
/// |---|---|
/// | 单价预填**售价**（默认值不是约束，改后不回写商品档） | `_pickProduct` |
/// | **散客**必须当场结清 | `_save` 报错走 `_invalid`，文案在 core |
/// | **负库存**：行内红色提示、不拦人，库存是**打开本页时**的快照（Z-2） | `_LineCard` |
/// | 客户选择器：最近往来（空查询）+ 新建走 `ensureParty`（同名追加 role，Z-4） | `_CustomerPickerSheet` |
/// | 无资金账户时橙色提示 + 「全款」禁用（死局预防，同采购页） | `_paymentSection` |
/// | 必填项红星（§Z 遗漏 7） | 各 `labelText` |
/// | v1 不显示利润（§Z 遗漏 6：SnackBar 也不带） | `_afterSaved` |
/// | 抹零：改最后一行单价即可，不做整单折扣（§Z 遗漏 2） | 无折扣控件 |
/// | **现金找零辅助行**：顾客给了 100 买 93 的货 → 当场显示「找零 ¥7.00」。
///   **落库永远是应收** —— 找零是现金箱内部的物理流动，不进
///   `immediate_payments`、不持久化；「顾客给了」< 应收显示「不够」但照常放行
///   （reply_review.md §AJ·AI-4） | `_cashChangeRow` |
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'product_form_dialog.dart';

/// 店内销售开单页。
class SalePage extends StatefulWidget {
  const SalePage({
    super.key,
    required this.service,
    required this.productService,
    required this.partyService,
  });

  final SaleService service;

  /// 商品搜索与「＋新建商品」复用商品建档。
  final ProductService productService;

  /// 客户「新建」入口（与供应商共用 ensureParty，Z-4）。
  final PartyService partyService;

  @override
  State<SalePage> createState() => _SalePageState();
}

/// 一行明细的控制器（商品选择结果 + 数量 / 单价原文）
class _RowCtl {
  _RowCtl({String quantity = '', String unitPrice = ''})
    : quantity = TextEditingController(text: quantity),
      unitPrice = TextEditingController(text: unitPrice);

  /// 商品选择结果 —— 只能由「选商品」动作写入（`_pickProduct`）。
  Product? product;

  /// 单价预填售价：**只在刚选中商品时填**，用户之后改了不再覆盖
  bool pricePrefilled = false;

  final TextEditingController quantity;
  final TextEditingController unitPrice;

  bool get isEmpty =>
      product == null &&
      quantity.text.trim().isEmpty &&
      unitPrice.text.trim().isEmpty;

  /// 数量取值；非法时 `null`（与 `PurchaseLineDraft.quantityValue` 同名对齐）
  int? get quantityValue {
    final int? qty = int.tryParse(quantity.text.trim());
    return (qty == null || qty <= 0) ? null : qty;
  }

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

/// 一条立即收款的控制器
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

class _SalePageState extends State<SalePage> {
  List<Account> _accounts = <Account>[];

  // ---- 表单状态 ----
  String? _partyId;
  String? _partyName;
  DateTime _date = DateTime.now();
  final TextEditingController _remark = TextEditingController();

  /// 「顾客给了」的原文（现金找零辅助行，§AJ·AI-4）。
  /// ⚠️ **只用于算找零** —— 永远不进 [_draft]、不落库，保存 / 取消即清。
  final TextEditingController _given = TextEditingController();
  final List<_RowCtl> _rows = <_RowCtl>[];
  final List<_PayCtl> _pays = <_PayCtl>[];

  /// **打开本页时**的库存快照（每商品账面库存）。Z-2：只用于提示，
  /// 不重查不校验 —— 负库存本来就允许，保存必然放行。
  late final Map<String, int> _stockSnapshot = widget.service.stockSnapshot();

  /// 保存失败的字段级原因（用户改任何输入后清掉）
  SaleDraftInvalid? _invalid;

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
    _given.dispose();
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
  SaleDraft get _draft => SaleDraft(
    partyId: _partyId,
    partyName: _partyName ?? '',
    date: _fmtDate(_date),
    remark: _remark.text,
    lines: <SaleLineDraft>[
      for (final _RowCtl row in _rows)
        SaleLineDraft(
          productId: row.product?.id ?? '',
          productName: row.product?.name ?? '',
          quantity: row.quantity.text,
          unitPrice: row.unitPrice.text,
        ),
    ],
    payments: <SalePaymentDraft>[
      for (final _PayCtl pay in _pays)
        SalePaymentDraft(
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

  /// 「全款」：**替换**语义 —— 清掉已有多条收款，填入一条等额
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

  // ---- 现金找零辅助（§AJ·AI-4）----

  /// 只有**第一条收款行**选了现金账户时才显示找零辅助行 ——
  /// 找零是现金的物理属性，微信 / 银行卡不存在「找零」。
  bool get _showCashChange {
    final Account? account = _pays.isEmpty ? null : _pays.first.account;
    return account != null && account.type == AccountType.cash;
  }

  /// [收整] 的整额：应收**向上取整到元**（93.50 → 94，93 → 93）。
  ///
  /// 裁定原文写「向下取整到元」，但向下取整对带角分的应收恒小于应收
  /// （必然显示「不够」），「一次点击完成算找零」就不成立了；
  /// 按个体户口语里「凑个整」的语义取向上取整。**待用户复核**（§AJ）。
  int get _roundUpYuanCents => ((_draft.totalCents + 99) ~/ 100) * 100;

  /// 找零辅助行的快捷键：收款框填**应收全额**，「顾客给了」填整额 ——
  /// 一次点击完成「算找零」。个体户的现金交易八成是整钱。
  void _quickGiven(int cents) {
    if (_pays.isEmpty || _saving) return;
    setState(() {
      _pays.first.amount.text = Money.format(_draft.totalCents);
      _given.text = Money.format(cents);
      _invalid = null;
    });
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: _date.subtract(const Duration(days: 730)),
      lastDate: _date.add(const Duration(days: 365)),
      helpText: '选择销售日期',
    );
    if (picked == null) return;
    setState(() => _date = picked);
  }

  /// 选客户：底部弹层（搜索 + 最近往来 + 新建）。返回后无需刷新列表
  /// （下一次打开弹层会重读）。
  Future<void> _pickParty() async {
    final Party? picked = await _showPartyPicker(context);
    if (picked == null) return;
    setState(() {
      _partyId = picked.id;
      _partyName = picked.name;
      _invalid = null;
    });
  }

  /// 清除客户 = 散客（当场结清）
  void _clearParty() {
    setState(() {
      _partyId = null;
      _partyName = null;
      _invalid = null;
    });
  }

  /// `create` 是**同步**的（库操作进程内完成，无 IO 等待）。
  void _save() {
    if (_saving) return;
    final SaleDraft draft = _draft;
    setState(() => _saving = true);
    try {
      final SaleSaved saved = widget.service.create(draft);
      _afterSaved(saved);
    } on SaleDraftInvalid catch (error) {
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

  /// 保存成功：**保留客户与日期**（连续给同一客户开单是常态），
  /// 只清明细与收款（§X 六 / P-3 同款）。
  /// ⚠️ v1 不显示利润（§Z 遗漏 6）—— SnackBar 只报单号与欠款。
  void _afterSaved(SaleSaved saved) {
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
      // 「顾客给了」不持久化：保存即清（§AJ·AI-4）
      _given.clear();
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
  Future<void> _cancel() async {
    final bool hasContent =
        _partyId != null ||
        _rows.any((_RowCtl row) => !row.isEmpty) ||
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
      _given.clear();
      _invalid = null;
    });
  }

  // ------------------------------------------------------------ 选择器

  Future<void> _pickProduct(int rowIndex) async {
    final Product? picked = await _showProductPicker(context);
    if (picked == null || rowIndex >= _rows.length) return;
    final _RowCtl row = _rows[rowIndex];
    row.product = picked;
    // 单价预填售价 —— 只在「刚选中」时填一次；**改后不回写商品档**
    if (!row.pricePrefilled) {
      row.unitPrice.text = Money.format(picked.sellPrice);
      row.pricePrefilled = true;
    }
    setState(() => _invalid = null);
  }

  /// 商品选择器（「最近采购」换成**最近销售**，§Z 遗漏对称）
  Future<Product?> _showProductPicker(BuildContext context) {
    return showModalBottomSheet<Product>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _ProductPickerSheet(
        service: widget.productService,
        recentProducts: widget.service.recentlySold(),
      ),
    );
  }

  /// 客户选择器（最近往来 + 新建走 ensureParty）
  Future<Party?> _showPartyPicker(BuildContext context) {
    return showModalBottomSheet<Party>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _CustomerPickerSheet(
        service: widget.service,
        partyService: widget.partyService,
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

  /// 客户 + 日期
  Widget _headerRow(ThemeData theme) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Expanded(
        flex: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('客户', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            InkWell(
              onTap: _pickParty,
              child: InputDecorator(
                isEmpty: _partyName == null,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  isDense: true,
                  errorText: _invalid?.fieldErrors[SaleField.party],
                ),
                child: Text(
                  _partyName ?? '散客（当场结清）',
                  style: TextStyle(height: 1.6, color: theme.colorScheme.onSurface),
                ),
              ),
            ),
            if (_partyName != null)
              TextButton(
                onPressed: _clearParty,
                child: const Text('改为散客'),
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
                  errorText: _invalid?.fieldErrors[SaleField.date],
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
            child: Text('商品明细 *', style: theme.textTheme.titleMedium),
          ),
        ],
      ),
      if (_invalid?.fieldErrors[SaleField.lines] != null) ...<Widget>[
        const SizedBox(height: 4),
        Text(
          _invalid!.fieldErrors[SaleField.lines]!,
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
          stockOfProduct: _rows[i].product == null
              ? null
              : _stockSnapshot[_rows[i].product!.id],
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
          Expanded(child: Text('本次收款', style: theme.textTheme.titleMedium)),
          TextButton(
            // 没有账户时「全款」只会造出一条解不开的错 —— 禁用（死局预防）
            onPressed: (_saving || _accounts.isEmpty) ? null : _fillFullPayment,
            child: const Text('全款'),
          ),
        ],
      ),
      if (_invalid?.fieldErrors[SaleField.payments] != null) ...<Widget>[
        const SizedBox(height: 4),
        Text(
          _invalid!.fieldErrors[SaleField.payments]!,
          style: TextStyle(color: theme.colorScheme.error, height: 1.6),
        ),
      ],
      const SizedBox(height: 8),
      Text(
        '留空 = 全部赊账；有客户时欠款记到名下。',
        style: TextStyle(height: 1.6, color: theme.textTheme.bodySmall?.color),
      ),
      if (_accounts.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '还没有资金账户，先到「账户」页新建一个再收款；'
            '在那之前只能全赊（需选客户）。',
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
        // 现金找零辅助行（§AJ·AI-4）：要用就用、不用就不看（不做成弹窗 ——
        // 收款是高频动作，弹窗每次都多一步）
        if (_showCashChange) ...<Widget>[
          const SizedBox(height: 4),
          _cashChangeRow(theme),
        ],
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

  /// 现金找零辅助行（§AJ·AI-4）。**只算找零，不记账**：
  /// 「顾客给了」永不出现在草稿里；小于应收显示「不够」但**照常允许提交**
  /// （用户可能只是拿它算个数）。快捷键 = 一次点击完成「算找零」。
  Widget _cashChangeRow(ThemeData theme) {
    final int total = _draft.totalCents;
    final int? given = Money.tryParseYuan(_given.text.trim());
    final bool notEnough = given != null && given < total;
    final String? changeText = given == null
        ? null
        : notEnough
            ? '不够'
            : '找零 ¥${Money.formatGrouped(given - total)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('顾客给了', style: theme.textTheme.bodySmall),
            const SizedBox(width: 8),
            SizedBox(
              width: 120,
              child: TextField(
                key: const Key('sale-given'),
                controller: _given,
                enabled: !_saving,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '选填',
                  isDense: true,
                  border: OutlineInputBorder(),
                  suffixText: '元',
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (changeText != null)
              Text(
                changeText,
                style: TextStyle(
                  height: 1.6,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                  // 「不够」是提醒不是拦截 —— 用内联橙，错误红只留给真错误
                  color: notEnough
                      ? const Color(0xFFB45309)
                      : theme.colorScheme.onSurface,
                ),
              ),
            const Spacer(),
            TextButton(
              onPressed: _saving ? null : () => _quickGiven(_roundUpYuanCents),
              child: const Text('收整'),
            ),
            TextButton(
              onPressed: _saving ? null : () => _quickGiven(5000),
              child: const Text('收 50'),
            ),
            TextButton(
              onPressed: _saving ? null : () => _quickGiven(10000),
              child: const Text('收 100'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '只用于算找零，不用记账 —— 收款框填多少，进账就是多少。',
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
      ],
    );
  }

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
    required this.stockOfProduct,
    required this.enabled,
    required this.onPickProduct,
    required this.onChanged,
    required this.onRemove,
  });

  final _RowCtl row;
  final int index;
  final Map<SaleLineField, String>? errors;

  /// 该商品的**库存快照**（打开本页时）；没选商品 / 无流水时为 `null`（按 0 理解）
  final int? stockOfProduct;
  final bool enabled;
  final VoidCallback onPickProduct;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int? qty = row.quantityValue;
    final int snapshot = stockOfProduct ?? 0;
    final bool negativeStock =
        row.product != null && qty != null && qty > snapshot;

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
                        errorText: errors?[SaleLineField.product],
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
                    key: const Key('sale-qty'),
                    controller: row.quantity,
                    enabled: enabled,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.next,
                    // P-6：Enter 到下一格（桌面端要显式切焦点）
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    onChanged: (_) => onChanged(),
                    decoration: InputDecoration(
                      labelText: '数量 *',
                      isDense: true,
                      errorText: errors?[SaleLineField.quantity],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: const Key('sale-price'),
                    controller: row.unitPrice,
                    enabled: enabled,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    onChanged: (_) => onChanged(),
                    decoration: InputDecoration(
                      labelText: '单价（元）*',
                      isDense: true,
                      errorText: errors?[SaleLineField.unitPrice],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 96,
                  child: Text(
                    row.product == null
                        ? ''
                        : '¥ ${Money.formatGrouped(row.amountCents ?? 0)}',
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
            // 库存快照（Z-2）：**提示不是校验** —— 负库存允许，保存必然放行。
            // 文案标明「打开本页时」，用户看到数字与实际有差不会以为是 bug。
            if (row.product != null) ...<Widget>[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  negativeStock
                      ? '当前库存 $snapshot（打开本页时），本单会按负库存记账（成本按最近入库价）'
                      : '当前库存 $snapshot（打开本页时）',
                  style: TextStyle(
                    height: 1.6,
                    color: negativeStock
                        ? theme.colorScheme.error
                        : theme.textTheme.bodySmall?.color,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 一条立即收款的摆放。控制器由页面持有。
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
  final Map<SalePaymentField, String>? errors;
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
          // 完全受控的 DropdownButton（理由同采购页：ValueKey 复用卡片时
          // FormField 的 initialValue 不跟控制器）
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: '账户 *',
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: errors?[SalePaymentField.account],
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
            key: const Key('sale-pay-amount'),
            controller: pay.amount,
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              labelText: '金额（元）',
              isDense: true,
              errorText: errors?[SalePaymentField.amount],
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

/// 客户选择器：搜索 + 最近往来 + 最小新建（`ensureParty`，Z-4）。
class _CustomerPickerSheet extends StatefulWidget {
  const _CustomerPickerSheet({required this.service, required this.partyService});

  final SaleService service;
  final PartyService partyService;

  @override
  State<_CustomerPickerSheet> createState() => _CustomerPickerSheetState();
}

class _CustomerPickerSheetState extends State<_CustomerPickerSheet> {
  final TextEditingController _query = TextEditingController();
  late List<Party> _items = widget.service.activeCustomers();
  bool _searched = false;
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
      _searched = q.isNotEmpty;
      // ⚠️ DAO 返回的是定长列表 —— 用 where().toList()，不 removeWhere
      _items = widget.service
          .activeCustomers()
          .where((Party party) => q.isEmpty || party.name.contains(q))
          .toList();
    });
  }

  Future<void> _create() async {
    // 搜索框里已有的文字就是客户名称；空名必须拦（P-7 同款）
    final String name = _query.text.trim();
    setState(() => _creating = true);
    try {
      final PartyMutation result = widget.partyService.ensureParty(
        name: name,
        role: PartyRole.customer,
      );
      if (!mounted) return;
      if (result.action == PartyMutationAction.roleAppended) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已有往来方「${result.party.name}」，已加为你的客户'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      Navigator.of(context).pop(result.party);
    } on StateError {
      if (!mounted) return;
      setState(() {
        _newNameError = '请先在上面输入客户名称';
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
          Text('选择客户', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            key: const Key('picker-search'),
            controller: _query,
            autofocus: true,
            onChanged: _search,
            onSubmitted: _search,
            decoration: InputDecoration(
              labelText: '搜索 / 输入新客户名称',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: _newNameError,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _searched ? '搜索结果' : '最近往来',
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
                          ? '没有匹配的客户，可以在下面新建。'
                          : '还没有往来的客户，直接在搜索框输入名称新建。',
                      textAlign: TextAlign.center,
                      style: const TextStyle(height: 1.6),
                    ),
                  )
                : ListView.builder(
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
            label: const Text('新建客户（用上面的名称）'),
          ),
        ],
      ),
    ),
  );
}

/// 商品选择器：搜索 + 最近销售 + 「＋新建商品」（复用商品建档对话框）。
class _ProductPickerSheet extends StatefulWidget {
  const _ProductPickerSheet({
    required this.service,
    required this.recentProducts,
  });

  final ProductService service;

  /// 空查询时展示的「最近销售」列表 —— 由页面查好传入。
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
            _searched ? '搜索结果' : '最近销售',
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
                      _searched ? '没有匹配的商品，可以点下面新建。' : '还没有销售记录，直接搜索或新建。',
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
                        '${_items[index].code}  ·  售价 ¥${Money.format(_items[index].sellPrice)}',
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
