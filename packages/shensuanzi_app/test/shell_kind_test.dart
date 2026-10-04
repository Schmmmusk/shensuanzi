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
}
