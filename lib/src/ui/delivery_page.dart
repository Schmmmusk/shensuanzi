/// 送货开单页（沉浸模式 —— 无面包屑，左侧导航仍在）。批次 1b / RULE-003。
///
/// 与 `sale_page.dart` 同构，**但砍掉了整个收款区**（§AP 范围已钉死）：
///
/// | 项 | 落点 |
/// |---|---|
/// | 单价预填**售价**（默认值不是约束，改后不回写商品档） | `_pickProduct` |
/// | **客户必选**（不是散客）—— 货离店，欠款得有人挂着 | `_save` 报错走 `_invalid`，文案在 core |
/// | **负库存**：行内红色提示、不拦人，库存是**打开本页时**的快照（Z-2） | `_LineCard` |
/// | 客户选择器：最近往来（空查询）+ 新建走 `ensureParty`（同名追加 role，Z-4） | `_CustomerPickerSheet` |
/// | 必填项红星（§Z 遗漏 7） | 各 `labelText` |
///
/// ## ⚠️ 这里**没有**的东西（都是故意的）
///
/// - **收款区 / 「全款」 / 找零辅助行 / 折算告知** —— 送货单本身就是赊销
///   （`PartyLedger.amount = +total_amount`）。客户当场付款走**单据详情页的
///   「收款」**（1a 的核销，RULE-004），与开单是两件事（§AP）。
/// - **从销售单「转送货」** —— 绝对不做：RULE-003 送货单**创建即扣库存**，
///   转一次就双扣。
/// - **拒收** —— 走 RULE-007 销售退货（v1.1）。本页只给一条内联提示，
///   免得 1b 自然长出退货需求（§AP「明确不做」）。
///
/// 规则本体在 core（`RuleEngine._delivery`），本页只摆放。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart'
    show MobileGuideTopic, mirrorEmptyMessage;
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'mobile_guidance_dialog.dart';
import 'entry_unit_hints.dart';
import 'product_form_dialog.dart';

/// 店内送货页。
class DeliveryPage extends StatefulWidget {
  const DeliveryPage({
    super.key,
    required this.service,
    required this.productService,
    required this.partyService,
    required this.sink,
    this.onSubmitted,
    this.readOnlyMasterData = false,
  });

  /// 开单页**查询**用（选择器 / 库存快照 —— 读）。
  final DeliveryService service;

  /// 提交**出口**（B3b·§CA）：页面对 [DocumentSink] 编程，**不出现
  /// 「是不是客户端」的分支**。桌面 = `ServiceSink`；手机 = `QueueSink`。
  final DocumentSink sink;

  /// 提交成功回调（B3b）。手机端注入 = 刷新三态条 + 触发自动推送（裁定 ③）。
  final void Function(DocumentSubmitResult result)? onSubmitted;

  /// 手机端**主数据禁建**（C2·§CC）：`true` 时「新建客户 / 新建商品」入口
  /// **保留但点击后弹引导对话框**。桌面缺省 `false` = 现状零变化。
  final bool readOnlyMasterData;

  /// 商品搜索与「＋新建商品」复用商品建档。
  final ProductService productService;

  /// 客户「新建」入口（与供应商共用 ensureParty，Z-4）。
  final PartyService partyService;

  @override
  State<DeliveryPage> createState() => _DeliveryPageState();
}

/// 一行明细的控制器（商品选择结果 + 数量 / 单价原文）
class _RowCtl {
  _RowCtl({String quantity = '', String unitPrice = ''})
    : quantity = TextEditingController(text: quantity),
      unitPrice = TextEditingController(text: unitPrice);

  /// 商品选择结果 —— 只能由「选商品」动作写入（`_pickProduct`）。
  Product? product;

  // ---- v3 换算上下文（选商品时由 [attachProduct] 写入）----
  String? baseUnit;
  String? packageUnit;
  int? packageSize;

  /// **录入单位**：'' = 最小单位（没切）；切到包装 = [packageUnit] 原文
  String entryUnit = '';

  /// 切单位时价格没换成（除不尽，保留原值）⇒ `true`：橙色告知，不拦提交
  /// （§BG 方案 A ②）—— 与采购 / 销售**逐字段同构**，改一边必须扫另两边
  bool entryPriceKept = false;

  /// 成对启用 ⇒ 行卡显示单位切换（§BD·三 第 3 条）
  bool get canSwitchPackage =>
      packageUnit != null &&
      packageUnit!.isNotEmpty &&
      (packageSize ?? 0) > 0;

  /// 数量框 label 上显示的单位
  String get entryUnitDisplay =>
      entryUnit.isNotEmpty ? entryUnit : (baseUnit ?? '');

