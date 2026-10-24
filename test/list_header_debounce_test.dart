// 列表搜索框的**防抖**护栏（4c，2026-10-24，§CV·九十九）。
//
// ## 为什么需要这个文件
//
// 单据页的搜索有四路匹配，其中「商品名」那一路的硬底约 **340 ms**（要碰一遍
// 37 万条明细，见提案 §三）—— 如果每敲一个字符都查一次库，打字会直接卡死。
//
// 防抖本身 **2026-10-23 就已实现**（`list_scaffold.dart`，§CV·八十五，
// `debounce` 默认 300 ms 且可注入），但当时**没有测试**：
// 谁把 `_onChanged` 里的 `_timer?.cancel()` 删掉，功能测试会全绿、
// 只有手感变差 —— 这种退化必须被钉住。
//
// ⚠️ 本文件**不重复实现防抖**（重复实现会叠成 600 ms），只钉住三条既有行为：
// ① 连续输入期间不回调；② 停手 300 ms 后**只回调一次**，且是最终文字；
// ③ 点「×」**立即**回调（用户点的是「清空」，再等 300 ms 会显得没反应）。
import 'package:flutter/material.dart';
import 'package:shensuanzi/src/ui/list_scaffold.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late TextEditingController controller;
  late List<String> calls;

  setUp(() {
    controller = TextEditingController();
    calls = <String>[];
  });
  tearDown(() => controller.dispose());

  Future<void> pumpHeader(WidgetTester tester, {Duration? debounce}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListHeader(
              searchKey: const Key('search'),
              controller: controller,
              hintText: '搜单号 / 对方 / 商品',
              onQueryChanged: calls.add,
              debounce: debounce ?? const Duration(milliseconds: 300),
            ),
          ),
        ),
      );

  testWidgets('连打 5 个字符只回调 1 次，且回调的是最终文字', (WidgetTester tester) async {
    await pumpHeader(tester);

    // 每 50 ms 敲一个字符 —— 间隔远小于 300 ms 的防抖窗口
    for (final String text in <String>['1', '12', '123', '1234', '12345']) {
      await tester.enterText(find.byKey(const Key('search')), text);
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(calls, isEmpty, reason: '还在连续输入，一次都不该回调（否则每键一次 340 ms 查询）');

    await tester.pump(const Duration(milliseconds: 350));
    expect(calls, <String>[
      '12345',
    ], reason: '停手 300 ms 后只回调一次，且是最终文字（中间态全被吞掉）');
  });

  testWidgets('点「×」立即生效，不等防抖', (WidgetTester tester) async {
    await pumpHeader(tester);
    await tester.enterText(find.byKey(const Key('search')), '可乐');
    await tester.pump(const Duration(milliseconds: 350));
    calls.clear();

    await tester.tap(find.byKey(const Key('list-search-clear')));
    await tester.pump();

    expect(calls, <String>[''], reason: '清空必须立即回调 —— 再等 300 ms 会显得点了没反应');
  });

  testWidgets('debounce = Duration.zero ⇒ 立即回调（测试与「即时筛选」用）', (
    WidgetTester tester,
  ) async {
    await pumpHeader(tester, debounce: Duration.zero);
    await tester.enterText(find.byKey(const Key('search')), '王');
    await tester.pump();
    expect(calls, <String>['王']);
  });
}
