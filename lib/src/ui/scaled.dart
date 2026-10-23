/// **尺寸与断点随界面缩放派生**（批 3 第 13 条，§CV·八十五）。
///
/// ## 为什么要有这个文件
///
/// 界面缩放（`UiScale` 1.0–2.0）只放大了**字**，没放大**布局**：
/// 导航项高度、金额列宽度、断点阈值全是写死的常量。结果是「字大了，
/// 但放它的格子没大」—— 要么挤成一团，要么黄黑溢出。
///
/// ## 判据：从环境取，不层层传参
///
/// 缩放值从 `MediaQuery.textScalerOf(context)` 取**实际生效的那一个**，
/// 而不是把 `uiScale` 一路传下来：
///
/// - 少一处传参就少一处漂移；
/// - **系统字号变大时也自动跟上**（批 3 第 15 条 `max(系统, 应用)` 落地后，
///   这里不用改一行）。
///
/// ## 用法
///
/// ```dart
/// final bool narrow = isNarrowOf(context, constraints.maxWidth);
/// SizedBox(width: scaledOf(context, 96));
/// ```
library;

import 'package:flutter/widgets.dart';

/// 当前**实际生效**的缩放倍数（应用档位与系统字号取大者的结果）。
///
/// `TextScaler.scale(1.0)` 取的是「基准字号 1.0 会被放大成多少」——
/// 线性缩放时正好是倍数；非线性缩放时是 1.0 号字处的瞬时斜率，
/// 对「算布局尺寸」这个用途足够。
double uiScaleOf(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1.0);

/// 把一个**基准尺寸**换算成当前缩放下的实际尺寸。
double scaledOf(BuildContext context, double base) => base * uiScaleOf(context);

/// **窄屏判据**：可用宽度是否小于「基准断点 × 缩放」。
///
/// 断点必须跟着缩放走 —— 否则 200% 下 480 逻辑像素里塞 2 倍大的字，
/// 判据还按 480 算，就会误判成「够宽」。
///
/// [base] 缺省 480（列表行换两行的阈值）；流水页用 [flowNarrowBase]。
bool isNarrowOf(
  BuildContext context,
  double availableWidth, {
  double base = narrowBase,
}) => availableWidth < base * uiScaleOf(context);

/// 列表行「换两行」的基准断点。
const double narrowBase = 480;

/// 流水页（单号 + 类型 + 金额同排）的基准断点 —— 比列表行宽，因为列更多。
const double flowNarrowBase = 600;

/// 金额列基准宽度（商品列表）。
const double amountColumnBase = 96;

/// 宽金额列基准宽度（开单行）。
const double wideAmountColumnBase = 120;

/// 日期列基准宽度（单据详情）。
const double dateColumnBase = 72;
