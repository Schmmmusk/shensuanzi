// 镜像打不开时的**界面全链路**（状态 3）—— 2026-10-31。
//
// 单元/集成层（`mirror_rescue_test` / `mirror_recovery_test`）已经钉住了
// 「抢得到 / 抢不到 / 留档 / 回填」；这一份只钉**用户看到的那一路**：
//
//   镜像坏 → 错误页（重试 + 修复本机数据副本）→ 确认框 → 结果框 → 进主界面
//
// 为什么值得单独一条：真机上一屏一屏点过去才会发现的问题（按钮点不动、
// 文案把「读不出来」说成「没有未传的单」）测试不会自己冒出来。
//
// 运行：`flutter test`
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/app.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late AppConfigStore store;
  late Directory root;

  setUp(() {
    box = Directory.systemTemp.createTempSync('ssz_mirror_page_');
    store = AppConfigStore(File(p.join(box.path, 'config.json')));
    root = Directory(p.join(box.path, 'files'))..createSync();
    // 本机账本是好的（这一条只测镜像坏）
    final DataLocation location = DataDirectoryService(
      environment: AppEnvironment.detect(),
      configStore: store,
    ).ensureInitialized(p.join(root.path, 'data'));
    Db.open(location.databasePath).close();
    // 镜像：认不出来的垃圾字节
    final String mirrorPath = p.join(root.path, 'mirror', 'shensuanzi_mirror.db');
    Directory(p.dirname(mirrorPath)).createSync(recursive: true);
    File(mirrorPath).writeAsBytesSync(List<int>.filled(4096, 0x42));
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget app() => ShensuanziApp(
    shellKind: ShellKind.mobile,
    dataRoot: root.path,
    configStore: store,
    pickDirectory: () async => null,
  );

  testWidgets('镜像打不开 ⇒ 错误页给「修复本机数据副本」，点完能进主界面', (WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // ① 错误页：说明 + 两条出路
    expect(find.textContaining('手机上的数据文件打不开'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('修复本机数据副本'), findsOneWidget);

    // ② 确认框：先问，并明说不删原件
    await tester.tap(find.text('修复本机数据副本'));
    await tester.pumpAndSettle();
    expect(find.text('修复本机数据副本？'), findsOneWidget);
    expect(find.textContaining('改名留档'), findsOneWidget);

    await tester.tap(find.text('修复'));
    await tester.pumpAndSettle();

    // ③ 结果框：文件认不出来时，**不许**说「没有未传的单」（那是撒谎）
    expect(find.text('修好了'), findsOneWidget);
    expect(find.textContaining('无法确认'), findsOneWidget);
    expect(
      find.textContaining('没有还没传上去的单'),
      findsNothing,
      reason: '读不出来 ≠ 本来就没有',
    );

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    // ④ 进主界面（新副本能开）
    for (final String label in <String>['概览', '开单', '库存', '往来', '我的']) {
      expect(find.text(label), findsWidgets, reason: 'tab $label 必须在');
    }

    // ⑤ 留档 + 清单都落在镜像目录里
    final List<String> names = Directory(p.join(root.path, 'mirror'))
        .listSync()
        .map((FileSystemEntity e) => p.basename(e.path))
        .toList();
    expect(
      names.where((String n) => n.contains('.broken-')),
      isNotEmpty,
      reason: '原件必须留档，不删',
    );
    expect(
      names.where((String n) => n.startsWith('未同步单据抢救-')),
      isNotEmpty,
      reason: '清单要落盘（用户要发给技术支持）',
    );
  });

  testWidgets('「先不修」⇒ 什么都不动，仍停在错误页', (WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('修复本机数据副本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('先不修'));
    await tester.pumpAndSettle();

    expect(find.textContaining('手机上的数据文件打不开'), findsOneWidget);
    expect(
      Directory(p.join(root.path, 'mirror'))
          .listSync()
          .where((FileSystemEntity e) => p.basename(e.path).contains('.broken-')),
      isEmpty,
      reason: '取消 = 一个字节都不动',
    );
  });
}
