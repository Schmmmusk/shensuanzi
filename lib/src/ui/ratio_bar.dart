import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 按比例画的一条横条（欠款 / 压货 / 月度对比三处共用）。
///
/// ## 为什么抽出来
///
/// 「比例至少留 4%」这个错误在本仓犯过**两次**：先写在欠款横条上，
/// 改完之后压货榜又照抄了一遍（用户审查 2026-10-30 第四轮）。同构代码
/// 各写一份，就一定会有一份没跟上 —— 这是纪律 18 说的那种漏改。
///
/// ## 两条口径（都写在这里，不再散落）
///
/// 1. **比例照实算**：`cents / maxCents`，不抬下限。
///    抬到 4% 会让 ¥10 对 ¥10,000 显示成 25:1，而真实是 1000:1 ——
///    图会暗示一个不存在的比例。
/// 2. **只保证最小 4 像素**：¥1 对 ¥10,000 按比例不到 0.1px，画不出来。
///    给 4px 是「让它可见」，不是「让它看起来占 4%」。
class RatioBar extends StatelessWidget {
  const RatioBar({
    super.key,
    required this.cents,
    required this.maxCents,
    required this.color,
    this.height = 12,
    this.barKey,
  });

  /// 本条代表的金额（分）
  final int cents;

  /// 同一组里的最大值（分）—— 比例的分母
  final int maxCents;

  final Color color;
  final double height;

  /// 给**填充条**用的 key（测试靠它量宽度）
  final Key? barKey;

  /// 轨道色（没填满的那一段）。
  ///
  /// ⚠️ **不能用 `theme.dividerColor`**（2026-10-31 真机实测）：本主题里它是
  /// `#73777F` 的中灰，跟填充色（深蓝 `#34618D`）**几乎一样深** ——
  /// 整条看起来都像填满了，用户根本分不出条有多长。
  ///
  /// 用 M3 的 `surfaceContainerHighest`（浅中性灰）：与任何强调色都拉开距离，
  /// 且三张卡（欠款 / 压货 / 月度对比）共用同一条轨道色。
  static Color trackColorOf(ThemeData theme) =>
      theme.colorScheme.surfaceContainerHighest;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double ratio = maxCents <= 0 ? 0 : (cents / maxCents).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = math.max(c.maxWidth * ratio, 4);
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            children: <Widget>[
              Container(height: height, color: trackColorOf(theme)),
              SizedBox(
                key: barKey,
                width: width,
                child: Container(height: height, color: color),
              ),
            ],
          ),
        );
      },
    );
  }
}
