/// 单位切换的**辅助说明行**（§BG 方案 A ②③ —— 销售 / 采购 / 送货三页共用）。
///
/// 判断与文案都在 core（`packageEntryHint` / `entryPriceKeptHint`，
/// 文案单一出处、`dart test` 钉得住），本文件只做「该显示哪几行」的摆放：
///
/// - 「1 箱 = 12 瓶，入库按 12 瓶记」—— **只在切到包装单位时显示**
///   （裁定 ③：不常驻，否则每行多一行字）；
/// - 「单价折算除不尽…」—— 切单位时价格没换成（除不尽、保留原值）才显示，
///   **橙色告知**（§1.3「不拦人」色），与「错误红」区分。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 返回 0～2 行说明，直接 spread 进行卡的 `Column` children。
List<Widget> entryUnitHints({
  required ThemeData theme,
  required String? baseUnit,
  required String? packageUnit,
  required int? packageSize,
  required String entryUnit,
  required bool priceKept,
}) {
  final String base = baseUnit ?? '';
  final String pkg = packageUnit ?? '';
  final bool onPackage = pkg.isNotEmpty && entryUnit == pkg;
  return <Widget>[
    if (onPackage && (packageSize ?? 0) > 0) ...<Widget>[
      const SizedBox(height: 4),
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          packageEntryHint(
            baseUnit: base,
            packageUnit: pkg,
            packageSize: packageSize!,
          ),
          style: TextStyle(
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
      ),
    ],
    if (priceKept) ...<Widget>[
      const SizedBox(height: 4),
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          entryPriceKeptHint(
            keptUnit: entryUnit.isEmpty ? base : entryUnit,
            otherUnit: onPackage ? base : pkg,
          ),
          style: const TextStyle(height: 1.6, color: Color(0xFFB45309)),
        ),
      ),
    ],
  ];
}
