/// 「这几个商品还没建档」的确认对话框（真实诉求批 ②，2026-10-25，§CV·一百零五）。
///
/// ## 为什么必须有这一步
///
/// 用户手打的名字可能是错别字，也可能本来就该建档。**不能静默建档**
/// （错字会被固化成商品），也**不能直接拒绝**（他会觉得「这软件不让我卖这个货」）。
/// 所以保存时拦一次，把名字**原样加引号**摆出来，让他自己决定。
///
/// ## 三个按钮（用户裁定 ③甲）
///
/// | 按钮 | 做什么 | 为什么要有 |
/// |---|---|---|
/// | **先建档再保存**（默认） | 按单子上的名字 + 单价建档，然后落单，一步完成 | 高频路径，回车即走 |
/// | 去商品页填详细信息 | 打开商品表单（**名字预填**），本单不保存 | 想认真填包装单位的人的后路 |
/// | 取消 | 什么都不做，回到表单 | **不关页面、不丢输入** |
///
/// ⚠️ **一次保存里有多个缺档行 ⇒ 一个对话框列全**，不要弹三次。
library;

import 'package:flutter/material.dart';

/// 用户在对话框里的选择。
enum MissingProductChoice {
  /// 先建档再保存（默认动作）
  createAndSave,

  /// 去商品表单填详细信息（本单不保存）
  openForm,

  /// 取消（回表单，什么都不动）
  cancel,
}

/// 弹出确认框。返回 `null` 等价于 [MissingProductChoice.cancel]（点遮罩 / 返回键）。
Future<MissingProductChoice> showMissingProductDialog(
  BuildContext context, {
  required List<String> names,
}) async {
  final MissingProductChoice? choice = await showDialog<MissingProductChoice>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      key: const Key('missing-product-dialog'),
      title: Text(
        names.length == 1
            ? '「${names.first}」还没建档'
            : '这 ${names.length} 个商品还没建档',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (names.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final String name in names)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('· $name'),
                    ),
                ],
              ),
            ),
          const Text(
            '选「先建档再保存」，会按单子上的名字和单价建好档案，然后直接保存这一单。',
            style: TextStyle(height: 1.5),
          ),
          const SizedBox(height: 8),
          const Text(
            '单位默认「件」，价格先按这一单填的记 —— 以后可以到商品页改。',
            style: TextStyle(height: 1.5),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('missing-product-cancel'),
          onPressed: () =>
              Navigator.of(dialogContext).pop(MissingProductChoice.cancel),
          child: const Text('取消'),
        ),
        TextButton(
          key: const Key('missing-product-open-form'),
          onPressed: () =>
              Navigator.of(dialogContext).pop(MissingProductChoice.openForm),
          child: const Text('去填详细信息'),
        ),
        FilledButton(
          key: const Key('missing-product-create'),
          onPressed: () => Navigator.of(
            dialogContext,
          ).pop(MissingProductChoice.createAndSave),
          child: const Text('先建档再保存'),
        ),
      ],
    ),
  );
  return choice ?? MissingProductChoice.cancel;
}
