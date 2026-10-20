/// 导出用的「给人看」形态（§AF：列名与值都要用业务语言，不是字段名）。
///
/// 这里是**词汇表**：日期怎么摆、状态怎么叫、对方为空怎么写。
/// 放纯 Dart 的理由与备份的文案一样 —— 判断与措辞不进 UI，`dart test` 才钉得住
/// （`docs/ui_principles.md` §二：错误信息由领域层给出，UI 不造句）。
///
/// ⚠️ 金额**不要**在这里再写一份：`Money.format(cents)`（core）已经是
/// 「分 → 元」的唯一实现，重复一份早晚漂。
library;

import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 毫秒 → `2026-09-28 15:30`（**本地时间**）。
///
/// 为什么带时分（§AF 遗漏 6）：只到日的话，同一天的多张单在 Excel 里
/// 排序是随机的（Excel 稳定排序只对**相同键**有效）—— 会计按日期排一下
/// 顺序就乱了。带上时分，排序稳，而且会计不会觉得多余。
///
/// ⚠️ **适用面 = 真实时刻**（往来流水、`created_at`）。**单据的 `occurred_at`
/// 不走本函数**，走 [formatOccurredAt] —— 那一列**混着两种口径**（主单是天粒度、
/// 退货 / 收付款是精确时刻），套本函数会让主单印出假的「00:00」（真机踩过，§BG 方案甲）。
String formatDateTime(int millis) {
  final DateTime t = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${formatDate(millis)} '
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// 毫秒 → `2026-09-28`（本地时间）
String formatDate(int millis) {
  final DateTime t = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}

/// **单据的 `occurred_at` 怎么印**（#26① 裁定 Q3 乙，2026-10-18）。
///
/// 这一列**存着两套口径**（同一列、两种语义 —— 这正是 #26① 的根因）：
/// - **主单**：`occurred_at` = **当天 00:00**（开单页只能选到「日」，§BG 方案甲）
/// - **退货 / 手记收付款**：`occurred_at` = **精确时刻**（`return_service` / `settlement_service`）
///
/// 所以按数据如实印，两头都不撒谎：
/// - 落在零点 ⇒ 只印日期（**不印假的 `00:00`**，§BG 真机踩过）
/// - 有真时刻 ⇒ 印到分（否则同一天的多张单在列表里长得一模一样，
///   用户只能逐张点开才知道先后 —— 2026-10-18 的实证就是这件事）
///
/// ⚠️ 判据用 `hour/minute/second/millisecond` 全零，而不是「< 某阈值」——
/// 零点整录入的单会只印日期，那是**无害的**（它的业务时间就是那天）。
String formatOccurredAt(int millis) {
  final DateTime t = DateTime.fromMillisecondsSinceEpoch(millis);
  final bool isMidnight =
      t.hour == 0 && t.minute == 0 && t.second == 0 && t.millisecond == 0;
  return isMidnight ? formatDate(millis) : formatDateTime(millis);
}

/// 日期时间 → 文件名里的 `20260928` / `20260601`
String formatFileDate(DateTime time) =>
    '${time.year.toString().padLeft(4, '0')}'
    '${time.month.toString().padLeft(2, '0')}'
    '${time.day.toString().padLeft(2, '0')}';

/// 单据状态的中文（§AF AF-9：导出的值也要是业务语言，不能是 `confirmed`）。
///
/// ⚠️ `DocType` 自带 label（core），`DocStatus` **没有** —— 这里补一份。
/// 刻意不往 core 的枚举上加：措辞是「给人看」的口径（`settled` → 「已结清」，
/// 而不是直译的「已结算」），放展示层更好改。
String docStatusLabel(DocStatus status) => switch (status) {
  DocStatus.draft => '草稿',
  DocStatus.confirmed => '已确认',
  DocStatus.inTransit => '在途',
  DocStatus.delivered => '已送达',
  DocStatus.settled => '已结清',
  DocStatus.cancelled => '已作废',
};

/// 往来方角色的中文；多角色用「、」连接（`客户、供应商`）
String partyRolesLabel(List<PartyRole> roles) =>
    roles.map(partyRoleLabel).join('、');

String partyRoleLabel(PartyRole role) => switch (role) {
  PartyRole.supplier => '供应商',
  PartyRole.customer => '客户',
  PartyRole.carrier => '司机',
};

/// 建档**提交后**「到底发生了什么」的人话（#40① 裁定甲，2026-10-18）。
///
/// 四个入口共用（销售 / 送货 / 采购 / 往来方页）—— 各写一遍必然漂（纪律 18）。
/// 口径：**先说发生了什么，再说「不会新建第二条」** —— 用户最怕的是重档。
/// 返回 `null` = 没什么要解释的（新建了一条 / 原样返回）。
String? partyMutationNotice(PartyMutation mutation, {PartyRole? role}) {
  switch (mutation.action) {
    case PartyMutationAction.created:
    case PartyMutationAction.existing:
      return null;
    case PartyMutationAction.roleAppended:
      final String what = role == null
          ? '已按你选的角色补齐身份'
          : '已加「${partyRoleLabel(role)}」身份';
      return '已有往来方「${mutation.party.name}」，$what（不会新建第二条）';
    case PartyMutationAction.revived:
      final String extra = role == null ? '' : '并加「${partyRoleLabel(role)}」身份';
      return '「${mutation.party.name}」原来是停用的，已重新启用$extra';
  }
}

/// 建档**提交前**的内联提醒（#40①）：名称框**失焦**时查到的同名档，
/// 说清「按保存会发生什么」。
///
/// - 返回 `null` = 没有同名 ⇒ 不打扰
/// - **不拦人**：同名追加身份是既有合法设计（Z-4「绝不出现两条同名」），
///   提示只解释会发生什么，绝不弹「已有同名，确定吗」
/// - ⚠️ **只在失焦时查**（`docs/reply.md` 2026-10-18 明确要求）：`onChanged`
///   每敲一个字查一次库 + `setState`，中老年用户打字慢，会一直闪
String? partySameNameHint(
  Party? existing, {
  List<PartyRole> adding = const <PartyRole>[],
}) {
  if (existing == null) return null;
  final List<PartyRole> missing = adding
      .where((PartyRole role) => !existing.roles.contains(role))
      .toList();
  final String who = existing.roles.isEmpty
      ? '往来方'
      : existing.roles.map(partyRoleLabel).join('、');
  final StringBuffer out = StringBuffer('已有同名$who「${existing.name}」');
  if (!existing.isActive) out.write('（原来是停用的）');
  if (missing.isEmpty) {
    out.write(' —— 保存后直接用它，不会新建第二条。');
  } else {
    final String what =
        missing.map((PartyRole r) => '「${partyRoleLabel(r)}」').join('、');
    out.write(' —— 保存后会加上$what身份，不会新建第二条。');
  }
  return out.toString();
}

/// 启用 / 停用（导出里要有这一列：含停用的行要能一眼看出来，AF-12）
String activeLabel(bool isActive) => isActive ? '启用' : '停用';

/// 单据的「对方」列：没有对方时写文字，**不留空白**。
///
/// 规则与单据列表页（`documents_page.dart`）**完全一致**：
/// 销售类单 → 「散客」，其余 → 「散采」。⚠️ 两处口径必须一样，
/// 页面那边也改成调本函数（不再各写一遍）。
String documentPartyLabel(String? partyName, DocType type) {
  if (partyName != null && partyName.isNotEmpty) return partyName;
  return type == DocType.sale ? '散客' : '散采';
}
