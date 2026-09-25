// 工具层：金额口径与 ID。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

void main() {
  group('Money.format', () {
    test('正数补零到两位', () {
      expect(Money.format(0), '0.00');
      expect(Money.format(5), '0.05');
      expect(Money.format(50), '0.50');
      expect(Money.format(1234), '12.34');
    });

    test('负数带符号', () {
      expect(Money.format(-1234), '-12.34');
      expect(Money.format(-5), '-0.05');
    });
  });

  group('Money.fromYuan / toYuan', () {
    test('四舍五入到分', () {
      expect(Money.fromYuan(12.34), 1234);
      expect(Money.fromYuan(0.005), 1);
      expect(Money.fromYuan(-12.34), -1234);
    });

    test('往返一致', () {
      expect(Money.toYuan(1234), closeTo(12.34, 1e-9));
      expect(Money.fromYuan(Money.toYuan(999)), 999);
    });
  });

  group('Money.divideRoundHalfUp（成本口径，docs/data_model.md §六）', () {
    test('非半数向下', () {
      expect(Money.divideRoundHalfUp(300, 3), 100);
      expect(Money.divideRoundHalfUp(301, 3), 100);
    });

    test('半数进位（远离零）', () {
      expect(Money.divideRoundHalfUp(1, 2), 1);
      expect(Money.divideRoundHalfUp(3, 2), 2);
    });

    test('超过半数进位 —— 整数除法 `~/` 会在这里出错', () {
      expect(302 ~/ 3, 100, reason: '截断');
      expect(Money.divideRoundHalfUp(302, 3), 101, reason: '四舍五入');
    });

    test('负数方向与正数对称（远离零）', () {
      expect(Money.divideRoundHalfUp(-302, 3), -101);
      expect(Money.divideRoundHalfUp(-300, 3), -100);
      expect(Money.divideRoundHalfUp(-1, 2), -1);
    });

    test('分子为 0', () {
      expect(Money.divideRoundHalfUp(0, 7), 0);
    });

    test('分母为负时符号正确', () {
      expect(Money.divideRoundHalfUp(302, -3), -101);
    });

    test('除数为 0 抛 ArgumentError', () {
      expect(() => Money.divideRoundHalfUp(1, 0), throwsArgumentError);
    });
  });

  group('newId（UUIDv7）', () {
    test('版本位为 7', () {
      for (int i = 0; i < 100; i++) {
        expect(newId()[14], '7');
      }
    });

    test('不重复', () {
      final Set<String> ids = <String>{for (int i = 0; i < 2000; i++) newId()};
      expect(ids.length, 2000);
    });

    test('时间戳前缀单调不减（毫秒粒度）', () {
      // ⚠️ UUIDv7 的时间戳精度是**毫秒**：同一毫秒内生成的 id，其顺序由随机尾巴决定，
      // 因此**不能**断言相邻两次调用的字典序（原先那条断言就是这么写错的）。
      int previous = -1;
      for (int i = 0; i < 300; i++) {
        final int ms = uuidV7TimestampMs(newId());
        expect(ms, greaterThanOrEqualTo(previous));
        previous = ms;
      }
    });

    test('跨毫秒时字典序严格递增', () async {
      final String first = newId();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final String second = newId();
      expect(second.compareTo(first), greaterThan(0));
    });
  });
}

/// 从 UUIDv7 字符串取前 48 位时间戳（毫秒）。
///
/// 格式 `xxxxxxxx-xxxx-7xxx-yxxx-xxxxxxxxxxxx` —— 时间戳占前 12 个十六进制字符
/// （前 8 位 + 连字符后的 4 位）。
int uuidV7TimestampMs(String id) =>
    int.parse(id.substring(0, 8) + id.substring(9, 13), radix: 16);
