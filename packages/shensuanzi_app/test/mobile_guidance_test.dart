// 手机端「保留入口 + 点击引导」的**文案契约**（§CV·十一，2026-10-09）。
//
// ## 为什么要有这个文件
//
// 这 6 条引导文案 + 镜像空态文案，是手机端**唯一**告知用户
// 「为什么不行 → 去哪做 → 做完怎么同步」的通道（`mobile_guidance.dart` 文件头
// 自己承诺的三段结构）。在此之前它**零断言**：
//
// - `switch` 穷尽性只守「加了新话题忘写 case」，**守不住**文案写空 / 复制粘贴 /
//   漏掉「电脑」（用户不知道去哪做）/ 漏掉「同步」（用户不知道做完怎么看到）/
//   混进开发术语。
// - `ui_principles.md §1.3`：内联提示必须说清「下一步会发生什么」。
//
// ## 契约的硬约束（判定与文案在纯 Dart ⇒ 可在这里钉住）
//
// ① 每条正文都含「电脑」 ② 每条正文都含「同步」 ③ 无开发术语
// ④ 各条正文互不相同（防复制粘贴） ⑤ `mirrorEmptyMessage` 拼参 + 双分支
// ⑥ 标题在字数上限内
//
// ⚠️ 开发术语黑名单走**共用表**（`forbiddenDevTermsInUserText`，**单一来源在 core**）
//    + 本包的薄 helper `expectNoDevTerms`（`test/support/dev_terms.dart`）——
//    **不新造一份表**：两份词表就是「文案污染」的两个来源。
//    引导文案**没有模块额外词**，所以只调 helper、不传 `extra`。
// ⚠️ 与 `tool/selfcheck_app.dart` 的「mobileGuidance 文案契约」一节**不重复**：
//    那边只放最关键的 2 条（含「电脑」+ 含「同步」），全量契约在本文件。
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:test/test.dart';

import 'support/dev_terms.dart';

void main() {
  // ⚠️ 局部声明必须排在**首个使用点之前**（Dart 不提升；`testing.md §L` 第 1 项）
  final List<MobileGuideTopic> topics = MobileGuideTopic.values;
  final String title = mobileGuideTitle(MobileGuideTopic.newParty);

  group('引导正文的文案契约', () {
    test('每个话题都说了「电脑」—— 用户要知道去哪做', () {
      for (final MobileGuideTopic topic in topics) {
        expect(
          mobileGuideMessage(topic),
          contains('电脑'),
          reason: '$topic：手机端禁建的唯一出路是电脑，漏了用户就不知道下一步',
        );
      }
    });

    test('每个话题都说了「同步」—— 用户要知道做完怎么让手机看到', () {
      for (final MobileGuideTopic topic in topics) {
        expect(
          mobileGuideMessage(topic),
          contains('同步'),
          reason: '$topic：文件头承诺的第三段「做完怎么同步」不能缺',
        );
      }
    });

    test('正文不含开发术语（共用表；本模块无额外词）', () {
      for (final MobileGuideTopic topic in topics) {
        // 逐条调 helper：任何一条命中都会红（命中的词在 reason 里）
        expectNoDevTerms(mobileGuideMessage(topic));
      }
    });

    test('各话题正文互不相同（防复制粘贴）', () {
      final Set<String> bodies = <String>{
        for (final MobileGuideTopic topic in topics) mobileGuideMessage(topic),
      };
      expect(
        bodies,
        hasLength(topics.length),
        reason: '有两句一模一样 ⇒ 大概率是复制粘贴忘了改（改了文案却改错了话题）',
      );
    });

    test('标题简短（ui_principles §1.1）—— 给个字面上限，防将来被写长', () {
      expect(title.length, lessThanOrEqualTo(15), reason: '标题「$title」');
    });
  });

  group('镜像空态文案（mirrorEmptyMessage）', () {
    test('what 参数被拼接进返回值（否则调用方传什么都看不到）', () {
      expect(mirrorEmptyMessage('商品列表'), contains('商品列表'));
      expect(mirrorEmptyMessage('往来方列表'), contains('往来方列表'));
    });

    test('含「电脑」+「同步」（与引导正文同一套契约）', () {
      final String text = mirrorEmptyMessage('商品列表');
      expect(text, contains('电脑'));
      expect(text, contains('同步'));
    });

    test('钉住**双分支**：可能「还没同步下来」，也可能「主机上也没有」', () {
      final String text = mirrorEmptyMessage('商品列表');
      expect(
        text,
        contains('稍等'),
        reason: '(a) 还没同步下来 —— 等一等就有了',
      );
      expect(
        text,
        contains('电脑上也还没有'),
        reason: '(b) 主机上也没有 —— 只说 (a) 会让用户以为「等一等就有了」，'
            '一直等下去（§CV·十一·五 明说了这条不能简化掉）',
      );
    });
  });
}
