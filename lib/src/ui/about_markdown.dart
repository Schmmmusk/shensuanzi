/// **极简 Markdown 渲染**（2026-11-28，关于页的「第三方组件」）。
///
/// ## 为什么自己写，不引 `flutter_markdown`
///
/// 我们要渲染的只有**一份**文件（`THIRD_PARTY.md`），它用到的东西是
/// 「标题 / 段落 / 列表 / 表格 / 分隔线 / 引用」这六样。引一个完整 Markdown 库要
/// 加依赖、加版本约束、还要跟着 Flutter 大版本升级 —— 为了六个语法付这个代价不划算。
///
/// 用户裁定（2026-11-28）也给了这条路：「如果为了保持零依赖，写一个极简的文本解析」。
///
/// ## 支持范围（**明确写死，不做"大概能解析"**）
///
/// | 语法 | 渲染结果 |
/// |---|---|
/// | `# 标题` / `## 标题` / `### 标题` | 三级标题，字号递减 |
/// | `| a | b |`（第二行是 `|---|---|`） | **真表格**（`Table` + 边框） |
/// | `- xxx` / `* xxx` / `1. xxx` | 列表项（圆点或原编号） |
/// | `> 引用` | 左侧竖线 + 灰字 |
/// | `---` | 分隔线 |
/// | 其它非空行 | 段落 |
///
/// 不处理：行内 `**加粗**` / `` `代码` `` / 链接语法（保持原文，等宽显示）——
/// 这些一旦"半解析"，反而会出现「有的地方粗了、有的没有」的不一致。
library;

import 'package:flutter/material.dart';

/// 一个块。纯数据，便于单测（不必起 widget 树）。
sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level; // 1..3
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdListItem extends MdBlock {
  const MdListItem(this.text, {this.marker = '·'});
  final String text;

  /// 圆点或原编号（`1.`）
  final String marker;
}

class MdTable extends MdBlock {
  const MdTable(this.rows);
  final List<List<String>> rows; // 第一行是表头
}

class MdQuote extends MdBlock {
  const MdQuote(this.text);
  final String text;
}

class MdRule extends MdBlock {
  const MdRule();
}

/// 把 Markdown 文本切成块。**纯函数**，不认识的一律当段落（不吞内容）。
List<MdBlock> parseMarkdown(String source) {
  final List<String> lines = source.replaceAll('\r\n', '\n').split('\n');
  final List<MdBlock> blocks = <MdBlock>[];
  final List<String> paragraph = <String>[];

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add(MdParagraph(paragraph.join(' ')));
    paragraph.clear();
  }

  int i = 0;
  while (i < lines.length) {
    final String raw = lines[i];
    final String line = raw.trimRight();
    final String trimmed = line.trim();

    if (trimmed.isEmpty) {
      flushParagraph();
      i++;
      continue;
    }

    // 表格：当前行以 | 开头，且下一行是 |---| 分隔行
    if (trimmed.startsWith('|') && i + 1 < lines.length) {
      final String next = lines[i + 1].trim();
      final bool isDivider =
          next.startsWith('|') &&
          RegExp(r'^\|[\s:\-\|]+\|?$').hasMatch(next) &&
          next.contains('-');
      if (isDivider) {
        flushParagraph();
        final List<List<String>> rows = <List<String>>[_splitRow(trimmed)];
        i += 2; // 跳过表头 + 分隔行
        while (i < lines.length && lines[i].trim().startsWith('|')) {
          rows.add(_splitRow(lines[i].trim()));
          i++;
        }
        blocks.add(MdTable(rows));
        continue;
      }
    }

    if (trimmed.startsWith('#')) {
      flushParagraph();
      final int level = trimmed.startsWith('###')
          ? 3
          : trimmed.startsWith('##')
          ? 2
          : 1;
      blocks.add(
        MdHeading(level, trimmed.replaceFirst(RegExp(r'^#+'), '').trim()),
      );
      i++;
      continue;
    }

    if (trimmed == '---' || trimmed == '***') {
      flushParagraph();
      blocks.add(const MdRule());
      i++;
      continue;
    }

    if (trimmed.startsWith('>')) {
      flushParagraph();
      blocks.add(MdQuote(trimmed.replaceFirst(RegExp(r'^>\s?'), '')));
      i++;
      continue;
    }

    final RegExpMatch? bullet = RegExp(r'^([-*])\s+(.*)$').firstMatch(trimmed);
    if (bullet != null) {
      flushParagraph();
      blocks.add(MdListItem(bullet.group(2)!.trim()));
      i++;
      continue;
    }
    final RegExpMatch? numbered = RegExp(
      r'^(\d+)[.)]\s+(.*)$',
    ).firstMatch(trimmed);
    if (numbered != null) {
      flushParagraph();
      blocks.add(
        MdListItem(numbered.group(2)!.trim(), marker: '${numbered.group(1)}.'),
      );
      i++;
      continue;
    }

    paragraph.add(trimmed);
    i++;
  }
  flushParagraph();
  return blocks;
}

