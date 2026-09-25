/// 金额工具。**金额一律用 `int` 分表示，禁止浮点。**
///
/// 见 `docs/data_model.md` §一 通用约定。
class Money {
  Money._();

  /// 元 → 分
  static int fromYuan(double yuan) => (yuan * 100).round();

  /// 分 → 元（仅用于展示）
  static double toYuan(int cents) => cents / 100.0;

  /// 分 → `"12.34"` / `"-12.34"`
  static String format(int cents) {
    final String sign = cents < 0 ? '-' : '';
    final int abs = cents.abs();
    return '$sign${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  }

  /// **round-half-up 整数除法**：半数**远离零**。
  ///
  /// 用于成本口径（`docs/data_model.md` §六：舍入策略 round-half-up）。
  ///
  /// 之所以自己实现而不用 `~/`：整数除法是**截断**，会让出库成本系统性偏低
  /// （例：302 / 3 → 100，少算 1 分），且出库成本写入即冻结，误差永久固化。
  ///
  /// 之所以用「远离零」而不是「向上」：出库数量为负（`quantity < 0`）时，
  /// 「向上」会让负数舍入方向与正数不一致，导致资产/负债两侧不对称。
  ///
  /// ```dart
  /// Money.divideRoundHalfUp(302, 3);   // 101  (100.666… → 101)
  /// Money.divideRoundHalfUp(300, 3);   // 100
  /// Money.divideRoundHalfUp(1, 2);     // 1    (0.5 → 1)
  /// Money.divideRoundHalfUp(-302, 3);  // -101 (远离零)
  /// ```
  static int divideRoundHalfUp(int numerator, int denominator) {
    if (denominator == 0) {
      throw ArgumentError.value(denominator, 'denominator', '除数不得为 0');
    }
    final bool negative = (numerator < 0) != (denominator < 0);
    final int n = numerator.abs();
    final int d = denominator.abs();
    final int quotient = (n * 2 + d) ~/ (d * 2);
    return negative ? -quotient : quotient;
  }
}
