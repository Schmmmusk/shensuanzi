import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';

/// 主机侧同步服务（`docs/sync_protocol.md`）—— **协议的服务端实现**。
///
/// ## 包边界（2026-09-25 裁定）
///
/// 本类在 **host** 而不是 core：
///
/// | 放哪 | 什么 |
/// |---|---|
/// | `shensuanzi_core` | 同步**协议**：DTO（`SyncOperation` / `SyncPushRequest` / `SyncPullResult` …）、游标编解码、白名单 |
/// | **本包** | 同步**服务端**：`SyncServer`（协议处理 + RuleEngine 分派） |
/// | 根 Flutter 应用 | HTTP 渲染层与 UI |
///
/// ## 边界
///
/// - **落库一律走 [RuleEngine]**（`Agents.md` 纪律 9）：客户端只推 `Document`，
///   主机按 `doc_type` 分派规则。`SyncServer` 自己**不写任何流水**。
/// - **表名 / 列名必须先过白名单**（纪律 10）：见 [SyncWhitelist]。
///   本文件里所有拼进 SQL 的表名都只来自白名单常量或 `Schema.*` 常量，
///   **没有任何一处来自客户端输入**。
/// - **一条 op 一个事务**。失败只影响该条，不回滚同一批里的其它条目
///   （它们是各自独立的队列条目，见 §六）。
class SyncServer {
  SyncServer(this.db, {this.onInternalError})
    : _engine = RuleEngine(db),
      _products = ProductService(db);

  final Db db;
  final RuleEngine _engine;

  /// **内部错误的日志出口**（§CS·五 裁定 ③，2026-10-08）。
  ///
  /// 客户端只拿到一句中文结论（[syncFailureReason]）；**原始异常 + 堆栈走这里**
  /// 进主机日志 —— 两个通道不混（与 M15 同一条纪律）。`null` = 不记（测试 /
  /// 自检里常见），不影响任何行为。
  final void Function(String label, Object error, StackTrace stack)?
  onInternalError;

  /// 商品建档的**编码改派**（D1，2026-10-08）。
  ///
  /// ⚠️ 本类只**调用**它，不自己算编码 —— 改派逻辑的唯一出处是
  /// `ProductService.resolvePreferredCode`（`docs/reply.md` 裁定 §二②）。
  /// 自己算的话，「桌面建档」与「同步建档」会各写一套（纪律 5）。
  final ProductService _products;

  Database get _raw => db.raw;

  /// 一次拉取每个实体的最大行数
  static const int defaultPullLimit = 500;

  /// `createDocument` 的 payload 允许出现的顶层字段（`sync_protocol.md` §8.1）
  static const Set<String> documentPayloadKeys = <String>{
    'document',
    'lines',
    'immediate_payments',
    'allocations',
  };

  /// `documentAction` 的 payload 允许出现的顶层字段（`sync_protocol.md` §三）
  static const Set<String> actionPayloadKeys = <String>{'action', 'occurred_at'};

  /// v1 唯一落地的动作（R-3.1：动作只做**单向终态转变**）
  static const String markDeliveredAction = 'mark_delivered';

  // ------------------------------------------------------------ 推送

  /// 批量推送（`sync_protocol.md` §8.1）。**逐条独立处理**，互不影响。
  ///
  /// [now] = 主机当前时间（毫秒）。**必须由调用方传入**，不在内部取 ——
  /// 这样单测可复现，也让「主机时钟为准」成为显式约定。
  List<SyncResponse> push(
    List<SyncOperation> operations, {
    required int now,
  }) => <SyncResponse>[
    for (final SyncOperation op in operations) handle(op, now: now),
  ];

  /// 处理单条操作。
  SyncResponse handle(SyncOperation op, {required int now}) {
    try {
      if (!SyncWhitelist.isWritableTable(op.entity)) {
        return _malformedRequest(
          op,
          '白名单',
          StateError('entity 不在白名单：${op.entity}'),
        );
      }
      switch (op.operation) {
        case SyncOpType.createDocument:
          return _createDocument(op, now);
        case SyncOpType.createMasterData:
          return _createMasterData(op, now);
        case SyncOpType.updateMasterData:
          return _updateMasterData(op, now);
        case SyncOpType.deleteMasterData:
          return _deleteMasterData(op, now);
        case SyncOpType.documentAction:
          return _applyAction(op, now);
      }
    } on FormatException catch (error) {
      return SyncResponse.rejected(op.entityId, error.message);
    } catch (error, stack) {
      // §CS·五 裁定 ③（2026-10-08）：**领域异常先分类，再回一句中文**。
      // 原来这里写 `'操作失败：$error'` —— `SqliteException.toString()` 带着
      // 整条 SQL 与绑定参数，等于把客户端 payload 原样回传（M15 同一类问题）。
      onInternalError?.call('同步操作失败（${op.operation.wire}）', error, stack);
      return SyncResponse.rejected(op.entityId, syncFailureReason(error));
    }
  }

