// 「忙碌态先画出来」的护栏（2026-11-09，用户实测「点了没反应 → 假死 → 忽然好了」）。
//
// 现场：26.4 万单的库，点「导出」后界面冻 4.4 秒（查库 1.7 s + 拼表 2.0 s +
// 拼 CSV 0.6 s，全在主 isolate）。`setState(() => _busy = true)` 只是标记重建，
// 帧要等当前同步块跑完才画 ⇒「导出中…」永远看不到。
//
// 这条用例数**帧**：导出真正开始时，必须已经画过至少一帧。
// 判据与机器快慢无关 —— 没有 `letBusyStatePaint()` 时它是 0。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/export_button.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

void main() {
  testWidgets('导出：忙碌态先画出来，再开始干重活', (WidgetTester tester) async {
    int frames = 0;
    tester.binding.addPersistentFrameCallback((_) => frames++);
    int framesWhenExportStarted = -1;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExportButton(
            label: '导出',
            export: () async {
              framesWhenExportStarted = frames;
              return const ExportSuccess(path: r'D:\导出\x.csv', rowCount: 1);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final int framesBeforeTap = frames;

    await tester.tap(find.byType(ExportButton));
    await tester.pumpAndSettle();

    expect(
      framesWhenExportStarted,
      greaterThan(framesBeforeTap),
      reason:
          '导出开始时必须已经画过至少一帧 —— 否则「导出中…」永远看不到，'
          '用户只会觉得点了没反应（实际帧数：$framesWhenExportStarted，'
          '点击前：$framesBeforeTap）',
    );
  });
}
