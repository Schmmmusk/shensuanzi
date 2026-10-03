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
      body: SingleChildScrollView(child: HostServicePanel(controller: controller)),
    ),
  );

  testWidgets('默认是关的，且说清「打开意味着什么」（§AH 遗漏 5）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(panel());

    expect(find.text('已关闭'), findsOneWidget);
    expect(
      tester
          .widget<Switch>(find.byKey(const Key('host-service-switch')))
          .value,
      isFalse,
      reason: '监听端口必须是显式用户动作，不是开机默认行为',
    );
    expect(find.text(HostServiceSnapshot.switchHint), findsOneWidget);
  });

  testWidgets('没开的时候不出现二维码 / 重试按钮（不给假入口）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(panel());

    expect(find.byKey(const Key('host-service-show-qr')), findsNothing);
    expect(find.byKey(const Key('host-service-reset')), findsNothing);
    expect(find.byKey(const Key('host-service-retry')), findsNothing);
  });

  testWidgets('渲染不抛异常（含单行提示的容器约束）', (WidgetTester tester) async {
    await tester.pumpWidget(panel());
    expect(tester.takeException(), isNull);
  });
}