  /// **协议违反的统一处置**（2026-10-09 裁定，`docs/reply_review.md` §CV·十五）。
  ///
  /// 这类分支**都不该是用户可见的 `rejected`** —— 它们全是**客户端实现的 bug**
  /// （白名单外 / entity 不符 / 字段类型不符 / 游标不合法…），**用户看了也修不了**
  /// （`ui_principles.md §五`：错误信息说怎么办，不说哪里错了）。
  ///
  /// ⇒ 与 [handle] 的兜底 catch **同一处置**：**原始细节走 `onInternalError` 进主机日志**
  /// （诊断要看的就是它），回执只给一句**通用中文** [malformedSyncRequestReason]。
  SyncResponse _malformedRequest(
    SyncOperation op,
    String cause,
    Object detail,
  ) {
    onInternalError?.call(
      '同步操作失败（${op.operation.wire}：$cause）',
      detail,
      StackTrace.current,
    );
    return SyncResponse.rejected(op.entityId, malformedSyncRequestReason);
  }

  // ------------------------------------------------------------ documentAction

  /// `documentAction` 通道（R-3，2026-09-29 裁定）。
  ///
  /// **动作只做单向终态转变**：v1 唯一的动作是 [markDeliveredAction]
  /// （`in_transit → delivered`）。转变本体在 `RuleEngine.markDelivered`
  /// （**规则的实现只应有一处**，纪律 9），本方法只做协议层的两件事：
  /// **payload 校验** 与 **回执分类**（R-3.4 的分类原则）：
  ///
  /// | 情形 | 回执 |
  /// |---|---|
  /// | 转变执行 | `applied` |
  /// | 已是 `delivered` / `settled`（重复签收） | `alreadyExists` |
  /// | **状态不匹配**（draft / confirmed / cancelled） | `conflict` + `server_state` —— 客户端自动对齐 |
  /// | 规则不允许（docType 不适用 / 单据不存在 / 参数错） | `rejected` |
  /// | 未知动作名 | `rejected` + `unknown_action: <名>` |
  ///
  /// 并发语义是 **FAW（first-arrival-wins）**（R-3.3 / R-3.5）：客户端时钟不可信，
  /// **到达主机顺序是唯一可观测的真相** —— 谁先到谁生效，后到者拿
  /// `conflict` + 主机状态。v1 没有 cancel 动作，两台设备不会同时做互斥的事
  /// （R-3.5 的场景在 v1 不发生；FAW 是「将来加 cancel 时」的判定规则）。
  ///
  /// `occurred_at`（客户端提供）**仅展示用，不参与任何判定、不落库**
  /// （R-3.3：不引入 `delivered_at` —— 主机 `updated_at` 已记录状态何时变化）。
  SyncResponse _applyAction(SyncOperation op, int now) {
    if (op.entity != Schema.documents) {
      return _malformedRequest(
        op,
        'entity 不符',
        StateError(
          'documentAction 的 entity 必须是 ${Schema.documents}，实际 ${op.entity}',
        ),
      );
    }
    final Set<String> unknownKeys = op.payload.keys
        .toSet()
        .difference(actionPayloadKeys);
    if (unknownKeys.isNotEmpty) {
      return SyncResponse.rejected(
        op.entityId,
        'documentAction 的 payload 含未知字段：${unknownKeys.join(', ')}'
        '（允许：${actionPayloadKeys.join(', ')}）',
      );
    }
    final Object? action = op.payload['action'];
    if (action is! String || action.isEmpty) {
      return SyncResponse.rejected(op.entityId, 'payload.action 缺失或不是字符串');
    }
    if (action != markDeliveredAction) {
      return SyncResponse.rejected(
        op.entityId,
        'unknown_action: $action（v1 只支持 $markDeliveredAction）',
      );
    }
    final Object? occurredAt = op.payload['occurred_at'];
    if (occurredAt != null && occurredAt is! int) {
      return SyncResponse.rejected(
        op.entityId,
        'payload.occurred_at 必须是 UTC 毫秒整数（客户端提供，仅展示用）',
      );
    }

    final RuleOutcome outcome = _engine.markDelivered(
      documentId: op.entityId,
      now: now,
    );
    switch (outcome.status) {
      case RuleStatus.applied:
        return SyncResponse(entityId: op.entityId, status: SyncStatus.applied);
      case RuleStatus.alreadyExists:
        return SyncResponse(
          entityId: op.entityId,
          status: SyncStatus.alreadyExists,
        );
      case RuleStatus.rejected:
        // R-3.4 分类：引擎拒绝有两种，回执语义不同 ——
        // **状态不匹配**（单据存在、类型也对，但前提不成立）→ `conflict`，
        // 让客户端用 server_state 对齐；**规则不允许**（类型不符 / 不存在）→ `rejected`。
        // 已是 delivered / settled 的情形到不了这里（引擎返回 alreadyExists）。
        // 注：in_transit 上的执行异常（「已回滚」）状态仍是 in_transit，
        // 不会误入 conflict 分支。
        final Row? row = _findRow(Schema.documents, op.entityId);
        final bool statusMismatch =
            row != null && row['doc_type'] == DocType.delivery.wire;
        if (statusMismatch) {
          return SyncResponse(
            entityId: op.entityId,
            status: SyncStatus.conflict,
            serverState: Map<String, Object?>.from(row),
          );
        }
        return SyncResponse.rejected(op.entityId, outcome.reason ?? '动作被拒绝');
    }
  }

