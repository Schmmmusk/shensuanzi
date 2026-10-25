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

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'package:flutter/services.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart'
    show
        DraftsStore,
        MasterDataPolicy,
        MobileGuideTopic,
        mirrorEmptyMessage,
        partyMutationNotice,
        partySameNameHint;
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'scaled.dart';

import 'keyboard_reveal.dart';
import 'mobile_guidance_dialog.dart';
import 'entry_unit_hints.dart';
import 'entry_fields_row.dart';
import 'stock_snapshot_cache.dart';
import 'draft_banner.dart';
import 'submit_error_summary.dart';
import 'missing_product_dialog.dart';
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
    required this.masterDataPolicy,
    this.partySink,
    required this.masterDataSink,
    this.mobileShell = false,
    this.drafts,
  });

  /// **草稿自动保存**（真实诉求批 ①，2026-10-24，§CV·一百零二）。
  ///
  /// `null` = **不启用** —— 现有 widget 测试都不传，行为与从前逐字相同。
  /// 生产由 `app.dart` 传 `<数据目录>/drafts/` 的 [DraftsStore]。
  ///
  /// 语义（用户裁定 ①甲）：
  /// - 输入变化 ⇒ **1.5 s 防抖**后写盘（`Timer` 异步）；
  /// - 落盘是**同步**的（`dispose` 里不能 `await` —— 一 await widget 就没了，
  ///   紧接着关 App 会中断写盘）；
  /// - 进页发现草稿 ⇒ 顶部**橙条**「恢复 / 放弃」，**不自动填**；
  /// - 保存成功 / 放弃 / 取消并确认 ⇒ 删草稿。
  final DraftsStore? drafts;

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

  /// **主数据门控**（§CV·七 ① 乙，2026-10-09）：三族各自能不能在**本机**建档。
  /// 桌面 = `MasterDataPolicy.desktop()`（全开，零变化）；
  /// 手机 v1 = `MasterDataPolicy.mobile()`（**只开商品**；往来仍「保留入口 + 引导」）。
  ///
  /// ⚠️ **required**：旧版 `readOnlyMasterData` 带默认 `false`，默默漏装就是
  /// 「手机上一切都能建」—— 静默丢数据。宁可编不过。
  final MasterDataPolicy masterDataPolicy;

  /// **往来方写入口的队列出口**（2026-10-20，§CV·七十七）。
  /// 手机 = `QueuePartySink`（写镜像 + 入队 + 立即推）；桌面 = `null`。
  final QueuePartySink? partySink;

  /// 主数据提交**出口**（桌面 `ServiceMasterSink` / 手机 `QueueMasterSink`）。
  ///
  /// ⚠️ 商品表单**必须**走它 —— 手机端的 `ProductService` 建在**镜像**上，
  /// 直接调 `create` 只会写镜像、不入队（见 `product_form_dialog.dart`）。
  final MasterDataSink masterDataSink;

  /// **未同步库存影响**（M08，2026-10-08）：手机端注入（镜像队列）；
  /// 桌面 `null` = 不叠加 —— 桌面的权威库就是本机，没有「未同步」这回事。
  final StockDelta? stockDelta;

  /// **壳类型**（#37①，2026-10-14）：手机壳**没有键盘** ⇒ 按钮文案不带
  /// `(Esc)` / `(Ctrl+S)` 后缀。判据沿用 `AppShell.mobileShell`（**不新造 flag**）。
  final bool mobileShell;

  /// 商品搜索与「＋新建商品」复用商品建档。
  final ProductService productService;

  /// 客户「新建」入口（与供应商共用 ensureParty，Z-4）。
  final PartyService partyService;

  @override
  State<SalePage> createState() => _SalePageState();
}

