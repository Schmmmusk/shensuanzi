/// 支持 `**强调**` 的文字（2026-10-31 真机：`Text` 不认 Markdown，
/// 星号被原样显示出来）。
///
/// 解析在 `shensuanzi_app` 的 `emphasisSegments`（纯 Dart，`dart test` 钉得住），
/// 本文件只做「片段 → `TextSpan`」的摆放。
///
/// ## 用法
///
/// ```dart
/// EmphasizedText('你的账**没有丢**。', style: const TextStyle(height: 1.6))
/// ```
///
/// ⚠️ 只用于**用户可见文案**。代码注释里的 `**` 是文档习惯，不用它。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

class EmphasizedText extends StatelessWidget {
  const EmphasizedText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
  });

  /// 原文（可含成对的 `**`）
  final String text;

  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final List<EmphasisSegment> segments = emphasisSegments(text);
    // 没有强调 ⇒ 走普通 Text（少一层 TextSpan，也便于 `find.text` 命中）
    if (segments.length == 1 && !segments.first.strong) {
      return Text(
        segments.first.text,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
      );
    }
    final TextStyle base = style ?? DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          for (final EmphasisSegment segment in segments)
            TextSpan(
              text: segment.text,
              style: segment.strong
                  ? base.copyWith(fontWeight: FontWeight.w700)
                  : base,
            ),
        ],
      ),
      style: base,
      textAlign: textAlign,
      maxLines: maxLines,
    );
  }
}
