/// 帮助页：四步上手 + 常见问题（含备份与恢复）+ 反馈入口 + 版本号。
///
/// ## 裁定落点（`docs/reply_review.md` §AC + §AE）
///
/// - **四步上手第一步是「录入现有货物」**（遗漏 4：不放第一步，用户会先建
///   商品再发现库存是空的）；每步带 emoji 视觉锚点（纯文字列表中老年不读）
/// - **FAQ 覆盖「期初成本为什么是 0」**（AB-2 第三层：解释 + 校准预期）
/// - **反馈入口给真实地址**（遗漏 3：占位要么不做要么给真实地址 —— 用户裁定
///   提供了 GitHub issues 与邮箱，因此落地而非省略）
/// - **版本号在底部**（遗漏 6：debug 时必要信息）
/// - **§AE-6**：恢复 FAQ 写成**六步能照做**的形式，并带上用户真实的两个
///   文件夹路径（`dataDirectory` / `backupDirectory`，没传就退回「到设置页看」）
///   —— 「先改名成 .bak 再粘贴」那一步不能省，它是用户的心理安全带
/// - **§AE 遗漏 8**：坦白「备份和数据在同一块硬盘」—— 备份解决的是误删误操作，
///   不是硬盘坏；重要数据要自己再拷一份到 U 盘
library;

import 'package:flutter/material.dart';

/// 帮助页（内容静态，只把两个真实路径插进恢复步骤）。
class HelpPage extends StatelessWidget {
  const HelpPage({super.key, this.dataDirectory, this.backupDirectory});

  /// 数据目录（恢复步骤第 4 步要回到这里；`null` = 只说「到设置页看」）
  final String? dataDirectory;

  /// 备份目录（恢复步骤第 2 步要打开它）
  final String? backupDirectory;

  static const String _issuesUrl = 'https://github.com/xgopilot/shensuanzi/issues';
  static const String _supportEmail = 'cedarandjoy@163.com';

  /// 备份文件夹怎么说（有真实路径就给路径 —— 用户能照着做）
  String get _backupFolder => backupDirectory == null
      ? '「设置」页里「备份位置」显示的那个文件夹'
      : '这个文件夹：$backupDirectory';

  /// 数据文件夹怎么说
  String get _dataFolder => dataDirectory == null
      ? '「设置」页里「数据位置」显示的那个文件夹'
      : '这个文件夹：$dataDirectory';

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
                  // §AE-6：恢复写成**六步能照做**的形式（带真实路径）
                  _Faq(
                    '备份放在哪？数据弄丢了怎么找回来？',
                    '备份放在$_backupFolder，名字里带日期。'
                        '每天首次打开软件会自动备份一次，最近 30 天的都留着，'
                        '每个星期最早的那一份会一直留着。\n\n'
                        '要恢复的话，照着做：\n'
                        '1. 先关掉神算子\n'
                        '2. 打开$_backupFolder\n'
                        '3. 找到你要恢复的那一份（看名字里的日期），右键「复制」\n'
                        '4. 打开$_dataFolder，'
                        '把里面的 shensuanzi.db 改名叫 shensuanzi.db.bak\n'
                        '5. 右键「粘贴」，把复制的那份贴进来，'
                        '也改名叫 shensuanzi.db\n'
                        '6. 重新打开神算子\n\n'
                        '第 4 步「先改名再粘贴」别省 —— 万一贴错了，原来那份还在。',
                  ),
                  // §AE 遗漏 8：诚实地告诉用户边界，不假装「备份万能」
                  _Faq(
                    '备份和数据在同一个硬盘，够安全吗？',
                    '备份解决的是「删错了、操作错了」，不是「硬盘坏了」。'
                        '备份就在数据文件夹旁边，整块硬盘坏掉的话两份都会丢。'
                        '重要的数据请自己再复制一份到 U 盘或另一台电脑上。',
                  ),
                  // §AF 遗漏 5：用户看到「导出」会以为能当备份用 —— 明说不能
                  _Faq(
                    '「导出」和「备份」是一回事吗？',
                    '不是，两个都要用。\n'
                        '导出：给会计、给人看的 —— CSV 文件，Excel / WPS 能打开，'
                        '但不能用它恢复软件。\n'
                        '备份：给自己防丢的 —— 数据库文件，只有神算子能恢复，'
                        '但会计打不开。\n'
                        '一句话：导出不能用来恢复，备份不能给会计看。',
                  ),
                  // §AF 六：出口在每页右上角，用户要知道从哪儿点
                  _Faq(
                    '怎么把数据给会计？',
                    '1. 打开「单据」页（或商品 / 库存 / 往来方页）\n'
                        '2. 选好时间范围\n'
                        '3. 点右上角「导出…」\n'
                        '4. 导出完点提示里的「打开文件夹」，用微信发出去'
                        '或复制到 U 盘\n\n'
                        '导出的文件完全属于你：它是一个普通的 CSV 文件，'
                        'Excel / WPS / 记事本都能打开。就算哪天不用神算子了，'
                        '这些数据还是你的。',
                  ),
                  // §AF 遗漏 8（Excel 版）：BOM 能解决 99%，剩下 1% 要有逃生门
                  _Faq(
                    'Excel 打开导出文件是乱码怎么办？',
                    '不要双击文件，改用导入：打开 Excel → 数据 → '
                        '从文本/CSV → 选这个文件 → 编码选 '
                        '「65001: Unicode (UTF-8)」 → 加载。\n'
                        '（少数很旧的 Excel 版本才会乱码；WPS 一般直接双击就正常。）',
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