/// 一行明细的控制器（商品选择结果 + 数量 / 单价原文）
class _RowCtl {
  _RowCtl({
    String quantity = '',
    String unitPrice = '',
    String productName = '',
  }) : quantity = TextEditingController(text: quantity),
       unitPrice = TextEditingController(text: unitPrice),
       name = TextEditingController(text: productName);

  /// 明细行上的**商品名**（② 无缝建档，2026-10-25，§CV·一百零五）。
  ///
  /// 这是**显示与提交的唯一来源**：`product` 非空时它等于商品名；
  /// 用户手打一个新名字时 [product] 会被解绑（`null`），保存时由服务层
  /// 「先精确匹配、匹配不到才建档」。
  final TextEditingController name;

  /// 名字被手改 ⇒ **解绑商品**（名字变了就不再是那个商品）。
  ///
  /// 换算上下文一并对齐清空：新名字可能是个新商品（单位「件」），
  /// 沿用旧商品的「箱 = 48 瓶」会算错数量。
  ///
  /// ⚠️ 用户只是误触（改成同名）⇒ 不解绑（`trim` 后相等就放过）。
  void setName(String text) {
    if (product == null) return;
    if (text.trim() == product!.name.trim()) return;
    product = null;
    baseUnit = null;
    packageUnit = null;
    packageSize = null;
    entryUnit = '';
    entryPriceKept = false;
  }

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
    name.text = picked.name;
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
      name.text.trim().isEmpty &&
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

  /// 换算后的**最小单位数量**（`document_lines.quantity` 的值）。
  ///
  /// ⚠️ **数量没填 / 非法 ⇒ `null`**（**不换算、不兜底**）；换算失败也 `null`
  /// （validate 会带文案拦住）。
  ///
  /// #44（2026-10-14 裁定「甲」）：原来写 `entryQuantity: quantityValue ?? 0`
  /// —— 空框被 **0 兜底**，而 `toBaseQuantity` 对「没切单位」原样返回 `0`
  /// ⇒ 负库存判定退化成 `0 > estimated` ⇒ 快照为负时**空数量也报假告警**，
  /// 并挤掉「本地未同步」说明（M08 就是这么红的）。
  /// 判据：**「没有数量」是 `null`，不是 `0`** —— `null` 让调用方短路，
  /// `0` 会伪装成一个合法的比较值。
  int? get baseQuantityValue {
    final int? entry = quantityValue;
    if (entry == null) return null;
    return toBaseQuantity(
      entryQuantity: entry,
      entryUnit: entryUnit.isEmpty ? null : entryUnit,
      baseUnit: baseUnit ?? '',
      packageUnit: packageUnit,
      packageSize: packageSize,
    ).baseQuantityOrNull;
  }

  /// 本行小计（分）= 折前 − 让价（v3 真相口径）；字段没填全 ⇒ `null`
  int? get amountCents {
    final int? gross = grossCents;
    if (gross == null) return null;
    return gross - discountCents;
  }

