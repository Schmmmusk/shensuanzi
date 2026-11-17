// 「启动耗时那一行」的**机械保证**（2026-11-17）。
//
// ## 为什么需要它
//
// `StartupTrace.reportLine` 只有在 `main()` **第一行**先起表（`startClock()`）时才有意义。
// 少了那一句，日志**照样会写**，只是数字变成 `elapsed=0ms` —— 看起来完全正常，
// 比「没有日志」更糟：会让人以为启动很快。
// 这类「删一行还静默正确」的东西必须有钳子（与 `save_lock_guard_test.dart` 同一思路）。
//
// ## 挡什么 / 不挡什么
//
// 挡：`main` 里的起表被删、或被挪到耗时操作之后；`app` 里不再写这一行。
// 挡不住：写在了**错误的时机**（例如早于数据就绪）—— 那要靠真机日志看数字。
//
// ⚠️ 读的是仓库根相对路径 ⇒ 工作目录必须是仓库根（既有先例：`save_lock_guard_test.dart`）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final File file = File(path);
  expect(
    file.existsSync(),
    isTrue,
    reason: '读不到 $path —— 钳子失效（工作目录应为仓库根）',
  );
  return file.readAsStringSync();
}

void main() {
  test('main.dart：startClock() 必须在 T0 埋点**之前**（正式包靠它起表）', () {
    final String src = _read('lib/main.dart');
    final int clock = src.indexOf('StartupTrace.startClock()');
    final int t0 = src.indexOf("StartupTrace.mark('T0_main')");

    expect(
      clock,
      greaterThan(-1),
      reason: 'main() 里没有 StartupTrace.startClock() —— '
          '那行日志会永远写 elapsed=0ms（看着像"启动很快"）',
    );
    expect(t0, greaterThan(-1), reason: 'T0 埋点不见了（那是另一套，不是这条要守的）');
    expect(
      clock,
      lessThan(t0),
      reason: '起表必须在 T0 之前 —— 否则计时从更晚的点起算，数字偏小',
    );
  });

  test('app.dart：数据就绪后写一行，且能按「启动」筛出来', () {
    final String src = _read('lib/src/app.dart');
    expect(
      src.contains('StartupTrace.reportLine('),
      isTrue,
      reason: '「启动完成」那行被删了 —— 正式包发生「打开很慢」时就没有现场了',
    );
    expect(
      src.contains("level: '启动'"),
      isTrue,
      reason: '日志级别要固定成「启动」，否则在几百行日志里筛不出来',
    );
  });
}
