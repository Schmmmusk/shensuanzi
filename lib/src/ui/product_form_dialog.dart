/// 商品建档表单（`docs/reply.md` 裁定的 6 个字段 + §AJ·AI-5 的包装说明）。
///
/// ```text
/// 商品名称   [                                ]
/// 单位 [ 件 ]        售价 [        ] 元
///      ↑ 最小销售单位 —— 不是进货的箱子单位（§AJ·AI-5）
///           件 个 斤 公斤 瓶 … 其他▾   ← 点一下即填；[其他▾] 聚焦输入框（§AJ·AI-6）
/// 包装说明（可选） [ 1 箱 = 48 瓶 ]   ← 纯备注，不影响记账
/// 进价 [      ] 元   安全库存 [     ]
/// 条码       [                                ]   ← 扫码枪扫完回车即保存
/// ```
///
/// ## 单位是自由文本（§AJ·AI-6）
///
/// **不是白名单** —— 单位可以随便打字，常用单位 chips 只是「顺手就能点」的
/// 快捷方式。chips 摆在那儿容易让用户以为「只能选」，所以：placeholder 用
/// 「例：」开头（自由填的信号）、chips 末尾给 [其他▾]（点了聚焦输入框）。
///
/// ## 校验不在这里
///
/// 校验与取值全在 `ProductDraft`（纯 Dart、`dart test` 覆盖）。
/// 本文件只负责：**摆放输入框**、**把错误标到对应那一栏**、调服务保存。
///
/// 金额输入框一律 `numberWithOptions(decimal: true)` —— 中老年用户做零售时
/// 输入数量与金额是最高频动作，默认弹出字母键盘等于每次都要多切一次
/// （`docs/ui_principles.md` §四）。
///
/// ## 条码重复为什么不弹窗（R-15 裁定）
///
/// 弹窗「条码已存在，继续吗？」会让用户每次都停下来读一遍 —— 读烦了就不读了，
/// 还可能手滑点「否」。**内联提示**眼睛扫到就看到了，不打断输入、不增加点击，
/// 而且**不拦人**（条码重复是真实常态：同箱拆卖、同款不同批次）。
library;

import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 常用单位。**不是白名单** —— 单位仍是自由文本，这只是「顺手就能点」的快捷方式。
///
/// 清单按真实个体户的高频单位扩充到 14 个（§AJ·AI-6，**刻意没有「箱」** ——
/// 单位要填最小售卖单位，按箱进按个卖的写进包装说明；超过 15 个就失去
/// 「快捷」的意义，剩下的用户自己打字）。
const List<String> _commonUnits = <String>[
  '件',
  '个',
  '斤',
  '公斤',
  '瓶',
  '包',
  '袋',
  '盒',
  '条',
  '桶',
  '捆',
  '扎',
  '提',
  '串',
];

/// 提示色（条码重复这类「需要注意但不拦人」的话）。
///
/// 刻意**不用主题的 error 红**：红只留给真错误（`docs/ui_principles.md` §二）。
/// 取深一档的橙是为了白底上对比度够 —— 浅橙在中老年用户的老花屏上会糊掉。
const Color _noticeColor = AppColors.warningOrange;

/// [sink] = **提交出口**（D2b·§CV·七）：桌面 `ServiceMasterSink`（落库）、
/// 手机 `QueueMasterSink`（**乐观写镜像 + 入队**）。表单只认它。
///
/// ⚠️ **不能再用 `service.create`**：手机端那个 `ProductService` 建在**镜像**上，
/// 直接调它会**只写镜像、不入队**（改动永远到不了电脑，且没人报错）。
///
/// [service] 仍要传 —— 但**只用于读**（条码查重 `barcodeOwners`）。
/// [initialName] = **名字预填**（开单页「去填详细信息」那条路，§CV·一百零五）：
/// 用户在明细行手打的名字带过来，省得再敲一遍；其余字段仍是空表单。
Future<Product?> showProductFormDialog(
  BuildContext context, {
  required ProductService service,
  required MasterDataSink sink,
  Product? existing,
  bool allowOpeningStock = false,
  String? initialName,
}) => showDialog<Product>(
  context: context,
  builder: (BuildContext dialogContext) => _ProductFormDialog(
    service: service,
    sink: sink,
    existing: existing,
    allowOpeningStock: allowOpeningStock,
    initialName: initialName,
  ),
);

class _ProductFormDialog extends StatefulWidget {
  const _ProductFormDialog({
    required this.service,
    required this.sink,
    this.existing,
    this.allowOpeningStock = false,
    this.initialName,
  });

