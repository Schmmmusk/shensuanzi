// `ExportButton` 的 5c-2 行为测试（2026-11-04）。
//
// 5c-2 的诉求（`docs/proposals/第5批-低配体验-方案.md` §四 5c-2）：
// 「导出成功文案只活 6 秒」⇒ 页面上**留一行**「上次导出：文件名（今天 09:12）」，
// SnackBar 保留。低配机导出慢，SnackBar 退了用户还没找到文件。
//
// 为什么单独一个文件：`ExportButton` 被 8 个页面共用，之前**没有任何测试**
// 覆盖它（只有各页顺带点了按钮）。同构控件没有测试 = 改一处炸八处
// —— 本轮 AppBar 溢出（`RenderFlex overflowed by 8.0 pixels`）就是这么漏的。
//
// ⚠️ 反向灵敏度：把 `export_button.dart` 的 `Column` 改回只返回 `button`，
// 「成功后留一行小字」与「SnackBar 退后小字还在」两条必须变红。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/export_button.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

import 'support/fake_export.dart';

/// 放进一个**限宽**容器模拟真实表头（窄窗 / 与 AppBar 同级的约束）。
Future<void> _pump(
  WidgetTester tester,
  FakeExport fake, {
  double width = 420,
}) async {
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.topRight,
              child: ExportButton(
                key: const Key('eb'),
                label: '导出流水',
                // write 需要一张表；本文件只测按钮自身的行为 ⇒ 给最小的表
                export: () => fake.write(
                  const ExportTable(
                    label: '往来流水',
                    header: <String>['单号'],
                    rows: <List<String>>[],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 点**按钮本体**，不是 `Key('eb')`。
///
/// 5c-2 之后 `ExportButton` 是 `Column(按钮, 小字)`，Key 落在整个 Column 上 ——
/// 它的几何中心正好在「按钮与小字的缝隙」里，tap 落不到按钮上
/// （`would not hit test on the specified widget`）。
Finder _button() => find
    .descendant(of: find.byKey(const Key('eb')), matching: find.byType(TextButton));

void main() {
  FakeExport fake() => FakeExport();

  /// 只取文件名部分（与被测代码同一口径，但不复制它的实现）
  String nameOf(String path) => path.split(Platform.pathSeparator).last;

  testWidgets('没导出过 ⇒ 页面上没有「上次导出」这行', (
    WidgetTester tester,
  ) async {
    await _pump(tester, fake());
    await tester.pumpAndSettle();

    expect(find.textContaining('上次导出'), findsNothing);
  });

  testWidgets('导出成功 ⇒ 留下一行「上次导出：文件名（今天 HH:mm）」', (
    WidgetTester tester,
  ) async {
    final String path =
        'D:\\神算子导出'
        '${Platform.pathSeparator}神算子-往来流水-甲客户-20261104.csv';
    await _pump(
      tester,
      fake()..result = ExportSuccess(path: path, rowCount: 7),
    );
    await tester.pumpAndSettle();

    await tester.tap(_button());
    await tester.pumpAndSettle();

    final Finder line = find.textContaining('上次导出：');
    expect(line, findsOneWidget);
    // 只给**文件名**，不给完整路径（完整路径在 SnackBar 里，太长会撑爆表头）
    expect(
      tester.widget<Text>(line).data,
      startsWith('上次导出：${nameOf(path)}（今天 '),
    );
    expect(tester.widget<Text>(line).data, isNot(contains('神算子导出')));
  });

  testWidgets('SnackBar 退场后小字**还在**（5c-2 的全部意义）', (
    WidgetTester tester,
  ) async {
    await _pump(tester, fake());
    await tester.pumpAndSettle();

    await tester.tap(_button());
    await tester.pumpAndSettle();
    expect(find.textContaining('上次导出：'), findsOneWidget);

    // SnackBar 的 duration 是 6 秒（export_button.dart）—— 越过它
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('上次导出：'),
      findsOneWidget,
      reason: '5c-2 就是为了让「导到哪了」在 SnackBar 消失后仍可见',
    );
  });

  testWidgets('导出 0 行（没生成文件）⇒ 不留小字', (WidgetTester tester) async {
    await _pump(tester, fake()..result = const ExportEmpty());
    await tester.pumpAndSettle();

    await tester.tap(_button());
    await tester.pumpAndSettle();

    expect(
      find.textContaining('上次导出'),
      findsNothing,
      reason: '没有文件可找，留一行「上次导出」是撒谎',
    );
  });

  testWidgets('导出失败 ⇒ 不覆盖上一次**真实成功**的留痕', (
    WidgetTester tester,
  ) async {
    final FakeExport export = fake();
    await _pump(tester, export);
    await tester.pumpAndSettle();

    await tester.tap(_button());
    await tester.pumpAndSettle();
    final String first = tester
        .widget<Text>(find.textContaining('上次导出：'))
        .data!;

    // 再点一次，这次失败（文件被占用是真实场景）。
    // ⚠️ 必须先让上一条 SnackBar 退场 —— 它会盖住按钮，tap 落不上去
    // （落不上去 ⇒ 这条断言就变成「什么都没发生」的空断言）。
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    export.result = const ExportFailed('文件正被别的程序占用。请关掉 Excel 再导出。');
    await tester.tap(_button());
    await tester.pumpAndSettle();

    expect(export.calls, 2, reason: '确认第二次导出**真的发生了**，不是没点到');

    expect(
      tester.widget<Text>(find.textContaining('上次导出：')).data,
      first,
      reason: '失败不能把上一次真实成功的留痕抹掉',
    );
  });

  testWidgets('超大字号（2.0）+ 窄窗 ⇒ 表头不溢出', (WidgetTester tester) async {
    // 本轮 AppBar 溢出事故的护栏：小字**加在按钮下方**后，任何容器都要
    // 装得下。2.0 档 + 420 宽是最坏组合。
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _pump(tester, fake(), width: 420);
    await tester.pumpAndSettle();

    await tester.tap(_button());
    await tester.pumpAndSettle();

    expect(find.textContaining('上次导出：'), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: '5c-2 的小字把表头撑爆过（AppBar 硬 56px ⇒ 溢出 8px）',
    );
  });
}