  // ------------------------------------------------------------ createDocument

  SyncResponse _createDocument(SyncOperation op, int now) {
    if (op.entity != Schema.documents) {
      return _malformedRequest(
        op,
        'entity 不符',
        StateError(
          'createDocument 的 entity 必须是 ${Schema.documents}，实际 ${op.entity}',
        ),
      );
    }

    final Set<String> unknownKeys = op.payload.keys
        .toSet()
        .difference(documentPayloadKeys);
    if (unknownKeys.isNotEmpty) {
      return SyncResponse.rejected(
        op.entityId,
        'createDocument 的 payload 含未知字段：${unknownKeys.join(', ')}'
        '（允许：${documentPayloadKeys.join(', ')}）',
      );
    }

    final Object? rawDocument = op.payload['document'];
    if (rawDocument is! Map) {
      return SyncResponse.rejected(
        op.entityId,
        'createDocument 缺少 payload.document',
      );
    }
    final Map<String, Object?> raw = Map<String, Object?>.from(rawDocument);

    final List<String> badColumns = SyncWhitelist.offendingColumns(
      Schema.documents,
      raw.keys,
    );
    if (badColumns.isNotEmpty) {
      return SyncResponse.rejected(
        op.entityId,
        'documents 含不可写列：${badColumns.join(', ')}',
      );
    }

    final Map<String, Object?> values = SyncValueCheck.normalize(raw);
    if (values['id'] != op.entityId) {
      return SyncResponse.rejected(
        op.entityId,
        'payload.document.id（${values['id']}）必须等于 entity_id（${op.entityId}）'
        '—— id 是幂等键（sync_protocol.md §二）',
      );
    }

    // 主机专属字段补默认值。客户端的值不可能覆盖它们 ——
    // 白名单已把 hostOnlyColumns 挡在外面，所以展开顺序是安全的。
    final Map<String, Object?> row = <String, Object?>{
      'doc_no': '', // 空 = 临时展示号，主机 `_prepare` 会分配正式单号
      'total_amount': 0,
      'paid_amount': 0,
      'time_estimated': 0,
      'created_at': now,
      'updated_at': now,
      ...values,
    };

    final Document document;
    final List<DocumentLine> lines;
    try {
      document = Document.fromRow(row);
      lines = _linesFrom(op.payload['lines'], documentId: op.entityId);
    } catch (error) {
      return SyncResponse.rejected(
        op.entityId,
        'document / lines 字段缺失或类型不符：$error'
        '（document 必填 id / doc_type / status / occurred_at；'
        'lines 的元素是完整 wire 行，含客户端生成的 id —— sync_protocol.md §8.1）',
      );
    }

    final List<PaymentEntry> immediate = _jsonList(
      op.payload['immediate_payments'],
      'immediate_payments',
      PaymentEntry.fromJson,
    );
    final List<Allocation> allocations = _jsonList(
      op.payload['allocations'],
      'allocations',
      Allocation.fromJson,
    );

    // 落库一律走 RuleEngine（纪律 9）：互斥校验、按 doc_type 分派、
    // seq_no 分配、流水写入、paid_amount 刷新全在里面。
    // 事务也由 RuleEngine 开 —— 此处**不再包一层**。
    return _mapOutcome(
      op.entityId,
      _engine.dispatch(
        document: document,
        lines: lines,
        immediatePayments: immediate,
        allocations: allocations,
        now: now,
      ),
    );
  }

  // ------------------------------------------------------------ 主数据

