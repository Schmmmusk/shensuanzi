import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'auth.dart';
import 'sync_server.dart';

/// 端口范围（`docs/sync_protocol.md` §9.1：**从 17890 起探测到 17900**）。
class PortRange {
  const PortRange({this.start = 17890, this.end = 17900})
    : assert(start <= end, '端口范围起点不得大于终点');

  static const PortRange defaults = PortRange();

  final int start;
  final int end;

  List<int> get ports => <int>[for (int p = start; p <= end; p++) p];
}

/// 主机 HTTP 服务（`docs/sync_protocol.md` §八 / §九）。
///
/// ## 职责
///
/// 只做**传输**：路由、Bearer 鉴权、JSON ↔ DTO。所有协议语义都在
/// [SyncServer]，所有业务规则都在 `shensuanzi_core` 的 `RuleEngine`。
///
/// ## 路由
///
/// | 方法 | 路径 | 鉴权 | 说明 |
/// |---|---|---|---|
/// | GET | `/api/health` | **否** | 连通性探测（配对前就要能探到） |
/// | POST | `/api/sync/push` | 是 | 推送队列条目 |
/// | GET | `/api/sync/pull` | 是 | 增量拉取 |
///
/// `health` 不鉴权是刻意的：客户端在**扫码之前**就要能判断
/// 「这个 IP:端口是不是主机」。它只返回 `ok` / 服务器时间 / schema 版本，
/// 不含任何业务数据。
class HostHttpServer {
  HostHttpServer._(this._server, this.sync, this.identity);

  static const String apiVersion = '1';

  final HttpServer _server;

  /// 供测试直接调用（HTTP 层只是搬运）
  final SyncServer sync;

  final HostIdentity identity;

  int get port => _server.port;

  InternetAddress get address => _server.address;

  /// 绑定成功后实际生效的基址，如 `http://192.168.1.5:17890`
  String get baseUrl => 'http://${_server.address.address}:${_server.port}';

  /// 在 [ports] 范围内找到第一个可用端口并开始监听。
  ///
  /// **逐个真正 `serve`，不做「先探测再绑」**：先探测再绑存在竞态，
  /// 而这里只可能失败一次，代价可以忽略。
  ///
  /// [onAuthenticated] 每有一次**通过鉴权**的请求就回调一次 —— 给
  /// `HostServiceController` 统计「有没有手机在连」用。**只在鉴权通过后调**：
  /// 拿它当「有活动」的判据，就不能把被人乱扫端口也算进来。
  static Future<HostHttpServer> start({
    required Db db,
    required HostIdentity identity,
    PortRange ports = PortRange.defaults,
    InternetAddress? address,
    int Function()? clock,
    void Function()? onAuthenticated,
  }) async {
    final int Function() now =
        clock ?? () => DateTime.now().millisecondsSinceEpoch;
    final _HostRoutes routes = _HostRoutes(
      sync: SyncServer(db),
      identity: identity,
      clock: now,
      onAuthenticated: onAuthenticated,
    );
    final InternetAddress bind = address ?? InternetAddress.anyIPv4;

    SocketException? lastError;
    for (final int port in ports.ports) {
      try {
        final HttpServer server = await shelf_io.serve(
          routes.handler,
          bind,
          port,
        );
        // ⚠️ 时钟**只交给 _HostRoutes**：它才是真正取时间的地方
        // （`health` 的 `server_time`、`occurred_at` 回填）。
        // 这里曾经也存了一份 `_clock` 字段，但从未读过 —— 死状态，已删。
        return HostHttpServer._(server, routes.sync, identity);
      } on SocketException catch (error) {
        lastError = error;
      }
    }
    throw StateError(
      '端口 ${ports.start}~${ports.end} 全部不可用。最后一个错误：$lastError',
    );
  }

  Future<void> close({bool force = false}) => _server.close(force: force);
}

