/// 应用启动流程。
///
/// ```text
/// 启动 → AppEnvironment.detect()
///   → service.existing()                 // 配置里的位置现在还能用吗
///        ├─ 能 → 直接开库 → 主界面
///        └─ 不能 → 弹「选择数据存放位置」→ 开库 → 主界面
/// ```
///
/// 为什么 `existing()` 要**重跑一遍校验**而不是信配置：用户可能把数据目录
/// 搬走了、盘符变了、标记文件被删了 —— 配置里「有路径」不等于「能用」。
/// 详见 `docs/data_directory.md` §六。
///
/// ⚠️ **打开数据库在这里发生**（而不是在对话框里）：对话框只管「路径可用」，
/// 库能不能建起来是下一步的事，两件事分开才能把失败原因说清楚。
library;

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'folder_picker.dart';
import 'ui/app_shell.dart';
import 'ui/data_directory_dialog.dart';

class ShensuanziApp extends StatefulWidget {
  /// `pickDirectory` 的默认值**就在参数上就地给出**（真实实现）——
  /// 不能留 `null` 再在 `build` 里兜底：那样「忘了传」会变成「运行时才炸」。
  /// 就地给默认值，类型系统保证它非空，现有调用点
  /// `runApp(const ShensuanziApp())` 一个字都不用改。
  const ShensuanziApp({
    super.key,
    this.pickDirectory = pickFolderFromSystem,
    this.configStore,
  });

  /// 选文件夹。**启动流程的两个系统交互之一** —— 它会真弹系统框，
  /// 不注入的话 widget 测试直接挂死（`docs/reply_review.md` §V）。
  final Future<String?> Function() pickDirectory;

  /// 配置读写（另一个系统交互）。`null` = 用 `%APPDATA%\神算子\config.json`。
  ///
  /// 为什么它不像 [pickDirectory] 那样有编译期默认值：真实位置依赖**运行时环境**
  /// （`AppEnvironment.detect()`），没法写进参数默认值 —— 所以用 `null` 表示
  /// 「用默认的」，在 `_ShensuanziAppState._configStore` 里 `??` 解析。
  /// 两者表达的是同一件事：**不传就用生产行为**（`docs/reply_review.md` §W）。
  ///
  /// ⚠️ **widget 测试必须把它指向沙箱**：否则测试会读、甚至**改写**开发者真实的
  /// 配置文件 —— 下次真机启动就会开到测试用的临时目录（`docs/testing.md` §K）。
  final AppConfigStore? configStore;

  @override
  State<ShensuanziApp> createState() => _ShensuanziAppState();
}

class _ShensuanziAppState extends State<ShensuanziApp> {
  /// 真机事实只探测一次（盘符 / 环境变量）。
  ///
  /// **刻意不注入、保持真实**：启动流程要验证的恰恰是「真实机器 + 沙箱配置」
  /// 下的行为；把机器也伪造了，就变成「在假机器上跑假配置」，
  /// 每个场景还得自己造一套盘符（`docs/reply_review.md` §W 二）。
  final AppEnvironment _environment = AppEnvironment.detect();

  /// 配置读写：测试传沙箱，生产用 `%APPDATA%`。
  late final AppConfigStore _configStore =
      widget.configStore ?? AppConfigStore.forEnvironment(_environment);

  /// 数据目录服务。**不注入** —— [configStore] 指向沙箱之后，
  /// 建目录、写标记、开库全都走真实路径，测出来的才是真的。
  late final DataDirectoryService _service = DataDirectoryService(
    environment: _environment,
    configStore: _configStore,
  );

  /// ⚠️ **弹对话框必须用这个 key 的 context，不能用本 State 的 `context`。**
  ///
  /// 本 State 的 `context` 在 `MaterialApp` **上面**（`MaterialApp` 是本 widget
  /// 自己 build 出来的）。拿它去 `showDialog`，会沿祖先链找不到
  /// `MaterialLocalizations`（它由 `MaterialApp` 提供），直接抛
  /// `No MaterialLocalizations found.` —— 而且**对话框根本不出现**，
  /// 界面停在兜底页，看起来像「按钮没反应」。
  ///
  /// `navigatorKey.currentContext` 是 `Navigator` 的 context，在 `MaterialApp`
  /// **下面**，正是「从外面弹对话框」的标准做法。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  DataLocation? _location;

  /// 打开着的数据库；成功后一直持有，供后续功能页使用
  Db? _db;

  /// 商品建档服务（数据库打开成功才有）
  ProductService? _products;

