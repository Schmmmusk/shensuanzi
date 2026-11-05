// #24 的 **UI 按码分支**（N-e，2026-11-05 裁定甲：六码全接 + 保留业务拒绝原文）。
//
// ## 为什么在 core 而不是只写 widget 测试
//
// 判据是纯映射（`reason_code` + `last_error` → 一句用户文案），摆进 Flutter 只能靠
// `testWidgets` 起壳才能验；放 core 就能 `dart test` 直接喂枚举。与
// `write_blocked.dart` / `integrity.dart` 同一个套路（判断在纯 Dart，Flutter 只摆放）。
//
// ## 钉住的三件事
//
// 1. **每个可达码都有专属文案**，且**说「怎么办」**（不出现开发术语 —— 过
//    `forbiddenDevTermsInUserText`）；
// 2. **业务拒绝透传**：`rule_validation_failed` / `return_exceeds_original`
//    **必须**原样带出主机中文（「退货数量超过原单」这类信息一旦换成通用文案，
//    用户唯一能照做的线索就没了）；
// 3. **认不出的码不得静默降级成「原因不明」** —— 主机可以**加**新码（`reason_code`
//    只增不改），老客户端遇到新码时仍要把主机的中文显示出来。
//
// ⚠️ 反向灵敏度：把 `syncQueueFailureText` 整个换成 `lastError ?? '推送没成功（原因不明）'`
// ⇒ 本文件除「透传」组外全部变红。若全绿，说明测的不是这个修复。
//
// 运行：`dart test test/sync_failure_copy_test.dart`（在 `packages/shensuanzi_core` 下）
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

import 'support/dev_terms.dart';

