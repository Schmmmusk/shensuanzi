/// 同步操作与响应（`docs/sync_protocol.md` §8.1）。
///
/// ## wire JSON 约定
///
/// **字段名 = 数据库列名（snake_case），值 = `toRow()` 的形态**
/// —— 布尔用 `0/1`、时间用 UTC 毫秒 `int`、金额用整数分。
///
/// 这样 wire ↔ DB row 之间**没有转换层**，也就没有转换漂移：
/// 模型已有的 `toRow()` / `fromRow()` 直接就是编解码器。
///
/// 例：`products` 的 `is_active` 在 wire 上是 `1` / `0`，不是 `true` / `false`。
library;

/// 同步操作类型（`docs/data_model.md` §4.1）。
enum SyncOpType {
  createDocument('createDocument'),
  createMasterData('createMasterData'),
  updateMasterData('updateMasterData'),
  deleteMasterData('deleteMasterData'),

  /// **动作通道**（R-3，2026-09-29 裁定）：v1 唯一落地 `mark_delivered`
  /// （送货单 `in_transit → delivered`）；未知动作 → `rejected` + `unknown_action`；
  /// 状态不匹配 → `conflict` + `server_state`（客户端自动对齐，见 R-3.4）。
  documentAction('documentAction');

  const SyncOpType(this.wire);

  final String wire;

  static SyncOpType fromWire(String value) => SyncOpType.values.firstWhere(
    (SyncOpType type) => type.wire == value,
    orElse: () => throw ArgumentError('未知同步操作：$value'),
  );
}

/// 客户端推送的**一条**队列条目。
class SyncOperation {
  const SyncOperation({
    required this.entity,
    required this.entityId,
    required this.operation,
    this.baseVersion,
    this.payload = const <String, Object?>{},
  });

  factory SyncOperation.fromJson(Map<String, Object?> json) {
    final Object? payload = json['payload'];
    return SyncOperation(
      entity: json['entity']! as String,
      entityId: json['entity_id']! as String,
      operation: SyncOpType.fromWire(json['operation']! as String),
      baseVersion: json['base_version'] as int?,
      payload: payload == null
          ? const <String, Object?>{}
          : Map<String, Object?>.from(payload as Map<Object?, Object?>),
    );
  }

  /// 目标表名（必须过白名单）
  final String entity;

  /// 目标实体 id —— **幂等键**（`sync_protocol.md` §二）
  final String entityId;

  final SyncOpType operation;

  /// 乐观锁基准版本，仅 `updateMasterData` 用
  final int? baseVersion;

  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
    'entity': entity,
    'entity_id': entityId,
    'operation': operation.wire,
    if (baseVersion != null) 'base_version': baseVersion,
    'payload': payload,
  };
}

/// 单条操作的处理结果（`docs/sync_protocol.md` §8.1 的 `status` 枚举）。
enum SyncStatus {
  applied('applied'),
  alreadyExists('already_exists'),
  conflict('conflict'),
  rejected('rejected');

  const SyncStatus(this.wire);

  final String wire;

  static SyncStatus fromWire(String value) => SyncStatus.values.firstWhere(
    (SyncStatus status) => status.wire == value,
    orElse: () => throw ArgumentError('未知同步状态：$value'),
  );
}

/// `POST /api/sync/push` 的**请求体**（`docs/sync_protocol.md` §8.1）。
///
/// ```json
/// { "operations": [ { "entity": "documents", ... } ] }
/// ```
///
/// 放在 core 而不是 host：**两端都要用它**（客户端拼请求、主机解请求），
/// 而它不含任何传输实现。
class SyncPushRequest {
  const SyncPushRequest({required this.operations});

  factory SyncPushRequest.fromJson(Map<String, Object?> json) {
    final Object? raw = json['operations'];
    if (raw is! List) {
      throw const FormatException('推送请求体缺少 operations 数组');
    }
    return SyncPushRequest(
      operations: <SyncOperation>[
        for (final Object? item in raw)
          SyncOperation.fromJson(Map<String, Object?>.from(item! as Map)),
      ],
    );
  }

  final List<SyncOperation> operations;

  Map<String, Object?> toJson() => <String, Object?>{
    'operations': <Object?>[
      for (final SyncOperation op in operations) op.toJson(),
    ],
  };
}

/// `POST /api/sync/push` 的**响应体**。
///
/// ```json
/// { "results": [ { "entity_id": "...", "status": "applied" } ] }
/// ```
///
/// 客户端按 `entity_id` 与队列条目配对，**不按下标**（§六）。
class SyncPushResponse {
  const SyncPushResponse({required this.results});

  factory SyncPushResponse.fromJson(Map<String, Object?> json) {
    final Object? raw = json['results'];
    if (raw is! List) {
      throw const FormatException('推送响应体缺少 results 数组');
    }
    return SyncPushResponse(
      results: <SyncResponse>[
        for (final Object? item in raw) _resultFrom(item),
      ],
    );
  }

  static SyncResponse _resultFrom(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('results 的元素必须是对象');
    }
    final Map<String, Object?> map = Map<String, Object?>.from(raw);
    final Object? serverState = map['server_state'];
    return SyncResponse(
      entityId: map['entity_id']! as String,
      status: SyncStatus.fromWire(map['status']! as String),
      reason: map['reason'] as String?,
      serverState: serverState == null
          ? null
          : Map<String, Object?>.from(serverState as Map),
    );
  }

  final List<SyncResponse> results;

  /// 按 `entity_id` 取回执 —— 客户端配对队列条目用（§六）
  Map<String, SyncResponse> byEntityId() => <String, SyncResponse>{
    for (final SyncResponse result in results) result.entityId: result,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'results': <Object?>[
      for (final SyncResponse result in results) result.toJson(),
    ],
  };
}

/// 一条操作的回执。**客户端按 [SyncResponse.entityId] 与队列条目配对，不按下标**
/// （`docs/sync_protocol.md` §六）。
///
/// ⚠️ 回执里**不含**主机分配的正式单号 —— 客户端通过 `/api/sync/pull` 拉取。
/// 这样 `push` 的响应契约保持最小（`sync_protocol.md` §8.1）。
class SyncResponse {
  const SyncResponse({
    required this.entityId,
    required this.status,
    this.reason,
    this.serverState,
  });

  /// 便捷构造：拒绝 + 原因
  factory SyncResponse.rejected(String entityId, String reason) =>
      SyncResponse(
        entityId: entityId,
        status: SyncStatus.rejected,
        reason: reason,
      );

  final String entityId;
  final SyncStatus status;

  /// 仅 `rejected` 时非空
  final String? reason;

  /// 仅 `conflict` 时非空：主机侧的当前状态（wire JSON）
  final Map<String, Object?>? serverState;

  bool get isApplied => status == SyncStatus.applied;

  Map<String, Object?> toJson() => <String, Object?>{
    'entity_id': entityId,
    'status': status.wire,
    if (reason != null) 'reason': reason,
    if (serverState != null) 'server_state': serverState,
  };

  @override
  String toString() =>
      'SyncResponse(${status.wire}${reason == null ? '' : ', $reason'})';
}
