// 提案 60（乙）的**机械保证** + 摘要卡单测（2026-11-17）。
//
// ## 为什么需要它
//
// 「保存失败 ⇒ 点一下跳到出错区块」要在**四个提交页**各写一遍（销售 / 采购 / 送货 /
// 退货），而这四页是纪律 18 点名的**同构代码**：`_headerRow` / `_linesSection` 基本
// 逐字复制，没有基类、没有钳子。N-i（锁输入）就是漏改的实例 —— 只改了三个页面，
// `return_page` 漏了。
//
// 本文件挡的是**整页漏改**：
//   - 某页的 `SubmitErrorSummary` 没接 `items/onJump` ⇒ 红；
//   - 某页声明了 `GlobalKey` 却没挂到布局上（或反过来）⇒ 红；
//   - 还留着旧的 `_submitErrorMessages()`（半迁移）⇒ 红。
//
// ⚠️ 它挡不住「key 挂错了 widget」（数量对但位置错）—— 那是行为测试的活，
// 每个页面的「点了真的滚下去」由各自的 page test 钉（目前销售页有一条完整链路，
// 其余三页共用同一个 `_jumpTo` 形状 + 本钳子的数量约束）。**不要**把本文件当成
// 「四页都验过了」的证明（`docs/testing.md`：钳子要说清自己挡什么、不挡什么）。
//
// ⚠️ 按 `lib/src/ui/...` 相对路径读盘 ⇒ `flutter test` 必须在**包根**运行
// （既有先例：`save_lock_guard_test.dart` / `page_isomorphism_test.dart`）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/submit_error_summary.dart';

/// 读 `lib/src/ui/<name>.dart`；读不到 ⇒ 报错并打出当前目录（**前提断言**）。
String _source(String name) {
  final File file = File('lib/src/ui/$name.dart');
  expect(
    file.existsSync(),
    isTrue,
    reason:
        '读不到 $file —— `flutter test` 必须在**包根**运行'
        '（当前目录：${Directory.current.path}）',
  );
  return file.readAsStringSync();
}

void main() {
  // ---------------------------------------------------------------- 组件行为
  group('SubmitErrorSummary（可点摘要）', () {
    Widget host(List<SubmitErrorItem> items, {void Function(SubmitSection)? onJump}) =>
        MaterialApp(
          home: Scaffold(
            body: SubmitErrorSummary(items: items, onJump: onJump),
          ),
        );

    testWidgets('每条错误都照原样列出来（文案不变）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(const <SubmitErrorItem>[
          SubmitErrorItem('请选择客户', section: SubmitSection.header),
          SubmitErrorItem('第 2 行数量不能为 0'),
        ]),
      );

      expect(find.textContaining('还有 2 处要填'), findsOneWidget);
      expect(find.textContaining('请选择客户'), findsOneWidget);
      expect(find.textContaining('第 2 行数量不能为 0'), findsOneWidget);
    });

    testWidgets('带 block 的给按钮，不带的不给（行级细节跳过去也定位不到具体格）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const <SubmitErrorItem>[
            SubmitErrorItem('请选择客户', section: SubmitSection.header),
            SubmitErrorItem('第 2 行数量不能为 0'),
          ],
          onJump: (_) {},
        ),
      );

      expect(
        find.byKey(const Key('submit-error-jump-header')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('submit-error-jump-lines')),
        findsNothing,
        reason: '没有 section 的错误不该凭空长出一个按钮',
      );
    });

    testWidgets('同一块错三处 ⇒ 只给一个按钮（不堆一排）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const <SubmitErrorItem>[
            SubmitErrorItem('请选择客户', section: SubmitSection.header),
            SubmitErrorItem('日期不能晚于今天', section: SubmitSection.header),
            SubmitErrorItem('备注太长了', section: SubmitSection.remark),
          ],
          onJump: (_) {},
        ),
      );

      expect(find.byKey(const Key('submit-error-jump-header')), findsOneWidget);
      expect(find.byKey(const Key('submit-error-jump-remark')), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNWidgets(2));
    });

    testWidgets('按钮点了报的是那个区块（页面据此滚过去）', (WidgetTester tester) async {
      final List<SubmitSection> jumped = <SubmitSection>[];
      await tester.pumpWidget(
        host(
          const <SubmitErrorItem>[
            SubmitErrorItem('明细里有个数为 0', section: SubmitSection.lines),
          ],
          onJump: jumped.add,
        ),
      );

      await tester.tap(find.byKey(const Key('submit-error-jump-lines')));
      await tester.pump();

      expect(jumped, <SubmitSection>[SubmitSection.lines]);
    });

    testWidgets('没有 onJump ⇒ 不出按钮（不给死按钮）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(const <SubmitErrorItem>[
          SubmitErrorItem('请选择客户', section: SubmitSection.header),
        ]),
      );

      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('按钮高度 ≥ 44（`ui_principles.md` 的最小点击区）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const <SubmitErrorItem>[
            SubmitErrorItem('请选择客户', section: SubmitSection.header),
          ],
          onJump: (_) {},
        ),
      );

      final Size size = tester.getSize(
        find.byKey(const Key('submit-error-jump-header')),
      );
      expect(size.height, greaterThanOrEqualTo(44));
    });
  });

  // ---------------------------------------------------------------- 机械保证
  group('四页都接上了（整页漏改护栏）', () {
    /// 每页应当挂几个区块 key（送货不收钱 ⇒ 3；退货只有明细+退款 ⇒ 2）
    const Map<String, int> expectedBlocks = <String, int>{
      'sale_page': 4,
      'purchase_page': 4,
      'delivery_page': 3,
      'return_page': 2,
    };

    for (final MapEntry<String, int> entry in expectedBlocks.entries) {
      test('${entry.key}：摘要接 items/onJump，${entry.value} 个区块 key 都真的挂上了', () {
        final String source = _source(entry.key);

        expect(
          RegExp(r'SubmitErrorSummary\(\s*items:\s*_submitErrorItems\(\),'
                  r'\s*onJump:\s*_jumpTo,')
              .hasMatch(source),
          isTrue,
          reason: '摘要卡必须接上 items + onJump —— 否则按钮不出现或点了没反应',
        );

        expect(
          source.contains('_submitErrorMessages'),
          isFalse,
          reason: '还有旧的 `_submitErrorMessages()` = 半迁移（有人只改了一半）',
        );

        final int declared = RegExp(r'final GlobalKey _\w+Key = GlobalKey\(\);')
            .allMatches(source)
            .length;
        final int attached = RegExp(r'key: _\w+Key,').allMatches(source).length;

        expect(declared, entry.value, reason: '声明了 $declared 个区块 key');
        expect(
          attached,
          entry.value,
          reason: '挂到布局上的只有 $attached 个 —— 声明了不挂等于没接',
        );

        final int jumps = RegExp(r'Future<void> _jumpTo\(SubmitSection')
            .allMatches(source)
            .length;
        expect(jumps, 1, reason: '每页恰有一个跳转实现（复制粘贴不该多出来）');
      });
    }
  });
}
