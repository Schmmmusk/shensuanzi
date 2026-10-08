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
/// | 抹零 / 整单议价：走 `document_lines.discount_amount` 字段（§AU·3.2 的 A1+B2，v3 批次 —— §BA·一） | 合计下方「让价 ¥__」；`unit_price` 保持档价 |
/// | **现金找零辅助行**：顾客给了 100 买 93 的货 → 当场显示「找零 ¥7.00」。
///   **落库永远是应收** —— 找零是现金箱内部的物理流动，不进
///   `immediate_payments`、不持久化；「顾客给了」< 应收显示「不够」但照常放行
///   （reply_review.md §AJ·AI-4） | `_cashChangeRow` |
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart'
    show MobileGuideTopic, mirrorEmptyMessage;
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'keyboard_reveal.dart';
import 'mobile_guidance_dialog.dart';
import 'entry_unit_hints.dart';
import 'entry_fields_row.dart';
import 'product_form_dialog.dart';

/// 店内销售开单页。
class SalePage extends StatefulWidget {
  const SalePage({
    super.key,
    required this.service,
    required this.productService,
    required this.partyService,
    required this.sink,
    this.onSubmitted,
    this.onStorageFailure,
    this.stockDelta,
    this.readOnlyMasterData = false,
  });

  /// 开单页**查询**用（选择器 / 库存快照 —— 读）。
  final SaleService service;

  /// 提交**出口**（B3b·§CA）：页面对 [DocumentSink] 编程，**不出现
  /// 「是不是客户端」的分支**。桌面 = `ServiceSink`（落库+规则，与直连
  /// 逐字同行为）；手机 = `QueueSink`（校验 → 入队）。
  final DocumentSink sink;

  /// 提交成功回调（B3b）。手机端注入 = 刷新三态条 + 触发自动推送
  /// （裁定 ③，在 app.dart 装配）；桌面不注入。
  final void Function(DocumentSubmitResult result)? onSubmitted;

  /// 保存失败时把**原始异常**交给宿主记日志（M15，2026-10-08）。
  ///
  /// 界面只显示 [storageFailureNote] 的分类文案 —— `SqliteException` 的文本
  /// 带着整条 SQL 与绑定参数（等于把这张单的 payload 印给用户看）。
  /// `null` = 不记（测试）；生产由 `app.dart` 接到 `AppLog`。
  final void Function(Object error, StackTrace stack)? onStorageFailure;

  /// 手机端**主数据禁建**（C2·§CC）：`true` 时「新建客户 / 新建商品」入口
  /// **保留但点击后弹引导对话框**（不隐藏 —— Agents.md 4.3）。
  /// 桌面缺省 `false` = 现状零变化。
  final bool readOnlyMasterData;

  /// **未同步库存影响**（M08，2026-10-08）：手机端注入（镜像队列）；
  /// 桌面 `null` = 不叠加 —— 桌面的权威库就是本机，没有「未同步」这回事。
  final StockDelta? stockDelta;

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

  // ---- v3 换算上下文（选商品时由 [attachProduct] 写入）----
  String? baseUnit;
  String? packageUnit;
  int? packageSize;

  /// **录入单位**：'' = 最小单位（没切）；切到包装 = [packageUnit] 原文
  String entryUnit = '';

  /// 切单位时价格没换成（除不尽，保留原值）⇒ `true`：橙色告知，不拦提交
  /// （§BG 方案 A ②）—— 与采购 / 送货**逐字段同构**，改一边必须扫另两边
  bool entryPriceKept = false;

  /// 本行让价（分）—— 由整单让价分摊写入（`_syncSpread`），行卡只读展示
  int discountCents = 0;

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
  /// 保留原值 + [entryPriceKept] 告知。与采购 / 送货**逐字段同构**。
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

  /// **录入原文数量**取值；非法时 `null`（调用方应先 `validate`）
  int? get quantityValue {
    final int? qty = int.tryParse(quantity.text.trim());
    return (qty == null || qty <= 0) ? null : qty;
  }

