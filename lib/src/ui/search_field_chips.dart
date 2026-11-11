import 'package:flutter/material.dart';

/// 搜索时的一个「在哪儿找」选项（如「全部」「商品名」「编码」）。
class SearchFieldOption {
  const SearchFieldOption(this.id, this.label);

  /// 稳定标识（存进页面 state、测试用它定位）。**不要用中文当 id**。
  final String id;

  /// 按钮上显示的字（中文，面向用户）。
  final String label;
}

/// 搜索框下面那一排「在哪儿找」的**单选** chip 行。
///
/// ## 为什么需要它（2026-11-11 用户裁定）
///
/// 真机测试里搜「6」命中了**全部 300 个商品** —— 因为造数库的条码全是
/// `6900001000000…` 开头，而默认三路匹配（商品名 / 编码 / 条码）里条码那一路
/// 把所有人都捞进来了。用户看到的是「搜一个数字出来一屏」，分不清是自己搜错了
/// 还是软件坏了。
///
/// ⇒ 给「在哪儿找」一个显式开关，让人能说「我只在商品名里找」。
///
/// ## 三个设计决定
///
/// 1. **单选，不是多选**。中老年用户对「勾了三个只生效一个」的复选框容易困惑；
///    而实际场景是互斥的：扫码时只想搜条码，找货时只想搜名称。
/// 2. **搜索词为空时整行不显示**（由调用方控制）。日常不搜索时它不该占地方。
/// 3. **默认「全部」**，与加这个功能之前的行为一致 —— 老用户不会因为升级而
///    「搜不到了」（默认收紧是最容易造成「软件坏了」错觉的改法）。
///
/// ## 与 `ListHeader.leading` 的关系
///
/// `ListHeader` 早就留了 `leading` 这个位（注释写着「搜索框下方的额外筛选控件，
/// 各页自摆」），所以本组件是**零侵入**接入 —— 不需要改共用列表头。
class SearchFieldChips extends StatelessWidget {
  const SearchFieldChips({
    super.key,
    required this.options,
    required this.selectedId,
    required this.onChanged,
    this.keyPrefix = 'search-field',
  });

  final List<SearchFieldOption> options;

  /// 当前选中的 `id`。必须能在 [options] 里找到，否则视为「全部」（第一项）。
  final String selectedId;

  final ValueChanged<String> onChanged;

  /// 每个 chip 的 Key 前缀：`<prefix>-<id>`。
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 选中的 id 不在选项里（比如调用方换了字段集）⇒ 退回第一项，不崩
    final String effective =
        options.any((SearchFieldOption o) => o.id == selectedId)
        ? selectedId
        : (options.isEmpty ? '' : options.first.id);

    return Wrap(
      spacing: 6,
      runSpacing: 0,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          '在哪儿找：',
          style: TextStyle(
            fontSize: 13,
            height: 1.6,
            color: theme.textTheme.bodySmall?.color,
          ),
        ),
        for (final SearchFieldOption option in options)
          ChoiceChip(
            key: Key('$keyPrefix-${option.id}'),
            label: Text(option.label),
            selected: option.id == effective,
            // 视觉密度：默认 chip 对「超大界面」（中老年用户常用）偏大
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            visualDensity: VisualDensity.compact,
            onSelected: (bool picked) {
              // 再点已选中的那个不做任何事（不是「取消选中」——
              // 单选组里取消会让「在哪儿找」变成未定义状态）
              if (picked) onChanged(option.id);
            },
          ),
      ],
    );
  }
}