  /// `createMasterData`（`sync_protocol.md` §8.1）。
  ///
  /// ## 商品编码的「主机改派」（D1，2026-10-08）
  ///
  /// 手机**离线**建档时，编码由客户端按**自己镜像**的 `max(code)+1` 生成
  /// （`reply_review.md` §CH 提案 A §3）。主机的并发现实是「另一台设备
  /// （或电脑上）可能已经用了同一个码」—— 于是：
  ///
  /// - 客户端的编码**可用** ⇒ 原样采用（用户无感）；
  /// - **已被别的商品占用** ⇒ 主机**改派**一个新的编码。
  ///
  /// 客户端不为此多发一次往返：它靠 **pull 回写镜像**拿到真实编码
  /// （镜像行与这里同 id ⇒ `SyncClient._upsertRow` 直接覆盖，
  /// 见 `sync_client.dart` 的 UPSERT 说明）。
  ///
  /// ⚠️ 判定一律走 [ProductService.resolvePreferredCode]（**改派唯一出处**）；
  /// 本方法只决定「**什么时候**该改派」= 建商品时。其它主数据表原样落库。
  SyncResponse _createMasterData(SyncOperation op, int now) {
    final SyncResponse? guard = _requireMasterData(op);
    if (guard != null) return guard;

    final Map<String, Object?> values = SyncValueCheck.normalize(op.payload);
    if (values['id'] != null && values['id'] != op.entityId) {
      return SyncResponse.rejected(
        op.entityId,
        'payload.id（${values['id']}）必须等于 entity_id（${op.entityId}）',
      );
    }

    return db.transaction<SyncResponse>(() {
      if (_exists(op.entity, op.entityId)) {
        return SyncResponse(
          entityId: op.entityId,
          status: SyncStatus.alreadyExists,
        );
      }
      return _insertMasterData(op, values, now);
    });
  }

  /// 主数据**落库**（建档路径的**唯一实现**）—— `createMasterData` 与
  /// `updateMasterData` 的 **upsert 分支**共用（§CV·3 裁定，2026-10-08）。
  ///
  /// ⚠️ **必须在事务内调用**：编码可能顺延自增（`products.code` 是 UNIQUE）。
  ///
  /// 商品编码的改派：判定一律走 [ProductService.resolvePreferredCode]
  /// （**改派唯一出处**）；本方法只决定「**什么时候**该改派」= 落库时。
  SyncResponse _insertMasterData(
    SyncOperation op,
    Map<String, Object?> values,
    int now,
  ) {
    Map<String, Object?> effective = values;
    if (op.entity == Schema.products) {
      final Object? rawCode = values['code'];
      if (rawCode != null && rawCode is! String) {
        // 不静默兜底：`code` 是 TEXT 列，塞数字会被 SQLite 存成文本，
        // 用户会看到一个莫名其妙的编码，而没人知道是谁塞的。
        // ⚠️ 这是**客户端 bug**（用户修不了）⇒ 细节进日志、回执只说通用中文（§CV·十五）。
        return _malformedRequest(
          op,
          'code 类型不符',
          StateError('products.code 必须是字符串，实际 ${rawCode.runtimeType}'),
        );
      }
      effective = <String, Object?>{
        ...values,
        'code': _products.resolvePreferredCode(rawCode as String?),
      };
    }
    // created_at / updated_at / sync_version 由主机写（纪律 10 + §七）
    _insertRow(op.entity, <String, Object?>{
      ...effective,
      'id': op.entityId,
      'created_at': now,
      'updated_at': now,
      'sync_version': 0,
    });
    return SyncResponse(entityId: op.entityId, status: SyncStatus.applied);
  }

