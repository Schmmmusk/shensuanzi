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
import 'package:shensuanzi_app/shensuanzi_app.dart'
    show
        MasterDataPolicy,
        MobileGuideTopic,
        mirrorEmptyMessage,
        partyMutationNotice,
        partySameNameHint;
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'keyboard_reveal.dart';
import 'mobile_guidance_dialog.dart';
import 'product_form_dialog.dart';
import 'entry_unit_hints.dart';
import 'entry_fields_row.dart';
import 'submit_error_summary.dart';

/// 采购入库开单页。
///
/// [service] 为 `null` 时显示「数据未就绪」（数据库没打开成功）。
class PurchasePage extends StatefulWidget {
  const PurchasePage({
    super.key,
    required this.service,
    required this.productService,
    required this.sink,
    this.onSubmitted,
    this.onStorageFailure,
    required this.masterDataPolicy,
    this.partySink,
    required this.masterDataSink,
    this.mobileShell = false,
  });

  /// 开单页**查询**用（选择器 / 库存快照 —— 读）。
  final PurchaseService service;

  /// 提交**出口**（B3b·§CA）：页面对 [DocumentSink] 编程，**不出现
  /// 「是不是客户端」的分支**。桌面 = `ServiceSink`；手机 = `QueueSink`。
  final DocumentSink sink;

  /// 提交成功回调（B3b）。手机端注入 = 刷新三态条 + 触发自动推送（裁定 ③）。
  final void Function(DocumentSubmitResult result)? onSubmitted;

  /// 保存失败时把**原始异常**交给宿主记日志（M15，2026-10-08）。
  ///
  /// 界面只显示 [storageFailureNote] 的分类文案 —— `SqliteException` 的文本
  /// 带着整条 SQL 与绑定参数（等于把这张单的 payload 印给用户看）。
  /// `null` = 不记（测试）；生产由 `app.dart` 接到 `AppLog`。
  final void Function(Object error, StackTrace stack)? onStorageFailure;

  /// **主数据门控**（§CV·七 ① 乙，2026-10-09）：三族各自能不能在**本机**建档。
  /// 桌面 = `MasterDataPolicy.desktop()`；手机 v1 = `MasterDataPolicy.mobile()`
  /// （**只开商品**；往来仍「保留入口 + 引导」）。⚠️ **required** —— 缺省 `false`
  /// 那版默默漏装就是「手机上一切都能建」（静默丢数据），宁可编不过。
  final MasterDataPolicy masterDataPolicy;

  /// **往来方写入口的队列出口**（2026-10-20，§CV·七十七）。
  ///
  /// 手机 = `QueuePartySink`（写镜像 + 入队 + 立即推）；桌面 = `null`（服务直连主库）。
  final QueuePartySink? partySink;

  /// 主数据提交**出口**（桌面 `ServiceMasterSink` / 手机 `QueueMasterSink`）。
  /// ⚠️ 商品表单**必须**走它 —— 手机端的 `ProductService` 建在镜像上。
  final MasterDataSink masterDataSink;

  /// **壳类型**（#37①，2026-10-14）：手机壳**没有键盘** ⇒ 按钮文案不带
  /// `(Esc)` / `(Ctrl+S)` 后缀。判据沿用 `AppShell.mobileShell`（**不新造 flag**）。
  final bool mobileShell;

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

  // ---- v3 换算上下文（选商品时由 [attachProduct] 写入）----
  String? baseUnit;
  String? packageUnit;
  int? packageSize;

  /// **录入单位**：'' = 最小单位（没切）；切到包装 = [packageUnit] 原文
  String entryUnit = '';

  /// 切单位时价格没换成（除不尽，保留原值）⇒ `true`：橙色告知，不拦提交
  /// （§BG 方案 A ②）
  bool entryPriceKept = false;

  /// 成对启用 ⇒ 行卡显示单位切换（§BD·三 第 3 条）
  bool get canSwitchPackage =>
      packageUnit != null && packageUnit!.isNotEmpty && (packageSize ?? 0) > 0;

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

  /// 价格框被**用户手改过**（§BG 方案 A ①：裁定明令用**显式布尔**，
  /// 不靠「值变没变」猜）—— 预填 = false；用户编辑（非空）= true；
  /// 用户清空 = false；**程序换算不算手改**（换算后的价仍是「预填价」，
  /// 可继续跟随单位）。
  bool priceTouched = false;