  void dispose() {
    quantity.dispose();
    unitPrice.dispose();
    name.dispose();
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

  /// ⚠️ **库存快照与未同步影响不再是字段**（#28②，2026-10-14）——
  /// 它们原来是 `late final`（**只在建页时算一次**），而保存成功后
  /// `_afterSaved` 是「原地清行 + 复用同一个 State」⇒ 接着开第二单时，
  /// 估算库存**不含刚下的那一单**（两个快照都过期）⇒ 该提示负库存时不提示。
  /// 现在改成在 `build()` 里各取一次（每条都是一次单查询，不是每行一次）。

  /// 保存失败的字段级原因（用户改任何输入后清掉）
  SaleDraftInvalid? _invalid;

  /// 保存失败要**滚回页顶**（§CV·八十 批 1 ③：错误摘要放在页顶）
  final ScrollController _scroll = ScrollController();

  /// 库存快照：一次会话内缓存，**提交成功后失效**（§CV·八十一 批 2）
  late final StockSnapshotCache _stockSnapshot = StockSnapshotCache(
    widget.service.stockSnapshot,
  );

  bool _saving = false;

  // ---------------------------------------------------------------- 草稿（①）
  //
  // 真实诉求批 ①（2026-10-24，§CV·一百零二）。三条纪律：
  //  ① 防抖用 `Timer`（异步），**落盘用 `*Sync`** —— `dispose` 里不能 `await`；
  //  ② 空表单不写草稿（`saleDraftHasContent`），否则下次进页挂一个「空草稿」橙条；
  //  ③ 进页发现草稿**只挂橙条、不自动填**（用户可能想开新单）。

  /// 1.5 s 防抖定时器（用户裁定：1~2 s）
  Timer? _draftTimer;

  /// 上次调度时的草稿指纹 —— 用来避免「每次 build 都重置定时器」
  String _lastDraftSig = '';

  /// 进页读到的**待恢复**草稿（`null` = 没有 / 已处理）
  Map<String, Object?>? _restoreRaw;

  @override
  void initState() {
    super.initState();
    _accounts = widget.service.activeAccounts();
    // 进页先看有没有上次的草稿（读不懂的直接删掉，不打扰用户）
    final Map<String, Object?>? raw = widget.drafts?.read(DraftKind.sale);
    if (raw != null) {
      if (saleDraftFromJson(raw) == null) {
        widget.drafts!.delete(DraftKind.sale);
      } else {
        _restoreRaw = raw;
      }
    }
    // 默认账户：第一个启用中的（一般是现金）—— 用户不用每次都选
    if (_accounts.isNotEmpty) {
      _pays.add(_PayCtl(account: _accounts.first));
    }
    _addRow();
  }

  @override
  void dispose() {
    // ⚠️ **必须在 dispose 控制器之前**、且**必须同步**：
    // 用户可能直接关窗口，这里 `await` 的话 widget 已销毁、写盘会被中断。
    _draftTimer?.cancel();
    _writeDraftNow();
    _scroll.dispose();
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

  // ------------------------------------------------------------ 草稿自动保存

  /// 任何输入变化都会重建 ⇒ 在这里统一调度防抖。
  ///
  /// ⚠️ 为什么挂在 `build` 而不是逐个 `onChanged`：本页有 10+ 个输入点
  ///（行数量 / 行单价 / 让价 / 备注 / 顾客给了 / 客户 / 日期 / 收付款…），
  /// 漏接一个的后果是「那一项不进草稿，恢复出来是残缺的单」——
  /// 而用户以为已经救回来了。用「内容指纹变了才重置定时器」来避免
  /// 无关重建（缩放等）把定时器一直顶掉。
  void _maybeScheduleDraft() {
    if (widget.drafts == null) return;
    final Map<String, Object?> json = saleDraftToJson(_draft);
    json.remove('savedAt'); // 时间戳每次都变，不能进指纹
    final String sig = jsonEncode(json);
    if (sig == _lastDraftSig) return;
    _lastDraftSig = sig;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 1500), _writeDraftNow);
  }

  /// 立刻落盘（**同步**）。空表单 ⇒ 删草稿（不是写一份空的）。
  void _writeDraftNow() {
    final DraftsStore? store = widget.drafts;
    if (store == null) return;
    final SaleDraft draft = _draft;
    if (!saleDraftHasContent(draft)) {
      // F1（2026-10-25 复跑）：**表单空 ≠ 用户清空了草稿**。
      // 进页时草稿只被读进 `_restoreRaw` 等用户点「恢复」，表单本来就还是空的；
      // 此时删掉 = 「切两次页面就丢」。宁可多留一份脏数据，也不吞用户输入。
      if (_restoreRaw != null) return;
      store.delete(DraftKind.sale);
      return;
    }
    store.writeSync(DraftKind.sale, saleDraftToJson(draft));
  }

