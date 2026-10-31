/// 「**强调**」的解析（纯 Dart，`dart test` 钉得住）。
///
/// ## 为什么需要它
///
/// 2026-10-31 真机：`怎么办` 对话框里写着「**你的账没有丢**」—— 屏幕上
/// **连星号一起显示**了。Flutter 的 `Text` 不认 Markdown，星号就是普通字符。
///
/// 这不是一处笔误：全仓有 5 处用户可见文案用了 `**`（启动错误页、
/// 恢复确认框、抢救确认框、设置页 SnackBar、这次的降级说明）。按纪律 18
/// （修 bug 先 grep 全仓同款模式）应当**一处机制、五处共用**，
/// 而不是把五处的星号删掉了事 —— 删掉就丢了「这句最要紧」的排版意图。
///
/// ## 边界
///
/// - 只认成对的 `**`；落单的 `**` 原样保留（宁可显示星号，也不要吞掉半句话）；
/// - **不支持嵌套**（`**a**b**c**` ⇒ 粗 / 细 / 粗 / 细，按出现顺序交替）；
/// - 空串 / 没有 `**` ⇒ 一个普通片段。
library;

/// 一段文字：是否加粗。
class EmphasisSegment {
  const EmphasisSegment(this.text, {required this.strong});

  final String text;
  final bool strong;

  @override
  String toString() => strong ? '**$text**' : text;

  @override
  bool operator ==(Object other) =>
      other is EmphasisSegment &&
      other.text == text &&
      other.strong == strong;

  @override
  int get hashCode => Object.hash(text, strong);
}

/// 把 `**强调**` 拆成「普通 / 加粗」交替的片段。
///
/// **落单的 `**`（个数为奇数）⇒ 整句按普通文字处理、星号原样保留**：
/// 宁可显示星号，也不要猜「他想强调到哪儿」—— 猜错就是吞掉半句话。
///
/// 调用方拿到的所有片段拼起来，除了成对的 `**` 被摘掉之外，与输入**逐字相同**。
List<EmphasisSegment> emphasisSegments(String text) {
  int pairs = 0;
  for (int i = 0; i + 1 < text.length; i++) {
    if (text[i] == '*' && text[i + 1] == '*') {
      pairs++;
      i++;
    }
  }
  if (pairs == 0 || pairs.isOdd) {
    return <EmphasisSegment>[EmphasisSegment(text, strong: false)];
  }

  final List<EmphasisSegment> out = <EmphasisSegment>[];
  int index = 0;
  bool strong = false;
  while (true) {
    final int next = text.indexOf('**', index);
    final int end = next < 0 ? text.length : next;
    final String segment = text.substring(index, end);
    if (segment.isNotEmpty) out.add(EmphasisSegment(segment, strong: strong));
    if (next < 0) break;
    strong = !strong;
    index = next + 2;
  }
  // 全是空片段（例如整句就是 `**`）⇒ 给一个空串，调用方渲染成空
  if (out.isEmpty) {
    return const <EmphasisSegment>[EmphasisSegment('', strong: false)];
  }
  return out;
}
