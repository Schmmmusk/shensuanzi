/// 商品名称**自动补全**（三个开单页共用）。
///
/// 落地依据：`docs/proposals/商品名称自动补全-方案.md`（2026-10-25 裁定
/// `D1′乙` 前缀豁免 · `D2′甲` 只做桌面 + 手机选择器加搜索）。
///
/// ## 为什么单独一个文件
///
/// 三个开单页的行卡是**同构代码**（基本逐字复制）。补全逻辑若各写一份，
/// 迟早漂移（`Agents.md` 纪律 18 的高发区）。所以：
/// **匹配与排序只有这一个定义**，三页各接一次组件。
///
/// ## 这一版只做桌面
///
/// 手机的行卡是「点此选商品」单元格（`QueueSink.canCreateProducts == false`）——
/// 放开手打就得先让「无匹配 ⇒ 建档」能进队列，否则是假承诺（裁定 `D2′甲`）。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'product_form_dialog.dart';

/// 一条候选的**匹配强度**（数字越小越靠前）。
enum ProductMatchKind {
  /// 名称完全相同（忽略大小写与首尾空白）—— 用户已经把名字打全了
  exact,

  /// 名称以输入开头 —— 「正在搜索」的典型形态
  prefix,

  /// 名称中间包含
  contains,

  /// 编码 / 条码命中（用户拿扫码枪或背编码时走这条）
  code,
}

/// 按「完全匹配 → 前缀 → 包含 → 编码/条码」排序，同分按 `code` 升序（稳定）。
///
/// ## 规则（与提案 §三 逐条对应）
///
/// | 优先级 | 规则 |
/// |---|---|
/// | 1 | 名称完全相同（`trim` + 忽略大小写） |
/// | 2 | 名称前缀 |
/// | 3 | 名称包含 |
/// | 4 | 编码 / 条码命中（相等或前缀） |
///
/// **停用商品**默认不出现；但输入的是它的**完整名称**时仍然给出 ——
/// 与 `ProductBackfill.findByExactName`（不过滤 `is_active`）保持一致，
/// 否则用户会以为「这个商品不存在」，反手建一个重名的。
///
/// **空输入返回空**（一进页面就糊一屏候选是很糟的体验）。
///
/// ⚠️ 纯函数：不碰数据库、不 setState —— 所以能直接单测，也能在 `build` 里安全调用。
List<Product> rankProductMatches(
  String rawQuery,
  List<Product> products, {
  int limit = 8,
}) {
  final String query = rawQuery.trim().toLowerCase();
  if (query.isEmpty) return const <Product>[];

  final List<_Ranked> ranked = <_Ranked>[];
  for (final Product product in products) {
    final String name = product.name.trim().toLowerCase();
    final String code = product.code.trim().toLowerCase();
    final String? barcode = product.barcode?.trim().toLowerCase();

    ProductMatchKind? kind;
    if (name == query) {
      kind = ProductMatchKind.exact;
    } else if (name.startsWith(query)) {
      kind = ProductMatchKind.prefix;
    } else if (name.contains(query)) {
      kind = ProductMatchKind.contains;
    } else if (code == query ||
        code.startsWith(query) ||
        (barcode != null && barcode.isNotEmpty && barcode.startsWith(query))) {
      kind = ProductMatchKind.code;
    }
    if (kind == null) continue;

    // 停用商品：只有「输入的就是它的完整名称」才放行（见上面的说明）
    if (!product.isActive && kind != ProductMatchKind.exact) continue;

    ranked.add(_Ranked(product, kind));
  }

  ranked.sort((_Ranked a, _Ranked b) {
    final int byKind = a.kind.index.compareTo(b.kind.index);
    if (byKind != 0) return byKind;
    // 同分按 code 升序 —— 稳定排序，避免每次按键候选顺序抖动
    return a.product.code.compareTo(b.product.code);
  });

  return <Product>[for (final _Ranked item in ranked.take(limit)) item.product];
}

class _Ranked {
  const _Ranked(this.product, this.kind);

  final Product product;
  final ProductMatchKind kind;
}

