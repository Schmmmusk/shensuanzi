/// 用户手册内容（§AG·八：**单一来源**）。
///
/// ## 为什么内容放纯 Dart
///
/// 同一份内容要出现在**两个地方**：软件内的「完整手册」页（Flutter 渲染）、
/// 随包分发的 `用户手册.html`（任意浏览器打开）。两个来源早晚漂移 ——
/// 所以内容在这里定义成**数据**，两边都只是渲染。
///
/// ## 「不给开发者看」的纪律（可执行）
///
/// 手册是给**使用者**看的，不是给开发者看的。这不是靠自觉：定义一个
/// **开发词汇黑名单**（`manualForbiddenDevTerms`），[assertManualIsUserFacing]
/// 逐字扫一遍 —— 测试、自检、生成脚本三方都会调它，
/// 谁往手册里写了「Dart / schema / 编译」之类的词，门禁直接红。
library;

/// 手册里的一个内容块。
sealed class ManualBlock {
  const ManualBlock();
}

/// 普通段落。
class ManualParagraph extends ManualBlock {
  const ManualParagraph(this.text);

  final String text;
}

/// 编号步骤（用户照着做的操作序列）。
class ManualSteps extends ManualBlock {
  const ManualSteps(this.items);

  final List<String> items;
}

/// 提示框。`warning = true` 是**注意**（amber），否则是**小贴士**（绿）。
class ManualNote extends ManualBlock {
  const ManualNote(this.text, {this.warning = false});

  final String text;
  final bool warning;
}

/// 常见问题（问 + 答）。
class ManualQa extends ManualBlock {
  const ManualQa(this.question, this.answer);

  final String question;
  final String answer;
}

/// 手册的一章。
class ManualSection {
  const ManualSection({required this.id, required this.title, required this.blocks});

  /// 稳定标识（HTML 锚点 / 测试引用用），如 `backup`。
  final String id;

  final String title;

  final List<ManualBlock> blocks;
}