void main() {
  /// 主机回执里**真的会带**的中文（`syncFailureReason` / `RuleRejection.reason`）。
  const String hostRuleText =
      '这次要退的数量超过了原单剩的（原单共 2、算上这次累计 3）。请把数量改小后再退。';
  const String hostGenericRule = '核销金额超过了这张单的未收金额，请改小一点。';
  const String hostReferenceText =
      '这条数据引用的对象在主机上不存在（可能已被删除），没有收下。';

  group('业务拒绝：透传主机原文（N-e 的纪律要求）', () {
    test('rule_validation_failed ⇒ 原样带出主机中文，不替换', () {
      expect(
        syncQueueFailureText(
          reasonCode: 'rule_validation_failed',
          lastError: hostGenericRule,
        ),
        hostGenericRule,
      );
    });

    test('return_exceeds_original ⇒ 同样透传（它和上一条是**两个码**）', () {
      // ⚠️ 决策单的六码表把它漏了 —— 它是独立枚举值，主机文案比通用兜底更有用，
      // 处置必须与 rule_validation_failed 一致，否则「退货退多了」会掉进固定文案。
      expect(
        syncQueueFailureText(
          reasonCode: 'return_exceeds_original',
          lastError: hostRuleText,
        ),
        hostRuleText,
      );
    });

    test('透传组：主机没给中文时兜底一句「怎么办」，不显示「原因不明」', () {
      for (final String code in <String>[
        'rule_validation_failed',
        'return_exceeds_original',
      ]) {
        final String text = syncQueueFailureText(
          reasonCode: code,
          lastError: null,
        );
        expect(text, isNotEmpty);
        expect(text, isNot(contains('原因不明')));
        expectNoDevTerms(text);
      }
    });
  });

  group('固定文案：可达码逐个钉', () {
    test('reference_missing ⇒ 说「先同步一次，会自动重传」', () {
      final String text = syncQueueFailureText(
        reasonCode: 'reference_missing',
        // ⚠️ 即使主机原文提到了「不存在」，也**不能**透传 —— 那句会让人以为单子废了，
        // 而这个码恰恰是唯一「等一会儿重推就好」的（reject_code.dart 注释点名）。
        lastError: hostReferenceText,
      );
      expect(text, contains('先同步'));
      expect(text, contains('自动'));
      expectNoDevTerms(text);
    });

    test('unknown_action ⇒ 说「在电脑上更新软件」', () {
      final String text = syncQueueFailureText(
        reasonCode: 'unknown_action',
        lastError: '主机处理这条操作时出错，请把电脑上的日志发给技术支持。',
      );
      expect(text, contains('更新'));
      expect(text, isNot(hostReferenceText));
      expectNoDevTerms(text);
    });

    test('target_missing ⇒ 说「刷新后确认」', () {
      final String text = syncQueueFailureText(
        reasonCode: 'target_missing',
        lastError: 'x',
      );
      expect(text, contains('刷新'));
      expectNoDevTerms(text);
    });

    test('field_type_mismatch ⇒ 说「把手机上的软件更新到最新版」', () {
      final String text = syncQueueFailureText(
        reasonCode: 'field_type_mismatch',
        lastError: 'x',
      );
      expect(text, contains('手机'));
      expect(text, contains('更新'));
      expectNoDevTerms(text);
    });

    test('host_storage ⇒ 说「电脑存不下」+「确认后重试」', () {
      final String text = syncQueueFailureText(
        reasonCode: 'host_storage',
        lastError: 'x',
      );
      expect(text, contains('电脑'));
      expect(text, contains('重试'));
      expectNoDevTerms(text);
    });

    test('固定文案**两两不同**（同文案 = 分支等于没做）', () {
      final List<String> texts = <String>[
        for (final String code in <String>[
          'reference_missing',
          'unknown_action',
          'target_missing',
          'field_type_mismatch',
          'host_storage',
          'duplicate',
        ])
          syncQueueFailureText(reasonCode: code, lastError: 'x'),
      ];
      expect(texts.toSet().length, texts.length, reason: '$texts');
    });
  });

  group('没有码的三种情况：都不许说「原因不明」', () {
    test('reasonCode = null（旧主机不带码）⇒ 显示主机中文原文', () {
      expect(
        syncQueueFailureText(
          reasonCode: null,
          lastError: '传输失败：SocketException',
        ),
        isNot(contains('原因不明')),
      );
    });

    test('换主机挂起（markHeld 写中文、无码）⇒ 原文照出，那是写给用户看的一段话', () {
      const String held =
          '这条单是在连接上一台主机时开的（主机 旧店电脑），先不发，等你确认。';
      expect(
        syncQueueFailureText(reasonCode: null, lastError: held),
        held,
        reason: '#47 丁：挂起原因本身就是人话，按码分支不能把它盖掉',
      );
    });

    test('认不出的新码（主机比客户端新）⇒ 退回主机中文，不静默降级', () {
      final String text = syncQueueFailureText(
        reasonCode: 'a_future_code_we_do_not_know',
        lastError: hostGenericRule,
      );
      expect(text, hostGenericRule);
      expect(text, isNot(contains('原因不明')));
    });

    test('既没码也没原文 ⇒ 才允许「原因不明」，且要带下一步动作', () {
      final String text = syncQueueFailureText(
        reasonCode: null,
        lastError: null,
      );
      expect(text, isNotEmpty);
      expectNoDevTerms(text);
    });
  });

  group('RejectCode 覆盖：可达面逐个有归属', () {
    /// UI 会**替换**成固定文案的码。
    ///
    /// ⚠️ 枚举有 **19 个**码，决策单的表只列了 6 个（2026-11-05 复核发现）。
    /// 剩下的按「**用户能不能做点什么**」分两类：
    /// * 能做点什么的（先同步 / 刷新 / 更新软件 / 腾地方）⇒ **各自一句**；
    /// * 「协议没写对」那一类（`not_writable_table` / `unknown_field` /
    ///   `unwritable_column` / `missing_field` / `id_mismatch` /
    ///   `malformed_parameter` / `payload_mutually_exclusive`）⇒ **共用一句**：
    ///   它们全是「客户端发了主机不收的东西」= 软件自身的缺陷，用户能做的动作
    ///   完全相同（更新软件 / 重开这张单），拆成七句只会让七句里六句是废话。
    ///   与 `sync_failure.dart` 里「协议违规 = 用户修不了」的既有立场一致。
    const Set<String> replacedCodes = <String>{
      'reference_missing',
      'unknown_action',
      'target_missing',
      'field_type_mismatch',
      'host_storage',
      'duplicate',
      'data_invalid',
      'unsupported_doc_type',
      'action_not_applicable',
      'rule_internal_error',
      'not_writable_table',
      'unknown_field',
      'unwritable_column',
      'missing_field',
      'id_mismatch',
      'malformed_parameter',
      'payload_mutually_exclusive',
    };

    /// UI **透传**主机中文的码。
    const Set<String> passthroughCodes = <String>{
      'rule_validation_failed',
      'return_exceeds_original',
    };

    test('枚举里每个码要么被替换、要么透传，**没有第三种**', () {
      final List<String> unassigned = <String>[
        for (final RejectCode code in RejectCode.values)
          if (!replacedCodes.contains(code.wire) &&
              !passthroughCodes.contains(code.wire))
            code.wire,
      ];
      expect(
        unassigned,
        isEmpty,
        reason: '新增 RejectCode 时必须同时决定 UI 怎么显示（N-e）：$unassigned',
      );
    });

    test('替换组的文案**不等于**主机原文（否则等于没分支）', () {
      for (final RejectCode code in RejectCode.values) {
        if (!replacedCodes.contains(code.wire)) continue;
        expect(
          syncQueueFailureText(reasonCode: code.wire, lastError: '主机原文 ABC'),
          isNot('主机原文 ABC'),
          reason: '${code.wire} 属于替换组',
        );
      }
    });

    test('全部码的文案过开发术语表', () {
      for (final RejectCode code in RejectCode.values) {
        expectNoDevTerms(
          syncQueueFailureText(reasonCode: code.wire, lastError: 'x'),
        );
      }
    });
  });
}
