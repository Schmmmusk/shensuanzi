/// **列表页的共用外壳**（批 3 第 16 条，§CV·八十七）。
///
/// ## 为什么只抽「头 / 箭头 / 空态」
///
/// 五页的**行**结构差得远（商品有价格列、往来方有角色、单据有状态色），
/// 硬抽一个 `ListPage` 会把行也框死 —— 那是更大的重构，收益不成正比。
/// 只抽重复度最高的三段。
///
/// ## 三条硬要求（2026-10-23 用户裁定）
///
/// 1. **防抖统一**：连打 5 个字只查 1 次库。单据页是四路 `LIKE`、库存页是
///    5 个聚合 —— 低配机器上逐键查库会明显卡。**默认 300ms，可注入**。
/// 2. **`searchKey` 必须挂到内部 `TextField` 上**：现有测试靠
///    `find.byKey(Key('doc-search'))` 定位，抽组件不能把它们弄红。
/// 3. **「清空全部筛选」要闭环**：清搜索文字 + 清各页自己的筛选状态 + 刷新，
///    三件事一次做完 —— 只清一半等于没清。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'scaled.dart';

/// 计数行文案：**说真实总数**，被 `limit` 截断时把话说明白。
///
/// ## 为什么必须有它（2026-10-27，现实用户暴雷）
///
/// 商品页原来写 `共 ${rows.length} 种`，而 `ProductService.list()` 的 `limit`
/// 默认 200 ⇒ **商品过 200 个后页面永远显示「共 200 种」**。用户拿它对账，
/// 会以为自己只有 200 个商品 —— 这是数据可信度问题，不是美观问题
/// （同 `documents_page` 早先修过的那条）。
///
/// ## 三件事必须同时说
///
/// | # | 说什么 | 为什么 |
/// |---|---|---|
/// | ① | **真实总数**（「共 348 种」） | 用户要的是「我有多少」 |
/// | ② | **只展示了多少**（「当前仅展示前 200 种」） | 不说 ⇒ 用户以为数据丢了 |
/// | ③ | **怎么看到其余的**（「要具体的请用上方搜索」） | 只说①②等于告诉他「你看不全」却不给出路 |
///
/// [shown] 是**当前真的渲染了几条**，[total] 是**同口径的真实总数**。
/// 两者相等（没被截断）时只输出一句干净的「共 N 种」，不吓人。
String countWithLimitText({
  required int shown,
  required int total,
  required String unit,
  bool searching = false,
}) {
  final String head = searching ? '找到 $total $unit' : '共 $total $unit';
  if (shown >= total) return head;
  return '$head（当前仅展示前 $shown $unit，要具体的请用上方搜索）';
}

/// 列表头：搜索（常驻）+ × 清空 + 额外筛选 + 计数行。
///
/// **搜索是常驻的**（不是点开才有）：`ui_principles.md` §1.1 —— 要用户先找到
/// 放大镜才叫「有搜索」，对目标用户等于没有。
class ListHeader extends StatefulWidget {
  const ListHeader({
    super.key,
    required this.searchKey,
    required this.controller,
    required this.hintText,
    required this.onQueryChanged,
    this.leading,
    this.countText,
    this.onClearAll,
    this.clearAllLabel = '清空全部筛选',
    this.debounce = const Duration(milliseconds: 300),
  });

  /// **挂到内部 `TextField` 上的 Key** —— 现有测试靠它定位输入框。
  final Key searchKey;

  final TextEditingController controller;
  final String hintText;

  /// 防抖**之后**才回调（收到的是当时的文字）。
  final void Function(String query) onQueryChanged;

  /// 搜索框下方的额外筛选控件（开关 / chips），各页自摆。
  final Widget? leading;

  /// 计数行文案，如「共 12 种」「只显示最近 200 条（共 348 条）」。
  final String? countText;

  /// 非 `null` ⇒ 显示「清空全部筛选」。**组件负责清搜索文字**，
  /// 调用方只管清自己的筛选状态 + 刷新。
  final VoidCallback? onClearAll;

  final String clearAllLabel;

  /// 防抖时长。测试里传 [Duration.zero] 可立即生效。
  final Duration debounce;

  @override
  State<ListHeader> createState() => _ListHeaderState();
}

class _ListHeaderState extends State<ListHeader> {
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onChanged(String text) {
    _timer?.cancel();
    if (widget.debounce == Duration.zero) {
      widget.onQueryChanged(text);
      return;
    }
    _timer = Timer(widget.debounce, () {
      if (!mounted) return;
      widget.onQueryChanged(text);
    });
  }

  /// × 与「清空全部筛选」都走这里：**立即**回调，不等防抖
  /// （用户点的是「清空」，再等 300ms 才生效会显得没反应）。
  void _clearSearch() {
    _timer?.cancel();
    widget.controller.clear();
    widget.onQueryChanged('');
  }

  void _clearAll() {
    _clearSearch();
    widget.onClearAll?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          key: widget.searchKey,
          controller: widget.controller,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.hintText,
            prefixIcon: const Icon(Icons.search),
            // × 只在有字时出现 —— 空框上挂个 × 会让人以为点了能干嘛
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (BuildContext context, TextEditingValue value, _) =>
                  value.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      key: const Key('list-search-clear'),
                      tooltip: '清空',
                      icon: const Icon(Icons.clear),
                      onPressed: _clearSearch,
                    ),
            ),
            border: const OutlineInputBorder(),
          ),
        ),
        if (widget.leading != null) ...<Widget>[
          const SizedBox(height: 4),
          widget.leading!,
        ],
        if (widget.countText != null || widget.onClearAll != null) ...<Widget>[
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              if (widget.countText != null)
                Expanded(
                  child: Text(
                    widget.countText!,
                    style: TextStyle(
                      height: 1.6,
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                )
              else
                const Spacer(),
              if (widget.onClearAll != null)
                TextButton.icon(
                  key: const Key('list-clear-filters'),
                  onPressed: _clearAll,
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
                  label: Text(widget.clearAllLabel),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// **行尾箭头**：只给「点了会跳走」的行。
///
/// 箭头是「点击会有新页面」的承诺（用户裁定 ③）。用在不跳转的行上
/// （比如打开弹窗）会让承诺失效 —— 所以这是一个**需要主动加**的组件，
/// 不是默认装饰。
class RowChevron extends StatelessWidget {
  const RowChevron({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    // 与文字基线留点空隙，不贴边
    padding: EdgeInsets.only(left: scaledOf(context, 4)),
    child: Icon(
      Icons.chevron_right,
      size: scaledOf(context, 20),
      color: Theme.of(context).hintColor,
    ),
  );
}

/// 列表空态：图标 + 一句「为什么空」+ **一条出路**。
///
/// 只说「没有数据」等于把用户留在死路上 —— 必须给一个可点的下一步
/// （清空搜索 / 清空筛选 / 新建）。
class ListEmptyState extends StatelessWidget {
  const ListEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: <Widget>[
          Icon(icon, size: scaledOf(context, 32), color: theme.hintColor),
          const SizedBox(height: 8),
          Text(title, textAlign: TextAlign.center),
          if (hint != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: TextStyle(
                height: 1.6,
                color: theme.textTheme.bodySmall?.color,
              ),
            ),
          ],
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: 8),
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
