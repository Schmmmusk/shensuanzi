// 界面字体栈（`docs/ui_principles.md` §二），对应 `tool/selfcheck_app.dart` 同名小节。
//
// 为什么值得测：字体栈错了**不会报错**，只会静默退回兜底字体 ——
// 在 Windows 上就是宋体。这种「无声的降级」只能靠断言钉住。
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

void main() {
  group('AppTypography · Windows 字体栈', () {
    test('非空，且首选是界面字体 Microsoft YaHei UI', () {
      final List<String> stack = AppTypography.fontStackFor(isWindows: true);

      expect(stack, isNotEmpty);
      expect(stack.first, 'Microsoft YaHei UI');
    });

    test('栈里没有重复族名（同一个名字写两遍 = 有一层兜底是摆设）', () {
      final List<String> stack = AppTypography.fontStackFor(isWindows: true);

      expect(stack.toSet().length, stack.length);
    });

    test('族名全为非空、无前后空格的英文名', () {
      for (final String family in AppTypography.fontStackFor(isWindows: true)) {
        expect(family.trim(), family, reason: '族名不该有前后空格：`$family`');
        expect(family, isNotEmpty);
        expect(
          family,
          isNot(matches(RegExp(r'[^\x20-\x7E]'))),
          reason: '必须用 DirectWrite 的不变族名（英文）；本地化名匹配不上：`$family`',
        );
      }
    });

    test('雅黑本体在栈里（精简版 / 老版本没有 UI 变体）', () {
      expect(
        AppTypography.fontStackFor(isWindows: true),
        contains('Microsoft YaHei'),
      );
    });

    test('有中文字形保底，且是**无衬线**（不能退回宋体）', () {
      final List<String> stack = AppTypography.fontStackFor(isWindows: true);

      expect(stack, contains('SimHei'), reason: '雅黑彻底缺失时的中文字形保底');
      expect(
        stack,
        isNot(contains('SimSun')),
        reason: '宋体是本次要修掉的观感，不能出现在自己的栈里',
      );
    });

    test('有拉丁字母兜底（英文不能掉字形）', () {
      expect(
        AppTypography.fontStackFor(isWindows: true),
        contains('Segoe UI'),
      );
    });
  });

  group('AppTypography · 其他平台', () {
    test('Android 不干预：空栈 = 用系统默认（Noto / 思源本来就是对的）', () {
      expect(AppTypography.fontStackFor(isWindows: false), isEmpty);
      expect(AppTypography.primaryFamilyFor(isWindows: false), isNull);
      expect(AppTypography.fallbackFor(isWindows: false), isNull);
    });
  });

  group('AppTypography · 给 ThemeData 的两个取值', () {
    test('primaryFamilyFor = 栈首', () {
      expect(
        AppTypography.primaryFamilyFor(isWindows: true),
        AppTypography.fontStackFor(isWindows: true).first,
      );
    });

    test('fallbackFor = 栈去掉首选（不重复写一遍）', () {
      final List<String> stack = AppTypography.fontStackFor(isWindows: true);
      final List<String>? fallback = AppTypography.fallbackFor(
        isWindows: true,
      );

      expect(fallback, stack.sublist(1));
      expect(fallback, isNot(contains(stack.first)));
    });

    test('首选 + 后备拼起来 = 完整栈（不会漏掉任何一层）', () {
      final List<String>? fallback = AppTypography.fallbackFor(
        isWindows: true,
      );
      final List<String> rebuilt = <String>[
        AppTypography.primaryFamilyFor(isWindows: true)!,
        ...?fallback,
      ];

      expect(rebuilt, AppTypography.fontStackFor(isWindows: true));
    });
  });
}
