/// 帮助页：四步上手 + 常见问题 + 反馈入口 + 版本号。
///
/// ## 裁定落点（`docs/reply_review.md` §AC）
///
/// - **四步上手第一步是「录入现有货物」**（遗漏 4：不放第一步，用户会先建
///   商品再发现库存是空的）；每步带 emoji 视觉锚点（纯文字列表中老年不读）
/// - **FAQ 覆盖「期初成本为什么是 0」**（AB-2 第三层：解释 + 校准预期）
/// - **反馈入口给真实地址**（遗漏 3：占位要么不做要么给真实地址 —— 用户裁定
///   提供了 GitHub issues 与邮箱，因此落地而非省略）
/// - **版本号在底部**（遗漏 6：debug 时必要信息）
library;

import 'package:flutter/material.dart';

/// 帮助页（纯静态 —— 无依赖，内容改动不需要新查询）。
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const String _issuesUrl = 'https://github.com/xgopilot/shensuanzi/issues';
  static const String _supportEmail = 'cedarandjoy@163.com';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color secondary = theme.textTheme.bodySmall?.color ?? theme.hintColor;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('帮助', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                '四步用起来。每一步在左侧导航都有常驻入口，随时可以点。',
                style: TextStyle(height: 1.6, color: secondary),
              ),
              const SizedBox(height: 16),

              // ---- 四步上手（遗漏 4：期初录入选第一步）----
              _Section(
                title: '四步上手',
                children: <Widget>[
                  _Step('1️⃣', '录入现有货物', '开店时店里已经有的货，'
                      '到「库存」页点「录入现有货物」一次记入。只有第一次需要做。'),
                  _Step('2️⃣', '建商品', '到「商品」页给每样商品建档'
                      '（名称、售价；进价可选）。新进的货也要先建档。'),
                  _Step('3️⃣', '采购入库 / 销售开单', '进货点「采购入库」，'
                      '卖货点「销售开单」。当场收付款可以直接在单子里记。'),
                  _Step('4️⃣', '看库存和往来', '「库存」页看还剩多少货，'
                      '「往来方」页看谁欠你、你欠谁。'),
                ],
              ),

              // ---- 常见问题（AB-2 第三层：期初成本 0 的解释）----
              _Section(
                title: '常见问题',
                children: <Widget>[
                  _Faq(
                    '我的数据存在哪里？',
                    '在「设置」页可以看到数据文件夹的位置，'
                        '点「打开文件夹」就能看到文件。备份文件夹也在那里。',
                  ),
                  _Faq(
                    '换电脑 / 重装系统怎么办？',
                    '把数据文件夹整个复制到新电脑同样位置（或在「设置」页打开'
                        '文件夹后整体拷走），软件装好后数据原样回来。',
                  ),
                  _Faq(
                    '期初录入后，为什么成本显示 0？',
                    '期初录入只记数量、不记成本（开店时的货当时花了多少钱，'
                        '系统不知道）。下次进货时填了进价，系统会自动用进价校准成本。'
                        '在此之前成本列显示「待校准」，不是坏了。',
                  ),
                  _Faq(
                    '数量填错了能改吗？',
                    '单据提交后不能改（账要留痕）。录错了用「再盘一次」纠正库存，'
                        '或开一张相反方向的单子冲抵。',
                  ),
                ],
              ),

              // ---- 反馈入口（遗漏 3：真实地址，用户裁定提供）----
              _Section(
                title: '遇到问题？',
                children: <Widget>[
                  SelectableText(
                    '到 GitHub 提交问题：$_issuesUrl\n'
                    '或发邮件：$_supportEmail\n'
                    '反馈时请附上本页最下方的版本号，能帮我们更快定位。',
                    style: TextStyle(height: 1.8, color: secondary),
                  ),
                ],
              ),

              const SizedBox(height: 24),
              // 遗漏 6：版本号 —— debug 时的必要信息
              Text(
                '神算子 v0.1.0 · 数据格式版本 schema v1',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.6, color: theme.hintColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一个小节：标题 + 内容
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

/// 四步上手的一步：emoji 锚点 + 标题 + 说明
class _Step extends StatelessWidget {
  const _Step(this.emoji, this.title, this.description);

  final String emoji;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(emoji, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    height: 1.6,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  description,
                  style: TextStyle(
                    height: 1.6,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条 FAQ：问题（加粗）+ 答案
class _Faq extends StatelessWidget {
  const _Faq(this.question, this.answer);

  final String question;
  final String answer;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Q：$question',
            style: const TextStyle(height: 1.6, fontWeight: FontWeight.w700),
          ),
          Text(
            'A：$answer',
            style: TextStyle(height: 1.6, color: theme.textTheme.bodySmall?.color),
          ),
        ],
      ),
    );
  }
}
