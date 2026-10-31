// 手机端「本机账本打不开」的处理 —— 2026-10-31 联调 #0。
//
// ## 用户裁定（`docs/reply.md` §三/§四，2026-10-31）
//
// **A 第一阶段 = 降级只读**，不是「只把错误页去掉」：
//
// - 旧主库 `data/shensuanzi.db` 打不开、但镜像完好 ⇒ **照常进主界面**；
// - 能看的照常看（概览 / 库存 / 往来 / 导出 / 同步状态）；
// - **开单、改资料暂时禁用** —— 理由是还没逐页验证每个提交出口都与旧主库解耦；
// - 明确告知「现在用的是手机上的镜像数据」并**显示最近一次同步时间**；
// - **不删除、不覆盖**损坏的旧主库。
//
// 用户原话：「A 的真正工作量主要在于：不能只把 `_dbFailure` 清掉就算完事。」
//
// ## 三条断言的分工
//
// | 断言 | 钉住的是 |
// |---|---|
// | 错误页文案 `findsNothing` + 5 个 tab 都在 | 不再整页拦人 |
// | 开单 tab 三个入口不可点 + 原因在 + 提交出口为 null | **只读**是真的（不是画灰） |
// | 说明条带「最近一次同步」+「怎么办」 | 用户知道自己看的是哪一刻的数据 |
//
// ⚠️ 反向灵敏度：把 `_openDatabase` 的 catch 退回「一律 `_dbFailure`」
// ⇒ 第一组立刻红（错误页又回来了）。
//
// 运行：`flutter test`
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/app.dart';
import 'package:shensuanzi/src/ui/app_shell.dart';
import 'package:shensuanzi/src/ui/mobile_shell.dart';
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
  Directory rootWithBrokenDb() {
    final Directory root = Directory(p.join(box.path, 'files'))..createSync();
    final DataLocation location = DataDirectoryService(
      environment: AppEnvironment.detect(),
      configStore: store,
    ).ensureInitialized(p.join(root.path, 'data'));
    // 不是 SQLite 的文件 —— `Db.open` 必炸（真机现场是 disk I/O error）
    File(location.databasePath).writeAsStringSync('坏掉的账本' * 200);
    return root;
  }

  /// 健康的手机私有目录（库文件是一本完好的空账）。
  Directory rootWithHealthyDb() {
    final Directory root = Directory(p.join(box.path, 'files'))..createSync();
    final DataLocation location = DataDirectoryService(
      environment: AppEnvironment.detect(),
      configStore: store,
    ).ensureInitialized(p.join(root.path, 'data'));
    Db.open(location.databasePath).close();
    return root;
  }

  Widget app(Directory root) => ShensuanziApp(
    // 跑在 Windows 上也要走手机分支（否则测的是桌面壳，什么都不成立）
    shellKind: ShellKind.mobile,
    dataRoot: root.path,
    configStore: store,
    pickDirectory: () async => null,
  );

  AppShell shellOf(WidgetTester tester) =>
      tester.widget<MobileShell>(find.byType(MobileShell)).shell;

  group('A 降级：本地账本打不开，界面照进', () {
    testWidgets('不再出现启动错误页，5 个 tab 齐', (WidgetTester tester) async {
      await tester.pumpWidget(app(rootWithBrokenDb()));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('数据文件暂时打不开'),
        findsNothing,
        reason: '镜像好好的，本地账本坏了不该拦人（联调 #0 的原始症状）',
      );
      expect(find.textContaining('找回数据'), findsNothing, reason: '那是桌面的出路，手机没有');
      for (final String label in <String>['概览', '开单', '库存', '往来', '我的']) {
        expect(find.text(label), findsWidgets, reason: 'tab $label 必须在');
      }
    });

    testWidgets('说明条：账没丢 + 最近一次同步 + 「怎么办」', (WidgetTester tester) async {
      await tester.pumpWidget(app(rootWithBrokenDb()));
      await tester.pumpAndSettle();

      expect(find.textContaining('账没丢'), findsOneWidget);
      // 用户裁定原文要求「显示最近一次同步时间」——没配对过时也要说清
      expect(find.textContaining('还没和电脑成功同步过'), findsOneWidget);
      expect(find.text('怎么办'), findsOneWidget);
      // 措辞里不许出现「损坏 / 数据库」这类吓人的词（`docs/reply.md` 的基调）
      expect(find.textContaining('数据库'), findsNothing);
    });

    testWidgets('概览按**镜像**说「数据已就绪」，不说「请到设置里换位置」', (WidgetTester tester) async {
      await tester.pumpWidget(app(rootWithBrokenDb()));
      await tester.pumpAndSettle();

      expect(find.textContaining('请到设置里换一个位置'), findsNothing);
      expect(find.textContaining('数据文件已就绪'), findsOneWidget);
    });
  });

  group('A 只读：写入出口真的摘掉了（不是把按钮画灰）', () {
    testWidgets('开单 tab：三个入口不可点 + 原因在 + 点了也不推页', (WidgetTester tester) async {
      await tester.pumpWidget(app(rootWithBrokenDb()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('开单'));
      await tester.pumpAndSettle();

      expect(find.textContaining('开单和改资料暂时关闭'), findsOneWidget);
      for (final String label in <String>['销售开单', '采购入库', '送货']) {
        expect(find.text(label), findsOneWidget, reason: '入口还在（别让人以为功能没了）');
      }
      // 不可点：点了不该推整屏（没有 AppBar 标题）
      await tester.tap(find.text('销售开单'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('销售开单')),
        findsNothing,
        reason: '只读时入口必须真的点不动',
      );
    });

    testWidgets('提交出口 / 主数据出口 / 建策全部为 null 或只读', (WidgetTester tester) async {
      await tester.pumpWidget(app(rootWithBrokenDb()));
      await tester.pumpAndSettle();

      final AppShell shell = shellOf(tester);
      expect(shell.documentSink, isNull, reason: '开单出口必须摘掉（不是只画灰）');
      expect(shell.masterDataSink, isNull);
      expect(shell.partySink, isNull);
      expect(shell.masterDataPolicy.canCreateProducts, isFalse);
      expect(shell.masterDataPolicy.canCreateParties, isFalse);
      expect(shell.readOnlyReason, isNotNull);
    });

    testWidgets('库存页的「重新清点」也不给（没有提交出口就别开写入口）', (
      WidgetTester tester,
    ) async {
      // 清点单走单据队列；只读时 sink 为 null ⇒ 清点只会写镜像、永远到不了电脑。
      // 用户看到「清点成功」而主机上没有这张单，比没有入口糟得多。
      // （原来这里是 `assert`，只读降级让这个组合变成合法状态，assert 会直接抛。）
      await tester.pumpWidget(app(rootWithBrokenDb()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('库存'));
      await tester.pumpAndSettle();

      expect(find.text('重新清点'), findsNothing);
      expect(find.text('录入现有货物'), findsNothing);
      expect(find.textContaining('导出库存'), findsOneWidget, reason: '导出是只读，要留着');
    });

    testWidgets('「怎么办」给出恢复路径（含重试），取消则什么都不动', (WidgetTester tester) async {
      final Directory root = rootWithBrokenDb();
      await tester.pumpWidget(app(root));
      await tester.pumpAndSettle();

      await tester.tap(find.text('怎么办'));
      await tester.pumpAndSettle();

      expect(find.text('账本打不开，怎么办'), findsOneWidget);
      // 三步自救：先重试、再导出、最后重装（重装会清副本，所以必须先导出）
      expect(find.textContaining('重装'), findsOneWidget);
      expect(find.textContaining('导出本机数据文件'), findsOneWidget);

      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      expect(find.textContaining('账没丢'), findsOneWidget, reason: '说明条不该消失');
      expect(
        File(p.join(root.path, 'data', 'shensuanzi.db')).readAsStringSync(),
        '坏掉的账本' * 200,
        reason: '裁定原文：不删除、不覆盖损坏的旧主库',
      );
      // 也没有偷偷改名留档（那是「镜像损坏」那条路才做的事）
      expect(
        Directory(p.join(root.path, 'data'))
            .listSync()
            .where((FileSystemEntity e) => p.basename(e.path).contains('.broken-')),
        isEmpty,
      );
    });
  });

  group('正常态不受影响', () {
    testWidgets('库是好的 ⇒ 无说明条、写入出口齐、单据列表仍不接本地库', (WidgetTester tester) async {
      await tester.pumpWidget(app(rootWithHealthyDb()));
      await tester.pumpAndSettle();

      expect(find.textContaining('账没丢'), findsNothing, reason: '库是好的，不该降级');
      final AppShell shell = shellOf(tester);
      expect(shell.localDbNotice, isNull);
      expect(shell.readOnlyReason, isNull);
      expect(shell.documentSink, isNotNull, reason: '正常态开单要能入队');
      expect(shell.masterDataPolicy.canCreateProducts, isTrue);
      expect(shell.databaseReady, isTrue, reason: '镜像开着 ⇒ 对用户来说数据是就绪的');
      // 联调 #4 的潜在缺口：手机 5 个 tab 没有「单据」，一旦加了入口也**不许**
      // 读本地空壳库（主库在手机上是空壳，单据全在镜像里）
      expect(shell.documents, isNull);
    });
  });
}
