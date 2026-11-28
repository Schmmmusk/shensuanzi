// 极简 Markdown 解析（2026-11-28，关于页「第三方组件」）。
//
// 判据只有一条：**真的把语法变成了结构**（标题/表格/列表），
// 而不是把 `#` 和 `|` 原样丢给用户。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/about_markdown.dart';

void main() {
  test('标题：# / ## / ### 分成三级，井号不进正文', () {
    final List<MdBlock> blocks = parseMarkdown('# 一级\n## 二级\n### 三级\n');
    expect(blocks.whereType<MdHeading>().map((MdHeading h) => h.level), <int>[
      1,
      2,
      3,
    ]);
    expect(blocks.whereType<MdHeading>().map((MdHeading h) => h.text), <String>[
      '一级',
      '二级',
      '三级',
    ]);
  });

  test('表格：表头 + 分隔行 + 数据行 ⇒ 一个 MdTable（分隔行不进表格）', () {
    final List<MdBlock> blocks = parseMarkdown(
      '| 组件 | 许可 |\n'
      '|---|---|\n'
      '| SQLite | Public Domain |\n'
      '| Flutter | BSD-3-Clause |\n',
    );
    final MdTable table = blocks.whereType<MdTable>().single;
    expect(table.rows, <List<String>>[
      <String>['组件', '许可'],
      <String>['SQLite', 'Public Domain'],
      <String>['Flutter', 'BSD-3-Clause'],
    ]);
  });

  test('列表：`-` 圆点、`1.` 保留原编号', () {
    final List<MdBlock> blocks = parseMarkdown('- 甲\n- 乙\n1. 丙\n');
    final List<MdListItem> items = blocks.whereType<MdListItem>().toList();
    expect(items.map((MdListItem i) => i.text), <String>['甲', '乙', '丙']);
    expect(items.first.marker, '·');
    expect(items.last.marker, '1.');
  });

  test('引用 / 分隔线 / 段落：各归各类，不吞字', () {
    final List<MdBlock> blocks = parseMarkdown(
      '> 引用一句\n'
      '\n'
      '---\n'
      '\n'
      '普通段落\n',
    );
    expect(blocks.whereType<MdQuote>().single.text, '引用一句');
    expect(blocks.whereType<MdRule>(), hasLength(1));
    expect(blocks.whereType<MdParagraph>().single.text, '普通段落');
  });

  testWidgets('渲染：表格用真 Table、标题用大字（不再是 `|` 与 `#`）', (
    WidgetTester tester,
  ) async {
    const String source =
        '# 第三方组件与许可声明\n'
        '\n'
        '| 组件 | 许可 |\n'
        '|---|---|\n'
        '| SQLite | Public Domain |\n';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownView(parseMarkdown(source)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('about-markdown-table')), findsOneWidget);
    expect(find.text('SQLite'), findsOneWidget);
    expect(find.textContaining('|'), findsNothing, reason: '管道符不许原样出现在界面上');
    expect(find.textContaining('#'), findsNothing, reason: '井号不许原样出现在界面上');
  });
}
