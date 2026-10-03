/// 超收（找零）的**口径与文案** —— `docs/reply_review.md` §AX·一（2026-10-02 裁定）。
///
/// ## 核心判断（**不变，且不该推翻**）
///
/// **落库金额永远 = 应收 / 未收额。** 用户多给的部分**不是入账**，
/// 是**找零**（现金箱内部的物理流动）—— 不进 `immediate_payments`、
/// 不落库、不引入「找零」科目。这是 §AJ·AI-4 的判断，2026-10-02 复核**维持**。
///
/// ## 变的只是交互（方案 3甲）
///
/// | | 旧行为 | 新行为 |
/// |---|---|---|
/// | 填的 > 应收 | **报错拦住**（"请改小"） | **不拦** —— 按应收折算入账 |
/// | 告知 | 一条错误文案 | **两处提前说清**：输入时内联 + 提交按钮文字 |
///
/// ## ⚠️ 本类不是装饰，是裁定的组成部分
///
/// 裁定原文写明 3甲 成立的**前提**：用户提交后**必须被明确告知「记了多少」**。
/// 否则就退回到当初否掉的那个坑 —— **老板以为记了 100**（应收平白被冲）。
/// 所以 [notice] / [actionLabel] 与折算逻辑放在**同一个类**里，
/// **不允许 UI 各写一份文案**（两处措辞必然漂移）。
///
/// **三处使用**：开单页（「顾客给了」/ 收款框）、核销对话框（本次收付金额）。
library;

import '../util/money.dart';

/// 一次「填的金额 vs 应收」的折算结论。
///
/// 纯粹的**值对象 + 纯函数** —— 不碰磁盘、不碰 UI，可 `dart test` 钉住。
class Overpay {
  const Overpay({required this.givenCents, required this.dueCents});

  /// 用户填的金额（开单页的「顾客给了」/ 核销页的「本次收付金额」）。
  ///
  /// **不要求**已校验：非正数时 [hasChange] 恒 `false`，[recordedCents]
  /// 原样返回（＝不参与折算）。
  final int givenCents;

  /// 应收 / 未收额。
  final int dueCents;

  /// 是否**超收**（= 需要告知找零）。非正数的 [givenCents] 一律不算超收。
  bool get hasChange => givenCents > dueCents;

  /// **入账金额**（分）—— **永远不超过应收**。
  int get recordedCents => hasChange ? dueCents : givenCents;

  /// **找零**（分）—— 只有超收才有意义，否则 `0`。
  int get changeCents => hasChange ? givenCents - dueCents : 0;

  /// 输入时的**内联告知**（橙色，**不是错误**）；未超收 ⇒ `null`（不打扰）。
  ///
  /// > 实收 ¥100，其中 ¥93 入账、找零 ¥7
  ///
  /// [paidVerb]：收款 = `'收'`（默认），付款 = `'付'` —— 只有第一个字不同。
  String? notice({String paidVerb = '收'}) => hasChange
      ? '实$paidVerb ¥${Money.format(givenCents)}，'
            '其中 ¥${Money.format(recordedCents)} 入账、'
            '找零 ¥${Money.format(changeCents)}'
      : null;

  /// 提交按钮文字 —— **用户动作的最终确认**（裁定原文）；未超收 ⇒ `null`
  /// （调用方用默认的「保存」/「确认收款」）。
  ///
  /// > 记 ¥93 并找零 ¥7
  ///
  /// 措辞对收 / 付**通用**（不说「收」也不说「付」）。
  String? get actionLabel => hasChange
      ? '记 ¥${Money.format(recordedCents)} 并找零 ¥${Money.format(changeCents)}'
      : null;

  /// 保存成功后 SnackBar 里那半句；未超收 ⇒ `null`（调用方拼接时跳过）。
  ///
  /// > 记账 ¥93（找零 ¥7）
  ///
  /// 这是「两处告知」的**第二处**（第一处是 [notice] / [actionLabel]）——
  /// 用户如果只记得住一句话，应当记住的是「**记了多少**」。
  String? get savedNote {
    final String text = savedNoteOf(
      recordedCents: recordedCents,
      changeCents: changeCents,
    );
    return text.isEmpty ? null : text;
  }

  /// [savedNote] 的**静态形式** —— UI 手上只有 `SaleSaved`（没有 given/due）时用它，
  /// 于是「记了多少、找了多少」这句话**全项目只有一个出处**。
  static String savedNoteOf({
    required int recordedCents,
    required int changeCents,
  }) => changeCents > 0
      ? '记账 ¥${Money.format(recordedCents)}'
            '（找零 ¥${Money.format(changeCents)}）'
      : '';

  /// 把**一串**要落库的金额按**总额上限** [totalCents] **逐行钳制**
  /// （返回与入参**等长**的列表）。用于开单页的多个收款行。
  ///
  /// 算法：顺着走，每行取 `min(本行, 剩余)`，剩余递减 ——
  /// 于是「合计不超过应收」由构造保证，且**前面的行优先满足**
  /// （与用户从上往下填的心智一致）。
  ///
  /// ⚠️ 只钳**最后一行**是不够的：多行时前面几行本身就可能已超。
  ///
  /// 例：`clamp([10000], 9300) => [9300]`；`clamp([5000, 5000], 9300) => [5000, 4300]`。
  static List<int> clamp(List<int> wanted, int totalCents) {
    final List<int> out = <int>[];
    int remaining = totalCents < 0 ? 0 : totalCents;
    for (final int want in wanted) {
      final int want0 = want < 0 ? 0 : want;
      final int take = want0 < remaining ? want0 : remaining;
      out.add(take);
      remaining -= take;
    }
    return out;
  }
}

