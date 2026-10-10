/// **业务拒绝**：用户**能改**，所以必须告诉他改什么（#22 裁定，2026-10-09）。
///
/// 与 [RejectCode] 分开一个文件，只为一件事：本类型要用
/// `sync/sync_failure.dart` 的 [malformedSyncRequestReason]，而那个文件又要用
/// [RejectCode] —— 放一起就是**循环 import**。这里 `rules → {reject_code, sync}`，
/// 单向。
library;

import '../reject_code.dart';
import '../sync/sync_failure.dart';

/// 规则层的**业务拒绝**（用户能改）。
///
/// ## 为什么用异常而不是直接 `return RuleOutcome`
///
/// 各条规则跑在**一个事务**里，而且**边算边写**（先插流水、后算分摊）。
/// 校验命中时若直接 `return`，**已经写进去的行会被提交** —— 只有 `throw`
/// 才能让 `Db.transaction` 回滚。所以业务拒绝也**抛**，只是抛的是本类型：
/// `RuleEngine.dispatch` 认得它，转成 `RuleOutcome.rejected(reason, code:)`。
///
/// | 抛什么 | 谁认 | 结果 |
/// |---|---|---|
/// | [RuleRejection] | `dispatch` 的 `on RuleRejection` | 用户可见的中文（**说怎么办**） |
/// | `StateError`（不变量破坏 / 协议违反） | `dispatch` 的兜底 catch | 细节**只进日志**，回执给通用中文 |
class RuleRejection implements Exception {
  /// 业务拒绝：`reason` 是给用户看的中文，**要写「怎么办」**（`ui_principles §五`）。
  const RuleRejection(this.reason, {required this.code, this.detail});

  /// 协议违反（客户端 bug）：文案恒为 [malformedSyncRequestReason]。
  ///
  /// 用这个工厂而不是手写文案，是为了让「协议违反却把细节写进 `reason`」
  /// **不可表示**（与 `SyncResponse.malformed` 同一口径）。
  /// 诊断细节走 [detail] —— 它**只进日志**（`dispatch` 转记 `onInternalError`）。
  const RuleRejection.protocol(this.code, {this.detail})
    : reason = malformedSyncRequestReason;

  final String reason;
  final RejectCode code;

  /// **诊断细节**（例：哪个 id 没找到）—— 恒不进 `reason`，只由
  /// `RuleEngine.dispatch` 送进 `onInternalError`。
  ///
  /// 没有它的话，「不把细节写进 reason」就退化成「细节丢失」。
  final String? detail;

  @override
  String toString() => 'RuleRejection(${code.wire}: $reason)';
}
