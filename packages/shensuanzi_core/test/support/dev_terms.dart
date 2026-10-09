// ⚠️ **与 `packages/shensuanzi_app/test/support/dev_terms.dart` 逐字相同** ——
// 薄封装，**不是重复实现**：`expectNoDevTerms` 依赖 `package:test`，既进不了
// `lib/`（生产代码不能引 test 依赖），也跨不了包（跨包测试目录互不可见）
// ⇒ 常量单一来源（core 的 `forbiddenDevTermsInUserText`）+ helper 各包各一份。
// **改动时两处同步**（见 `docs/reply_review.md` §CV·十三·二）。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

/// 断言 [text] 不含任何**通用**开发术语（共用表），外加调用方给的 [extra]
/// —— [extra] 是**模块特有**的泄漏（表名 / 样例数据 / 插件类名 / 占位符）。
void expectNoDevTerms(String text, {List<String> extra = const <String>[]}) {
  for (final String term in <String>[
    ...forbiddenDevTermsInUserText,
    ...extra,
  ]) {
    expect(text, isNot(contains(term)), reason: '不该出现「$term」');
  }
}
