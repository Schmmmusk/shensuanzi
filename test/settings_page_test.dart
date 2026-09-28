// 设置页（`SettingsPage`）的 widget 测试。
//
// 覆盖：缩放五档改档即回调 + 落盘（SC-1）/ 重置按钮（遗漏 2）/
// 店名 20 字符上限（SC-2）/ 数据安全区的打开按钮存在（遗漏 1）。
// ⚠️ 「打开文件夹」点下去会真起 explorer —— 测试只断言按钮存在，不点它。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/settings_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';

void main() {
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

  Widget page(void Function(AppConfig) onChanged, {String? backupDirectory}) =>
      MaterialApp(
    home: Scaffold(
      body: SettingsPage(
        config: current,
        configStore: store,
        backupDirectory: backupDirectory,
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
}