  /// `updateMasterData`（`sync_protocol.md` §8.1）—— **upsert 语义**（§CV·3 裁定，2026-10-08）。
  ///
  /// | 主机该 id | 行为 |
  /// |---|---|
  /// | **存在** | 乐观锁校验 `base_version`：匹配 ⇒ 更新 + `sync_version + 1`；落后 ⇒ `conflict` + `server_state` |
  /// | **不存在** | **转为建档**（用 payload 的 id；**忽略 `base_version`**） |
  ///
  /// ## 为什么是 upsert（§CV·3 方案丙）
  ///
  /// 客户端队列**不合并**同一实体的 create / update，只保证**正常路径**按
  /// `created_at` 升序 push。一旦 create 进了重试（`next_retry_at` 后退），
  /// update 可能**先到主机** —— 旧实现（不存在 ⇒ `rejected`）会让这条编辑
  /// **永远补不上**（指数退避到死信）。
  ///
  /// upsert 把它**从根上消除**：create / update 谁先到都收敛到同一状态
  /// （`Agents.md §二·8`「主机永远赢」）。
  ///
  /// ⚠️ **仅主数据** —— 单据必须走 `RuleEngine`，**不存在** upsert 概念。
  SyncResponse _updateMasterData(SyncOperation op, int now) {
    final SyncResponse? guard = _requireMasterData(op);
    if (guard != null) return guard;

    if (op.baseVersion == null) {
      return SyncResponse.rejected(
        op.entityId,
        'updateMasterData 必须带 base_version（乐观锁，sync_protocol.md §四）',
      );
    }

    final Map<String, Object?> values = SyncValueCheck.normalize(op.payload);
    if (values['id'] != null && values['id'] != op.entityId) {
      return SyncResponse.rejected(
        op.entityId,
        'payload.id（${values['id']}）必须等于 entity_id（${op.entityId}）',
      );
    }
    values.remove('id');
    // §CS·五 裁定 ①（2026-10-08）：**系统生成的字段一律以主机为准**。
    //
    // `products.code` 客户端**不该发**（`data_model.md §2.1`：由系统生成、用户不填）；
    // 就算发了也一律丢弃 —— 主机永远赢（`Agents.md §二·8`），且避免
    // 「客户端拿着**被改派前的过期 code** 来 update」撞 `products.code UNIQUE`
    // ⇒（修复前）`rejected` + 指数退避重试到死信，这张编辑永远补不上。
    //
    // 通用规则（`sync_protocol.md §8.1`）：**update payload 不含系统生成字段**。
    if (op.entity == Schema.products) {
      values.remove('code');
    }

    return db.transaction<SyncResponse>(() {
      final Row? current = _findRow(op.entity, op.entityId);
      if (current == null) {
        // upsert：主机没有该行 ⇒ 用 payload（已剥 `id` / 系统生成字段）建档。
        // `base_version` 在此**无意义**（没有可比对的版本），故不校验。
        // 编码由 `_insertMasterData` → `resolvePreferredCode(null)` 生成 / 改派。
        return _insertMasterData(op, values, now);
      }

      final int version = current['sync_version']! as int;
      if (version != op.baseVersion) {
        // 主机赢：把主机侧当前状态回给客户端（§四）
        return SyncResponse(
          entityId: op.entityId,
          status: SyncStatus.conflict,
          serverState: Map<String, Object?>.from(current),
        );
      }

      _updateRow(op.entity, op.entityId, <String, Object?>{
        ...values,
        'updated_at': now,
        'sync_version': version + 1,
      });
      return SyncResponse(entityId: op.entityId, status: SyncStatus.applied);
    });
  }

  SyncResponse _deleteMasterData(SyncOperation op, int now) {
    final SyncResponse? guard = _requireMasterData(op);
    if (guard != null) return guard;

    final Set<String> extraKeys = op.payload.keys
        .toSet()
        .difference(const <String>{'id'});
    if (extraKeys.isNotEmpty) {
      return SyncResponse.rejected(
        op.entityId,
        'deleteMasterData 的 payload 只允许 id，实际含：${extraKeys.join(', ')}',
      );
    }

    return db.transaction<SyncResponse>(() {
      final Row? current = _findRow(op.entity, op.entityId);
      if (current == null) {
        return SyncResponse.rejected(op.entityId, '主数据不存在：${op.entityId}');
      }
      if ((current['is_active']! as int) == 0) {
        return SyncResponse(
          entityId: op.entityId,
          status: SyncStatus.alreadyExists, // 已软删 → 幂等
        );
      }
      // 软删：只翻 is_active，**从不 DELETE**
      _updateRow(op.entity, op.entityId, <String, Object?>{
        'is_active': 0,
        'updated_at': now,
        'sync_version': (current['sync_version']! as int) + 1,
      });
      return SyncResponse(entityId: op.entityId, status: SyncStatus.applied);
    });
  }

  /// 主数据操作的公共前置：表必须是主数据表，且 payload 列名全在白名单内。
  /// 返回非 null 表示已经可以短路返回。
  SyncResponse? _requireMasterData(SyncOperation op) {
    if (!SyncWhitelist.isMasterData(op.entity)) {
      return SyncResponse.rejected(
        op.entityId,
        '${op.operation.wire} 只支持主数据表'
        '（${SyncWhitelist.masterDataTables.join(' / ')}），实际 ${op.entity}',
      );
    }
    final List<String> badColumns = SyncWhitelist.offendingColumns(
      op.entity,
      op.payload.keys,
    );
    if (badColumns.isNotEmpty) {
      return SyncResponse.rejected(
        op.entityId,
        '${op.entity} 含不可写列：${badColumns.join(', ')}',
      );
    }
    return null;
  }

  // ------------------------------------------------------------ 拉取

