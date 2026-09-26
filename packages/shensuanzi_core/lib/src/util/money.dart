/// 金额工具。**金额一律用 `int` 分表示，禁止浮点。**
///
/// 见 `docs/data_model.md` §一 通用约定。
class Money {
  Money._();

  /// 元 → 分
  static int fromYuan(double yuan) => (yuan * 100).round();

  /// 解析**用户输入的「元」字符串** → 分；不合法返回 `null`。
  ///
  /// ⚠️ **刻意不经过 `double`**：`double.parse('1.005') * 100` 得到的是
  /// `100.49999999999999`，四舍五入后与「1.005 元 = 1.01 元」的直觉不符。
  /// 这里按小数点切分后用整数拼，**误差为零**。
  ///
  /// 接受：`12` / `12.3` / `12.34` / `.5` / `-12.34` / 前后带空格；
  /// 拒绝（返回 `null`）：空串、多个小数点、非数字、**超过两位小数**、
  /// 位数过长（防 `int.parse` 溢出）。
  ///
  /// 符号由这里保留 —— 「售价不能为负」是**业务校验**的事，不是解析的事。
  static int? tryParseYuan(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return null;

    final bool negative = text.startsWith('-');
    final String body = (negative || text.startsWith('+'))
        ? text.substring(1)
        : text;
    if (body.isEmpty) return null;

    final int dot = body.indexOf('.');
    if (dot != body.lastIndexOf('.')) return null; // 多个小数点

    final String whole = dot < 0 ? body : body.substring(0, dot);
    final String fraction = dot < 0 ? '' : body.substring(dot + 1);
    if (whole.isEmpty && fraction.isEmpty) return null; // 只有一个 "."
    if (fraction.length > 2) return null; // 金额最小到分
    if (whole.length > 15) return null; // 防 int 溢出
    if (!_isDigits(whole) || !_isDigits(fraction)) return null;

    final int yuanPart = whole.isEmpty ? 0 : int.parse(whole);
    final int centPart = fraction.isEmpty
        ? 0
        : int.parse(fraction.padRight(2, '0'));
    final int cents = yuanPart * 100 + centPart;
    return negative ? -cents : cents;
  }

  static bool _isDigits(String text) {
    for (int i = 0; i < text.length; i++) {
      final int code = text.codeUnitAt(i);
      if (code < 0x30 || code > 0x39) return false;
    }
    return true; // 空串视为「这半边没写」，由调用方按需处理
  }

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
