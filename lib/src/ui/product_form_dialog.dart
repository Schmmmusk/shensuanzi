/// 商品建档表单（`docs/reply.md` 裁定的 6 个字段）。
///
/// ```text
/// 商品名称   [                                ]
/// 单位 [ 件 ]        售价 [        ] 元
///           件 个 斤 箱 包 瓶        ← 点一下即填
/// 进价 [      ] 元   安全库存 [     ]
/// 条码       [                                ]   ← 扫码枪扫完回车即保存
/// ```
///
/// ## 校验不在这里
///
/// 校验与取值全在 `ProductDraft`（纯 Dart、`dart test` 覆盖）。
/// 本文件只负责：**摆放输入框**、**把错误标到对应那一栏**、调服务保存。
///
/// 金额输入框一律 `numberWithOptions(decimal: true)` —— 中老年用户做零售时
/// 输入数量与金额是最高频动作，默认弹出字母键盘等于每次都要多切一次
/// （`docs/ui_principles.md` §四）。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 常用单位。**不是白名单** —— 单位仍是自由文本，这只是「顺手就能点」的快捷方式。
const List<String> _commonUnits = <String>['件', '个', '斤', '箱', '包', '瓶'];

Future<Product?> showProductFormDialog(
  BuildContext context, {
  required ProductService service,
  Product? existing,
}) => showDialog<Product>(
  context: context,
  builder: (BuildContext dialogContext) =>
      _ProductFormDialog(service: service, existing: existing),
);

class _ProductFormDialog extends StatefulWidget {
  const _ProductFormDialog({required this.service, this.existing});

  final ProductService service;

  /// `null` = 新增；非 null = 编辑
  final Product? existing;

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

  /// 字段级错误（界面标红哪一栏就看它）
  Map<ProductField, String> _errors = <ProductField, String>{};

  /// 服务层抛出的意外错误（说「怎么办」）
  String? _failure;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final ProductDraft draft = widget.existing == null
        ? const ProductDraft()
        : ProductDraft.of(widget.existing!);
    _name = TextEditingController(text: draft.name);
    _unit = TextEditingController(text: draft.unit);
    _sellPrice = TextEditingController(text: draft.sellPrice);
    _costPrice = TextEditingController(text: draft.costPrice);
    _barcode = TextEditingController(text: draft.barcode);
    _safetyStock = TextEditingController(text: draft.safetyStock);
  }

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _sellPrice.dispose();
    _costPrice.dispose();
    _barcode.dispose();
    _safetyStock.dispose();
    super.dispose();
  }

  ProductDraft get _draft => ProductDraft(
    name: _name.text,
    unit: _unit.text,
    sellPrice: _sellPrice.text,
    costPrice: _costPrice.text,
    barcode: _barcode.text,
    safetyStock: _safetyStock.text,
  );

  /// 用户一改这个字段就把它那条错误清掉 —— 边改边消，而不是等再点一次保存
  void _clearError(ProductField field) {
    if (!_errors.containsKey(field)) return;
    setState(() => _errors = Map<ProductField, String>.from(_errors)..remove(field));
  }

  Future<void> _save() async {
    final ProductDraft draft = _draft;

    final Map<ProductField, String> errors = draft.validate();
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }

    setState(() {
      _saving = true;
      _failure = null;
    });

    try {
      final Product saved = widget.existing == null
          ? widget.service.create(draft)
          : widget.service.update(widget.existing!.id, draft);
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } on ProductDraftInvalid catch (error) {
      // 服务层又校验了一遍（它不假设调用方校验过）—— 把结论标回界面
      setState(() {
        _errors = error.errors;
        _saving = false;
      });
    } catch (error) {
      setState(() {
        _failure = '没能保存（$error）。'
            '先关掉这个窗口再试一次；如果一直这样，请把这句话告诉技术支持。';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isNew = widget.existing == null;

    return AlertDialog(
      title: Text(isNew ? '新增商品' : '编辑商品'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (_failure != null) ...<Widget>[
                _failureBox(context),
                const SizedBox(height: 12),
              ],

              // 名称独占一行（最长、最重要）
              TextField(
                controller: _name,
                textInputAction: TextInputAction.next,
                onChanged: (_) => _clearError(ProductField.name),
                decoration: _decoration(ProductField.name),
              ),
              const SizedBox(height: 16),

              // 单位（短的放左边）
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _unit,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => _clearError(ProductField.unit),
                      decoration: _decoration(ProductField.unit),
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
                      onChanged: (_) => _clearError(ProductField.sellPrice),
                      decoration: _decoration(
                        ProductField.sellPrice,
                        suffix: '元',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 常用单位：点一下就填好，不用敲字
              Wrap(
                spacing: 8,
                children: <Widget>[
                  for (final String unit in _commonUnits)
                    ActionChip(
                      label: Text(unit),
                      onPressed: () {
                        _unit.text = unit;
                        _clearError(ProductField.unit);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),

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
                      onChanged: (_) => _clearError(ProductField.costPrice),
                      decoration: _decoration(
                        ProductField.costPrice,
                        suffix: '元',
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _safetyStock,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => _clearError(ProductField.safetyStock),
                      decoration: _decoration(ProductField.safetyStock),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 条码独占一行：可能很长，且要接扫码枪
              TextField(
                controller: _barcode,
                // 扫码枪通常在末尾带回车 —— 回车即保存，一次扫码完成建档
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                onChanged: (_) => _clearError(ProductField.barcode),
                decoration: _decoration(
                  ProductField.barcode,
                  helper: '没有条码可以先空着。有条码的话，扫一下会自动保存。',
                ),
              ),

              const SizedBox(height: 12),
              Text(
                isNew
                    ? '商品编码由系统自动编号，不用你填。'
                    : '编码由系统生成，不会因为编辑而改变。',
                style: TextStyle(
                  height: 1.6,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ],
          ),
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
  }) => InputDecoration(
    labelText: field.label,
    suffixText: suffix,
    // 字段级错误直接挂在这一栏下面 —— 用户不用猜是哪一栏填错了
    errorText: _errors[field],
    helperText: helper,
    helperMaxLines: 2,
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
            child: Text(
              _failure!,
              style: TextStyle(color: color, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}
