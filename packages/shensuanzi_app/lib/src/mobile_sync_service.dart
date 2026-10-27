/// 手机端同步服务（§BL·二，2026-10-05 裁定）—— 把 core 的 `SyncClient`、
/// 镜像库、配对凭据串成**一个入口**：`syncNow()`。
///
/// ## 镜像库（裁定 ④）
///
/// 路径 `<应用私有目录>/mirror/shensuanzi_mirror.db`，`Db.open` 时
/// `foreignKeys: false`（`SyncClient` 构造函数有毒丸守卫，开着会直接拒绝）。
///
/// ## 镜像重建（`schema_migration.md` §六，逻辑在 `SyncClient.rebuildMirror`）
///
/// `/api/health` 返回主机的 `schema_version`；**主机版本比镜像高** ⇒ 客户端
/// 不做迁移（镜像是派生数据）⇒ drop 九表重建 + 游标清零，本次 pull 从头全量拉。
///
/// ## 配对失效（§BL 裁定 ②）
///
/// 任何请求返回 **401 / 403** ⇒ 配对失效（主机重启过 / 重新生成了配对码）
/// ⇒ 返回 `SyncOutcomeKind.authExpired`，UI 引导重新扫码
/// （`forgetHost()` 清除 `pairing.json` 的动作也在本服务里）。
///
/// ## 包边界
///
/// 本文件在 `shensuanzi_app`（纯 Dart）—— **不依赖 host**（裁定）；
/// 配对载荷解析用 core 的 `PairingPayload`（§BL·一 迁入）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;

import 'package:path/path.dart' as p;
import 'package:shensuanzi_core/shensuanzi_core.dart'
    show
        Db,
        MirrorMeta,
        PairingPayload,
        SyncClient,
        SyncHttpException,
        SyncPullReport,
        SyncPushReport,
        SyncQueueDao,
        SyncQueueEntry,
        SyncQueueStatus,
        SyncQueueTriage,
        Transport,
        TransportRequest,
        TransportResponse,
        ensureSchemaIndexes;

import 'http_transport.dart';
import 'sync_failure_message.dart';
import 'mirror_archive.dart';
import 'pairing_address.dart';
import 'pairing_store.dart';

/// 一次 `syncNow()` 的结果。
enum SyncOutcomeKind {
  /// 成功（可能带「重建了镜像」标记）
  ok,

  /// 还没配对（pairing.json 不存在）
  notPaired,

  /// 连不上主机（超时 / 拒连 —— 文案已含「怎么办」）
  unreachable,

  /// 配对失效（401 / 403）—— UI 引导重新扫码
  authExpired,

  /// 其它错误（主机 5xx / 数据异常等）
  error,
}

class SyncOutcome {
  /// 通用构造（**必须公开** —— 宿主 `app.dart` 也要能造兜底结果）
  const SyncOutcome(this.kind, this.message, {this.rebuilt = false});

  /// 成功
  const SyncOutcome.ok(this.message, {this.rebuilt = false})
    : kind = SyncOutcomeKind.ok;

  final SyncOutcomeKind kind;

  /// 给用户看的话（说「怎么办」；UI 直接展示，不造句）
  final String message;

  /// 本次是否触发了镜像重建（主机 schema 版本高于镜像）
  final bool rebuilt;
}