/// 手册章节（[versionLine] 印在「反馈与版本」一章，如 `v0.1.0（第一个可部署版本）`）。
List<ManualSection> buildManualSections({required String versionLine}) => <ManualSection>[
  ManualSection(
    id: 'welcome',
    title: '欢迎使用神算子',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '神算子是一家小店的记账帮手：进货、卖货、谁欠你钱、你欠谁钱，'
        '记下来，随时能看，也能导出成表格文件给会计。',
      ),
      const ManualParagraph(
        '三件你最关心的事，先说清楚：\n'
        '一、数据存在你自己选的电脑文件夹里，不会上传到任何服务器。\n'
        '二、软件是免费的，没有试用期，不会过期。\n'
        '三、软件会每天自动备份你的数据（见「备份与恢复」一章）。',
      ),
      const ManualNote(
        '第一次用？照着「第一次启动」和「开始记账前的准备」两章做一遍，'
        '大概十分钟就能开始记第一笔账。',
      ),
    ],
  ),
  ManualSection(
    id: 'first-run',
    title: '第一次启动',
    blocks: <ManualBlock>[
      const ManualSteps(<String>[
        '双击软件文件夹里的 shensuanzi.exe。',
        '如果 Windows 弹出蓝色提示「Windows 已保护你的电脑」，'
            '点「更多信息」，再点「仍要运行」。这是没买数字证书的软件都会遇到的提示，'
            '不是病毒警告，只需要做一次。',
        '软件会问「数据放在哪」。建议选 D 盘这样的非系统盘 —— 以后重装系统，数据也不会丢。',
        '点「开始使用」。',
      ]),
      const ManualNote(
        '不要把数据放在 U 盘或网盘的同步文件夹里（微信传输、坚果云这类）—— '
            '这类位置容易拔掉或同步出错，会弄坏正在写入的数据。',
        warning: true,
      ),
      const ManualParagraph(
        '选好之后，软件会在那个文件夹里建立你的数据。以后每次打开软件，'
        '都会直接进入主界面，不再询问。',
      ),
    ],
  ),
  ManualSection(
    id: 'tour',
    title: '认识主界面',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '左边一列是所有功能的入口，从上到下分成四组：',
      ),
      const ManualParagraph(
        '「概览」—— 开门第一眼：今天要不要备份、数据在哪，都在这一页。\n'
        '「销售开单」「采购入库」—— 每天用得最多的两个动作，做成大按钮。\n'
        '「商品」「库存」「单据」「往来方」「账户」—— 查东西的地方。\n'
        '「设置」「帮助」—— 调整字号、看手册、找反馈方式。',
      ),
      const ManualNote(
        '「销售开单」和「采购入库」是整屏的单子页面，方便专注录入；'
            '左边的导航仍然在，随时能跳去别的地方。',
      ),
      const ManualParagraph(
        '字太小？去「设置」页把字号调大（五档），一键「恢复默认大小」随时调回来。',
      ),
    ],
  ),
  ManualSection(
    id: 'prepare',
    title: '开始记账前的准备',
    blocks: <ManualBlock>[
      const ManualParagraph('第一次记账前，先做三件事（每件一两分钟）：'),
      const ManualSteps(<String>[
        '建收付款的账户：进「账户」页，新建一个，比如「现金」「微信收款」。'
            '有了账户，开单时才能记「当场收了钱 / 付了钱」。',
        '建商品：进「商品」页，点「新增商品」。编码不用想 —— 软件自动按顺序生成；'
            '条码有就填（可以重复，扫码遇到多个时软件会让你挑一个）；进价售价填现在的行情。',
        '店里已经有存货？进「库存」页，点「录入现有货物」，把眼下的库存数量录进去。'
            '这叫期初建账。',
      ]),
      const ManualNote(
        '期初录入的成本按 0 记，所以库存金额会偏低 —— 这是正常的。'
            '下次采购入库时，软件会用真实进价自动校准成本。帮助页的常见问题里也有解释。',
      ),
    ],
  ),
  ManualSection(
    id: 'purchase',
    title: '采购入库',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '进「采购入库」，一行填一个商品：选商品、填数量和进价。'
            '单价会按商品档案里存的进价预填，直接改就行。',
      ),
      const ManualParagraph(
        '当场给钱：在「立即付款」里选账户、填金额，可以填多条（一部分现金、一部分微信）。\n'
        '先赊着：选一个供应商，付款那部分少填或不填 —— 差额就记成你欠他的。',
      ),
      const ManualNote(
        '供应商一栏留空叫「散采」—— 散采必须当场结清，'
            '留下未付的金额软件会拦下来提醒你。',
        warning: true,
      ),
      const ManualParagraph('保存之后，库存立刻增加，单据页里多一张采购单。'),
    ],
  ),
  ManualSection(
    id: 'sale',
    title: '销售开单',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '进「销售开单」，一行填一个商品：选商品、填数量和售价。'
            '售价按商品档案预填，可以改（改的是这一单的价格，不会动商品档案）。',
      ),
      const ManualParagraph(
        '散客：客户一栏留空 —— 散客必须当场结清。\n'
        '熟客赊账：选一个客户（第一次可以先去「往来方」页新建），'
            '收款少填一点，差额就记成他欠你的，往来方页里看得到。',
      ),
      const ManualNote(
        '库存不够时，页面会出现红色提示，告诉你按「打开这一页时」的库存还差多少。'
            '提示不会拦你保存 —— 先货后款、来不及点货是常见的事，但数字对不上时要心里有数。',
        warning: true,
      ),
      const ManualParagraph('保存之后，库存立刻减少，单据页里多一张销售单。'),
    ],
  ),
  ManualSection(
    id: 'stock',
    title: '看库存',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '「库存」页每个商品一行，四列数字各有含义：\n'
        '「账面库存」—— 按单据算出来应该有多少。\n'
        '「在途」—— 已经开了送货单、还在路上的数量。\n'
        '「在店可售」—— 账面减在途，真正能卖的数。低库存提醒按这一列判断。\n'
        '「库存成本」—— 现在压在货上大概多少钱。',
      ),
      const ManualParagraph(
        '实物和账面对不上（丢了、送了、记错了）？点「录入现有货物」（已录过的话叫「重新清点」），'
            '把实际数量填进去，软件会算出差额记一笔盘盈盘亏，账马上对齐。',
      ),
    ],
  ),
  ManualSection(
    id: 'parties',
    title: '往来方与欠款',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '「往来方」页管两件事：客户欠你的（应收），你欠供应商的（应付）。'
            '点「新建往来方」，至少给他一个角色 —— 客户、供应商，或两者都是。',
      ),
      const ManualParagraph(
        '列表直接按欠款排好序，谁欠得多一眼看到。点一个人进去是他的全部流水，'
            '每一笔对应一张单子。',
      ),
      const ManualNote(
        '把不合作的往来方「停用」而不是删除 —— 他名下的欠款还在账上，'
            '停用后只是不再出现在开单的选择器里。',
      ),
    ],
  ),
  ManualSection(
    id: 'accounts',
    title: '账户',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '「账户」页管你的钱袋子：现金、微信收款、银行卡……每个账户一个余额。'
            '开单时的「立即付款 / 当场收款」都从这些账户里选。',
      ),
      const ManualParagraph(
        '期初余额在新建时填一次（现在一共有多少钱）。'
            '之后余额只随单据变动 —— 编辑账户时这一项是只读的，防止手改把账改乱。',
      ),
    ],
  ),
  ManualSection(
    id: 'documents',
    title: '单据',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '「单据」页是所有记账凭证的流水账。可以按「今天 / 本周 / 本月 / 最近 30 天 / 全部」'
            '筛时间，也可以按类型筛（采购、销售、收款、付款）。',
      ),
      const ManualParagraph(
        '点任意一行看这张单的详情：单号、对方、金额、已收付、还没收付多少、'
            '每一行货、以及这张单被收付过几次。详情页右上角可以复制单号。',
      ),
      const ManualNote(
        '还欠钱的单子，行右侧会显示橙色的「未收 ¥…」（欠供应商的是「未付」）——'
            '一眼就能看出哪张还没结清。',
      ),
      const ManualNote(
        '收付款时自动生成的那张「收款」/「付款」单**不会**混在默认列表里'
            '（免得同一笔交易看起来记了两遍）。想专门看它们，点上面的类型筛选。',
      ),
      const ManualNote(
        '单子提交后**不能修改** —— 账要留痕，这是故意设计的。'
            '录错了怎么办：库存记错了用「录入现有货物 / 重新清点」纠正；'
            '金额方向错了开一张相反方向的单子冲抵。',
        warning: true,
      ),
    ],
  ),
  ManualSection(
    id: 'settlement',
    title: '收款与付款',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '赊出去的账，对方来还钱的时候记在这里；欠供应商的货款，去付钱也记在这里。'
            '开单时就付清的不算 —— 那种在开单页直接填「已收款 / 已付款」。',
      ),
      const ManualParagraph('客户来还钱：'),
      const ManualSteps(<String>[
        '打开「单据」页，找到那张销售单 —— 还欠钱的行显示橙色的「未收 ¥…」。',
        '点这一行，打开单据详情。',
        '点「收款 ¥…」按钮。金额已经替你填好（就是还没收的部分）；对方只还了一部分，'
            '就把金额改小。',
        '选这笔钱进哪个账户（现金 / 微信 / 银行），点「确认收款」。',
      ]),
      const ManualNote(
        '收完之后：详情页的「已收 / 未收」会跟着变，收满了状态变成「已结清」，'
            '按钮也会消失；同时多出一张「收款」单留着备查。',
      ),
      const ManualParagraph('付钱给供应商：步骤一模一样，把「收款」换成「付款」。'),
      const ManualNote(
        '少收了钱：等对方补钱时再记一次收款就行。多收了钱：和对方商量退回，'
            '退回时按「付款」记一笔。账一旦记下就不能改，只能再记一笔冲回来。',
      ),
    ],
  ),
  ManualSection(
    id: 'export',
    title: '导出数据',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '五个地方各有一个导出按钮，导出内容不一样：\n'
        '「商品」页 —— 全部商品（含停用的）；\n'
        '「库存」页 —— 现在的库存账；\n'
        '「往来方」页 —— 全部往来方和欠款；\n'
        '「单据」页 —— 按当前筛选导出单据（先筛好再点）；\n'
        '往来方流水页 —— 这个人的全部流水。',
      ),
      const ManualSteps(<String>[
        '点导出按钮。',
        '弹出的提示里带着文件保存的完整路径，点「打开文件夹」直接看到文件。',
        '文件是 CSV 格式，双击就能用 Excel 或 WPS 打开，直接打印或发给会计。',
      ]),
      const ManualNote(
        'Excel 打开是乱码？不要双击文件 —— 打开 Excel，点「数据」→「从文本 / CSV」→'
            '选这个文件，编码选「65001: Unicode (UTF-8)」→ 加载。只有少数很旧版本的 Excel 才需要这样。',
      ),
      const ManualNote('导出的文件完全属于你：想给谁看、存哪里、存多少份，都由你决定。'),
    ],
  ),
  ManualSection(
    id: 'backup',
    title: '备份与恢复',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '每天第一次打开软件，神算子会自动把数据备份一份（还没有任何单据时不备份）。'
            '想马上备一份：概览页或设置页点「立即备份」。',
      ),
      const ManualParagraph(
        '备份放在数据文件夹旁边的「神算子备份」文件夹里，文件名带日期。'
            '最近的 30 天每天留一份；更早的每周留一份；你自己手动备的永不删除。',
      ),
      const ManualSteps(<String>[
        '恢复备份只有三步：先完全关闭神算子。',
        '打开「神算子备份」文件夹，挑一个日期合适的备份文件，'
            '复制到数据文件夹里，替换掉里面那个同名的数据文件。',
        '重新打开神算子 —— 数据回到备份那个时刻。',
      ]),
      const ManualNote(
        '诚实地说：备份和数据在同一块硬盘上，它防的是「删错了、操作错了」，'
            '防不了整块硬盘坏掉。真正重要的数据，请偶尔把备份文件夹整个拷一份到 U 盘。',
        warning: true,
      ),
    ],
  ),
  ManualSection(
    id: 'settings',
    title: '设置',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '「设置」页只有几样东西，都改完立即生效，不需要保存按钮：\n'
        '「界面文字大小」—— 五档，旁边有「恢复默认大小」。\n'
        '「店名」—— 最多 20 个字，显示在概览页顶部。\n'
        '「数据位置」「备份位置」—— 各带一个打开文件夹的按钮，随时去看那里有什么。\n'
        '「多设备同步」—— 还在开发中，做好了这里会有开关。',
      ),
    ],
  ),
  ManualSection(
    id: 'faq',
    title: '常见问题',
    blocks: <ManualBlock>[
      const ManualQa(
        '数据到底存在哪里？',
        '在你第一次启动时自己选的那个文件夹里；备份在它旁边的「神算子备份」文件夹。'
            '设置页里能看到两个位置的确切路径，点按钮可以直接打开。',
      ),
      const ManualQa(
        '换电脑怎么办？',
        '把数据文件夹和「神算子备份」文件夹一起拷到新电脑，'
            '装好神算子后第一次启动时选拷过来的那个文件夹。数据原样都在。',
      ),
      const ManualQa(
        '期初录入后库存金额怎么是 0？',
        '期初成本按 0 记是有意的 —— 眼下说不清这批货的进价，就不猜。'
            '下次采购同样的商品时，软件会用真实进价把成本校准过来。',
      ),
      const ManualQa(
        '数量或金额填错了能改吗？',
        '单子不能改（账要留痕）。库存错了用「录入现有货物 / 重新清点」对齐；'
            '方向反了开一张相反方向的单子冲抵。',
      ),
      const ManualQa(
        '「散客」「散采」是什么意思？',
        '没有留名字的一次性买卖：散客是来买东西的陌生人（必须当场结清），'
            '散采是没留名的进货（同样必须当场结清）。要赊账，就得先在往来方里建档。',
      ),
      const ManualQa(
        '每次打开都有蓝色提示框？',
        '只会第一次。点「更多信息」→「仍要运行」后，Windows 就记住了。'
            '如果每次都弹，说明你每次都在换文件夹运行软件。',
      ),
      const ManualQa(
        '想删掉这个软件？',
        '直接删掉软件文件夹就是删掉程序 —— 不写注册表、不留垃圾。'
            '数据在你自己选的文件夹里，删不删由你；删之前建议把备份拷到 U 盘。',
      ),
    ],
  ),
  ManualSection(
    id: 'feedback',
    title: '反馈与版本',
    blocks: <ManualBlock>[
      const ManualParagraph(
        '遇到问题、有想不通的地方，两条路都能找到我们：\n'
        'GitHub（推荐，能贴截图）：https://github.com/xgopilot/shensuanzi/issues\n'
        '邮箱：cedarandjoy@163.com\n'
        '反馈时请附上版本号（本页最下方，「帮助」页最下方也有），能帮我们更快定位。',
      ),
      ManualParagraph('你正在使用的版本：$versionLine。'),
      const ManualParagraph(
        '本手册也可以在软件外查看：软件文件夹里有一份「用户手册.html」，'
            '双击用浏览器打开，可打印。软件内则从「帮助」页最上方进入。',
      ),
    ],
  ),
];

