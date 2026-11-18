// 设置页「多设备同步」面板（§AH · AH-A）的 widget 测试。
//
// 覆盖：**默认关**（§AH 遗漏 5 的硬要求）+ 关闭态的文案与按钮可见性。
//
// ## ⚠️ 一处**刻意不测**的地方
//
// 「打开开关 → 跑起服务 → 弹二维码」这条路径需要一个**真实绑定的端口**，
// 而本侧（AI 沙箱）编译不到 Flutter 层 ⇒ 写完没法跑。
// 状态机本身已经被 `shensuanzi_host` 的
// `test/service_controller_test.dart` + `tool/selfcheck_service.dart`（114 项）
// 完整覆盖；这里只钉住「摆放」这一层不会退化。
// 绑定端口的 widget 测试见 `docs/reply_review.md` §BB·六 的待补清单。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/host_service_section.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

/// 等一个**真实**异步动作落地（最多 5 秒）。
///
/// 换地址从提案 62 第二刀起是「停旧监听 → 用新地址重绑」，要真的 bind socket；
/// 而 widget 测试的假时钟不会推进真实 I/O ⇒ 只能 `runAsync` + 轮询。
/// 固定 `Duration` 睡等会变成 flaky（机器慢就红），所以轮询到条件成立为止。
Future<void> _waitFor(
  bool Function() done, {
  Duration limit = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(limit);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('等待超时：条件在 ${limit.inSeconds} 秒内没有成立');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 一按开关就抛异常的控制器 —— 专门用来钉「失败后界面不会卡死」。
class _ThrowingController extends HostServiceController {
  _ThrowingController({required super.db, required super.identities})
    : super(
        ports: const PortRange(start: 17970, end: 17979),
        detectLocalIp: () async => '192.168.1.7',
        // 2026-11-16（提案 62）：服务绑**探测到的地址**，而假 IP 在本机绑不上
        // （cannot assign requested address）⇒ 测试映射到 loopback。
        // 二维码/地址行显示的仍是假 IP（那是 `_address`，不是绑定地址）。
        resolveBindAddress: (String _) => InternetAddress.loopbackIPv4,
      );

  @override
  Future<HostServiceSnapshot> start() async =>
      throw StateError('故意抛的：模拟写盘失败 / 端口异常');

  @override
  Future<HostServiceSnapshot> stop() async => snapshot;

  @override
  Future<HostServiceSnapshot> resetToken() async =>
      throw StateError('故意抛的：模拟写 host.json 失败');
}

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late HostServiceController controller;

  setUp(() {
    db = Db.openInMemory();
    controller = HostServiceController(
      db: db,
      identities: HostIdentityStore.inMemory(),
      // 不绑生产端口（17890），也不与 host 包自检的 17985~17999 撞
      ports: const PortRange(start: 17960, end: 17969),
      detectLocalIp: () async => '192.168.1.7',
      // 2026-11-16（提案 62）：服务绑**探测到的地址**，而假 IP 在本机绑不上
      // （cannot assign requested address）⇒ 测试映射到 loopback。
      // 二维码/地址行显示的仍是假 IP（那是 `_address`，不是绑定地址）。
      resolveBindAddress: (String _) => InternetAddress.loopbackIPv4,
    );
  });

  tearDown(() async {
    await controller.stop();
    db.close();
  });

  Widget panel() => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: HostServicePanel(controller: controller),
      ),
    ),
  );

  testWidgets('默认是关的，且说清「打开意味着什么」（§AH 遗漏 5）', (WidgetTester tester) async {
    await tester.pumpWidget(panel());

    expect(find.text('已关闭'), findsOneWidget);
    expect(
      tester.widget<Switch>(find.byKey(const Key('host-service-switch'))).value,
      isFalse,
      reason: '监听端口必须是显式用户动作，不是开机默认行为',
    );
    expect(find.text(HostServiceSnapshot.switchHint), findsOneWidget);
  });

  testWidgets('没开的时候不出现二维码 / 重试按钮（不给假入口）', (WidgetTester tester) async {
    await tester.pumpWidget(panel());

    expect(find.byKey(const Key('host-service-show-qr')), findsNothing);
    expect(find.byKey(const Key('host-service-reset')), findsNothing);
    expect(find.byKey(const Key('host-service-retry')), findsNothing);
  });

  testWidgets('渲染不抛异常（含单行提示的容器约束）', (WidgetTester tester) async {
    await tester.pumpWidget(panel());
    expect(tester.takeException(), isNull);
  });

  test('PairingQrPainter.shouldRepaint：同一实例 ⇒ false（§BF·二 补强 3）', () {
    const PairingPayload payload = PairingPayload(
      hostId: 'h-0001',
      ip: '192.168.1.5',
      port: 17890,
      token: 'dG9rZW4=',
    );
    final PairingQr qr = PairingQr(payload);

    expect(
      PairingQrPainter(qr).shouldRepaint(PairingQrPainter(qr)),
      isFalse,
      reason: '同一实例不该重绘 —— 否则 painter 会主动绕过 RepaintBoundary',
    );

    final PairingQr changed = PairingQr(
      const PairingPayload(
        hostId: 'h-0002',
        ip: '192.168.1.9',
        port: 17899,
        token: 'other',
      ),
    );
    expect(
      PairingQrPainter(changed).shouldRepaint(PairingQrPainter(qr)),
      isTrue,
      reason: '载荷真的换了就该重绘 —— 否则会把旧码留在屏上',
    );
  });

  // ------------------------------------------------------------ D 批（2026-10-25）
  //
  // 自动挑地址永远可能挑错（穿透工具 / 虚拟网卡 / 公司 VPN）。挑错时用户看到的
  // 只有一句「手机连不上」，从前**毫无自救手段** —— 只能来找我们。
  // 所以二维码对话框里把候选全摆出来，点一下换一个。
  testWidgets('D 批：对话框里能换网卡地址，地址行当场跟着变', (WidgetTester tester) async {
    final HostServiceController multi = HostServiceController(
      db: db,
      identities: HostIdentityStore.inMemory(),
      // 不与其它用例的端口段撞（17960~17969 / 17985~17999）
      ports: const PortRange(start: 17970, end: 17979),
      detectLocalIp: () async => '10.102.43.94',
      // 2026-11-16（提案 62）：服务绑**探测到的地址**，而假 IP 在本机绑不上
      // （cannot assign requested address）⇒ 测试映射到 loopback。
      // 二维码/地址行显示的仍是假 IP（那是 `_address`，不是绑定地址）。
      resolveBindAddress: (String _) => InternetAddress.loopbackIPv4,
      detectAddresses: () async => const <NetAddressOption>[
        NetAddressOption(name: 'WLAN', address: '10.102.43.94'),
        NetAddressOption(name: 'natpierce', address: '10.6.22.1'),
      ],
    );
    addTearDown(multi.stop);
    // ⚠️ **先 start 再 pump**：`_toggle` 里的启动是异步的，靠 `pumpAndSettle`
    // 等它完成是不可靠的（它不排帧）。先起好服务，面板 initState 直接读到 running。
    // 同理包 `runAsync`：绑端口是真实 I/O，假时钟下等不到回调就会卡死
    await tester.runAsync(() => multi.start());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HostServicePanel(controller: multi),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('可以换一个网卡地址'),
      findsOneWidget,
      reason: '候选不止一个 ⇒ 面板上就要提示，别等连不上再去找',
    );

    await tester.tap(find.byKey(const Key('host-service-show-qr')));
    await tester.pumpAndSettle();

    // ⚠️ 面板自己那行也含同样的文字（对话框是浮在它上面的）⇒ 必须限定在对话框内
    Finder inDialog(String text) => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.textContaining(text),
    );
    expect(inDialog('主机地址：10.102.43.94'), findsOneWidget);
    expect(
      find.byKey(const Key('host-address-option-10.6.22.1')),
      findsOneWidget,
    );
    expect(
      find.textContaining('10.102.43.94（WLAN）'),
      findsOneWidget,
      reason: '必须显示网卡名 —— 只给 IP 用户认不出哪个是自己家的 WiFi',
    );

    // ⚠️ 测试视口 800×600 比真实窗口矮，第二个选项被挤到对话框折叠线以下 ——
    // 真实用户会滚一下，测试里也得先滚（否则 tap 落在裁剪区外，什么都不会发生）
    final Finder second = find.byKey(
      const Key('host-address-option-10.6.22.1'),
    );
    await tester.ensureVisible(second);
    await tester.pumpAndSettle();
    // 换地址 = **真的换绑定**（提案 62 第二刀）：停旧监听 → 用新地址起，
    // 要真的 bind socket ⇒ 假时钟推不动，必须 runAsync + 轮询到换完
    await tester.runAsync(() async {
      await tester.tap(second);
      await _waitFor(() => multi.snapshot.address == '10.6.22.1');
    });
    await tester.pumpAndSettle();

    expect(
      multi.snapshot.state,
      HostServiceState.running,
      reason: '换完要自己起来 —— 半路上停掉服务是最糟的结局',
    );
    expect(
      inDialog('主机地址：10.6.22.1'),
      findsOneWidget,
      reason: '换了地址，地址行必须当场变（不许关掉再开才生效）',
    );
    expect(
      find.byKey(const Key('host-address-switching')),
      findsNothing,
      reason: '换完就得把「正在重启…」收掉',
    );
    expect(inDialog('主机地址：10.102.43.94'), findsNothing);
    expect(multi.pairingPayload!.ip, '10.6.22.1', reason: '二维码内容也要跟着换');

    // ⚠️ **必须在用例体里停服务**：`addTearDown` 跑在「无遗留 Timer」检查**之后**，
    // 而 `HttpServer` 自己带着 keep-alive 定时器 ⇒ 只靠 tearDown 会报
    // 「A Timer is still pending even after the widget tree was disposed」。
    //
    // ⚠️ 而且必须包在 `runAsync` 里：`testWidgets` 默认跑在**假时钟**下，
    // 直接 `await stop()` 会一直等不到真实 I/O 的回调 —— 实测卡死 4 分 54 秒。
    await tester.runAsync(() => multi.stop());
  });

  // 2026-11-18（提案 62 §四）：地址列表要标「推荐」+ 虚拟网卡提示。
  //
  // 判据来自实测：`LocalIp.rank` 把真网卡 + 私有网段排在前面 ⇒ 第一项就是首选；
  // 而 `vEthernet (WSL)` / VMware 这类地址「看着正常、手机连不上」，
  // 用户在一个个试的时候需要一句解释（同类坑：`natpierce` 排在 WLAN 之前那次）。
  testWidgets('地址列表：首项标「推荐」，虚拟网卡带一句「手机多半连不上」', (WidgetTester tester) async {
    final HostServiceController multi = HostServiceController(
      db: db,
      identities: HostIdentityStore.inMemory(),
      ports: const PortRange(start: 17980, end: 17984),
      detectLocalIp: () async => '10.102.43.94',
      resolveBindAddress: (String _) => InternetAddress.loopbackIPv4,
      detectAddresses: () async => const <NetAddressOption>[
        NetAddressOption(name: 'WLAN', address: '10.102.43.94'),
        NetAddressOption(name: 'vEthernet (WSL)', address: '172.24.16.1'),
      ],
    );
    addTearDown(multi.stop);
    await tester.runAsync(() => multi.start());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HostServicePanel(controller: multi),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-service-show-qr')));
    await tester.pumpAndSettle();

    Finder inDialog(Finder f) =>
        find.descendant(of: find.byType(AlertDialog), matching: f);

    expect(
      inDialog(find.byKey(const Key('host-address-recommended'))),
      findsOneWidget,
      reason: '只给首选标「推荐」，不然等于没推荐',
    );
    // 「推荐」必须落在 WLAN 那一行（不是 WSL 那行）
    expect(
      find.ancestor(
        of: find.text('推荐'),
        matching: find.byKey(const Key('host-address-option-10.102.43.94')),
      ),
      findsOneWidget,
    );
    expect(
      inDialog(find.byKey(const Key('host-address-virtual-hint'))),
      findsOneWidget,
      reason: '虚拟网卡要解释「为什么连不上」，否则用户只会一个个瞎试',
    );
    expect(
      find.ancestor(
        of: find.byKey(const Key('host-address-virtual-hint')),
        matching: find.byKey(const Key('host-address-option-172.24.16.1')),
      ),
      findsOneWidget,
      reason: '提示只能挂在虚拟那块网卡上',
    );
  });

  testWidgets('提案 64：换了 WiFi ⇒ 面板上就说「地址变了」，二维码对话框也带同一句', (
    WidgetTester tester,
  ) async {
    // 先用 WiFi A 起服务，再把「网卡」换成 WiFi B —— 模拟用户切了 WiFi
    List<NetAddressOption> current = const <NetAddressOption>[
      NetAddressOption(name: 'WLAN', address: '192.168.1.7'),
      NetAddressOption(name: 'natpierce', address: '10.6.22.1'),
    ];
    final HostServiceController mover = HostServiceController(
      db: db,
      identities: HostIdentityStore.inMemory(),
      // 与文件里其它用例的端口段错开（17940/17960/17970 都被占了）
      ports: const PortRange(start: 17920, end: 17929),
      detectLocalIp: () async => '192.168.1.7',
      resolveBindAddress: (String _) => InternetAddress.loopbackIPv4,
      detectAddresses: () async => current,
    );
    // 绑端口是真实 I/O ⇒ 必须先 runAsync 起好，面板 initState 直接读到 running
    await tester.runAsync(() => mover.start());
    current = const <NetAddressOption>[
      NetAddressOption(name: 'WLAN', address: '192.168.0.20'),
      NetAddressOption(name: '以太网', address: '192.168.0.21'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HostServicePanel(controller: mover),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(); // initState 的 recheck 是纯内存异步，假时钟推得动

    final Finder staleLine = find.byKey(
      const Key('host-service-address-stale'),
    );
    expect(staleLine, findsOneWidget, reason: '这是「手机现在根本连不上」的原因，必须主动说出来');
    final String hint = tester.widget<Text>(staleLine).data!;
    expect(hint, contains('192.168.1.7'), reason: '要说清服务还听在哪个已经不存在的地址');
    expect(hint, contains('192.168.0.20'), reason: '要给出现在该用哪个');
    expect(hint, contains('显示二维码'), reason: '要给「怎么办」');

    // 二维码那一屏同样要红着说 —— 那正是用户扫码的地方
    await tester.tap(find.byKey(const Key('host-service-show-qr')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-qr-address-stale')), findsOneWidget);

    // 换到新地址 ⇒ 提示必须撤掉（否则用户以为没生效）
    final Finder newOption = find.byKey(
      const Key('host-address-option-192.168.0.20'),
    );
    await tester.ensureVisible(newOption);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(newOption);
      await _waitFor(() => mover.snapshot.address == '192.168.0.20');
    });
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('host-service-address-stale')),
      findsNothing,
      reason: '换成新地址之后不该继续红着',
    );

    // 必须在用例体里停（`addTearDown` 跑在「无遗留 Timer」检查之后）
    await tester.runAsync(() => mover.stop());
  });

  testWidgets('换地址失败 ⇒ 如实说失败 + 服务退回原地址（提案 62 第二刀）', (
    WidgetTester tester,
  ) async {
    // 真机上的失败形态：换到的那块网卡已经没了 / 被别的程序占住。
    // 界面绝不能假装成功（用户会对着一个连不上的码猜半天），
    // 也绝不能把服务弄停（那比不让换更糟）。
    final HostServiceController flaky = HostServiceController(
      db: db,
      identities: HostIdentityStore.inMemory(),
      ports: const PortRange(start: 17940, end: 17949),
      detectLocalIp: () async => '10.102.43.94',
      // 第二个地址解析成本机没有的 8.8.8.8 ⇒ `HttpServer.bind` 抛
      // SocketException（真机上等价于「那块网卡不在了」）
      resolveBindAddress: (String ip) => ip == '10.6.22.1'
          ? InternetAddress('8.8.8.8')
          : InternetAddress.loopbackIPv4,
      detectAddresses: () async => const <NetAddressOption>[
        NetAddressOption(name: 'WLAN', address: '10.102.43.94'),
        NetAddressOption(name: 'natpierce', address: '10.6.22.1'),
      ],
    );
    addTearDown(flaky.stop);
    await tester.runAsync(() => flaky.start());

    // `selectAddress` 全程调两次数据监听者（开始时一次、finally 一次）——
    // 用它当「换完了」的信号，比猜 `Duration` 稳
    int notes = 0;
    flaky.addDataListener(() => notes++);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HostServicePanel(controller: flaky),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('host-service-show-qr')));
    await tester.pumpAndSettle();

    final Finder second = find.byKey(
      const Key('host-address-option-10.6.22.1'),
    );
    await tester.ensureVisible(second);
    await tester.pumpAndSettle();
    // ⚠️ 先把计数清零再点：`_showQr` 打开对话框之前会先 `recheckAddress()`
    // （提案 64），它也会广播一次 —— 不清零的话 `notes` 在点之前就到 2 了，
    // `_waitFor` 会立刻返回，断言跑在「换还没做完」的时刻（假红）。
    notes = 0;
    await tester.runAsync(() async {
      await tester.tap(second);
      await _waitFor(() => notes >= 2);
    });
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('host-address-switch-error')),
      findsOneWidget,
      reason: '失败必须说出来 —— 假装成功会把人引向「码看着正常、就是连不上」',
    );
    expect(find.textContaining('没成功'), findsOneWidget);
    expect(
      flaky.snapshot.state,
      HostServiceState.running,
      reason: '换失败要退回原地址把服务拉起来',
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('主机地址：10.102.43.94'),
      ),
      findsOneWidget,
      reason: '地址行要退回能用的那个',
    );

    await tester.runAsync(() => flaky.stop());
  });

  testWidgets('操作抛异常时**不会把界面卡在「忙」状态**（2026-10-31 真机）', (
    WidgetTester tester,
  ) async {
    // 真机现场：点「重新生成配对码」之后，转圈一直转、按钮全变灰、状态还停在
    // 「已开启 / 这台电脑重启过了」。根因是 `_run` 里没有 try —— `action()`
    // 一抛异常（写 host.json 失败 / 端口异常），`_busy` 就永远停在 true。
    final HostServiceController throwing = _ThrowingController(
      db: db,
      identities: HostIdentityStore.inMemory(),
    );
    addTearDown(throwing.stop);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HostServicePanel(controller: throwing),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('host-service-switch')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('host-service-action-error')),
      findsOneWidget,
      reason: '失败必须说出来 —— 转圈 + 灰按钮等于什么都没告诉用户',
    );
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: '转圈必须停 —— 停在 true 就是永久卡死',
    );
    expect(
      tester
          .widget<Switch>(find.byKey(const Key('host-service-switch')))
          .onChanged,
      isNotNull,
      reason: '开关必须还能点，否则用户只能重启软件',
    );
  });

  // ---------------------------------------------------------------- A4（2026-11-01）
  //
  // 提案 58 · A4 乙：手机不再抄 100 个字符的配对码，改成输电脑屏幕上的 6 位数字。
  // 用户裁定的六条约束里，有三条是**这一屏**负责的：显示待配对设备、
  // 由用户主动确认、码 5 分钟一次性。所以这里逐条钉住「摆放」这一层。
  testWidgets('A4：短码对话框显示 6 位码 + 地址，允许后设备行消失', (WidgetTester tester) async {
    // 两个网卡候选：模拟「穿透工具抢了 WLAN」（2026-10-25 与 2026-11-01
    // 两次现场都是这个形状）—— 短码这条路也必须能换地址
    final HostServiceController host = HostServiceController(
      db: db,
      identities: HostIdentityStore.inMemory(),
      ports: const PortRange(start: 17970, end: 17979),
      detectLocalIp: () async => '192.168.1.7',
      // 2026-11-16（提案 62）：服务绑**探测到的地址**，而假 IP 在本机绑不上
      // （cannot assign requested address）⇒ 测试映射到 loopback。
      // 二维码/地址行显示的仍是假 IP（那是 `_address`，不是绑定地址）。
      resolveBindAddress: (String _) => InternetAddress.loopbackIPv4,
      detectAddresses: () async => const <NetAddressOption>[
        NetAddressOption(name: 'WLAN', address: '192.168.1.7'),
        NetAddressOption(name: 'natpierce', address: '10.6.22.1'),
      ],
    );
    addTearDown(host.stop);
    // 绑端口是真实 I/O —— 必须 runAsync，否则假时钟下等不到回调
    await tester.runAsync(() => host.start());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HostServicePanel(controller: host),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('host-service-short-code')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('host-short-code-value')),
      findsOneWidget,
      reason: '这一屏的全部意义就是把这 6 位数字给用户看',
    );
    expect(
      find.byKey(const Key('host-short-code-countdown')),
      findsOneWidget,
      reason: '5 分钟有效期是安全约束，用户得知道还剩多少',
    );
    expect(
      find.byKey(const Key('host-short-code-address')),
      findsOneWidget,
      reason: '手机上还要填地址 —— 不给出来用户就得自己找 IP',
    );
    expect(find.textContaining('还没有手机连过来'), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const Key('host-short-code-address')),
          )
          .data,
      contains('192.168.1.7'),
      reason: '地址要摆出来给用户抄 —— 手机不知道往哪发',
    );

    // 换地址：挑错网卡时唯一的自救手段（这一屏也得有）
    final Finder alt = find.byKey(
      const Key('host-short-code-address-10.6.22.1'),
    );
    await tester.ensureVisible(alt);
    await tester.pumpAndSettle();
    // 同上：真 bind，得喂真实事件循环
    await tester.runAsync(() async {
      await tester.tap(alt);
      await _waitFor(() => host.snapshot.address == '10.6.22.1');
    });
    await tester.pump();
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const Key('host-short-code-address')),
          )
          .data,
      contains('10.6.22.1'),
      reason: '换完地址行要当场变（手机照着抄的就是它）',
    );
    expect(
      find.byKey(const Key('host-short-code-switched')),
      findsOneWidget,
      reason: '换地址会重发配对码 —— 不说明的话用户以为码被人改了',
    );

    // 模拟手机来请求（真机上是 HTTP 打进来的，这里直接打状态机）
    final String code = host.pairRequests.code!;
    expect(code.length, 6);
    final PairPending pending = host.pairRequests
        .request(code: code, deviceName: '安卓手机（Android 14）', ip: '192.168.1.23')
        .request!;
    await tester.pump();

    expect(
      find.textContaining('安卓手机（Android 14）'),
      findsOneWidget,
      reason: '约束 4：必须显示是哪台设备，用户才知道自己在批准谁',
    );
    expect(find.textContaining('192.168.1.23'), findsOneWidget);
    final Finder approve = find.byKey(Key('host-pair-approve-${pending.id}'));
    expect(approve, findsOneWidget);
    // ⚠️ 必须先滚到它：这一屏上方有「6 位码 + 地址 + 换地址列表 + 换完提示」，
    // 600 高的测试视口装不下，按钮落在对话框折叠线以下 ⇒ `tap` 会打空
    //（`warnIfMissed` 只警告不中断，结果就是「点了但没生效」的假红）。
    // 真机用户也是滚一下再点，这里照着做。
    await tester.ensureVisible(approve);
    await tester.pumpAndSettle();

    await tester.tap(approve);
    await tester.pump();

    expect(
      find.byKey(Key('host-pair-device-${pending.id}')),
      findsNothing,
      reason: '批准过的行要撤掉 —— 留着会让人以为还能再批一次',
    );
    expect(host.pairRequests.statusOf(pending.id), PairRequestStatus.approved);

    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    // ⚠️ 必须在用例体里停服务（tearDown 跑在「无遗留 Timer」检查之后）
    await tester.runAsync(() => host.stop());
  });

  testWidgets('A4：有人等着确认时，面板上就看得见（不用打开对话框）', (WidgetTester tester) async {
    final HostServiceController host = HostServiceController(
      db: db,
      identities: HostIdentityStore.inMemory(),
      ports: const PortRange(start: 17970, end: 17979),
      detectLocalIp: () async => '192.168.1.7',
      // 2026-11-16（提案 62）：服务绑**探测到的地址**，而假 IP 在本机绑不上
      // （cannot assign requested address）⇒ 测试映射到 loopback。
      // 二维码/地址行显示的仍是假 IP（那是 `_address`，不是绑定地址）。
      resolveBindAddress: (String _) => InternetAddress.loopbackIPv4,
    );
    addTearDown(host.stop);
    await tester.runAsync(() => host.start());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HostServicePanel(controller: host),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('台手机在请求配对'), findsNothing);

    host.pairRequests.request(
      code: host.pairRequests.issueCode(),
      deviceName: '安卓手机',
      ip: '192.168.1.23',
    );
    await tester.pump();

    expect(
      find.textContaining('台手机在请求配对'),
      findsOneWidget,
      reason: '对话框收起来之后，用户也得知道有人在等 —— 否则手机那边一直转圈',
    );

    await tester.runAsync(() => host.stop());
  });
}