/// 路由与中间件。抽成独立类是为了让 [HostHttpServer.start] 能把
/// 实例交给返回的服务器 —— handler 需要先于 `serve` 构建。
class _HostRoutes {
  _HostRoutes({
    required this.sync,
    required this.identity,
    required this.clock,
    this.onAuthenticated,
  });

  final SyncServer sync;
  final HostIdentity identity;
  final int Function() clock;

  /// 鉴权通过一次调一次（`null` = 不关心）
  final void Function()? onAuthenticated;

  Handler get handler {
    final Router router = Router()
      ..get('/api/health', _health)
      ..post('/api/sync/push', _withAuth(_push))
      ..get('/api/sync/pull', _withAuth(_pull));

    return const Pipeline()
        // 未捕获异常 → 500 JSON，而不是把 stack trace 泄给客户端
        .addMiddleware(_catchErrors())
        .addHandler(router.call);
  }

  // ------------------------------------------------------------ 路由

  Response _health(Request request) => _json(<String, Object?>{
    'ok': true,
    'api_version': HostHttpServer.apiVersion,
    'server_time': clock(),
    'schema_version': Schema.version,
  });

  Future<Response> _push(Request request) async {
    final String body = await request.readAsString();
    final SyncPushRequest payload;
    try {
      payload = SyncPushRequest.fromJson(
        Map<String, Object?>.from(
          jsonDecode(body) as Map<Object?, Object?>,
        ),
      );
    } on FormatException catch (error) {
      return _error(400, error.message);
    } catch (error) {
      return _error(400, '请求体解析失败：$error');
    }

    // 逐条独立处理（SyncServer.push 保证一条失败不拖累其它条目）
    final List<SyncResponse> results = sync.push(
      payload.operations,
      now: clock(),
    );
    return _json(SyncPushResponse(results: results).toJson());
  }

  Response _pull(Request request) {
    final Map<String, String> q = request.url.queryParameters;
    try {
      return _json(
        sync
            .pull(
              stockSince: q[SyncCursorKeys.stock] ?? '0',
              moneySince: q[SyncCursorKeys.money] ?? '0',
              partySince: q[SyncCursorKeys.party] ?? '0',
              settleSince: q[SyncCursorKeys.settle] ?? '0',
              docSince: q[SyncCursorKeys.doc] ?? '',
              productsSince: q[SyncCursorKeys.products] ?? '',
              partiesSince: q[SyncCursorKeys.parties] ?? '',
              accountsSince: q[SyncCursorKeys.accounts] ?? '',
              limit:
                  int.tryParse(q['limit'] ?? '') ?? SyncServer.defaultPullLimit,
              // 最近更新窗口（2026-10-07，`docs/reply.md` §1 甲方案）：
              // 客户端传「现在 − 窗口天数」，拿了之后按 updated_at 再取一遍
              // 动过的主单（签收 / 拒收 / 收款的状态变化）。缺省不传 = 旧行为。
              docUpdatedSince: int.tryParse(q['doc_updated_since'] ?? ''),
            )
            .toJson(),
      );
    } on FormatException catch (error) {
      return _error(400, error.message);
    }
  }

  // ------------------------------------------------------------ 中间件

  /// Bearer 鉴权（§9.1：`Authorization: Bearer <token>`）
  Handler _withAuth(Handler inner) => (Request request) {
    final String? token = _bearerToken(request.headers['authorization']);
    if (!identity.authorizes(token)) {
      return _error(401, '令牌无效或缺失');
    }
    onAuthenticated?.call();
    return inner(request);
  };

  Middleware _catchErrors() => (Handler inner) => (Request request) async {
    try {
      return await inner(request);
    } catch (error) {
      return _error(500, '服务端异常：$error');
    }
  };

  static String? _bearerToken(String? header) {
    if (header == null) return null;
    const String prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return null;
    final String token = header.substring(prefix.length).trim();
    return token.isEmpty ? null : token;
  }

  static Response _json(Map<String, Object?> body, {int status = 200}) =>
      Response(
        status,
        body: jsonEncode(body),
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );

  static Response _error(int status, String message) =>
      _json(<String, Object?>{'error': message}, status: status);
}
