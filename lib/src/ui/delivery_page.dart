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

import 'keyboard_reveal.dart';
import 'mobile_guidance_dialog.dart';
import 'entry_unit_hints.dart';
import 'entry_fields_row.dart';
import 'stock_snapshot_cache.dart';
import 'draft_banner.dart';
import 'submit_error_summary.dart';
import 'missing_product_dialog.dart';
import 'product_form_dialog.dart';
import 'notice.dart';

/// 店内送货页。
class DeliveryPage extends StatefulWidget {
  const DeliveryPage({
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

  /// 开单页**查询**用（选择器 / 库存快照 —— 读）。
  final DeliveryService service;

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
  /// 手机 = `QueuePartySink`（写镜像 + 入队 + 立即推）；桌面 = `null`。
  final QueuePartySink? partySink;

  /// 主数据提交**出口**（桌面 `ServiceMasterSink` / 手机 `QueueMasterSink`）。
  /// ⚠️ 商品表单**必须**走它 —— 手机端的 `ProductService` 建在镜像上。
  final MasterDataSink masterDataSink;

  /// **未同步库存影响**（M08，2026-10-08）：手机端注入（镜像队列）；
  /// 桌面 `null` = 不叠加 —— 桌面的权威库就是本机，没有「未同步」这回事。
  final StockDelta? stockDelta;

  /// **是不是手机壳**（M07 / BUG-06，2026-10-08）：决定「怎么办」的指引写给谁。
  ///
  /// 手机壳**没有单据详情页**，也没有退货入口 —— 对它说「到「单据」详情页点
  /// 收款」是一条走不通的路。桌面才给本机路径。
  final bool mobileShell;

  /// **草稿自动保存**（真实诉求批 ①，2026-10-24，§CV·一百零三）。
  ///
  /// 语义与销售 / 采购页逐字相同，**唯一差别：送货单没有收付款**。
  final DraftsStore? drafts;

  /// 商品搜索与「＋新建商品」复用商品建档。
  final ProductService productService;

  /// 客户「新建」入口（与供应商共用 ensureParty，Z-4）。
  final PartyService partyService;

  @override
  State<DeliveryPage> createState() => _DeliveryPageState();
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
  /// 与销售 / 采购页**逐字段同构** —— 改一边必须扫另两边（纪律 18）。
  final TextEditingController name;

  /// 名字被手改 ⇒ 解绑商品；换算上下文一并对齐清空。
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
  /// （§BG 方案 A ②）—— 与采购 / 销售**逐字段同构**，改一边必须扫另两边
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
      name.text.trim().isEmpty &&
      quantity.text.trim().isEmpty &&
      unitPrice.text.trim().isEmpty;

  /// 数量取值；非法时 `null`（与 `PurchaseLineDraft.quantityValue` 同名对齐）
  int? get quantityValue {
    final int? qty = int.tryParse(quantity.text.trim());
    return (qty == null || qty <= 0) ? null : qty;
  }

  /// 换算后的**最小单位数量**（`document_lines.quantity` 的值）。
  ///
  /// ⚠️ **与销售页 `_RowCtl.baseQuantityValue` 逐字同构**（#44 的硬前置：
  /// 三页是**三份独立实现**，改一页必须 grep 另两页 —— `Agents.md` 纪律 18）。
  /// 采购页**故意没有**这份 getter：进货是加库存，不做负库存判定。
  ///
  /// 语义（#44 裁定「甲」）：**数量没填 / 非法 ⇒ `null`**（**不换算、不兜底**）；
  /// 换算失败也 `null`。⚠️ 不能写 `quantityValue ?? 0` —— 空框被 0 兜底会让
  /// 「本行没数量」伪装成一个合法的 0，负库存判定（`qty > estimated`）就会
  /// 在快照为负时**假告警**（销售页 #28① 踩过，见 §CV·三十三）。
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
    name.dispose();
  }
}

class _DeliveryPageState extends State<DeliveryPage> {
  /// **本机能不能建往来方**：策略放开 **且** 出口齐备。
  ///
  /// 手机上的 `partyService` / `service` 建在**镜像**上，直写不入队 ⇒ 到不了电脑
  ///（静默丢数据）。桌面没有这个问题（直连主库）⇒ 只在策略就是「手机」且
  /// 没装出口时拦住。
  bool get _canCreateParty =>
      widget.masterDataPolicy.canCreateParties &&
      (widget.partySink != null ||
          widget.masterDataPolicy != const MasterDataPolicy.mobile());
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
  /// 库存快照：一次会话内缓存，**提交成功后失效**（§CV·八十一 批 2）。
  ///
  /// 原来是 `late final`（只算一次），而 `_afterSaved` 复用同一个 State ⇒
  /// **第二张送货单**的「当前库存」还含上一单已扣的量 ⇒ 该报负库存时不报。
  late final StockSnapshotCache _stockSnapshot = StockSnapshotCache(
    widget.service.stockSnapshot,
  );

