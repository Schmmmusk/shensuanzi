/// 界面字体（`docs/ui_principles.md` §二）。
///
/// ## 为什么必须显式指定
///
/// Flutter 自带的正文字体 Roboto **没有中文字形**。Windows 上找不到字形时
/// 由系统兜底 —— 实测落到**宋体**，那是二十年前的观感，用户会说
/// 「像外国软件，没适配」。显式给出字体栈，中文才会与系统其它窗口一致。
///
/// ## 为什么用系统字体，而不是把字体打进包里
///
/// | 方案 | 代价 |
/// |---|---|
/// | 内置一套中文字体 | **10–20 MB**，而且用户系统里已经有更好的那一套 |
/// | **指定系统字体族** | 零体积、随系统更新、与资源管理器 / 设置**同款** |
///
/// ## 只管「用哪一族字」，不管「多大」
///
/// 字号与行高的基线在 `docs/ui_principles.md` §二，档位由 `UiScale` 给 ——
/// 尺寸的事不在这里。**平台差异也只在这一层判断**，Flutter 侧照着摆。
library;

/// 界面字体栈。**纯函数，可 `dart test`。**
class AppTypography {
  const AppTypography._();

  /// Windows 上的中文字体栈，**顺序即优先级**。
  ///
  /// | 族名 | 为什么在里面 |
  /// |---|---|
  /// | `Microsoft YaHei UI` | Windows 的**界面**字体（资源管理器、设置都用它），与其它窗口观感一致 |
  /// | `Microsoft YaHei` | 「微软雅黑」本体；缺少 UI 变体的精简版 / 老版本靠它兜 |
  /// | `SimHei` | 雅黑彻底缺失时的中文字形保底（黑体，仍是无衬线，不会退回宋体） |
  /// | `Segoe UI` | 拉丁字母保底，保证任何环境下英文都不掉字形 |
  ///
  /// ⚠️ **必须用英文族名**：Flutter 在 Windows 上走 DirectWrite，
  /// `fontFamily` 要匹配字体的**不变族名**（invariant family name），
  /// 写「微软雅黑」这类本地化名字匹配不上，会静默退回兜底字体。
  static const List<String> windowsFontStack = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'SimHei',
    'Segoe UI',
  ];

  /// 平台对应的字体栈。**返回空列表 = 不干预，用系统默认。**
  ///
  /// - **Windows**：见 [windowsFontStack]（默认字体不含中文字形，必须显式给）
  /// - **Android**：**不指定** —— 它的默认字体本来就是 Noto Sans CJK / 思源黑体，
  ///   那正是「本机的原生观感」；硬塞一个 Windows 字体名只会让它找不到字体，
  ///   反而退回更差的兜底。
  static List<String> fontStackFor({required bool isWindows}) =>
      isWindows ? windowsFontStack : const <String>[];

  /// 直接给 `ThemeData.fontFamily` 用的首选族名；`null` = 不干预。
  static String? primaryFamilyFor({required bool isWindows}) {
    final List<String> stack = fontStackFor(isWindows: isWindows);
    return stack.isEmpty ? null : stack.first;
  }

  /// 直接给 `ThemeData.fontFamilyFallback` 用的后备族名；`null` = 不设。
  ///
  /// 不包含首选（它已经在 `fontFamily` 里），避免同一个名字写两遍。
  static List<String>? fallbackFor({required bool isWindows}) {
    final List<String> stack = fontStackFor(isWindows: isWindows);
    return stack.length <= 1 ? null : stack.sublist(1);
  }
}
