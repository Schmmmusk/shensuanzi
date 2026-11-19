/// 左侧常驻导航的**结构**（`docs/ui_principles.md` §八）。
///
/// ## 为什么结构要放在纯 Dart 包
///
/// 导航本身是「画出来的」，但**关于它的几条原则**是硬规则：
///
/// - 所有功能都有**常驻可见的入口**
/// - 每个入口的**文字标签是常态**（只有图标的入口对中老年用户等于不存在）；
///   仅当窗口窄到**放不下文字**时退为「图标 + 悬停提示」，判据见 [AppNavigation.navLayout]
/// - 分组清晰、顺序固定；高频动作在最上面
/// - 开单页是**沉浸模式**（不显示面包屑）
///
/// 这些能用 `dart test` 钉住，就不必等界面截图靠人眼确认。
/// Flutter 侧只做两件事：**把 [iconKey] 映射成 `IconData`**、摆位置。
///
/// ## 图标为什么存字符串
///
/// `IconData` 是 Flutter 的类型，纯 Dart 包不能依赖它。
/// 所以这里存 Material 图标**名**，由 Flutter 侧查表 —— 表里查不到时
/// 用兜底图标，**不会因为写错一个名字就崩**。
library;

/// 导航分组。顺序即显示顺序。
enum NavSection {
  /// 落地页：回答「我的数据在哪 / 生意怎么样」
  home('首页'),

  /// 高频动作：每天几十次，放最上面形成肌肉记忆
  quick('高频动作'),

  /// 数据查询：按「找什么」组织，符合日常语言
  data('数据查询'),

  /// 系统：低频，放底部
  system('系统');

  const NavSection(this.label);

  final String label;
}

/// 一个导航项
class NavDestination {
  const NavDestination({
    required this.id,
    required this.label,
    required this.iconKey,
    required this.section,
    this.immersive = false,
  });

  /// 稳定标识（用于选中状态、测试、后续的路由键）—— **不要用 label 当键**
  final String id;

  /// 界面上的文字。**必填且非空** —— 只有图标的入口对中老年用户等于不存在。
  ///
  /// ⚠️ 唯一例外：窗口窄到放不下文字时（[AppNavigation.navLayout] 的 `iconOnly`），
  /// 界面上不画它，但必须**放进 `Tooltip`** —— 悬停/长按仍能读到。
  final String label;

  /// Material 图标名（如 `dashboard`）；Flutter 侧查表映射
  final String iconKey;

  final NavSection section;

  /// **沉浸模式**：占用整个右侧，不显示面包屑与工具栏。
  ///
  /// 只用于开单页 —— 开单是**连续的动作流程**，不是「浏览一个列表」。
  /// 左侧导航仍然显示，用户随时能跳走（比如发现商品没建档）。
  final bool immersive;

  @override
  String toString() => 'NavDestination($id, $label)';
}

/// 默认导航结构
class AppNavigation {
  AppNavigation._();

  /// 展开宽度（默认）
  static const double expandedWidth = 220;

  /// 紧凑模式（高级选项，默认关闭）
  static const double compactWidth = 160;

  /// 仅图标宽度 —— 窄窗口下的形态之一。
  ///
  /// ✅ **2026-11-14 起真的有仅图标渲染**（纪律 17 更正，2026-11-19）：
  /// `app_shell.dart` 的 `_NavItem` 里有 `if (iconOnly)` 分支 ——
  /// **居中图标 + `Tooltip(目的地名)`**，选中态仍靠左侧竖条与底色表达。
  /// 这里从前写着「`_NavColumn` 没有『仅图标』的渲染实现，真退到 60 是一列省略号」，
  /// 那是 2026-11-14 之前的状态，已作废。
  ///
  /// 触发条件见 [navLayout]：放不下文字时才退到这一档。
  static const double iconOnlyWidth = 60;

