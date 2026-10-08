/// 明细行「数量 / 单价 / 小计」的摆放判定（M10，2026-10-08）。
///
/// 判断放纯 Dart（`dart test` 钉得住），Flutter 只摆放 —— 与本项目其它
/// 「判断进纯 Dart 包」的模块同一条纪律。
///
/// ## 为什么需要它
///
/// 明细行原先是**固定横向比例**（数量 flex 1、单价 flex 2、小计固定 96px）。
/// 窄屏 + 超大字号（设置里最高 200%）时，单价框被压得放不下
/// 「单价（元/箱）」这个 label ⇒ 系统把它截成省略号（真机 M10 实测）。
/// 该堆叠时堆叠成上下三行，各占满宽。
library;

/// 并排所需的**最小可用宽度**（逻辑像素）。
///
/// 取 340：小于它时「数量（瓶）」「单价（元/瓶）」两个 label 加上右侧
/// 小计就挤不下（桌面上明细行的常见可用宽度 ≥ 600，留足余量）。
const double entryFieldsMinWidth = 340;

/// 明细行是否该改成**上下堆叠**。
///
/// - [maxWidth] 为该行的可用宽度（`LayoutBuilder` 给的 `constraints.maxWidth`）；
/// - [textScale] 为字号放大倍数（1.0 = 标准，2.0 = 设置里的最高档）。
///
/// 宽度阈值随字号**线性**放宽：字放大一倍，同样的字需要一倍横向空间。
/// 无界宽度（横向滚动容器）⇒ 不堆叠（没有「太窄」这回事）。
bool entryFieldsShouldStack({
  required double maxWidth,
  required double textScale,
}) {
  if (!maxWidth.isFinite) return false;
  final double factor = textScale > 0 ? textScale : 1;
  return maxWidth < entryFieldsMinWidth * factor;
}