  /// 单价框 label（§BG 方案 A ②：标注「这个数现在按什么单位计」——
  /// 否则切到箱后，瓶价会被悄悄当成箱价，真机踩过）
  String get priceLabel {
    final String unit = entryUnitDisplay;
    return unit.isEmpty ? '单价（元）' : '单价（元/$unit）';
  }

  /// 选商品时写入换算上下文；**换商品重置单位**（不同商品上下文不同）
  void attachProduct(Product picked) {
    product = picked;
    baseUnit = picked.unit;
    packageUnit = picked.packageUnit;
    packageSize = picked.packageSize;
    entryUnit = '';
    entryPriceKept = false;
    priceTouched = false;
  }

  /// 单价预填售价：**只在刚选中商品时填**，用户之后改了不再覆盖
  bool pricePrefilled = false;

  /// 价格框被**用户手改过**（§BG 方案 A ①：裁定明令用**显式布尔**，
  /// 不靠「值变没变」猜）—— 预填 = false；用户编辑（非空）= true；
  /// 用户清空 = false；**程序换算不算手改**（换算后的价仍是「预填价」，
  /// 可继续跟随单位）。
  bool priceTouched = false;

  /// 切录入单位（§BG 方案 A）。**判断在 core**（`convertEntryPriceCents`），
  /// 这里只做状态变更：未被手改的价格跟着换到新单位；换算不出（除不尽）⇒
  /// 保留原值 + [entryPriceKept] 告知。与采购 / 销售**逐字段同构**。
  void switchEntryUnit(String toUnit) {
    final String fromUnit = entryUnit;
    final int? price = Money.tryParseYuan(unitPrice.text.trim());
    entryUnit = toUnit;
    entryPriceKept = false;
    if (priceTouched || price == null) return; // 手改过 / 空 ⇒ 数字是用户的，不动
    final int? converted = convertEntryPriceCents(
      priceCents: price,
      fromUnit: fromUnit,
      toUnit: toUnit,
      baseUnit: baseUnit ?? '',
      packageUnit: packageUnit,
      packageSize: packageSize,
    );
    if (converted == null) {
      entryPriceKept = true;
      return;
    }
    // 程序写入不触发 onChanged ⇒ priceTouched 保持 false（仍是「预填价」）
    unitPrice.text = Money.format(converted);
  }

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

class _DeliveryPageState extends State<DeliveryPage> {
  // ---- 表单状态 ----
  String? _partyId;
  String? _partyName;
  DateTime _date = DateTime.now();
  final TextEditingController _remark = TextEditingController();

  /// ⚠️ **没有收款区** —— 送货单本身就是赊销（§AP）：没有 `_pays` / `_given` /
  /// `_accounts`，也没有找零辅助行。客户当场给钱走**单据详情页的「收款」**（1a）。
  final List<_RowCtl> _rows = <_RowCtl>[];

  /// **打开本页时**的库存快照（每商品账面库存）。Z-2：只用于提示，
  /// 不重查不校验 —— 负库存本来就允许，保存必然放行。
  late final Map<String, int> _stockSnapshot = widget.service.stockSnapshot();

  /// 保存失败的字段级原因（用户改任何输入后清掉）
  DeliveryDraftInvalid? _invalid;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _addRow();
  }

