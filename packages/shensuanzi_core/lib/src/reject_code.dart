/// 拒绝原因码（wire 字段名 `reason_code`，`docs/sync_protocol.md` §8.5）。
///
/// ## 为什么要有它（#21 + #22 裁定，2026-10-09）
///
/// 用户可见的 `reason` 是**中文**，而中文是给人看的、**不能拿来判分支**：
///
/// 1. **测试**：15+ 条 `contains('中文')` 断言，一旦文案改通用就**同时变绿**
///    —— 某个分支的逻辑被写进另一个分支，没有测试能发现（裁定 §二 的原话：
///    「会让测试退化成冒烟测试」）；
/// 2. **客户端**：`sync_protocol.md §8.5` 早就要求「把被拒绝的原因与引用的主数据 id
///    关联起来」，而用中文做这件事等于解析自然语言。
///
/// ⇒ 把**机读**与**人读**分开：`reason_code`（本枚举）给测试与客户端分类，
/// `reason` 给人看。
///
/// ## 三类，两套措辞
///
/// | 类 | 用户能做什么 | `reason` 写什么 |
/// |---|---|---|
/// | **协议违反**（前 12 个） | 什么都不能（是**客户端实现的 bug**） | 通用中文（`malformedSyncRequestReason`），细节走主机日志 |
/// | **落库失败**（4 个） | 什么都不能（主机侧状态） | 分类中文（`syncFailureReason`） |
/// | **规则拒绝**（3 个） | **见 [RuleRejectKind] 的分界** | 业务拒绝写「怎么办」；内部 bug 写通用中文 |
///
/// ## 判据（`ui_principles.md §五`）
///
/// **用户能不能做点什么** —— 不是「文案里有没有术语」。
/// `'数量必须为正数'` 不含术语，但用户改不了（界面上那个框早拦了）⇒ 它是**内部 bug**，
/// 不该出现在回执里；而 `'累计退货量超过原单量'` 用户**能改**（少退一点）⇒ 必须说清楚。
///
/// ⚠️ **不留伞码**（裁定 §三）：伞码的诱惑是「不知道该分几类」；而
/// 「不能做 / 能做」这条判据已经给出了边界。同理，本表里**没有** `rule_rejected`
/// 这种不上不下的层级。
library;

/// 拒绝原因码。`wire` 值即 `reason_code` 字段的字面量（snake_case，
/// 与 §8.5 既有的 `unknown_action` / `return_exceeds_original` 同风格）。
///
/// ⚠️ **只增不改**：`wire` 值是**协议**，客户端可能按它分支（改它 = 破坏兼容）。
enum RejectCode {
  // ---------------------------------------------------------------- 协议违反
  //
  // 全是**客户端实现的 bug**：用户看了也修不了 ⇒ `reason` 只有通用中文，
  // 诊断细节走 `onInternalError` 进主机日志（`malformedSyncRequestReason`）。

  /// 表不在可写白名单（`SyncWhitelist`）／该 op 不支持这张表
  notWritableTable('not_writable_table'),

  /// payload 含协议外的字段
  unknownField('unknown_field'),

  /// payload 含**不可写列**（主机专属列；`deleteMasterData` 只允许 `id` 同属此类）
  unwritableColumn('unwritable_column'),

  /// **顶层 payload 键**缺失（`payload.document` / `base_version` / `action`…）。
  ///
  /// ⚠️ **与 [fieldTypeMismatch] 是「层次」关系，不是重叠**（§CV·十九 裁定）：
  /// 本码管**结构**（键在不在），那条管**内容**（值 / 类型对不对）。
  /// 「键在不在」⇒ 本码；「键在但值或内容不符」⇒ `fieldTypeMismatch`。
  missingField('missing_field'),

  /// **键存在，但值类型 / 内容不符**（`occurred_at` 不是整数 / `document` 不是对象 /
  /// `lines` 元素缺 `id`…）—— **含嵌套对象内部的字段**。
  ///
  /// ⚠️ 边界见 [missingField]：`document` **内部**字段缺失也归本码 —— 因为
  /// **客户端对两者是同一件事**（都属协议错误、重试无意义），拆码只会让协议面变宽；
  /// 排查要区分时靠**主机日志的 detail**（`sync_server.dart` 已把 `document` / `lines`
  /// 拆成两条 detail）。
  fieldTypeMismatch('field_type_mismatch'),

