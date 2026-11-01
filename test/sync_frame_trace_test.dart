// **同步期间帧耗时**的摘要计算（2026-11-01，用户裁定 A5 的额外要求）。
//
// 为什么只测纯函数、不测采集器本身：
// `SchedulerBinding.addTimingsCallback` 的真实回调**只有真机能给**
// （widget 测试里没有真实渲染管线），所以在测试里采集永远拿到空列表 ——
// 那样的用例只会证明「没崩」，没有信息量。
//
// 真正需要钉住的是「**一串帧耗时怎么算成结论**」：
// 分位数算错、掉帧阈值算错、格式变了导致事后 grep 不到，才是会误导决策的地方。
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/sync_frame_trace.dart';

void main() {
  group('帧耗时摘要', () {
    test('一帧都没有 ⇒ frames=0（这本身就是信号：界面被完全阻塞了）', () {
      final FrameTraceSummary s = summarizeFrames(
        <double>[],
        spanMs: 4200,
      );
      expect(s.frames, 0);
      expect(s.totalMs, 4200);
      expect(s.slowRatio, 0);
      expect(s.describe(), contains('frames=0'));
    });

    test('分位数按最近秩取（p50/p90/p99 落在真实存在的帧上）', () {
      // 1..100 ms
      final List<double> frames = <double>[
        for (int i = 1; i <= 100; i++) i.toDouble(),
      ];
      final FrameTraceSummary s = summarizeFrames(frames, spanMs: 3000);

      expect(s.frames, 100);
      // 索引 = round((n-1)*q)，取的是**下标**（0 起）⇒
      //   p50 → round(99×0.5)=50 → sorted[50]=51
      //   p90 → round(99×0.9)=89 → sorted[89]=90
      //   p99 → round(99×0.99)=98 → sorted[98]=99
      // 差 1 是下标与「第几个」的区别，不是 bug —— 这里写死口径，免得以后改算法时静默漂移。
      expect(s.p50Ms, 51);
      expect(s.p90Ms, 90);
      expect(s.p99Ms, 99);
      expect(s.totalMs, 3000);
    });

    test('掉帧按 > 16.7 ms 计数（60 Hz 一把尺子）', () {
      final FrameTraceSummary s = summarizeFrames(<double>[
        8,
        12,
        16.7, // 等于阈值 ⇒ **不算**掉帧
        16.8, // 刚过 ⇒ 算
        20,
        100,
      ], spanMs: 500);

      expect(s.frames, 6);
      expect(s.slowFrames, 3, reason: '16.8 / 20 / 100 三帧超阈值，16.7 不算');
      expect(s.slowRatio, closeTo(0.5, 1e-9));
    });

    test('describe() 的格式固定（事后要能 grep「同步帧耗时」）', () {
      final FrameTraceSummary s = summarizeFrames(<double>[10, 20, 30, 40], spanMs: 1234);
      final String line = s.describe();

      expect(line, startsWith('同步帧耗时 '));
      expect(line, contains('frames=4'));
      expect(line, contains('p50='));
      expect(line, contains('p99='));
      expect(line, contains('slow='));
      expect(line, contains('span=1234ms'));
      // 一位小数（免得日志里出现 12.299999999999999）
      expect(line, isNot(contains('9999')));
    });

    test('输入顺序不影响结果（内部要排序）', () {
      final FrameTraceSummary a = summarizeFrames(<double>[30, 10, 20], spanMs: 1);
      final FrameTraceSummary b = summarizeFrames(<double>[10, 20, 30], spanMs: 1);
      expect(a.p50Ms, b.p50Ms);
      expect(a.p99Ms, b.p99Ms);
    });

    test('默认关闭：enabled 为 false 时 start() 返回 null（零副作用）', () {
      // 没编 `--dart-define=SSZ_SYNC_FRAME_TRACE=true` ⇒ 必须完全不介入
      expect(SyncFrameTrace.enabled, isFalse, reason: '测试与生产默认都关');
      expect(SyncFrameTrace.start(), isNull);
    });
  });
}
