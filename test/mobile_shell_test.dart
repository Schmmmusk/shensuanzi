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
}
