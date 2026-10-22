/// **主数据「停用 / 恢复」的统一安全等级**（2026-10-22，§CV·八十三 批 2 第 9/10 条）。
///
/// ## 收敛前的三种后果（同一个词，三种体验）
///
/// | 页 | 停用时的行为 |
/// |---|---|
/// | 商品 | 直接执行 + 「撤销」SnackBar |
/// | 往来方 | **只有余额非 0 才确认**，确认后无撤销 |
/// | 账户 | **既不确认也不撤销** —— 账户里有钱也能一键停用且无退路 |
///
/// 中老年用户学的是「词 → 后果」的固定映射，同一个「停用」三种后果 = 三种教学成本。
///
/// ## 收敛后的规则（`ui_principles.md` §1.2/§1.3 的判据）
///
/// > **不可逆才弹窗，其余内联 + 撤销。**
///
/// - **有未结清的余额** ⇒ 先确认（说清「停用后不会出现在选择器里，但账还在」）；
/// - **余额为 0** ⇒ 直接执行 + 「撤销」SnackBar（6 秒内可反悔）。
///
/// 三条都走这里，改规则只改这一个文件。
library;

import 'package:flutter/material.dart';

/// 停用前的确认（仅在**有余额**时弹）。返回 `true` = 继续停用。
///
/// [subject] 是「往来方 / 账户」这类称呼；[balanceCents] 是未结清余额（可负）。
Future<bool> confirmDisableWithBalance(
  BuildContext context, {
  required String name,
  required String subject,
  required String title,
  required int balanceCents,
  required String balanceLabel,
}) async {
  if (balanceCents == 0) return true;
  final bool? sure = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(
        '$name 现在还有$balanceLabel ¥${_yuan(balanceCents.abs())}。\n\n'
        '停用后这个$subject不会再出现在开单的选择器里；'
        '但账不会消失 —— 列表里仍然会显示（标着「已停用」），'
        '想接着用，点「恢复」就行。',
        style: const TextStyle(height: 1.8),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('还是停用'),
        ),
      ],
    ),
  );
  return sure == true;
}

/// 停用 / 恢复之后的「撤销」提示（统一文案与时长）。
void showDisableUndoBar(
  BuildContext context, {
  required String message,
  required VoidCallback onUndo,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(label: '撤销', onPressed: onUndo),
    ),
  );
}

/// 分 → 「12.34」（不带 ¥，调用方拼）
String _yuan(int cents) {
  final int yuan = cents ~/ 100;
  final int fen = cents % 100;
  return fen == 0 ? '$yuan' : '$yuan.${fen.toString().padLeft(2, '0')}';
}
