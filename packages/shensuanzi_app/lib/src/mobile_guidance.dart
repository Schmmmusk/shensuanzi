/// 手机端「保留入口 + 点击引导」的文案（C2·§CC 裁定三 / reply.md 修订）。
///
/// ## 为什么是「引导」不是「隐藏」
///
/// `Agents.md 4.3`：所有功能有**常驻可见入口** —— 隐藏按钮会让用户以为
/// 软件坏了。手机端主数据禁建是**协议正确性要求**（本机建的 id 推到主机
/// 必被外键拒绝），但入口必须还在：点击后弹本文件的引导，给出**明确的下一步**。
///
/// ## 写权限边界（§CC·裁定四）
///
/// 手机端 UI 不写九张业务表；唯一写入方是 pull。主库废弃但保留
/// （v1 Android 未发布 ⇒ 无历史数据，不迁移）—— 详见 `MirrorView` 类文档。
library;

/// 引导话题（四处入口：往来方新建、往来方编辑、商品新建、期初录入）
enum MobileGuideTopic { newParty, editParty, newProduct, openingStock }

/// 引导对话框标题
String mobileGuideTitle(MobileGuideTopic topic) => '这一步在电脑上做';

/// 引导对话框正文 —— **判定与文案都在这里，UI 只取值**（不造句铁律）。
///
/// 每条都按同一结构：说清「为什么不行」→「去哪做」→「做完怎么同步」。
String mobileGuideMessage(MobileGuideTopic topic) => switch (topic) {
  MobileGuideTopic.newParty =>
    '手机上不建客户 / 供应商档案。\n\n'
    '请到电脑上打开神算子，在「往来方」页新建；'
    '然后手机点「立即同步」，这里就能选到了。',
  MobileGuideTopic.editParty =>
    '往来方资料的修改在电脑上做。\n\n'
    '请到电脑上打开神算子，在「往来方」页改好后，'
    '手机点「立即同步」就能看到最新的。',
  MobileGuideTopic.newProduct =>
    '手机上不建商品档案。\n\n'
    '请到电脑上打开神算子，在「商品」页新建；'
    '然后手机点「立即同步」，这里就能选到了。',
  MobileGuideTopic.openingStock =>
    '期初录入在电脑上做。\n\n'
    '请到电脑上打开神算子，在「库存」页点「录入现有货物」一次记完；'
    '手机点「立即同步」后数字就对上了。',
};

/// 镜像空状态的正文（§CC 裁定六：镜像还没拉到数据时，别让用户以为数据丢了）。
///
/// [what] = 页面上这些东西的名字（如「商品列表」「往来方」）。
String mirrorEmptyMessage(String what) =>
    '$what 还在从电脑同步 —— 请稍等，或到「我的 → 设置」点「立即同步」。\n'
    '如果电脑上也还没有，请先在电脑上建好。';