  /// 导航列右侧那条**分割线**的粗细（逻辑像素）。
  ///
  /// ## 三个数都是量出来的（2026-11-18，用户两次反馈「窄屏看不出来」）
  ///
  /// | 时点 | 粗细 | 实际画出来的颜色 | 对 #FAFAFA 的对比度 |
  /// |---|---|---|---|
  /// | 最初 | 1 | `#C2C7CF`（`outlineVariant`） | **1.63 : 1** |
  /// | 第一次改（只加粗） | 2 | 同上 | 1.63 : 1 —— 加粗不改色，白改 |
  /// | 现在 | **3** | `#73777F`（`outline`） | **4.30 : 1** |
  ///
  /// ⚠️ **第一次的判据是错的**：当时读代码注释（「`dividerColor` = #73777F」）
  /// 就下了「颜色够深、只是太细」的结论。后来**从用户截图上逐像素取色**才发现，
  /// M3 里 `VerticalDivider` 实际吃的是 `outlineVariant` = **#C2C7CF**，
  /// 与背景 1.63 : 1 —— 远低于 WCAG 1.4.11 对非文字 UI 的 3 : 1。
  /// 教训：**别信注释里的颜色，去截图上取像素**（用户两次反馈「还看不出来」就是证据）。
  ///
  /// ## ⚠️ `width` 与 `thickness` 必须一起设
  ///
  /// `VerticalDivider` 的实现是 `SizedBox(width) → Center → Container(width: thickness)`，
  /// **`width` 不一起放开，`thickness` 会被父级夹回**。所以这条线统一由
  /// `lib/src/ui/nav_divider.dart` 的 `NavDivider` 造 —— 两个参数一起给，颜色也在那儿定。
  static double dividerThickness({required bool iconOnly}) => iconOnly ? 3 : 1;

  /// 每一项的高度。按 `docs/ui_principles.md` §二：点击区 ≥ 44，表格行 48 —— 取 48
  static const double itemHeight = 48;

  /// 选中的左侧竖条宽度（高亮三重信号之一）
  static const double indicatorWidth = 3;

  /// 导航列最多占窗口的多少（2026-10-19 定的上限，2026-11-14 保留作兜底）。
  static const double maxShareOfWindow = 0.4;

  /// 最长标签的字数（「销售开单」「采购入库」）—— 列宽按它算内容需求。
  ///
  /// 改导航结构时**必须同步**：加一个比 4 字更长的入口，这里不改就会被截断。
  /// `navigation_test` 会对着 [destinations] 的实际标签长度校验。
  static const int labelMaxChars = 4;

  /// 标签的基准字号（导航项没有显式 `fontSize` ⇒ 主题 `bodyMedium` = 14）。
  static const double labelFontBase = 14;

  /// 图标基准尺寸（与 `_NavItem` 的图标大小同源，那里用 `scaledOf(context, iconBase)`）。
  static const double iconBase = 20;

  /// 行内**不随缩放**的固定占位：左竖条 3 + 间距 13 + 间距 12。
  static const double chromeFixed = indicatorWidth + 13 + 12;

  /// 一个都没选时落到哪一项
  static const String fallbackId = 'overview';

