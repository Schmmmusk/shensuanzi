// 设置页（`SettingsPage`）的 widget 测试。
//
// 覆盖：缩放五档改档即回调 + 落盘（SC-1）/ 重置按钮（遗漏 2）/
// 店名 20 字符上限（SC-2）/ 数据安全区的打开按钮存在（遗漏 1）/
// 备份区（§AE-5 状态行 + 遗漏 5 SnackBar 带路径 + 遗漏 6 说明文案 +
// 遗漏 11 按钮防抖）。
// ⚠️ 「打开文件夹」点下去会真起 explorer —— 测试只断言按钮存在，不点它。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/settings_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Directory box;
  late AppConfigStore store;
  AppConfig current = const AppConfig();

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_settings_page_');
    store = AppConfigStore(File(p.join(box.path, 'config.json')));
    current = store.load();
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  Widget page(
    void Function(AppConfig) onChanged, {
    String? backupDirectory,
    String? backupStatusLine,
    bool backupNeedsAttention = false,
    Future<BackupOutcome> Function()? onBackupNow,
    HostServiceController? hostService,
  }) => MaterialApp(
    home: Scaffold(
      body: SettingsPage(
        config: current,
        configStore: store,
        backupDirectory: backupDirectory,
        backupStatusLine: backupStatusLine,
        backupNeedsAttention: backupNeedsAttention,
        onBackupNow: onBackupNow,
        hostService: hostService,
        onChanged: (AppConfig config) {
          current = config;
          onChanged(config);
        },
      ),
    ),
  );

  testWidgets('改缩放档位 → 回调新配置 + 落盘（SC-1）', (WidgetTester tester) async {
    AppConfig? received;
    await tester.pumpWidget(page((AppConfig config) => received = config));

    await tester.tap(find.byKey(const Key('setting-scale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('特大').last);
    await tester.pumpAndSettle();

    expect(received?.uiScale, UiScale.huge, reason: '改完立即回调（热应用）');
    expect(store.load().uiScale, UiScale.huge, reason: '并已落盘');
  });

  testWidgets('「恢复默认大小」一键重置（遗漏 2）', (WidgetTester tester) async {
    // 先调到超大
    store.save(
      AppConfig(uiScale: UiScale.giant, shopName: null),
    );
    current = store.load();
    AppConfig? received;
    await tester.pumpWidget(page((AppConfig config) => received = config));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('setting-reset-scale')));
    await tester.pumpAndSettle();

    expect(received?.uiScale, UiScale.standard);
    expect(store.load().uiScale, UiScale.standard);
  });

  testWidgets('店名超 20 字 → 提示且不落盘（SC-2）', (WidgetTester tester) async {
    AppConfig? received;
    await tester.pumpWidget(page((AppConfig config) => received = config));

    await tester.enterText(
      find.byKey(const Key('setting-shop-name')),
      '长' * 21,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('最长 20 个字'), findsOneWidget);
    expect(received, isNull, reason: '超长不回调（不保存）');
  });

  testWidgets('店名合法 → 保存；数据安全区显示两个「打开」按钮', (WidgetTester tester) async {
    // 数据安全区只在配置了数据目录时渲染 —— 默认配置（null）下两行都不出现
    store.save(const AppConfig(dataDirectory: r'D:\shensuanzi_data'));
    current = store.load();
    AppConfig? received;
    await tester.pumpWidget(
      page((AppConfig config) => received = config,
          backupDirectory: r'D:\神算子备份'),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('setting-shop-name')), '王记小卖部');
    await tester.pumpAndSettle();

    expect(received?.shopName, '王记小卖部');
    expect(store.load().shopName, '王记小卖部');

    // 遗漏 1：数据安全区 —— 数据位置 + 备份位置两行，各带「打开」按钮
    // （不点：点了会真起 explorer）
    expect(find.text('数据'), findsOneWidget);
    expect(find.text('数据位置'), findsOneWidget);
    expect(find.text('备份位置'), findsOneWidget);
    expect(find.byIcon(Icons.folder_open), findsNWidgets(2));
  });

  // ---------------------------------------------------------------- 备份区

  testWidgets('备份区：状态行 + 说明文案 + 「立即备份」→ SnackBar 带完整路径', (
    WidgetTester tester,
  ) async {
    store.save(const AppConfig(dataDirectory: r'D:\shensuanzi_data'));
    current = store.load();
    const String path = r'D:\神算子备份\shensuanzi-m-schema1-20260928-1530.db';
    await tester.pumpWidget(
      page(
        (AppConfig config) {},
        backupDirectory: r'D:\神算子备份',
        backupStatusLine: '上次备份：从未',
        onBackupNow: () async => const BackupOutcome.ok(path),
      ),
    );
    await tester.pumpAndSettle();

    // AE-5：状态行
    expect(find.text('上次备份：从未'), findsOneWidget);
    // 遗漏 6：两行说明（含 §AE-1 的技术承诺）
    expect(find.textContaining('每天首次打开软件会自动备份一次'), findsOneWidget);
    expect(find.textContaining('任何 SQLite 工具打开'), findsOneWidget);

    await tester.tap(find.byKey(const Key('setting-backup-now')));
    await tester.pumpAndSettle();

    // 遗漏 5：SnackBar 带完整路径
    expect(find.textContaining(path), findsOneWidget);
  });

  testWidgets('超 3 天没备份 → 状态行红字（AE-5）', (WidgetTester tester) async {
    store.save(const AppConfig(dataDirectory: r'D:\shensuanzi_data'));
    current = store.load();
    await tester.pumpWidget(
      page(
        (AppConfig config) {},
        backupDirectory: r'D:\神算子备份',
        backupStatusLine: '上次备份：9月24日 12:00（自动）',
        backupNeedsAttention: true,
      ),
    );

    final Color expected = Theme.of(
      tester.element(find.byType(SettingsPage)),
    ).colorScheme.error;
    final Text line = tester.widget<Text>(
      find.text('上次备份：9月24日 12:00（自动）'),
    );
    expect(line.style?.color, expected, reason: '数据安全要看得见');

    await tester.pumpWidget(
      page(
        (AppConfig config) {},
        backupDirectory: r'D:\神算子备份',
        backupStatusLine: '上次备份：今天 09:05（自动）',
      ),
    );
    final Text calm = tester.widget<Text>(find.text('上次备份：今天 09:05（自动）'));
    expect(calm.style?.color, isNull, reason: '正常情况不刷红');
  });

  testWidgets('备份不可用（库没就绪）→ 状态与按钮都不摆，说明文案仍在', (
    WidgetTester tester,
  ) async {
    store.save(const AppConfig(dataDirectory: r'D:\shensuanzi_data'));
    current = store.load();
    await tester.pumpWidget(
      page((AppConfig config) {}, backupDirectory: r'D:\神算子备份'),
    );

    expect(find.byKey(const Key('setting-backup-now')), findsNothing);
    expect(find.textContaining('上次备份'), findsNothing);
    expect(find.textContaining('每天首次打开软件会自动备份一次'), findsOneWidget);
  });

  testWidgets('点「立即备份」立刻禁用 +「备份中…」（遗漏 11 防连点）', (
    WidgetTester tester,
  ) async {
    store.save(const AppConfig(dataDirectory: r'D:\shensuanzi_data'));
    current = store.load();
    final Completer<BackupOutcome> gate = Completer<BackupOutcome>();
    var calls = 0;
    await tester.pumpWidget(
      page(
        (AppConfig config) {},
        backupDirectory: r'D:\神算子备份',
        backupStatusLine: '上次备份：从未',
        onBackupNow: () {
          calls++;
          return gate.future;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('setting-backup-now')));
    await tester.pump();

    expect(find.text('备份中…'), findsOneWidget);
    expect(find.text('立即备份'), findsNothing);
    await tester.tap(find.byKey(const Key('setting-backup-now')));
    await tester.pump();
    expect(calls, 1, reason: '进行中的重复点击必须被页面拦住');

    gate.complete(const BackupOutcome.ok(r'D:\神算子备份\a.db'));
    await tester.pump();
    await tester.pump();
    expect(find.text('立即备份'), findsOneWidget);
  });

  // ---- 多设备同步（§AH · AH-A；原 §AG-6「开发中」占位已换成实装）----

  testWidgets('库没就绪时不装作能用：整段显示「暂时用不了」', (WidgetTester tester) async {
    await tester.pumpWidget(
      page((AppConfig _) {}, hostService: null),
    );

    expect(find.text('多设备同步'), findsOneWidget);
    expect(find.textContaining('数据目录还没准备好'), findsOneWidget);
    // 不给假入口
    expect(find.byKey(const Key('host-service-switch')), findsNothing);
  });

  testWidgets('库就绪时出现真正的开关，且默认关（§AH 遗漏 5）', (
    WidgetTester tester,
  ) async {
    final Db db = Db.openInMemory();
    final HostServiceController hostService = HostServiceController(
      db: db,
      identities: HostIdentityStore.inMemory(),
      ports: const PortRange(start: 17970, end: 17979),
      detectLocalIp: () async => '192.168.1.7',
    );
    addTearDown(() async {
      await hostService.stop();
      db.close();
    });

    await tester.pumpWidget(
      page((AppConfig _) {}, hostService: hostService),
    );

    expect(find.text('多设备同步'), findsOneWidget);
    expect(
      tester
          .widget<Switch>(find.byKey(const Key('host-service-switch')))
          .value,
      isFalse,
    );
    expect(find.text('已关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