  /// 放弃草稿（橙条上的「放弃」）：删文件 + 收起橙条，**表单不动**。
  void _discardDraft() {
    widget.drafts?.delete(DraftKind.sale);
    setState(() {
      _restoreRaw = null;
      // 用户还在填（表单有内容）⇒ 下一次 build 会重新调度保存，这是对的
      _lastDraftSig = '';
    });
  }

  /// 恢复草稿（橙条上的「恢复」）：把 JSON 摊回控制器。
  void _restoreDraft() {
    final SaleDraft? draft = saleDraftFromJson(_restoreRaw);
    if (draft == null) {
      _discardDraft();
      return;
    }
    setState(() {
      _partyId = draft.partyId;
      _partyName = draft.partyName.isEmpty ? null : draft.partyName;
      final DateTime? day = DateTime.tryParse(draft.date);
      if (day != null) _date = day;
      _remark.text = draft.remark;

      for (final _RowCtl row in _rows) {
        row.dispose();
      }
      _rows.clear();
      for (final SaleLineDraft line in draft.lines) {
        final _RowCtl row = _RowCtl(
          quantity: line.quantity,
          unitPrice: line.unitPrice,
        );
        // 商品可能已被删 / 停用 ⇒ 保留「只有数量单价的行」（保存时会按现有校验报错，
        // 不会静默丢行 —— 提案 §1.6 边界 1）
        final Product? product = line.productId.isEmpty
            ? null
            : widget.productService.byId(line.productId);
        row.product = product;
        // ② 手打名字的行也要把名字填回去（草稿里存了 `productName`）
        row.name.text = line.productName.trim().isEmpty
            ? (product?.name ?? '')
            : line.productName.trim();
        row.baseUnit = line.baseUnit ?? product?.unit;
        row.packageUnit = line.packageUnit ?? product?.packageUnit;
        row.packageSize = line.packageSize ?? product?.packageSize;
        row.entryUnit = line.entryUnit;
        _rows.add(row);
      }
      if (_rows.isEmpty) _rows.add(_RowCtl());

      for (final _PayCtl pay in _pays) {
        pay.dispose();
      }
      _pays.clear();
      for (final SalePaymentDraft p in draft.payments) {
        Account? account;
        for (final Account a in _accounts) {
          if (a.id == p.accountId) {
            account = a;
            break;
          }
        }
        _pays.add(_PayCtl(account: account, amount: p.amount));
      }
      if (_pays.isEmpty && _accounts.isNotEmpty) {
        _pays.add(_PayCtl(account: _accounts.first));
      }

      _restoreRaw = null;
      _lastDraftSig = ''; // 恢复后内容变了，下一次 build 重新调度
    });
    _syncSpread();
  }

