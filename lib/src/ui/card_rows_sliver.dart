import 'package:flutter/material.dart';

/// 把「一张卡片里的 N 行」做成**懒加载的 sliver**（2026-11-09）。
///
/// ## 为什么要有它
///
/// 单据 / 库存 / 往来三页原来是 `SingleChildScrollView + Column(for ... rows)`：
/// **一次性 build 全部行**。单据页 200 行、每行十几层 widget，在低配机（尤其
/// 无 3D 加速的虚拟机，Flutter 走 CPU 光栅化）上切页要卡 **4 秒**——
/// 而这 200 行里用户一眼只看得到 6~8 行。
///
/// 换成 sliver 之后只有**可见的那几行**会被 build / layout / paint。
///
/// ## 为什么不是直接 `ListView`
///
/// 三页的「头」都很高（标题 + 导出 + 搜索 + 三排筛选 + 说明）。把头顶死成
/// 不可滚动的一截，列表区就只剩半屏。所以用 `CustomScrollView`：
/// 头是 `SliverToBoxAdapter`，行是 `SliverList`，一起滚。
///
/// ## 视觉为什么还像一张卡片
///
/// `DecoratedSliver` 给整段行铺一层卡片底色 + 圆角（`Card` 的默认圆角 12）。
/// **刻意不加 elevation**：200 行共享一张卡片的阴影在视觉上本来就没有意义，
/// 而 `DecoratedSliver` 不做裁剪，阴影反而会在圆角处露出来。
SliverPadding cardRowsSliver({
  Key? key,
  required int itemCount,
  required Widget Function(BuildContext context, int index) itemBuilder,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
  bool dividers = true,
}) {
  return SliverPadding(
    key: key,
    padding: padding,
    sliver: SliverList(
      delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
        final ThemeData theme = Theme.of(context);
        final Widget row = itemBuilder(context, index);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(index == 0 ? 12 : 0),
              bottom: Radius.circular(index == itemCount - 1 ? 12 : 0),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (dividers && index > 0) const Divider(height: 1),
              row,
            ],
          ),
        );
      }, childCount: itemCount),
    ),
  );
}
