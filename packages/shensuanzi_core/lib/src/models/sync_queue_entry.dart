/// 同步队列条目（`docs/data_model.md` §4.1）。
///
/// ⚠️ **它不是业务数据，也不是主数据** —— 所以**不**继承
/// [ImmutableEntity] / [MutableEntity]，也不受「不可变」「乐观锁」纪律约束：
/// 那张纪律管的是**业务记录**（单据、流水、主数据），
/// 而队列条目是**客户端的传输状态**，本来就该被反复改写（重试、退避、状态流转）。
library;

import 'dart:convert';

import '../db/read_failures.dart';

import '../sync/sync_operation.dart';
import '../util/ids.dart';

/// 队列条目的状态（`docs/data_model.md` §4.1）。
///
/// | 状态 | 含义 | 贡献的未同步影响 |
/// |---|---|---|
/// | [pending] | 本地已开单，**尚未 push 成功**；到期后参与自动推送 | `pending_delta` |
/// | [sent] | 已 push 成功、主机已收下，但**拉取尚未确认** | `in_flight_delta` |
/// | [failed] | 重试超限（死信）—— **退出自动重试**，需人工处理后 `requeue` | 仍算未同步影响 |
///
/// ⚠️ **`sent` 不删除、只在 pull 确认后删除**（R-14 裁定附带的问题 3）：
/// 如果 push 成功就删条目，用户在下次 pull 之前**看不到自己刚做的生意** ——
/// 界面会显示「库存 10」而用户刚刚卖了 3 件。保留 `sent` 条目正是为了让
/// 「主机已收下、但我还没在权威状态里见到」这段窗口**可见**。
enum SyncQueueStatus {
  pending('pending'),
  sent('sent'),
  failed('failed');

  const SyncQueueStatus(this.wire);

  final String wire;

  /// 严格版：**不认识就抛**。用于 **wire 报文校验**（畸形请求要拒绝）。
  static SyncQueueStatus fromWire(String value) =>
      SyncQueueStatus.values.firstWhere(
        (SyncQueueStatus status) => status.wire == value,
        orElse: () => throw ArgumentError('未知队列状态：$value'),
      );

  /// **读库用**（#42 甲 · L2）：未知值 ⇒ `null`，**不抛**。
  /// ⚠️ 调用方（[SyncQueueEntry.fromRow]）遇到 `null` **跳过该行 + 计数** ——
  /// **不要兜底成 `failed`**（2026-10-14 裁定）：`failed` 的语义是
  /// 「死信，退出自动重试，等人工处理」，拿来装「主机不认识的新状态」
  /// 会把**兼容性问题伪装成同步失败**，误导用户去处理一个根本不需要处理的东西。
  static SyncQueueStatus? fromWireOrNull(String value) {
    for (final SyncQueueStatus status in SyncQueueStatus.values) {
      if (status.wire == value) return status;
    }
    return null;
  }
}

/// 一条待同步（或已同步待确认）的操作。
class SyncQueueEntry {
  const SyncQueueEntry({
    required this.id,
    required this.entity,
    required this.entityId,
    required this.operation,
    this.baseVersion,
    this.payload = const <String, Object?>{},
    this.status = SyncQueueStatus.pending,
    this.retryCount = 0,
    this.lastError,
    required this.createdAt,
    this.nextRetryAt = 0,
  });

  /// **#42 甲 · L2**（2026-10-14 裁定 §三）：两个枚举**认不出就跳过该行**
  /// （抛 [RowDecodeException]，由 `decodeRows` 捕获 + 计数）——
  /// **不兜底成 `pending` / `failed`**：
  /// `failed` 会把「主机不认识的新状态」伪装成「同步失败，请处理」，
  /// `pending` 则可能让一条永远推不动的条目无限重试。
  factory SyncQueueEntry.fromRow(Map<String, Object?> row) {
    final String rawOperation = row['operation']! as String;
    final SyncOpType? operation = SyncOpType.fromWireOrNull(rawOperation);
    if (operation == null) {
      throw RowDecodeException(
        column: 'operation',
        reason: '认不出的同步操作',
        value: rawOperation,
      );
    }
    final String rawStatus = row['status']! as String;
    final SyncQueueStatus? status = SyncQueueStatus.fromWireOrNull(rawStatus);
    if (status == null) {
      throw RowDecodeException(
        column: 'status',
        reason: '认不出的队列状态',
        value: rawStatus,
      );
    }
    return SyncQueueEntry(
      id: row['id']! as String,
      entity: row['entity']! as String,
      entityId: row['entity_id']! as String,
      operation: operation,
      baseVersion: row['base_version'] as int?,
      payload: _decodePayload(row['payload']! as String),
      status: status,
      retryCount: row['retry_count']! as int,
      lastError: row['last_error'] as String?,
      createdAt: row['created_at']! as int,
      nextRetryAt: row['next_retry_at']! as int,
    );
  }

  static Map<String, Object?> _decodePayload(String raw) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw FormatException('sync_queue.payload 不是 JSON 对象：$raw');
    }
    return Map<String, Object?>.from(decoded);
  }

  final String id;

  /// 目标表名
  final String entity;

  /// 目标实体 id —— **幂等键**，回执按它配对（`sync_protocol.md` §二 / §六）
  final String entityId;

  final SyncOpType operation;
  final int? baseVersion;
  final Map<String, Object?> payload;
  final SyncQueueStatus status;
  final int retryCount;
  final String? lastError;
  final int createdAt;

  /// 到期时间（毫秒）。`0` = 立即可送。
  final int nextRetryAt;

  /// 是否可参与本轮推送：`pending` 且已到退避时间。
  ///
  /// `sent` 已成功（等确认），`failed` 是死信（等人工）——两者都不参与自动推送。
  bool isDue(int now) =>
      status == SyncQueueStatus.pending && nextRetryAt <= now;

  /// 转成推送操作（`sync_protocol.md` §8.1）
  SyncOperation toOperation() => SyncOperation(
    entity: entity,
    entityId: entityId,
    operation: operation,
    baseVersion: baseVersion,
    payload: payload,
  );

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'entity': entity,
    'entity_id': entityId,
    'operation': operation.wire,
    'base_version': baseVersion,
    'payload': jsonEncode(payload),
    'status': status.wire,
    'retry_count': retryCount,
    'last_error': lastError,
    'created_at': createdAt,
    'next_retry_at': nextRetryAt,
  };

  SyncQueueEntry copyWith({
    SyncQueueStatus? status,
    int? retryCount,
    String? lastError,
    int? nextRetryAt,
  }) => SyncQueueEntry(
    id: id,
    entity: entity,
    entityId: entityId,
    operation: operation,
    baseVersion: baseVersion,
    payload: payload,
    status: status ?? this.status,
    retryCount: retryCount ?? this.retryCount,
    lastError: lastError ?? this.lastError,
    createdAt: createdAt,
    nextRetryAt: nextRetryAt ?? this.nextRetryAt,
  );

  /// 入队一条新条目（`pending`，退避计时归零）
  static SyncQueueEntry create(SyncOperation op, {required int now}) =>
      SyncQueueEntry(
        id: newId(),
        entity: op.entity,
        entityId: op.entityId,
        operation: op.operation,
        baseVersion: op.baseVersion,
        payload: op.payload,
        createdAt: now,
      );

  @override
  String toString() =>
      'SyncQueueEntry(${operation.wire} $entity/$entityId '
      '${status.wire} retry=$retryCount)';
}