  /// 本行**折前**金额（分）= 录入原文数量 × 录入单位报价
  int? get grossCents {
    final int? qty = int.tryParse(quantity.text.trim());
    final int? price = Money.tryParseYuan(unitPrice.text.trim());
    if (qty == null || qty <= 0 || price == null || price < 0) return null;
    return qty * price;
  }

  /// 换算后的**最小单位数量**（`document_lines.quantity` 的值）；
  /// 换算失败 ⇒ `null`（validate 会带文案拦住）
  int? get baseQuantityValue => toBaseQuantity(
    entryQuantity: quantityValue ?? 0,
    entryUnit: entryUnit.isEmpty ? null : entryUnit,
    baseUnit: baseUnit ?? '',
    packageUnit: packageUnit,
    packageSize: packageSize,
  ).baseQuantityOrNull;

  /// 本行小计（分）= 折前 − 让价（v3 真相口径）；字段没填全 ⇒ `null`
  int? get amountCents {
    final int? gross = grossCents;
    if (gross == null) return null;
    return gross - discountCents;
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

  /// **整单让价**原文（元）—— 分摊到各行（`spreadDiscount`，从最后一行向前，
  /// §BD·九 #3）。行卡的让价只是分摊**结果**，用户永远只填这一个框。
  final TextEditingController _discountAll = TextEditingController();

  /// 让价分摊失败的内联提示（超整单折前金额 / 不是数字）
  String? _discountError;
  final List<_RowCtl> _rows = <_RowCtl>[];
  final List<_PayCtl> _pays = <_PayCtl>[];

  /// **打开本页时**的库存快照（每商品账面库存）。Z-2：只用于提示，
  /// 不重查不校验 —— 负库存本来就允许，保存必然放行。
  late final Map<String, int> _stockSnapshot = widget.service.stockSnapshot();

  /// 打开本页时的**未同步影响**（M08）：手机刚开的单还没推到电脑，
  /// 权威快照里没有它们 —— 提示要说清「其中本地未同步 N 件」。
  late final Map<String, int> _unsyncedDelta =
      widget.stockDelta?.unsyncedDelta() ?? const <String, int>{};

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
    _discountAll.dispose();
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
          entryUnit: row.entryUnit,
          discountAmount: row.discountCents == 0
              ? ''
              : Money.format(row.discountCents),
          baseUnit: row.baseUnit,
          packageUnit: row.packageUnit,
          packageSize: row.packageSize,
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
    _syncSpread();
  }

  /// 把整单让价分摊到各行（§BD·九 #3：**从最后一行向前**，每行钳在折前金额内）。
  /// 超整单 / 非数字 ⇒ 记 [_discountError]（内联橙字），各行清零。
  void _syncSpread() {
    final String text = _discountAll.text.trim();
    if (text.isEmpty) {
      _discountError = null;
      for (final _RowCtl row in _rows) {
        row.discountCents = 0;
      }
      return;
    }
    final int? disc = Money.tryParseYuan(text);
    if (disc == null || disc < 0) {
      _discountError = '让价只能填数字，最多两位小数';
      return;
    }
    int total = 0;
    for (final _RowCtl row in _rows) {
      total += row.grossCents ?? 0;
    }
    if (disc > total) {
      _discountError = '让价不能超过合计 ¥${Money.format(total)}';
      return;
    }
    _discountError = null;
    final List<int> spread = spreadDiscount(
      grossAmounts: <int>[for (final _RowCtl row in _rows) row.grossCents ?? 0],
      discountCents: disc,
    );
    for (int i = 0; i < _rows.length; i++) {
      _rows[i].discountCents = spread[i];
    }
  }