/// 候选副标题（「内容视所处页面而定」—— 提案 §三）。
///
/// - 采购看**进价**（这一单要付多少）
/// - 销售 / 送货看**售价**（这一单收多少）
///
/// 停用商品加「（已停用）」—— 用户选中它会得到一条不能卖的商品，
/// 必须在他按回车之前就看见。
String productCandidateSubtitle(Product product, {required bool forPurchase}) {
  final String price = forPurchase
      ? '进价 ¥${Money.format(product.costPrice)}'
      : '售价 ¥${Money.format(product.sellPrice)}';
  final String suffix = product.isActive ? '' : ' · （已停用）';
  return '${product.code} · $price$suffix';
}

/// 商品名输入框 + 候选浮层（**三个开单页共用**）。
///
/// 用法：把行卡里原来的 `TextField(...)` 整个换成它，参数一一对应 ——
/// 外观、`suffixIcon` 列表按钮、错误文案、`textInputAction` 全部保持原样。
///
/// ## 三条不能破的规矩
///
/// 1. **不查库**：`products` 由页面在打开时取一次传进来（`list(active: null)` 之外
///    的筛选都在内存里做）。每次按键查一次库就是商品页那个 2.7 秒的老路。
/// 2. **中文输入法组合期不更新候选**：拼音还没上屏时重建候选会打断 IME
///    （`value.composing.isValid` 时直接返回空）。
/// 3. **回车两种语义**：浮层开着 ⇒ `RawAutocomplete` 自己吃掉回车去选中；
///    浮层关着 ⇒ 走 `onSubmitted`（跳下一格，保留原来的录入节奏）。
class ProductNameAutocomplete extends StatefulWidget {
  const ProductNameAutocomplete({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.products,
    required this.forPurchase,
    required this.onPicked,
    required this.onChangedText,
    required this.onPickPressed,
    this.onCreateRequested,
    this.pickerKey,
    this.errorText,
    this.hintText = '输入或选商品',
  });

  /// 输入框自己的 Key（三页各一个，测试用）
  final Key fieldKey;
  final TextEditingController controller;

  /// ⚠️ 必须由**行卡持有**并 dispose —— 每个输入框一个，不能共用
  final FocusNode focusNode;
  final bool enabled;

  /// 页面打开时取一次的商品表（**不要**每次按键去查）
  final List<Product> products;

  /// 采购页显示进价，销售/送货显示售价
  final bool forPurchase;

  /// 选中候选：页面负责绑定商品、重算、触发覆盖确认。
  ///
  /// `typedBefore` = **选中之前**输入框里的字（覆盖确认要靠它判「是不是正在搜」）。
  final void Function(Product product, {required String typedBefore}) onPicked;

  /// 用户改字：页面负责 `row.setName(text)` + 解绑
  final ValueChanged<String> onChangedText;

  /// 右侧列表按钮（原 `suffixIcon`）
  final VoidCallback onPickPressed;

  /// **回车且名字在库里找不到**时回调（提案 §四·B / 诉求 6）。
  ///
  /// `null` = 这个页面不提供「立刻建档」（手机 `QueueSink` 就是这种情况）。
  final ValueChanged<String>? onCreateRequested;
  final Key? pickerKey;

  final String? errorText;
  final String hintText;

  @override
  State<ProductNameAutocomplete> createState() =>
      _ProductNameAutocompleteState();
}

class _ProductNameAutocompleteState extends State<ProductNameAutocomplete> {
  /// **选中之前**输入框里的文字。
  ///
  /// ⚠️ 不能等到 `onSelected` 里再读 `controller.text` —— `RawAutocomplete`
  /// 是**先把输入框改成候选名、再回调** `onSelected`（Flutter 源码
  /// `_RawAutocompleteState._select`）。直接读会永远等于候选名，
  /// 于是「前缀豁免」判定恒为真 ⇒ 覆盖确认**永远不会弹**
  /// （2026-10-29 实测：那条测试就是这么红的）。
  String _lastTyped = '';