  /// 切录入单位（§BG 方案 A）。**判断在 core**（`convertEntryPriceCents`），
  /// 这里只做状态变更：未被手改的价格跟着换到新单位；换算不出（除不尽）⇒
  /// 保留原值 + [entryPriceKept] 告知。
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
  /// **本机能不能建往来方**：策略放开 **且** 出口齐备。
  ///
  /// 手机上的 `partyService` / `service` 建在**镜像**上，直写不入队 ⇒ 到不了电脑
  ///（静默丢数据）。桌面没有这个问题（直连主库）⇒ 只在策略就是「手机」且
  /// 没装出口时拦住。
  bool get _canCreateParty =>
      widget.masterDataPolicy.canCreateParties &&
      (widget.partySink != null ||
          widget.masterDataPolicy != const MasterDataPolicy.mobile());
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

  /// 保存失败要**滚回页顶**（§CV·八十 批 1 ③）
  final ScrollController _scroll = ScrollController();

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
    _scroll.dispose();
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
          entryUnit: row.entryUnit,
          baseUnit: row.baseUnit,
          packageUnit: row.packageUnit,
          packageSize: row.packageSize,
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
      _pays.add(_PayCtl(account: _accounts.isEmpty ? null : _accounts.first));
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
    final PartyMutation? picked = await _showPartyPicker(
      context,
      widget.service,
    );
    if (picked == null) return;
    final Party party = picked.party;
    setState(() {
      _partyId = party.id;
      _partyName = party.name;
      _invalid = null;
    });
    // #40①：提交后**如实告知**发生了什么（以前采购页整个丢掉这个信息）
    final String? notice = partyMutationNotice(
      picked,
      role: PartyRole.supplier,
    );
    if (notice != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(notice), duration: const Duration(seconds: 4)),
      );
    }
  }

  /// 清除供应商 = 改为散采（当场结清）
  void _clearParty() {
    setState(() {
      _partyId = null;
      _partyName = null;
      _invalid = null;
    });
  }

  /// `sink.submitPurchase` 是**同步**的（库操作 / 入队进程内完成，无 IO 等待）。
  void _save() {
    if (_saving) return;
    final PurchaseDraft draft = _draft;
    setState(() => _saving = true);
    try {
      // B3b：提交走 Sink（桌面 = 落库+规则；手机 = 入队）——页面无分支
      final DocumentSubmitResult result = widget.sink.submitPurchase(draft);
      if (result.isFailure) {
        // 校验失败（裁定 ⑥）：带着原始的 PurchaseDraftInvalid 标红字段
        setState(() {
          _invalid = result.error! as PurchaseDraftInvalid;
          _saving = false;
        });
        _scrollToTop();
        return;
      }
      _afterSaved(result);
    } on RuleRejected catch (error) {
      // #23（2026-10-17 裁定甲）：**业务拒绝** —— 规则层的文案已写「怎么办」，
      // 照实显示（此前的「请再试一次」对它必然重试再败）。不调
      // onStorageFailure：这不是内部错误（detail 已由引擎经 onInternalError
      // 进宿主日志）。草稿保留，改完能直接再交。
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.reason),
          duration: const Duration(seconds: 8),
        ),
      );
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

  /// 保存成功：**保留供应商与日期**（连续给同一供应商录多笔 / 补录同一天是常态），
  /// 只清明细与付款 —— 每次开单不多两步（§X 六 / P-3）。
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
    // §AY·四 的**第二处告知**：SnackBar 再说一次「记了多少、找了多少」。
    // 措辞取自 core 的 `Overpay.savedNoteOf` —— 与销售页、核销对话框**同源**。
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
  /// （`ui_principles.md` §1.2「给『我错了也能补救』的信心」）。
  ///
  /// 本页是导航内容区的一部分（不是独立路由），「离开」即回到初始状态。
  /// 草稿是否有内容 —— **取消确认**与**返回拦截**（M09）共用同一判据。
  ///
  /// ⚠️ M11（2026-10-08）：**备注也算内容**。以前只填备注时点取消会直接清空，
  /// 用户白打了一行字（三种表单都如此，报告实测）。
  bool get _hasContent =>
      _partyId != null ||
      _rows.any((_RowCtl row) => !row.isEmpty) ||
      _pays.any((_PayCtl pay) => !pay.isBlank) ||
      _remark.text.trim().isNotEmpty;

  /// 「取消这次开单」：有内容先确认；确认（或本来为空）⇒ 清草稿并返回 `true`。
  ///
  /// ⚠️ 只回答「是否放弃」，**不负责退出页面**（#51 裁定乙）—— 退出是调用方
  /// （`PopScope` 的返回拦截）的事：手机确认后 pop 路由，桌面不退出。
  Future<bool> _cancel() async {
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
      if (confirmed != true) return false;
    }
    if (!mounted) return false;
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
    // #51（裁定乙）：本方法只回答「是否确认放弃」—— 退不退出由调用方定
    return true;
  }

  // ------------------------------------------------------------ 选择器

  /// 商品选择器：搜索 + 最近使用 + 扫码枪回车 + 「＋新建商品」
  Future<void> _pickProduct(int rowIndex) async {
    final Product? picked = await _showProductPicker(context);
    if (picked == null || rowIndex >= _rows.length) return;
    final _RowCtl row = _rows[rowIndex];
    row.attachProduct(picked); // v3：带换算上下文 + 重置录入单位（含 priceTouched = false）
    // ⚠️ **无条件**预填进价 —— 别在这里加守卫。换商品（**含重选同一商品**）时，
    // 旧价对新商品没有意义，必须覆盖；而 `priceTouched` 的语义是「用户**手改过**」，
    // 不是「是否预填过」—— 把它当预填守卫用**正是 #25 的病根**（§CV·二四·一 / §CV·二五）。
    // 与「切单位」（§BG 方案 A）判据**不同**：那里换的是**同一商品**的价格单位，
    // 手改过的价仍是用户的意愿 ⇒ 「未被手改才跟随」；这里换的是**不同商品** ⇒ 总覆盖。
    row.unitPrice.text = Money.format(picked.costPrice);
    setState(() => _invalid = null);
  }

  /// 选供应商 + 最小新建
  ///
  /// 返回 [PartyMutation]（#40① 裁定甲-改）：页面要据此说出「新建了 / 追加了身份 /
  /// 复活了停用档」。选中已有供应商时 action = `existing`（没什么要解释的）。
  Future<PartyMutation?> _showPartyPicker(
    BuildContext context,
    PurchaseService service,
  ) {
    return showModalBottomSheet<PartyMutation>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _PartyPickerSheet(
        service: service,
        canCreate: _canCreateParty,
        partySink: widget.partySink,
      ),
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
        canCreate: widget.masterDataPolicy.canCreateProducts,
        sink: widget.masterDataSink,
        allowOpeningStock: widget.mobileShell,
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
      // #51（2026-10-15 裁定）：**手机** = 有内容拦返回，确认放弃 ⇒ 清草稿 +
      // 退出页面（开单页是推入的整屏路由，返回键语义 = 离开）；**桌面** =
      // 一律不 pop —— 系统返回键（Alt+← / 鼠标侧键）不启用：中老年用户不认识
      // 它，误触会走到「放弃确认」、有丢草稿风险；桌面清空只走 Esc / 取消按钮。
      canPop: widget.mobileShell && !_hasContent,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        if (!widget.mobileShell) return; // 桌面吞掉系统返回（见上）
        final bool confirmed = await _cancel();
        if (confirmed && context.mounted) Navigator.of(context).pop();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        },
        child: FocusScope(
          // #37甲（2026-10-14）：这里**必须**是 `FocusScope`，不能降回 `Focus` ——
          // `CallbackShortcuts` 内部是 `Focus(canRequestFocus: false)`，按键只能靠
          // **后代节点上溯**经过它；而点页内空白会触发 `EditableText.onTapOutside`
          // （桌面专属）调 `unfocus()`，默认 `disposition: scope` 把焦点升到
          // **最近的外层 scope**。若是普通 `Focus`，焦点升到路由的 `FocusScope`
          // （在 `CallbackShortcuts` **之上**）⇒ 上溯不再经过它 ⇒ Ctrl+S / Esc 静默失效。
          // 换成 `FocusScope` ⇒ 最近 scope 就是本页 ⇒ 焦点留在页内 ⇒ 恒生效。
          autofocus: true,
          // C3·真机反馈 ④：键盘（含输入法候选栏）高度变化时，把焦点字段滚回可视区
          child: KeyboardReveal(
            child: Scaffold(
              body: SafeArea(
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // §CV·八十 批 1 ③：失败时把「哪几处要填」摆在页顶
                      SubmitErrorSummary(messages: _submitErrorMessages()),
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

  /// 供应商 + 日期
  /// 失败时滚回页顶（用户视线在页底的保存按钮）
  void _scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(0);
  }

  /// 把 typed invalid 摊成「人话」列表给页顶摘要（去重保序）
  List<String> _submitErrorMessages() {
    final PurchaseDraftInvalid? invalid = _invalid;
    if (invalid == null) return const <String>[];
    final List<String> all = <String>[
      ...invalid.fieldErrors.values,
      for (final Map<PurchaseLineField, String> line in invalid.lineErrors)
        ...line.values,
    ];
    return <String>{
      for (final String m in all)
        if (m.trim().isNotEmpty) m,
    }.toList();
  }

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
                  style: TextStyle(
                    height: 1.6,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
            if (_partyName != null)
              TextButton(onPressed: _clearParty, child: const Text('改为散采')),
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
                  style: TextStyle(
                    height: 1.6,
                    color: theme.colorScheme.onSurface,
                  ),
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
          Expanded(child: Text('商品明细', style: theme.textTheme.titleMedium)),
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
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '¥ ${Money.formatGrouped(_draft.totalCents)}',
            textAlign: TextAlign.right,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
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
        // 多付告知（§AY·四，与销售同构）：**橙色内联**、**不拦住提交** ——
        // 「实付 ¥100，其中 ¥93 入账、找零 ¥7」。文案在 core 的 `Overpay`。
        if (_draft.overpayNotice != null) ...<Widget>[
          const SizedBox(height: 4),
          _overpayLine(theme, _draft.overpayNotice!),
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

  /// 多付告知行（橙色）—— 与「错误红」区分：它**不拦人**。
  /// 文案来自 core（`PurchaseDraft.overpayNotice`），这里只摆放。
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
        // #37①：手机壳没有键盘 ⇒ 不显示快捷键后缀（判据 = AppShell.mobileShell）
        child: Text('取消${widget.mobileShell ? '' : ' (Esc)'}'),
      ),
      FilledButton.icon(
        // ⚠️ **稳定 Key**：按钮文案会随「有没有找回」变（§AY·四），
        // 测试**不要**按文案找它 —— 按 Key 找。
        key: const Key('purchase-save'),
        onPressed: _saving ? null : _save,
        icon: _saving
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save_outlined),
        // §AY·四（与销售同构）：**按钮文字是用户动作的最终确认**。
        // 文案由 core 给（`PurchaseDraft.saveActionLabel`），这里只取值。
        label: Text(
          _saving
              ? '保存中…'
              : '${_draft.saveActionLabel()}${widget.mobileShell ? '' : ' (Ctrl+S)'}',
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
            // M10（2026-10-08）：数量 / 单价 / 小计交给共用控件（宽屏并排、
            // 窄屏 + 超大字号堆叠）。⚠️ 单位 chips 与单位错误**移到行卡下方** ——
            // 原先它们是 Row 的直接子项，会挤压两个输入框（与销售/送货页的
            // 摆放也不一致）。
            EntryFieldsRow(
              quantityField: TextField(
                key: const Key('purchase-qty'),
                controller: row.quantity,
                enabled: enabled,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                // P-6：Enter 到下一格（桌面端没有虚拟键盘，要显式切焦点）
                onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                onChanged: (_) => onChanged(),
                decoration: InputDecoration(
                  labelText: row.entryUnitDisplay.isEmpty
                      ? '数量'
                      : '数量（${row.entryUnitDisplay}）',
                  isDense: true,
                  errorText: errors?[PurchaseLineField.quantity],
                ),
              ),
              priceField: TextField(
                key: const Key('purchase-price'),
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
                  labelText: row.priceLabel,
                  isDense: true,
                  errorText: errors?[PurchaseLineField.unitPrice],
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
            // v3 单位切换（§BD·三 第 3 条）：只在**成对启用**时出现
            if (row.canSwitchPackage && enabled) ...<Widget>[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  ChoiceChip(
                    label: Text(row.baseUnit ?? ''),
                    selected:
                        row.entryUnit.isEmpty || row.entryUnit == row.baseUnit,
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
            if (errors?[PurchaseLineField.entryUnit] != null) ...<Widget>[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  errors![PurchaseLineField.entryUnit]!,
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
                    child: Text(
                      account.name,
                      style: const TextStyle(height: 1.6),
                    ),
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
  const _PartyPickerSheet({
    required this.service,
    this.canCreate = false,
    this.partySink,
  });

  final PurchaseService service;

  /// 本机能不能建供应商（`MasterDataPolicy.canCreateParties`）。
  final bool canCreate;

  /// **手机队列出口**（`null` = 桌面 / 未装配 ⇒ 走 `service.createSupplier`）。
  ///
  /// 手机上的 `service` 建在**镜像**上，直写不入队 ⇒ 到不了电脑（2026-10-20
  /// 放开手机往来方建档时补的，§CV·七十七）。
  final QueuePartySink? partySink;

  @override
  State<_PartyPickerSheet> createState() => _PartyPickerSheetState();
}

class _PartyPickerSheetState extends State<_PartyPickerSheet> {
  final TextEditingController _query = TextEditingController();

  /// #40①：名称框失焦时查同名（**不在 `onChanged` 查** —— 每敲一个字查一次库
  /// 再 `setState`，中老年用户打字慢，会一直闪；`docs/reply.md` 2026-10-18）
  final FocusNode _nameFocus = FocusNode();
  String? _sameNameHint;

  late List<Party> _items = widget.service.activeSuppliers();
  String? _newNameError;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(_onNameFocusChanged);
  }

  @override
  void dispose() {
    _nameFocus.removeListener(_onNameFocusChanged);
    _nameFocus.dispose();
    _query.dispose();
    super.dispose();
  }

  void _onNameFocusChanged() {
    if (_nameFocus.hasFocus) return;
    final String name = _query.text.trim();
    final Party? existing = name.isEmpty
        ? null
        : widget.service.findPartyByNameIncludingInactive(name);
    final String? hint = partySameNameHint(
      existing,
      adding: const <PartyRole>[PartyRole.supplier],
    );
    if (hint != _sameNameHint) setState(() => _sameNameHint = hint);
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
    // 本机不能建 ⇒ 保留入口、点击后引导
    if (!widget.canCreate) {
      await showMobileGuideDialog(context, MobileGuideTopic.newParty);
      return;
    }
    // 搜索框里已有的文字就是供应商名称（少一步复制粘贴）；空名必须拦 ——
    // 「名称必填」是 P-7 的约定，默默造一个「供应商」会让列表长出垃圾数据。
    final String name = _query.text.trim();
    setState(() => _creating = true);
    try {
      final PartyMutation mutation = widget.partySink == null
          ? widget.service.createSupplier(name)
          : widget.partySink!.createFull(
              name: name,
              roles: const <PartyRole>[PartyRole.supplier],
            );
      if (!mounted) return;
      Navigator.of(context).pop(mutation);
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
            focusNode: _nameFocus,
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
          // #40① 内联提醒（不拦人）：说清「保存后会发生什么」
          if (_sameNameHint != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _sameNameHint!,
                key: const Key('party-same-name-hint'),
                style: const TextStyle(height: 1.6, color: Color(0xFFB45309)),
              ),
            ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _items.length,
              itemBuilder: (BuildContext context, int index) => ListTile(
                dense: true,
                title: Text(
                  _items[index].name,
                  style: const TextStyle(height: 1.6),
                ),
                subtitle: _items[index].phone == null
                    ? null
                    : Text(_items[index].phone!),
                // 选中已有供应商 = 什么都没改 ⇒ `existing`
                onTap: () => Navigator.of(context).pop(
                  PartyMutation(
                    party: _items[index],
                    action: PartyMutationAction.existing,
                  ),
                ),
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
    required this.sink,
    this.canCreate = false,
    // #31：手机壳才显示「当前库存」框（桌面期初有独立入口）
    this.allowOpeningStock = false,
  });

  final ProductService service;

  /// 空查询时展示的「最近采购」列表 —— 由页面查好传入
  /// （查询在 `PurchaseService` 上，本组件只拿 `ProductService` 做搜索与新建）。
  final List<Product> recentProducts;

  /// 本机能不能建商品（`MasterDataPolicy.canCreateProducts`）。
  final bool canCreate;

  /// 建档 / 编辑的**提交出口**（桌面落库 / 手机乐观写 + 入队）。
  final MasterDataSink sink;

  /// **#31（2026-10-16 裁定甲）**：`true` =「新建商品」对话框显示可选的
  /// 「当前库存」框（手机壳）。桌面期初有独立入口 ⇒ 恒 false。
  final bool allowOpeningStock;

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
    // 本机不能建 ⇒ 保留入口、点击后引导
    if (!widget.canCreate) {
      await showMobileGuideDialog(context, MobileGuideTopic.newProduct);
      return;
    }
    // 复用商品建档对话框（§X P-4：搜不到就建，不打断录入）
    final Product? created = await showProductFormDialog(
      context,
      service: widget.service,
      sink: widget.sink,
      // #31：手机建档带可选期初（堵「不能填库存 ⇒ 超卖」，A1 验收发现）
      allowOpeningStock: widget.allowOpeningStock,
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
                      !widget.canCreate
                          ? mirrorEmptyMessage('商品列表')
                          : _searched
                          ? '没有匹配的商品，可以点下面新建。'
                          : '还没有采购记录，直接搜索或新建。',
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
