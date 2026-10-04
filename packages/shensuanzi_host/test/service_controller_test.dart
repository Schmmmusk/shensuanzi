// 主机服务的**启停控制器**（§AH · AH-A）。
//
// 覆盖：状态迁移、端口耗尽、局域网地址探测、令牌生命周期（含「重启后画不出码」）、
// 鉴权回调、以及**全部用户可见文案**。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；需要可用的 SQLite 原生库，见 `lib/sqlite_local.dart`。
// ⚠️ 与 `tool/selfcheck_service.dart` **互为镜像** —— 改一边必须改另一边。
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late HostIdentityStore store;
  late HostServiceController controller;

  // 避开 17890（生产端口），免得与本机真跑着的实例撞车
  const PortRange testPorts = PortRange(start: 17985, end: 17999);
  const String fakeIp = '192.168.1.7';

  int clock = 1700000000000;
  int now() => clock++;

  /// 带**可控 LAN 地址**的控制器（探测结果是网络环境的函数，测试不能依赖真网卡）
  HostServiceController build({
    HostIdentityStore? identities,
    PortRange ports = testPorts,
    Future<String?> Function()? detectLocalIp,
  }) => HostServiceController(
    db: db,
    identities: identities ?? store,
    ports: ports,
    detectLocalIp: detectLocalIp ?? () async => fakeIp,
    clock: now,
  );

  setUp(() {
    db = newMemoryDb();
    store = HostIdentityStore.inMemory();
    controller = build();
  });

  tearDown(() async => controller.stop());

  /// 每次都新建客户端：`resetToken` 会 `force: true` 关掉在飞的连接
  /// （旧令牌已作废，这是对的），但复用的 keep-alive 池会因此拿到死连接。
  Future<int> get(int port, String path, {String? token}) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      if (token != null) {
        request.headers.set('authorization', 'Bearer $token');
      }
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  group('LocalIp.choose（纯函数）', () {
    test('跳过环路与 link-local，私有网段优先', () {
      expect(
        LocalIp.choose(<NetCandidate>[
          const NetCandidate('Wi-Fi', <String>['127.0.0.1']),
          const NetCandidate('eth0', <String>['169.254.3.4']),
          const NetCandidate('eth0', <String>['203.0.113.9']),
          const NetCandidate('Wi-Fi', <String>['192.168.1.7']),
        ]),
        '192.168.1.7',
      );
    });

    test('虚拟网卡被跳过（WSL 的 172.x 不抢真网卡）', () {
      expect(
        LocalIp.choose(<NetCandidate>[
          const NetCandidate('vEthernet (WSL)', <String>['172.20.0.1']),
          const NetCandidate('Wi-Fi', <String>['192.168.1.7']),
        ]),
        '192.168.1.7',
      );
    });

    test('只剩虚拟网卡时兜底，不返回 null', () {
      expect(
        LocalIp.choose(<NetCandidate>[
          const NetCandidate('vEthernet (WSL)', <String>['172.20.0.1']),
        ]),
        '172.20.0.1',
      );
    });

    test('一块网卡都没有 ⇒ null（UI 必须能处理）', () {
      expect(LocalIp.choose(<NetCandidate>[]), isNull);
    });
  });

  group('LocalIp.detect（接缝：扫网卡可注入）', () {
    test('扫到空 / 全 loopback / 全 link-local ⇒ null', () async {
      expect(await LocalIp.detect(scan: () async => <NetCandidate>[]), isNull);
      expect(
        await LocalIp.detect(
          scan: () async => <NetCandidate>[
            const NetCandidate('lo', <String>['127.0.0.1']),
          ],
        ),
        isNull,
      );
      expect(
        await LocalIp.detect(
          scan: () async => <NetCandidate>[
            const NetCandidate('eth0', <String>['169.254.1.1']),
          ],
        ),
        isNull,
      );
    });

    test('扫到真网卡 ⇒ 挑出私有地址（虚拟网卡不抢）', () async {
      expect(
        await LocalIp.detect(
          scan: () async => <NetCandidate>[
            const NetCandidate('vEthernet (WSL)', <String>['172.20.0.1']),
            const NetCandidate('Wi-Fi', <String>['192.168.1.7']),
          ],
        ),
        '192.168.1.7',
      );
    });

    test('扫网卡本身抛异常 ⇒ 返回 null，**不上抛**', () async {
      // 上抛会把「找不到地址」升级成「同步服务起不来」——两件事差一个量级（同 §AT 口径）
      expect(
        await LocalIp.detect(
          scan: () async => throw const SocketException('no nic'),
        ),
        isNull,
      );
    });
  });

  group('起始态', () {
    test('恒为 stopped —— 开关不持久化（§AH 遗漏 5）', () {
      final HostServiceSnapshot snapshot = controller.snapshot;
      expect(snapshot.state, HostServiceState.stopped);
      expect(snapshot.headline, '已关闭');
      expect(snapshot.qrAvailable, isFalse);
      expect(snapshot.needsReset, isFalse);
      expect(snapshot.addressLine, isNull);
      // running 之外不显示「连接」那行
      expect(snapshot.trafficLabel(now()), isNull);
    });
  });

  group('start', () {
    test('首次启动：本会话生成令牌 ⇒ 能画码，载荷可解析回自身', () async {
      final HostServiceSnapshot snapshot = await controller.start();

      expect(snapshot.state, HostServiceState.running);
      expect(snapshot.headline, '已开启');
      expect(snapshot.port, inInclusiveRange(testPorts.start, testPorts.end));
      expect(snapshot.address, fakeIp);
      expect(
        snapshot.addressLine,
        '主机地址：$fakeIp:${snapshot.port}',
        reason: '§AH 遗漏 4：扫码失败时用户要能手打地址',
      );
      expect(snapshot.qrAvailable, isTrue);
      expect(snapshot.needsReset, isFalse);
      expect(snapshot.trafficLabel(now()), '还没有手机连接过');
      expect(snapshot.detail, isNull);

      final PairingPayload payload = controller.pairingPayload!;
      expect(payload.uri, contains('ip=$fakeIp'));
      expect(PairingPayload.parse(payload.uri).token, payload.token);
    });

    test('幂等：再点一次不会起第二个服务', () async {
      final int? first = (await controller.start()).port;
      final int? second = (await controller.start()).port;
      expect(second, first);
    });

    test('探不到局域网地址：服务照起，但不画码、给「怎么办」', () async {
      final HostServiceController noIp = build(detectLocalIp: () async => null);
      addTearDown(noIp.stop);

      final HostServiceSnapshot snapshot = await noIp.start();
      expect(snapshot.state, HostServiceState.running);
      expect(snapshot.address, isNull);
      expect(snapshot.addressLine, isNull);
      expect(snapshot.addressHint, contains('热点'));
      expect(snapshot.detail, snapshot.addressHint);
      expect(
        snapshot.qrAvailable,
        isFalse,
        reason: '宁可说「找不到地址」，也不能把 0.0.0.0 画进二维码',
      );
    });

    test('端口全被占 ⇒ failed，文案给端口范围 + 怎么办', () async {
      final ServerSocket blocker = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      addTearDown(blocker.close);

      final HostServiceController busy = build(
        ports: PortRange(start: blocker.port, end: blocker.port),
      );
      addTearDown(busy.stop);

      final HostServiceSnapshot snapshot = await busy.start();
      expect(snapshot.state, HostServiceState.failed);
      expect(snapshot.headline, '启动失败');
      expect(snapshot.failureHint, contains('${blocker.port}'));
      expect(snapshot.failureHint, contains('防火墙'));
      expect(snapshot.detail, snapshot.failureHint);
      expect(snapshot.qrAvailable, isFalse);
    });
  });

  group('真 HTTP：鉴权与活动统计', () {
    test('health 免鉴权；pull 要令牌；只有通过鉴权才算「有活动」', () async {
      final HostServiceSnapshot snapshot = await controller.start();
      final int port = snapshot.port!;
      final String token = controller.pairingPayload!.token;

      expect(await get(port, '/api/health'), 200, reason: '配对前就要能探到主机');
      expect(await get(port, '/api/sync/pull'), 401);
      expect(await get(port, '/api/sync/pull', token: 'nope'), 401);
      expect(controller.snapshot.trafficCount, 0, reason: '401 不算活动');

      expect(await get(port, '/api/sync/pull', token: token), 200);
      expect(controller.snapshot.trafficCount, 1);
      expect(controller.snapshot.trafficLabel(now()), '最近连接：刚刚');
    });

    test('trafficLabel 按分钟/小时降级', () async {
      await controller.start();
      final int port = controller.snapshot.port!;
      await get(port, '/api/sync/pull', token: controller.pairingPayload!.token);

      final int at = controller.snapshot.lastTrafficAt!;
      expect(controller.snapshot.trafficLabel(at + 5 * 60000), '最近连接：5 分钟前');
      expect(controller.snapshot.trafficLabel(at + 3 * 3600000), '最近连接：3 小时前');
    });
  });

  group('令牌生命周期', () {
    test('resetToken：换令牌 + 换 host_id + 旧令牌立刻失效', () async {
      await controller.start();
      final String oldToken = controller.pairingPayload!.token;
      final String oldHostId = controller.pairingPayload!.hostId;

      final HostServiceSnapshot after = await controller.resetToken();
      expect(after.state, HostServiceState.running);
      expect(after.qrAvailable, isTrue);

      final PairingPayload fresh = controller.pairingPayload!;
      expect(fresh.token, isNot(oldToken));
      expect(fresh.hostId, isNot(oldHostId), reason: '§9.3：所有设备重新配对');

      final int port = after.port!;
      expect(await get(port, '/api/sync/pull', token: fresh.token), 200);
      expect(
        await get(port, '/api/sync/pull', token: oldToken),
        401,
        reason: '重置后旧手机必须连不上',
      );
    });

    test('**重启后画不出码**（明文不落盘）—— 但服务本身没坏', () async {
      await controller.start();
      final String token = controller.pairingPayload!.token;
      await controller.stop();

      // 同一个 host.json（里面只有 sha256），新一个控制器 = 模拟应用重启
      final HostServiceController restarted = build();
      addTearDown(restarted.stop);
      final HostServiceSnapshot snapshot = await restarted.start();

      expect(snapshot.state, HostServiceState.running);
      expect(
        snapshot.qrAvailable,
        isFalse,
        reason: '明文不可逆：重启后拿不到它，就画不出二维码',
      );
      expect(snapshot.needsReset, isTrue, reason: 'UI 据此给「重新生成配对码」');
      expect(restarted.pairingPayload, isNull);
      expect(
        await get(snapshot.port!, '/api/sync/pull', token: token),
        200,
        reason: '已配对的手机不受影响 —— 校验只需要哈希',
      );
      expect((await restarted.resetToken()).qrAvailable, isTrue);
    });

    test('stop 后再 start：令牌不变（没重置就不该换）', () async {
      await controller.start();
      final String token = controller.pairingPayload!.token;
      await controller.stop();
      await controller.start();
      expect(controller.pairingPayload!.token, token);
    });
  });

  group('stop', () {
    test('回到 stopped 并清空运行期状态（地址会过期，不能留）', () async {
      await controller.start();
      final HostServiceSnapshot snapshot = await controller.stop();

      expect(snapshot.state, HostServiceState.stopped);
      expect(snapshot.port, isNull);
      expect(snapshot.address, isNull);
      expect(snapshot.addressLine, isNull);
      expect(snapshot.trafficCount, 0);
      expect(snapshot.lastTrafficAt, isNull);
    });

    test('幂等：没开也能调', () async {
      expect((await controller.stop()).state, HostServiceState.stopped);
    });
  });

  group('单飞：并发防御是服务自己的职责，不靠面板的 _busy', () {
    test('连点两下 start ⇒ 复用同一个 Future；跑完再调是新一轮', () async {
      final Future<HostServiceSnapshot> a = controller.start();
      final Future<HostServiceSnapshot> b = controller.start();
      expect(identical(a, b), isTrue);
      expect((await a).state, HostServiceState.running);

      final Future<HostServiceSnapshot> next = controller.start();
      expect(identical(a, next), isFalse);
      await next;
    });

    test('**启动中按停止不会被丢弃**（异种动作排队，不复用 Future）', () async {
      final Future<HostServiceSnapshot> starting = controller.start();
      final Future<HostServiceSnapshot> stopping = controller.stop();
      expect(
        identical(starting, stopping),
        isFalse,
        reason: '复用会让这次「停止」被静默吞掉、服务照起 —— 比竞态更糟',
      );

      final HostServiceSnapshot after = await stopping;
      expect(after.state, HostServiceState.stopped);
      expect(after.port, isNull, reason: '端口要真的关掉');
      await starting; // 收尾，别把在飞的 Future 留在 tearDown 后面
    });

    test('连点两下 stop ⇒ 复用同一个 Future', () async {
      await controller.start();
      final Future<HostServiceSnapshot> a = controller.stop();
      final Future<HostServiceSnapshot> b = controller.stop();
      expect(identical(a, b), isTrue);
      await a;
    });

    test('resetToken 不自等待（内部走 _startRaw / _stopRaw）', () async {
      await controller.start();
      final HostServiceSnapshot after = await controller
          .resetToken()
          .timeout(const Duration(seconds: 10));
      expect(after.state, HostServiceState.running);
      expect(after.qrAvailable, isTrue, reason: '重置后应拿到可扫的新码');
    });

    test('reset 在飞时再调 reset ⇒ 复用同一个 Future', () async {
      final Future<HostServiceSnapshot> a = controller.resetToken();
      final Future<HostServiceSnapshot> b = controller.resetToken();
      expect(identical(a, b), isTrue);
      await a;
    });
  });

  group('文案', () {
    test('resetWarning 说清「掉线」（不只是「重新扫码」）', () {
      expect(HostServiceSnapshot.resetWarning, contains('掉线'));
      expect(HostServiceSnapshot.resetWarning, contains('重新扫'));
    });
  });

  group('host.json 位置', () {
    test('落在数据目录下（主机设施放文件，不动 schema）', () {
      // 参数是**路径字符串** —— 与 `DataLocation.directory` 同型
      expect(hostIdentityFile('D:/data').path, endsWith(hostIdentityFileName));
      expect(hostIdentityFile('D:/data').path, contains('data'));
    });
  });
}
