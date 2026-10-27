// 设置页 · 多设备同步面板的两处 F14 出口（2026-10-25 用户裁定）：
// ① 「历史主机数据（N 份）」—— 换主机时自动归档的可见出口；
// ② 「重建本机数据副本」—— 镜像坏了 / 数字不对时的兜底（错误文案早就承诺过，
//    之前界面上没有这个按钮）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/settings_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

void main() {
  late Directory box;
  late MobileSyncService service;
  late AppConfigStore configStore;

  setUp(() {
    box = Directory.systemTemp.createTempSync('sz_settings_sync_');
    service = MobileSyncService(
      mirrorPath: p.join(box.path, 'mirror', 'shensuanzi_mirror.db'),
      pairingStore: PairingStore(File(p.join(box.path, 'pairing.json'))),
    );
    configStore = AppConfigStore(File(p.join(box.path, 'config.json')));
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  Widget page() => MaterialApp(
    home: Scaffold(
      body: SettingsPage(
        config: const AppConfig(),
        configStore: configStore,
        mobileSync: service,
        onChanged: (AppConfig _) {},
      ),
    ),
  );

  /// 镜像里塞一个商品（模拟从主机拉下来过）
  void seedMirrorProduct() {
    final Db mirror = service.openMirror();
    mirror.raw.execute(
      'INSERT INTO products (id, code, name, unit, cost_price, sell_price, '
      'safety_stock, is_active, created_at, updated_at, sync_version) '
      "VALUES ('p1','P0001','旧货','瓶',100,200,0,1,1,1,0)",
    );
  }

  /// 设置页很长，按钮在折叠线以下 ⇒ 先滚到可见再点（真机同理）
  Future<void> tapKey(WidgetTester tester, String key) async {
    final Finder finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  int productRows() =>
      service
              .openMirror()
              .raw
              .select('SELECT COUNT(*) AS n FROM products')
              .first['n']!
          as int;

  testWidgets('没连主机、也没有归档 ⇒ 只有一行灰字，不给死按钮', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('历史主机数据：暂无'), findsOneWidget);
    expect(find.byKey(const Key('mobile-sync-archives')), findsNothing);
    expect(
      find.byKey(const Key('mobile-sync-rebuild')),
      findsNothing,
      reason: '没配对时重建没有意义（没有主机可拉）',
    );
  });

  testWidgets('换过主机 ⇒ 显示「历史主机数据（1 份）」并能点开看', (WidgetTester tester) async {
    // 先配 h-1 并留一个商品 + 一份归档，再换到 h-2
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=17890&token=t1&v=1',
    );
    seedMirrorProduct();
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-2&ip=127.0.0.1&port=17890&token=t2&v=1',
    );
    expect(service.archives(), hasLength(1), reason: '换主机必须归档');

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('历史主机数据（1 份）'), findsOneWidget);
    await tapKey(tester, 'mobile-sync-archives');

    expect(find.text('历史主机数据'), findsWidgets);
    expect(find.text('主机 h-1'), findsOneWidget, reason: '归档里要能看出是哪台主机');
  });

  testWidgets('点「重建本机数据副本」⇒ 先确认，确认后镜像被重建', (WidgetTester tester) async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=17890&token=t1&v=1',
    );
    seedMirrorProduct();
    expect(productRows(), 1);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tapKey(tester, 'mobile-sync-rebuild');
    expect(find.text('重建本机数据副本？'), findsOneWidget);

    // 先点「取消」⇒ 什么都不该发生
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(productRows(), 1, reason: '取消不许动数据');

    await tapKey(tester, 'mobile-sync-rebuild');
    await tester.tap(find.text('重建'));
    await tester.pumpAndSettle();

    expect(productRows(), 0, reason: '重建 = 清镜像，等下次同步全量重拉');
    expect(service.archives(), hasLength(1), reason: '重建前必须先归档（用户的数据不能凭空消失）');
  });

  // ------------------------------------------------------------ D 批（2026-10-27）
  //
  // 真机验收时发现的**设计漏洞**：`pairFromAddress`（只换地址）只有**未配对**时
  // 能进（扫码页），而它要救的场景恰恰是「扫码成功、但电脑挑错了网卡 ⇒ 连不上」——
  // 那时手机是**已配对**状态，设置页只有「立即同步 / 忘记主机」，
  // **根本进不去扫码页**。所以已配对态也必须给一个入口。
  testWidgets('D 批：已配对时有「手动换地址」，且只换地址不动身份', (WidgetTester tester) async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=10.6.22.1&port=17890&token=tok&v=1',
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(
      find.textContaining('已连接主机（10.6.22.1:17890）'),
      findsOneWidget,
      reason: '前提：这就是现场 —— 配对着，但地址是穿透网卡的',
    );

    await tapKey(tester, 'mobile-manual-address');
    expect(find.text('手动填地址'), findsOneWidget, reason: '点开的是同一个对话框');

    await tester.enterText(
      find.byKey(const Key('manual-address-field')),
      '10.102.43.94:17890',
    );
    await tester.tap(find.byKey(const Key('manual-address-ok')));
    await tester.pumpAndSettle();

    expect(find.text('手动填地址'), findsNothing, reason: '换好了就关掉');
    expect(
      find.textContaining('已连接主机（10.102.43.94:17890）'),
      findsOneWidget,
      reason: '面板那一行要跟着变 —— 否则用户以为没生效',
    );
    final PairingInfo saved = service.pairingStore.load()!;
    expect(saved.hostId, 'h-1');
    expect(saved.token, 'tok', reason: '只换地址，令牌不能动（否则要重新扫码）');
  });

  testWidgets('D 批护栏：未配对时给的是「扫码」，不是「手动换地址」', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('mobile-manual-address')),
      findsNothing,
      reason: '没配对过就没有令牌可沿用 —— 那时该走扫码 / 粘配对码',
    );
  });
}
