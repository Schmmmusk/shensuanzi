// 手机端「本机账本打不开」的两半修法 —— 2026-10-31 联调 #0，用户裁定 **A + B
// 相结合，缺一不可**。
//
// ## 真机症状（这条测试要钉住的原始 bug）
//
// 把手机上 `files/data/shensuanzi.db` 换成一份 `integrity ok` 的同结构库
// （或把它弄坏）后重启 App：**直接进「数据文件暂时打不开」页** ——
// 尽管手机已配对、镜像完好、80 张单据都在镜像里。日志真因：
//
//     SqliteException(522): disk I/O error
//       Causing statement: PRAGMA journal_mode = WAL
//
// 而手机壳的业务页**全部读镜像**（主库在手机上是空壳，见 `app_shell.dart`
// 里 `allowBackup` 那段注释）⇒ 本地库坏掉不该拦住整个 App。
//
// ## 两条断言的分工
//
// | 断言 | 钉住的是 |
// |---|---|
// | 错误页文案 `findsNothing` + 5 个 tab 都在 | **A 降级**：不再整页拦人 |
// | 点「修复本机账本」→ 确认 → 顶部说明消失、库能开、`.broken-*` 留档 | **B 重建** |
//
// ⚠️ 反向灵敏度：把 `_openDatabase` 的 catch 退回「一律 `_dbFailure`」
// ⇒ 第一条立刻红（错误页又回来了）。这是本批的判据，别把它改成
// 「只要不崩就行」。
//
// 运行：`flutter test`
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/app.dart';
import 'package:shensuanzi/src/ui/app_shell.dart';
import 'package:shensuanzi/src/ui/mobile_shell.dart';
import 'package:shensuanzi/src/ui/sale_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  // `flutter test` 不打包 sqlite3.dll（见 `sqlite_local.dart` 头注释）
  useLocalSqlite();

  late Directory box;
  late AppConfigStore store;

  setUp(() {
    box = Directory.systemTemp.createTempSync('ssz_mobile_localdb_');
    store = AppConfigStore(File(p.join(box.path, 'config.json')));
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  /// 造一个**「目录 + 标记都在、库文件是坏的」**的手机私有目录。
  ///
  /// 必须走 `ensureInitialized` 造标记 —— 手写 `.shensuanzi-data` 会与真实
  /// 标记格式脱钩，哪天标记改结构，这条测试会变成「在测一个不存在的东西」。
  Directory brokenRoot() {
    final Directory root = Directory(p.join(box.path, 'files'))..createSync();
    final DataDirectoryService service = DataDirectoryService(
      environment: AppEnvironment.detect(),
      configStore: store,
    );
    final DataLocation location = service.ensureInitialized(
      p.join(root.path, 'data'),
    );
    // 不是 SQLite 的文件 —— `Db.open` 必炸（真机现场是 disk I/O error）
    File(location.databasePath).writeAsStringSync('坏掉的账本' * 200);
    return root;
  }

  Widget app(Directory root) => ShensuanziApp(
    // 跑在 Windows 上也要走手机分支（否则测的是桌面壳，什么都不成立）
    shellKind: ShellKind.mobile,
    dataRoot: root.path,
    configStore: store,
    pickDirectory: () async => null,
  );

  testWidgets('单据列表**不接本地库**（手机主库是空壳，联调 #4 的潜在缺口）', (WidgetTester tester) async {
    // 这次本地库是**好的** —— 否则「documents == null」可能只是因为库打不开，
    // 证明不了「手机端有意不接本地库」。
    final Directory root = Directory(p.join(box.path, 'files'))..createSync();
    final DataLocation location = DataDirectoryService(
      environment: AppEnvironment.detect(),
      configStore: store,
    ).ensureInitialized(p.join(root.path, 'data'));
    Db.open(location.databasePath).close(); // 一本完好的空账

    await tester.pumpWidget(app(root));
    await tester.pumpAndSettle();

    expect(find.textContaining('账没丢'), findsNothing, reason: '库是好的，不该降级');
    final AppShell shell = tester.widget<MobileShell>(find.byType(MobileShell)).shell;
    expect(shell.databaseReady, isTrue, reason: '镜像开着 ⇒ 对用户来说数据是就绪的');
    expect(
      shell.documents,
      isNull,
      reason: '手机 5 个 tab 没有「单据」，一旦加了入口也**不许**读本地空壳库',
    );
  });

  testWidgets('A 降级：本机账本打不开 ⇒ 照样进主界面，顶部一条说明', (WidgetTester tester) async {
    await tester.pumpWidget(app(brokenRoot()));
    await tester.pumpAndSettle();

    // ① 原始 bug 的判据：**不许**再出现启动错误页
    expect(
      find.textContaining('数据文件暂时打不开'),
      findsNothing,
      reason: '镜像好好的，本地账本坏了不该拦人（联调 #0 的原始症状）',
    );
    expect(find.textContaining('找回数据'), findsNothing, reason: '那是桌面的出路，手机没有');

    // ② 真的进了壳：5 个 tab 齐
    for (final String label in <String>['概览', '开单', '库存', '往来', '我的']) {
      expect(find.text(label), findsWidgets, reason: 'tab $label 必须在');
    }

    // ③ 说明条在，且说的是「账没丢 + 能开单」，不是「文件坏了」
    expect(find.textContaining('账没丢'), findsOneWidget);
    expect(find.textContaining('本机自动备份暂停'), findsOneWidget);
    expect(find.text('修复本机账本'), findsOneWidget);
  });

  testWidgets('概览页按**镜像**说「数据已就绪」，不说「请到设置里换位置」', (WidgetTester tester) async {
    await tester.pumpWidget(app(brokenRoot()));
    await tester.pumpAndSettle();

    // 手机上根本没有「换一个位置」这个设置项（私有目录系统管）——
    // 判据跟壳走（`databaseReady: mirror != null`），否则这句话是死路
    expect(find.textContaining('请到设置里换一个位置'), findsNothing);
    expect(find.textContaining('数据文件已就绪'), findsOneWidget);
  });

  testWidgets('A 降级**不是只读**：开单页照常能进（走镜像 + 队列，不碰本地库）', (
    WidgetTester tester,
  ) async {
    // 裁定原文里 A 是「降级为镜像只读」，但落到代码上**不该只读**：
    // 手机壳的开单出口是 `QueueSink(mirror)`（镜像 + 待同步队列），
    // 读面也全是镜像 —— 这条路**一次都不碰**本地库。
    // 让店主在本机账本坏掉时只能看不能记单，比 bug 本身更糟。
    await tester.pumpWidget(app(brokenRoot()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('开单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('销售开单'));
    await tester.pumpAndSettle();

    expect(find.byType(SalePage), findsOneWidget, reason: '开单页要真的装配出来');
    expect(
      find.textContaining('正在开发'),
      findsNothing,
      reason: '不许退化成「数据未就绪」占位页',
    );
    // 提交出口存在（`SalePage.sink` 非空即证明）⇒ 单据会入队，不会写本地库
    expect(tester.widget<SalePage>(find.byType(SalePage)).sink, isNotNull);
  });

  testWidgets('B 重建：确认后留档坏文件、开一本空账、说明条消失', (WidgetTester tester) async {
    final Directory root = brokenRoot();
    await tester.pumpWidget(app(root));
    await tester.pumpAndSettle();

    await tester.tap(find.text('修复本机账本'));
    await tester.pumpAndSettle();

    // 先问，并明说「不会删、账不会丢」（不替用户决定）
    expect(find.text('修复本机账本？'), findsOneWidget);
    expect(find.textContaining('不会删掉'), findsOneWidget);

    await tester.tap(find.text('修复'));
    await tester.pumpAndSettle();

    // ① 说明条消失（说明本地库开成功了 —— 它由 `_localDbFailure` 驱动）
    expect(find.textContaining('账没丢'), findsNothing);
    expect(find.text('修复本机账本'), findsNothing);

    // ② 库真的能开了，而且是**空账**（旧数据只在留档里）
    final String databasePath = p.join(root.path, 'data', 'shensuanzi.db');
    expect(File(databasePath).existsSync(), isTrue);
    final Db db = Db.open(databasePath);
    addTearDown(db.close);
    expect(db.schemaVersion, Schema.version);
    expect(
      db.raw.select('SELECT COUNT(*) FROM documents').first.values.first,
      0,
    );

    // ③ 坏文件**留档**了（不删是这条的底线）
    final List<String> archived = Directory(p.join(root.path, 'data'))
        .listSync()
        .map((FileSystemEntity e) => p.basename(e.path))
        .where((String n) => n.contains('.broken-'))
        .toList();
    expect(archived, hasLength(1), reason: '一个坏文件 ⇒ 一份留档');
    expect(
      File(p.join(root.path, 'data', archived.single)).readAsStringSync(),
      '坏掉的账本' * 200,
      reason: '留档内容一个字节都不许变',
    );
  });

  testWidgets('「先不修」⇒ 什么都不动，说明条还在', (WidgetTester tester) async {
    final Directory root = brokenRoot();
    await tester.pumpWidget(app(root));
    await tester.pumpAndSettle();

    await tester.tap(find.text('修复本机账本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('先不修'));
    await tester.pumpAndSettle();

    expect(find.textContaining('账没丢'), findsOneWidget, reason: '说明条不该消失');
    final String databasePath = p.join(root.path, 'data', 'shensuanzi.db');
    expect(
      File(databasePath).readAsStringSync(),
      '坏掉的账本' * 200,
      reason: '取消 = 一个字节都不动',
    );
  });
}