  /// 增量拉取（`sync_protocol.md` §8.2）。
  ///
  /// ## 游标语义
  ///
  /// | 实体 | 游标 | 为什么 |
  /// |---|---|---|
  /// | 四张流水 | `seq_no`（整数字符串） | `seq_no` 唯一且单调，`>` 即安全 |
  /// | `documents` | `"<created_at>\|<id>"` | `created_at` **不唯一**，见 [SyncCursor] |
  /// | `document_lines` | **无独立游标** | 明细随主单走，理由见下 |
  /// | 主数据（products / parties / accounts） | `"<updated_at>\|<id>"` | 主数据**会被改**，`created_at` 感知不到（R-13 方案 A） |
  ///
  /// **`document_lines` 没有独立游标是刻意的**：它**没有时间列**（`data_model.md`
  /// §3.2），而且明细与主单**在同一个事务里写入**，永远不会单独存在。
  /// 所以它按「本页 `documents`」取 —— 这正是 §8.2 只给了 `doc_since`
  /// 而没有 `line_since` 的原因。
  ///
  /// 因此 [limit] 限制的是**主单条数**；明细条数由「本页主单的明细总数」决定，
  /// **不额外截断** —— 截断会造出「有主单但明细不全」的镜像，
  /// 而那恰恰是「明细随主单走」要避免的状态。
  ///
  /// 对称地，明细也**不会越过本页**：`limit=1` 时只返回那 1 张主单的明细。
  /// 「不截断」与「不越界」是两件事 —— 前者指本页明细全给，后者指页边界一致。
  ///
  /// ## `has_more`（2026-10-07 新增，`docs/reply.md` §1）
  ///
  /// 任一**分页实体**本页取满 `limit` ⇒ `has_more = true`。客户端据此循环拉到底，
  /// 不再把「拉了一页」当「同步完成」（审查 #9 / Android 报告 ③）。
  ///
  /// [docUpdatedSince]（毫秒）= **最近更新窗口**的下界：非 `null` 时额外返回
  /// `updated_at > docUpdatedSince` 的主单（签收 / 拒收 / 收款后的状态变化），
  /// 与主分页并进同一个 `documents` 数组。窗口**只带主单、不带明细**——
  /// 明细没变；新单的明细由后续常规分页补齐。见 [pull] 里的说明。
  ///
  /// [limit] 对**每个分页实体独立生效**，各自推进：某一个先拉完不影响其它。
  SyncPullResult pull({
    String stockSince = '0',
    String moneySince = '0',
    String partySince = '0',
    String settleSince = '0',
    String docSince = '',
    String productsSince = '',
    String partiesSince = '',
    String accountsSince = '',
    int limit = defaultPullLimit,
    int? docUpdatedSince,
  }) {
    final Map<String, List<Map<String, Object?>>> entities =
        <String, List<Map<String, Object?>>>{};
    final Map<String, String> next = <String, String>{};
    bool hasMore = false;

    void bySeqNo(String table, String key, String since) {
      final int from = _parseSeqNoCursor(since, key);
      final List<Map<String, Object?>> rows = _select(
        'SELECT * FROM $table WHERE seq_no > ? ORDER BY seq_no LIMIT ?',
        <Object?>[from, limit],
      );
      entities[table] = rows;
      next[key] = rows.isEmpty ? '$from' : '${rows.last['seq_no']! as int}';
      if (rows.length == limit) hasMore = true;
    }

    /// `(column, id)` 复合游标分页。
    ///
    /// ⚠️ [column] **只接受本文件里的字面量**（`created_at` / `updated_at`），
    /// 绝不来自客户端 —— 它会被拼进 SQL。列名白名单（`SyncWhitelist`）
    /// 约束的是**客户端可写**的列，不覆盖这里的查询列，所以这层把关靠约定 + 这段注释。
    void byStampCursor(String table, String column, String key, String since) {
      final SyncCursor from = SyncCursor.parse(since);
      final List<Map<String, Object?>> rows = _select(
        'SELECT * FROM $table '
        'WHERE $column > ? OR ($column = ? AND id > ?) '
        'ORDER BY $column, id LIMIT ?',
        <Object?>[from.stamp, from.stamp, from.id, limit],
      );
      entities[table] = rows;
      next[key] = rows.isEmpty
          ? from.wire
          : SyncCursor(
              rows.last[column]! as int,
              rows.last['id']! as String,
            ).wire;
      if (rows.length == limit) hasMore = true;
    }

    bySeqNo(Schema.stockLedger, SyncCursorKeys.stock, stockSince);
    bySeqNo(Schema.moneyLedger, SyncCursorKeys.money, moneySince);
    bySeqNo(Schema.partyLedger, SyncCursorKeys.party, partySince);
    bySeqNo(Schema.settlements, SyncCursorKeys.settle, settleSince);

    // documents 与「它这一页的明细」用**同一个页边界**：明细直接从
    // 本页 documents 的结果派生（见 [_linesOf]），不重跑一遍谓词，
    // 从结构上排除「两次查询页边界不一致」。
    byStampCursor(
      Schema.documents,
      'created_at',
      SyncCursorKeys.doc,
      docSince,
    );
    entities[Schema.documentLines] = _linesOf(<String>[
      for (final Map<String, Object?> doc in entities[Schema.documents]!)
        doc['id']! as String,
    ]);

    // ---- 最近更新窗口（2026-10-07，`docs/reply.md` §1「甲方案」）----
    //
    // **为什么需要它**：`documents` 的游标列是 `created_at`（不可变），
    // 而主机事后会改 `status` / `paid_amount` / `updated_at`（签收 / 拒收 /
    // 收款核销）。已拉过的单因此**永远不会再被推给手机** —— 手机一直显示
    // 「未收 / 在途」的旧态（审查报告 #7 / Android 测试报告 ④）。
    //
    // 改游标为 `(updated_at, id)` 被**明确否决**（同步基石不动、旧数据漏刷新
    // `updated_at` 会漏单）。所以：主分页**一个字不变**，另按 `updated_at`
    // 拉一段「最近动过的单」，与主分页**并进同一个 `documents` 数组**
    // （客户端按 id 幂等 upsert，两条路径都对同一行说同一件事）。
    final List<Map<String, Object?>> pageDocs = entities[Schema.documents]!;
    if (docUpdatedSince != null) {
      final Set<String> mainIds = <String>{
        for (final Map<String, Object?> doc in pageDocs) doc['id']! as String,
      };
      final List<Map<String, Object?>> window = _select(
        'SELECT * FROM ${Schema.documents} WHERE updated_at > ? '
        'ORDER BY updated_at, id LIMIT ?',
        <Object?>[docUpdatedSince, limit],
      );
      // ⚠️ **窗口取满不置 `has_more`**：它是「尽力而为的补齐」，不是协议分页。
      // 客户端每轮同步都重算窗口（`现在 − 窗口长度`），这次没带上的下一次会带上；
      // 若在这里置 `has_more`，一周内动过「≥ limit 张单」的店会**每次同步都
      // 拉不完**（而主分页其实早就拉到底了）—— 那是假信号。
      final List<Map<String, Object?>> fresh = <Map<String, Object?>>[
        for (final Map<String, Object?> row in window)
          if (!mainIds.contains(row['id'])) row,
      ];
      // 上限内合并：主分页优先，窗口行补在后面（超出的留给下一轮同步）
      final int room = limit - pageDocs.length;
      if (room > 0 && fresh.isNotEmpty) {
        final int take = fresh.length <= room ? fresh.length : room;
        pageDocs.addAll(fresh.sublist(0, take));
      }
    }

    // 主数据（R-13 方案 A）：软删行**照常返回**（客户端据此在本地标记删除），
    // 列**全给** —— 客户端要 `sync_version` 做下次更新的 `base_version`、
    // 要 `updated_at` 做游标。这里不筛选 `is_active`，是刻意的。
    byStampCursor(
      Schema.products,
      'updated_at',
      SyncCursorKeys.products,
      productsSince,
    );
    byStampCursor(
      Schema.parties,
      'updated_at',
      SyncCursorKeys.parties,
      partiesSince,
    );
    byStampCursor(
      Schema.accounts,
      'updated_at',
      SyncCursorKeys.accounts,
      accountsSince,
    );

    return SyncPullResult(
      entities: entities,
      nextCursors: next,
      hasMore: hasMore,
    );
  }