  /// 打开本页时的**未同步影响**（M08）：手机刚开的单还没推到电脑，
  /// 权威快照里没有它们 —— 提示要说清「其中本地未同步 N 件」。
  late final Map<String, int> _unsyncedDelta =
      widget.stockDelta?.unsyncedDelta() ?? const <String, int>{};

  /// 保存失败的字段级原因（用户改任何输入后清掉）
  DeliveryDraftInvalid? _invalid;

  /// 保存失败要**滚回页顶**（§CV·八十 批 1 ③）
  final ScrollController _scroll = ScrollController();

  bool _saving = false;

  // ---- 草稿（①）----
  Timer? _draftTimer;
  String _lastDraftSig = '';

  /// **保存后那一刻的表单指纹**（F2，2026-10-25 复跑）。
  ///
  /// P-3 裁定"保存后保留供应商"（连续录单更快），于是保存完表单里还剩一个往来方。
  /// 离开页面时 `_writeDraftNow()` 会把这堆"残留"当成一份草稿写下去 ——
  /// 下次进页面弹「恢复草稿」，恢复出来是空表单（复跑实测的假草稿）。
  /// 记下基线：**表单没再动过**就不写（也不调度）。
  String _savedSig = '';

  String _draftSig() {
    final Map<String, Object?> json = deliveryDraftToJson(_draft);
    json.remove('savedAt');
    return jsonEncode(json);
  }

  Map<String, Object?>? _restoreRaw;

  @override
  void initState() {
    super.initState();
    _addRow();
    final Map<String, Object?>? raw = widget.drafts?.read(DraftKind.delivery);
    if (raw != null) {
      if (deliveryDraftFromJson(raw) == null) {
        widget.drafts!.delete(DraftKind.delivery);
      } else {
        _restoreRaw = raw;
      }
    }
  }

  @override
  void dispose() {
    // ① 先同步落盘再 dispose 控制器（顺序反了就读不到用户输入）
    _draftTimer?.cancel();
    _writeDraftNow();
    _scroll.dispose();
    _remark.dispose();
    for (final _RowCtl row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------ 草稿自动保存（①）

  void _maybeScheduleDraft() {
    if (widget.drafts == null) return;
    if (_savedSig.isNotEmpty && _draftSig() == _savedSig) return; // F2：保存后的残留
    final Map<String, Object?> json = deliveryDraftToJson(_draft);
    json.remove('savedAt');
    final String sig = jsonEncode(json);
    if (sig == _lastDraftSig) return;
    _lastDraftSig = sig;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 1500), _writeDraftNow);
  }

  void _writeDraftNow() {
    final DraftsStore? store = widget.drafts;
    if (store == null) return;
    // F2：保存后表单没再动过 ⇒ 这是残留，不是用户要留的草稿
    if (_savedSig.isNotEmpty && _draftSig() == _savedSig) {
      store.delete(DraftKind.delivery);
      return;
    }
    final DeliveryDraft draft = _draft;
    if (!deliveryDraftHasContent(draft)) {
      // F1（2026-10-25 复跑）：**表单空 ≠ 用户清空了草稿**。
      // 进页时草稿只被读进 `_restoreRaw` 等用户点「恢复」，表单本来就还是空的；
      // 此时删掉 = 「切两次页面就丢」。宁可多留一份脏数据，也不吞用户输入。
      if (_restoreRaw != null) return;
      store.delete(DraftKind.delivery);
      return;
    }
    store.writeSync(DraftKind.delivery, deliveryDraftToJson(draft));
  }

