// 启动流程（`ShensuanziApp`）的 widget 测试。
//
// ## 为什么这份测试之前写不了、现在能写了
//
// 启动流程有**两个系统交互**：选文件夹（`pickDirectory`）与读写配置
// （`configStore`）。前者会真弹系统框（测试挂死），后者默认落在真实
// `%APPDATA%`（测试会读、甚至**改写**开发者的真实配置）。
// 2026-09-26 裁定：只注入这两个（`docs/reply_review.md` §W），其余走真实路径 ——
// 所以 [ShensuanziApp] 的 `pickDirectory` 传桩、`configStore` 指到沙箱。
//
// ⚠️ 环境（盘符 / 剩余空间）**保持真实**（`AppEnvironment.detect()`）：
// 我们要测的是「真实机器 + 沙箱配置」下的启动行为，不是「假机器上的假配置」。
// 因此场景 2 的「配置过且可用」需要一个**真实存在**的目录 + 有效标记。
//
// 运行：`flutter test`（本机由用户执行）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/app.dart';
import 'package:shensuanzi/src/ui/app_shell.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  // ⚠️ `flutter test` 不打包 `sqlite3.dll`（那是 `sqlite3_flutter_libs` 给应用
  // 目录用的），不显式覆盖加载就会一律开库失败。在 Windows 上这会兜到
  // `C:\Windows\System32\winsqlite3.dll`。见 `sqlite_local.dart` 顶部注释。
  useLocalSqlite();

  // 一个用完即弃的沙箱；tearDown 里删掉，绝不碰真实 %APPDATA%
  late Directory box;
  late AppConfigStore store;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_app_startup_');
    store = AppConfigStore(File(p.join(box.path, 'config.json')));
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉（占用等）不影响结论
    }
  });

  Widget app({
    Future<String?> Function()? pickDirectory,
    AppConfigStore? configStore,
  }) => ShensuanziApp(
    pickDirectory: pickDirectory ?? () async => null,
    configStore: configStore ?? store,
  );

  // ---------------------------------------------------------------- 查找器
  //
  // ⚠️ **不能直接 `find.text('选择数据存放位置')`**：启动兜底页（`_StartupPage`）
  // 的按钮文字**也叫这个**，而对话框开着时底下的兜底页还在 —— 于是恰好找到
  // 2 个（一个标题 + 一个按钮）。2026-09-26 首轮就这么翻的车，
  // 所以「对话框标题」必须限定在 `AlertDialog` 里面找。
  //
  // ⚠️ 用局部 `final` 变量，**不能用 getter**：getter 只能写在类 / 库顶层，
  // 写在 `main()` 里是语法错误（二轮翻车：`Expected ';' after this`，
  // 整个测试文件编译不过，6 条 widget_test 连带显示 "Some tests failed"）。
  final Finder dialog = find.byType(AlertDialog);
  final Finder dialogTitle = find.descendant(
    of: dialog,
    matching: find.text('选择数据存放位置'),
  );

  testWidgets('场景 1：没有配置过 → 弹出「选择数据存放位置」对话框', (WidgetTester tester) async {
    var picked = 0;
    await tester.pumpWidget(
      app(pickDirectory: () async {
        picked++;
        return null;
      }),
    );
    await tester.pumpAndSettle();

    expect(dialog, findsOneWidget);
    expect(dialogTitle, findsOneWidget);
    expect(picked, 0, reason: '还没点「更改」，不该调选择器');
  });

  testWidgets('场景 2：配置过且目录可用 → 不弹对话框，直接进主界面', (WidgetTester tester) async {
    // 造一个真实存在的目录 + 有效标记，写进沙箱配置
    final String dataDir = p.join(box.path, 'data');
    Directory(dataDir).createSync(recursive: true);
    DataMarker.write(dataDir, schemaVersion: 1, now: 1700000000000);
    store.save(AppConfig(dataDirectory: dataDir));

    var picked = 0;
    await tester.pumpWidget(
      app(pickDirectory: () async {
        picked++;
        return null;
      }),
    );
    await tester.pumpAndSettle();

    expect(dialog, findsNothing);
    expect(find.byType(AppShell), findsOneWidget);
    expect(picked, 0);
  });

  testWidgets('场景 3：选了目录 → 对话框消失，进入主界面', (WidgetTester tester) async {
    final String dataDir = p.join(box.path, 'data');
    await tester.pumpWidget(app(pickDirectory: () async => dataDir));
    await tester.pumpAndSettle();

    expect(dialog, findsOneWidget);

    // ⚠️ 必须先点「更改」把路径换成沙箱目录：直接点「开始使用」会落到
    // 真实默认路径（`D:\神算子数据`），污染开发者磁盘。
    await tester.tap(find.text('更改'));
    await tester.pumpAndSettle();

    // 现在路径已是沙箱目录，点「开始使用」→ 建档 → 主界面
    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();

    expect(dialog, findsNothing);
    expect(find.byType(AppShell), findsOneWidget);
  });

  testWidgets('场景 4：取消（选择器返回 null）→ 对话框仍在，不崩', (WidgetTester tester) async {
    await tester.pumpWidget(app(pickDirectory: () async => null));
    await tester.pumpAndSettle();

    expect(dialog, findsOneWidget);

    // 点「更改」触发选择器 → 返回 null → 对话框还在
    await tester.tap(find.text('更改'));
    await tester.pumpAndSettle();

    expect(dialog, findsOneWidget);
    expect(tester.takeException(), isNull, reason: '取消不该抛异常');
  });

  testWidgets('场景 5：库打不开 → 错误页（不是主界面）', (WidgetTester tester) async {
    // 造一个「标记有效、但数据库文件是坏的」目录，再选它
    final String dataDir = p.join(box.path, 'data');
    Directory(dataDir).createSync(recursive: true);
    DataMarker.write(dataDir, schemaVersion: 1, now: 1700000000000);
    // 把数据库文件写成一个非法 SQLite 文件（非空、但不是有效库）
    File(p.join(dataDir, AppBootstrap.databaseFileName)).writeAsStringSync(
      '这不是一个有效的 SQLite 数据库',
    );

    await tester.pumpWidget(app(pickDirectory: () async => dataDir));
    await tester.pumpAndSettle();

    expect(dialog, findsOneWidget);

    // 先「更改」到沙箱目录，再「开始使用」
    await tester.tap(find.text('更改'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();

    expect(dialog, findsNothing);
    expect(find.textContaining('数据文件打不开'), findsOneWidget);
  });
}
