/// 完整用户手册页（§AG·八）。
///
/// ## 内容不是这里写的
///
/// 全部来自 `manual_content.dart`（纯 Dart 单一来源）—— 随包分发的
/// `用户手册.html` 用**同一份数据**由 `make_manual_html.dart` 生成，
/// 两边永远一致。本页只负责把数据摆成 Flutter 的样子。
///
/// ## 渲染纪律
///
/// - 手册面向**所有用户**（含把字号调到 200% 的）：行高 1.7 起步，
///   提示框不用纯颜色区分（加「注意 / 小贴士」前缀，色弱也能分清）；
/// - 整页可滚动（UI 内容一律要能滚动 —— 200% 缩放是已发布功能）；
/// - 不造句：所有文字来自内容模型，本文件不出现任何用户可见的新文案。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

/// 完整手册页。从「帮助」页最上方进入。
class ManualPage extends StatelessWidget {
  const ManualPage({super.key, required this.versionLine});

  /// 印在「反馈与版本」一章的版本行（宿主传 `AppVersion.display`）。
  final String versionLine;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.textTheme.bodySmall?.color ?? Colors.black54;
    final List<ManualSection> sections = buildManualSections(
      versionLine: versionLine,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('用户手册')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (int i = 0; i < sections.length; i++) ...<Widget>[
                  _SectionHeader(index: i + 1, title: sections[i].title),
                  for (final ManualBlock block in sections[i].blocks)
                    _Block(block: block, secondary: secondary),
                  const SizedBox(height: 28),
                ],
                Text(
                  '这份手册在软件文件夹里也有一份网页版（用户手册.html），'
                  '双击就能用浏览器打开、可打印。',
                  style: TextStyle(height: 1.7, color: secondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.index, required this.title});

  final int index;
  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$index',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// 手册正文 → 富文本（§审查：手册里的 `**加粗**` 以前是**原样印成星号**的）。
///
/// 只认 `**…**` 一种标记 —— 手册不需要完整 Markdown，多一种语法就多一处
/// 两边渲染不一致的机会（HTML 侧与这里必须同款）。
Widget _manualText(String text, TextStyle style) {
  // 按 `**` 切开后**奇数段**是加粗的（0 普通 / 1 粗 / 2 普通 …）
  final List<String> parts = text.split('**');
  return Text.rich(
    TextSpan(
      children: <TextSpan>[
        for (int i = 0; i < parts.length; i++)
          TextSpan(
            text: parts[i],
            style: i.isOdd ? const TextStyle(fontWeight: FontWeight.w700) : null,
          ),
      ],
    ),
    style: style,
  );
}

class _Block extends StatelessWidget {
  const _Block({required this.block, required this.secondary});

  final ManualBlock block;
  final Color secondary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle body = TextStyle(height: 1.7, color: theme.textTheme.bodyLarge?.color);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: switch (block) {
        ManualParagraph(:final text) => _manualText(text, body),
        ManualSteps(:final items) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // C3·真机反馈：编号圆圈是固定尺寸，最大缩放下内部数字
                    // （textScaler 放大）会戳出圆圈边界 —— 圆圈随缩放一起变大
                    Container(
                      width: MediaQuery.textScalerOf(context).scale(22),
                      height: MediaQuery.textScalerOf(context).scale(22),
                      margin: const EdgeInsets.only(top: 3),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: MediaQuery.textScalerOf(context).scale(12),
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: _manualText(items[i], body)),
                  ],
                ),
              ),
          ],
        ),
        ManualNote(:final text, :final warning) => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: warning
                ? const Color(0xFFFDF6E3)
                : const Color(0xFFF0F7F0),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: warning ? const Color(0xFFE8C268) : const Color(0xFFB7DFB7),
            ),
          ),
          child: _manualText('${warning ? '注意' : '小贴士'}：$text', body),
        ),
        ManualQa(:final question, :final answer) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _manualText('问：$question', body),
            // 问句本身就是主句，用「问：」前缀 + 原有字重（不再整句加粗，
            // 免得与正文里的 `**` 强调抢视觉）
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: _manualText('答：$answer', body),
            ),
          ],
        ),
      },
    );
  }
}
