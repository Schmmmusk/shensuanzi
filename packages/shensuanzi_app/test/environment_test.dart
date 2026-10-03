// `AppEnvironment.detect()` 的**盘符枚举**测试（`docs/reply_review.md` §AT）。
//
// ## 这份测试要守住的三件事
//
// 1. **`detect()` 永不抛** —— 它在启动路径上（`main()` 第一行、
//    `_ShensuanziAppState` 的字段初始化），抛一次就是「软件打不开」。
// 2. **远程盘：事实可见、候选排除** —— 这是两条**独立**规则
//    （`docs/data_directory.md` §2.2）：枚举回答「本机有什么」，
//    候选回答「哪块盘适合放数据」。
// 3. **`DRIVE_*` → `DriveKind` 的归属** —— 纯函数 [mapRawDrives]，
//    不需要真的插一块内存盘或光驱就能钉住。
//
// ## 为什么必须能注入枚举器
//
// 「枚举失败」「离线映射盘」「远程盘」这些路径**没法用真实机器在测试里构造**
// （总不能在跑测试时拔一根网线）。所以 `detect({driveEnumerator})` 留了缝 ——
// 与 `folder_picker.dart` 同一个模式：**系统调用收敛到注入点，判断逻辑纯 Dart**。
//
// ⚠️ **不可接受的做法**：以「没法造出那种机器」为理由不测这条路径 ——
// 那等于让最需要保护的场景没有回归守卫。
//
// 历史（2026-10-01）：`Directory('Y:\\').existsSync()` 在**离线的映射网络盘**上
// 会**抛** `FileSystemException`（`errno 53`）**而不是返回 `false`** ⇒ 启动崩、
// `flutter test` 的 9 个启动场景全红；容错之后又发现它要等 SMB 超时
// （实测 **63,127 ms**）⇒ 启动白屏。最终改用 FFI 枚举（整轮 **3 ms**）。
//
// 运行：`cd packages/shensuanzi_app && dart test`（`docs/testing.md` §零）
library;

import 'dart:io';

import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

// ⚠️ 下面两个 `src/` 导入是**刻意的**：`mapRawDrives` / `RawDrive` / `winDrive*`
// 是**生产实现的词汇**，不是 `DriveEnumerator` 接缝的一部分，因此**不进桶文件**
// （不扩大包的公开面，见 `lib/shensuanzi_app.dart` 的注释）。
// 但「`DRIVE_*` → `DriveKind` 的归属」是**纯 Dart 逻辑**，必须能被测 ——
// 包内测试直接测内部实现，是这里唯一不扩公开面的办法。
import 'package:shensuanzi_app/src/environment.dart' show mapRawDrives;
import 'package:shensuanzi_app/src/windows_drives.dart'
    show
        RawDrive,
        winDriveCdrom,
        winDriveFixed,
        winDriveNoRootDir,
        winDriveRamdisk,
        winDriveRemote,
        winDriveRemovable,
        winDriveUnknown;

import 'support/fixtures.dart';

List<String> _letters(Iterable<DriveInfo> drives) =>
    <String>[for (final DriveInfo d in drives) d.letter];