  @override
  void dispose() {
    _remark.dispose();
    for (final _RowCtl row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------ 草稿合成

  /// 从控制器合成草稿。**控制器是真相**，草稿按需构造。
  DeliveryDraft get _draft => DeliveryDraft(
    partyId: _partyId,
    partyName: _partyName ?? '',
    date: _fmtDate(_date),
    remark: _remark.text,
    lines: <DeliveryLineDraft>[
      for (final _RowCtl row in _rows)
        DeliveryLineDraft(
          productId: row.product?.id ?? '',
          productName: row.product?.name ?? '',
          quantity: row.quantity.text,
          unitPrice: row.unitPrice.text,
          entryUnit: row.entryUnit,
          baseUnit: row.baseUnit,
          packageUnit: row.packageUnit,
          packageSize: row.packageSize,
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

  /// `sink.submitDelivery` 是**同步**的（库操作 / 入队进程内完成，无 IO 等待）。
  void _save() {
    if (_saving) return;
    final DeliveryDraft draft = _draft;
    setState(() => _saving = true);
    try {
      // B3b：提交走 Sink（桌面 = 落库+规则；手机 = 入队）——页面无分支
      final DocumentSubmitResult result = widget.sink.submitDelivery(draft);
      if (result.isFailure) {
        // 校验失败（裁定 ⑥）：带着原始的 DeliveryDraftInvalid 标红字段
        setState(() {
          _invalid = result.error! as DeliveryDraftInvalid;
          _saving = false;
        });
        return;
      }
      _afterSaved(result);
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

  /// 保存成功：**保留客户与日期**（连续给同一客户送货是常态），只清明细。
  ///
  /// ⚠️ 送货单**没有收款** ⇒ 落库后必然是「全额欠款 + 待签收」，
  /// 所以 SnackBar 不该说「已结清」那一套，而要说清**下一步做什么**。
  void _afterSaved(DocumentSubmitResult result) {
    setState(() {
      for (final _RowCtl row in _rows) {
        row.dispose();
      }
      _rows.clear();
      _addRow();
      _invalid = null;
      _saving = false;
    });

    // B3b：提交成功回调（手机端装配 = 刷新三态条 + 自动推送；桌面为 null）
    widget.onSubmitted?.call(result);

    // 裁定 ②：入队成功的文案在 core（`queuedNotice`），UI 不造句。
    // ⚠️ 手机入队路径**不能**走下面的「库存已扣」文案 —— 本地没扣（叠加显示
    // 由 `stockViewOf` 负责），「到单据详情点签收」也不适用（单在队列里）。
    if (result.isQueued) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.queuedNotice!),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    final String partyDue = (result.partyDueCents ?? 0) > 0
        ? '；$_partyName 累计欠款 ¥${Money.formatGrouped(result.partyDueCents!)}'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '单号 ${result.finalDocNo} 已保存 ¥${Money.formatGrouped(result.totalCents)}'
          '，库存已扣（待签收）$partyDue｜客户签收后，到单据详情点「签收」',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// 取消：空表单直接清；有内容先确认「确定要放弃吗」
  Future<void> _cancel() async {
    final bool hasContent =
        _partyId != null ||
        _rows.any((_RowCtl row) => !row.isEmpty);
    if (hasContent) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('放弃这次送货？'),
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
      _invalid = null;
    });
  }

  // ------------------------------------------------------------ 选择器

  Future<void> _pickProduct(int rowIndex) async {
    final Product? picked = await _showProductPicker(context);
    if (picked == null || rowIndex >= _rows.length) return;
    final _RowCtl row = _rows[rowIndex];
    row.attachProduct(picked); // v3：带换算上下文 + 重置录入单位
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
        recentProducts: widget.service.recentlyDelivered(),
        readOnly: widget.readOnlyMasterData,
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
        readOnly: widget.readOnlyMasterData,
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
                  // ⚠️ 这里**没有** `_paymentSection` —— 送货单不收钱（§AP）
                  _noPaymentNote(theme),
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
                  errorText: _invalid?.fieldErrors[DeliveryField.party],
                ),
                child: Text(
                  // 送货的客户**必选**，没有「散客」这一档 ⇒ 空的时候是提示语，
                  // 不是「散客（当场结清）」（那是销售页的说法）
                  _partyName ?? '点这里选客户（必选）',
                  style: TextStyle(height: 1.6, color: theme.colorScheme.onSurface),
                ),
              ),
            ),
            if (_partyName != null)
              TextButton(
                onPressed: _clearParty,
                child: const Text('换一个客户'),
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
                  errorText: _invalid?.fieldErrors[DeliveryField.date],
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
      if (_invalid?.fieldErrors[DeliveryField.lines] != null) ...<Widget>[
        const SizedBox(height: 4),
        Text(
          _invalid!.fieldErrors[DeliveryField.lines]!,
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

  /// 没有收款区时的**替代说明**——不是空白，而是把两件事说清（§AP）：
  ///
  /// 1. **为什么不收钱**：送货单本身就是赊销，货离店、账挂在客户名下；
  ///    客户当场给钱，送完去单据详情点「收款」。
  /// 2. **拒收怎么办**：内联提示走销售退货（v1.1），免得用户找不到路、
  ///    也免得 1b 自然长出退货需求。
  ///
  /// 全部**内联橙色**（`ui_principles.md` §1.3：可以不拦人的提醒一律内联）。
  Widget _noPaymentNote(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const Text(
        '送货单不收钱：货送出去，货款先挂在客户名下（赊销）。'
        '客户当场给钱的话，送完到「单据」详情页点「收款」。',
        style: TextStyle(height: 1.6, color: Color(0xFFB45309)),
      ),
      const SizedBox(height: 6),
      const Text(
        '客户拒收：请改用「销售退货」把货退回来（退货功能开发中）。',
        style: TextStyle(height: 1.6, color: Color(0xFFB45309)),
      ),
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
        // ⚠️ **稳定 Key**：测试按 Key 找，不按文案找（本项目约定）。
        // 送货单没有收款/找零 ⇒ 文案不会变，但 Key 仍作统一习惯留着。
        key: const Key('delivery-save'),
        onPressed: _saving ? null : _save,
        icon: _saving
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save_outlined),
        label: Text(_saving ? '保存中…' : '保存 (Ctrl+S)'),
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
  final Map<DeliveryLineField, String>? errors;

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
                        errorText: errors?[DeliveryLineField.product],
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
                    key: const Key('delivery-qty'),
                    controller: row.quantity,
                    enabled: enabled,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.next,
                    // P-6：Enter 到下一格（桌面端要显式切焦点）
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    onChanged: (_) => onChanged(),
                    decoration: InputDecoration(
                      labelText: row.entryUnitDisplay.isEmpty
                          ? '数量 *'
                          : '数量（${row.entryUnitDisplay}）*',
                      isDense: true,
                      errorText: errors?[DeliveryLineField.quantity],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: const Key('delivery-price'),
                    controller: row.unitPrice,
                    enabled: enabled,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                    onChanged: (_) {
                      // §BG 方案 A ①：显式布尔记「手改过」——编辑（非空）= true，清空 = false
                      row.priceTouched = row.unitPrice.text.trim().isNotEmpty;
                      row.entryPriceKept = false; // 重新输入 ⇒ 「保留」告知失效
                      onChanged();
                    },
                    decoration: InputDecoration(
                      labelText: '${row.priceLabel}*',
                      isDense: true,
                      errorText: errors?[DeliveryLineField.unitPrice],
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
            // v3 单位切换（§BD·三 第 3 条）：只在**成对启用**时出现
            if (row.canSwitchPackage && enabled) ...<Widget>[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  ChoiceChip(
                    label: Text(row.baseUnit ?? ''),
                    selected: row.entryUnit.isEmpty ||
                        row.entryUnit == row.baseUnit,
                    onSelected: (_) {
                      row.switchEntryUnit(''); // §BG 方案 A：预填价跟着换
                      onChanged();
                    },
                  ),
                  ChoiceChip(
                    label: Text(row.packageUnit ?? ''),
                    selected:
                        row.entryUnit.isNotEmpty &&
                        row.entryUnit == row.packageUnit,
                    onSelected: (_) {
                      row.switchEntryUnit(row.packageUnit ?? '');
                      onChanged();
                    },
                  ),
                ],
              ),
            ],
            if (errors?[DeliveryLineField.entryUnit] != null) ...<Widget>[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  errors![DeliveryLineField.entryUnit]!,
                  style: TextStyle(color: theme.colorScheme.error, height: 1.6),
                ),
              ),
            ],
            // §BG 方案 A ②③：切到包装才显示换算说明；除不尽保留原价的橙色告知
            ...entryUnitHints(
              theme: theme,
              baseUnit: row.baseUnit,
              packageUnit: row.packageUnit,
              packageSize: row.packageSize,
              entryUnit: row.entryUnit,
              priceKept: row.entryPriceKept,
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

/// 客户选择器：搜索 + 最近往来 + 「＋新建客户」（走 `ensureParty`）。
class _CustomerPickerSheet extends StatefulWidget {
  const _CustomerPickerSheet({
    required this.service,
    required this.partyService,
    this.readOnly = false,
  });

  final DeliveryService service;
  final PartyService partyService;

  /// 手机端主数据禁建（C2·§CC）：`true` = 「新建客户」点击后弹引导。
  final bool readOnly;

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
    // C2·§CC：手机端主数据禁建 —— 保留入口，点击后引导
    if (widget.readOnly) {
      await showMobileGuideDialog(context, MobileGuideTopic.newParty);
      return;
    }
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
                      widget.readOnly
                          ? mirrorEmptyMessage('客户列表')
                          : _searched
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

/// 商品选择器：搜索 + 最近送货 + 「＋新建商品」（复用商品建档对话框）。
class _ProductPickerSheet extends StatefulWidget {
  const _ProductPickerSheet({
    required this.service,
    required this.recentProducts,
    this.readOnly = false,
  });

  final ProductService service;

  /// 空查询时展示的「最近送货」列表 —— 由页面查好传入。
  final List<Product> recentProducts;

  /// 手机端主数据禁建（C2·§CC）：`true` = 「新建商品」点击后弹引导。
  final bool readOnly;

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
    // C2·§CC：手机端主数据禁建 —— 保留入口，点击后引导
    if (widget.readOnly) {
      await showMobileGuideDialog(context, MobileGuideTopic.newProduct);
      return;
    }
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
            _searched ? '搜索结果' : '最近送货',
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
                      widget.readOnly
                          ? mirrorEmptyMessage('商品列表')
                          : _searched
                          ? '没有匹配的商品，可以点下面新建。'
                          : '还没有销售记录，直接搜索或新建。',
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
