/// 应用版本号 —— **唯一来源在这里**。
///
/// ## 为什么单开一个文件
///
/// 版本号有**四处**要用：帮助页（用户看）、`pubspec.yaml`（构建用，Windows 的
/// `FileVersion` 由它派生）、README、以及将来的「关于」页。§AG-1 裁定后发现的
/// 真实问题就是**两处不一致**：`pubspec.yaml` 写着 `1.0.0+1`，帮助页写着 `v0.1.0`。
///
/// 判据（`Agents.md` §二：「判断放纯 Dart」的同一个思路）：**能被断言钉住的，
/// 就不要靠记忆维护**。所以：
///
/// - 用户可见的版本号从这里取（`AppVersion.value`）；
/// - `test/version_test.dart` **读 `pubspec.yaml` 与它比对** —— 谁改了一边忘了
///   另一边，测试立刻红。
///
/// ## ⚠️ 对外文案要带限定词（§AG-1 裁定）
///
/// `0.1.0` 对工程师是「早期」，对用户是「**未完成 / 试用版**」——
/// 中老年用户看到 `v0.1.0` 会想「会不会用几天就不能用了？」
/// 所以 [AppVersion.display] 带上「（第一个可部署版本）」：**这不是美化，
/// 是消除疑虑**。
library;

/// 版本号的**机器形态**（与 `pubspec.yaml` 的 `version:` 前半段逐字一致）
abstract final class AppVersion {
  /// `0.1.0` —— 与 `pubspec.yaml` 的 `version:` 相同
  static const String value = '0.1.0';

  /// `0.1.0+1` 里的构建号
  static const int build = 1;

  /// 给用户看的完整形态（帮助页 / 关于页用这个）
  static const String display = 'v$value（第一个可部署版本）';
}
