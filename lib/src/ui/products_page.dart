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
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'product_form_dialog.dart';

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key, required this.service});

  /// `null` = 数据库没打开成功（启动时选的位置有问题）
  final ProductService? service;

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

  List<Product> get _rows => _service.list(
    query: _search.text.trim().isEmpty ? null : _search.text.trim(),
    active: _showInactive ? null : true,
  );

  Future<void> _create() async {
    final Product? saved = await showProductFormDialog(
      context,
      service: _service,
    );
    if (!mounted || saved == null) return;
    _announce('已保存，编码 ${saved.code}');
    setState(() {});
  }

  Future<void> _edit(Product product) async {
    final Product? saved = await showProductFormDialog(
      context,
      service: _service,
      existing: product,
    );
    if (!mounted || saved == null) return;
    _announce('已保存，编码 ${saved.code}');
    setState(() {});
  }

  /// 停用 / 恢复，并给一次**撤销**机会
  void _toggleActive(Product product) {
    final bool wasActive = product.isActive;
    _service.setActive(product.id, !wasActive);
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
            _service.setActive(product.id, wasActive);
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
                  decoration: const InputDecoration(
                    labelText: '搜商品',
                    hintText: '商品名 / 编码 / 条码',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 16),
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
              ? const _Empty()
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (BuildContext context, int index) =>
                      const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) =>
                      _ProductRow(
                        product: rows[index],
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
    required this.onEdit,
    required this.onToggleActive,
  });

  final Product product;
  final ValueChanged<Product> onEdit;
  final ValueChanged<Product> onToggleActive;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String subtitle = <String>[
      product.code,
      if (product.barcode != null) '条码 ${product.barcode}',
      product.unit,
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
              ],
            ),
          ),
          const SizedBox(width: 16),
          _priceColumn(theme, '售价', product.sellPrice),
          const SizedBox(width: 16),
          _priceColumn(theme, '进价', product.costPrice),
          const SizedBox(width: 24),
          TextButton(
            onPressed: () => onEdit(product),
            child: const Text('编辑'),
          ),
          TextButton(
            onPressed: () => onToggleActive(product),
            child: Text(product.isActive ? '停用' : '恢复'),
          ),
        ],
      ),
    );
  }

  Widget _priceColumn(ThemeData theme, String label, int cents) => SizedBox(
    width: 96,
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

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          Icons.inventory_2_outlined,
          size: 40,
          color: Theme.of(context).textTheme.bodySmall?.color,
        ),
        const SizedBox(height: 12),
        const Text('还没有商品', style: TextStyle(height: 1.6)),
        const SizedBox(height: 8),
        Text(
          '点上面的「新增商品」把店里卖的东西录进来。',
          style: TextStyle(
            height: 1.6,
            color: Theme.of(context).textTheme.bodySmall?.color,
          ),
        ),
      ],
    ),
  );
}

/// 数据库没打开成功时的兜底（与概览页同一套说法）
class _NotReady extends StatelessWidget {
  const _NotReady();

  @override
  Widget build(BuildContext context) => const Center(
    child: Text('数据文件还没就绪，请先到设置里选好存放位置。', textAlign: TextAlign.center),
  );
}