/// 手册里**不允许出现**的开发词汇 —— 「不给开发者看」是可执行的门禁，不是自觉。
///
/// 原则：用户不需要知道实现。 「数据文件」不说「数据库」；「软件」不说「应用架构」。
const List<String> manualForbiddenDevTerms = <String>[
  'Flutter',
  'Dart',
  'schema',
  'Schema',
  'API',
  'UI',
  'DAO',
  '编译',
  '构建',
  '依赖',
  '游标',
  '白名单',
  '框架',
  '数据库',
  '进程',
  '参数',
];

/// 扫全部文本，返回命中的开发词汇（**空列表 = 干净**）。
///
/// 测试、自检、HTML 生成脚本三方都调它 —— 任何一方红都说明手册混进了开发内容。
List<String> assertManualIsUserFacing(List<ManualSection> sections) {
  final List<String> hits = <String>[];
  for (final ManualSection section in sections) {
    final List<String> texts = <String>[
      section.title,
      for (final ManualBlock block in section.blocks)
        switch (block) {
          ManualParagraph(:final text) => text,
          ManualNote(:final text) => text,
          ManualSteps(:final items) => items.join('\n'),
          ManualQa(:final question, :final answer) => '$question\n$answer',
        },
    ];
    for (final String text in texts) {
      for (final String term in manualForbiddenDevTerms) {
        if (text.contains(term)) hits.add('${section.id}: $term');
      }
    }
  }
  return hits;
}