  /// 取「本页 `documents` 的全部明细」。谓词与主单页边界**完全一致**。
  /// 本页主单的明细。
  ///
  /// ⚠️ [documentIds] 直接来自**本页 `documents` 的实际结果**，
  /// 而不是把 `documents` 的谓词**再写一遍** —— 两次查询的页边界一旦
  /// 写法不同就会错位。曾经就是这样：明细查询漏了 `LIMIT`，
  /// 于是每一页都带上**后面所有主单**的明细（第 1 页就返回全量明细，
  /// 客户端还会先收到「主单还没到」的孤儿明细行）。
  ///
  /// 分批绑定参数：`IN (?, ?, …)` 的占位符数量受
  /// `SQLITE_MAX_VARIABLE_NUMBER` 约束（旧版 999），
  /// 而 `limit` 是客户端可控的，所以不假设它一定很小。
  List<Map<String, Object?>> _linesOf(List<String> documentIds) {
    const int batch = 500;
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
    for (int start = 0; start < documentIds.length; start += batch) {
      final int end = start + batch > documentIds.length
          ? documentIds.length
          : start + batch;
      final List<String> chunk = documentIds.sublist(start, end);
      rows.addAll(
        _select(
          'SELECT * FROM ${Schema.documentLines} '
          'WHERE document_id IN '
          '(${List<String>.filled(chunk.length, '?').join(', ')}) '
          'ORDER BY document_id, id',
          chunk,
        ),
      );
    }
    return rows;
  }