  @override
  void initState() {
    super.initState();
    _lastTyped = widget.controller.text;
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<Product>(
      textEditingController: widget.controller,
      focusNode: widget.focusNode,
      displayStringForOption: (Product product) => product.name,
      optionsBuilder: (TextEditingValue value) {
        // 组合期（拼音未上屏）不更新候选 —— 见类注释第 2 条
        if (value.composing.isValid) return const <Product>[];
        return rankProductMatches(value.text, widget.products);
      },
      onSelected: (Product product) {
        final String typedBefore = _lastTyped;
        // 选完之后输入框会变成候选名 —— 同步一下，否则下一次选中
        // 还会拿着更早的字去判前缀
        _lastTyped = product.name;
        widget.onPicked(product, typedBefore: typedBefore);
      },
      fieldViewBuilder:
          (
            BuildContext context,
            TextEditingController fieldController,
            FocusNode fieldFocusNode,
            VoidCallback onFieldSubmitted,
          ) {
            return TextField(
              key: widget.fieldKey,
              controller: fieldController,
              focusNode: fieldFocusNode,
              enabled: widget.enabled,
              textInputAction: TextInputAction.next,
              onSubmitted: (String _) {
                final String typed = fieldController.text.trim();
                // 名字已经在库里（精确匹配）⇒ 回车就是「往下走」，别打扰
                final bool known = widget.products.any(
                  (Product p) =>
                      p.name.trim().toLowerCase() == typed.toLowerCase(),
                );
                if (typed.isNotEmpty &&
                    !known &&
                    widget.onCreateRequested != null) {
                  widget.onCreateRequested!(typed);
                  return;
                }
                FocusScope.of(context).nextFocus();
              },
              onChanged: (String text) {
                _lastTyped = text;
                widget.onChangedText(text);
              },
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                isDense: true,
                hintText: widget.hintText,
                errorText: widget.errorText,
                suffixIcon: IconButton(
                  key: widget.pickerKey,
                  tooltip: '从商品列表选',
                  onPressed: widget.enabled ? widget.onPickPressed : null,
                  icon: const Icon(Icons.list_alt_outlined, size: 20),
                ),
              ),
            );
          },
      optionsViewBuilder:
          (
            BuildContext context,
            AutocompleteOnSelected<Product> onSelected,
            Iterable<Product> options,
          ) {
            final List<Product> list = options.toList(growable: false);
            if (list.isEmpty) return const SizedBox.shrink();
            final ThemeData theme = Theme.of(context);
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  // 8 条上限（提案 §三）；高度也跟着封顶，避免糊满整屏
                  constraints: const BoxConstraints(
                    maxHeight: 8 * 56.0,
                    maxWidth: 420,
                  ),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Product product = list[index];
                      return InkWell(
                        key: ValueKey<String>('product-option-${product.id}'),
                        onTap: () => onSelected(product),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                product.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium,
                              ),
                              Text(
                                productCandidateSubtitle(
                                  product,
                                  forPurchase: widget.forPurchase,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.hintColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
          },
    );
  }
}

/// 输入了一个「库里没有」的商品名 ⇒ 问要不要**现在建档**（提案 §四·B / 诉求 6）。
///
/// 返回建好的商品；用户选「先不建」或取消建档 ⇒ `null`（该行保持「只有名字」，
/// 保存时仍由 `missing_product_dialog` 兜底 —— **两条路互不替代**）。
///
/// ## 为什么只有「回车」触发，没有做「失焦」触发
///
/// 提案里写了「回车**或失焦**」，但失焦的时机太多：点保存、点下一个输入框、
/// 点合计、切窗口……每一种都会弹一次「没找到，现在建吗？」，比原来的问题更烦。
/// 回车是用户**明确表示「这个名字我打完了」**的唯一动作，所以只认它。
/// （这一条偏离提案字面，理由记在这里，不是漏做。）
Future<Product?> offerCreateMissingProduct(
  BuildContext context, {
  required String typedName,
  required ProductService service,
  required MasterDataSink sink,
  bool allowOpeningStock = false,
}) async {
  final String name = typedName.trim();
  if (name.isEmpty) return null;

  final bool? go = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('没找到这个商品'),
      content: Text('「$name」还不在商品档案里，现在建一个吗？'),
      actions: <Widget>[
        TextButton(
          key: const Key('missing-product-later'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('先不建'),
        ),
        FilledButton(
          key: const Key('missing-product-create'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('建档'),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return null;

  // 复用**无缝建档**：名字预填进去，其余字段用户在对话框里补
  return showProductFormDialog(
    context,
    service: service,
    sink: sink,
    initialName: name,
    allowOpeningStock: allowOpeningStock,
  );
}
