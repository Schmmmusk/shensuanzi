// 「**强调**」解析（`emphasisSegments`）—— 2026-10-31 真机。
//
// ## 起因（真实缺陷，不是设想）
//
// 手机上点「怎么办」，对话框里写着 `**你的账没有丢**` —— **星号一起显示出来了**。
// Flutter 的 `Text` 不认 Markdown。按纪律 18 先 grep 全仓：同一模式共 6 处
// 用户可见文案（启动错误页 / 迁移结果 / 恢复确认 / 抢救确认 / 抢救报告 / 设置页提示），
// 所以修法是一处机制 + 六处共用，而不是删掉星号了事（删掉就丢了排版意图）。
//
// 这一层只测**解析**：拆分正确、落单不吞、拼回去与原文等价。
// 「渲染出来没有星号」由根目录的 `emphasized_text_test.dart` 钉。
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  /// 把片段拼回去（粗体片段用 `**` 包回来），用于「不丢字」的等价断言
  String roundTrip(List<EmphasisSegment> segments) =>
      segments.map((EmphasisSegment s) => s.strong ? '**${s.text}**' : s.text)
          .join();

  test('没有 ** ⇒ 单个普通片段（不额外加工）', () {
    final List<EmphasisSegment> out = emphasisSegments('你的账没有丢。');
    expect(out, <EmphasisSegment>[
      const EmphasisSegment('你的账没有丢。', strong: false),
    ]);
  });

  test('成对的 ** ⇒ 粗 / 细交替，星号被摘掉', () {
    final List<EmphasisSegment> out = emphasisSegments('你的账**没有丢**。');
    expect(out, <EmphasisSegment>[
      const EmphasisSegment('你的账', strong: false),
      const EmphasisSegment('没有丢', strong: true),
      const EmphasisSegment('。', strong: false),
    ]);
    // 屏幕上不许再出现星号：拼起来 == 去掉 ** 的原文
    expect(out.map((EmphasisSegment s) => s.text).join(), '你的账没有丢。');
  });

  test('整句都是强调（`**x**`）⇒ 一个粗体片段', () {
    expect(emphasisSegments('**先别删旧文件夹**'), <EmphasisSegment>[
      const EmphasisSegment('先别删旧文件夹', strong: true),
    ]);
  });

  test('落单的 ** ⇒ 原样保留（宁可显示星号，也不要吞掉半句话）', () {
    for (final String text in <String>['**没配对', '没配对**', 'a**b']) {
      final List<EmphasisSegment> out = emphasisSegments(text);
      expect(
        out.map((EmphasisSegment s) => s.text).join(),
        text,
        reason: '落单时文字必须一字不少：$text',
      );
      expect(out.every((EmphasisSegment s) => !s.strong), isTrue);
    }
  });

  test('多处强调：按出现顺序交替（不支持嵌套，文档已写明）', () {
    final List<EmphasisSegment> out = emphasisSegments(
      '**先别删旧文件夹**，确认新位置好用再说。',
    );
    expect(out.first.strong, isTrue);
    expect(out.first.text, '先别删旧文件夹');
    expect(out.last.strong, isFalse);

    final List<EmphasisSegment> two = emphasisSegments('A**B**C**D**E');
    expect(
      two.where((EmphasisSegment s) => s.strong).map((EmphasisSegment s) => s.text),
      <String>['B', 'D'],
    );
    expect(roundTrip(two), 'A**B**C**D**E');
  });

  test('空串 / 只有星号 ⇒ 不崩，也不产生空片段', () {
    expect(emphasisSegments(''), <EmphasisSegment>[
      const EmphasisSegment('', strong: false),
    ]);
    // 单个 `**` = 一个**没闭合**的定界符 ⇒ 按落单处理，原样保留
    expect(emphasisSegments('**'), <EmphasisSegment>[
      const EmphasisSegment('**', strong: false),
    ]);
    // `****` = 一对空的强调 ⇒ 星号摘掉、渲染成空（屏幕上什么都没有）
    final List<EmphasisSegment> empty = emphasisSegments('****');
    expect(empty.map((EmphasisSegment s) => s.text).join(), '');
    expect(empty.any((EmphasisSegment s) => s.text.contains('*')), isFalse);
  });

  test('全仓 6 处真实文案：解析后屏幕上不再有 `**`', () {
    // 逐字取自源码（改文案时这条会跟着漂，是有意的：它同时是一份清单）
    const List<String> real = <String>[
      '这个数据文件是**更新版本**的神算子做的（数据格式 v7，你现在打开的这个版本只到 v6）。',
      '先说清楚：**你的账没有丢**。手机上的单据、库存都是从电脑同步过来的。',
      '⚠️ 重装会清掉手机上的一切副本，所以**第二步和第三步不能省**。',
      '· 现在打不开的那个数据文件会**改名保存**（名字带 broken），不会删除；',
      '要说清楚：救回来的东西**可能不完整**。',
      '这次的改动**现在已生效**，但重启软件后会变回原来的设置。',
    ];
    for (final String text in real) {
      final String rendered = emphasisSegments(
        text,
      ).map((EmphasisSegment s) => s.text).join();
      expect(
        rendered.contains('**'),
        isFalse,
        reason: '渲染后还留着星号 ⇒ 用户会看到 `**`：$text',
      );
      expect(
        rendered,
        text.replaceAll('**', ''),
        reason: '摘星号时不许顺手改字：$text',
      );
    }
  });
}
