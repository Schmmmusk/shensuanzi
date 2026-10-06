/// 三个开单草稿 `*DraftInvalid` 的**公共接口**（B3a，2026-10-06）。
///
/// ## 为什么需要它
///
/// B3 把「提交出口」抽成 `DocumentSink`，并把**校验失败从异常改成返回值**
/// （`DocumentSubmitFailure`，裁定 ①⑥）。于是需要一个能同时装下三种具体异常的
/// 类型 —— 把「字段级校验失败」这件事抽成接口，三个异常类各自 `implements` 它。
///
/// ⚠️ 接口**只声明 UI 真正共用的两件事**：一句汇总（日志 / 兜底提示）。
/// **字段映射留在各具体类型上**（`SaleDraftInvalid.fieldErrors` /
/// `PurchaseDraftInvalid.lineErrors` / …）—— 页面按自己的类型取，
/// 不在这里做任何统一（三个单据的字段枚举本就不同，强行统一只会糊掉它们）。
library;

/// 字段级校验失败（`SaleDraftInvalid` / `PurchaseDraftInvalid` /
/// `DeliveryDraftInvalid` / `ReturnDraftInvalid` … 的公共父接口）。
abstract class DraftInvalidException implements Exception {
  /// 拼成一句话（日志 / 汇总提示用）
  String get summary;
}
