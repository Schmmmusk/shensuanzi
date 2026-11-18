// 恢复对话框的「清单先行」契约（2026-11-18 用户裁定甲）。
//
// ## 为什么单独一个文件
//
// 这次改的是**交互顺序**（原来「全部体检完才显示」，现在「清单立刻出、点谁查谁」），
// 数据层的 `recovery_test.dart` 只能证明 `listRecoveryCandidates` 不打开库，
// **证明不了对话框真的用了它**。而退回旧行为的表现是「清单要等很久」——
// 那在单元测试里完全看不见。
//
// 判据（两条）：
// 1. 打开对话框后，**不经过任何真实等待**就能看到全部候选（含坏文件）；
// 2. 坏文件在清单里**不许**被预先标“不可用”（那说明它已被体检过）——
//    点它之后才给出「这份备份现在不能用了」。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/recovery_dialog.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory root;
  late Directory dataDir;
  late Directory backupDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ssz_dialog_');
    dataDir = Directory(p.join(root.path, '神算子数据'))..createSync();
    backupDir = Directory(p.join(root.path, '神算子备份'))..createSync();
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄偶尔没释放 —— 临时目录，删不掉就算了
    }
  });

  String backupName(DateTime time) => BackupFileName(
    manual: true,
    schemaVersion: Schema.version,
    time: time,
  ).fileName;

  /// 造一份**能开**的备份
  String goodBackup(DateTime time) {
    // 每次重建：同一个 seed 复用会导致 `doc_no` 唯一约束冲突
    final String source = p.join(root.path, 'seed-${time.millisecondsSinceEpoch}.db');
    final Db db = Db.open(source);
    db.raw.execute(
      'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
      'paid_amount, occurred_at, time_estimated, created_at, updated_at, '
      'business_day) '
      "VALUES ('d1', 'XS20261118-001', 'sale', 'confirmed', 1000, 0, "
      '1700000000000, 0, 1700000000000, 1700000000000, '
      '${businessDayOf(1700000000000)})',
    );
    db.close();
    final String target = p.join(backupDir.path, backupName(time));
    File(source).copySync(target);
    return target;
  }

  /// 造一份**看起来像备份、其实是垃圾**的文件
  String brokenBackup(DateTime time) {
    final String target = p.join(backupDir.path, backupName(time));
    File(target).writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
    return target;
  }

  Widget host() {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: ElevatedButton(
              key: const Key('open'),
              onPressed: () => showRecoveryDialog(
                context,
                dataDirectory: dataDir.path,
                databasePath: p.join(dataDir.path, 'shensuanzi.db'),
                backupDirectory: backupDir.path,
                currentSchemaVersion: Schema.version,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('清单先行：3 份全部立刻出现，坏文件也不会被预先标「不可用」', (
    WidgetTester tester,
  ) async {
    goodBackup(DateTime(2026, 11, 16, 9));
    goodBackup(DateTime(2026, 11, 17, 9));
    brokenBackup(DateTime(2026, 11, 18, 9)); // 最新的一份是坏的

    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('open')));
    // ⚠️ 只给两次 `pump`（假时钟），**不给任何真实等待**：
    // 清单是列目录得来的，若退回「逐份 quick_check」，这里就出不来 3 行。
    await tester.pump();
    await tester.pump();

    expect(find.text('数据体检与恢复'), findsOneWidget);
    expect(
      find.text('用这一份'),
      findsNWidgets(3),
      reason: '清单先行：不体检也要能看到并点选每一份',
    );
    expect(
      find.text('不可用'),
      findsNothing,
      reason: '坏文件在清单阶段**还没被体检**，不该提前标死 —— 那是旧行为（全部体检完才显示）',
    );
    expect(find.textContaining('还没检查'), findsWidgets);
  });

  testWidgets('点了坏的那份 ⇒ 说「不能用了」，列表不消失、其它份仍可点', (
    WidgetTester tester,
  ) async {
    goodBackup(DateTime(2026, 11, 16, 9));
    brokenBackup(DateTime(2026, 11, 18, 9)); // 最新，排最前

    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    await tester.pump();

    // 第一份就是坏的那份
    await tester.tap(find.text('用这一份').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recovery-confirm-restore')));

    // 体检 + 失败都在工作 isolate 里跑 ⇒ 要放真实时间
    for (int i = 0; i < 80; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (find.byKey(const Key('recovery-error')).evaluate().isNotEmpty) {
        break;
      }
    }

    expect(
      find.textContaining('不能用了'),
      findsOneWidget,
      reason: '坏文件必须在**接回前**被拦住（真机上不能拿它覆盖好文件）',
    );
    expect(
      find.text('用这一份'),
      findsWidgets,
      reason: '失败后列表要留在原地，让用户换一份，而不是把对话框清空',
    );
    // 2026-11-18 用户反馈：体检结论要回写到那一行 —— 否则它还写着「还没检查」，
    // 用户只能靠上方报错去猜是哪一份坏。
    expect(
      find.text('不可用'),
      findsOneWidget,
      reason: '被拦下的那一份必须当场标成不可用（它不是「还没检查」了）',
    );
    expect(
      find.textContaining('点「用这一份」会先体检'),
      findsOneWidget,
      reason: '另一份第 2 份仍然没体检过 —— 不能跟着一起标死',
    );
  });

  testWidgets('接回一份期间，其余未体检的行写「请等待体检完成」，不写「不可用」', (
    WidgetTester tester,
  ) async {
    goodBackup(DateTime(2026, 11, 16, 9));
    goodBackup(DateTime(2026, 11, 17, 9));

    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('用这一份').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recovery-confirm-restore')));
    // 只走假时钟：接回在工作 isolate 里，这里还停在「正在接回」那一刻
    await tester.pump();

    expect(
      find.textContaining('正在体检并接回'),
      findsOneWidget,
      reason: '前提：此刻确实处于「接回中」',
    );
    expect(
      find.text('不可用'),
      findsNothing,
      reason: '其余备份只是还没轮到体检，标「不可用」会让用户以为它们坏了',
    );
    expect(find.text('请等待体检完成'), findsOneWidget);
    expect(
      find.text('正在体检…'),
      findsOneWidget,
      reason: '正在接回的那一份要说清是它，不能与「等待」的那些混成一句',
    );

    // 收尾：让这次接回真的跑完（否则对话框挂着，后面的用例会受影响）
    for (int i = 0; i < 80; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (find.text('数据体检与恢复').evaluate().isEmpty) break;
    }
  });

  testWidgets('体检通过、接回失败 ⇒ 那一行还回「用这一份」，并显示真实内容', (
    WidgetTester tester,
  ) async {
    // 2026-11-18 评审 P2-b：体检通过、后续复制失败时，**不该**把这一行留在「还没检查」——
    // 用户会以为这份备份也有问题，从而白扔掉一份好备份。
    goodBackup(DateTime(2026, 11, 16, 9));
    goodBackup(DateTime(2026, 11, 17, 9));

    // 压住半成品：Windows 上打开的句柄不带 FILE_SHARE_DELETE ⇒ 复制那一步必然失败
    final RandomAccessFile locked = File(
      p.join(dataDir.path, 'shensuanzi.db.restoring'),
    ).openSync(mode: FileMode.write);
    addTearDown(locked.closeSync);

    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('用这一份').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recovery-confirm-restore')));
    for (int i = 0; i < 80; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (find.byKey(const Key('recovery-error')).evaluate().isNotEmpty) {
        break;
      }
    }

    expect(find.byKey(const Key('recovery-error')), findsOneWidget);
    expect(
      find.text('用这一份'),
      findsNWidgets(2),
      reason: '这一份体检是**过的**（问题出在磁盘），不该被标成不可用 —— 还它按钮让用户重试',
    );
    expect(find.text('不可用'), findsNothing);
    expect(
      find.textContaining('张单据'),
      findsOneWidget,
      reason: '体检结论要回写：这一行该显示「1 张单据 …」而不是「还没检查」',
    );
  },
      // 只有 Windows 锁得住文件（Linux 允许删已打开的文件，造不出「删不掉」）
      skip: !Platform.isWindows);

  testWidgets('极窄窗口（371 px，真机截图那档）：行内文字不越出列表视口', (
    WidgetTester tester,
  ) async {
    // 用户 2026-11-18 截图里的窗口是 371 px 宽。这个对话框内容写死 `width: 620`，
    // 会被父约束压到 ~243 px；而「2026-11-16 09:00」这个**不可断行**的词就要 228 px。
    //
    // ⚠️ 这类越界 `RenderFlex` **不报错**（整行被 `ListView` 裁掉，字是缺一块），
    // 所以不能用 `takeException()` 判 —— 实测把它改成 90 px 宽也照样「通过」。
    // 判据只能是**几何**：每一处文字的右边缘都要在对话框里面。
    tester.view.physicalSize = const Size(371, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    goodBackup(DateTime(2026, 11, 16, 9));
    brokenBackup(DateTime(2026, 11, 18, 9));

    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    await tester.pump();

    expect(find.text('数据体检与恢复'), findsOneWidget);
    // ⚠️ `find.byType(AlertDialog)` 拿到的是**整屏**（0..371），拿它当边界等于没判。
    // 真正会被裁掉的是列表视口：文字必须完整落在 ListView 里。
    final Rect viewport = tester.getRect(find.byType(ListView));
    for (final Finder finder in <Finder>[
      find.textContaining('2026-11-16').first, // 行首那行：时间
      find.textContaining('2026-11-18').first,
      find.textContaining('还没检查').first, // 说明
      find.text('用这一份').first, // 按钮
    ]) {
      final Rect rect = tester.getRect(finder);
      expect(
        rect.right,
        lessThanOrEqualTo(viewport.right),
        reason: '在 371 px 宽的窗口里越出了列表右边缘（${rect.right} > ${viewport.right}）',
      );
    }
  });
}
