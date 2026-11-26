/// 开单三页的**标题行**（2026-11-26，提案 §1.3）。
///
/// ## 为什么需要
///
/// 三个开单页在沉浸模式下（壳层不显示面包屑）**页面内没有任何标题**——
/// 用户开单前无法确认"我在开哪一种单"。而这恰恰是最需要标题的三页：
/// 销售 / 采购 / 送货的录入区长得几乎一样，唯一的区别是价格口径与提交后的流向。
///
/// ## 为什么共用一份
///
/// 三页同构（纪律 18）。三处各写一份 `Text(..., titleLarge)` 看起来无害，
/// 但字号 / 粗细 / 边距一旦分叉，用户会以为这是三个不同的东西。
/// 用同一个组件 + `page_isomorphism_test` 的一条 pin，改一处三页一起变。
///
/// ## 尺寸的取舍
///
/// 标题吃掉约 **36 px** 垂直空间（titleLarge + 8 底部间距）。开单页是
/// "一屏塞满输入框"的布局，加标题必然挤掉一点 —— 因此：
/// - **不加 AppBar**（那会吃掉 56 px 且多一条标题栏）；
/// - 标题**居中**、与内容同列，不额外占横向空间；
/// - 窄屏 / 大字号下由各页自己的滚动容器兜底（三页都有极窄护栏用例）。
library;

import 'package:flutter/material.dart';

/// 一行居中加粗的页面标题。文案由调用方给（三页各自不同）。
class EntryPageTitle extends StatelessWidget {
  const EntryPageTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    // 父级是 `crossAxisAlignment: stretch` 的 Column ⇒ 本组件拿满宽，
    // `textAlign` 才真的能居中（不是靠 Align 包一层）。
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(
        context,
      ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}
