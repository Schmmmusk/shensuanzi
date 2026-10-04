/// 整单让价**分摊**（v3，§BD·九 #3 的裁定：差额超过最后一行折前金额时
/// 「由 UI 从最后一行向前分摊到多行」—— 本函数就是那个分摊，**唯一实现**）。
///
/// ## 为什么从最后一行向前
///
/// 与「整单议价记在最后一行」的默认起点一致（§BA·一 / data_model §3.2 第 6 条）：
/// 用户的心智是「一共 100，收 98」—— 最后那行少收点最自然。
///
/// ## 前置
///
/// `discountCents ≤ Σ grossAmounts`（整单差额不会超过整单折前金额 ——
/// 否则用户在「倒贴钱」，开单页合计栏会先拦）。违反 ⇒ `ArgumentError`。
/// 每行结果都满足 `0 ≤ discount ≤ 本行折前金额`（由构造保证，不需要调用方再钳）。
///
/// 纯函数、无状态 —— `dart test` 可覆盖，UI 只摆结果。
library;

/// 把 [discountCents] 摊到各行，返回与 [grossAmounts] **等长**的逐行让价（分）。
///
/// 例：`spreadDiscount(grossAmounts: [5000, 3000], discountCents: 200)`
/// ⇒ `[0, 200]`（最后一行全担）；
/// `spreadDiscount(grossAmounts: [5000, 3000], discountCents: 6000)`
/// ⇒ `[3000, 3000]`（最后一行担满，余量向前摊）。
List<int> spreadDiscount({
  required List<int> grossAmounts,
  required int discountCents,
}) {
  if (discountCents < 0) {
    throw ArgumentError('让价不能是负数：$discountCents');
  }
  int total = 0;
  for (final int gross in grossAmounts) {
    total += gross;
  }
  if (discountCents > total) {
    throw ArgumentError(
      '让价 $discountCents 超过整单折前金额 $total —— '
      '这不可能是正常的议价（用户在倒贴钱），上游合计栏应先拦',
    );
  }
  final List<int> out = List<int>.filled(grossAmounts.length, 0);
  int remaining = discountCents;
  for (int i = grossAmounts.length - 1; i >= 0 && remaining > 0; i--) {
    final int take = grossAmounts[i] < remaining ? grossAmounts[i] : remaining;
    out[i] = take;
    remaining -= take;
  }
  return out;
}
