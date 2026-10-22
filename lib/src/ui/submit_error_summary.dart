/// **保存失败时的页顶错误摘要**（2026-10-21，§CV·八十 批 1 第 ③ 条）。
///
/// ## 为什么是「页顶摘要」而不是「滚到第一个出错字段」
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
library;

import 'package:flutter/material.dart';

/// 一次提交失败的错误摘要。`messages` 由各页从自己的
/// `*DraftInvalid.fieldErrors` / `lineErrors` 里取（类型不同，不能在这里统一）。
class SubmitErrorSummary extends StatelessWidget {
  const SubmitErrorSummary({super.key, required this.messages});

  /// 人话级错误文案（已经是「怎么办」的句式，来自 core 的校验层）
  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final Color error = theme.colorScheme.error;
    // 最多列 5 条 —— 再多也不是「一眼能看完」的量，剩下的给一句总述
    const int maxShown = 5;
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
                  '还有 ${messages.length} 处要填',
                  style: TextStyle(
                    height: 1.6,
                    fontWeight: FontWeight.w700,
                    color: error,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final String message in messages.take(maxShown))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('· $message', style: const TextStyle(height: 1.6)),
            ),
          if (messages.length > maxShown)
            Text(
              '…还有 ${messages.length - maxShown} 处',
              style: TextStyle(height: 1.6, color: theme.hintColor),
            ),
        ],
      ),
    );
  }
}