void main() {
  // 盘符枚举是 **Windows 专属分支**（`detect()` 里的 `if (Platform.isWindows)`）。
  // 本仓库的 `dart test` 在 Windows 上跑（`docs/testing.md` §零），
  // 这里只是**诚实标注**，不是「跳过保护」。
  final bool onWindows = Platform.isWindows;
  const String windowsOnly =
      '盘符枚举是 Windows 专属分支（detect() 内的 if (Platform.isWindows)）';

  // ============================================================ 纯函数：映射
  group('mapRawDrives：Win32 事实 → 领域类型（不需要真机）', () {
    test('FIXED / REMOVABLE / REMOTE 各归各档，且**远程盘进列表**（事实可见）', () {
      final DriveEnumeration e = mapRawDrives(<RawDrive>[
        RawDrive(letter: 'C', type: winDriveFixed, freeBytes: 33784053760),
        RawDrive(letter: 'E', type: winDriveRemovable, freeBytes: 16 * gb),
        RawDrive(letter: 'Y', type: winDriveRemote), // ⚠️ 不查剩余空间（会触网）
      ]);

      expect(_letters(e.drives), <String>['C', 'E', 'Y']);
      expect(e.drives[0].kind, DriveKind.fixed);
      expect(e.drives[1].kind, DriveKind.removable);
      expect(e.drives[2].kind, DriveKind.network);
      expect(e.drives[2].freeBytes, isNull);
      expect(e.failures, isEmpty);
    });

    test('光驱 / 内存盘**不进列表**（硬塞成 unknown 会被当成可放数据的盘）', () {
      final DriveEnumeration e = mapRawDrives(<RawDrive>[
        RawDrive(letter: 'D', type: winDriveCdrom),
        RawDrive(letter: 'R', type: winDriveRamdisk),
      ]);

      expect(e.drives, isEmpty);
      // 它们是**正常结果**，不是失败 —— 不该污染诊断
      expect(e.failures, isEmpty);
    });

    test('类型问不出来的盘符**不进列表**，但记进 failures（留现场）', () {
      final DriveEnumeration e = mapRawDrives(<RawDrive>[
        RawDrive(letter: 'Q', type: winDriveUnknown),
        RawDrive(letter: 'W', type: winDriveNoRootDir),
      ]);

      expect(e.drives, isEmpty);
      expect(e.failures, <String>['Q', 'W']);
    });

    test('远程盘进了列表，但**不进默认位置候选**（策略排除，不是事实排除）', () {
      final DriveEnumeration e = mapRawDrives(<RawDrive>[
        RawDrive(letter: 'C', type: winDriveFixed, freeBytes: 100 * gb),
        RawDrive(letter: 'D', type: winDriveFixed, freeBytes: 128 * gb),
        RawDrive(letter: 'Y', type: winDriveRemote),
      ]);

      // 事实：三块盘都在
      expect(_letters(e.drives), <String>['C', 'D', 'Y']);
      // 策略：候选只剩 D（C 是系统盘、Y 是网络盘）
      final AppEnvironment env = machine(
        drives: e.drives,
        probeFailures: e.failures,
      );
      expect(_letters(env.candidateDataDrives), <String>['D']);
    });
  });

  // ============================================================ detect() 容错
  group('detect() 永不抛异常', () {
    test('① 只有离线的映射盘可用时 → 默认数据目录**不落在它上面**', () {
      final AppEnvironment env = AppEnvironment.detect(
        driveEnumerator: () =>
            const DriveEnumeration(drives: <DriveInfo>[cDrive, zNetwork]),
      );

      expect(_letters(env.drives), <String>['C', 'Z']);
      expect(env.candidateDataDrives, isEmpty);
      // C 是系统盘、Z 是网络盘 ⇒ 退回用户目录（而不是把数据放到连不上的盘上）
      expect(
        DataDirectoryPolicy(env).defaultDataDirectory(),
        isNot(startsWith('Z:')),
      );
    }, skip: onWindows ? false : windowsOnly);

    test('② 枚举**抛异常** → drives 为空，但 detect() 正常返回', () {
      final AppEnvironment env = AppEnvironment.detect(
        driveEnumerator: () => throw StateError('GetLogicalDrives 失败（模拟）'),
      );

      expect(env.drives, isEmpty);
      expect(env.probeFailures, isEmpty);
      expect(env.isWindows, isTrue);
      expect(env.environment, isNotEmpty);
      expect(env.candidateDataDrives, isEmpty);
    }, skip: onWindows ? false : windowsOnly);

    test('②b 枚举返回空（没有盘）→ 同样降级，不崩', () {
      final AppEnvironment env = AppEnvironment.detect(
        driveEnumerator: () => const DriveEnumeration(),
      );

      expect(env.drives, isEmpty);
      expect(env.candidateDataDrives, isEmpty);
    }, skip: onWindows ? false : windowsOnly);

    test('②c 回归：正常机器行为**不变**', () {
      final AppEnvironment env = AppEnvironment.detect(
        driveEnumerator: () =>
            const DriveEnumeration(drives: <DriveInfo>[cDrive, dDrive]),
      );

      expect(_letters(env.drives), <String>['C', 'D']);
      expect(env.probeFailures, isEmpty);
      expect(_letters(env.candidateDataDrives), <String>['D']);
      expect(DataDirectoryPolicy(env).defaultDataDirectory(), r'D:\神算子数据');
    }, skip: onWindows ? false : windowsOnly);
  });

  // ============================================================ 消费端
  group('消费端容忍「盘列表为空」', () {
    test('③ 空盘列表 → 按「没有非系统盘」回退到用户目录，而不是崩', () {
      final DataDirectoryPolicy policy = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[]),
      );

      expect(policy.defaultDataDirectory(), r'C:\Users\tester\神算子数据');
    });

    test('③b 空盘列表下校验一个 D 盘路径 → 能用，且不误报盘相关警告', () {
      final DataDirectoryPolicy policy = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[]),
      );

      final DirectoryAdvice advice = policy.inspect(r'D:\我的账本');
      expect(advice.isUsable, isTrue);
      expect(advice.isWarning, isFalse);
    });

    test('③c 空盘列表 → 容量提示拿不到就是 null（不猜一个值）', () {
      final DataDirectoryPolicy policy = DataDirectoryPolicy(
        machine(drives: <DriveInfo>[]),
      );

      expect(policy.spaceHint(r'D:\我的账本'), isNull);
    });
  });
}
