// 未结金额（债权口径）—— **唯一来源**（业务审查 §3.4 / §3.7 P2 #1，2026-10-24 裁定「零 schema」）。
//
// ## 为什么要有这个文件
//
// 「还欠多少」这件事在四处出现过，其中三处**漏了退货冲减**：
//
// | 位置 | 公式 |
// |---|---|
// | `document_dao` 未结清筛选（SQL） | 总额 − 已核销 − 退货冲减 ✅ |
// | `settlement_service.unsettledCentsOf`（封顶口径） | 总额 − 已核销 − 退货冲减 ✅ |
// | `sale_service` / `purchase_service`（保存提示） | 总额 − 已收 ❌ |
// | `rule_engine` 校验文案 | 总额 − 已核销 ❌ |
//
// ⇒ 「部分退货 + 部分收款」的单，列表说欠 20、保存提示说欠 50。
//
// 本文件把**债权口径**收成一个纯函数 + 一段 SQL 片段，并有一条对拍测试
// （`test/unsettled_test.dart`）保证两者逐行相等 —— 改一处必须改另一处。
//
// ⚠️ **与 `SettlementService.unsettledCentsOf` 的区别**（两个都要留着）：
// - 本文件 = **「这张单还欠多少钱」**（销售 / 采购 / 送货；退货单本身 = 0）；
// - 服务层那个 = **「核销封顶用多少」**（退货单读作「未退款额」= 总额 − 已退）。
//   退货单是**冲减方**，它自己的欠款由原单的 `returnedAmount` 表达，
//   所以在「还欠多少」这个问题上它恒为 0（用户 2026-10-24 明确）。
import '../models/document.dart';

/// **未结金额（债权口径）** —— 列表 / 详情 / 保存提示 / 规则文案**四处共用**。
///
/// | `doc_type` | 结果 |
/// |---|---|
/// | `sale` / `purchase` / `delivery` | `总额 − 已核销 − 该单累计退货冲减`（**可为负**） |
/// | `sale_return` / `purchase_return` | **0** —— 冲减方，欠款由原单表达 |
/// | `receipt` / `payment` | **0** —— 流水本身，不产生债权债务 |
/// | `stocktake` | **0** |
/// | 任意类型 `cancelled` | **0** —— 作废单不算欠钱 |
///
/// **不 clamp 到 0**：负数是真实信号（退得比收得多 ⇒ 「多收 ¥X」，见
/// `docs/reply.md` 2026-10-24）。要展示「欠款不会小于 0」的旧语义用
/// `SettlementService.unsettledForDisplayCentsOf`。
int outstandingCentsOf({
  required DocType docType,
  required DocStatus status,
  required int totalAmount,
  required int paidAmount,
  required int returnedAmount,
}) {
  if (status == DocStatus.cancelled) return 0;
  switch (docType) {
    case DocType.sale:
    case DocType.purchase:
    case DocType.delivery:
      return totalAmount - paidAmount - returnedAmount;
    case DocType.saleReturn:
    case DocType.purchaseReturn:
    case DocType.receipt:
    case DocType.payment:
    case DocType.stocktake:
    case DocType.transfer: // v1 一律拒绝（`Agents.md`），留着只为穷尽枚举
      return 0;
  }
}

/// 与 [outstandingCentsOf] **逐字同形**的 SQL 片段（未结清筛选用）。
///
/// [doc] 是 `documents` 的表别名；[returned] 是「该单累计退货冲减」的表达式
/// （`document_dao` 里是 `COALESCE(r.rsum, 0)`，来自 settlements 汇总的 LEFT JOIN）。
///
/// ⚠️ 改这里必须同步改 [outstandingCentsOf]，对拍测试会红。
String outstandingAmountSql({
  String doc = 'd',
  String paid = 'd.paid_amount',
  String returned = 'COALESCE(r.rsum, 0)',
}) => '($doc.total_amount - $paid - $returned)';
