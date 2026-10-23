/// 商品建档列表（`docs/reply.md` 第 2–3 天）。
///
/// ## 界面原则的落点
///
/// - **搜索框 + 「新增商品」常驻可见**：不用图标按钮，也不用悬浮
/// - 行操作是**文字按钮**「编辑」「停用」，不是只有图标的菜单
/// - 停用是**可撤销**的：SnackBar 上带「撤销」，比弹二次确认更友好
///   （`docs/ui_principles.md` §1.2「允许撤销，给『我错了也能补救』的信心」）
/// - 保存成功后明确告诉用户**发生了什么**（「已保存，编码 P0007」）
///
/// ## 判断都不在这里
///
/// 校验、取值、编码生成、事务全在 `shensuanzi_core`（`ProductDraft` /
/// `ProductService`，`dart test` 覆盖）。本文件只摆放与调用。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'scaled.dart';

import 'export_button.dart';
import 'list_scaffold.dart';
import 'product_form_dialog.dart';

class ProductsPage extends StatefulWidget {
  const ProductsPage({
    super.key,
    required this.service,
    this.exports,
    this.pendingMarks,
  });

  /// `null` = 数据库没打开成功（启动时选的位置有问题）
  final ProductService? service;

  /// 导出服务（`null` = 不显示导出按钮）
  final ExportSink? exports;

  /// **主机还没确认**的主数据行（D2b —— `data_model.md §4.4` 第 3 条）。
  /// `null` = 一律不显示「待同步」小字（桌面 / 测试默认）。
  final PendingMarks? pendingMarks;

  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  final TextEditingController _search = TextEditingController();

  /// 默认只看启用中的；勾上之后连已停用的一起显示
  bool _showInactive = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  ProductService get _service => widget.service!;

  /// 主数据提交出口。**本页是桌面专用**（`products` 不在手机 tab 里，
  /// `mobile_shell.dart` 的 tab 是 overview / stock / parties / billing / mine）
  /// ⇒ 出口恒为**主机落库** `ServiceMasterSink`（§CV·七 ① 乙）。
  /// 全部主数据写（建档 / 编辑 / 停用）都走它，与「一处出口」的纪律一致。
  MasterDataSink get _masterDataSink => ServiceMasterSink(_service);

  List<Product> get _rows => _service.list(
    query: _search.text.trim().isEmpty ? null : _search.text.trim(),
    active: _showInactive ? null : true,
  );

  Future<void> _create() async {
    final Product? saved = await showProductFormDialog(
      context,
      service: _service,
      sink: _masterDataSink,
    );
    if (!mounted || saved == null) return;
    _announce('已保存，编码 ${saved.code}');
    setState(() {});
  }

  Future<void> _edit(Product product) async {
    final Product? saved = await showProductFormDialog(
      context,
      service: _service,
      sink: _masterDataSink,
      existing: product,
    );
    if (!mounted || saved == null) return;
    _announce('已保存，编码 ${saved.code}');
    setState(() {});
  }

