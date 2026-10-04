// 整单让价分摊（v3，§BD·九 #3）—— 唯一实现 spreadDiscount 的全分支。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

void main() {
  group('spreadDiscount（整单让价分摊）', () {
    test('差额 ≤ 最后一行 ⇒ 最后一行全担（默认起点）', () {
      expect(
        spreadDiscount(grossAmounts: <int>[5000, 3000], discountCents: 200),
        <int>[0, 200],
      );
    });

    test('差额超过最后一行 ⇒ 向前摊，每行钳在自己折前金额内', () {
      expect(
        spreadDiscount(grossAmounts: <int>[5000, 3000], discountCents: 6000),
        <int>[3000, 3000],
      );
      expect(
        spreadDiscount(grossAmounts: <int>[5000, 3000], discountCents: 7000),
        <int>[4000, 3000],
      );
    });

    test('全部担满 ⇒ 每行 = 折前金额（整单免单的边界）', () {
      expect(
        spreadDiscount(grossAmounts: <int>[5000, 3000], discountCents: 8000),
        <int>[5000, 3000],
      );
    });

    test('单行 ⇒ 全担在该行', () {
      expect(
        spreadDiscount(grossAmounts: <int>[5000], discountCents: 200),
        <int>[200],
      );
    });

    test('0 让价 ⇒ 全 0', () {
      expect(
        spreadDiscount(grossAmounts: <int>[5000, 3000], discountCents: 0),
        <int>[0, 0],
      );
    });

    test('负数 / 超整单 ⇒ ArgumentError（上游合计栏应先拦）', () {
      expect(
        () => spreadDiscount(
          grossAmounts: <int>[5000, 3000],
          discountCents: -1,
        ),
        throwsArgumentError,
      );
      expect(
        () => spreadDiscount(
          grossAmounts: <int>[5000, 3000],
          discountCents: 8001,
        ),
        throwsArgumentError,
      );
    });
  });
}
