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
        PairingPayload,
        SyncClient,
        SyncHttpException,
        SyncPullReport,
        SyncPushReport,
        SyncQueueDao,
        SyncQueueEntry,
        SyncQueueTriage,
        Transport,
        TransportRequest,
        TransportResponse;

import 'http_transport.dart';
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
    int? Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 镜像库文件路径（`<私有目录>/mirror/shensuanzi_mirror.db`，裁定 ④）
  final String mirrorPath;

  /// 配对凭据（`pairing.json`，裁定 ②：与 config 分离）
  final PairingStore pairingStore;

  /// 传输层；`null` = 生产用 [HttpTransport]（测试注入桩）
  final Transport? transport;

  final int? Function() _clock;

  Db? _mirror;
  bool _syncing = false;

  /// 打开（或创建）镜像库。库的生命周期跟随服务（app 退出时 close）。
  ///
  /// ⚠️ **先建父目录**（`mirror/`）—— sqlite3 只建文件、不建中间目录，
  /// 父目录不存在 = `SqliteException(14) unable to open database file`
  /// （真机首跑踩过：§BL·落地·补 2）。
  Db openMirror() {
    if (_mirror == null) {
      Directory(p.dirname(mirrorPath)).createSync(recursive: true);
      _mirror = Db.open(mirrorPath, foreignKeys: false);
    }
    return _mirror!;
  }

  /// 当前镜像的 schema 版本（`user_version`；fresh 库 = `Schema.version`）
  int get mirrorSchemaVersion => openMirror().schemaVersion;

  /// 「忘记这台主机」/ 配对失效后的重置
  void forgetHost() {
    pairingStore.clear();
  }

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
    // 先把队列挂起，再重建镜像 —— 顺序反了也一样（rebuildMirror 不碰队列），
    // 但「先挂起」保证任何中途失败都不会留下"仍会自动推给新主机"的条目
    final SyncQueueDao queue = SyncQueueDao(mirror);
    int held = 0;
    for (final SyncQueueEntry entry in queue.unsent()) {
      queue.markHeld(
        entry.id,
        reason: '这条单是在连接上一台主机时开的'
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
    } catch (error) {
      // ⚠️ 顶层兜底：openMirror（SqliteException 14 = 父目录不存在 / 权限）
      // 等任何异常都必须变成结果 —— 抛出去 = 遮罩永转圈（真机两连踩）
      return SyncOutcome(
        SyncOutcomeKind.error,
        '同步时出错（$error）—— 请重试；一直这样请把这句话告诉技术支持',
      );
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
    } on SyncHttpException catch (error) {
      return SyncOutcome(SyncOutcomeKind.unreachable, error.detail);
    } catch (error) {
      // ⚠️ 兜底：任何非预期异常都必须变成结果 —— 抛出去 = 调用方的
      // 转圈永远停不下来（真机踩过：§BL·落地·补 1）
      return SyncOutcome(
        SyncOutcomeKind.error,
        '同步时出错（$error）—— 请重试；一直这样请把这句话告诉技术支持',
      );
    }

    // ② 镜像重建（裁定：重建而非迁移 —— 主机版本更高时，本库作废重来）
    bool rebuilt = false;
    if (hostSchema > mirror.schemaVersion) {
      client.rebuildMirror();
      rebuilt = true;
    }

    // ③ pull + push
    try {
      final SyncPullReport pulled = await client.pull();
      await client.push(); // B2 里队列通常为空；计数暂不展示
      final int now = _clock() ?? DateTime.now().millisecondsSinceEpoch;
      pairingStore.save(pairing.withLastSyncAt(now));
      final int entities = pulled.entities.values.fold(0, (int a, int b) => a + b);
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
      return SyncOutcome.ok(
        rebuilt
            ? '同步完成（镜像已重建）：拉取 $entities 条'
            : '同步完成：拉取 $entities 条',
        rebuilt: rebuilt,
      );
    } on SyncHttpException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        return _authExpired();
      }
      return SyncOutcome(SyncOutcomeKind.error, error.detail);
    } catch (error) {
      // ⚠️ 兜底同上 —— 任何非预期异常都变成结果，不让调用方转圈到天荒地老
      return SyncOutcome(
        SyncOutcomeKind.error,
        '同步时出错（$error）—— 请重试；一直这样请把这句话告诉技术支持',
      );
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
      return const SyncOutcome(
        SyncOutcomeKind.error,
        '推送已在进行中 —— 完成后会自动补推一次',
      );
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
      final SyncPushReport report = await client.push();
      // 顶层兜底与 syncNow 同理：任何异常都变成结果，绝不抛给 UI
      final String message = report.attempts == 0
          ? '没有待同步的条目'
          : (report.errors.isEmpty
                ? '已推送 ${report.sent} 条'
                : '推送未全部成功 —— 条目留在队列，稍后自动重试');
      return SyncOutcome.ok(message);
    } on SyncHttpException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        return _authExpired();
      }
      return SyncOutcome(SyncOutcomeKind.error, error.detail);
    } catch (error) {
      return SyncOutcome(
        SyncOutcomeKind.error,
        '自动推送失败（$error）—— 条目留在队列，稍后随同步重试',
      );
    }
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
    lastHostSwitchHeldEntries = previous != null && previous.hostId != info.hostId
        ? resetForNewHost(previousHostId: previous.hostId)
        : 0;
    pairingStore.save(info);
    return info;
  }

  /// 上一次 [pairFromCode] 因**换主机**而挂起的队列条目数（0 = 没换主机）。
  ///
  /// UI 用它决定要不要多说一句「有 N 条单已暂停上传」—— 那几条是用户
  /// 自己开的单，不说清楚他会以为还在自动补传。
  int lastHostSwitchHeldEntries = 0;

  SyncOutcome _authExpired() => const SyncOutcome(
    SyncOutcomeKind.authExpired,
    '配对已失效 —— 主机可能重启过或重新生成了配对码，请重新扫码连接',
  );
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
