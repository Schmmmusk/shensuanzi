/// 开单校验摘要。销售和采购可定位到具体输入框，其余页面支持区块导航。
library;

import 'package:flutter/material.dart';

/// 没有关联输入控件时，可跳转到对应表单区块。
enum SubmitSection {
  /// 往来方 + 日期（同一行，共用一个 key）
  header,

  /// 明细区（含行卡片）
  lines,

  /// 收款 / 付款 / 退款区
  payments,

  /// 备注
  remark,
}

/// 一条错误及其字段焦点或区块位置。
class SubmitErrorItem {
  const SubmitErrorItem(
    this.message, {
    this.section,
    this.sectionLabel,
    this.focusNode,
  });

  /// 人话级错误文案（已经是「怎么办」的句式，来自 core 的校验层）
  final String message;

  /// 没有具体字段焦点时使用的区块。
  final SubmitSection? section;

  /// 按钮上的短名（「供应商」「明细」…）；`null` ⇒ 用 [SubmitSection] 的默认名
  final String? sectionLabel;
  final FocusNode? focusNode;

  void revealField() {
    final FocusNode? node = focusNode;
    final BuildContext? context = node?.context;
    if (node == null || context == null || !context.mounted) return;
    node.requestFocus();
    Scrollable.ensureVisible(
      context,
      alignment: 0.35,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }
}

/// 一次提交失败的错误摘要。`items` 由各页从自己的
/// `*DraftInvalid.fieldErrors` / `lineErrors` 里映射（类型不同，不能在这里统一）。
class SubmitErrorSummary extends StatelessWidget {
  const SubmitErrorSummary({super.key, required this.items, this.onJump});

  /// 每个出错字段一条，保持表单顺序。
  final List<SubmitErrorItem> items;

  /// 点了某个区块按钮 ⇒ 由**页面**负责滚过去（组件不碰滚动控制器）
  final void Function(SubmitSection section)? onJump;

  /// 默认短名 —— 页面可以覆盖（采购说「付款」而不是「收款」）
  static String defaultLabel(SubmitSection section) {
    switch (section) {
      case SubmitSection.header:
        return '往来方 / 日期';
      case SubmitSection.lines:
        return '明细';
      case SubmitSection.payments:
        return '收付款';
      case SubmitSection.remark:
        return '备注';
    }
  }

  /// 需要跳的区块（按错误出现顺序去重）—— 同一块错三处只给一个按钮
  List<({SubmitSection section, String label})> get _jumps {
    final Map<SubmitSection, String> bySection = <SubmitSection, String>{};
    for (final SubmitErrorItem item in items) {
      final SubmitSection? section = item.section;
      if (section == null || item.focusNode != null) continue;
      bySection.putIfAbsent(
        section,
        () => item.sectionLabel ?? defaultLabel(section),
      );
    }
    return <({SubmitSection section, String label})>[
      for (final MapEntry<SubmitSection, String> e in bySection.entries)
        (section: e.key, label: e.value),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final Color error = theme.colorScheme.error;
    // 最多列 5 条 —— 再多也不是「一眼能看完」的量，剩下的给一句总述
    const int maxShown = 5;
    final bool fieldLinks = items.any((item) => item.focusNode != null);
    final List<({SubmitSection section, String label})> jumps = _jumps;
    Widget errorLine(SubmitErrorItem item) {
      if (item.focusNode == null) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('· ${item.message}', style: const TextStyle(height: 1.6)),
        );
      }
      return TextButton(
        onPressed: item.revealField,
        style: TextButton.styleFrom(
          foregroundColor: error,
          minimumSize: const Size(44, 44),
          alignment: Alignment.centerLeft,
        ),
        child: Text(item.message),
      );
    }

    return Padding(
      key: const Key('submit-error-summary'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: error.withValues(alpha: 0.45)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.error_outline, size: 20, color: error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '还有 ${items.length} 处要填',
                      style: TextStyle(
                        height: 1.6,
                        fontWeight: FontWeight.w700,
                        color: error,
                      ),
                    ),
                  ),
                ],
              ),
              // 「点一下跳过去」——没有可跳的区块时整排不出现（不留空行）
              if (jumps.isNotEmpty && onJump != null) ...<Widget>[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final ({SubmitSection section, String label}) jump
                        in jumps)
                      OutlinedButton(
                        key: Key('submit-error-jump-${jump.section.name}'),
                        // 44 高：`docs/ui_principles.md` 的「按钮最小点击区 44×44」。
                        // 这个摘要只在**已经保存失败**时出现，此时用户就是要来改错的，
                        // 占高一点换「一眼能点」是划算的。
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 44),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          foregroundColor: error,
                          side: BorderSide(color: error.withValues(alpha: 0.6)),
                          // ⚠️ **不许在这里给 `textStyle`**（2026-11-22 真机）：
                          // `ButtonStyle.textStyle` 是**替换**按钮的排版样式，一个只有
                          // `fontWeight` 的 `TextStyle` 会把 `fontFamily` 一起抹掉 ——
                          // 中文于是掉回系统兜底字体，同一个页面上「跳到退货明细」的字形
                          // 与别处明显不同（用户截图报的就是它）。
                          // 字重放到 label 上：`Text` 是**合并**进 `DefaultTextStyle`，
                          // 字体族会跟着主题走。
                        ),
                        onPressed: () => onJump!(jump.section),
                        child: Text(
                          '跳到${jump.label}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              for (final item in items.take(maxShown)) errorLine(item),
              if (fieldLinks && items.length > maxShown)
                ExpansionTile(
                  title: Text('查看其余 ${items.length - maxShown} 处'),
                  children: [
                    for (final item in items.skip(maxShown)) errorLine(item),
                  ],
                ),
              if (!fieldLinks && items.length > maxShown)
                Text(
                  '…还有 ${items.length - maxShown} 处',
                  style: TextStyle(height: 1.6, color: theme.hintColor),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
