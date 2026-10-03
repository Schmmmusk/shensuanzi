/// 左侧常驻导航的**结构**（`docs/ui_principles.md` §八）。
///
/// ## 为什么结构要放在纯 Dart 包
///
/// 导航本身是「画出来的」，但**关于它的几条原则**是硬规则：
///
/// - 所有功能都有**常驻可见的入口**
/// - 每个入口都**带文字标签**（不能只有图标）
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

  /// 界面上的文字。**必填且非空** —— 只有图标的入口对中老年用户等于不存在
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

  /// 仅图标（只在「200% 缩放 + 小窗口」时自动启用）
  static const double iconOnlyWidth = 60;

  /// 每一项的高度。按 `docs/ui_principles.md` §二：点击区 ≥ 44，表格行 48 —— 取 48
  static const double itemHeight = 48;

  /// 选中的左侧竖条宽度（高亮三重信号之一）
  static const double indicatorWidth = 3;

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
  /// [iconOnlyWidth]（那时才轮到「仅图标」，且这是自动兜底不是默认）。
  static double widthFor({double scale = 1.0, bool compact = false}) {
    final double base = compact ? compactWidth : expandedWidth;
    final double scaled = base * scale;
    return scaled < iconOnlyWidth ? iconOnlyWidth : scaled;
  }
}
