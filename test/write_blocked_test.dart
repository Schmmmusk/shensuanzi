// **写入被强制关闭**的判据与原因（2026-11-01，提案 57 批复 §三）。
//
// ## 为什么要有这一组（而 `read_only_test.dart` 不够）
//
// `read_only_test.dart` 钉的是「拿到 `canWrite: false` / `documentSink: null`
// 之后页面怎么表现」。但**「什么时候该传 false」**那个判据原来内联在
// `app.dart` 的 `build()` 里 —— 只有真机能验，而真机上造 Low 完整性
// 得给 exe 打标签、测完还得清现场（用户已明确说这条路走不通了）。
//
// 抽成纯函数之后，这里直接喂枚举就能钉住。**这一组绿了，代表**
// 「低权限 ⇒ 写入被关」这条连接点在代码层面是锁死的，只剩端到端那一段
// 需要真机（Low 进程 → 界面真的只读）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/integrity.dart';
import 'package:shensuanzi/src/write_blocked.dart';

void main() {
  group('判据：什么时候必须强制只读', () {
    test('low / untrusted ⇒ **必须**关闭（否则用户能录单、全白干）', () {
      for (final IntegrityLevel level in <IntegrityLevel>[
        IntegrityLevel.low,
        IntegrityLevel.untrusted,
      ]) {
        expect(
          isWriteBlocked(integrity: level, localDbFailed: false),
          isTrue,
          reason: '$level 下写什么都失败，不关就是让用户白录',
        );
      }
    });

    test('unknown ⇒ **不许**关闭（查不出来不能擅自废掉功能）', () {
      // 非 Windows 平台、或 OpenProcessToken 失败都会落到 unknown。
      // 用户裁定：这种情况只记日志，不禁用。
      expect(
        isWriteBlocked(integrity: IntegrityLevel.unknown, localDbFailed: false),
        isFalse,
        reason: '「查不出来」不等于「不能写」—— 擅自只读等于给所有人降级',
      );
    });

    test('medium / high / system ⇒ 可写', () {
      for (final IntegrityLevel level in <IntegrityLevel>[
        IntegrityLevel.medium,
        IntegrityLevel.high,
        IntegrityLevel.system,
      ]) {
        expect(
          isWriteBlocked(integrity: level, localDbFailed: false),
          isFalse,
          reason: '$level 是正常环境',
        );
      }
    });

    test('本机账本打不开 ⇒ 无论完整性级别都关闭', () {
      for (final IntegrityLevel level in IntegrityLevel.values) {
        expect(
          isWriteBlocked(integrity: level, localDbFailed: true),
          isTrue,
          reason: '$level + 账本打不开：写入本来就没地方落',
        );
      }
    });

    test('六档 × 两值 全覆盖（新增一档不会静默漏掉）', () {
      // 这条是给「以后加了一个 IntegrityLevel」准备的：默认必须落在
      // 「可写」那一侧，想让它只读就得显式改判据 —— 反向提醒。
      for (final IntegrityLevel level in IntegrityLevel.values) {
        final bool blocked = isWriteBlocked(
          integrity: level,
          localDbFailed: false,
        );
        final bool expectBlocked =
            level == IntegrityLevel.low || level == IntegrityLevel.untrusted;
        expect(blocked, expectBlocked, reason: '级别 $level 的默认档位变了？');
      }
    });
  });

  group('原因：两种情况的说法必须不一样', () {
    test('可写 ⇒ null（不显示任何说明）', () {
      expect(
        writeBlockedReason(
          integrity: IntegrityLevel.medium,
          localDbFailed: false,
        ),
        isNull,
      );
    });

    test('低权限 ⇒ 告诉用户「复制到别的位置」（他自己能走的一步）', () {
      for (final IntegrityLevel level in <IntegrityLevel>[
        IntegrityLevel.low,
        IntegrityLevel.untrusted,
      ]) {
        final String? reason = writeBlockedReason(
          integrity: level,
          localDbFailed: false,
        );
        expect(reason, isNotNull);
        expect(reason, contains('低权限'));
        expect(reason, contains('复制到别的位置'));
      }
    });

    test('本机账本打不开 ⇒ 说明「看数照常」（用户最想知道的一句）', () {
      final String? reason = writeBlockedReason(
        integrity: IntegrityLevel.medium,
        localDbFailed: true,
      );
      expect(reason, isNotNull);
      expect(reason, contains('账本打不开'));
      expect(reason, contains('看数'));
    });

    test('两种原因同时成立 ⇒ 说低权限（更根本，且用户能自己修）', () {
      final String? reason = writeBlockedReason(
        integrity: IntegrityLevel.low,
        localDbFailed: true,
      );
      expect(reason, contains('低权限'));
      expect(
        reason,
        isNot(contains('账本打不开')),
        reason: '低权限时账本「打不开」多半只是表象 —— 说错原因会把用户引去重装',
      );
    });

    test('文案里不许出现技术术语（errno / ACL / 完整性级别）', () {
      // 用户读不懂这些词，而且它们指向「找技术支持」，而我们要他先自己走一步
      for (final IntegrityLevel level in IntegrityLevel.values) {
        for (final bool failed in <bool>[true, false]) {
          final String? reason = writeBlockedReason(
            integrity: level,
            localDbFailed: failed,
          );
          if (reason == null) continue;
          for (final String jargon in <String>[
            'errno',
            'ACL',
            '完整性级别',
            'S-1-16',
          ]) {
            expect(
              reason.contains(jargon),
              isFalse,
              reason: '$level / localDbFailed=$failed 的文案里出现了「$jargon」',
            );
          }
        }
      }
    });
  });
}