  void _discardDraft() {
    widget.drafts?.delete(DraftKind.delivery);
    setState(() {
      _restoreRaw = null;
      _lastDraftSig = '';
    });
  }

  void _restoreDraft() {
    final DeliveryDraft? draft = deliveryDraftFromJson(_restoreRaw);
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
      for (final DeliveryLineDraft line in draft.lines) {
        final _RowCtl row = _RowCtl(
          quantity: line.quantity,
          unitPrice: line.unitPrice,
        );
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

      _restoreRaw = null;
      _lastDraftSig = '';
    });
  }

  Widget _draftBanner(ThemeData theme) {
    final Object? rawLines = _restoreRaw?['lines'];
    return DraftBanner(
      prefix: 'delivery',
      savedAt: draftSavedAt(_restoreRaw),
      lineCount: rawLines is List ? rawLines.length : 0,
      onRestore: _restoreDraft,
      onDiscard: _discardDraft,
    );
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
          // ② 手打名字的行：`productId` 为空、`productName` 有值（服务层补档）
          productId: row.product?.id ?? '',
          productName: row.name.text.trim(),
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
  /// 打开商品表单（名字预填），建好后绑到同名的那一行（「去填详细信息」那条路）。
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

  Future<void> _save() async {
    if (_saving) return;

    // ② 无缝建档（2026-10-25，§CV·一百零五）：先按名字绑已有商品（只读），
    // 剩下的才问 —— 名字一模一样就自动匹配，不拿弹窗打扰用户（④甲）。
    final ProductBackfill backfill = ProductBackfill(widget.productService.db);
    for (final _RowCtl row in _rows) {
      if (row.product != null || row.name.text.trim().isEmpty) continue;
      final Product? found = backfill.findByName(row.name.text);
      if (found != null) row.attachProduct(found);
    }
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
        await _openProductFormFor(missing.first);
        return; // 本单不保存
      }
    }

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
      showSnack(
        context,
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
      showSnack(
        context,
        SnackBar(
          content: Text(storageFailureNote(error)),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  /// 保存成功：**保留客户与日期**（连续给同一客户送货是常态），只清明细。
  ///
  /// ⚠️ 送货单**没有收款** ⇒ 落库后必然是「全额欠款 + 待签收」，
  /// 所以 SnackBar 不该说「已结清」那一套，而要说清**下一步做什么**。
  void _afterSaved(DocumentSubmitResult result) {
    // ① 保存成功 ⇒ 草稿使命完成（清空表单后 `_writeDraftNow` 也会删，这里删得更快）
    widget.drafts?.delete(DraftKind.delivery);
    _lastDraftSig = '';
    // F2：等这一帧的 setState 落地（明细已清空、只留客户）再记"保存后基线"；
    // 用户之后再动任何输入，指纹就偏离基线 ⇒ 照常写草稿。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _savedSig = _draftSig();
    });
    // 刚提交的单据已落账 ⇒ 快照作废（§CV·八十一 批 2）
    _stockSnapshot.invalidate();
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
      showSnack(
        context,
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
    showSnack(
      context,
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
  /// 草稿是否有内容 —— **取消确认**与**返回拦截**（M09）共用同一判据。
  ///
  /// ⚠️ M11（2026-10-08）：**备注也算内容**。以前只填备注时点取消会直接清空，
  /// 用户白打了一行字（三种表单都如此，报告实测）。
  bool get _hasContent =>
      _partyId != null ||
      _rows.any((_RowCtl row) => !row.isEmpty) ||
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
      if (confirmed != true) return false;
    }
    if (!mounted) return false;
    // ① 用户确认放弃 ⇒ 草稿一起删
    widget.drafts?.delete(DraftKind.delivery);
    _lastDraftSig = '';
    // 放弃之后表单是空的，「保存后基线」不再有任何意义 —— 清掉，
    // 免得上一单的基线残留下来误判（F2 的基线只在 `_afterSaved` 里记）
    _savedSig = '';
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
        recentProducts: widget.service.recentlyDelivered(),
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
        canCreate: _canCreateParty,
      ),
    );
  }