  /// 新增时**预填的商品名**（`null` = 空表单；编辑时忽略 —— 名字来自 [existing]）
  final String? initialName;

  /// **只读**用（条码查重）—— 写入一律走 [sink]。
  final ProductService service;

  /// 提交出口（桌面落库 / 手机乐观写 + 入队）。
  final MasterDataSink sink;

  /// `null` = 新增；非 null = 编辑
  final Product? existing;

  /// **#31（2026-10-16 裁定甲）**：显示可选的「当前库存」框（手机新建专用）。
  /// 桌面不显示 —— 桌面期初有独立入口（`OpeningStockPage`）。
  final bool allowOpeningStock;

  @override
  State<_ProductFormDialog> createState() => _ProductFormDialogState();
}

class _ProductFormDialogState extends State<_ProductFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _unit;
  late final TextEditingController _sellPrice;
  late final TextEditingController _costPrice;
  late final TextEditingController _barcode;
  late final TextEditingController _safetyStock;
  late final TextEditingController _packageNote;
  late final TextEditingController _packageUnit;
  late final TextEditingController _packageSize;

  /// [其他▾] chips（§AJ·AI-6）：点了聚焦单位输入框 —— 「直接打字」的显式入口
  final FocusNode _unitFocus = FocusNode();

  /// 条码框：右侧扫码图标点了聚焦它（扫码枪是键盘设备，聚焦就能打进同一个框）
  final FocusNode _barcodeFocus = FocusNode();

  /// 字段级错误（界面标红哪一栏就看它）
  Map<ProductField, String> _errors = <ProductField, String>{};

  /// 服务层抛出的意外错误（说「怎么办」）
  String? _failure;

  /// #31：「当前库存」框（[ProductFormDialog] 仅在 `allowOpeningStock &&
  /// existing == null` 时显示）。`null` = 没建控制器（桌面 / 编辑模式）。
  TextEditingController? _openingStock;

  /// 「当前库存」的内联错误（不是 `ProductField` —— 它不是商品表的列）
  String? _openingError;

  bool _saving = false;

  // ---- P3（2026-10-25，§CV·一百零七）：滚动发现性 ----
  //
  // 表单在 800×600 / 125% 缩放下装不下：首屏只看得到 名称 / 单位 / 售价 / 包装，
  // 「进价 · 安全库存 · 条码」要往下滚。目标用户是中老年，滚动发现性差
  // （外测报告 P3：测试者本人差点据此误报「字段缺失」）。

  /// 内容区滚动控制器（判断「下面还有没有东西」用）
  final ScrollController _scroll = ScrollController();

  /// **下面还有内容没露出来** —— 只有真的滚得动、且还没滚到底时才为真。
  bool _moreBelow = false;

  /// 条码重复的内联提示原文（`ProductDraft.barcodeNotice` 的返回值）
  String? _barcodeNotice;

  /// 「启用包装换算」是否展开（2026-11-24 三段式重排）。
  ///
  /// **编辑已配置过换算的商品时必须自动展开**（`initState` 里回填）——
  /// 否则用户会以为"这个商品没有配置包装"，而库里明明有。
  bool _packageOpen = false;

  /// 常用单位是否展开「更多」（2026-11-24）。
  ///
  /// 默认只摆 7 个（用户示意截图里的那一排：件·个·斤·公斤·瓶·包·袋）+「更多单位」。
  /// 14 个平铺会占两行、把「进价」挤出 800×600 首屏 —— 而进价决定毛利能不能算出来。
  bool _showAllUnits = false;

  @override
  void initState() {
    super.initState();
    final ProductDraft draft = widget.existing == null
        ? const ProductDraft()
        : ProductDraft.of(widget.existing!);
    // 预填只在「新增」时生效（编辑当然显示原来的名字）
    _name = TextEditingController(
      text: widget.existing == null
          ? (widget.initialName ?? draft.name)
          : draft.name,
    );
    _unit = TextEditingController(text: draft.unit);
    _sellPrice = TextEditingController(text: draft.sellPrice);
    _costPrice = TextEditingController(text: draft.costPrice);
    _barcode = TextEditingController(text: draft.barcode);
    _safetyStock = TextEditingController(text: draft.safetyStock);
    _packageNote = TextEditingController(text: draft.packageNote);
    _packageUnit = TextEditingController(text: draft.packageUnit);
    _packageSize = TextEditingController(text: draft.packageSize);
    // 编辑一条条码本身就已重复的商品时，一打开就该看到提示（不用等用户改动）
    _barcodeNotice = _computeBarcodeNotice();
    // 已配置过换算 ⇒ 打开就展开并回填（不让折叠掩盖已存在的数据）
    _packageOpen =
        draft.packageUnit.trim().isNotEmpty ||
        draft.packageSize.trim().isNotEmpty;
    // #31：只给「手机 + 新建」建控制器；桌面 / 编辑模式连框都不出现
    //（裁定③：编辑时改库存**本批不做** —— 要走期初通路，随整页期初批另裁）。
    if (widget.allowOpeningStock && widget.existing == null) {
      _openingStock = TextEditingController();
    }
    _scroll.addListener(_syncMoreBelow);
  }

  /// 重新判断「下面还有内容没露出来」。
  ///
  /// ⚠️ **只在真的超出时才为真**：大窗口下所有字段都在视口里，还挂一句
  /// 「往下还有」就是撒谎（纪律 17）—— 而目标用户会照着它去滚，滚不动
  /// 就以为软件卡了。所以判据是 `maxScrollExtent > 0`，不是「有没有这个字段」。
  void _syncMoreBelow() {
    if (!mounted || !_scroll.hasClients) return;
    final ScrollPosition position = _scroll.position;
    final bool more =
        position.maxScrollExtent > 0 &&
        position.pixels < position.maxScrollExtent - 1;
    if (more != _moreBelow) setState(() => _moreBelow = more);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _barcodeFocus.dispose();
    _name.dispose();
    _unit.dispose();
    _sellPrice.dispose();
    _costPrice.dispose();
    _barcode.dispose();
    _safetyStock.dispose();
    _packageNote.dispose();
    _packageUnit.dispose();
    _packageSize.dispose();
    _unitFocus.dispose();
    _openingStock?.dispose();
    super.dispose();
  }

  ProductDraft get _draft => ProductDraft(
    name: _name.text,
    unit: _unit.text,
    sellPrice: _sellPrice.text,
    costPrice: _costPrice.text,
    barcode: _barcode.text,
    safetyStock: _safetyStock.text,
    packageNote: _packageNote.text,
    packageUnit: _packageUnit.text,
    packageSize: _packageSize.text,
  );

  /// 用户一改这个字段就把它那条错误清掉 —— 边改边消，而不是等再点一次保存
  void _clearError(ProductField field) {
    if (!_errors.containsKey(field)) return;
    setState(
      () => _errors = Map<ProductField, String>.from(_errors)..remove(field),
    );
  }

  /// 查重全在 core 里（`barcodeOwners` + `barcodeNotice`），这里只负责摆出来。
  ///
  /// `excludeId` 是**必须**的：编辑时商品自己也在库里，
  /// 不排除就会显示「这个条码已经给『它自己』用过了」。
  String? _computeBarcodeNotice() {
    final String text = _barcode.text.trim();
    if (text.isEmpty) return null;
    return ProductDraft.barcodeNotice(
      widget.service.barcodeOwners(text, excludeId: widget.existing?.id),
    );
  }

  /// 条码边打边查重 —— 输入框下方那行橙字实时更新，**不弹窗、不拦人**
  void _onBarcodeChanged(String _) {
    _clearError(ProductField.barcode);
    final String? notice = _computeBarcodeNotice();
    if (notice != _barcodeNotice) {
      setState(() => _barcodeNotice = notice);
    }
  }

  Future<void> _save() async {
    final ProductDraft draft = _draft;

    final Map<ProductField, String> errors = draft.validate();
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }

    // #31：「当前库存」解析（选填；非空必须是 ≥ 0 的整数）。
    // 0 = 「现在没有」，与不填同义 ⇒ 不发（host 端只收正数）。
    int? openingQuantity;
    if (_openingStock != null) {
      final String text = _openingStock!.text.trim();
      if (text.isNotEmpty) {
        final int? parsed = int.tryParse(text);
        if (parsed == null || parsed < 0) {
          setState(() => _openingError = '当前库存要是整数（可以是 0）');
          return;
        }
        if (parsed > 0) openingQuantity = parsed;
      }
    }

    setState(() {
      _saving = true;
      _failure = null;
    });

    try {
      // D2b：**写入走 sink**（桌面 = 落库；手机 = 乐观写镜像 + 入队）。出口把它
      // 自己的校验结论装进结果（不再抛 `ProductDraftInvalid`）。
      final MasterDataSubmitResult result = widget.existing == null
          ? widget.sink.createProduct(draft, openingQuantity: openingQuantity)
          : widget.sink.updateProduct(widget.existing!.id, draft);

      if (!mounted) return;

      if (result.isFailure) {
        setState(() {
          _errors = result.error!.errors;
          _saving = false;
        });
        return;
      }

      // 手机端：**说清这条还没到电脑** —— 编码由主机定，靠 pull 回写镜像
      final String? notice = result.queuedNotice;
      if (notice != null) {
        ScaffoldMessenger.maybeOf(context)
          ?..removeCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(notice)));
      }
      Navigator.of(context).pop(result.product);
    } catch (error) {
      setState(() {
        // #36 文案半（2026-10-14）：**不要把原始异常拼进用户文案** ——
        // 原来是 `SqliteException` 全文直抛（**带整条 SQL 与绑定参数**），
        // 而且「先关掉这个窗口再试一次」对「只读 / 被占用」以外的原因并不成立
        //（正是 M15 那条「不承诺做不到的事」）。与三张开单页同一条通道：
        // `storageFailureNote` 按**结果码**给分类文案，细节由日志承担。
        _failure = storageFailureNote(error);
        _saving = false;
      });
    }
  }

  /// 「下面还有内容」提示（P3）。
  ///
  /// 为什么值得单做一个控件：目标用户不会「先滚一下看看还有没有」——
  /// 他们看到表单结束就以为填完了，于是**进价永远填不上**（毛利恒为 0）。
  /// 这行字把「还有东西」变成可见事实，**点一下直接滚到底**（不用学着拖）。
  ///
  /// 只在 [_moreBelow] 为真时出现（见 `_syncMoreBelow`）。
  /// 分段标题（一、二、三）—— 三段式重排的锚点。
  ///
  /// 为什么值得多花这两行高度：用户要能一眼看出「还有几段没填」。
  /// `optional` 时右侧挂一个「选填」小徽标 —— 比在标题里写括号更安静。
  Widget _sectionHeader(
    ThemeData theme,
    String text, {
    bool optional = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 8),
    child: Row(
      children: <Widget>[
        Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (optional) ...<Widget>[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '选填',
              style: TextStyle(
                fontSize: 12,
                height: 1.2,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
          ),
        ],
      ],
    ),
  );

  /// 「启用包装换算」折叠区（2026-11-24，`docs/reply.md` §二·3）。
  ///
  /// 折叠的是**换算数据**（`packageUnit` + `packageSize`），不是备注 ——
  /// 后者是另一栏（「包装说明」），两者语义不同，界面必须分开放。
  ///
  /// ⚠️ 编辑已配置过换算的商品时**必须已展开并回填**（`initState` 里定的
  /// `_packageOpen`）—— 折叠掩盖既有数据 = 让用户以为没配过。
  Widget _packageToggle(ThemeData theme) => Container(
    key: const Key('product-package-toggle'),
    decoration: BoxDecoration(
      border: Border.all(color: theme.dividerColor),
      borderRadius: BorderRadius.circular(4),
    ),
    child: ExpansionTile(
      initiallyExpanded: _packageOpen,
      onExpansionChanged: (bool open) => setState(() => _packageOpen = open),
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      // 去掉展开态/折叠态的描边（外层容器已经有边框，再叠一层会显脏）
      shape: const Border(),
      collapsedShape: const Border(),
      title: const Text('启用包装换算'),
      subtitle: Text(
        '按箱、包等较大单位录入时，自动换算成最小单位。',
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: theme.textTheme.bodySmall?.color,
        ),
      ),
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _packageUnit,
                textInputAction: TextInputAction.next,
                onChanged: (_) => _clearError(ProductField.packageUnit),
                decoration: _decoration(
                  ProductField.packageUnit,
                  label: '包装单位（可选）',
                  hint: '例：箱',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _packageSize,
                keyboardType: const TextInputType.numberWithOptions(),
                textInputAction: TextInputAction.next,
                onChanged: (_) => _clearError(ProductField.packageSize),
                decoration: _decoration(
                  ProductField.packageSize,
                  label: '1 包 = 多少（可选）',
                  hint: '例：48',
                  helper: '两格都填，开单就能按「箱」录入',
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _moreBelowHint(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: const Key('product-form-more-below'),
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            if (!_scroll.hasClients) return;
            _scroll.animateTo(
              _scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: <Widget>[
                Icon(Icons.arrow_downward, size: 16, color: theme.hintColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    // ⚠️ 2026-11-24：**不再点名具体字段**。三段式重排之后
                    // 「进价 · 安全库存 · 条码」的相对位置全变了，写死名字就是撒谎
                    // （用户实测截图里已经看得见进价，提示还写着"进价在下面"）。
                    '往下还有内容（点这里滚下去）',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: theme.hintColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isNew = widget.existing == null;
    final ThemeData theme = Theme.of(context);

    // P3：内容高度会变（条码提示出现、错误框出现、窗口缩放）⇒ 每帧布局后重算
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncMoreBelow());

    return AlertDialog(
      title: Text(isNew ? '新增商品' : '编辑商品'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 内容区可滚动；「下面还有」提示挂在滚动区**外面**（不会被滚走）
            Flexible(
              child: SingleChildScrollView(
                controller: _scroll,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (_failure != null) ...<Widget>[
                      _failureBox(context),
                      const SizedBox(height: 12),
                    ],

                    // ================= 一、基本资料 =================
                    //
                    // 2026-11-24：三段式重排（用户给的示意 + `docs/reply.md` §二）。
                    // 分区的目的不是"好看"，是让用户**知道还剩多少没填** ——
                    // 旧版一屏铺开，用户填完名称/单位/售价就以为完事了，
                    // 于是进价永远空着、毛利恒为 0（P3 的同一个病根）。
                    _sectionHeader(theme, '一、基本资料'),

                    TextField(
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => _clearError(ProductField.name),
                      decoration: _decoration(
                        ProductField.name,
                        // 必填标红星（`docs/ui_principles.md` §一：必填要显眼）
                        label: '商品名称 *',
                      ),
                    ),
                    const SizedBox(height: 8),

                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _unit,
                            focusNode: _unitFocus,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => _clearError(ProductField.unit),
                            decoration: _decoration(
                              ProductField.unit,
                              label: '单位 *',
                              hint: '例：桶、箱、捆、扎',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _sellPrice,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textInputAction: TextInputAction.next,
                            onChanged: (_) =>
                                _clearError(ProductField.sellPrice),
                            decoration: _decoration(
                              ProductField.sellPrice,
                              label: '售价 *',
                              suffix: '元',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // 常用单位：点一下就填好；[其他 ▾] 聚焦输入框（可自由打字）。
                    // 2026-11-24：改成**紧凑一行**（dense chip + 收起点击区留白）——
                    // 旧版 14 个 chip 占掉三行，把「进价」挤出了首屏。
                    // 点击区仍是 44 高（`Q5 点击区` 用例钉着），只是视觉更紧。
                    Wrap(
                      spacing: 6,
                      runSpacing: 0,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          '常用单位：',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: theme.textTheme.bodySmall?.color,
                          ),
                        ),
                        for (final String unit
                            in _showAllUnits
                                ? _commonUnits
                                : _commonUnits.take(7))
                          ActionChip(
                            label: Text(unit),
                            labelStyle: const TextStyle(fontSize: 13),
                            // ⚠️ **不许加 `visualDensity: compact`**：它会把点击区
                            // 压到 40 高，`Q5 点击区 ≥ 44×44` 的用例当场红（实测）。
                            // 省高度的正确做法是减**数量与字号**，不是减可点面积。
                            onPressed: () {
                              _unit.text = unit;
                              _clearError(ProductField.unit);
                            },
                          ),
                        // 「更多单位」= 展开剩下的 7 个；再点收起。
                        // 它与「其他 ▾」分工：这个展开**预设**，那个去**打字**。
                        ActionChip(
                          label: Text(_showAllUnits ? '收起 ▴' : '更多单位'),
                          labelStyle: const TextStyle(fontSize: 13),
                          onPressed: () =>
                              setState(() => _showAllUnits = !_showAllUnits),
                        ),
                        ActionChip(
                          label: const Text('其他 ▾'),
                          labelStyle: const TextStyle(fontSize: 13),
                          onPressed: () => _unitFocus.requestFocus(),
                        ),
                      ],
                    ),

                    const SizedBox(height: 2),
                    // 一句话说清「单位 = 最小售卖单位」（§AJ·AI-5）。
                    // 2026-11-24：从旧版的三行长文压成一行紧凑小字（字号 12）。
                    Text(
                      '单位填最小的售卖单位（瓶 / 个 / 斤）；'
                      '按箱进的货，装箱关系写在下面的「包装说明」里。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),

                    // ================= 二、经营信息 =================
                    _sectionHeader(theme, '二、经营信息'),

                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _costPrice,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textInputAction: TextInputAction.next,
                            onChanged: (_) =>
                                _clearError(ProductField.costPrice),
                            decoration: _decoration(
                              ProductField.costPrice,
                              suffix: '元',
                              helper: '不清楚可以先留空',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _safetyStock,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) =>
                                _clearError(ProductField.safetyStock),
                            decoration: _decoration(
                              ProductField.safetyStock,
                              helper: '低于这个数量时提醒',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 条码：2026-11-24 从页尾**上移到这里**（reply.md：太靠后会被忽略）。
                    // 扫码枪=键盘设备，回车即保存；右侧图标是「用摄像头/扫码枪」的显式入口
                    //（点了聚焦输入框，扫码枪照样能打进来）。
                    TextField(
                      controller: _barcode,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _save(),
                      onChanged: _onBarcodeChanged,
                      decoration: _decoration(
                        ProductField.barcode,
                        hint: '扫描或输入条码',
                        // 有查重提示时让位（下面那块橙色提示负责说）——
                        // 两行辅助文字挤在一起反而没人看
                        helper: _barcodeNotice == null
                            ? '没有条码可以留空；有条码建议现在录入。'
                            : null,
                        suffixIcon: IconButton(
                          key: const Key('product-barcode-scan'),
                          tooltip: '扫描条码',
                          icon: const Icon(Icons.qr_code_scanner, size: 20),
                          onPressed: () => _barcodeFocus.requestFocus(),
                        ),
                      ),
                    ),

                    // ================= 三、包装信息（选填） =================
                    _sectionHeader(theme, '三、包装信息', optional: true),

                    // 「包装说明」= **纯备注**（不参与计算）；与下面的「包装换算」
                    // 是两件事 —— 旧界面把两者摆在一起，用户分不清哪个影响记账。
                    TextField(
                      controller: _packageNote,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => _clearError(ProductField.packageNote),
                      decoration: _decoration(
                        ProductField.packageNote,
                        label: '包装说明（可选）',
                        hint: '例：1 箱 = 48 瓶',
                        helper: '只是给人看的备注，不影响计算。',
                      ),
                    ),
                    const SizedBox(height: 12),
                    _packageToggle(theme),

                    // #31（2026-10-16 裁定甲）：可选「当前库存」—— 手机新建专用
                    //（`allowOpeningStock`；桌面期初有独立入口，编辑模式不显示 = 裁定③）。
                    // 只按**商品单位**填（本批不做按箱换算，见台账 §CV·四十六·deviation）；
                    // 空着 = 纯建档。
                    if (_openingStock != null) ...<Widget>[
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('product-opening-stock'),
                        controller: _openingStock,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                        onChanged: (_) {
                          if (_openingError != null) {
                            setState(() => _openingError = null);
                          }
                        },
                        decoration: InputDecoration(
                          labelText: '当前库存（选填）',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          errorText: _openingError,
                          helperText:
                              '货架上现在实际有多少（按商品单位填）—— '
                              '同步前库存页会标「期初 … 待同步」',
                        ),
                      ),
                    ],

                    // 条码重复：**内联橙色提示**，不弹窗、不打断输入（R-15 裁定）。
                    // 文案（含第二句「保存后扫码会显示…」）来自 core，界面只上色。
                    if (_barcodeNotice != null) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        _barcodeNotice!,
                        style: const TextStyle(
                          color: _noticeColor,
                          height: 1.6,
                        ),
                      ),
                    ],

                    const SizedBox(height: 12),
                    Text(
                      isNew ? '商品编码由系统自动编号，不用你填。' : '编码由系统生成，不会因为编辑而改变。',
                      style: TextStyle(
                        height: 1.6,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_moreBelow) _moreBelowHint(context),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }

  InputDecoration _decoration(
    ProductField field, {
    String? suffix,
    String? helper,
    String? hint,
    String? label,
    Widget? suffixIcon,
  }) => InputDecoration(
    labelText: label ?? field.label,
    suffixText: suffix,
    suffixIcon: suffixIcon,
    // 字段级错误直接挂在这一栏下面 —— 用户不用猜是哪一栏填错了
    errorText: _errors[field],
    helperText: helper,
    helperMaxLines: 2,
    hintText: hint,
    border: const OutlineInputBorder(),
  );

  /// 意外失败：**说「怎么办」**，而不是把异常原文丢给用户
  Widget _failureBox(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_failure!, style: TextStyle(color: color, height: 1.6)),
          ),
        ],
      ),
    );
  }
}