/// 手机端同步服务。镜像库与凭据文件由调用方注入路径（可测）。
class MobileSyncService {
  MobileSyncService({
    required this.mirrorPath,
    required this.pairingStore,
    this.transport,
    this.onError,
    int? Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 镜像库文件路径（`<私有目录>/mirror/shensuanzi_mirror.db`，裁定 ④）
  final String mirrorPath;

  /// 配对凭据（`pairing.json`，裁定 ②：与 config 分离）
  final PairingStore pairingStore;

  /// 传输层；`null` = 生产用 [HttpTransport]（测试注入桩）
  final Transport? transport;

  /// **原始异常的唯一去处**（F15 / M15 两通道）：界面只给人话
  /// （[syncFailureMessage]），`toString()` + 栈进日志。
  /// `null` = 不记（测试 / 未装配日志的宿主）。
  final void Function(Object error, StackTrace stack, String label)? onError;

  final int? Function() _clock;

  Db? _mirror;
  bool _syncing = false;

  /// 换主机时的镜像归档（F14，2026-10-25 裁定）。落点 = 镜像库的兄弟目录 `archive/`。
  late final MirrorArchive archive = MirrorArchive(
    mirrorPath: mirrorPath,
    // 本服务的 clock 允许返回 null（测试可注入"读不到时间"），归档要一个确定的毫秒
    clock: () => _clock() ?? DateTime.now().millisecondsSinceEpoch,
  );

  /// 镜像的身份标记（哪台主机的镜像）。**判定换主机看它，不看 `pairing.json`。**
  MirrorMeta _meta() => MirrorMeta(openMirror());

  /// 打开（或创建）镜像库。库的生命周期跟随服务（app 退出时 close）。
  ///
  /// ⚠️ **先建父目录**（`mirror/`）—— sqlite3 只建文件、不建中间目录，
  /// 父目录不存在 = `SqliteException(14) unable to open database file`
  /// （真机首跑踩过：§BL·落地·补 2）。
  Db openMirror() {
    if (_mirror == null) {
      Directory(p.dirname(mirrorPath)).createSync(recursive: true);
      final Db opened = Db.open(mirrorPath, foreignKeys: false);
      // ⚠️ **自愈：补建缺失的索引**（2026-10-26 真机 P0）。
      //
      // `SyncClient.rebuildMirror()` 从前只重放建表语句，而 `DROP TABLE` 会把索引
      // 一起删掉 ⇒ 现网手机上**已经**有一个没有索引的镜像。
      // `QueryDao.recentProducts` / `recentParties` 用 `INDEXED BY`（硬提示），
      // 缺索引是直接报错 —— 现场表现就是「点『选商品』整页变错误边界」。
      //
      // `CREATE INDEX IF NOT EXISTS` 幂等，索引齐了就是空转（十几条语句，
      // 只在**首次打开镜像**时跑一次，不是每次查询）。
      ensureSchemaIndexes(opened.raw);
      _mirror = opened;
    }
    return _mirror!;
  }

  /// 当前镜像的 schema 版本（`user_version`；fresh 库 = `Schema.version`）
  int get mirrorSchemaVersion => openMirror().schemaVersion;

  /// 「忘记这台主机」/ 配对失效后的重置
  void forgetHost() {
    pairingStore.clear();
  }

  /// 手动「重建本机数据副本」（F14 的 UI 出口）。
  ///
  /// 与换主机的区别：**身份不变**（还是同一台主机）⇒ 不清 `mirror_meta`、
  /// 不需要重新扫码。用于「镜像坏了 / 数字明显不对 / 拉了一半」的兜底。
  ///
  /// 顺序 = 归档 → 挂起未推送队列 → 重建镜像（游标清零）⇒ 下次同步从头全量拉。
  /// 返回被挂起的队列条数（UI 用它多说一句）。
  int rebuildLocalCopy() {
    final MirrorMeta meta = _meta();
    return resetForNewHost(previousHostId: meta.hostId);
  }

  /// 已有的历史主机归档（设置页「历史主机数据」列表用），新 → 旧。
  List<MirrorArchiveEntry> archives() => archive.list();

  /// **换主机 = 重置同步状态**（2026-10-07 裁定，审计报告 #3 / Android 报告 ②）。
  ///
  /// ## 为什么必须重置
  ///
  /// 镜像 + 游标 + 队列都是**针对某一台主机**的状态：
  /// 游标说「这台主机已交付到哪里」，镜像是这台主机的权威快照。
  /// 换主机后继续用它们，会出现两件事故：
  ///
  /// - **漏数据**：新主机的 `seq_no` / 时间戳与旧主机毫无关系，旧游标会让
  ///   pull 从「新主机的某个中间位置」开始 ⇒ 前半截永远拉不到
  /// - **交错数据**：旧主机的镜像行还在本地，与新主机行混在一张表里
  /// - **推错机器**：离线队列里是「本来要发给旧主机」的单，
  ///   自动推送会把它发给新主机（账就记到别人店里去了）
  ///
  /// ## 怎么重置
  ///
  /// - 镜像：`rebuildMirror()`（drop 九表 + 重建 + 游标清零；`sync_queue` 不动）
  /// - 队列：**既不推也不删** —— 挂起（`failed` + 说清原因），等用户决定
  ///   （用户刚开的单是手机端唯一真正会丢的数据，见 `docs/reply.md` §4）
  ///
  /// [previousHostId] 只用于**给用户看的说明**（「原本要发给 XX 号主机」）。
  /// 返回被挂起的条目数。
  int resetForNewHost({String? previousHostId}) {
    final Db mirror = openMirror();
    // F14（2026-10-25 用户裁定）：换主机前先把旧主机这份镜像**整份归档**到
    // `archive/<旧 hostId>-<时间>/`（含当时未推送的队列）。
    // ⚠️ 归档是**快照**、不搬走队列：队列里是用户自己开的单，留在活库里他才能
    // 在新主机上点「重试」补发（既有行为，见 `mobile_sync_service_test` 换主机用例）。
    // 归档失败不阻断（`snapshot` 内部吞异常）—— 磁盘满也要让用户能换主机。
    archive.snapshot(
      db: mirror,
      hostId: previousHostId ?? 'unknown',
      now: _clock(),
    );
    // 先把队列挂起，再重建镜像 —— 顺序反了也一样（rebuildMirror 不碰队列），
    // 但「先挂起」保证任何中途失败都不会留下"仍会自动推给新主机"的条目
    final SyncQueueDao queue = SyncQueueDao(mirror);
    int held = 0;
    // C-2（2026-10-24，业务审查 §3.7）：用**全量**口径 —— `sent` 条目
    // （主机已收下、本机没确认）换主机后两头落空：新主机没有它、
    // `unsent()` 又排除它 ⇒ 永远停在 `sent`、永远不会再推。必须一并降级。
    for (final SyncQueueEntry entry in queue.allForHostSwitch()) {
      final bool wasSent = entry.status == SyncQueueStatus.sent;
      queue.markHeld(
        entry.id,
        reason: wasSent
            ? '这条单已经发给上一台主机'
                  '${previousHostId == null ? '' : '（主机 $previousHostId）'}'
                  '了，但本机还没确认收下。换主机后新主机没有它 —— '
                  '确认要发给现在这台主机，就在「同步队列」里点重试。'
            : '这条单是在连接上一台主机时开的'
                  '${previousHostId == null ? '' : '（主机 $previousHostId）'}'
                  '，还没有同步给它。为避免记到别的店里，已暂停自动上传 —— '
                  '确认要发给现在这台主机，就在「同步队列」里点重试。',
      );
      held++;
    }
    SyncClient(
      db: mirror,
      transport: transport ?? HttpTransport(),
      baseUri: Uri.parse('http://127.0.0.1:1'), // 重建不需要网络
      token: '',
    ).rebuildMirror();
    return held;
  }

  /// 一次完整同步：health（连通 + 主机 schema 版本）→ 需要则重建镜像
  /// → pull（全量或增量）→ push（离线队列，B2 里通常为空）。
  ///
  /// 同一时刻只允许一个同步在跑（按钮互斥在 UI 层，这里再兜一层）。
  Future<SyncOutcome> syncNow() async {
    if (_syncing) {
      return const SyncOutcome(SyncOutcomeKind.error, '上一次同步还在进行中');
    }
    _syncing = true;
    try {
      return await _syncNowInner();
    } catch (error, stack) {
      onError?.call(error, stack, '同步失败');
      // ⚠️ 顶层兜底：openMirror（SqliteException 14 = 父目录不存在 / 权限）
      // 等任何异常都必须变成结果 —— 抛出去 = 遮罩永转圈（真机两连踩）
      return SyncOutcome(SyncOutcomeKind.error, syncFailureMessage(error));
    } finally {
      _syncing = false;
    }
  }

  Future<SyncOutcome> _syncNowInner() async {
    final PairingInfo? pairing = pairingStore.load();
    if (pairing == null) {
      return const SyncOutcome(SyncOutcomeKind.notPaired, '还没连接主机 —— 请先扫码配对');
    }
    final Db mirror = openMirror();
    final Transport wire = transport ?? HttpTransport();
    final SyncClient client = SyncClient(
      db: mirror,
      transport: wire,
      baseUri: pairing.baseUri,
      token: pairing.token,
    );

    // ① health：连通性 + 主机 schema 版本（裁定 ④ 的比对源）
    final int hostSchema;
    try {
      final TransportResponse resp = await wire.send(
        TransportRequest(
          method: 'GET',
          uri: pairing.baseUri.resolve('/api/health'),
        ),
      );
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        return _authExpired();
      }
      if (resp.statusCode != 200) {
        return SyncOutcome(
          SyncOutcomeKind.error,
          '主机响应异常（${resp.statusCode}）—— 请把这句话告诉技术支持',
        );
      }
      final Object? decoded = jsonDecode(resp.body);
      // jsonDecode 给的是 Map<String, dynamic> —— 别按 Object? 的 map 判
      if (decoded is! Map || decoded['schema_version'] is! int) {
        return const SyncOutcome(
          SyncOutcomeKind.error,
          '主机响应里没有版本号 —— 两端版本可能不匹配，请把这句话告诉技术支持',
        );
      }
      hostSchema = decoded['schema_version']! as int;
      // P2 #9（2026-10-24，业务审查 §3.7）：把主机的 `server_time` 记成时钟偏移 ——
      // pull 的「最近更新窗口」按它算（手机时钟歪时不至于窗口整段落空）。
      final Object? serverTime = decoded['server_time'];
      if (serverTime is int) client.recordClockOffset(serverTime);
    } on SyncHttpException catch (error) {
      return SyncOutcome(SyncOutcomeKind.unreachable, error.detail);
    } catch (error, stack) {
      onError?.call(error, stack, '同步失败（health）');
      // ⚠️ 兜底：任何非预期异常都必须变成结果 —— 抛出去 = 调用方的
      // 转圈永远停不下来（真机踩过：§BL·落地·补 1）
      return SyncOutcome(SyncOutcomeKind.error, syncFailureMessage(error));
    }

    // ② 镜像重建。两条**独立**理由：
    //    ⓐ 身份不符（F14）：镜像属于另一台主机，或老镜像没有身份但**有数据**
    //       —— 这是"扫码成功、第一次同步就撞 `UNIQUE constraint failed`"的兜底
    //       （例如 `pairing.json` 是上一版写的、没走新 `pairFromCode`）。
    //    ⓑ 主机 schema 更高（既有裁定：重建而非迁移 —— 镜像是派生数据）。
    bool rebuilt = false;
    final MirrorMeta meta = _meta();
    final String? mirrorHostId = meta.hostId;
    final bool identityMismatch = mirrorHostId == null
        ? meta.hasAnyData()
        : mirrorHostId != pairing.hostId;
    if (identityMismatch) {
      archive.snapshot(
        db: mirror,
        hostId: mirrorHostId ?? 'unknown',
        now: _clock(),
      );
      client.rebuildMirror();
      meta.writeHostId(pairing.hostId);
      rebuilt = true;
    }
    if (hostSchema > mirror.schemaVersion) {
      client.rebuildMirror();
      rebuilt = true;
    }

    // ③ pull + push
    try {
      final SyncPullReport pulled = await client.pull(
        // #50（2026-10-15）：更新窗口下界的离线兜底 —— 固定 7 天窗口在
        // 「离线超过 7 天」时永远漏改单；用「上次成功同步 − 1 天」盖住整个跨度
        docUpdatedSinceFloor: _updateWindowFloor(pairing),
      );
      // #48（2026-10-15）：**有界连续推送** —— 从前只推一批（200 条），剩下的
      // 留在队列里却照样报「同步完成」（外测 R09：250 传 200 报完成剩 50）
      final SyncPushReport pushedReport = await client.pushAll();
      final int now = _clock() ?? DateTime.now().millisecondsSinceEpoch;
      pairingStore.save(pairing.withLastSyncAt(now));
      final int entities = pulled.entities.values.fold(
        0,
        (int a, int b) => a + b,
      );
      // ⚠️ **没拉完就不许说「同步完成」**（2026-10-07，`docs/reply.md` §1）：
      // 循环拉到底已由 `SyncClient.pull` 负责；到这里仍 `hasMore` 说明
      // 撞上了页数上限（主机分页异常）—— 镜像只是部分权威，如实告知并让用户
      // 再点一次，而不是让他以为看到的是全部（审查 #9 / Android 报告 ③）。
      if (pulled.hasMore) {
        return SyncOutcome(
          SyncOutcomeKind.error,
          '这次只同步了一部分（已拉 $entities 条，共 ${pulled.pages} 页）'
          '—— 请再点一次「立即同步」把剩下的拉完',
          rebuilt: rebuilt,
        );
      }
      final int pushedCount = pushedReport.sent + pushedReport.conflicts;
      // #48 裁定 §一②：撞批数上限仍有待传 ⇒ 文案必须与三触发的自动推送
      // 对得上（回到本页 / 点「立即同步」都会继续），不许报「同步完成」
      if (pushedReport.remaining > 0) {
        return SyncOutcome.ok(
          '已传 $pushedCount 条，还有 ${pushedReport.remaining} 条待传。'
          '回到本页或点「立即同步」会继续。',
          rebuilt: rebuilt,
        );
      }
      final String pushedNote = pushedCount == 0 ? '' : '、推送 $pushedCount 条';
      return SyncOutcome.ok(
        rebuilt
            ? '同步完成（镜像已重建）：拉取 $entities 条$pushedNote'
            : '同步完成：拉取 $entities 条$pushedNote',
        rebuilt: rebuilt,
      );
    } on SyncHttpException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        return _authExpired();
      }
      return SyncOutcome(SyncOutcomeKind.error, error.detail);
    } catch (error, stack) {
      onError?.call(error, stack, '同步失败（pull/push）');
      // ⚠️ 兜底同上 —— 任何非预期异常都变成结果，不让调用方转圈到天荒地老
      return SyncOutcome(SyncOutcomeKind.error, syncFailureMessage(error));
    }
  }

  // ---------------------------------------------------------- 自动推送（B3·裁定 ③）

  bool _autoPushing = false;
  bool _autoPushQueued = false;

  /// 开单成功后的**自动推送**（B3 裁定 ③）：尽力而为，**不打扰用户**。
  ///
  /// - **只 push 不 pull** —— 完整同步（health / 镜像重建 / pull）走 [syncNow]；
  ///   自动推送失败后条目留在队列，`failed` / 待重试状态由三态条显示（B3b）。
  /// - **结果只给三态条** —— UI 不为它弹 SnackBar（避免打扰连续开单）。
  /// - **并发（裁定 ③）**：推送中再有新单入队触发本方法 ⇒ 记一次「尾随」，
  ///   当前这轮结束后**自动再推一次** —— 连开三单只打两轮请求，不会三发并发。
  Future<SyncOutcome> autoPush() async {
    if (_autoPushing) {
      _autoPushQueued = true;
      return const SyncOutcome(SyncOutcomeKind.error, '推送已在进行中 —— 完成后会自动补推一次');
    }
    _autoPushing = true;
    try {
      return await _autoPushInner();
    } finally {
      _autoPushing = false;
      if (_autoPushQueued) {
        _autoPushQueued = false;
        unawaited(autoPush());
      }
    }
  }

  Future<SyncOutcome> _autoPushInner() async {
    final PairingInfo? pairing = pairingStore.load();
    if (pairing == null) {
      return const SyncOutcome(SyncOutcomeKind.notPaired, '还没连接主机 —— 请先扫码配对');
    }
    final SyncClient client = SyncClient(
      db: openMirror(),
      transport: transport ?? HttpTransport(),
      baseUri: pairing.baseUri,
      token: pairing.token,
    );
    try {
      final SyncPushReport report = await client.pushAll();
      // 顶层兜底与 syncNow 同理：任何异常都变成结果，绝不抛给 UI。
      // #48（2026-10-15）：撞批数上限仍有待传 ⇒ 说「回到开单页会继续」，
      // 与三触发的自动推送对上（不许让两个状态互相矛盾）
      final String message = report.attempts == 0
          ? '没有待同步的条目'
          : (report.remaining > 0
                ? '已推送 ${report.sent + report.conflicts} 条，'
                      '还有 ${report.remaining} 条待传 —— 回到开单页会继续'
                : (report.errors.isEmpty
                      ? '已推送 ${report.sent + report.conflicts} 条'
                      : '推送未全部成功 —— 条目留在队列，稍后自动重试'));
      return SyncOutcome.ok(message);
    } on SyncHttpException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        return _authExpired();
      }
      return SyncOutcome(SyncOutcomeKind.error, error.detail);
    } catch (error) {
      return SyncOutcome(SyncOutcomeKind.error, '自动推送没成功 —— 这条单还在队列里，稍后随同步重试。');
    }
  }

  /// #50（2026-10-15）：更新窗口下界的**离线兜底** = 「上次成功同步 − 1 天」。
  ///
  /// 固定 7 天窗口在「离线超过 7 天」时，窗口外的改单**永远**拉不到
  /// （主分页游标是 `created_at`，不回头）；用上次成功同步兜底就能盖住
  /// 整个离线跨度。⚠️ `lastSyncAt` 只在同步成功后写入（[syncNow] 里
  /// pull + push 都完成才 save；失败路径不 save —— 2026-10-15 核对过），
  /// 所以它不会把下界推到「从未成功过」的位置；首次同步（`null`）⇒
  /// 不兜底，走 `SyncClient` 的默认窗口。
  int? _updateWindowFloor(PairingInfo pairing) {
    final int? last = pairing.lastSyncAt;
    if (last == null) return null;
    return last - const Duration(days: 1).inMilliseconds;
  }

  /// 解析扫码结果：合法配对码 → 存 `pairing.json` 并返回主机信息；
  /// 非法 → 抛 `FormatException`（文案由 [PairingPayload.parse] 给，UI 不造句）。
  ///
  /// ⚠️ **扫到的是另一台主机时，先重置同步状态**（2026-10-07 裁定，
  /// 审计报告 #3 / Android 报告 ②）—— 镜像 / 游标 / 队列都是**按主机**成立的，
  /// 不重置就会漏数据、交错数据、甚至把离线单推到错的店里。
  ///
  /// 判定用 `host_id`（配对载荷里有，主机自己生成的）：
  /// **同一台主机重新生成配对码（`hostId` 不变）不该清镜像** —— 那只是换个令牌。
  PairingInfo pairFromCode(String raw) {
    final PairingPayload payload = PairingPayload.parse(raw.trim());
    final PairingInfo info = PairingInfo(
      hostId: payload.hostId,
      ip: payload.ip,
      port: payload.port,
      token: payload.token,
    );
    final PairingInfo? previous = pairingStore.load();
    final MirrorMeta meta = _meta();

    // ---------------------------------------------------------------- F14
    // 判定依据 = **镜像自己记的 hostId**，不是 `pairing.json`。
    // 原因：「忘记这台主机」会删掉 `pairing.json`（正常路径），旧实现据此判定
    // `previous == null` ⇒ 跳过重建 ⇒ 旧镜像的商品编码与新主机撞车 ⇒ 同步永久失败。
    final String? mirrorHostId = meta.hostId;
    final String? effectiveOld = mirrorHostId ?? previous?.hostId;
    // 没有身份标记、但镜像里**有数据** ⇒ 0.6.5 及更早的老镜像，无法证明属于谁。
    // 按"换了主机"处理（安全侧）：宁可归档重建，也不把旧店的货混进新店。
    final bool unknownButDirty = effectiveOld == null && meta.hasAnyData();
    final bool switched = effectiveOld != null && effectiveOld != info.hostId;

    if (switched || unknownButDirty) {
      lastHostSwitchHeldEntries = resetForNewHost(previousHostId: effectiveOld);
    } else {
      // 情形 A：同一台主机（hostId 相同、只是换了 IP / 端口 / 令牌）
      // ⇒ **不归档、不重建**，本地积压的队列照旧推给新地址。
      lastHostSwitchHeldEntries = 0;
    }

    // 身份写到镜像上（情形 C 的空镜像也在这里落身份，下次就能判 A / B）
    meta.writeHostId(info.hostId);
    pairingStore.save(info);
    return info;
  }

  /// **只换地址**（2026-10-25 D 批）—— 二维码里的 IP 挑错时的手动兜底。
  ///
  /// ## 为什么不复用 [pairFromCode]
  ///
  /// 那条路径要一整段 `shensuanzi://pair?...`（含 `host_id` 与令牌）。
  /// 用户手上只有一个地址时，两样都无从得知 —— 令牌是鉴权凭据，编不出来。
  /// 所以这条路径的**前提是「之前配对过」**：身份与令牌沿用
  /// `pairing.json` 里那份，只把 `ip` / `port` 换掉。
  ///
  /// ## 为什么这里**不**走 F14 的归档重建
  ///
  /// F14 的判据是 `hostId` 变了（换了另一台电脑）。这里 `hostId` **原样保留**，
  /// 只换地址 ⇒ 同一台主机换了条路进来，镜像、游标、队列都还有效。
  /// 若这里也归档重建，用户只是填错一次地址就会丢掉整份镜像数据。
  ///
  /// 没配对过 ⇒ 抛 [FormatException]（消息给用户看）。
  PairingInfo pairFromAddress(String raw) {
    final ({String ip, int? port}) parsed = PairingAddress.parse(raw);
    final PairingInfo? previous = pairingStore.load();
    if (previous == null) {
      throw const FormatException(
        '这台手机还没连过电脑，光填地址不够（还缺配对令牌）。'
        '请扫一次电脑上的二维码；扫不了码就把二维码下面那段配对码文字整段粘进来。',
      );
    }
    final PairingInfo info = previous.withAddress(
      ip: parsed.ip,
      // 用户没写端口 ⇒ 沿用上次配对里的端口（大多数情况就是它）
      port: parsed.port ?? previous.port,
    );
    pairingStore.save(info);
    return info;
  }

  /// 上一次 [pairFromCode] 因**换主机**而挂起的队列条目数（0 = 没换主机）。
  ///
  /// UI 用它决定要不要多说一句「有 N 条单已暂停上传」—— 那几条是用户
  /// 自己开的单，不说清楚他会以为还在自动补传。
  int lastHostSwitchHeldEntries = 0;

  /// 认证失效（401 / 403）的**唯一处置点**。
  ///
  /// P2 #8（2026-10-24，业务审查 §3.7）：**清配对收进服务一处**，三条路径
  /// （health 探测 / `syncNow` / `autoPush`）共用。从前只有「立即同步」在
  /// `app.dart` 里调 `forgetHost()` —— 开单 / 建档后的**后台自动推送**不清，
  /// 面板还显示「已连接」，每次推送都 401，用户看不到任何变化。
  SyncOutcome _authExpired() {
    forgetHost();
    return const SyncOutcome(
      SyncOutcomeKind.authExpired,
      '配对已失效 —— 主机可能重启过或重新生成了配对码，请重新扫码连接',
    );
  }
}

