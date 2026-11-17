// 「进程年龄」的测试（2026-11-17 补，起因是真机「双击后 14 秒」）。
//
// ## 两件事分开钉
//
// 1. **换算必须对**（纯函数）：`DateTime` → `FILETIME` 差一秒就是差 1 亿，
//    而这种错**不会抛、不会空**，只会给出一个「看着像真的」的毫秒数 ——
//    和 `dbMb` 那次 `0.0` 一样，是**静默**的。所以硬编码参照值。
// 2. **Win32 那条路真的能拿到东西**（Windows 上非空、非负）。
//    拿不到就等于没埋点，而「拿不到」在日志里只表现为 `preMain=?`，
//    很容易被当成「这版没这功能」而不是「FFI 没走通」。
import 'dart:io';

import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  group('FILETIME 换算（纯函数）', () {
    test('1970-01-01 恰好是纪元差 —— 这是整套换算的锚点', () {
      expect(fileTimeOf(DateTime.utc(1970, 1, 1)), 116444736000000000);
    });

    test('2026-11-17 与 2000-01-01 的参照值（硬编码，别用公式自证）', () {
      expect(fileTimeOf(DateTime.utc(2026, 11, 17)), 134393472000000000);
      expect(fileTimeOf(DateTime.utc(2000, 1, 1)), 125911584000000000);
    });

    test('带时区的 DateTime 先归到 UTC 再换算', () {
      final DateTime local = DateTime.utc(2026, 11, 17).toLocal();
      expect(fileTimeOf(local), fileTimeOf(DateTime.utc(2026, 11, 17)));
    });

    test('两个时间相差 1 秒 ⇒ 1000 ms', () {
      final int a = fileTimeOf(DateTime.utc(2026, 11, 17, 10));
      final int b = fileTimeOf(DateTime.utc(2026, 11, 17, 10, 0, 1));
      expect(msBetweenFileTimes(b, a), 1000);
    });

    test('不足 1 ms 向下取整（这个数只判量级，不做四舍五入）', () {
      expect(msBetweenFileTimes(10000 + 9999, 10000), 0);
      expect(msBetweenFileTimes(10000 + 10000, 10000), 1);
    });

    test('真机那种量级：13.8 秒 = 13800 ms', () {
      final int created = fileTimeOf(DateTime.utc(2026, 11, 17, 22, 0, 0));
      final int now = fileTimeOf(DateTime.utc(2026, 11, 17, 22, 0, 13, 800));
      expect(msBetweenFileTimes(now, created), 13800);
    });
  });

  group('Win32 GetProcessTimes', () {
    test('Windows 上拿得到，且非负', () {
      final int? age = currentProcessAgeMs();
      if (!Platform.isWindows) {
        expect(age, isNull, reason: '非 Windows 一律 null（不许抛）');
        return;
      }
      expect(age, isNotNull, reason: '拿不到 ⇒ 日志里只会是 preMain=?，等于没埋点');
      expect(age, greaterThanOrEqualTo(0));
      // 测试进程刚起来，不可能已经跑了一小时 —— 顺带挡住「单位算错」（100 ns 当 ms）
      expect(age, lessThan(const Duration(hours: 1).inMilliseconds));
    });

    test('连调两次，第二次不小于第一次（时间只会往前走）', () {
      if (!Platform.isWindows) return;
      final int? first = currentProcessAgeMs();
      final int? second = currentProcessAgeMs();
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(second!, greaterThanOrEqualTo(first!));
    });
  });
}