  /// **全部入口**。顺序 = 显示顺序。
  ///
  /// ⚠️ 增删这里就等于增删界面入口 —— 别用条件编译藏入口。
  static const List<NavDestination> destinations = <NavDestination>[
    // ---- 首页 ----
    NavDestination(
      id: 'overview',
      label: '概览',
      iconKey: 'dashboard',
      section: NavSection.home,
    ),

    // ---- 高频动作（每天几十次）----
    NavDestination(
      id: 'sale',
      label: '销售开单',
      iconKey: 'point_of_sale',
      section: NavSection.quick,
      immersive: true,
    ),
    // §AP：**送货**与销售 / 采购并列，**不做模式开关** ——
    // 开关会让用户每次问「我该选哪个」（`ui_principles.md` §1.1「不愿意思考」）
    NavDestination(
      id: 'delivery',
      label: '送货',
      iconKey: 'local_shipping',
      section: NavSection.quick,
      immersive: true,
    ),
    NavDestination(
      id: 'purchase',
      label: '采购入库',
      iconKey: 'inventory_2',
      section: NavSection.quick,
      immersive: true,
    ),

    // ---- 数据查询（按「找什么」组织）----
    NavDestination(
      id: 'products',
      label: '商品',
      iconKey: 'category',
      section: NavSection.data,
    ),
    NavDestination(
      id: 'stock',
      label: '库存',
      iconKey: 'warehouse',
      section: NavSection.data,
    ),
    NavDestination(
      id: 'documents',
      label: '单据',
      iconKey: 'description',
      section: NavSection.data,
    ),
    NavDestination(
      id: 'parties',
      label: '往来方',
      iconKey: 'people',
      section: NavSection.data,
    ),
    NavDestination(
      id: 'accounts',
      label: '账户',
      iconKey: 'account_balance_wallet',
      section: NavSection.data,
    ),

    // ---- 系统（低频）----
    NavDestination(
      id: 'settings',
      label: '设置',
      iconKey: 'settings',
      section: NavSection.system,
    ),
    NavDestination(
      id: 'help',
      label: '帮助',
      iconKey: 'help_outline',
      section: NavSection.system,
    ),
  ];

  /// 某一组的入口（顺序与 [destinations] 一致）
  static List<NavDestination> of(NavSection section) => <NavDestination>[
    for (final NavDestination destination in destinations)
      if (destination.section == section) destination,
  ];

  /// 按 id 找入口；找不到返回 `null`（**不抛** —— 旧配置里的 id 可能已不存在）
  static NavDestination? byId(String? id) {
    for (final NavDestination destination in destinations) {
      if (destination.id == id) return destination;
    }
    return null;
  }

  /// 启动时的默认选中项：找不到就退回第一项（而不是让界面空白）
  static NavDestination initial([String? id]) =>
      byId(id) ?? byId(fallbackId) ?? destinations.first;

  /// 拖动窗口时导航该多宽。缩放系数由设置页提供（默认 1.0）。
  ///
  /// 按 §八：**宽度按比例缩放，但文字不换行**；窗口再窄也不低于
  /// [iconOnlyWidth]（那只是兜底下限，见该常量的更正）。
  ///
  /// ⚠️ **界面上别直接调它** —— 实际列宽走 [navWidth]（它按内容增长、还有窗口占比上限）。
  /// 本方法保留是因为「1.0 档的基准宽」仍是列宽的锚点（[navWidth] 从它出发）。
  static double widthFor({double scale = 1.0, bool compact = false}) {
    final double base = compact ? compactWidth : expandedWidth;
    final double scaled = base * scale;
    return scaled < iconOnlyWidth ? iconOnlyWidth : scaled;
  }

  /// 导航列里的**内容需求宽**（逻辑像素）：左竖条 + 间距 + 图标 + 4 字标签。
  ///
  /// 每一项的横向占位在 `lib/src/ui/app_shell.dart` 的 `_NavItem` 里是写死的
  /// （`indicatorWidth` / 13 / 图标 / 12 / 文字），本方法**必须与它逐项对应** ——
  /// 改了那边忘了这边，「列宽按内容算」就退化成拍脑袋。
  static double contentWidthFor({required double scale}) =>
      chromeFixed + iconBase * scale + labelMaxChars * labelFontBase * scale;

