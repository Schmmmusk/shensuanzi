/// **保存失败时的页顶错误摘要**（2026-10-21，§CV·八十 批 1 第 ③ 条）。
///
/// ## 为什么是「页顶摘要」而不是「自动滚到第一个出错字段」
///
/// 用户裁定原话：「`ensureVisible` 要做到精准滚动，得给每个字段挂 `GlobalKey`，
/// 在 `Column` 布局下很容易写成一坨循环遍历 —— 这绝对不能草率」。
///
/// 四个提交页（销售 / 采购 / 送货 / 退货）每页 3–6 个字段，逐字段挂 key 的
/// 成本远大于收益，而且**漏挂一个就静默失效**。改成：
///
/// 1. 保存失败 ⇒ **滚回页顶**（`jumpTo(0)`）；
/// 2. 页顶列出「哪几处要填」（本组件）；
/// 3. 每个字段**仍然**就地 `errorText` 标红（既有行为不变）。
///
/// 用户看到的是「还有 2 处要填」+ 两句具体的话，而不是「按钮点了没反应」。
///
/// ## 2026-11-17 增补（提案 60 裁定乙）：从「只读的摘要」变成「可点的摘要」
///
/// 上面那条裁定的**代价**是：用户知道「第 2 行数量不对」，仍要自己在页面里找那一行。
/// 提案 60 补的就是这一半，走**乙**方案 —— **用户点一下才跳**，而不是校验失败自动滚：
///
/// | | 自动滚（甲） | 点着跳（乙·本实现） |
/// |---|---|---|
/// | 同时错三处 | 只滚到第一个，用户改完页面又跳走 | 一次只跳他点的那个，跳完不动 |
/// | 要挂的 key | 每个字段 + 每行动态 key（24+ × 4 页） | **每页 3–4 个静态区块 key**（往来+日期是一行，合一个） |
/// | 同构漏改风险 | 高（纪律 18 点名的高发区） | 低（区块是布局骨架，不随行增删） |
///
/// ⇒ 现在每条错误可以带一个「跳到哪个区块」的标记，渲染成页顶的一排按钮
/// （`[往来方] [明细] [收款]`），点了由页面用 `Scrollable.ensureVisible` 滚过去。
///
/// **仍然不做自动滚**：多个错误时「先跳哪个」是猜的，而猜错比不跳更烦 ——
/// 见 `docs/ui_principles.md` 对「暗行为」的立场。
library;

import 'package:flutter/material.dart';

/// 出错时「点一下能跳过去」的**区块**（每页 3–4 个静态块）。
///
/// ⚠️ 刻意**不是**字段粒度：`party` 与 `date` 在同一行，跳谁都落在同一处；
/// 行级错误（第 2 行数量）也归到 `lines` —— 一个块。
/// 粒度越细，key 越多、漏挂的机会越大（纪律 18）。
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

/// 一条错误：文案 + 可选「跳到哪个区块」。
class SubmitErrorItem {
  const SubmitErrorItem(this.message, {this.section, this.sectionLabel});

  /// 人话级错误文案（已经是「怎么办」的句式，来自 core 的校验层）
  final String message;

  /// 点了要跳到哪块；`null` = 这一条不给跳（例如行级细节，跳过去也定位不到具体格）
  final SubmitSection? section;

  /// 按钮上的短名（「供应商」「明细」…）；`null` ⇒ 用 [SubmitSection] 的默认名
  final String? sectionLabel;
}

/// 一次提交失败的错误摘要。`items` 由各页从自己的
/// `*DraftInvalid.fieldErrors` / `lineErrors` 里映射（类型不同，不能在这里统一）。
class SubmitErrorSummary extends StatelessWidget {
  const SubmitErrorSummary({super.key, required this.items, this.onJump});

  /// 人话错误（已去重保序，由调用方保证）
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
    final Map<SubmitSection, String> bySection =
        <SubmitSection, String>{};
    for (final SubmitErrorItem item in items) {
      final SubmitSection? section = item.section;
      if (section == null) continue;
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
    final List<({SubmitSection section, String label})> jumps = _jumps;
    return Container(
      key: const Key('submit-error-summary'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: error.withValues(alpha: 0.45)),
      ),
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
          for (final SubmitErrorItem item in items.take(maxShown))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '· ${item.message}',
                style: const TextStyle(height: 1.6),
              ),
            ),
          if (items.length > maxShown)
            Text(
              '…还有 ${items.length - maxShown} 处',
              style: TextStyle(height: 1.6, color: theme.hintColor),
            ),
        ],
      ),
    );
  }
}
