// 全时段帧耗时埋点（`SSZ_FRAME_TRACE`）的测试。
//
// 与 `sync_frame_trace` 的测试分工：那个测「同步窗口内的分位算法」，
// 这里测**这一层新增的东西** —— 三列（total / build / raster）的拼行格式，
// 以及「开关关着时零副作用」。分位算法直接复用 `summarizeFrames`，不重复测。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/frame_trace.dart';
import 'package:shensuanzi/src/sync_frame_trace.dart';

void main() {
  test('kFrameTrace 在测试里是 false（没传 dart-define）', () {
    expect(kFrameTrace, isFalse);
  });

  test('关闭时 attach 不装任何东西（可重复调用、不抛）', () {
    FrameTrace.attach(null);
    FrameTrace.attach(r'F:\神算子数据\shensuanzi.db');
    // 关着时 `attach` 直接返回；这里能走到下一行且不抛，就是「零副作用」
    expect(true, isTrue);
    FrameTrace.detachForTest();
  });

  test('frameCostLine：三列都在、是合法 JSON、一条不含换行', () {
    final DateTime now = DateTime(2026, 11, 10, 19, 35, 40);
    final String line = frameCostLine(
      now: now,
      winMs: 5000,
      // 三列故意给不同分位：判据就是「哪一列高」
      total: summarizeFrames(<double>[4, 6, 8, 40], spanMs: 5000),
      build: summarizeFrames(<double>[1, 2, 3, 5], spanMs: 5000),
      raster: summarizeFrames(<double>[20, 30, 40, 60], spanMs: 5000),
    );

    expect(line, isNot(contains('\n')), reason: 'JSONL 靠换行分条');
    final Map<String, dynamic> json = jsonDecode(line) as Map<String, dynamic>;
    expect(json['kind'], 'frames');
    expect(json['ts'], now.toIso8601String());
    expect(json['winMs'], 5000);

    final Map<String, dynamic> build = json['build'] as Map<String, dynamic>;
    final Map<String, dynamic> raster = json['raster'] as Map<String, dynamic>;
    expect(build['n'], 4);
    expect(build['p99'], 5.0);
    expect(raster['p99'], 60.0);
    expect(
      (raster['slow'] as int) > (build['slow'] as int),
      isTrue,
      reason: 'raster 那列全是长帧 —— 这种形状就该判「画得慢」而不是「算得慢」',
    );
  });

  test('frameCostLine：零帧窗口也是合法 JSON（不许拼出 ",]"）', () {
    final Map<String, dynamic> json =
        jsonDecode(
              frameCostLine(
                now: DateTime(2026),
                winMs: 5000,
                total: summarizeFrames(<double>[], spanMs: 5000),
                build: summarizeFrames(<double>[], spanMs: 5000),
                raster: summarizeFrames(<double>[], spanMs: 5000),
              ),
            )
            as Map<String, dynamic>;
    expect((json['total'] as Map<String, dynamic>)['n'], 0);
  });
}
