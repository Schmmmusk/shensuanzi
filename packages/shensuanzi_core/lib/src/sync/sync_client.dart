import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../dao/sync_dao.dart';
import '../db/database.dart';
import '../db/schema.dart';
import '../models/sync_queue_entry.dart';
import 'sync_operation.dart';
import 'sync_pull.dart';
import 'stock_delta.dart';
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
    this.docUpdateWindow = const Duration(days: 7),
    this.maxPullPages = 200,
  })     : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       cursors = SyncCursorDao(db),
       queue = SyncQueueDao(db),
       clockOffset = ClockOffsetDao(db) {
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

  /// 一次 `pull` 每实体最大行数
  final int pageLimit;

  /// 一次 `push` 最多推送的条目数
  final int batchLimit;

  /// **最近更新窗口**的长度（`docs/reply.md` §1 甲方案，2026-10-07）。
  ///
  /// `null` = 不请求窗口（旧行为，测试里也用得上）。非 `null` 时每次 `pull`
  /// 都请主机额外返回「`updated_at` 在窗口内」的主单 —— 签收 / 拒收 / 收款
  /// 只改 `status` / `paid_amount` / `updated_at`，而 `documents` 的游标列是
  /// 不可变的 `created_at`，不这样取的话手机**永远看不到**这些变化。
  ///
  /// 7 天是「够长到覆盖手机离线一阵子，又短到不会让每页都拖一大坨」的折中；
  /// 窗口边缘漏掉的行会在下一次同步的窗口里被补上（每次都是**开区间**查询）。
  final Duration? docUpdateWindow;

  /// `pull` 一次最多循环多少页（防主机分页出错时**无限循环**）。
  ///
  /// 200 页 × `pageLimit` 500 = 10 万行/实体，远超个体户的年度体量。
  /// 到顶仍 `has_more` ⇒ 结果如实标 `hasMore: true`，让 UI 说「还没同步完」
  /// —— 与「假装完成」相比，这是唯一诚实的处置。
  final int maxPullPages;

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

  // ---------------------------------------------------------------- 镜像重建

  /// 每条建表语句 → 表名（首次访问时从 [Schema.createStatements] 推导；
  /// Schema 加表自动跟上，**没有手维护的映射可漂移**）。
  static final Map<String, String> _createByTable = () {
    final RegExp pattern = RegExp(r'CREATE TABLE\s+(\w+)');
    return <String, String>{
      for (final String sql in Schema.createStatements)
        if (pattern.firstMatch(sql) != null)
          pattern.firstMatch(sql)!.group(1)!: sql,
    };
  }();

  /// 镜像重建（`schema_migration.md` §六：**重建而非迁移**）。
  ///
  /// 镜像是**派生数据**（真相在主机）⇒ 客户端不写迁移逻辑：主机 schema 版本
  /// 与本地镜像不一致时，**drop 全部镜像表 + 重建 + 游标清零**（下次 pull
  /// 从头全量拉）。版本比对由应用层做（`/api/health` 的 `schema_version` vs
  /// 镜像库的 `user_version`，后者 `Db.schemaVersion` 直读）。
  ///
  /// ⚠️ **`sync_queue` 不动** —— 队列里是客户端自己创建、还没被主机确认的
  /// 操作（payload 内嵌在队列行里），不是派生数据；清了它 = 丢用户离线单。
  /// `clock_offset` 同理保留（客户端时钟校准，与镜像内容无关）。
  void rebuildMirror() {
    db.transaction<void>(() {
      for (final String table in applyOrder.reversed) {
        _raw.execute('DROP TABLE IF EXISTS $table');
      }
      for (final String table in applyOrder) {
        final String? sql = _createByTable[table];
        if (sql == null) {
          // Schema 加了表但没进 applyOrder（或反之）⇒ 立刻炸出来，不许静默
          throw StateError('镜像重建：applyOrder 里的 $table 找不到建表语句');
        }
        _raw.execute(sql);
      }
      cursors.clear();
    });
  }

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

  /// 增量拉取（§8.2）。**循环拉到底**（见下方 ⚠️）。
  ///
  /// **行与游标在同一个事务内落库**（R-14 §4.3）。崩溃点只有两种：
  ///
  /// - 「应用了行、没写游标」→ 下次重复拉（幂等 upsert，**无害**）
  /// - 「写了游标、没应用行」→ **静默丢数据**
  ///
  /// 同事务保证**永远不会出现后者** —— **每页**一个事务。
  Future<SyncPullReport> pull({int? limit}) async {
    // ⚠️ **循环拉到 `has_more == false`**（2026-10-07，`docs/reply.md` §1）：
    // 从前只拉一页就返回，于是「首次同步」几乎必然只拉了前 500 行流水，
    // 而调用方对用户显示「同步完成」—— 库存与往来是照着**残缺镜像**算出来的
    // （审查 #8/#9、Android 报告 ③）。
    //
    // 「每页一个事务」是刻意的：页与页之间**已落库 + 游标已推进**，
    // 中断只需重跑（幂等 upsert + 开区间游标），不会退回去。
    final Map<String, int> totals = <String, int>{};
    int pages = 0;
    int cleared = 0;
    bool hasMore = true;
    while (hasMore) {
      final SyncPullReport page = await _pullPage(
        limit: limit,
        firstPage: pages == 0,
      );
      pages++;
      hasMore = page.hasMore;
      cleared += page.confirmedQueueEntries;
      page.entities.forEach((String entity, int count) {
        totals[entity] = (totals[entity] ?? 0) + count;
      });
      if (pages >= maxPullPages) {
        // 跑了这么多页还没到底 ⇒ 主机侧分页有问题，**如实报告为「没拉完」**
        // 而不是假装完成（宁可诚实地说「还没同步完」，也不要看起来精确的错误）
        hasMore = true;
        break;
      }
    }

    return SyncPullReport(
      entities: totals,
      nextCursors: cursors.getAll(),
      confirmedQueueEntries: cleared,
      pages: pages,
      hasMore: hasMore,
    );
  }

  /// 一页 `pull`（协议层：请求 → 落库 → 存游标），由 [pull] 循环驱动。
  ///
  /// [firstPage] 决定**要不要带最近更新窗口**。窗口是「当前时刻 − 窗口长度」，
  /// 每页都带会出两个问题（都实测得到）：
  ///
  /// - 窗口本身取满一页 ⇒ `has_more` **永远是 true** ⇒ 稳态同步永远「拉不完」
  /// - 窗口取到的是**最新**那一批，若每页都带，后页会把早先跳过的行重复带回来
  ///
  /// 所以**只有第一页带窗口**：窗口是「这一轮同步开始时，最近动过的单据」，
  /// 一轮只要取一次就够（它本来就是拿来补 `created_at` 感知不到的状态变化）。
  Future<SyncPullReport> _pullPage({int? limit, bool firstPage = true}) async {
    final int now = _clock();
    final Map<String, String> since = cursors.getAll();

    // 最近更新窗口的下界 = 「现在 − [docUpdateWindow]」。传绝对毫秒（不传天数）：
    // 客户端本地时钟可以歪，但歪的是**窗口边缘**，漏掉一行会在下一次同步的
    // 窗口里被补回来；而「主机时间」客户端拿不到，硬要反而要额外一次握手。
    final int? docUpdatedSince = docUpdateWindow == null || !firstPage
        ? null
        : now - docUpdateWindow!.inMilliseconds;

    final TransportResponse response = await transport.send(
      TransportRequest(
        method: 'GET',
        uri: baseUri.resolve(pullPath).replace(
          queryParameters: <String, String>{
            ...since,
            'limit': '${limit ?? pageLimit}',
            if (docUpdatedSince != null)
              'doc_updated_since': '$docUpdatedSince',
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
      // ⚠️ **队列清理只在「这一轮拉到底」时做**（2026-10-07，`docs/reply.md` §2）：
      // 从前每页都清 —— 主单排在后面的页时，队列条目先被清掉、单据后到，
      // 而且清早了会让「未同步影响」的叠加提前消失 ⇒ 库存显示**少计**
      // （Android 测试报告 ⑤）。`applied` 是**本轮已落镜像**的 id 集合，
      // `clearConfirmed` 只删「已 sent 且确实见到」的条目，其余照留。
      if (!result.hasMore) {
        cleared = queue.clearConfirmed(applied);
      }
    });

    return SyncPullReport(
      entities: <String, int>{
        for (final String table in SyncPullResult.entityNames)
          table: result.entities[table]?.length ?? 0,
      },
      nextCursors: result.nextCursors,
      confirmedQueueEntries: cleared,
      pages: 1,
      hasMore: result.hasMore,
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
  /// C1：实现搬到了 [StockDelta.deltaOf]（手机端库存视图不依赖传输层也要用
  /// 同一份计算）；此处保留原 API 作转调 —— 行为零变化。
  ///
  /// 只做 `±quantity` 累加：**不算成本、不算往来、不算盘点**（盘点诚实贡献 0）。
  static Map<String, int> deltaOf(SyncQueueEntry entry) =>
      StockDelta.deltaOf(entry);

  /// 全部「已发生、但权威状态还没包含」的库存影响之和（`pending` + `sent` +
  /// `failed` 都算）。UI 的表达式是：
  ///
  /// ```
  /// 显示库存 = 权威镜像 + delta   ← 用 stockViewOf 一次算好
  /// ```
  ///
  /// C1：转调 [StockDelta.unsyncedDelta]（行为零变化）。
  Map<String, int> unsyncedDelta() =>
      StockDelta(db: db, queue: queue).unsyncedDelta();

  /// 给 UI 用：`权威库存 + 未同步影响`，并给出拆解（C1：转调 [StockDelta]）。
  ///
  /// 「权威镜像 10、未同步 −3」这样的拆解要能点开看到是哪几张单 ——
  /// 所以返回结构里带 [StockView.contributors]。
  StockView stockViewOf(String productId) =>
      StockDelta(db: db, queue: queue).stockViewOf(productId);

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
    this.pages = 1,
    this.hasMore = false,
  });

  /// 每个实体本次落库的行数（**本次 `pull` 全部页的合计**）
  final Map<String, int> entities;

  /// 主机返回的新游标（已原样存进 `sync_cursor`）
  final Map<String, String> nextCursors;

  /// 本次清除的队列条目数（`sent` 且已确认）
  final int confirmedQueueEntries;

  /// 本次实际请求了几页（1 = 一页就到底）
  final int pages;

  /// **还没拉完**（`_pullPage` 的 `has_more`，或循环撞上 `maxPullPages`）。
  ///
  /// 调用方**不许**在它为 `true` 时说「同步完成」—— 镜像只是部分权威，
  /// 库存 / 往来都是残缺的（2026-10-07 裁定，`docs/reply.md` §1）。
  final bool hasMore;

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

  /// 业务拒绝 → 已排重试（回执分类见 `sync_protocol.md` §8.5）
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