  /// `payload.id` 与 `entity_id` 不一致（id 是幂等键，必须相等）
  idMismatch('id_mismatch'),

  /// 动作名不认识（v1 只支持 `mark_delivered`）
  unknownAction('unknown_action'),

  /// 参数不合法（游标不是整数等）
  malformedParameter('malformed_parameter'),

  /// payload 自相矛盾：`immediate_payments` 与 `allocations` **互斥**
  payloadMutuallyExclusive('payload_mutually_exclusive'),

  /// v1 有意不支持的 `doc_type`（如 `transfer` 调拨）
  unsupportedDocType('unsupported_doc_type'),

  /// 这个动作对这类单**不适用**（非送货单不能签收 / 该状态不能签收 /
  /// 该类型不可作核销目标）
  actionNotApplicable('action_not_applicable'),

  /// 被操作的目标在主机上不存在（`documentAction` 的单据 / 核销目标单）
  ///
  /// ⚠️ 与 [referenceMissing] 的区别：这个是**动作/核销指向的目标**没了，
  /// 那个是**落库时外键**指向的对象没了。两者用户都只能等或重选。
  targetMissing('target_missing'),

  // ---------------------------------------------------------------- 落库失败
  //
  // `reason` 由 `syncFailureReason` 按**结果码**分类给出中文（`sync_failure.dart`）。

  /// 唯一字段重复（`PRIMARY KEY` / `UNIQUE`）
  duplicate('duplicate'),

  /// 🔑 **引用的对象在主机上不存在（`FOREIGN KEY`）** —— 承载
  /// `sync_protocol.md §8.5`「引用的主数据尚未同步」的契约。
  ///
  /// ⚠️ **本表里唯一一个「等一会儿重推就能成功」的码**：客户端**不要**删镜像行、
  /// **不要**删队列条目 —— 等被引用的主数据 push 成功、pull 确认之后，重推该单即可。
  /// 其余码都是**重试无意义**的（要么是客户端 bug，要么得先改数据）。
  referenceMissing('reference_missing'),

  /// 数据不完整或不合法（`NOT NULL` / `CHECK`）
  dataInvalid('data_invalid'),

  /// 主机侧存储故障（忙 / 满 / 只读 / 损坏 / 打不开）
  hostStorage('host_storage'),

  // ---------------------------------------------------------------- 规则拒绝

  /// **累计退货量超过原单量**（`docs/rules.md` RULE-007 / RULE-008）。
  ///
  /// 业务拒绝里**唯一单独命名**的一个：用户能做的事很明确（**少退一点**），
  /// 而且它是**状态相关**的 —— 界面的前置拦截（`quotasFor`）只能尽力，
  /// 并发退货时仍会命中（`CostPolicy.returnCost`）。
  returnExceedsOriginal('return_exceeds_original'),

  /// **业务拒绝的通用兜底**：用户能改，但没单独命名的一类
  /// （核销额超过未收金额 / 核销总额超过收付款单金额 / 立即收付款超过单据总额…）。
  ruleValidationFailed('rule_validation_failed'),

  /// **规则层内部 bug**（不变量破坏 / 协议违反被抓到）：细节**只进日志**，
  /// 回执只给通用中文（[ruleInternalErrorReason]）。
  ///
  /// ⚠️ 这**不是**伞码：它与 [ruleValidationFailed] 的边界是**用户能不能做点什么**，
  /// 而这一类的答案恒为「不能」（界面的草稿校验本该拦住它，拦不住就是 bug）。
  ruleInternalError('rule_internal_error');

  const RejectCode(this.wire);

  /// `reason_code` 字段的字面量。
  final String wire;

  /// `wire` 值 → 码；**不认识的返回 `null`**（不抛）。
  ///
  /// 前向兼容是必需的：**主机可能比客户端新**（`wire` 只增不改，但那是对「改名」说的
  /// —— 新版本可以**加**码，老客户端收到就得不认识）。客户端遇到 `null` 就当
  /// 「有个我不知道的原因」处理（`reason` 仍可展示）。
  static RejectCode? fromWire(String? wire) {
    if (wire == null) return null;
    for (final RejectCode code in RejectCode.values) {
      if (code.wire == wire) return code;
    }
    return null;
  }
}
