// 「多设备同步」面板的**文案**（`host_service_hints.dart`）—— 2026-11-01。
//
// 为什么单独测：提案 57 裁定 ②③⑤ 要求「原因不同，话就不一样」。
// 这些句子埋在 widget 里就只能靠人眼在真机上一屏一屏点；抽成纯函数后
// 每个分支都能被钉住，而且**改文案改坏了会红**。
//
// 判据有两层：
// 1. 该说的必须在（`contains`）；
// 2. **不该说的必须不在** —— 尤其「保存成功」这类话，加密失败时绝对不许出现。
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/host_service_hints.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

void main() {
  HostServiceSnapshot snapshotWith(TokenRestoreState state) =>
      HostServiceSnapshot(
        state: HostServiceState.running,
        port: 17890,
        address: '192.168.1.7',
        tokenRestore: state,
      );

  group('持久化提示（写盘失败 / 加密失败）', () {
    test('都正常 ⇒ 不提示', () {
      expect(
        hostPersistHint(writeFailed: false, protectFailed: false),
        isNull,
      );
    });

    test('写盘失败 ⇒ 说「只对这次运行有效」+ 指出 host.json', () {
      final String hint = hostPersistHint(
        writeFailed: true,
        protectFailed: false,
      )!;
      expect(hint, contains('只对这次运行有效'));
      expect(hint, contains('host.json'));
      expect(hint, contains('手机现在照样能连'));
    });

    test('加密失败 ⇒ 说「没能加密存下来」+ 只存了哈希（**不许**说保存成功）', () {
      final String hint = hostPersistHint(
        writeFailed: false,
        protectFailed: true,
      )!;
      expect(hint, contains('没能加密存下来'));
      expect(hint, contains('哈希'));
      expect(hint, contains('下次开机会需要重新生成'));
      for (final String forbidden in <String>['已保存', '保存成功', '已妥善保存']) {
        expect(hint, isNot(contains(forbidden)), reason: '裁定 ③：不许报成保存成功');
      }
    });

    test('两个都失败 ⇒ 只说写盘（更严重，且加密的前提本来就不成立）', () {
      final String hint = hostPersistHint(
        writeFailed: true,
        protectFailed: true,
      )!;
      expect(hint, contains('host.json'));
      expect(hint, isNot(contains('加密')));
    });
  });

  group('画不出码的说明（按 TokenRestoreState 分岔）', () {
    test('undecryptable ⇒ 点明「换了 Windows 用户或换了电脑」且说明这是有意的', () {
      final String hint = hostRestoreHint(
        snapshotWith(TokenRestoreState.undecryptable),
      );
      expect(hint, contains('换了 Windows 用户'));
      expect(hint, contains('这是有意的'));
      expect(hint, contains('重新生成'));
      // 不许说成「没存到硬盘」—— 那是 hashOnly 的说法，会把用户带偏
      expect(hint, isNot(contains('没有存到硬盘')));
    });

    test('mismatch ⇒ 说清「两份数据对不上」+ 按不可信处理', () {
      final String hint = hostRestoreHint(
        snapshotWith(TokenRestoreState.mismatch),
      );
      expect(hint, contains('对不上'));
      expect(hint, contains('不可信'));
      expect(hint, contains('重新生成'));
    });

    test('unsupported ⇒ 说「格式不认识」（可能被别的版本改过）', () {
      final String hint = hostRestoreHint(
        snapshotWith(TokenRestoreState.unsupported),
      );
      expect(hint, contains('不认识'));
      expect(hint, contains('重新生成'));
    });

    test('hashOnly ⇒ 旧说法（重启过了 / 没存到硬盘）', () {
      final String hint = hostRestoreHint(
        snapshotWith(TokenRestoreState.hashOnly),
      );
      expect(hint, contains('重启过了'));
      expect(hint, contains('没有存到硬盘'));
    });

    test('四句话互不相同（不许退化成同一句）', () {
      final Set<String> hints = <String>{
        for (final TokenRestoreState s in <TokenRestoreState>[
          TokenRestoreState.undecryptable,
          TokenRestoreState.mismatch,
          TokenRestoreState.unsupported,
          TokenRestoreState.hashOnly,
        ])
          hostRestoreHint(snapshotWith(s)),
      };
      expect(hints.length, 4);
    });

    test('每种都说清了「接下来做什么」（都要提到重新生成）', () {
      for (final TokenRestoreState s in <TokenRestoreState>[
        TokenRestoreState.undecryptable,
        TokenRestoreState.mismatch,
        TokenRestoreState.unsupported,
        TokenRestoreState.hashOnly,
      ]) {
        expect(
          hostRestoreHint(snapshotWith(s)),
          contains('重新生成'),
          reason: '$s 缺了「怎么办」',
        );
      }
    });
  });
}