/// `| a | b |` → `['a','b']`（去掉首尾空段）
List<String> _splitRow(String line) {
  String body = line;
  if (body.startsWith('|')) body = body.substring(1);
  if (body.endsWith('|')) body = body.substring(0, body.length - 1);
  return body.split('|').map((String c) => c.trim()).toList();
}

/// 把 [parseMarkdown] 的结果渲染成 widget。
///
/// 只在**一个**滚动容器里用（调用方负责 `SingleChildScrollView`）。
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.blocks, {super.key});

  final List<MdBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.textTheme.bodySmall?.color ?? Colors.black54;

    Widget wrap(MdBlock block) => switch (block) {
      MdHeading(:final int level, :final String text) => Padding(
        padding: EdgeInsets.only(top: level == 1 ? 4 : 12, bottom: 6),
        child: Text(
          text,
          style: switch (level) {
            1 => theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            2 => theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            _ => theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          },
        ),
      ),
      MdParagraph(:final String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: TextStyle(height: 1.8, color: secondary)),
      ),
      MdListItem(:final String text, :final String marker) => Padding(
        padding: const EdgeInsets.only(bottom: 4, left: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 22,
              child: Text(
                marker,
                style: TextStyle(height: 1.8, color: secondary),
              ),
            ),
            Expanded(
              child: Text(
                text,
                style: TextStyle(height: 1.8, color: secondary),
              ),
            ),
          ],
        ),
      ),
      MdTable(:final List<List<String>> rows) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Table(
          key: const Key('about-markdown-table'),
          border: TableBorder.all(color: theme.dividerColor, width: 0.6),
          columnWidths: const <int, TableColumnWidth>{
            // 第一列是组件名，窄一些；其余按内容分配
            0: FlexColumnWidth(2),
            1: FlexColumnWidth(1),
            2: FlexColumnWidth(1),
            3: FlexColumnWidth(2),
          },
          children: <TableRow>[
            for (int r = 0; r < rows.length; r++)
              TableRow(
                children: <Widget>[
                  for (int c = 0; c < rows[r].length; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 5,
                      ),
                      child: Text(
                        rows[r][c],
                        style: TextStyle(
                          height: 1.5,
                          fontSize: 12,
                          fontWeight: r == 0
                              ? FontWeight.w700
                              : FontWeight.normal,
                          color: r == 0 ? null : secondary,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
      MdQuote(:final String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: theme.dividerColor, width: 3),
            ),
          ),
          child: Text(
            text,
            style: TextStyle(height: 1.8, color: theme.hintColor),
          ),
        ),
      ),
      MdRule() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Divider(height: 1, color: theme.dividerColor),
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[for (final MdBlock block in blocks) wrap(block)],
    );
  }
}