/// 三态条的**前置链接态**（M04，2026-10-08 · `docs/reply.md` §二·1）。
///
/// ## 为什么「队列空」不能等于「已同步」
///
/// 原判定是「队列里没有 pending / failed ⇒ 已同步」。而**全新安装、
/// 从没配对过**的手机，队列**天然是空的** ⇒ 顶栏第一天就写「已同步」，
/// 用户以为「已经连上电脑了」，他刚开的单其实还躺在本地队列里 ——
/// 直到某天发现电脑上根本没有这张单。这是**信任问题**，不是显示问题。
///
/// ## 判定顺序
///
/// 1. 有没有配对（`pairing.json` 在不在）；
/// 2. 配对过的话，**成功同步过没有**（`lastSyncAt`）；
/// 3. 只有过了前两关，队列的空 / 非空才有话语权。
enum SyncLinkState {
  /// 没配对过 —— 队列空**不代表任何事**
  notPaired,

  /// 配对过，但一次都没同步成功
  neverSynced,

  /// 至少成功同步过一次（这时队列才有话语权）
  linked,
}

/// 由「是否已配对」与「是否同步成功过」判定链接态（纯函数）。
SyncLinkState syncLinkStateOf({
  required bool paired,
  required bool everSynced,
}) {
  if (!paired) return SyncLinkState.notPaired;
  return everSynced ? SyncLinkState.linked : SyncLinkState.neverSynced;
}

