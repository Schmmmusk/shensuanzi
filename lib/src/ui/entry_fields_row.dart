/// 明细行「数量 / 单价 / 小计」的**响应式摆放**（M10，2026-10-08）。
///
/// 销售 / 采购 / 送货三页的行卡共用这一份 —— 三处各写一份必然漂
/// （purchase 的 chips 就是漂的例子，见 `Agents.md` §二 纪律 5）。
///
/// - **宽屏**：并排 —— 左数量、中单价（占 2 份）、右小计（固定 96）——
///   与改动前**像素级一致**（桌面零变化）。
/// - **窄屏 / 超大字号**：**上下堆叠** —— 数量、单价各占满宽，小计另起一行
///   右对齐。否则单价框放不下「单价（元/箱）」这个 label，被系统截成省略号
///   （真机 M10 实测）。
///
/// 判据在 `shensuanzi_app` 的 `entryFieldsShouldStack`（**纯 Dart，`dart test`
/// 钉得住**）—— 本文件只做摆放，不自己算阈值。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

class EntryFieldsRow extends StatelessWidget {
  const EntryFieldsRow({
    super.key,
    required this.quantityField,
    required this.priceField,
    required this.amount,
  });

  /// 数量框（调用方给，Key / 校验 / 控制器都由调用方持有）
  final Widget quantityField;

  /// 单价框
  final Widget priceField;

  /// 小计（一行文字，由调用方格式化）
  final Widget amount;

  /// 并排时小计的固定宽度 —— 与改动前一致（96）
  static const double amountWidth = 96;

  @override
  Widget build(BuildContext context) {
    // 字号倍数：`scale(14) / 14` 反推 —— 对 `TextScaler.linear` 与系统的
    // 非线性缩放都成立（比已废弃的 `textScaleFactor` 稳妥）。
    final double textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool stack = entryFieldsShouldStack(
          maxWidth: constraints.maxWidth,
          textScale: textScale,
        );
        if (!stack) {
          return Row(
            children: <Widget>[
              Expanded(child: quantityField),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: priceField),
              const SizedBox(width: 12),
              SizedBox(width: amountWidth, child: amount),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            quantityField,
            const SizedBox(height: 8),
            priceField,
            const SizedBox(height: 6),
            Align(alignment: Alignment.centerRight, child: amount),
          ],
        );
      },
    );
  }
}
