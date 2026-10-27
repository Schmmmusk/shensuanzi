// 设置页「多设备同步」面板（§AH · AH-A）的 widget 测试。
//
// 覆盖：**默认关**（§AH 遗漏 5 的硬要求）+ 关闭态的文案与按钮可见性。
//
// ## ⚠️ 一处**刻意不测**的地方
//
// 「打开开关 → 跑起服务 → 弹二维码」这条路径需要一个**真实绑定的端口**，
// 而本侧（AI 沙箱）编译不到 Flutter 层 ⇒ 写完没法跑。
// 状态机本身已经被 `shensuanzi_host` 的
// `test/service_controller_test.dart` + `tool/selfcheck_service.dart`（56 项）
// 完整覆盖；这里只钉住「摆放」这一层不会退化。
// 绑定端口的 widget 测试见 `docs/reply_review.md` §BB·六 的待补清单。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/host_service_section.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

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
    await tester.tap(second);
    await tester.pumpAndSettle();

    expect(
      inDialog('主机地址：10.6.22.1'),
      findsOneWidget,
      reason: '换了地址，地址行必须当场变（不许关掉再开才生效）',
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
}