  /// 采购开单服务（同一数据库）
  PurchaseService? _purchases;

  /// 店内销售开单服务（同一数据库）
  SaleService? _sales;

  /// 账户建档服务（同一数据库）
  AccountService? _accounts;

  /// 往来方最小建档服务（供应商 / 客户选择器的「新建」共用）
  PartyService? _parties;

  /// 开库失败的原因（含「怎么办」）
  String? _dbFailure;

  @override
  void initState() {
    super.initState();
    // 首帧之后再弹对话框：此时才有可用的 Navigator
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }

  Future<void> _prepare() async {
    final DataLocation? existing = _service.existing();
    if (existing != null) {
      _openDatabase(existing);
      return;
    }
    if (!mounted) return;

    // 用 Navigator 的 context（见 `_navigatorKey` 的注释）
    final BuildContext? dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    final DataLocation? chosen = await showDataDirectoryDialog(
      dialogContext,
      model: DataDirectoryDialogModel(_service),
      // 注入点：生产环境是系统选择器，测试里是桩
      pickDirectory: widget.pickDirectory,
    );
    if (chosen == null) return; // 用户退出了 —— 界面会停在「需要选择位置」
    _openDatabase(chosen);
  }

  void _openDatabase(DataLocation location) {
    try {
      final Db db = _service.open(location);
      setState(() {
        _location = location;
        _db = db;
        _products = ProductService(db);
        _purchases = PurchaseService(
          engine: RuleEngine(db),
          queries: QueryDao(db),
        );
        _sales = SaleService(
          engine: RuleEngine(db),
          queries: QueryDao(db),
        );
        _accounts = AccountService(AccountDao(db));
        _parties = PartyService(PartyDao(db));
        _dbFailure = null;
      });
    } catch (error) {
      setState(() {
        _location = location;
        _db = null;
        _products = null;
        _purchases = null;
        _sales = null;
        _accounts = null;
        _parties = null;
        _dbFailure = '数据文件打不开（$error）。'
            '如果这个文件夹在 U 盘或网盘里，请换到本机磁盘上的文件夹。';
      });
    }
  }

  /// 主题只建一次（字体栈依赖平台，平台不会中途变）
  late final ThemeData _theme = _buildTheme();

  ThemeData _buildTheme() {
    final bool isWindows = _environment.isWindows;
    return ThemeData(
      // ⚠️ **中文字体必须显式指定**：Flutter 自带的 Roboto 没有中文字形，
      // Windows 上会兜到**宋体**，看着像「外国软件没适配」（`docs/ui_principles.md` §二）。
      // 字体栈由纯 Dart 的 `AppTypography` 决定（`dart test` 覆盖），这里只取值。
      fontFamily: AppTypography.primaryFamilyFor(isWindows: isWindows),
      fontFamilyFallback: AppTypography.fallbackFor(isWindows: isWindows),
      // 低饱和蓝作主色：红色只留给错误与告警（`docs/ui_principles.md` §二）
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FA8)),
      scaffoldBackgroundColor: const Color(0xFFFAFAFA),
      useMaterial3: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '神算子',
      debugShowCheckedModeBanner: false,
      // 启动流程要在首帧之后弹对话框，用它的 context（见 `_navigatorKey`）
      navigatorKey: _navigatorKey,
      theme: _theme,
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (_dbFailure != null) {
      return _StartupPage(
        message: _dbFailure!,
        actionLabel: '重新选择位置',
        onAction: () async {
          setState(() => _dbFailure = null);
          _location = null;
          _db = null;
          await _prepare();
        },
      );
    }

    final DataLocation? location = _location;
    if (location == null) {
      return _StartupPage(
        message: '需要一个文件夹来存放数据，才能开始使用。',
        actionLabel: '选择数据存放位置',
        onAction: _prepare,
      );
    }

    return AppShell(
      dataDirectory: location.directory,
      backupDirectory: location.backupDirectory,
      schemaVersion: location.marker.schemaVersion,
      databaseReady: _db != null,
      products: _products,
      purchases: _purchases,
      sales: _sales,
      accounts: _accounts,
      parties: _parties,
    );
  }
}

/// 还没进入主界面时的过渡页（选位置 / 开库失败）。
///
/// 刻意**不做**欢迎页、店名输入、账户预设 —— 那些按 `docs/reply.md` §五
/// 放到第 10 天回补。
class _StartupPage extends StatelessWidget {
  const _StartupPage({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            // 常驻可见的文字按钮，不用图标（`docs/ui_principles.md` §1.1）
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    ),
  );
}
