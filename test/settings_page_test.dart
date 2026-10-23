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
    VoidCallback? onChangeBackupLocation,
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
        onChangeBackupLocation: onChangeBackupLocation,
        onChanged: (AppConfig config) {
          current = config;
          onChanged(config);
        },
      ),
    ),
  );

  // 2026-10-21（§CV·八十 P0-1）：**迁移数据位置后，本页的配置快照必须回灌**。
  // 原来 `late AppConfig _current = widget.config` 只在 State 首次创建时求值，
  // 没有 `didUpdateWidget` ⇒ 迁移后改任何设置都会把 `data_directory` 写回旧路径，
  // 用户下次启动打开旧目录，以为「单据丢了」。
  // 2026-10-22（用户实测两轮）：
  // 第一轮「回滚 + 告知」⇒ 用户看到「恢复按钮又变灰、界面还是没变」——
  // 对一台写不进配置的机器，回滚等于「这个设置永久废了」。
  // 现在：**改动照样生效**（通知宿主重建），只把「重启会变回去」说清楚。
  testWidgets('保存失败 ⇒ 改动照样生效，并明说不会持久化', (WidgetTester tester) async {
    // 把 config.json 占成**目录** ⇒ save 必抛（主位置与备用位置都指这里）
    final Directory blocker = Directory(store.file.path);
    blocker.createSync(recursive: true);
    addTearDown(() {
      try {
        blocker.deleteSync(recursive: true);
      } catch (_) {}
    });

    AppConfig? received;
    await tester.pumpWidget(page((AppConfig config) => received = config));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('setting-scale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('特大').last);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('没能存到磁盘'),
      findsOneWidget,
      reason: '必须说清楚没存上',
    );
    expect(find.textContaining('重启软件后会变回'), findsOneWidget);
    expect(
      received?.uiScale,
      UiScale.huge,
      reason: '虽然没存上，本次改动仍要生效（否则设置永远用不了）',
    );
  });

  // 同一批：备份位置要能改（用户实测：备份目录不可写时没有出路 = 死局）
  testWidgets('备份位置行有「更改」（装配了 onChange 时）', (WidgetTester tester) async {
    // 路径两行要 dataDirectory 非空才渲染
    current = const AppConfig(dataDirectory: r'D://神算子数据');
    await tester.pumpWidget(
      page(
        (AppConfig config) {},
        backupDirectory: r'D://神算子备份',
        onChangeBackupLocation: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('备份位置'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, '更改'),
      findsWidgets,
      reason: '数据位置与备份位置都要能改',
    );
  });

  testWidgets('P0-1：宿主换了配置（如迁移后）⇒ 改缩放不能把旧路径写回去', (
    WidgetTester tester,
  ) async {
    current = const AppConfig(dataDirectory: r'D://旧位置');
    AppConfig? received;
    await tester.pumpWidget(page((AppConfig config) => received = config));

    // 宿主（app.dart）迁移完成后推送新配置
    current = const AppConfig(dataDirectory: r'D://新位置');
    await tester.pumpWidget(page((AppConfig config) => received = config));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('setting-scale')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('特大').last);
    await tester.pumpAndSettle();

    expect(
      received?.dataDirectory,
      r'D://新位置',
      reason: '迁移后改设置必须保留**新**路径（旧快照会把它写回旧目录）',
    );
    expect(received?.uiScale, UiScale.huge);
  });

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
    store.save(AppConfig(uiScale: UiScale.giant, shopName: null));
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
      page(
        (AppConfig config) => received = config,
        backupDirectory: r'D:\神算子备份',
      ),
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

    // 诊断行让页面变高 ⇒ 按钮可能落到视口外，先滚到它再点
    await tester.ensureVisible(find.byKey(const Key('setting-backup-now')));
    await tester.pumpAndSettle();
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
    final Text line = tester.widget<Text>(find.text('上次备份：9月24日 12:00（自动）'));
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

  testWidgets('备份不可用（库没就绪）→ 状态与按钮都不摆，说明文案仍在', (WidgetTester tester) async {
    store.save(const AppConfig(dataDirectory: r'D:\shensuanzi_data'));
    current = store.load();
    await tester.pumpWidget(
      page((AppConfig config) {}, backupDirectory: r'D:\神算子备份'),
    );

    expect(find.byKey(const Key('setting-backup-now')), findsNothing);
    expect(find.textContaining('上次备份'), findsNothing);
    expect(find.textContaining('每天首次打开软件会自动备份一次'), findsOneWidget);
  });

  testWidgets('点「立即备份」立刻禁用 +「备份中…」（遗漏 11 防连点）', (WidgetTester tester) async {
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

    await tester.ensureVisible(find.byKey(const Key('setting-backup-now')));
    await tester.pumpAndSettle();
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
    await tester.pumpWidget(page((AppConfig _) {}, hostService: null));

    expect(find.text('多设备同步'), findsOneWidget);
    expect(find.textContaining('数据目录还没准备好'), findsOneWidget);
    // 不给假入口
    expect(find.byKey(const Key('host-service-switch')), findsNothing);
  });

  testWidgets('库就绪时出现真正的开关，且默认关（§AH 遗漏 5）', (WidgetTester tester) async {
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

    await tester.pumpWidget(page((AppConfig _) {}, hostService: hostService));

    expect(find.text('多设备同步'), findsOneWidget);
    expect(
      tester.widget<Switch>(find.byKey(const Key('host-service-switch'))).value,
      isFalse,
    );
    expect(find.text('已关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