  /// 顶部橙条：发现草稿。**不自动填**，两个动作都摆在眼前。
  ///
  /// 组件在 `draft_banner.dart` —— 三个开单页共用（措辞只有一处）。
  Widget _draftBanner(ThemeData theme) {
    final Object? rawLines = _restoreRaw?['lines'];
    return DraftBanner(
      prefix: 'sale',
      savedAt: draftSavedAt(_restoreRaw),
      lineCount: rawLines is List ? rawLines.length : 0,
      onRestore: _restoreDraft,
      onDiscard: _discardDraft,
    );
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
          // ② 手打名字的行：`productId` 为空、`productName` 有值 ——
          // 服务层保存时补档（`SaleService.create` 的事务内）
          productId: row.product?.id ?? '',
          productName: row.name.text.trim(),
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

  /// #40④：顾客给了钱、收款框却没填够 ⇒ 一句内联指路（判断与文案都在 core）
  String? get _cashGivenNotice {
    final int? given = Money.tryParseYuan(_given.text.trim());
    return given == null ? null : _draft.cashGivenNotice(given);
  }

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

  /// 打开商品表单（名字预填），建好后**直接绑到同名的那一行**。
  ///
  /// 这是「去填详细信息」那条路：给愿意填包装单位 / 条码的人留的后路。
  /// 不自动保存单据 —— 用户回来自己点保存（避免「点了取消却把单存了」）。
  Future<void> _openProductFormFor(String name) async {
    final Product? created = await showProductFormDialog(
      context,
      service: widget.productService,
      sink: widget.masterDataSink,
      initialName: name,
    );
    if (created == null || !mounted) return;
    setState(() {
      for (final _RowCtl row in _rows) {
        if (row.product == null && row.name.text.trim() == name.trim()) {
          row.attachProduct(created);
        }
      }
    });
  }

  /// `sink.submitSale` 是**同步**的（库操作 / 入队进程内完成，无 IO 等待）。
  Future<void> _save() async {
    if (_saving) return;
    _syncSpread();
    if (_discountError != null) return; // 内联橙字已在屏上（onChanged 里 setState）

    // ② 无缝建档（2026-10-25，§CV·一百零五）：手打名字、还没绑商品的行，
    // 保存前**先按名字绑一次已有商品**（只读，不写库）。
    //
    // 这一步是 ④甲 的要求：名字一模一样就自动匹配，**不要拿弹窗打扰用户**
    // （他手打名字多半只是懒得翻列表，不是想新建）。剩下的才是真·缺档。
    final ProductBackfill backfill = ProductBackfill(widget.productService.db);
    for (final _RowCtl row in _rows) {
      if (row.product != null || row.name.text.trim().isEmpty) continue;
      final Product? found = backfill.findByName(row.name.text);
      if (found != null) row.attachProduct(found);
    }

    // 一次保存里有多个缺档行 ⇒ 一个对话框列全（不弹三次）。
    final List<String> missing = <String>[
      for (final _RowCtl row in _rows)
        if (row.product == null && row.name.text.trim().isNotEmpty)
          row.name.text.trim(),
    ];
    if (missing.isNotEmpty) {
      final MissingProductChoice choice = await showMissingProductDialog(
        context,
        names: missing.toSet().toList(),
      );
      if (!mounted) return;
      if (choice == MissingProductChoice.cancel) return;
      if (choice == MissingProductChoice.openForm) {
        // 提案 §2.4：**本单不保存** —— 用户去把包装单位这类信息填全，
        // 建好后自动绑到那一行，回来点保存即可（输入一个都不丢）。
        await _openProductFormFor(missing.first);
        return;
      }
      // createAndSave ⇒ 往下走：服务层在同一事务里建档 + 落单
    }

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
        // 用户视线在页底保存按钮 ⇒ 滚回页顶看摘要（§CV·八十 批 1 ③）
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

  /// 保存成功：**保留客户与日期**（连续给同一客户开单是常态），
  /// 只清明细与收款（§X 六 / P-3 同款）。
  /// ⚠️ v1 不显示利润（§Z 遗漏 6）—— SnackBar 只报单号与欠款。
  void _afterSaved(DocumentSubmitResult result) {
    // ① 保存成功 ⇒ 草稿使命完成（清空表单后 `_writeDraftNow` 也会删，这里删得更快）
    widget.drafts?.delete(DraftKind.sale);
    _lastDraftSig = '';
    // 2026-10-22（§CV·八十一 批 2）：刚提交的单据已落账 ⇒ 快照作废，
    // 下一单看到的「当前库存」才是扣过的（否则该报负库存时不报）
    _stockSnapshot.invalidate();
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
    // ① 用户确认放弃 ⇒ 草稿一起删（否则下次进页还会问「要不要恢复」）
    widget.drafts?.delete(DraftKind.sale);
    _lastDraftSig = '';
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
    // #51（裁定乙）：本方法只回答「是否确认放弃」—— 退不退出由调用方定
    return true;
  }

  // ------------------------------------------------------------ 选择器

  Future<void> _pickProduct(int rowIndex) async {
    final Product? picked = await _showProductPicker(context);
    if (picked == null || rowIndex >= _rows.length) return;
    final _RowCtl row = _rows[rowIndex];
    row.attachProduct(picked); // v3：带换算上下文 + 重置录入单位（含 priceTouched = false）
    // ⚠️ **无条件**预填售价 —— 别在这里加守卫。换商品（**含重选同一商品**）时，
    // 旧价对新商品没有意义，必须覆盖；而 `priceTouched` 的语义是「用户**手改过**」，
    // 不是「是否预填过」—— 把它当预填守卫用**正是 #25 的病根**（§CV·二四·一 / §CV·二五）。
    // 与「切单位」（§BG 方案 A）判据**不同**：那里换的是**同一商品**的价格单位，
    // 手改过的价仍是用户的意愿 ⇒ 「未被手改才跟随」；这里换的是**不同商品** ⇒ 总覆盖。
    row.unitPrice.text = Money.format(picked.sellPrice);
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
        // 商品：手机 v1 = 可建（走 sink 乐观写 + 入队）
        canCreate: widget.masterDataPolicy.canCreateProducts,
        sink: widget.masterDataSink,
        allowOpeningStock: widget.mobileShell,
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
        partySink: widget.partySink,
        // 往来：手机 v1 仍禁建（保留入口 + 引导）
        canCreate: _canCreateParty,
      ),
    );
  }