  /// 停用 / 恢复，并给一次**撤销**机会
  void _toggleActive(Product product) {
    final bool wasActive = product.isActive;
    _masterDataSink.setProductActive(product.id, !wasActive);
    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          wasActive ? '已停用「${product.name}」' : '已恢复「${product.name}」',
        ),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            if (!mounted) return;
            _masterDataSink.setProductActive(product.id, wasActive);
            setState(() {});
          },
        ),
      ),
    );
  }

  void _announce(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.service == null) {
      return const _NotReady();
    }

    final ThemeData theme = Theme.of(context);
    final List<Product> rows = _rows;
    // ⚠️ 一次 build 取一次快照，再逐行 contains —— `ids` 每次访问都查库
    final Set<String> pending = widget.pendingMarks?.ids ?? const <String>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: '搜商品',
                    hintText: '商品名 / 编码 / 条码',
                    prefixIcon: const Icon(Icons.search),
                    // 2026-10-21：加「清空」—— 报告 §2.5「清空搜索全仓只有单据页有」
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            key: const Key('products-clear-search'),
                            tooltip: '清空',
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _search.clear();
                              setState(() {});
                            },
                          ),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              if (widget.exports != null)
                ExportButton(
                  key: const Key('export-products'),
                  // AF-2：按钮文案说清导的是**全部商品（含停用）** ——
                  // 刻意**不看搜索框**，否则用户以为导的是搜出来的那几条
                  label: '导出全部商品',
                  export: () => widget.exports!.write(
                    productExportTable(widget.service!.listForExport()),
                  ),
                ),
              // 常驻可见的文字按钮（不是图标按钮）
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add),
                label: const Text('新增商品'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              Checkbox(
                value: _showInactive,
                onChanged: (bool? value) =>
                    setState(() => _showInactive = value ?? false),
              ),
              // 文字标签必须在（中老年用户不看纯图标）
              const Text('显示已停用的商品'),
              const Spacer(),
              // 批 3 第 16 条：**真实总数**（商品页无分页，rows 就是全量）
              Text(
                '共 ${rows.length} 种',
                style: TextStyle(
                  height: 1.6,
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: rows.isEmpty
              ? _Empty(query: _search.text.trim())
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (BuildContext context, int index) =>
                      const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) => _ProductRow(
                    product: rows[index],
                    isPending: pending.contains(rows[index].id),
                    onEdit: _edit,
                    onToggleActive: _toggleActive,
                  ),
                ),
        ),
      ],
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({
    required this.product,
    required this.isPending,
    required this.onEdit,
    required this.onToggleActive,
  });

  final Product product;

  /// 主机还没确认（乐观行）⇒ 名下列一行浅灰「待同步」
  final bool isPending;

  final ValueChanged<Product> onEdit;
  final ValueChanged<Product> onToggleActive;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String subtitle = <String>[
      product.code,
      if (product.barcode != null) '条码 ${product.barcode}',
      // 「单位：个」而不是裸「个」—— 裸单位容易让人以为是别的字段
      // （用户真机反馈 2026-09-28）；unit 理论上可空，判空兜底
      if (product.unit.trim().isNotEmpty) '单位：${product.unit.trim()}',
    ].join('  ·  ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        product.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    if (!product.isActive) ...<Widget>[
                      const SizedBox(width: 8),
                      Text(
                        '（已停用）',
                        style: TextStyle(
                          height: 1.6,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
                // 乐观行必须可分辨（`data_model.md §4.4` 第 3 条）：
                // 「我有的」与「主机确认的」一眼可分 —— 否则乐观写就是一句谎话
                if (isPending) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    '待同步',
                    key: Key('pending-product-${product.id}'),
                    style: TextStyle(height: 1.6, color: theme.hintColor),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          _priceColumn(context, theme, '售价', product.sellPrice),
          const SizedBox(width: 16),
          _priceColumn(context, theme, '进价', product.costPrice),
          const SizedBox(width: 24),
          TextButton(onPressed: () => onEdit(product), child: const Text('编辑')),
          TextButton(
            onPressed: () => onToggleActive(product),
            child: Text(product.isActive ? '停用' : '恢复'),
          ),
        ],
      ),
    );
  }

  Widget _priceColumn(
    BuildContext context,
    ThemeData theme,
    String label,
    int cents,
  ) => SizedBox(
    // 批 3 第 13 条：金额列宽随缩放派生，否则 2.0 下数字被挤到换行
    width: scaledOf(context, amountColumnBase),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
        Text('¥${Money.format(cents)}', style: const TextStyle(height: 1.6)),
      ],
    ),
  );
}

/// 商品页空态 —— 换成共用 `ListEmptyState`（批 3 第 16 条）。
///
/// 「搜不到」与「空库」必须说两种话（§CV·八十，报告 §2.2 漂移 1）：
/// 店里 80 种商品、只是搜错了，却提示「还没有商品」会让用户去重复建档。
class _Empty extends StatelessWidget {
  const _Empty({this.query = ''});

  /// 搜索框里的词（空 = 真的一个商品都没有）
  final String query;

  @override
  Widget build(BuildContext context) {
    final bool searching = query.isNotEmpty;
    return ListEmptyState(
      icon: searching ? Icons.search_off : Icons.inventory_2_outlined,
      title: searching ? '没有找到「$query」' : '还没有商品',
      hint: searching
          ? '换个词试试，或点搜索框右边的 × 清空，看全部商品。'
          : '点上面的「新增商品」把店里卖的东西录进来。',
    );
  }
}

/// 数据库没打开成功时的兜底（与概览页同一套说法）
class _NotReady extends StatelessWidget {
  const _NotReady();

  @override
  Widget build(BuildContext context) => const Center(
    child: Text('数据文件还没就绪，请先到设置里选好存放位置。', textAlign: TextAlign.center),
  );
}
