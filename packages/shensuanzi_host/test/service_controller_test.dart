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
    Future<List<NetAddressOption>> Function()? detectAddresses,
    InternetAddress? Function(String address)? resolveBindAddress,
    void Function(String label, Object error, StackTrace stack)?
    onInternalError,
  }) => HostServiceController(
    db: db,
    identities: identities ?? store,
    ports: ports,
    detectLocalIp: detectLocalIp ?? () async => fakeIp,
    detectAddresses: detectAddresses,
    // 2026-11-16（提案 62 第一刀）：服务现在**绑探测到的地址**，
    // 而 `fakeIp`（192.168.x）在本机绑不上 ⇒ 测试把它映射到 loopback。
    // 「绑的是不是探测到的那个」由专门的用例断言（会捕获入参）。
    resolveBindAddress:
        resolveBindAddress ?? (String _) => InternetAddress.loopbackIPv4,
    clock: now,
    onInternalError: onInternalError,
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

    // ---------------------------------------------------------------- D-1
    // 复跑现场（2026-10-25）：机器上装了 `natpierce` 穿透工具，多出一块
    // `natpierce` 网卡（10.6.22.1）。Windows 的枚举顺序把它排在 `WLAN` 之前，
    // 而 `virtualMarkers` 是**穷举法**、名单里没有它 ⇒ 规则 ① 直接命中隧道地址，
    // 手机 `http=000` 5 秒超时 —— 整组同步测试卡了半小时。
    //
    // 修法 = **正向规则**（真网卡名优先）+ 补齐已知隧道名，两道都要有：
    // 只补名单，将来换了别的穿透工具又会踩；只加正向规则，纯隧道环境仍会挑错。
    test('D-1：natpierce 隧道网卡不许抢 WLAN（两种枚举顺序都要对）', () {
      // ① 隧道在前（现场就是这一种，Windows 的实际顺序）
      expect(
        LocalIp.choose(<NetCandidate>[
          const NetCandidate('natpierce', <String>['10.6.22.1']),
          const NetCandidate('WLAN', <String>['10.102.43.94']),
        ]),
        '10.102.43.94',
        reason: '规则 ① 从前是"私有 + 非虚拟"，而 natpierce 不在虚拟名单里 ⇒ 直接挑错',
      );
      // ② 真网卡在前（不许因为顺序变了就换答案 —— 选择结果必须与枚举顺序无关）
      expect(
        LocalIp.choose(<NetCandidate>[
          const NetCandidate('WLAN', <String>['10.102.43.94']),
          const NetCandidate('natpierce', <String>['10.6.22.1']),
        ]),
        '10.102.43.94',
      );
    });

    test('D-1 护栏：只有隧道网卡时仍返回它（不许退化成 null）', () {
      // 「全部候选都是虚拟网卡」是**既有行为**：返回一个总比返回 null 好 ——
      // null 会让二维码画不出来，用户连"猜一个地址"的机会都没有。
      expect(
        LocalIp.choose(<NetCandidate>[
          const NetCandidate('natpierce', <String>['10.6.22.1']),
        ]),
        '10.6.22.1',
      );
      expect(
        LocalIp.choose(<NetCandidate>[
          const NetCandidate('Tailscale', <String>['100.64.1.1']),
          const NetCandidate('natpierce', <String>['10.6.22.1']),
        ]),
        isNotNull,
        reason: '两个都是隧道 ⇒ 仍要给一个地址，不能 null',
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

  group('LocalIp.detectAll / rank（D 批：把候选列出来让人自己挑）', () {
    test('排序：真网卡私有地址在前，隧道垫底', () {
      final List<NetAddressOption> ranked = LocalIp.rank(<NetCandidate>[
        const NetCandidate('natpierce', <String>['10.6.22.1']),
        const NetCandidate('WLAN', <String>['10.102.43.94']),
        const NetCandidate('以太网', <String>['192.168.1.7']),
      ]);
      expect(
        <String>[for (final NetAddressOption o in ranked) o.address],
        <String>['10.102.43.94', '192.168.1.7', '10.6.22.1'],
      );
      expect(ranked.first.name, 'WLAN', reason: '界面要显示网卡名，用户才认得出哪个是自己家的 WiFi');
      expect(ranked.first.label, contains('10.102.43.94'));
      expect(ranked.first.label, contains('WLAN'));
    });

    test('同档内保持枚举顺序（不用 sort —— Dart 的 sort 不保证稳定）', () {
      final List<NetAddressOption> ranked = LocalIp.rank(<NetCandidate>[
        const NetCandidate('WLAN', <String>['10.0.0.2']),
        const NetCandidate('以太网', <String>['10.0.0.1']),
      ]);
      expect(
        <String>[for (final NetAddressOption o in ranked) o.address],
        <String>['10.0.0.2', '10.0.0.1'],
      );
    });

    test('detectAll：扫不动 ⇒ 空列表，**不上抛**（与 detect 同口径）', () async {
      expect(
        await LocalIp.detectAll(scan: () async => <NetCandidate>[]),
        isEmpty,
      );
      expect(
        await LocalIp.detectAll(
          scan: () async => throw const SocketException('no nic'),
        ),
        isEmpty,
      );
    });
  });

  group('selectAddress（D 批：自动挑选猜错时的自救）', () {
    test('能在候选里换地址，二维码跟着变；不在候选里的拒绝', () async {
      final HostServiceController c = build(
        detectAddresses: () async => const <NetAddressOption>[
          NetAddressOption(name: 'WLAN', address: '10.102.43.94'),
          NetAddressOption(name: 'natpierce', address: '10.6.22.1'),
        ],
      );
      addTearDown(c.stop);
      int woke = 0;
      c.addDataListener(() => woke++);

      final HostServiceSnapshot started = await c.start();
      expect(started.address, '10.102.43.94', reason: '默认取排好序的第一个');
      expect(started.addressOptions.length, 2);
      expect(started.hasAddressChoice, isTrue);
      expect(c.pairingPayload!.ip, '10.102.43.94');

      expect(await c.selectAddress('10.6.22.1'), isTrue);
      expect(c.snapshot.address, '10.6.22.1');
      expect(
        c.pairingPayload!.ip,
        '10.6.22.1',
        reason: '二维码必须跟着换 —— 换了地址但码没变，等于没换',
      );
      expect(woke, greaterThan(0), reason: '界面要重画（否则用户以为没生效）');

      expect(
        await c.selectAddress('1.2.3.4'),
        isFalse,
        reason: '不在候选里的地址不接受 —— 手填错 IP 会变成"码看着正常、就是连不上"',
      );
      expect(c.snapshot.address, '10.6.22.1');
    });

    test('只有一块网卡时没有选择项（不摆一个假的"换地址"）', () async {
      final HostServiceController c = build();
      addTearDown(c.stop);
      final HostServiceSnapshot started = await c.start();
      expect(started.addressOptions, isEmpty);
      expect(started.hasAddressChoice, isFalse);
      expect(started.address, fakeIp, reason: '退回单地址探测，行为与从前一致');
    });
  });

  // ------------------------------------------------ 提案 62 第二刀（2026-11-16）
  //
  // 第一刀之后「换地址只改二维码」变成半真半假。第二刀 = **真的换绑定**。
  // 反向灵敏度（手动验过）：把 `_startRaw(preferredAddress: to)` 的
  // `preferredAddress` 去掉 ⇒ 「重绑用的是新地址」与「不再重新探测」双双变红。
  group('换地址 = 真的换绑定（提案 62 第二刀）', () {
    List<NetAddressOption> twoNics() => const <NetAddressOption>[
      NetAddressOption(name: 'WLAN', address: '10.102.43.94'),
      NetAddressOption(name: 'natpierce', address: '10.6.22.1'),
    ];

    test('换地址后服务**重新绑到新地址**，且不重新探测网卡', () async {
      final List<String> bindings = <String>[];
      int detected = 0;
      final HostServiceController c = build(
        detectAddresses: () async {
          detected++;
          return twoNics();
        },
        resolveBindAddress: (String ip) {
          bindings.add(ip);
          return InternetAddress.loopbackIPv4;
        },
      );
      addTearDown(c.stop);

      await c.start();
      expect(bindings, <String>['10.102.43.94'], reason: '启动绑的是第一个候选');

      expect(await c.selectAddress('10.6.22.1'), isTrue);
      expect(bindings, <String>[
        '10.102.43.94',
        '10.6.22.1',
      ], reason: '必须**重新绑**到新地址 —— 这是第二刀的全部意义');
      expect(detected, 1, reason: '重绑不许重新探测：探测会把地址覆盖回「排序第一」，等于没换');
      expect(c.snapshot.state, HostServiceState.running, reason: '断连一瞬间后要自己起来');
      expect(c.boundAddress, InternetAddress.loopbackIPv4);
      expect(c.snapshot.address, '10.6.22.1');
      expect(c.pairingPayload!.ip, '10.6.22.1', reason: '码里的地址与绑定同源');
    });

    test('换地址时那个 6 位短码**重新发一个**（旧的会被 clear 掉）', () async {
      final HostServiceController c = build(
        detectAddresses: () async => twoNics(),
      );
      addTearDown(c.stop);
      await c.start();

      final String before = c.pairRequests.issueCode();
      expect(before.length, 6);

      expect(await c.selectAddress('10.6.22.1'), isTrue);
      final String? after = c.pairRequests.code;
      expect(
        after,
        isNotNull,
        reason: '停服务会 clear() 掉短码；不补发的话用户在短码对话框里换完地址，码就凭空消失',
      );
      expect(after, isNot(before), reason: '补发的是新码（旧码随服务一起作废了）');
    });

    test('新地址绑不上 ⇒ 退回原地址 + 返回 false（不让用户丢服务）', () async {
      final HostServiceController c = build(
        detectAddresses: () async => twoNics(),
        // 新地址解析成一个本机没有的地址 ⇒ `HttpServer.bind` 抛 SocketException
        resolveBindAddress: (String ip) => ip == '10.6.22.1'
            ? InternetAddress('8.8.8.8')
            : InternetAddress.loopbackIPv4,
      );
      addTearDown(c.stop);
      expect((await c.start()).address, '10.102.43.94');

      expect(await c.selectAddress('10.6.22.1'), isFalse, reason: '不许假装成功');
      expect(
        c.snapshot.state,
        HostServiceState.running,
        reason: '换失败也要退回原地址把服务拉起来 —— 否则用户「换了个连不上的」还丢了服务',
      );
      expect(c.snapshot.address, '10.102.43.94', reason: '地址行要退回能用的那个');
      expect(c.pairingPayload!.ip, '10.102.43.94');
    });

    test('没在听时换地址只改界面（没有绑定可换）', () async {
      final HostServiceController c = build(
        detectAddresses: () async => twoNics(),
      );
      addTearDown(c.stop);
      await c.start();
      await c.stop();

      // 停掉之后候选表已经清空 ⇒ 一律拒绝（第二刀之前也是这个结果）
      expect(c.snapshot.addressOptions, isEmpty);
      expect(await c.selectAddress('10.6.22.1'), isFalse);
      expect(c.snapshot.state, HostServiceState.stopped);
    });
  });

  // ---------------------------------------------------------------- 端口契约
  //
  // `docs/reply_review.md` §九十·⑥ 登记的欠账：「换地址后端口不变」原来只是
  // **实测事实**，不是契约。2026-11-17 把它变成契约（`_startRaw` 的 `preferredPort`）。
  //
  // 为什么值一条测试：手机端有「连不上？手动填地址」那条路，用户手敲过 ip:port；
  // 端口一换，他手填的那个就失效了，而界面只会说「连不上」。
  //
  // 反向灵敏度（落定时验过）：去掉 `preferredPort` ⇒ 下面这条红（端口从第二个退回第一个）。
  group('端口契约（换地址不换端口）', () {
    test('range 首端口刚空出来也不许换 —— 手机里手填过的 ip:port 不能失效', () async {
      // 先把 range 的第一个端口占住 ⇒ 服务只能落到第二个
      final ServerSocket blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(blocker.close);
      final int first = blocker.port;

      final HostServiceController c = build(
        ports: PortRange(start: first, end: first + 2),
        detectAddresses: () async => const <NetAddressOption>[
          NetAddressOption(name: 'WLAN', address: '10.102.43.94'),
          NetAddressOption(name: 'natpierce', address: '10.6.22.1'),
        ],
      );
      addTearDown(c.stop);

      final HostServiceSnapshot started = await c.start();
      expect(started.port, isNot(first), reason: '首端口被占着，服务只能落到下一个');
      final int port = started.port!;

      // 占着的人走了 —— 不守约的实现会在重绑时回到更靠前的那个端口
      await blocker.close();

      expect(await c.selectAddress('10.6.22.1'), isTrue);
      expect(
        c.snapshot.port,
        port,
        reason: '换地址只该换绑定地址；端口变了 = 用户手填的 ip:port 失效',
      );
      expect(c.snapshot.state, HostServiceState.running);
      expect(c.snapshot.address, '10.6.22.1');
    });
  });

  // ---------------------------------------------------------------- 提案 64
  //
  // 2026-11-17：绑定收紧（第一刀）带来**新代价** —— 换 WiFi / 拔网线之后监听套接字
  // 还挂在旧 IP 上，二维码里写的地址已经不存在，而界面仍显示「已开启」。
  // 控制器负责判断（`recheckAddress`），UI 只取值显示。
  //
  // 反向灵敏度（落定时手动验过）：把 `_staleAddress = ... : null` 的三元写反
  // ⇒ 「换了网卡 ⇒ 报失效」立刻红；只保留 `latest.any(...)` 不写 `_addressOptions`
  // ⇒ 「候选表要换成新的」那条红。
  group('地址失效提示（提案 64）', () {
    List<NetAddressOption> nicsWifiA() => const <NetAddressOption>[
      NetAddressOption(name: 'WLAN', address: '192.168.1.7'),
      NetAddressOption(name: 'natpierce', address: '10.6.22.1'),
    ];

    /// 换了 WiFi：旧的 192.168.1.7 没了，新的是 192.168.0.20
    List<NetAddressOption> nicsWifiB() => const <NetAddressOption>[
      NetAddressOption(name: 'WLAN', address: '192.168.0.20'),
    ];

    test('换了网卡 ⇒ 报失效，并把候选表换成新的（否则「换地址」列表还是旧的）', () async {
      int detected = 0;
      late List<NetAddressOption> current;
      current = nicsWifiA();
      final HostServiceController c = build(
        detectAddresses: () async {
          detected++;
          return current;
        },
      );
      addTearDown(c.stop);
      await c.start();
      expect(c.snapshot.staleAddress, isNull, reason: '刚探过，这会儿还不能说它失效');

      // 用户切到另一个 WiFi
      current = nicsWifiB();
      final HostServiceSnapshot after = await c.recheckAddress();

      expect(after.staleAddress, '192.168.1.7');
      expect(
        after.addressOptions.map((NetAddressOption o) => o.address),
        <String>['192.168.0.20'],
        reason: '候选表必须是**这次**探到的 —— 不然对话框里换不过去',
      );
      expect(detected, 2, reason: '启动一次 + 重探一次');
      // 提示里三件事都要有：旧地址、新地址、怎么办
      expect(after.staleAddressHint, contains('192.168.1.7'));
      expect(after.staleAddressHint, contains('192.168.0.20'));
      expect(after.staleAddressHint, contains('显示二维码'));
      // **不自动重绑**：服务还听在旧地址上，等用户点
      expect(after.address, '192.168.1.7');
      expect(after.state, HostServiceState.running);
    });

    test('地址没变 ⇒ 不报失效（探到多一块网卡也不算）', () async {
      late List<NetAddressOption> current;
      current = nicsWifiA();
      final HostServiceController c = build(
        detectAddresses: () async => current,
      );
      addTearDown(c.stop);
      await c.start();

      current = const <NetAddressOption>[
        NetAddressOption(name: 'WLAN', address: '192.168.1.7'),
        NetAddressOption(name: '以太网', address: '192.168.1.9'),
      ];
      final HostServiceSnapshot after = await c.recheckAddress();

      expect(after.staleAddress, isNull);
      expect(after.staleAddressHint, isNull);
      expect(after.addressOptions.length, 2, reason: '候选表仍要更新（多了一块网卡）');
    });

    test('探测失败（一块网卡都没有）⇒ **不**报失效，也**不**清空候选表', () async {
      late List<NetAddressOption> current;
      current = nicsWifiA();
      final HostServiceController c = build(
        detectAddresses: () async => current,
        detectLocalIp: () async => null,
      );
      addTearDown(c.stop);
      await c.start();

      current = const <NetAddressOption>[];
      final HostServiceSnapshot after = await c.recheckAddress();

      expect(
        after.staleAddress,
        isNull,
        reason: '探不到 ≠ 地址失效 —— 凭空吓唬人比不提示更糟',
      );
      expect(after.addressOptions.length, 2, reason: '证据不足时保留上一份候选表');
    });

    test('没在听 ⇒ 不探测（`recheckAddress` 只对运行中的服务有意义）', () async {
      int detected = 0;
      final HostServiceController c = build(
        detectAddresses: () async {
          detected++;
          return nicsWifiA();
        },
      );
      addTearDown(c.stop);

      await c.recheckAddress();
      expect(detected, 0);
      expect(c.snapshot.staleAddress, isNull);
    });

    test('换到新地址之后 ⇒ 失效标记被清掉', () async {
      late List<NetAddressOption> current;
      current = nicsWifiA();
      final HostServiceController c = build(
        detectAddresses: () async => current,
      );
      addTearDown(c.stop);
      await c.start();

      current = nicsWifiB();
      expect((await c.recheckAddress()).staleAddress, '192.168.1.7');

      expect(await c.selectAddress('192.168.0.20'), isTrue);
      expect(
        c.snapshot.staleAddress,
        isNull,
        reason: '换过去了就不该继续红着 —— 否则用户会以为没生效',
      );
      expect(c.snapshot.address, '192.168.0.20');
    });
  });

  // ---------------------------------------------------------------- 提案 62 第一刀
  //
  // 2026-11-16 裁定「乙」：**只绑探测到的局域网网卡**；探不到才回退 `0.0.0.0`，
  // 并用 `bindFallback` 明说（界面上那句 addressHint 就是「明说」）。
  //
  // 反向灵敏度（手动验过）：把 `_startRaw` 里的 `address: bind` 删掉
  // ⇒ 「绑的是探测地址」那条立刻红（服务会绑回 `0.0.0.0`）。
  group('绑定收紧（提案 62 第一刀）', () {
    test('启动时绑的是**探测到的局域网地址**，不是 0.0.0.0', () async {
      String? resolved;
      final HostServiceController c = build(
        resolveBindAddress: (String ip) {
          resolved = ip;
          return InternetAddress.loopbackIPv4;
        },
      );
      addTearDown(c.stop);

      final HostServiceSnapshot snapshot = await c.start();
      expect(resolved, fakeIp, reason: '生产把**选定地址**交给 tryParse —— 这里捕获到的必须是它');
      expect(c.boundAddress, InternetAddress.loopbackIPv4);
      expect(
        c.boundAddress,
        isNot(InternetAddress.anyIPv4),
        reason: '绑 0.0.0.0 就是文档里那句假话的根源',
      );
      expect(snapshot.bindFallback, isFalse);
      expect(snapshot.address, fakeIp, reason: '二维码里的地址不受绑定方式影响');
    });

    test('探不到地址 ⇒ 仍然 running + 回退绑全部网卡 + 界面明说', () async {
      final HostServiceController c = build(
        detectLocalIp: () async => null,
        detectAddresses: () async => const <NetAddressOption>[],
      );
      addTearDown(c.stop);

      final HostServiceSnapshot snapshot = await c.start();
      expect(
        snapshot.state,
        HostServiceState.running,
        reason: '裁定乙：不拒绝启动 —— 拒绝会让用户以为软件坏了',
      );
      expect(snapshot.bindFallback, isTrue);
      expect(c.boundAddress, InternetAddress.anyIPv4);
      expect(snapshot.address, isNull);
      expect(
        snapshot.detail,
        contains('监听全部网卡'),
        reason: '不能留假话：必须让用户在界面上看到这一句',
      );
      expect(snapshot.qrAvailable, isFalse, reason: '没地址就画不出码（现状不变）');
    });

    test('先回退、后探到地址 ⇒ bindFallback 复位为 false', () async {
      bool hasIp = false;
      final HostServiceController c = build(
        detectLocalIp: () async => hasIp ? fakeIp : null,
        detectAddresses: () async => const <NetAddressOption>[],
      );
      addTearDown(c.stop);

      expect((await c.start()).bindFallback, isTrue);
      hasIp = true;
      await c.stop();
      final HostServiceSnapshot again = await c.start();
      expect(again.bindFallback, isFalse);
      expect(c.boundAddress, InternetAddress.loopbackIPv4);
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
      await get(
        port,
        '/api/sync/pull',
        token: controller.pairingPayload!.token,
      );

      final int at = controller.snapshot.lastTrafficAt!;
      expect(controller.snapshot.trafficLabel(at + 5 * 60000), '最近连接：5 分钟前');
      expect(controller.snapshot.trafficLabel(at + 3 * 3600000), '最近连接：3 小时前');
    });
  });

  group('令牌生命周期', () {
    // C-3（2026-10-24，用户裁定 ⑦甲）：resetToken 只换令牌，**host_id 不变**
    // —— 手机重扫后是「同一台主机重新配对」，不清镜像、不挂起队列。
    test('resetToken：换令牌、host_id 不变（C-3）、旧令牌立刻失效', () async {
      await controller.start();
      final String oldToken = controller.pairingPayload!.token;
      final String oldHostId = controller.pairingPayload!.hostId;

      final HostServiceSnapshot after = await controller.resetToken();
      expect(after.state, HostServiceState.running);
      expect(after.qrAvailable, isTrue);

      final PairingPayload fresh = controller.pairingPayload!;
      expect(fresh.token, isNot(oldToken));
      expect(fresh.hostId, oldHostId, reason: 'C-3：主机身份持久化 —— 重生成配对码 ≠ 换主机');

      final int port = after.port!;
      expect(await get(port, '/api/sync/pull', token: fresh.token), 200);
      expect(
        await get(port, '/api/sync/pull', token: oldToken),
        401,
        reason: '重置后旧手机必须连不上',
      );
    });

    // ⚠️ 2026-11-01 语义变更（用户裁定，提案 57）：从前这条叫「重启后画不出码」，
    // 断言 `qrAvailable == false` —— 那是**旧设计**（只存哈希）。现在明文由
    // DPAPI 加密落盘、重启能解回来 ⇒ **重启后照样画同一个码**。
    // 旧行为没有消失：它现在是「加密器不可用」那条降级路径，见下一个用例。
    test('重启后**仍能画同一个码**（DPAPI 解回明文）—— 手机不用重扫', () async {
      if (!const DpapiTokenProtector().isSupported) {
        markTestSkipped('本条要真 DPAPI；非 Windows 上由下一条（降级）覆盖');
        return;
      }
      // 用**独立的** store（不共用 setUp 那个），模拟「同一个 host.json」
      final HostIdentityStore shared = HostIdentityStore.inMemory();
      final HostServiceController first = build(identities: shared);
      addTearDown(first.stop);
      await first.start();
      final String token = first.pairingPayload!.token;
      final String hostId = first.pairingPayload!.hostId;
      await first.stop();

      // 同一个 store（里面有 DPAPI 密文），新控制器 = 模拟应用重启
      final HostServiceController restarted = build(identities: shared);
      addTearDown(restarted.stop);
      final HostServiceSnapshot snapshot = await restarted.start();

      expect(snapshot.state, HostServiceState.running);
      expect(
        snapshot.tokenRestore,
        TokenRestoreState.restored,
        reason: '密文解回来了',
      );
      expect(snapshot.qrAvailable, isTrue, reason: '重启后能画码 —— 这才是提案 57 的目的');
      expect(snapshot.needsReset, isFalse, reason: '不再需要「重新生成配对码」');
      expect(restarted.pairingPayload!.token, token, reason: '令牌逐字相同');
      expect(restarted.pairingPayload!.hostId, hostId);
      expect(
        await get(snapshot.port!, '/api/sync/pull', token: token),
        200,
        reason: '已配对的手机照常连（本来就不受影响）',
      );
    });

    test('（降级）没有加密器时回到旧语义：重启后画不出码，但手机照连', () async {
      // 用 NoTokenProtector 的 store 模拟「这台机器不支持加密存储」
      final HostIdentityStore plain = HostIdentityStore.inMemory(
        protector: const NoTokenProtector(),
      );
      final HostServiceController legacy = build(identities: plain);
      addTearDown(legacy.stop);
      await legacy.start();
      final String token = legacy.pairingPayload!.token;
      await legacy.stop();

      final HostServiceController restarted = build(identities: plain);
      addTearDown(restarted.stop);
      final HostServiceSnapshot snapshot = await restarted.start();

      expect(snapshot.tokenRestore, TokenRestoreState.hashOnly);
      expect(snapshot.qrAvailable, isFalse, reason: '只存哈希 ⇒ 画不出码');
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
      final HostServiceSnapshot after = await controller.resetToken().timeout(
        const Duration(seconds: 10),
      );
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

  // N-f 站点 7 / 8（2026-11-05 裁定甲）：两条兜底 catch 原本只把 `$error`
  // 拼进界面文案（英文 + 端口 / 路径），**日志里什么都没留**。
  // `onInternalError` 本来就在作用域里（同一个方法别处调用过），只是没调。
  group('兜底 catch：现场进日志、界面不拼原文（N-f）', () {
    test('启动服务抛异常 ⇒ 原文交给 onInternalError，hint 里没有异常原文', () async {
      // 注入一个「探测地址就炸」的接缝：它在 `_startRaw` 的 try 里被 await，
      // 且**不是** StateError（StateError 会被端口那条专门分支接走）。
      final List<String> labels = <String>[];
      final List<Object> errors = <Object>[];
      final HostServiceController c = build(
        detectAddresses: () async => throw _Boom('探测网卡炸了'),
        onInternalError: (String label, Object error, StackTrace stack) {
          labels.add(label);
          errors.add(error);
        },
      );
      addTearDown(c.stop);

      final HostServiceSnapshot snapshot = await c.start();

      expect(snapshot.state, HostServiceState.failed);
      expect(labels, hasLength(1), reason: '现场必须有去处（裁定 ①）');
      expect(labels.single, contains('启动'));
      expect(errors.single, isA<_Boom>());
      // 界面那句：分类文案，**不含**异常类型名 / message
      final String hint = snapshot.failureHint ?? '';
      expect(hint, isNotEmpty);
      for (final String leak in <String>['Boom', 'Exception', 'StateError']) {
        expect(hint, isNot(contains(leak)), reason: '界面漏出「$leak」');
      }
      // 有出口 ⇒ 可以提日志（裁定 ③）
      expect(hint, contains('日志'));
    });

    test('没接 onInternalError ⇒ 界面**不许**提「日志」（不许指空路）', () async {
      final HostServiceController c = build(
        detectAddresses: () async => throw _Boom('探测网卡炸了'),
      );
      addTearDown(c.stop);

      final HostServiceSnapshot snapshot = await c.start();
      expect(snapshot.state, HostServiceState.failed);
      expect(snapshot.failureHint ?? '', isNot(contains('日志')));
    });

    test('resetToken 抛异常 ⇒ 原文交给 onInternalError，hint 不拼原文', () async {
      // clock 在 `reset(now: _clock())` 里求值 ⇒ 抛它就能命中 resetToken 的 catch
      final List<String> logged = <String>[];
      final HostServiceController c = HostServiceController(
        db: db,
        identities: store,
        ports: testPorts,
        detectLocalIp: () async => fakeIp,
        clock: () => throw _Boom('时钟坏了'),
        onInternalError: (String label, Object error, StackTrace stack) =>
            logged.add('$label|$error'),
      );
      addTearDown(c.stop);

      final HostServiceSnapshot snapshot = await c.resetToken();

      expect(snapshot.state, HostServiceState.failed);
      expect(logged, hasLength(1));
      expect(logged.single, contains('生成新的配对码失败'));
      expect(logged.single, contains('时钟坏了'), reason: '原文要带出去');
      final String hint = snapshot.failureHint ?? '';
      expect(hint, isNot(contains('时钟坏了')));
      expect(hint, isNot(contains('Exception')));
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

    test('落盘失败 ⇒ 原文交给宿主日志（根因未定，下次复现要有现场）', () async {
      // 2026-10-31 真机：`host.json` 被拒写（`errno = 5`），ACL / SDDL / 只读 /
      // 完整性标签全部排除，根因至今未定。当时日志里**只有一个布尔值**，
      // 等于下次复现要从零再查一遍。
      final Directory box = Directory.systemTemp.createTempSync('host_json_');
      addTearDown(() {
        try {
          box.deleteSync(recursive: true);
        } catch (_) {}
      });
      // 「父路径其实是个文件」⇒ 写盘必然失败（与真机 errno 5 同类效果）
      final File blocker = File('${box.path}${Platform.pathSeparator}blocker')
        ..writeAsStringSync('x');
      final HostIdentityStore broken = HostIdentityStore(
        File('${blocker.path}${Platform.pathSeparator}host.json'),
      );

      final List<String> labels = <String>[];
      final List<Object> errors = <Object>[];
      final HostServiceController c = build(
        identities: broken,
        onInternalError: (String label, Object error, StackTrace stack) {
          labels.add(label);
          errors.add(error);
        },
      );
      addTearDown(c.stop);

      final HostServiceSnapshot snapshot = await c.resetToken();

      // 功能照旧（降级成内存令牌）—— 日志只是**附加**，不是新故障点
      expect(snapshot.state, isNot(HostServiceState.failed));
      expect(c.identityPersistFailed, isTrue);
      expect(labels, hasLength(1), reason: '失败必须留一条日志');
      expect(labels.single, contains('host.json'));
      expect(
        errors.single.toString(),
        contains(box.path),
        reason: '原文要带上出问题的路径，否则拿到 errno 也不知道是哪个文件',
      );
    });
  });
}

/// 测试用的**具名**异常：既能确定「日志里那条就是它」，又能断言
/// 界面文案里**没有**它的类型名与 message（N-f 的判据）。
class _Boom implements Exception {
  const _Boom(this.msg);
  final String msg;
  @override
  String toString() => '_Boom: $msg';
}
