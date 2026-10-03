// 主机服务控制器自检：`dart run tool/selfcheck_service.dart`
//
// 与 `test/service_controller_test.dart` **断言等价** —— 本机 `dart test` 在沙箱里
// 编译不了测试文件（见 `docs/testing.md` §零），所以长期保留一份可 `dart run` 的镜像。
//
// ⚠️ **改一边必须改另一边**。
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**。
import 'dart:io';

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

int _clock = 1700000000000;
int now() => _clock++;

/// 避开 17890（生产端口），免得与本机真跑着的实例撞车
const PortRange testPorts = PortRange(start: 17985, end: 17999);
const String fakeIp = '192.168.1.7';

Db buildDb() => Db.openInMemory();

HostServiceController build(
  Db db,
  HostIdentityStore store, {
  PortRange ports = testPorts,
  Future<String?> Function()? detectLocalIp,
}) => HostServiceController(
  db: db,
  identities: store,
  ports: ports,
  detectLocalIp: detectLocalIp ?? () async => fakeIp,
  clock: now,
);

/// 每次新建客户端：`resetToken` 会 `force: true` 关掉在飞的连接（这是对的），
/// 复用的 keep-alive 池会因此拿到死连接。
Future<int> get(int port, String path, {String? token}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (token != null) request.headers.set('authorization', 'Bearer $token');
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  useLocalSqlite();
  final Db db = buildDb();

  section('LocalIp.choose（纯函数）');
  check(
    '跳过环路与 link-local，私有网段优先',
    LocalIp.choose(<NetCandidate>[
          const NetCandidate('Wi-Fi', <String>['127.0.0.1']),
          const NetCandidate('eth0', <String>['169.254.3.4']),
          const NetCandidate('eth0', <String>['203.0.113.9']),
          const NetCandidate('Wi-Fi', <String>['192.168.1.7']),
        ]) ==
        '192.168.1.7',
  );
  check(
    '虚拟网卡被跳过（WSL 的 172.x 不抢真网卡）',
    LocalIp.choose(<NetCandidate>[
          const NetCandidate('vEthernet (WSL)', <String>['172.20.0.1']),
          const NetCandidate('Wi-Fi', <String>['192.168.1.7']),
        ]) ==
        '192.168.1.7',
  );
  check(
    '只剩虚拟网卡时兜底，不返回 null',
    LocalIp.choose(<NetCandidate>[
          const NetCandidate('vEthernet (WSL)', <String>['172.20.0.1']),
        ]) ==
        '172.20.0.1',
  );
  check('一块网卡都没有 ⇒ null', LocalIp.choose(<NetCandidate>[]) == null);

  section('起始态：恒为 stopped（开关不持久化，§AH 遗漏 5）');
  final HostIdentityStore store = HostIdentityStore.inMemory();
  final HostServiceController controller = build(db, store);
  final HostServiceSnapshot initial = controller.snapshot;
  check('state = stopped', initial.state == HostServiceState.stopped);
  check("headline = '已关闭'", initial.headline == '已关闭');
  check('无二维码 / 无地址行', !initial.qrAvailable && initial.addressLine == null);
  check('running 之外不显示「连接」那行', initial.trafficLabel(now()) == null);

  section('start：首次启动应当能画码');
  final HostServiceSnapshot started = await controller.start();
  check('state = running', started.state == HostServiceState.running);
  check("headline = '已开启'", started.headline == '已开启');
  check(
    '端口落在 ${testPorts.start}~${testPorts.end}',
    started.port! >= testPorts.start && started.port! <= testPorts.end,
    '${started.port}',
  );
  check('地址行 = 主机地址：$fakeIp:${started.port}（遗漏 4 的手输兜底）',
      started.addressLine == '主机地址：$fakeIp:${started.port}');
  check('qrAvailable = true', started.qrAvailable);
  check('needsReset = false', !started.needsReset);
  check("trafficLabel = '还没有手机连接过'",
      started.trafficLabel(now()) == '还没有手机连接过');
  final PairingPayload payload = controller.pairingPayload!;
  check('载荷可解析回自身', PairingPayload.parse(payload.uri).token == payload.token);
  check('载荷里是真实 LAN 地址（不是 0.0.0.0）', payload.uri.contains('ip=$fakeIp'));

  final HostServiceSnapshot again = await controller.start();
  check('重复 start 幂等（端口没变）', again.port == started.port);

  section('真 HTTP：health 免鉴权 / pull 要令牌 / 只有通过鉴权才算活动');
  final int port = started.port!;
  check('/api/health 免鉴权 ⇒ 200', await get(port, '/api/health') == 200);
  check('pull 不带令牌 ⇒ 401', await get(port, '/api/sync/pull') == 401);
  check('pull 带错令牌 ⇒ 401', await get(port, '/api/sync/pull', token: 'nope') == 401);
  check('401 不计入活动', controller.snapshot.trafficCount == 0);
  check('pull 带对令牌 ⇒ 200', await get(port, '/api/sync/pull', token: payload.token) == 200);
  check('鉴权成功后 trafficCount = 1', controller.snapshot.trafficCount == 1);
  check("trafficLabel = '最近连接：刚刚'",
      controller.snapshot.trafficLabel(now()) == '最近连接：刚刚');
  final int at = controller.snapshot.lastTrafficAt!;
  check("5 分钟后 = '最近连接：5 分钟前'",
      controller.snapshot.trafficLabel(at + 5 * 60000) == '最近连接：5 分钟前');
  check("3 小时后 = '最近连接：3 小时前'",
      controller.snapshot.trafficLabel(at + 3 * 3600000) == '最近连接：3 小时前');

  section('探不到局域网地址：服务照起，但不画码、给「怎么办」');
  final HostServiceController noIp = build(
    db,
    HostIdentityStore.inMemory(),
    detectLocalIp: () async => null,
  );
  final HostServiceSnapshot sNoIp = await noIp.start();
  check('state 仍 running', sNoIp.state == HostServiceState.running);
  check('addressHint 说「怎么办」', (sNoIp.addressHint ?? '').contains('热点'));
  check('addressLine = null', sNoIp.addressLine == null);
  check('qrAvailable = false（不把 0.0.0.0 画进码）', !sNoIp.qrAvailable);
  check('detail 透出 addressHint', sNoIp.detail == sNoIp.addressHint);
  await noIp.stop();

  section('resetToken：换令牌 + 换 host_id + 旧令牌立刻失效');
  final String oldToken = payload.token;
  final String oldHostId = payload.hostId;
  final HostServiceSnapshot reset = await controller.resetToken();
  check('仍在 running', reset.state == HostServiceState.running);
  check('qrAvailable = true', reset.qrAvailable);
  final PairingPayload fresh = controller.pairingPayload!;
  check('令牌换了', fresh.token != oldToken);
  check('host_id 换了（§9.3：所有设备重新配对）', fresh.hostId != oldHostId);
  check('新令牌可用', await get(reset.port!, '/api/sync/pull', token: fresh.token) == 200);
  check('**旧令牌已作废 ⇒ 401**',
      await get(reset.port!, '/api/sync/pull', token: oldToken) == 401);

  section('模拟重启：新控制器 + 同一个 host.json（只有哈希）');
  await controller.stop();
  final HostServiceController restarted = build(db, store);
  final HostServiceSnapshot sRestart = await restarted.start();
  check('state = running', sRestart.state == HostServiceState.running);
  check('**qrAvailable = false**（明文不可逆，画不出码）', !sRestart.qrAvailable);
  check('**needsReset = true**（UI 据此给「重新生成」）', sRestart.needsReset);
  check('pairingPayload = null', restarted.pairingPayload == null);
  check('但**旧令牌照样能鉴权**（服务本身没坏）',
      await get(sRestart.port!, '/api/sync/pull', token: fresh.token) == 200);
  check('重启后可重置出可扫的码',
      (await restarted.resetToken()).qrAvailable);

  section('stop：清空运行期状态');
  final HostServiceSnapshot stopped = await restarted.stop();
  check('state = stopped', stopped.state == HostServiceState.stopped);
  check('端口清空', stopped.port == null);
  check('地址清空（不能留下会过期的地址行）', stopped.address == null);
  check('活动统计归零', stopped.trafficCount == 0 && stopped.lastTrafficAt == null);
  check('stop 幂等', (await restarted.stop()).state == HostServiceState.stopped);

  section('端口全被占 ⇒ failed + 怎么办');
  final ServerSocket blocker = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final HostServiceController busy = build(
    db,
    HostIdentityStore.inMemory(),
    ports: PortRange(start: blocker.port, end: blocker.port),
  );
  final HostServiceSnapshot sBusy = await busy.start();
  check('state = failed', sBusy.state == HostServiceState.failed);
  check("headline = '启动失败'", sBusy.headline == '启动失败');
  check('failureHint 说清端口', (sBusy.failureHint ?? '').contains('${blocker.port}'));
  check('failureHint 给了「怎么办」', (sBusy.failureHint ?? '').contains('防火墙'));
  check('失败时不画码', !sBusy.qrAvailable);
  check('detail 透出 failureHint', sBusy.detail == sBusy.failureHint);
  await busy.stop();
  await blocker.close();

  section('host.json 位置');
  check('落在数据目录下（主机设施放文件，不动 schema）',
      hostIdentityFile('D:/data').path.endsWith(hostIdentityFileName));
  check('参数是路径字符串（与 DataLocation.directory 同型）',
      hostIdentityFile('D:/data').path.contains('data'));

  stdout.writeln('');
  if (_failures.isEmpty) {
    stdout.writeln('自检通过：$_passed / $_passed');
    exit(0);
  }
  stdout.writeln('自检失败：通过 $_passed，失败 ${_failures.length}');
  for (final String name in _failures) {
    stdout.writeln('  ✗ $name');
  }
  exit(1);
}
