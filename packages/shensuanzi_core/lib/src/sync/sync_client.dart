import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../dao/query_dao.dart';
import '../dao/sync_dao.dart';
import '../db/database.dart';
import '../db/schema.dart';
import '../models/sync_queue_entry.dart';
import 'sync_operation.dart';
import 'sync_pull.dart';
import 'transport.dart';

/// 客户端同步引擎（`docs/sync_protocol.md`）。
///
/// ## 边界
///
/// - **不含传输实现**：通过注入的 [Transport] 发请求（见 `transport.dart`）。
///   于是本类可在没有网络的环境里被完整测试，core 也保持零新依赖
/// - **不含业务规则**（R-14 附带问题 3 的裁定）：客户端**不跑 `RuleEngine`**。
///   成本、往来余额、盘点一律等主机 —— 客户端只维护
///   「已发生、但权威状态还没包含」的**数量 delta**（见 [deltaOf]）
/// - **不解析游标**：游标原样来自 / 回到主机（见 `SyncCursorDao`）
///
/// ## 两条写入路径的区别（R-14 §三）
///
/// | 路径 | 谁做的 |
/// |---|---|
/// | `pull` | 主机 → 客户端**镜像**（权威状态） |
/// | `push` | 客户端 → 主机 → **回程不经过 pull**，镜像要等下次 pull 才更新 |
/// | 本地离线写 | 客户端 → 镜像 + `sync_queue`（**推送前就在本地**） |
///
/// 正因为后端两条路径存在，「用本地镜像推算游标」会**静默丢数据** ——
/// 这是 R-14 选方案 A 的直接理由。
class SyncClient {
  SyncClient({
    required this.db,
    required this.transport,
    required this.baseUri,
    required this.token,
    int Function()? clock,
    this.pageLimit = 500,
    this.batchLimit = 200,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       cursors = SyncCursorDao(db),
       queue = SyncQueueDao(db),
       clockOffset = ClockOffsetDao(db),
       _queries = QueryDao(db) {
    if (db.foreignKeysEnabled) {
      throw StateError(
        '客户端镜像必须用 `Db.open(path, foreignKeys: false)` 打开。\n'
        '主机是权威，完整性由主机保证；客户端一侧的 FK 会让 pull 变成**毒丸**：\n'
        '某一行引用的主数据若落在本页之外（`limit` 分页），该行永远插不进去，\n'
        '于是 pull 每次都整批回滚 —— 而回滚又把游标退回去，形成死循环。\n'
        '（`PRAGMA foreign_keys` 在事务内是 no-op，所以这一步只能在打开时定，\n'
        '无法由 pull 自己临时关闭。）',
      );
    }
  }

  final Db db;
  final Transport transport;

  /// 主机地址，如 `http://127.0.0.1:17890`（来自配对二维码）
  final Uri baseUri;

  /// 配对令牌（来自配对二维码，`sync_protocol.md` §9.1）
  final String token;

  final SyncCursorDao cursors;
  final SyncQueueDao queue;
  final ClockOffsetDao clockOffset;
  final QueryDao _queries;

  /// 一次 `pull` 每实体最大行数
  final int pageLimit;

  /// 一次 `push` 最多推送的条目数
  final int batchLimit;

  final int Function() _clock;

  /// 超过此次数进死信（`sync_protocol.md` §六）
  static const int maxRetries = 10;

  static const String pushPath = '/api/sync/push';
  static const String pullPath = '/api/sync/pull';

  /// 落库顺序 —— **按引用依赖排**，与 §8.2 的字段顺序**不同**。
  ///
  /// §8.2 按「业务数据在前、主数据在后」列字段（那是**阅读顺序**：
  /// 主数据是附录）。但落库时 `document_lines` / `stock_ledger` 都引用
  /// `products`，照字段顺序写会先插子行、后插父行。
  ///
  /// 当前客户端镜像的 FK 是关闭的（见构造函数），所以顺序**不影响正确性**；
  /// 但按依赖顺序应用是**零成本**的，而且让行为不依赖那个开关 ——
  /// 将来若有人把它打开，这里不会突然炸。
  static const List<String> applyOrder = <String>[
    Schema.products,
    Schema.parties,
    Schema.accounts,
    Schema.documents,
    Schema.documentLines,
    Schema.stockLedger,
    Schema.moneyLedger,
    Schema.partyLedger,
    Schema.settlements,
  ];

  Database get _raw => db.raw;

  Map<String, String> _headers() => <String, String>{
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  // ---------------------------------------------------------------- 推送

  /// 推送队列里到期的条目。
  ///
  /// 回执**按 `entity_id` 配对，不按下标**（§六）；某条没有回执按失败处理。
  Future<SyncPushReport> push({int? maxEntries}) async {
    final int now = _clock();
    final List<SyncQueueEntry> entries = queue.due(
      now,
      limit: maxEntries ?? batchLimit,
    );
    if (entries.isEmpty) return SyncPushReport.empty;

    final TransportResponse response;
    try {
      response = await transport.send(
        TransportRequest(
          method: 'POST',
          uri: baseUri.resolve(pushPath),
          headers: _headers(),
          body: jsonEncode(
            SyncPushRequest(
              operations: <SyncOperation>[
                for (final SyncQueueEntry entry in entries) entry.toOperation(),
              ],
            ).toJson(),
          ),
        ),
      );
    } catch (error) {
      // 连不上：整批退避，**不改业务状态**（条目仍是 pending）
      _retryAll(entries, '传输失败：$error', now);
      return SyncPushReport(
        attempts: entries.length,
        retried: entries.length,
        lastError: '$error',
      );
    }

    if (response.statusCode != 200) {
      _retryAll(entries, 'HTTP ${response.statusCode}', now);
      throw SyncHttpException(response.statusCode, response.body);
    }

    final Map<String, SyncResponse> receipts = SyncPushResponse.fromJson(
      _jsonBody(response.body),
    ).byEntityId();

    int sent = 0;
    int conflicts = 0;
    int rejected = 0;
    int retried = 0;
    final List<String> errors = <String>[];

    db.transaction<void>(() {
      for (final SyncQueueEntry entry in entries) {
        final SyncResponse? receipt = receipts[entry.entityId];
        if (receipt == null) {
          _retry(entry, '主机未返回该条目的回执', now);
          retried++;
          errors.add('${entry.entityId}: 无回执');
          continue;
        }
        switch (receipt.status) {
          case SyncStatus.applied:
          case SyncStatus.alreadyExists:
            // ⚠️ **不删除** —— 改为 `sent`，等 pull 确认（R-14 附带问题 3）
            queue.markSent(entry.id);
            sent++;
          case SyncStatus.conflict:
            // §四：主机赢 —— 用 server_state 覆盖本地，并删掉队列条目
            if (receipt.serverState != null) {
              _upsertRow(entry.entity, receipt.serverState!);
            }
            queue.delete(entry.id);
            conflicts++;
          case SyncStatus.rejected:
            // 业务拒绝 → 排重试（**同时**计入 rejected 与 retried：
            // 前者是「为什么失败」的归类，后者是「接下来怎么办」的处置）
            _retry(entry, receipt.reason ?? 'rejected', now);
            rejected++;
            retried++;
            errors.add('${entry.entityId}: ${receipt.reason ?? 'rejected'}');
        }
      }
    });

    return SyncPushReport(
      attempts: entries.length,
      sent: sent,
      conflicts: conflicts,
      rejected: rejected,
      retried: retried,
      errors: errors,
    );
  }

  /// 整批退避（传输层失败 / 非 200）
  void _retryAll(List<SyncQueueEntry> entries, String error, int now) {
    db.transaction<void>(() {
      for (final SyncQueueEntry entry in entries) {
        _retry(entry, error, now);
      }
    });
  }

  /// 单条排下次重试：指数退避 `1s, 4s, 16s, 64s …`，超限进死信（§六）。
  void _retry(SyncQueueEntry entry, String error, int now) {
    final int retryCount = entry.retryCount + 1;
    queue.markFailed(
      entry.id,
      error: error,
      retryCount: retryCount,
      nextRetryAt: now + _backoffMs(retryCount),
      dead: retryCount > maxRetries,
    );
  }

  static int _backoffMs(int retryCount) {
    int ms = 1000;
    for (int i = 1; i < retryCount; i++) {
      ms *= 4;
    }
    return ms;
  }

  // ---------------------------------------------------------------- 拉取

  /// 增量拉取（§8.2）。
  ///
  /// **行与游标在同一个事务内落库**（R-14 §4.3）。崩溃点只有两种：
  ///
  /// - 「应用了行、没写游标」→ 下次重复拉（幂等 upsert，**无害**）
  /// - 「写了游标、没应用行」→ **静默丢数据**
  ///
  /// 同事务保证**永远不会出现后者**。
  Future<SyncPullReport> pull({int? limit}) async {
    final int now = _clock();
    final Map<String, String> since = cursors.getAll();

    final TransportResponse response = await transport.send(
      TransportRequest(
        method: 'GET',
        uri: baseUri.resolve(pullPath).replace(
          queryParameters: <String, String>{
            ...since,
            'limit': '${limit ?? pageLimit}',
          },
        ),
        headers: _headers(),
      ),
    );

    if (response.statusCode != 200) {
      throw SyncHttpException(response.statusCode, response.body);
    }

    final SyncPullResult result = SyncPullResult.fromJson(
      _jsonBody(response.body),
    );

    final Set<String> applied = <String>{};
    int cleared = 0;

    db.transaction<void>(() {
      // 按 [applyOrder] 落库（**不是** §8.2 的字段顺序）
      for (final String table in applyOrder) {
        final List<Map<String, Object?>>? rows = result.entities[table];
        if (rows == null) continue;
        for (final Map<String, Object?> row in rows) {
          _upsertRow(table, row);
          applied.add(row['id']! as String);
        }
      }
      // 游标：原样保存主机返回值，**不解析**
      cursors.upsertAll(result.nextCursors, now: now);
      // 已推送且**本次实际见到**的条目 → 清除（见 clearConfirmed 的注释）
      cleared = queue.clearConfirmed(applied);
    });

    return SyncPullReport(
      entities: <String, int>{
        for (final String table in SyncPullResult.entityNames)
          table: result.entities[table]?.length ?? 0,
      },
      nextCursors: result.nextCursors,
      confirmedQueueEntries: cleared,
    );
  }

  /// 落一行。**表名已在 [SyncPullResult.fromJson] 收窄到 9 个实体**，
  /// 所以这里拼进 SQL 的表名不可能来自客户端输入（`documents` 那一路
  /// 走的是 `createDocument`，与这里无关）。
  ///
  /// 用 `ON CONFLICT(id) DO UPDATE` 而非 `INSERT OR REPLACE`：
  /// 后者是「删了再插」，在开启外键时会被子行引用挡下
  /// （`documents` 被五张表引用）。真正的 upsert 不删行。
  void _upsertRow(String table, Map<String, Object?> row) {
    if (!SyncPullResult.entityNames.contains(table)) {
      throw ArgumentError('不在实体白名单内的表名：$table');
    }
    final Object? id = row['id'];
    if (id is! String || id.isEmpty) {
      throw FormatException('$table 的行缺少 id：$row');
    }
    final List<String> columns = row.keys.toList(growable: false);
    final String marks = List<String>.filled(columns.length, '?').join(', ');
    final String assignments = <String>[
      for (final String column in columns)
        if (column != 'id') '$column = excluded.$column',
    ].join(', ');

    try {
      _raw.execute(
        'INSERT INTO $table (${columns.join(', ')}) VALUES ($marks) '
        'ON CONFLICT(id) DO UPDATE SET $assignments',
        <Object?>[for (final String column in columns) row[column]],
      );
    } on SqliteException catch (error) {
      // 唯一的非 id 约束是 `documents.doc_no`（UNIQUE）。
      // 主机侧 `doc_no` 本身唯一，所以这条在正常同步里**不该出现** ——
      // 出现即意味着本地镜像已损坏（例如本地占位单号撞上了主机单号）。
      // 包一层 StateError 把「哪张表、哪一行、什么约束」讲清楚，
      // 否则调用方只看到一句 `SqliteException(2067)`。
      throw StateError(
        '落库 $table 的行（id=$id）失败：${error.message}\n'
        '若为 UNIQUE 冲突：主机侧 doc_no 唯一，正常同步不会撞 —— '
        '大概率是本地镜像损坏（本地占位单号与主机单号相同）。'
        '修复路径是重建镜像 + 全量重新拉取（游标清空即从头拉）。',
      );
    }
  }

  // ------------------------------------------------------- 未同步影响（delta）

  /// 一条队列条目对**库存数量**的影响（纯函数，`sync_protocol.md` §一）。
  ///
  /// 只做 `±quantity` 累加：**不算成本、不算往来、不算盘点**。
  ///
  /// | `doc_type` | 符号 | 为什么 |
  /// |---|---|---|
  /// | `purchase` / `sale_return` | **+** | 货进店 |
  /// | `sale` / `delivery` / `purchase_return` | **−** | 货离店 |
  /// | `stocktake` | `0` | 它的影响是「实际数量 − 账面数量」，而账面数量依赖完整流水 —— **客户端算不出**，所以诚实地贡献 0。盘点是低频操作，用户不会期望中途看到估算 |
  /// | `receipt` / `payment` | `0` | 资金单据，不影响库存 |
  ///
  /// 不做任何校验（负库存允许，`threat_model.md` §3.4），UI 标红即可。
  static Map<String, int> deltaOf(SyncQueueEntry entry) {
    if (entry.operation != SyncOpType.createDocument) {
      return const <String, int>{}; // 主数据与动作不影响库存数量
    }
    final Object? rawDocument = entry.payload['document'];
    if (rawDocument is! Map) return const <String, int>{};
    final Object? rawType = rawDocument['doc_type'];
    if (rawType is! String) return const <String, int>{};

    final int sign = switch (rawType) {
      'purchase' || 'sale_return' => 1,
      'sale' || 'delivery' || 'purchase_return' => -1,
      _ => 0, // 含 stocktake / receipt / payment
    };
    if (sign == 0) return const <String, int>{};

    final Object? rawLines = entry.payload['lines'];
    if (rawLines is! List) return const <String, int>{};

    final Map<String, int> delta = <String, int>{};
    for (final Object? rawLine in rawLines) {
      if (rawLine is! Map) continue;
      final Object? productId = rawLine['product_id'];
      final Object? quantity = rawLine['quantity'];
      if (productId is! String || quantity is! int) continue;
      delta[productId] = (delta[productId] ?? 0) + sign * quantity;
    }
    return delta;
  }

  /// 全部「已发生、但权威状态还没包含」的库存影响之和（`pending` + `sent` +
  /// `failed` 都算）。UI 的表达式是：
  ///
  /// ```
  /// 显示库存 = 权威镜像 + delta   ← 用 stockViewOf 一次算好
  /// ```
  Map<String, int> unsyncedDelta() {
    final Map<String, int> total = <String, int>{};
    for (final SyncQueueEntry entry in queue.all()) {
      deltaOf(entry).forEach((String productId, int value) {
        total[productId] = (total[productId] ?? 0) + value;
      });
    }
    return total;
  }

  /// 给 UI 用：`权威库存 + 未同步影响`，并给出拆解。
  ///
  /// 「权威镜像 10、未同步 −3」这样的拆解要能点开看到是哪几张单 ——
  /// 所以返回结构里带 [StockView.contributors]。
  StockView stockViewOf(String productId) {
    final int authoritative = _queries.stockByProduct()[productId] ?? 0;
    final List<SyncQueueEntry> contributors = <SyncQueueEntry>[
      for (final SyncQueueEntry entry in queue.all())
        if (deltaOf(entry).containsKey(productId)) entry,
    ];
    final int delta = contributors.fold<int>(
      0,
      (int sum, SyncQueueEntry entry) => sum + (deltaOf(entry)[productId] ?? 0),
    );
    return StockView(
      productId: productId,
      authoritative: authoritative,
      unsynced: delta,
      contributors: contributors,
    );
  }

  // ---------------------------------------------------------------- 时钟

  /// 记录时钟偏移（配对 / 每次 `health` 之后调用）。
  ///
  /// `offset = server_time - client_time`；离线期间用
  /// `client_time + offset` **估算** `occurred_at` 并标记 `time_estimated = 1`
  /// （`sync_protocol.md` §七）。
  int recordClockOffset(int serverTime) {
    final int now = _clock();
    final int offset = serverTime - now;
    clockOffset.set(offset, now: now);
    return offset;
  }

  /// 估算「现在」的主机时刻
  int estimatedServerTime() => _clock() + clockOffset.offsetMs;

  static Map<String, Object?> _jsonBody(String body) {
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('响应体不是 JSON 对象');
    }
    return Map<String, Object?>.from(decoded);
  }
}

/// `pull` 的结果摘要（供调用方展示 / 测试断言）
class SyncPullReport {
  const SyncPullReport({
    required this.entities,
    required this.nextCursors,
    this.confirmedQueueEntries = 0,
  });

  /// 每个实体本次落库的行数
  final Map<String, int> entities;

  /// 主机返回的新游标（已原样存进 `sync_cursor`）
  final Map<String, String> nextCursors;

  /// 本次清除的队列条目数（`sent` 且已确认）
  final int confirmedQueueEntries;

  int get totalRows => entities.values.fold<int>(0, (int a, int b) => a + b);
}

/// `push` 的结果摘要
class SyncPushReport {
  const SyncPushReport({
    this.attempts = 0,
    this.sent = 0,
    this.conflicts = 0,
    this.rejected = 0,
    this.retried = 0,
    this.errors = const <String>[],
    this.lastError,
  });

  static const SyncPushReport empty = SyncPushReport();

  final int attempts;

  /// 主机收下（`applied` / `already_exists`）→ 条目转为 `sent`
  final int sent;

  /// 乐观锁冲突 → 本地已被 `server_state` 覆盖、条目已删
  final int conflicts;

  /// 业务拒绝（含 v1 的 `action_not_implemented`）→ 已排重试
  final int rejected;

  /// 排入重试（含传输失败、无回执）
  final int retried;

  final List<String> errors;
  final String? lastError;
}

/// 单商品的库存视图：`权威 + 未同步`
class StockView {
  const StockView({
    required this.productId,
    required this.authoritative,
    required this.unsynced,
    this.contributors = const <SyncQueueEntry>[],
  });

  final String productId;

  /// 权威镜像（来自主机）
  final int authoritative;

  /// 未同步影响（本地 ± 累加）
  final int unsynced;

  /// 贡献该影响的队列条目 —— UI 展开「这 3 件是哪张单卖的」
  final List<SyncQueueEntry> contributors;

  int get display => authoritative + unsynced;

  /// 是否有未同步影响（UI 决定是否展示那行拆解）
  bool get hasUnsynced => unsynced != 0;
}