  // ------------------------------------------------------------ 内部

  SyncResponse _mapOutcome(String entityId, RuleOutcome outcome) {
    switch (outcome.status) {
      case RuleStatus.applied:
        return SyncResponse(entityId: entityId, status: SyncStatus.applied);
      case RuleStatus.alreadyExists:
        return SyncResponse(
          entityId: entityId,
          status: SyncStatus.alreadyExists,
        );
      case RuleStatus.rejected:
        return SyncResponse.rejected(entityId, outcome.reason ?? '规则拒绝');
    }
  }

  /// `payload.lines` → `DocumentLine` 列表。
  ///
  /// `document_id` 缺省时补成 [documentId] —— 它由 payload 结构唯一确定，
  /// 且 `RuleEngine` 还会再校验一次它是否等于主单 id，所以补默认值不会掩盖错误。
  List<DocumentLine> _linesFrom(Object? raw, {required String documentId}) {
    if (raw == null) return const <DocumentLine>[];
    if (raw is! List) throw const FormatException('payload.lines 必须是数组');
    return <DocumentLine>[
      for (final Object? item in raw)
        DocumentLine.fromRow(_lineRow(item, documentId)),
    ];
  }

  Map<String, Object?> _lineRow(Object? item, String documentId) {
    if (item is! Map) {
      throw const FormatException('payload.lines 的元素必须是对象');
    }
    final Map<String, Object?> row = Map<String, Object?>.from(item);
    final List<String> badColumns = SyncWhitelist.offendingColumns(
      Schema.documentLines,
      row.keys,
    );
    if (badColumns.isNotEmpty) {
      throw FormatException('document_lines 含不可写列：${badColumns.join(', ')}');
    }
    row['document_id'] ??= documentId;
    return SyncValueCheck.normalize(row);
  }

  List<T> _jsonList<T>(
    Object? raw,
    String field,
    T Function(Map<String, Object?>) fromJson,
  ) {
    if (raw == null) return <T>[];
    if (raw is! List) {
      throw FormatException('payload.$field 必须是数组');
    }
    return <T>[
      for (final Object? item in raw)
        if (item is Map)
          fromJson(SyncValueCheck.normalize(Map<String, Object?>.from(item)))
        else
          throw FormatException('payload.$field 的元素必须是对象'),
    ];
  }

  int _parseSeqNoCursor(String raw, String key) {
    final int? value = int.tryParse(raw);
    if (value == null) {
      throw FormatException('游标 $key 必须是整数，实际 "$raw"');
    }
    return value;
  }

  List<Map<String, Object?>> _select(String sql, List<Object?> args) =>
      <Map<String, Object?>>[
        for (final Row row in _raw.select(sql, args))
          Map<String, Object?>.from(row),
      ];

  /// ⚠️ [id] 是绑定参数，但 [table] 会拼进 SQL —— 调用点必须先过白名单。
  bool _exists(String table, String id) => _raw
      .select('SELECT 1 FROM $table WHERE id = ? LIMIT 1', <Object?>[id])
      .isNotEmpty;

  /// ⚠️ 同 [_exists]：`table` 必须已过白名单。
  Row? _findRow(String table, String id) {
    final ResultSet rows = _raw.select(
      'SELECT * FROM $table WHERE id = ?',
      <Object?>[id],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// ⚠️ `table` 与 `row.keys` 必须已过白名单。
  void _insertRow(String table, Map<String, Object?> row) {
    final List<String> columns = row.keys.toList(growable: false);
    _raw.execute(
      'INSERT INTO $table (${columns.join(', ')}) '
      'VALUES (${List<String>.filled(columns.length, '?').join(', ')})',
      <Object?>[for (final String column in columns) row[column]],
    );
  }

  /// ⚠️ 同 [_insertRow]。
  void _updateRow(String table, String id, Map<String, Object?> values) {
    if (values.isEmpty) return;
    final List<String> columns = values.keys.toList(growable: false);
    _raw.execute(
      'UPDATE $table SET '
      '${columns.map((String column) => '$column = ?').join(', ')} '
      'WHERE id = ?',
      <Object?>[for (final String column in columns) values[column], id],
    );
  }
}
