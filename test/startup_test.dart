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
// ⚠️ 环境（盘符 / 剩余空间）**保持真实**（`AppEnvironment.detect()`）——
// `AGENTS.md` §4.3「启动流程的两个注入点」明确：注入环境会把「真实机器」变成假的。
// 场景 2 的「配置过且可用」因此需要一个**真实存在**的目录 + 有效标记。
//
// ⚠️ **由此：首启究竟弹哪个框是「机器相关」的**（§审查 OBS-11 前半起）：
// 默认位置没数据 ⇒ 欢迎向导；有数据（重装 / 解压到别处 / 双击第二份 exe）
// ⇒ 先问「继续使用 / 选一个新位置」。开发机本机就在用，默认位置恰恰**有数据** ——
// 所以：① 「无配置」的用例只断言「弹了对话框 + 没乱调选择器」，不假设是哪种；
// ② 需要「**一定**弹『选择数据存放位置』」的用例改成**配置驱动**（配置指向一个
// 不存在的目录 ⇒ `recoverLocation`，与机器无关）；③ 六个场景的**精确**判定由
// `bootstrap_test` 覆盖（纯 Dart，机器可造）。
//
// 场景 6/7/8 是 §AE 备份接线：**空库不备份**（遗漏 1）、**自动备份失败要
// 静默但在概览页可见**（AE-3 两层机制）、**正常链路启动即出一份**（AE-3）。
//
// 运行：`flutter test`（本机由用户执行）
import 'dart:convert';
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
    String? defaultDataDirectory,
  }) => ShensuanziApp(
    pickDirectory: pickDirectory ?? () async => null,
    configStore: configStore ?? store,
    // §BR·补 2 裁定 方案 B：只注入「机器给的默认位置」**一个值**
    //（`null` = 不注入 ⇒ 走真实机器的默认值）
    defaultDataDirectory: defaultDataDirectory,
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

  testWidgets('场景 1：没有配置过 → 弹出对话框，且不乱调选择器', (WidgetTester tester) async {
    var picked = 0;
    await tester.pumpWidget(
      app(pickDirectory: () async {
        picked++;
        return null;
      }),
    );
    await tester.pumpAndSettle();

    // 首启两种形态（见文件头注释）**都该弹对话框、都不该调选择器** ——
    // widget 层只钉这两条；精确到哪种由 `bootstrap_test` 的六场景覆盖
    expect(dialog, findsOneWidget);
    expect(picked, 0, reason: '还没点任何按钮，不该调选择器');
  });

  // ---- §BR·补 2 裁定 方案 B：注入 `defaultDataDirectory` **一个值**，
  //      让「首启两条分支」都能**确定性**覆盖（不再依赖开发机默认位置有没有数据）----

  testWidgets('场景 1b：注入的默认位置**为空** ⇒ 走欢迎向导（Case 1）', (
    WidgetTester tester,
  ) async {
    // 注入「机器给的默认位置」一个值 —— 空目录 ⇒ 没有标记 ⇒ welcome
    final String injected = p.join(box.path, '注入的默认位置');
    Directory(injected).createSync(recursive: true);

    await tester.pumpWidget(app(defaultDataDirectory: injected));
    await tester.pumpAndSettle();

    expect(dialog, findsOneWidget);
    expect(dialogTitle, findsOneWidget, reason: '空位置 ⇒ 正常首启（带欢迎语）');
    expect(
      find.textContaining(injected),
      findsWidgets,
      reason: '对话框里预填的就是注入的那个位置',
    );
  });

  testWidgets('场景 1c：注入的默认位置**已有数据** ⇒ 先问一句（Case 2 / OBS-11 前半）', (
    WidgetTester tester,
  ) async {
    final String injected = p.join(box.path, '注入的默认位置');
    Directory(injected).createSync(recursive: true);
    DataMarker.write(injected, schemaVersion: 1, now: 1700000000000);
    Db.open(p.join(injected, AppBootstrap.databaseFileName)).close();

    var picked = 0;
    await tester.pumpWidget(
      app(
        defaultDataDirectory: injected,
        pickDirectory: () async {
          picked++;
          return null;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('这个位置已经有神算子的数据'),
      findsOneWidget,
      reason: '§审查 OBS-11 前半：不问就直接点「开始使用」会挂到同一份数据上',
    );
    expect(find.textContaining(injected), findsOneWidget, reason: '要说清是哪个位置');
    expect(dialogTitle, findsNothing, reason: '弹的是询问，不是「选择数据存放位置」');
    expect(picked, 0);

    // 「继续使用已有数据」⇒ 复用那份数据（**真的读盘**：标记是测试真写下去的）
    await tester.tap(find.text('继续使用已有数据'));
    await tester.pumpAndSettle();
    expect(store.load().dataDirectory, injected);
  });

  testWidgets('场景 1d：注入的默认位置有数据 → 选「新位置」⇒ 弹选位置对话框，原数据不动', (
    WidgetTester tester,
  ) async {
    final String injected = p.join(box.path, '注入的默认位置');
    Directory(injected).createSync(recursive: true);
    DataMarker.write(injected, schemaVersion: 1, now: 1700000000000);
    Db.open(p.join(injected, AppBootstrap.databaseFileName)).close();

    await tester.pumpWidget(app(defaultDataDirectory: injected));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选一个新位置'));
    await tester.pumpAndSettle();

    expect(dialog, findsOneWidget);
    expect(dialogTitle, findsOneWidget);
    expect(
      find.textContaining('不会被删掉'),
      findsOneWidget,
      reason: '要说清「那份数据不会被动」，否则用户以为被覆盖了',
    );
    expect(
      File(p.join(injected, AppBootstrap.databaseFileName)).existsSync(),
      isTrue,
      reason: '原数据一个字节都不动',
    );
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
    // 造**位置失效**（配置指向一个不存在的目录）⇒ **必然**弹「选择数据存放位置」，
    // 与机器上默认位置有没有数据无关（见文件头注释）
    store.save(AppConfig(dataDirectory: p.join(box.path, '搬走了')));
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
    // 位置失效 ⇒ **一定**弹选位置对话框（不受机器默认位置影响）
    store.save(AppConfig(dataDirectory: p.join(box.path, '搬走了')));
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
    // 位置失效 ⇒ **一定**弹选位置对话框（首启形态与机器默认位置无关）
    store.save(AppConfig(dataDirectory: p.join(box.path, '搬走了')));
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

  testWidgets('场景 5b：配置里的目录还在、只是库损坏 → **直接错误页**（不弹首启向导）', (
    WidgetTester tester,
  ) async {
    // 真机场景（2026-10-05）：配置指向 `D://fed`，目录与标记都好，
    // 只是库文件被弄坏了。修复前这里会弹「选择数据存放位置」——
    // 用户一点，`config.json` 就被默认路径覆盖，原目录**再也切不回去**。
    final String dataDir = p.join(box.path, 'data');
    Directory(dataDir).createSync(recursive: true);
    DataMarker.write(dataDir, schemaVersion: 1, now: 1700000000000);
    File(p.join(dataDir, AppBootstrap.databaseFileName)).writeAsStringSync(
      '这不是一个有效的 SQLite 数据库',
    );
    store.save(AppConfig(dataDirectory: dataDir));

    var picked = 0;
    await tester.pumpWidget(
      app(pickDirectory: () async {
        picked++;
        return null;
      }),
    );
    await tester.pumpAndSettle();

    expect(dialog, findsNothing, reason: '库坏 ≠ 第一次启动（§审查 2026-10-05）');
    expect(find.textContaining('数据文件打不开'), findsOneWidget);
    expect(
      find.textContaining(dataDir),
      findsOneWidget,
      reason: '要说清**哪个目录**打不开 —— 用户才知道去哪修',
    );
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('换一个文件夹'), findsOneWidget);
    expect(picked, 0, reason: '没点按钮就不该调选择器');

    // 点「重试」：库还没修好 ⇒ 仍停在错误页（不越走越乱，也不弹向导）
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(find.textContaining('数据文件打不开'), findsOneWidget);
    expect(picked, 0, reason: '「重试」不是「换文件夹」');

    // **配置一个字节都没被动** —— 这正是真机踩到的那个坑
    expect(
      store.load().dataDirectory,
      dataDir,
      reason: '库打不开时绝不覆盖 config（否则原目录就丢了）',
    );
  });

  testWidgets('场景 5c：配置被截断 ⇒ 从原文**抢救**回原位置，直接进主界面（§审查 OBS-15）', (
    WidgetTester tester,
  ) async {
    // 真机最可能的坏法：写到一半断电 ⇒ JSON 截断，但 `data_directory` 那段还在
    final String dataDir = p.join(box.path, 'data');
    Directory(dataDir).createSync(recursive: true);
    DataMarker.write(dataDir, schemaVersion: Schema.version, now: 1700000000000);
    Db.open(p.join(dataDir, AppBootstrap.databaseFileName)).close(); // 真库

    // 用 jsonEncode 生成**合法**的路径字面量，再手工截断（不手写转义）
    File(p.join(box.path, 'config.json')).writeAsStringSync(
      '{\n  "data_directory": ${jsonEncode(dataDir)},\n  "ui_sca',
    );

    var picked = 0;
    await tester.pumpWidget(
      app(pickDirectory: () async {
        picked++;
        return null;
      }),
    );
    await tester.pumpAndSettle();

    // 抢救成功 ⇒ 用户**什么都察觉不到**：不弹对话框、直接回主界面
    expect(dialog, findsNothing, reason: '救回来了就不该打扰用户');
    expect(find.byType(AppShell), findsOneWidget);
    expect(picked, 0);

    // 读不懂的原文件要留档（人工退路），但**原件不删**
    expect(
      File(p.join(box.path, 'config.json.corrupt')).existsSync(),
      isTrue,
      reason: '留一份给人工看',
    );
    expect(
      File(p.join(box.path, 'config.json')).existsSync(),
      isTrue,
      reason: '只是读不懂，不是垃圾 —— 不许删',
    );
  });

  testWidgets('场景 5d：位置记着但文件夹没了 ⇒ 不说「第一次启动」，说清「找不到了」', (
    WidgetTester tester,
  ) async {
    final String gone = p.join(box.path, '被搬走了');
    store.save(AppConfig(dataDirectory: gone));

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(dialog, findsOneWidget, reason: '位置用不了 ⇒ 要用户重新指一个');
    expect(
      find.text('欢迎使用神算子'),
      findsNothing,
      reason: '配过就不能说「第一次启动」（§AG 遗漏 1）',
    );
    expect(
      find.textContaining('上次用的数据文件夹'),
      findsOneWidget,
      reason: '光不说谎还不够 —— 要说清原来那个在哪、该怎么办',
    );
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

    // 位置失效 ⇒ 弹选位置对话框（与 200% 缩放叠加，是最容易顶出屏幕的组合）
    store.save(AppConfig(dataDirectory: p.join(box.path, '搬走了')));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(dialog, findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: '内容必须可滚动 —— 200% 字号下顶出屏幕 = 用户看不到「开始使用」',
    );

    // 标题与主按钮都仍然在（内容再长也不能把它们挤出屏幕）
    expect(dialogTitle, findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);
  });
}
