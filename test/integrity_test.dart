// 进程完整性自检（`lib/src/integrity.dart`）—— 2026-11-01，联调 #1 的根因。
//
// ## 这条测试钉什么
//
// 联调 #1（`host.json` 写不进去、`errno = 5`）查了两天，最后真相是
// **exe 带了 Low 完整性标签 ⇒ 进程以 Low 启动 ⇒ 写不了任何 Medium 目录**。
// 这个自检的意义是：下次再有人遇到，**启动就说人话**，而不是让他录半小时单再发现白干。
//
// 所以这里钉三件事：
// 1. RID → 级别 的映射（`S-1-16-4096` 必须是 `low`，不能映射成 medium）；
// 2. 只有 low / untrusted 才提示（medium/high/system/unknown 一律不打扰）；
// 3. 提示语里必须**有「怎么办」**（三条自救路径），且说清「账目没丢」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/integrity.dart';

void main() {
  group('RID → 完整性级别', () {
    test('五档 SID 尾部 RID 映射正确', () {
      expect(integrityLevelOfRid(0x0000), IntegrityLevel.untrusted);
      expect(integrityLevelOfRid(0x1000), IntegrityLevel.low);
      expect(integrityLevelOfRid(0x2000), IntegrityLevel.medium);
      expect(integrityLevelOfRid(0x3000), IntegrityLevel.high);
      expect(integrityLevelOfRid(0x4000), IntegrityLevel.system);
    });

    test('认不出的 RID ⇒ unknown（不猜成 medium）', () {
      expect(integrityLevelOfRid(0x1234), IntegrityLevel.unknown);
      expect(integrityLevelOfRid(0x9999), IntegrityLevel.unknown);
    });
  });

  group('提示语：只在该提示时提示', () {
    test('low / untrusted ⇒ 提示', () {
      expect(lowIntegrityNotice(IntegrityLevel.low), isNotNull);
      expect(lowIntegrityNotice(IntegrityLevel.untrusted), isNotNull);
    });

    test('medium / high / system / unknown ⇒ 不提示', () {
      for (final IntegrityLevel level in <IntegrityLevel>[
        IntegrityLevel.medium,
        IntegrityLevel.high,
        IntegrityLevel.system,
        IntegrityLevel.unknown,
      ]) {
        expect(
          lowIntegrityNotice(level),
          isNull,
          reason: '$level 不该打扰用户',
        );
      }
    });
  });

  group('提示语内容（说人话 + 怎么解决）', () {
    late String notice;

    setUp(() {
      notice = lowIntegrityNotice(IntegrityLevel.low)!;
    });

    test('说清「存不下来」而不是「没权限」这种术语', () {
      expect(notice, contains('存不下来'));
      expect(notice, isNot(contains('ACL')));
      expect(notice, isNot(contains('完整性标签')));
      expect(notice, isNot(contains('errno')));
    });

    test('先安抚：程序没坏、账目没丢', () {
      expect(notice, contains('程序本身没坏'));
      expect(notice, contains('账目也没丢'));
    });

    test('三条自救路径都在：复制到别处 / 解除锁定 / 找支持', () {
      expect(notice, contains('复制到别的位置'));
      expect(notice, contains('解除锁定'));
      expect(notice, contains('技术支持'));
    });

    test('警告别在这个窗口录单（这是最容易白干的地方）', () {
      expect(notice, contains('别在这个窗口里录单'));
    });
  });

  group('真机检测（当前进程）', () {
    test('Windows 上本进程是 medium（测试进程由正常终端启动）', () {
      if (!Platform.isWindows) {
        markTestSkipped('只在 Windows 上有完整性级别');
        return;
      }
      expect(
        detectIntegrityLevel(),
        IntegrityLevel.medium,
        reason: '若这条红了，先看是谁启动了测试进程（可能是低权限/提权终端）',
      );
    });

    test('非 Windows ⇒ unknown，且不提示', () {
      if (Platform.isWindows) {
        markTestSkipped('本条只验非 Windows');
        return;
      }
      expect(detectIntegrityLevel(), IntegrityLevel.unknown);
      expect(lowIntegrityNotice(IntegrityLevel.unknown), isNull);
    });
  });
}
