// host 自检：`dart run tool/selfcheck_host.dart`
//
// 覆盖令牌 / 主机身份 / 配对载荷 / 二维码数据 / shelf HTTP 层。
// 与 `test/{auth,pairing,http_server}_test.dart` 断言等价 ——
// 本机 `dart test` 无法编译测试文件（见 `docs/testing.md` §零）。
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**，失败可复现。

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

int _passed = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void section(String title) => stdout.writeln('\n[$title]');

bool throws(void Function() body) {
  try {
    body();
    return false;
  } catch (_) {
    return true;
  }
}

const int _fixedNow = 1700000000000;
const PortRange _testPorts = PortRange(start: 17985, end: 17999);

Future<void> main() async {
  useLocalSqlite();

  // ============================================================ 令牌
  section('HostToken');
  {
    final String a = HostToken.generate(random: Random(42));
    final String b = HostToken.generate(random: Random(42));
    check('注入种子可复现', a == b, a);
    check('不同种子不同结果', a != HostToken.generate(random: Random(43)));
    check('真实随机两次不同', HostToken.generate() != HostToken.generate());
    check('明文是 32 字节的 Base64', base64Url.decode(a).length == 32);

    check('hashOf 稳定', HostToken.hashOf('t') == HostToken.hashOf('t'));
    check('hashOf 是 64 位十六进制', HostToken.hashOf('t').length == 64);
    check('hashOf 区分内容', HostToken.hashOf('t') != HostToken.hashOf('u'));

    final String hash = HostToken.hashOf('secret');
    check('matches 正确令牌', HostToken.matches('secret', hash));
    check('matches 错误令牌', !HostToken.matches('secrez', hash));
    check('matches 空串', !HostToken.matches('', hash));
    check('matches null', !HostToken.matches(null, hash));

    check('constantTimeEquals 相等', HostToken.constantTimeEquals('abc', 'abc'));
    check('constantTimeEquals 等长不等', !HostToken.constantTimeEquals('abc', 'abd'));
    check('constantTimeEquals 不等长', !HostToken.constantTimeEquals('abc', 'ab'));
  }

  // ============================================================ 主机身份
  section('HostIdentityStore');
  {
    final HostIdentityStore store = HostIdentityStore.inMemory();
    final HostIdentity first = store.loadOrCreate(now: _fixedNow);

    check('首次生成 host_id', first.hostId.isNotEmpty);
    check('首次带明文（可画二维码）', first.canShowQr);
    check('明文能通过校验', first.authorizes(first.plaintextToken));

    final HostIdentity loaded = store.loadOrCreate(now: _fixedNow + 1);
    check('再次读取 host_id 不变', loaded.hostId == first.hostId);
    check('再次读取哈希不变', loaded.tokenHash == first.tokenHash);
    check('再次读取**没有明文**（哈希不可逆）', !loaded.canShowQr);
    check('重启后仍能校验旧令牌（只需哈希）',
        loaded.authorizes(first.plaintextToken));

    final HostIdentity after = store.reset(now: _fixedNow + 2);
    check('reset 换 host_id', after.hostId != first.hostId);
    check('reset 后旧令牌失效', !after.authorizes(first.plaintextToken));
    check('reset 后新令牌可用', after.authorizes(after.plaintextToken));
    check('reset 后能重新画二维码', after.canShowQr);
    check('落盘的哈希已更新', store.storedHash() == after.tokenHash);

    final String serialized = jsonEncode(first.toJson());
    check('落盘 JSON 不含明文', !serialized.contains(first.plaintextToken!));
    check('落盘 JSON 含哈希', serialized.contains(first.tokenHash));
    check('toJson 没有 token 键', !first.toJson().containsKey('token'));
  }

  // ============================================================ 配对载荷
  section('PairingPayload');
  {
    const PairingPayload sample = PairingPayload(
      hostId: 'h-0001',
      ip: '192.168.1.5',
      port: 17890,
      token: 'dG9rZW4=',
    );
    check('uri 是 shensuanzi://pair', sample.uri.startsWith('shensuanzi://pair?'));
    check('uri 含 host_id', sample.uri.contains('host_id=h-0001'));
    check('uri 含 port', sample.uri.contains('port=17890'));
    check('uri 含 v=1', sample.uri.contains('v=1'));

    final PairingPayload parsed = PairingPayload.parse(sample.uri);
    check('往返：host_id', parsed.hostId == sample.hostId);
    check('往返：ip', parsed.ip == sample.ip);
    check('往返：port', parsed.port == sample.port);
    check('往返：token', parsed.token == sample.token);
    check('往返：uri 稳定', parsed.uri == sample.uri);

    const PairingPayload tricky = PairingPayload(
      hostId: 'h-0002',
      ip: '10.0.0.2',
      port: 17891,
      token: 'a-b_c=d+e/f',
    );
    check('URL 不安全字符也能往返',
        PairingPayload.parse(tricky.uri).token == tricky.token);

    for (final String bad in <String>[
      'https://pair?host_id=x',
      'shensuanzi://other?host_id=x',
      '随便一句话',
      '',
    ]) {
      check('非配对码 → FormatException（$bad）',
          throws(() => PairingPayload.parse(bad)));
    }
    check('缺 token → FormatException',
        throws(() => PairingPayload.parse('shensuanzi://pair?host_id=h&ip=1.1.1.1&port=1')));
    check('缺 host_id → FormatException',
        throws(() => PairingPayload.parse('shensuanzi://pair?ip=1.1.1.1&port=1&token=t')));
    for (final String port in <String>['0', '-1', '70000', 'abc']) {
      check('port=$port → FormatException',
          throws(() => PairingPayload.parse(
              'shensuanzi://pair?host_id=h&ip=1.1.1.1&port=$port&token=t')));
    }
  }

  // ============================================================ 二维码
  section('PairingQr');
  {
    const PairingPayload sample = PairingPayload(
      hostId: 'h-0001',
      ip: '192.168.1.5',
      port: 17890,
      token: 'dG9rZW4=',
    );
    final PairingQr qr = PairingQr(sample);
    final List<List<bool>> matrix = qr.matrix;
    final int n = qr.moduleCount;

    check('uri 与载荷一致', qr.uri == sample.uri);
    check('moduleCount ≥ 21（最小 QR 版本）', n >= 21, '$n');
    check('矩阵是 n 行', matrix.length == n);
    check('每行 n 列', matrix.every((List<bool> row) => row.length == n));
    final int dark = matrix
        .expand((List<bool> row) => row)
        .where((bool cell) => cell)
        .length;
    check('有深色模块', dark > 0, '$dark');
    check('左上定位角是深色', matrix[0][0]);
    check('右上定位角是深色', matrix[0][n - 1]);
    check('左下定位角是深色', matrix[n - 1][0]);

    const PairingPayload other = PairingPayload(
      hostId: 'h-0009',
      ip: '192.168.1.9',
      port: 17899,
      token: 'other',
    );
    final List<List<bool>> otherMatrix = PairingQr(other).matrix;
    check('不同内容矩阵不同', matrix.length != otherMatrix.length || matrix != otherMatrix);
  }

  // ============================================================ HTTP
  section('HTTP 层');
  {
    final Db db = Db.openInMemory();
    final HostIdentity identity = HostIdentityStore.inMemory().loadOrCreate(now: _fixedNow);
    final String token = identity.plaintextToken!;
    final HostHttpServer server = await HostHttpServer.start(
      db: db,
      identity: identity,
      ports: _testPorts,
      address: InternetAddress.loopbackIPv4,
      clock: () => _fixedNow,
    );
    final String base = 'http://127.0.0.1:${server.port}';

    Future<(int, Map<String, Object?>)> call(
      String method,
      String path, {
      String? bearer,
      Object? body,
      String? rawBody,
    }) async {
      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest request =
            await client.openUrl(method, Uri.parse('$base$path'));
        if (bearer != null) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
        }
        if (rawBody != null) {
          request.write(rawBody);
        } else if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final HttpClientResponse response = await request.close();
        final String text = await response.transform(utf8.decoder).join();
        return (
          response.statusCode,
          Map<String, Object?>.from(jsonDecode(text) as Map<Object?, Object?>),
        );
      } finally {
        client.close(force: true);
      }
    }

    check('端口落在给定范围',
        server.port >= _testPorts.start && server.port <= _testPorts.end,
        '${server.port}');

    final (int healthStatus, Map<String, Object?> health) =
        await call('GET', '/api/health');
    check('health 无需鉴权 → 200', healthStatus == 200, '$healthStatus');
    check('health.ok = true', health['ok'] == true);
    check('health 用注入的时钟', health['server_time'] == _fixedNow);
    check('health 不含业务数据',
        health.keys.toSet().length == 4, '${health.keys.toList()}');

    final (int noAuth, Map<String, Object?> noAuthJson) = await call(
      'POST',
      '/api/sync/push',
      body: <String, Object?>{'operations': <Object?>[]},
    );
    check('push 缺令牌 → 401', noAuth == 401, '$noAuth');
    check('401 带 error 说明', '${noAuthJson['error']}'.contains('令牌'));
    check('push 错令牌 → 401',
        (await call('POST', '/api/sync/push', bearer: 'nope', body: <String, Object?>{'operations': <Object?>[]})).$1 == 401);
    check('pull 缺令牌 → 401', (await call('GET', '/api/sync/pull')).$1 == 401);

    final String productId = newId();
    final (int pushStatus, Map<String, Object?> pushJson) = await call(
      'POST',
      '/api/sync/push',
      bearer: token,
      body: <String, Object?>{
        'operations': <Object?>[
          <String, Object?>{
            'entity': 'products',
            'entity_id': productId,
            'operation': 'createMasterData',
            'payload': <String, Object?>{
              'id': productId,
              'code': 'HH1',
              'name': '商品',
            },
          },
          <String, Object?>{
            'entity': 'sqlite_master',
            'entity_id': 'bad',
            'operation': 'createMasterData',
          },
        ],
      },
    );
    check('push 合法 → 200', pushStatus == 200, '$pushStatus');
    final List<Object?> results = pushJson['results']! as List<Object?>;
    check('results 两条', results.length == 2);
    check('第一条 applied', (results[0]! as Map)['status'] == 'applied');
    check('第二条 rejected', (results[1]! as Map)['status'] == 'rejected');
    check('一条被拒不拖累同批', ProductDao(db).findById(productId) != null);

    check('非法 JSON → 400',
        (await call('POST', '/api/sync/push', bearer: token, rawBody: 'nope')).$1 == 400);
    final (int noOps, Map<String, Object?> noOpsJson) = await call(
      'POST',
      '/api/sync/push',
      bearer: token,
      body: <String, Object?>{'ops': <Object?>[]},
    );
    check('缺 operations → 400', noOps == 400, '$noOps');
    check('400 说明提到 operations', '${noOpsJson['error']}'.contains('operations'));

    final (int pullStatus, Map<String, Object?> pullJson) =
        await call('GET', '/api/sync/pull', bearer: token);
    check('pull → 200', pullStatus == 200, '$pullStatus');
    check('pull 含 next_cursors', pullJson.containsKey('next_cursors'));
    final Map<String, Object?> cursors =
        Map<String, Object?>.from(pullJson['next_cursors']! as Map);
    check('stock_since 初始为 0', cursors[SyncCursorKeys.stock] == '0');
    check('doc_since 初始为 0|', cursors[SyncCursorKeys.doc] == '0|');
    check('空库 stock_ledger 为空', (pullJson['stock_ledger']! as List).isEmpty);
    // ⚠️ pull **不含主数据** —— §8.2 只列 6 个业务实体。
    // 主数据的增量同步是另一件事（§8.3 的 REST 接口没有游标）。
    check('pull 不含主数据', !pullJson.containsKey('products'));
    check('pull 恰好 6 个实体 + next_cursors',
        pullJson.keys.length == 7, '${pullJson.keys.toList()}');

    final (int badCursor, Map<String, Object?> badCursorJson) =
        await call('GET', '/api/sync/pull?doc_since=oops', bearer: token);
    check('游标非法 → 400', badCursor == 400, '$badCursor');
    check('400 说明提到游标', '${badCursorJson['error']}'.contains('游标'));

    final (int zeroLimit, Map<String, Object?> zeroLimitJson) =
        await call('GET', '/api/sync/pull?limit=0', bearer: token);
    check('limit=0 → 200 且空页',
        zeroLimit == 200 && (zeroLimitJson['documents']! as List).isEmpty);

    await server.close(force: true);
    db.close();
  }

  stdout.writeln('\n${'=' * 46}');
  if (_failures.isEmpty) {
    stdout.writeln('全部通过：$_passed 项');
    exit(0);
  }
  stdout.writeln('通过 $_passed 项，失败 ${_failures.length} 项：');
  for (final String failure in _failures) {
    stdout.writeln('  - $failure');
  }
  exit(1);
}
