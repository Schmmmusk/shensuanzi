import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late Directory box;
  late DataDirectoryService service;
  late DataDirectoryDialogModel model;

  setUp(() {
    box = sandbox();
    service = serviceIn(box);
    model = DataDirectoryDialogModel(service);
  });

  tearDown(() {
    if (box.existsSync()) box.deleteSync(recursive: true);
  });

  /// 沙箱里造一个「里面有别人东西」的目录
  String foreignDir() {
    final String dir = sandboxPath(box, 'other');
    Directory(dir).createSync(recursive: true);
    File(p.join(dir, '别人的东西.txt')).writeAsStringSync('x');
    return dir;
  }

  // ============================================================ 打开
  group('打开对话框', () {
    test('用默认位置起步，且可以直接开始', () {
      model.open();

      expect(model.path, r'D:\神算子数据');
      expect(model.advice.verdict, DirectoryVerdict.ok);
      expect(model.canConfirm, isTrue);
      expect(model.notice, isNull, reason: '没问题时不该有提示');
      expect(model.noticeKind, DialogNoticeKind.none);
      expect(model.isDone, isFalse);
      expect(model.location, isNull);
    });

    test('容量提示跟着路径走（拿不到就是 null，不编一个值）', () {
      model.open();
      expect(model.capacityHint, 'D 盘剩余 128.0 GB');

      final DataDirectoryDialogModel noInfo = DataDirectoryDialogModel(
        serviceIn(box, environment: machine(drives: <DriveInfo>[])),
      )..open();
      expect(noInfo.capacityHint, isNull);
    });

    test('还没打开时没有路径，也不该崩', () {
      expect(model.path, isEmpty);
      expect(model.capacityHint, isNull);
      expect(model.notice, isNull);
    });
  });

  // ============================================================ 改路径
  group('「更改」后的三档反馈', () {
    test('reject → 不能开始，提示里带「怎么办」，严重程度 = error', () {
      model.open();
      model.choosePath(r'C:\Windows\神算子');

      expect(model.canConfirm, isFalse);
      expect(model.noticeKind, DialogNoticeKind.error);
      expect(model.notice, contains('系统目录'));
      expect(model.notice, contains('建议'), reason: '必须给出下一步动作，不能只说哪里错');
      expect(model.notice, contains('。'), reason: '理由与建议之间要有分隔');
    });

    test('reject 时按「开始使用」→ blocked，不抛，也不落盘', () {
      model.open();
      model.choosePath(r'C:\Program Files\神算子');

      expect(model.confirm(), ConfirmOutcome.blocked);
      expect(model.isDone, isFalse);
      expect(model.location, isNull);
      expect(DataMarker.existsIn(r'C:\Program Files\神算子'), isFalse);
    });

    test('warn → **仍然能开始**（警告不拦人），严重程度 = warning', () {
      model.open();
      model.choosePath(r'C:\Users\tester\AppData\Local\神算子');

      expect(model.canConfirm, isTrue, reason: '中老年用户被拦住会认为「软件坏了」');
      expect(model.noticeKind, DialogNoticeKind.warning);
      expect(model.notice, contains('%LOCALAPPDATA%'));
    });

    test('改路径会作废上一次的结果', () {
      model.open();
      final String dir = sandboxPath(box, 'data');
      model.choosePath(dir);
      expect(model.confirm(), ConfirmOutcome.created);
      expect(model.isDone, isTrue);

      model.choosePath(sandboxPath(box, 'data2'));
      expect(model.isDone, isFalse, reason: '路径变了，旧结果不能再用');
      expect(model.location, isNull);
    });
  });

  // ============================================================ 开始使用
  group('「开始使用」', () {
    test('空目录 → created，并给出 location', () {
      model.open();
      final String dir = sandboxPath(box, 'data');
      model.choosePath(dir);

      expect(model.confirm(), ConfirmOutcome.created);
      expect(model.isDone, isTrue);
      expect(model.location!.directory, dir);
      expect(model.location!.createdNow, isTrue);
      expect(model.failure, isNull);
      expect(service.isShensuanziDir(dir), isTrue);
    });

    test('目录不存在 → created（会自动建）', () {
      model.open();
      model.choosePath(p.join(box.path, 'a', 'b', '神算子数据'));

      expect(model.confirm(), ConfirmOutcome.created);
      expect(Directory(model.location!.directory).existsSync(), isTrue);
    });

    test('已有标记的老目录 → reused（数据立刻回来）', () {
      final String dir = sandboxPath(box, 'data');
      service.ensureInitialized(dir, now: 111);

      model.open();
      model.choosePath(dir);

      expect(model.confirm(), ConfirmOutcome.reused);
      expect(model.location!.createdNow, isFalse);
      expect(model.location!.marker.createdAt, 111);
    });
  });

  // ============================================================ 二次确认
  group('非空且无标记 → 先问一次', () {
    test('choosePath 时就标出「需要确认」，且不让直接开始', () {
      model.open();
      model.choosePath(foreignDir());

      expect(model.needsForeignConfirm, isTrue);
      expect(model.canConfirm, isFalse);
      expect(model.noticeKind, DialogNoticeKind.warning);
      expect(model.notice, contains('已经有别的东西'));
    });

    test('直接 confirm → needsForeignConfirm，且**什么都没写**', () {
      final String dir = foreignDir();
      model.open();
      model.choosePath(dir);

      expect(model.confirm(), ConfirmOutcome.needsForeignConfirm);
      expect(DataMarker.existsIn(dir), isFalse, reason: '没确认过就不该初始化');
      expect(model.isDone, isFalse);
    });

    test('确认过之后再 confirm(acceptForeign: true) → created', () {
      final String dir = foreignDir();
      model.open();
      model.choosePath(dir);
      model.confirm();

      expect(model.confirm(acceptForeign: true), ConfirmOutcome.created);
      expect(model.isDone, isTrue);
      expect(DataMarker.existsIn(dir), isTrue);
      expect(
        File(p.join(dir, '别人的东西.txt')).existsSync(),
        isTrue,
        reason: '不该动用户已有的文件',
      );
    });
  });

  // ============================================================ 失败路径
  group('写不进去', () {
    test('路径指向一个**文件**而不是目录 → blocked，给「换一个」的建议', () {
      final String path = sandboxPath(box, 'not-a-dir');
      File(path).writeAsStringSync('我是文件');

      model.open();
      model.choosePath(path);

      // 校验层只看路径形态（它不碰磁盘），所以这里会放行；
      // 真正的失败发生在落盘那一刻 —— 必须有结论、**不能抛**
      expect(model.confirm(), ConfirmOutcome.blocked);
      expect(model.failure, isNotNull);
      expect(model.notice, contains('换一个文件夹'));
      expect(model.isDone, isFalse);
    });
  });

  // ============================================================ 提示口径
  group('提示口径', () {
    test('warn 的提示把「代价」和「怎么办」连起来', () {
      model.open();
      model.choosePath(r'D:\Dropbox\神算子');

      expect(model.notice, contains('同步'));
      expect(model.notice, contains('。'), reason: '理由与建议之间要有分隔');
    });

    test('noticeKind 与 canConfirm 一致：error 一定不能开始', () {
      for (final String bad in <String>[r'C:\', r'C:\Windows\x', '']) {
        model.open();
        model.choosePath(bad);
        if (model.noticeKind == DialogNoticeKind.error) {
          expect(model.canConfirm, isFalse, reason: bad);
        }
      }
    });
  });
}
