// 移动端壳（`MobileShell`）的 widget 测试 —— §BH B1a。
//
// 页面装配与桌面壳**共用 `appShellPage`**（app_shell.dart），所以这里只钉
// 摆放层的三件事：5 个 tab 的文字标签、开单 tab 的三个入口、我的 tab 的
// 设置 / 帮助。服务全部不注入（走 `_PendingPage` 兜底）—— 摆放层不依赖库。
//
// 运行：`flutter test`（本机由用户执行）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/app_shell.dart';
import 'package:shensuanzi/src/ui/mobile_shell.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

void main() {
  late Directory box;
  late AppConfigStore store;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_mobile_shell_');
    store = AppConfigStore(File(p.join(box.path, 'config.json')));
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  Widget page() => MaterialApp(
    home: MobileShell(
      // 服务全部缺省 ⇒ 各 tab 走 `_PendingPage` 兜底 —— 摆放层零依赖
      shell: AppShell(
        dataDirectory: '/tmp/data',
        backupDirectory: '/tmp/backup',
        schemaVersion: 3,
        databaseReady: false,
        configStore: store,
        onConfigChanged: (AppConfig config) {},
        // 门控按能力走（§CV·七 ① 乙）；sink 缺省 = 相关 tab 照旧 `_PendingPage`
        masterDataPolicy: const MasterDataPolicy.desktop(),
      ),
    ),
  );

  testWidgets('底部导航：5 个入口的文字标签齐（§AH-5，不许增减改名）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());

    for (final String label in <String>['概览', '开单', '库存', '往来', '我的']) {
      expect(find.text(label), findsWidgets, reason: 'tab 标签 $label 必须在');
    }
  });

  testWidgets('开单 tab：三个入口（销售 / 采购 / 送货），点销售推整屏', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());

    await tester.tap(find.text('开单'));
    await tester.pumpAndSettle();

    // 三个入口的 label 取自 AppNavigation（与桌面导航同源，不会漂移）
    expect(find.text('销售开单'), findsOneWidget);
    expect(find.text('采购入库'), findsOneWidget);
    expect(find.text('送货'), findsOneWidget);

    // 点「销售开单」→ 推整屏：AppBar 标题在（列表项被盖在下面），
    // 服务缺省 ⇒ 页面内容是 _PendingPage 占位 —— 摆放层只验「推进去了、能返回」
    await tester.tap(find.text('销售开单'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('销售开单'),
      ),
      findsOneWidget,
      reason: '整屏 AppBar 标题 = 入口名',
    );
    expect(find.byType(BackButton), findsOneWidget, reason: '整屏要能返回');
  });

  testWidgets('我的 tab：设置 / 帮助 / 版本三行都在', (WidgetTester tester) async {
    await tester.pumpWidget(page());

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('帮助'), findsOneWidget);
    expect(find.text('版本与反馈'), findsOneWidget);
    expect(find.textContaining(AppVersion.display), findsOneWidget);
  });
  // ============================================ 三态条（B3b·§CA 裁定 ④）

  testWidgets('三态条：未注入 sync ⇒ 不显示（摆放层零依赖）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    expect(find.text('已同步'), findsNothing);
  });

  /// 三态条夹具：指向临时目录的同步服务。
  ///
  /// [pairing] 传 `null` = **没配对过**（`pairing.json` 不存在）；
  /// 传值 = 已配对（再带 `lastSyncAt` 才算「同步成功过」）。
  MobileSyncService syncServiceIn(Directory box, {PairingInfo? pairing}) {
    final PairingStore pairingStore = PairingStore(
      File(p.join(box.path, 'pairing.json')),
    );
    if (pairing != null) pairingStore.save(pairing);
    return MobileSyncService(
      mirrorPath: p.join(box.path, 'mirror', 'shensuanzi_mirror.db'),
      pairingStore: pairingStore,
    );
  }

  Widget shellWith(MobileSyncService sync) => MaterialApp(
    home: MobileShell(
      shell: AppShell(
        dataDirectory: '/tmp/data',
        backupDirectory: '/tmp/backup',
        schemaVersion: 3,
        databaseReady: false,
        configStore: store,
        onConfigChanged: (AppConfig config) {},
        masterDataPolicy: const MasterDataPolicy.desktop(),
        mobileSync: sync,
      ),
    ),
  );

  testWidgets('三态条：**没配对** + 空队列 ⇒ 「尚未连接电脑」（M04：空队列 ≠ 已同步）', (
    WidgetTester tester,
  ) async {
    final Directory syncBox = Directory.systemTemp.createTempSync(
      'shensuanzi_syncbar_',
    );
    addTearDown(() {
      try {
        syncBox.deleteSync(recursive: true);
      } catch (_) {
        // 镜像库可能还开着 —— 删不掉不影响结论（同既有测试的兜底）
      }
    });

    await tester.pumpWidget(shellWith(syncServiceIn(syncBox)));
    await tester.pumpAndSettle();

    // M04（2026-10-08，`docs/reply.md` §二·1）：**空队列不再等于「已同步」** ——
    // 没配对过就是什么都没连上，显示「已同步」会让用户以为单已经传给电脑了
    expect(find.text('尚未连接电脑'), findsOneWidget);
    expect(find.text('已同步'), findsNothing);

    // tab 之间常驻（切到「我的」再回来看，它还在）
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('概览'));
    await tester.pumpAndSettle();
    expect(find.text('尚未连接电脑'), findsOneWidget);
  });

  testWidgets('三态条：已配对 + 同步过 + 空队列 ⇒ 「已同步」', (WidgetTester tester) async {
    final Directory syncBox = Directory.systemTemp.createTempSync(
      'shensuanzi_syncbar2_',
    );
    addTearDown(() {
      try {
        syncBox.deleteSync(recursive: true);
      } catch (_) {
        // 同上：库还开着时删不掉，不影响结论
      }
    });

    await tester.pumpWidget(
      shellWith(
        syncServiceIn(
          syncBox,
          pairing: PairingInfo.fromPayload(
            hostId: 'h1',
            ip: '127.0.0.1',
            port: 17890,
            token: 't',
          ).withLastSyncAt(1700000000000),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 过了前两关，队列的空才有话语权（这就是原来那条断言的正确位置）
    expect(find.text('已同步'), findsOneWidget);
    expect(find.text('尚未连接电脑'), findsNothing);
  });
}