  /// **导航列实际宽度**（2026-10-19 定上限；**2026-11-14 改成按内容增长**）。
  ///
  /// ## 2026-10-19 那次的病根
  ///
  /// [widthFor] 只保证「不低于 60」，**没有上限**：`220 × 2.0 = 440`，
  /// 而那时窗口只有 ~480 逻辑像素 ⇒ 导航吃掉 92%，工作区只剩一条缝。
  /// ⇒ 加了「不超过可用宽度的 [maxShareOfWindow]」。
  ///
  /// ## 2026-11-14 真机实测：上限没兜住，因为**空列被一起放大了**
  ///
  /// 系统 200% + 应用「超大」时，列宽 440 逻辑、**标签只要 143**（实测 ink 宽度），
  /// 列内 68% 是空的，导航仍吃掉 35% 横向空间，工作区只剩 65%
  /// （用户原话：「左侧导航栏占据约 3~4 成横向空间」）。根因不是上限太低，
  /// 而是 `基准宽 × 缩放` 这条式子把「本来就空着的余量」也一起放大了。
  ///
  /// ## 现在的规则（裁定「甲」）
  ///
  /// ```
  /// 列宽 = widthFor(1.0) + (内容需求(scale) − 内容需求(1.0))
  /// ```
  ///
  /// 即 **余量固定、只有内容那部分随字号增长**：1.0 档仍是 220（观感不变），
  /// 2.0 档 220 → 296（窗口 1247 逻辑宽时占比 35% → 24%）。
  /// 仍保留 [maxShareOfWindow] 上限与 [iconOnlyWidth] 下限作兜底。
  ///
  /// ⚠️ [scale] 必须传**生效缩放**（`uiScaleOf(context)` = max(系统, 应用)），
  /// 不能传应用档位 —— 否则「系统 200% + 应用 100%」时字是 2 倍、列宽按 1 倍算
  /// （§CV·八十五 的判据：尺寸从环境取，不层层传参）。
  ///
  /// 只要宽度，用 [navWidth]；**要摆界面用 [navLayout]**（它还会告诉你「该不该退成仅图标」）。
  static double navWidth({
    required double scale,
    required double availableWidth,
    bool compact = false,
  }) => navLayout(
    scale: scale,
    availableWidth: availableWidth,
    compact: compact,
  ).width;

  /// **导航列该多宽 + 要不要退成「仅图标」**（2026-11-14 用户裁定「仅图标可以实现」）。
  ///
  /// [width] 的算法见 [navWidth]。这里多回答一个问题：
  /// **窗口窄到连一个标签都装不下时**（`40% 上限 < 内容需求`），与其画一排省略号，
  /// 不如退成「图标 + 悬停提示」—— 那是 [iconOnly] 为 `true` 的情形。
  ///
  /// 判据是**可计算的**，不是感觉：
  /// - 1247 逻辑宽 + 2.0 档 ⇒ 上限 498 > 内容 180 ⇒ 正常（带文字）；
  /// - 480 + 2.0 档 ⇒ 上限 192 > 180 ⇒ 仍是文字（挤但够）；
  /// - 420 + 2.0 档 ⇒ 上限 168 < 180 ⇒ **仅图标**。
  ///
  /// ⚠️ 仅图标是**兜底**，不是默认形态：`docs/ui_principles.md` §1.1 的
  /// 「入口必须带文字」仍然成立，退化的前提是「真的放不下」。所以除了图标，
  /// 每一项还必须带 `Tooltip`（鼠标悬停/长按可读），见 `app_shell.dart` 的 `_NavItem`。
  static ({double width, bool iconOnly}) navLayout({
    required double scale,
    required double availableWidth,
    bool compact = false,
  }) {
    final double base = widthFor(compact: compact);
    final double need = contentWidthFor(scale: scale);
    final double cap = availableWidth * maxShareOfWindow;

    if (cap < need) {
      // 装不下标签 ⇒ 仅图标。宽度按「竖条 + 间距 + 图标 + 一点余量」算，
      // 且**不再受 40% 上限约束**：这里是在「工作区几乎没地方」和
      // 「图标被裁掉一半」之间取舍，选前者（与旧代码「退到 60」同一立场）。
      final double iconOnly = chromeFixed + iconBase * scale + 8;
      return (
        width: iconOnly < iconOnlyWidth ? iconOnlyWidth : iconOnly,
        iconOnly: true,
      );
    }

    final double grown = base + (need - contentWidthFor(scale: 1.0));
    final double wanted = grown < iconOnlyWidth ? iconOnlyWidth : grown;
    return (width: wanted <= cap ? wanted : cap, iconOnly: false);
  }
}
