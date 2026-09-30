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
// 场景 6/7/8 是 §AE 备份接线：**空库不备份**（遗漏 1）、**自动备份失败要
// 静默但在概览页可见**（AE-3 两层机制）、**正常链路启动即出一份**（AE-3）。
//
// 运行：`flutter test`（本机由用户执行）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/app.dart';
import 'package:shensuanzi/src/ui/app_shell.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
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

  // ---------------------------------------------------------------- §AE 备份接线
  //
  // ⚠️ 断言的是**接线**（启动 → 自动备份 → 状态 → 界面），不是备份算法本身
  // —— 算法在 `packages/shensuanzi_app` 的 `dart test` 里覆盖。

  final Finder backupCard = find.byKey(const Key('overview-backup-now'));

  /// 数据目录的兄弟目录名（`DataDirectoryPolicy.backupDirectoryFor` 的产物）。
  ///
  /// 刻意写字面量：它同时钉住「备份目录 = 数据目录的兄弟」这条
  /// `docs/data_directory.md` §八 的约定。
  ///
  /// ⚠️ 用**局部函数**而不是局部 `final` 变量：`box` 要到 `setUp` 才赋值，
  /// 写成 `final` 会在 `main()` 里当场读 `box.path` → `LateInitializationError`。
  String backupDirPath() => p.join(box.path, '神算子备份');

  /// 造一个「已建账」的数据目录：有效标记 + 一条单据。
  ///
  /// 单据是必须的 —— §AE 遗漏 1 的空库判定看的就是 `documents` 有没有行。
  String seedDataDir(String name) {
    final String dir = p.join(box.path, name);
    Directory(dir).createSync(recursive: true);
    DataMarker.write(dir, schemaVersion: 1, now: 1700000000000);
    final Db db = Db.open(p.join(dir, AppBootstrap.databaseFileName));
    db.raw.execute(
      "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
      'paid_amount, occurred_at, time_estimated, created_at, updated_at) '
      "VALUES ('d1', 'CG20260928-001', 'purchase', 'confirmed', 0, 0, "
      '1700000000000, 0, 1700000000000, 1700000000000)',
    );
    db.close();
    return dir;
  }

  testWidgets('场景 6：空库启动 → 不自动备份（§AE 遗漏 1）', (WidgetTester tester) async {
    final String dataDir = p.join(box.path, 'data6');
    Directory(dataDir).createSync(recursive: true);
    DataMarker.write(dataDir, schemaVersion: 1, now: 1700000000000);
    store.save(AppConfig(dataDirectory: dataDir));

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byType(AppShell), findsOneWidget);
    // 空库连备份目录都不该建（跳过发生在可写探测之前）
    expect(
      Directory(backupDirPath()).existsSync(),
      isFalse,
      reason: '第一次启动就生成一份空库备份，此后几天全是同一份空库',
    );
    expect(backupCard, findsNothing, reason: '没数据可丢 → 不提醒');
  });

  testWidgets('场景 7：有单据 + 备份目录不可用 → 自动备份静默失败，橙卡说清「没成功」（§AE-3 + 遗漏 2）', (
    WidgetTester tester,
  ) async {
    final String dataDir = seedDataDir('data7');
    store.save(AppConfig(dataDirectory: dataDir));
    // 备份目录的路径上蹲一个文件（真实场景：U 盘拔了、被人改名/占位）
    File(backupDirPath()).writeAsStringSync('占位');

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byType(AppShell), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: '§AE-3：自动备份失败必须完全静默，不能抛到界面上',
    );
    expect(
      backupCard,
      findsOneWidget,
      reason: '「备份一直没成功」必须在用户不会主动打开设置页的地方说出来',
    );
    // ⚠️ 文案必须是**失败**那条：这一轮确实试过、确实没成。
    // 「还没有备份过」是另一种处境（从没试过），两条不能混
    expect(
      find.textContaining('上次备份没成功'),
      findsOneWidget,
      reason: '遗漏 2：不只让卡片在，还要说清「这次没成」',
    );
    expect(
      find.textContaining('备份文件夹用不了'),
      findsOneWidget,
      reason: '原因与「怎么办」由领域层给出，UI 不造句',
    );
  });

  testWidgets('场景 8：有单据 + 目录可写 → 启动即自动备份，橙卡不出现（§AE-3）', (
    WidgetTester tester,
  ) async {
    final String dataDir = seedDataDir('data8');
    store.save(AppConfig(dataDirectory: dataDir));

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final Directory backupDir = Directory(backupDirPath());
    expect(backupDir.existsSync(), isTrue, reason: '备份目录由服务自己建');
    final List<File> packs = backupDir
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.db'))
        .toList();
    expect(packs, hasLength(1), reason: '启动即生成一份，且只有一份');
    expect(
      p.basename(packs.single.path),
      startsWith('shensuanzi-schema${Schema.version}-'),
      reason: 'AE-4：文件名带 schema 版本（跟随 Schema.version，升版不再红）',
    );
    expect(backupCard, findsNothing, reason: '刚备份成功 → 不该再提醒');
  });

  // ---------------------------------------------------------------- 回归
  //
  // §AG 遗漏 1 落地后的**真实回归**：给数据目录对话框加了首启欢迎语之后，
  // 场景 3/5 报 `A RenderFlex overflowed by 36 pixels on the bottom`。
  //
  // ⚠️ **那不是测试挑剔，是真缺陷**：缩放最高档是 **200%**（本软件已发布的功能，
  // 中老年用户的本命功能），内容顶出屏幕后**「开始使用」按钮会看不见** ——
  // 首启就卡住。修法是给内容加可滚动容器，这条测试就是它的守卫。
  testWidgets('场景 9：数据目录对话框在 200% 文字缩放下不溢出（§AG 回归）', (
    WidgetTester tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(dialog, findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: '内容必须可滚动 —— 200% 字号下顶出屏幕 = 用户看不到「开始使用」',
    );

    // 主按钮仍然存在且可点（内容再长也不能把它挤出屏幕）
    expect(find.text('开始使用'), findsOneWidget);
  });
}
