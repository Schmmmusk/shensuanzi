// `shellKindFor` —— 壳形态判定（§AH-5 / §BH B1a）。
//
// 判断放纯 Dart 的理由见 `lib/src/shell_kind.dart` 文件头：
// 传入的是操作系统名字符串，测试不用碰 `dart:io`。
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  group('shellKindFor（§BH B1a：android ⇒ 移动，其余 ⇒ 桌面）', () {
    test('android ⇒ mobile（唯一走移动壳的平台）', () {
      expect(
        shellKindFor(operatingSystem: 'android'),
        ShellKind.mobile,
      );
    });

    test('其余全部 ⇒ desktop（含未支持平台 —— 落桌面壳 = 明确的「未适配」）', () {
      for (final String os in <String>[
        'windows',
        'macos',
        'linux',
        'ios',
        'fuchsia',
        '', // 空串也要能答，不能抛
      ]) {
        expect(
          shellKindFor(operatingSystem: os),
          ShellKind.desktop,
          reason: 'os=$os',
        );
      }
    });
  });

  // M05（2026-10-08）：概览页的指路文案必须跟着壳走 —— 手机壳没有左侧列表。
  group('overviewNavHint（M05：桌面说「左边」，手机说「底部」）', () {
    test('桌面壳 → 提「左边的功能列表」', () {
      final String hint = overviewNavHint(mobileShell: false);
      expect(hint, contains('左边'));
      expect(hint, isNot(contains('底部')));
    });

    test('手机壳 → 提「底部的按钮」，且**不再**出现「左边」', () {
      final String hint = overviewNavHint(mobileShell: true);
      expect(hint, contains('底部'));
      expect(
        hint,
        isNot(contains('左边')),
        reason: '手机上写「左边的功能列表」正是 M05 报的错',
      );
    });

    test('两套文案都要点出三个高频入口（开单 / 库存 / 商品）', () {
      for (final bool mobile in <bool>[true, false]) {
        final String hint = overviewNavHint(mobileShell: mobile);
        expect(hint, contains('开单'), reason: 'mobile=$mobile');
        expect(hint, contains('库存'), reason: 'mobile=$mobile');
        expect(hint, contains('商品'), reason: 'mobile=$mobile');
      }
    });
  });
}