  // ------------------------------------------------------------ 摆放

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 2026-10-22（§CV·八十一 批 2）：**不再每次 build 查库**。
    // 原来这里每 build 一次 `GROUP BY` 全表，而页内任何输入都 `setState`
    // ⇒ 每敲一个键一次全表聚合（报告 §2.5 的性能项）。
    // 现在：一次编辑会话内用缓存，**提交成功后失效**（`_afterSaved`）。
    final Map<String, int> stockSnapshot = _stockSnapshot.value;
    final Map<String, int> unsyncedDelta =
        widget.stockDelta?.unsyncedDelta() ?? const <String, int>{};
    // ① 草稿：任何输入变化都会走到这里（见 `_maybeScheduleDraft` 的注释）
    _maybeScheduleDraft();
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
                      // ① 草稿橙条（在最上面：进页第一眼就该看到「上次的东西还在」）
                      if (_restoreRaw != null) _draftBanner(theme),
                      // §CV·八十 批 1 ③：失败时把「哪几处要填」摆在页顶
                      SubmitErrorSummary(messages: _submitErrorMessages()),
                      _headerRow(theme),
                      const Divider(height: 24),
                      _linesSection(theme, stockSnapshot, unsyncedDelta),
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

  /// 失败时滚回页顶（用户视线在页底的保存按钮）
  void _scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(0);
  }

  /// 把 typed invalid 摊成「人话」列表给页顶摘要（去重保序）
  List<String> _submitErrorMessages() {
    final SaleDraftInvalid? invalid = _invalid;
    if (invalid == null) return const <String>[];
    final List<String> all = <String>[
      ...invalid.fieldErrors.values,
      for (final Map<SaleLineField, String> line in invalid.lineErrors)
        ...line.values,
    ];
    return <String>{
      for (final String m in all)
        if (m.trim().isNotEmpty) m,
    }.toList();
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
                  style: TextStyle(
                    height: 1.6,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
            if (_partyName != null)
              TextButton(onPressed: _clearParty, child: const Text('改为散客')),
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

  Widget _linesSection(
    ThemeData theme,
    Map<String, int> stockSnapshot,
    Map<String, int> unsyncedDelta,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Row(
        children: <Widget>[
          Expanded(child: Text('商品明细 *', style: theme.textTheme.titleMedium)),
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
              : stockSnapshot[_rows[i].product!.id],
          // M08：本地未同步影响（同一商品的队列 Δ）
          unsyncedOfProduct: _rows[i].product == null
              ? null
              : unsyncedDelta[_rows[i].product!.id],
          enabled: !_saving,
          // ② 主机出口才能顺手建档（手机 QueueSink 不行）
          allowTypedName: widget.sink.canCreateProducts,
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
            style: TextStyle(height: 1.6, color: AppColors.warningOrange),
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
          // #40④：填了「顾客给了」却没填够收款框 ⇒ **提交前**说清会发生什么
          // （不拦人：用户可能只是拿它算个数，与「不够」同款处置）
          if (_cashGivenNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _cashGivenNotice!,
                key: const Key('sale-cash-given-notice'),
                style: const TextStyle(
                  height: 1.6,
                  color: AppColors.warningOrange,
                ),
              ),
            ),
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
      const Icon(Icons.info_outline, color: AppColors.warningOrange, size: 18),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(height: 1.6, color: AppColors.warningOrange),
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
        : '找零 ¥${Money.formatGrouped(Overpay(givenCents: given, dueCents: total).changeCents)}';

    final Widget givenField = SizedBox(
      // 批 3 第 13 条：随缩放派生
      width: scaledOf(context, wideAmountColumnBase),
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
        // 批 3 第 13 条：断点随缩放派生
        if (isNarrowOf(context, constraints.maxWidth)) {
          // 窄屏（手机）：chips 独立成行右对齐 —— 不再挤爆
          content = <Widget>[
            Row(
              children: <Widget>[
                Text('顾客给了', style: theme.textTheme.bodySmall),
                const SizedBox(width: 8),
                // 批 3 第 13 条：**窄屏里必须可收缩**。字段宽随缩放变大后
                //（120→240），360px 窗口 + 2 倍字号直接溢出 38px。
                // `SizedBox` 会服从父级约束 ⇒ 用 Flexible 让它在不够时缩。
                Flexible(child: givenField),
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
                            ? AppColors.warningOrange
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
                            ? AppColors.warningOrange
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
        // #37①：手机壳没有键盘 ⇒ 不显示快捷键后缀（判据 = AppShell.mobileShell）
        child: Text('取消${widget.mobileShell ? '' : ' (Esc)'}'),
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
              : '${_draft.saveActionLabel(givenCents: Money.tryParseYuan(_given.text.trim()))}'
                    '${widget.mobileShell ? '' : ' (Ctrl+S)'}',
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
    required this.allowTypedName,
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

  /// 能不能**手打商品名**（② 无缝建档，§CV·一百零五）。
  ///
  /// = `widget.sink.canCreateProducts`：主机出口 `true`（保存时在同一事务里建档）；
  /// 手机队列出口 `false` —— 它只入队、不建主数据，放开就是「填了名字存不进去」
  /// 的假承诺。手机端仍是原来的「点此选商品」单元格。
  final bool allowTypedName;
  final VoidCallback onPickProduct;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // #28①（2026-10-14）：**必须比「最小单位」** —— 库存（`snapshot` / `estimated`）
    // 是最小单位口径，而 `quantityValue` 是**录入单位的原始数**（3 箱 = 3）
    // ⇒ 按箱录入必然漏报。改用同文件已有的换算 getter（`baseQuantityValue`）。
    final int? qty = row.baseQuantityValue;
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
                  // ② 桌面：直接手打名字（右边小图标仍能开选择器）；
                  //    手机：保持原来的「点此选商品」单元格（见 allowTypedName）
                  child: allowTypedName
                      ? TextField(
                          key: const Key('sale-product-name'),
                          controller: row.name,
                          enabled: enabled,
                          textInputAction: TextInputAction.next,
                          onSubmitted: (_) =>
                              FocusScope.of(context).nextFocus(),
                          onChanged: (String text) {
                            // 名字变了 ⇒ 解绑商品（保存时按名字重新匹配 / 建档）
                            row.setName(text);
                            onChanged();
                          },
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            isDense: true,
                            hintText: '输入或选商品',
                            errorText: errors?[SaleLineField.product],
                            suffixIcon: IconButton(
                              key: const Key('sale-pick-product'),
                              tooltip: '从商品列表选',
                              onPressed: enabled ? onPickProduct : null,
                              icon: const Icon(
                                Icons.list_alt_outlined,
                                size: 20,
                              ),
                            ),
                          ),
                        )
                      : InkWell(
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
    this.canCreate = false,
    this.partySink,
  });

  final SaleService service;
  final PartyService partyService;

  /// 本机能不能建客户（`MasterDataPolicy.canCreateParties`）。
  /// `false` = 「新建客户」点击后弹引导（保留入口，不隐藏）；空态换成同步引导。
  final bool canCreate;

  /// **手机队列出口**（`null` = 桌面 / 未装配 ⇒ 走 `partyService`）。
  /// 手机上的 `partyService` 建在**镜像**上，直写不入队 ⇒ 到不了电脑
  ///（2026-10-20 放开手机往来方建档时补的，§CV·七十七）。
  final QueuePartySink? partySink;

  @override
  State<_CustomerPickerSheet> createState() => _CustomerPickerSheetState();
}

class _CustomerPickerSheetState extends State<_CustomerPickerSheet> {
  final TextEditingController _query = TextEditingController();
  late List<Party> _items = widget.service.activeCustomers();
  bool _searched = false;
  String? _newNameError;
  bool _creating = false;

  /// #40①：名称框**失焦**才查同名（不在 `onChanged` 查 —— 每键一次库 + setState）
  final FocusNode _nameFocus = FocusNode();
  String? _sameNameHint;

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
        : widget.partyService.findByNameIncludingInactive(name);
    final String? hint = partySameNameHint(
      existing,
      adding: const <PartyRole>[PartyRole.customer],
    );
    if (hint != _sameNameHint) setState(() => _sameNameHint = hint);
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
    // 本机不能建 ⇒ 保留入口、点击后引导（文案在 app 包）
    if (!widget.canCreate) {
      await showMobileGuideDialog(context, MobileGuideTopic.newParty);
      return;
    }
    // 搜索框里已有的文字就是客户名称；空名必须拦（P-7 同款）
    final String name = _query.text.trim();
    setState(() => _creating = true);
    try {
      final PartyMutation result = widget.partySink == null
          ? widget.partyService.ensureParty(
              name: name,
              role: PartyRole.customer,
            )
          : widget.partySink!.createFull(
              name: name,
              roles: const <PartyRole>[PartyRole.customer],
            );
      if (!mounted) return;
      // #40①：措辞走**共用函数**（四页同源，纪律 18）——
      // 「追加身份」和「复活停用档」是两件事，以前只说了前一件
      final String? notice = partyMutationNotice(
        result,
        role: PartyRole.customer,
      );
      if (notice != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(notice), duration: const Duration(seconds: 4)),
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
            focusNode: _nameFocus,
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
          // #40① 内联提醒（不拦人）：说清「保存后会发生什么」
          if (_sameNameHint != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _sameNameHint!,
                key: const Key('party-same-name-hint'),
                style: const TextStyle(
                  height: 1.6,
                  color: AppColors.warningOrange,
                ),
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
                      !widget.canCreate
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
                      title: Text(
                        _items[index].name,
                        style: const TextStyle(height: 1.6),
                      ),
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
    required this.sink,
    this.canCreate = false,
    // #31：手机壳才显示「当前库存」框（桌面期初有独立入口）
    this.allowOpeningStock = false,
  });

  final ProductService service;

  /// 空查询时展示的「最近销售」列表 —— 由页面查好传入。
  final List<Product> recentProducts;

  /// 本机能不能建商品（`MasterDataPolicy.canCreateProducts`）。
  /// `false` = 「新建商品」点击后弹引导（**缺省是安全的**：不动库）。
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
                      !widget.canCreate
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