  // ------------------------------------------------------------ 摆放

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // ① 草稿：任何输入变化都会重建 ⇒ 在这里统一调度防抖
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
                      // ① 草稿橙条（最上面）
                      if (_restoreRaw != null) _draftBanner(theme),
                      // §CV·八十 批 1 ③：失败时把「哪几处要填」摆在页顶
                      SubmitErrorSummary(messages: _submitErrorMessages()),
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
    final DeliveryDraftInvalid? invalid = _invalid;
    if (invalid == null) return const <String>[];
    final List<String> all = <String>[
      ...invalid.fieldErrors.values,
      for (final Map<DeliveryLineField, String> line in invalid.lineErrors)
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
                  errorText: _invalid?.fieldErrors[DeliveryField.party],
                ),
                child: Text(
                  // 送货的客户**必选**，没有「散客」这一档 ⇒ 空的时候是提示语，
                  // 不是「散客（当场结清）」（那是销售页的说法）
                  _partyName ?? '点这里选客户（必选）',
                  style: TextStyle(
                    height: 1.6,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
            if (_partyName != null)
              TextButton(onPressed: _clearParty, child: const Text('换一个客户')),
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
          Expanded(child: Text('商品明细 *', style: theme.textTheme.titleMedium)),
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
              : _stockSnapshot.value[_rows[i].product!.id],
          // M08：本地未同步影响（同一商品的队列 Δ）
          unsyncedOfProduct: _rows[i].product == null
              ? null
              : _unsyncedDelta[_rows[i].product!.id],
          enabled: !_saving,
          // ② 主机出口才能顺手建档（手机 QueueSink 不行）
          allowTypedName: widget.sink.canCreateProducts,
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
        // #52（2026-10-15 外测 M13）：**窄屏 + 大金额不裁切** —— 原来是
        // `Row[Text, Spacer, Text]`：金额那格没有弹性，360 宽 + 2.0 字号下
        // 「¥ 19,999,980.00」被裁到不可读（外测截图实测）。改「Expanded +
        // 右对齐」：放得下视觉同旧，放不下自动换行 —— 与 sale / purchase
        // 的 `_totalBar` 同款（三页同构，纪律 18）。
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

  /// 没有收款区时的**替代说明**——不是空白，而是把两件事说清（§AP）：
  ///
  /// 1. **为什么不收钱**：送货单本身就是赊销，货离店、账挂在客户名下；
  ///    客户当场给钱，送完去单据详情点「收款」。
  /// 2. **拒收怎么办**：内联提示走销售退货（v1.1），免得用户找不到路、
  ///    也免得 1b 自然长出退货需求。
  ///
  /// 全部**内联橙色**（`ui_principles.md` §1.3：可以不拦人的提醒一律内联）。
  Widget _noPaymentNote(ThemeData theme) {
    const TextStyle noteStyle = TextStyle(
      height: 1.6,
      color: AppColors.warningOrange,
    );
    // ⚠️ **文案按壳分**（M07 / BUG-06，2026-10-08 修正两处）：
    // ① 原文「退货功能开发中」已过时 —— 退货（RULE-007/008）早已上线；
    // ② 手机壳没有「单据」详情页与退货入口，指本机路径 = 死路。
    final String payNote = widget.mobileShell
        ? '送货单不收钱：货送出去，货款先挂在客户名下（赊销）。'
              '客户当场给钱的话，请到电脑上收这笔款（这台手机上目前只能开单）。'
        : '送货单不收钱：货送出去，货款先挂在客户名下（赊销）。'
              '客户当场给钱的话，送完到「单据」详情页点「收款」。';
    final String rejectNote = widget.mobileShell
        ? '客户拒收：请在电脑上打开这张送货单，点「客户拒收」（整单退回）。'
        : '客户拒收：到这张送货单的详情页点「客户拒收」（整单退回）。';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(payNote, style: noteStyle),
        const SizedBox(height: 6),
        Text(rejectNote, style: noteStyle),
      ],
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

  /// `Wrap` 放不下就换行；`spacing` 取代原来的 `SizedBox`（与销售 / 采购两页一致，
  /// #29：这两页早已是 `Wrap`，送货页漏改 ⇒ 超大缩放下「取消 / 保存」并成一行并溢出）。
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
        label: Text(
          _saving ? '保存中…' : '保存${widget.mobileShell ? '' : ' (Ctrl+S)'}',
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
  final Map<DeliveryLineField, String>? errors;

  /// 该商品的**库存快照**（打开本页时）；没选商品 / 无流水时为 `null`（按 0 理解）
  final int? stockOfProduct;

  /// 该商品的**本地未同步影响**（M08）：`null` = 没有 / 桌面端
  final int? unsyncedOfProduct;
  final bool enabled;

  /// 能不能**手打商品名**（② 无缝建档）= `widget.sink.canCreateProducts`。
  /// 手机队列出口建不了主数据 ⇒ 保持原来的「点此选商品」单元格。
  final bool allowTypedName;
  final VoidCallback onPickProduct;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // #44（2026-10-14）：**必须比「最小单位」** —— 库存（`snapshot` / `estimated`）
    // 是最小单位口径，而 `quantityValue` 是**录入单位的原始数**（3 箱 = 3）
    // ⇒ 按箱录入必然漏报（3 箱 = 36 瓶，只跟库存比了 3）。改用本页刚补的
    // `baseQuantityValue`（与销售页逐字同构，空数量 ⇒ `null` 短路）。
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
                          key: const Key('delivery-product-name'),
                          controller: row.name,
                          enabled: enabled,
                          textInputAction: TextInputAction.next,
                          onSubmitted: (_) =>
                              FocusScope.of(context).nextFocus(),
                          onChanged: (String text) {
                            row.setName(text);
                            onChanged();
                          },
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            isDense: true,
                            hintText: '输入或选商品',
                            errorText: errors?[DeliveryLineField.product],
                            suffixIcon: IconButton(
                              key: const Key('delivery-pick-product'),
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
            // M10（2026-10-08）：数量 / 单价 / 小计的摆放交给共用控件 ——
            // 宽屏并排（与旧版一致），窄屏 + 超大字号自动堆叠。
            EntryFieldsRow(
              quantityField: TextField(
                key: const Key('delivery-qty'),
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
                  errorText: errors?[DeliveryLineField.quantity],
                ),
              ),
              priceField: TextField(
                key: const Key('delivery-price'),
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
                  errorText: errors?[DeliveryLineField.unitPrice],
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

/// 客户选择器：搜索 + 最近往来 + 「＋新建客户」（走 `ensureParty`）。
class _CustomerPickerSheet extends StatefulWidget {
  const _CustomerPickerSheet({
    required this.service,
    required this.partyService,
    this.canCreate = false,
    this.partySink,
  });

  final DeliveryService service;
  final PartyService partyService;

  /// 本机能不能建客户（`MasterDataPolicy.canCreateParties`）。
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
    // 本机不能建 ⇒ 保留入口、点击后引导
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
      // #40①：与销售页同源（`partyMutationNotice`）—— 追加身份 / 复活停用档都要说
      final String? notice = partyMutationNotice(
        result,
        role: PartyRole.customer,
      );
      if (notice != null) {
        showSnack(
          context,
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

/// 商品选择器：搜索 + 最近送货 + 「＋新建商品」（复用商品建档对话框）。
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

  /// 空查询时展示的「最近送货」列表 —— 由页面查好传入。
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
