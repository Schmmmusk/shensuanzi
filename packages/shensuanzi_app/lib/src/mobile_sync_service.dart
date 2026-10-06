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
  PairingInfo pairFromCode(String raw) {    final PairingPayload payload = PairingPayload.parse(raw.trim());
    final PairingInfo info = PairingInfo(
      hostId: payload.hostId,
      ip: payload.ip,
      port: payload.port,
      token: payload.token,
    );
    pairingStore.save(info);
    return info;
  }

  SyncOutcome _authExpired() => const SyncOutcome(
    SyncOutcomeKind.authExpired,
    '配对已失效 —— 主机可能重启过或重新生成了配对码，请重新扫码连接',
  );
}
