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