  /// 明细行里的字段变了（数量 / 单价）—— 清错误 + **重算整单让价分摊**。
  ///
  /// M12（2026-10-08）：以前只 `setState`。改完数量，合计 / 各行小计 /「全款」
  /// 读到的还是**旧**分摊，而保存时会重算 ⇒ 界面显示的和实际提交的不一致。
  /// （报告实测：3×20 + 2×20 让价 30，把第二行数量改成 1 后预览仍是 60，应为 50。）
  void _onRowChanged() {
    setState(() {
      _invalid = null;
      _syncSpread();
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

  /// 收款框填得超过应收 ⇒ 一句橙色告知（`null` = 没有要说的事）。
  /// 判断与文案都在 core（`SaleDraft.overpayNotice` → `Overpay`）——
  /// 这里**只取值**（铁律：判断放纯 Dart）。
  String? get _overpayNotice => _draft.overpayNotice;

  /// [收整] 的整额：应收**向上取整到元**（93.50 → 94，93 → 93）。
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

  /// `sink.submitSale` 是**同步**的（库操作 / 入队进程内完成，无 IO 等待）。
  void _save() {
    if (_saving) return;
    _syncSpread();
    if (_discountError != null) return; // 内联橙字已在屏上（onChanged 里 setState）
    final SaleDraft draft = _draft;
    setState(() => _saving = true);
    try {
      // B3b：提交走 Sink（桌面 = 落库+规则；手机 = 入队）——页面无分支
      final DocumentSubmitResult result = widget.sink.submitSale(draft);
      if (result.isFailure) {
        // 校验失败（裁定 ⑥）：带着原始的 SaleDraftInvalid 标红字段，不入库不入队
        setState(() {
          _invalid = result.error! as SaleDraftInvalid;
          _saving = false;
        });
        return;
      }
      _afterSaved(result);
    } catch (error, stack) {
      setState(() => _saving = false);
      // M15（2026-10-08）：界面只给**分类文案**，原始异常交给宿主记日志 ——
      // `SqliteException` 的文本带着整条 SQL 与绑定参数（等于把这张单印出来）
      widget.onStorageFailure?.call(error, stack);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(storageFailureNote(error)),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  /// 保存成功：**保留客户与日期**（连续给同一客户开单是常态），
  /// 只清明细与收款（§X 六 / P-3 同款）。
  /// ⚠️ v1 不显示利润（§Z 遗漏 6）—— SnackBar 只报单号与欠款。
  void _afterSaved(DocumentSubmitResult result) {
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
      // §审查 BUG-07：整单让价也要清 —— 否则下一单悄悄继承上一单的让价
      _discountAll.clear();
      _discountError = null;
      _invalid = null;
      _saving = false;
    });

    // B3b：提交成功回调（手机端装配 = 刷新三态条 + 自动推送；桌面为 null）
    widget.onSubmitted?.call(result);

    // 裁定 ②：入队成功的文案在 core（`queuedNotice`），UI 不造句
    if (result.isQueued) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.queuedNotice!),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    final String due = result.dueCents > 0
        ? '，欠款 ¥${Money.formatGrouped(result.dueCents)}'
        : '（已结清）';
    // §AX·一 的**第二处告知**：SnackBar 再说一次「记了多少、找了多少」。
    // 措辞取自 core 的 `Overpay.savedNoteOf` —— 与提交前的内联提示、
    // 按钮文字**同源**（这里不造句）。
    final String change = Overpay.savedNoteOf(
      recordedCents: result.paidCents,
      changeCents: result.changeCents,
    );
    final String partyDue = (result.partyDueCents ?? 0) > 0
        ? '；$_partyName 累计欠款 ¥${Money.formatGrouped(result.partyDueCents!)}'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '单号 ${result.finalDocNo} 已保存 ¥${Money.formatGrouped(result.totalCents)}'
          '$due${change.isEmpty ? '' : '，$change'}$partyDue',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// 取消：空表单直接清；有内容先确认「确定要放弃吗」
  /// 草稿是否有内容 —— **取消确认**与**返回拦截**（M09）共用同一判据。
  ///
  /// ⚠️ M11（2026-10-08）：**备注也算内容**。以前只填备注时点取消会直接清空，
  /// 用户白打了一行字（三种表单都如此，报告实测）。
  bool get _hasContent =>
      _partyId != null ||
      _rows.any((_RowCtl row) => !row.isEmpty) ||
      _pays.any((_PayCtl pay) => !pay.isBlank) ||
      _remark.text.trim().isNotEmpty;

  Future<void> _cancel() async {
    if (_hasContent) {
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
        recentProducts: widget.service.recentlySold(),
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
    // M09（2026-10-08）：**返回键也要走放弃确认** —— AppBar 返回箭头（手机壳的
    // 整屏开单页）与系统返回都绕过下面绑定的 Escape，以前填了数量点返回直接丢草稿。
    return PopScope(
      canPop: !_hasContent,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _cancel();
      },
      child: CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: Focus(
        autofocus: true,
        // C3·真机反馈 ④：键盘（含输入法候选栏）高度变化时，把焦点字段滚回可视区
        child: KeyboardReveal(
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
          // M08：本地未同步影响（同一商品的队列 Δ）
          unsyncedOfProduct: _rows[i].product == null
              ? null
              : _unsyncedDelta[_rows[i].product!.id],
          enabled: !_saving,
          onPickProduct: () => _pickProduct(i),
          // M12（2026-10-08）：行内字段变了要**重算整单让价分摊** ——
          // 以前只清错误，改完数量后合计 /「全款」读到的还是旧分摊（保存时才重算）
          onChanged: _onRowChanged,
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
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // M13（2026-10-08）：**窄屏 + 大金额不溢出** —— 原来是
        // `Row[Text, Spacer, Text]`：金额那格没有弹性，小屏 + 超大字号下
        // 「¥ 9,999,990」会被裁掉（报告实测）。改成「合计 + Expanded(右对齐金额)」：
        // 放得下视觉同旧，放不下自动换行。
        Row(
          children: <Widget>[
            Text('合计', style: theme.textTheme.titleMedium),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '¥ ${Money.formatGrouped(_draft.totalCents)}',
                textAlign: TextAlign.right,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('sale-discount'),
          controller: _discountAll,
          enabled: !_saving,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) {
            _syncSpread();
            setState(() {});
          },
          decoration: InputDecoration(
            labelText: '整单让价（可选）',
            hintText: '例：2.00',
            isDense: true,
            prefixText: '- ¥',
            errorText: _discountError,
            helperText: '从最后一行往前分摊；每行让价不超过它自己的金额',
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
        // 超收告知（§AX·一）：**橙色内联**、**不拦住提交** ——
        // 「实收 ¥100，其中 ¥93 入账、找零 ¥7」。文案在 core 的 `Overpay`，
        // 与核销对话框、与下方按钮文字**同源**。
        if (_overpayNotice != null) ...<Widget>[
          const SizedBox(height: 4),
          _overpayLine(theme, _overpayNotice!),
        ],
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

  /// 超收告知行（橙色）—— §AX·一：「实收 ¥100，其中 ¥93 入账、找零 ¥7」。
  ///
  /// 与「错误红」明确区分：它**不拦人**（填超了照样能保存），
  /// 只是把「记多少、找多少」在**提交前**说清 —— 这是 3甲 成立的前提。
  Widget _overpayLine(ThemeData theme, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const Icon(Icons.info_outline, color: Color(0xFFB45309), size: 18),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(height: 1.6, color: Color(0xFFB45309)),
        ),
      ),
    ],
  );

  /// 现金找零辅助行（§AJ·AI-4）。**只算找零，不记账**：
  /// 「顾客给了」永不出现在草稿里；小于应收显示「不够」但**照常允许提交**
  /// （用户可能只是拿它算个数）。快捷键 = 一次点击完成「算找零」。
  ///
  /// ⚠️ 窄屏（手机）快捷 chips 会溢出 44px（C3 真机实测）⇒ LayoutBuilder
  /// 响应式：宽屏（桌面）单行右对齐**零变化**；窄屏 chips 独立成行。
  Widget _cashChangeRow(ThemeData theme) {
    final int total = _draft.totalCents;
    final int? given = Money.tryParseYuan(_given.text.trim());
    final bool notEnough = given != null && given < total;
    // ⚠️ 找零的**数**只有一个出处：core 的 `Overpay`（与内联告知、按钮文字、
    // SnackBar、核销对话框同源）—— 这里再算一遍 `given - total` 就是第二处口径。
    final String? changeText = given == null
        ? null
        : notEnough
            ? '不够'
            : '找零 ¥${Money.formatGrouped(
                Overpay(givenCents: given, dueCents: total).changeCents,
              )}';

    final Widget givenField = SizedBox(
      width: 120,
      child: TextField(
        key: const Key('sale-given'),
        controller: _given,
        enabled: !_saving,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          hintText: '选填',
          isDense: true,
          border: OutlineInputBorder(),
          suffixText: '元',
        ),
      ),
    );

    final List<Widget> quickChips = <Widget>[
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
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final List<Widget> content;
        if (constraints.maxWidth < 480) {
          // 窄屏（手机）：chips 独立成行右对齐 —— 不再挤爆
          content = <Widget>[
            Row(
              children: <Widget>[
                Text('顾客给了', style: theme.textTheme.bodySmall),
                const SizedBox(width: 8),
                givenField,
                const SizedBox(width: 12),
                if (changeText != null)
                  Flexible(
                    child: Text(
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
                  ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(spacing: 4, children: quickChips),
            ),
          ];
        } else {
          // 宽屏（桌面）：chips 与找零文本同行右对齐。结构与窄屏**同源**
          //（Flexible 找零文本 + Wrap chips）—— 最大缩放下也不溢出
          //（C3·Windows 反馈：最大档位款项行超出绘制边界，宽屏分支此前无防护）。
          content = <Widget>[
            Row(
              children: <Widget>[
                Text('顾客给了', style: theme.textTheme.bodySmall),
                const SizedBox(width: 8),
                givenField,
                const SizedBox(width: 12),
                if (changeText != null)
                  Flexible(
                    child: Text(
                      changeText,
                      style: TextStyle(
                        height: 1.6,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                        color: notEnough
                            ? const Color(0xFFB45309)
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(spacing: 4, children: quickChips),
                  ),
                ),
              ],
            ),
          ];
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ...content,
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
      },
    );
  }

  /// 备注框。
  ///
  /// ⚠️ `onChanged` 只为**触发重建**：返回拦截（M09）的 `canPop` 在 build 时求值，
  /// 备注变了不重建的话，「只填备注 + 按返回」仍会直接走掉（M11）。
  Widget _remarkField() => TextField(
    controller: _remark,
    enabled: !_saving,
    maxLines: 2,
    onChanged: (_) => setState(() {}),
    decoration: const InputDecoration(
      labelText: '备注（可选）',
      border: OutlineInputBorder(),
    ),
  );

  /// ⚠️ M13（2026-10-08）：用 `Wrap` 而不是 `Row` —— 小屏 + 超大字号下
  /// 「取消 + 保存（文案可能很长）」会横向溢出，**保存按钮越出屏幕**（点不到）。
  /// `Wrap` 放不下就换行；`spacing` 取代原来的 `SizedBox`。
  Widget _actions(ThemeData theme) => Wrap(
    alignment: WrapAlignment.end,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 16,
    runSpacing: 8,
    children: <Widget>[
      TextButton(
        onPressed: _saving ? null : _cancel,
        child: const Text('取消 (Esc)'),
      ),
      FilledButton.icon(
        // ⚠️ **稳定 Key**：按钮文案会随「有没有找零」变（§AX·一），
        // 测试**不要**按文案找它 —— 按 Key 找（`test/sale_page_test.dart`）。
        key: const Key('sale-save'),
        onPressed: _saving ? null : _save,
        icon: _saving
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save_outlined),
        // §AX·一：**按钮文字是用户动作的最终确认** —— 超收时直接说清会记多少。
        // 文案由 core 给（`SaleDraft.saveActionLabel`），这里只取值。
        label: Text(
          _saving
              ? '保存中…'
              : '${_draft.saveActionLabel(givenCents: Money.tryParseYuan(_given.text.trim()))} (Ctrl+S)',
        ),
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
    this.unsyncedOfProduct,
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

  /// 该商品的**本地未同步影响**（M08）：`null` = 没有 / 桌面端
  final int? unsyncedOfProduct;
  final bool enabled;
  final VoidCallback onPickProduct;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int? qty = row.quantityValue;
    final int snapshot = stockOfProduct ?? 0;
    // M08（2026-10-08）：**估算库存 = 权威快照 + 本地未同步影响** ——
    // 手机上刚开的单还没推给电脑，权威快照不含它们；只报权威值
    // 会让老板按「还有 7 件」判断缺货，而实际只剩 6 件。
    final int local = unsyncedOfProduct ?? 0;
    final int estimated = snapshot + local;
    final bool negativeStock =
        row.product != null && qty != null && qty > estimated;

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
            // M10（2026-10-08）：数量 / 单价 / 小计的摆放交给共用控件 ——
            // 宽屏并排（与旧版一致），窄屏 + 超大字号自动堆叠，
            // 否则单价框的「单价（元/箱）」label 会被截成省略号。
            EntryFieldsRow(
              quantityField: TextField(
                key: const Key('sale-qty'),
                controller: row.quantity,
                enabled: enabled,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                // P-6：Enter 到下一格（桌面端要显式切焦点）
                onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                onChanged: (_) => onChanged(),
                decoration: InputDecoration(
                  labelText: row.entryUnitDisplay.isEmpty
                      ? '数量 *'
                      : '数量（${row.entryUnitDisplay}）*',
                  isDense: true,
                  errorText: errors?[SaleLineField.quantity],
                ),
              ),
              priceField: TextField(
                key: const Key('sale-price'),
                controller: row.unitPrice,
                enabled: enabled,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
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
                  errorText: errors?[SaleLineField.unitPrice],
                ),
              ),
              amount: Text(
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
            // v3 单位切换（§BD·三 第 3 条）：只在**成对启用**时出现；
            // chips 是唯一入口 —— 文字标签必须有（UI 基线），不用图标猜
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
            if (errors?[SaleLineField.entryUnit] != null) ...<Widget>[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  errors![SaleLineField.entryUnit]!,
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
                      ? '当前库存 $estimated（打开本页时），本单会按负库存记账（成本按最近入库价）'
                      : local == 0
                      ? '当前库存 $snapshot（打开本页时）'
                      : '当前库存 $estimated（打开本页时；权威 $snapshot，'
                            '本地未同步 ${local > 0 ? '+' : ''}$local）',
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
  const _CustomerPickerSheet({
    required this.service,
    required this.partyService,
    this.readOnly = false,
  });

  final SaleService service;
  final PartyService partyService;

  /// 手机端主数据禁建（C2·§CC）：`true` = 「新建客户」点击后弹引导
  /// （保留入口，不隐藏）；空态文案换成同步引导。
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
    // C2·§CC：手机端主数据禁建 —— 保留入口，点击后引导（文案在 app 包）
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

/// 商品选择器：搜索 + 最近销售 + 「＋新建商品」（复用商品建档对话框）。
class _ProductPickerSheet extends StatefulWidget {
  const _ProductPickerSheet({
    required this.service,
    required this.recentProducts,
    this.readOnly = false,
  });

  final ProductService service;

  /// 空查询时展示的「最近销售」列表 —— 由页面查好传入。
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
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        // C3·真机反馈 ④：键盘补偿（客户 picker 既有模式，商品 picker 此前漏了）
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
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