/// 三态条的颜色语义（UI 只把它映射成主题色）。
enum SyncBarTone {
  /// 中性（未连接 / 没同步过 / 已同步）
  neutral,

  /// 进行中（有待同步）
  active,

  /// 出错（有失败）
  error,
}

/// 顶栏那一句话（**文案在纯 Dart**，UI 只渲染）。
String syncBarLabel({
  required SyncLinkState link,
  required SyncQueueTriage triage,
}) {
  switch (link) {
    case SyncLinkState.notPaired:
      return '尚未连接电脑';
    case SyncLinkState.neverSynced:
      return '还没同步过';
    case SyncLinkState.linked:
      if (triage.isSynced) return '已同步';
      return <String>[
        if (triage.pendingCount > 0) '待同步 ${triage.pendingCount} 条',
        if (triage.failedCount > 0) '失败 ${triage.failedCount} 条',
      ].join(' · ');
  }
}

/// 颜色语义。**未链接时恒为中性** —— 没连上不是错误，别用红色吓人。
SyncBarTone syncBarToneOf({
  required SyncLinkState link,
  required SyncQueueTriage triage,
}) {
  if (link != SyncLinkState.linked) return SyncBarTone.neutral;
  if (triage.failedCount > 0) return SyncBarTone.error;
  if (triage.pendingCount > 0) return SyncBarTone.active;
  return SyncBarTone.neutral;
}
