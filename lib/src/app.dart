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
///
/// ## 备份接线（`docs/reply_review.md` §AE）
///
/// - 库打开成功后**异步**触发一次自动备份检查（§AE-3 每天首次启动）；
///   **失败完全静默** —— 用户开软件是要开单的，不是来读报错。
///   「一直没备份成功」由概览页橙卡 + 设置页红字呈现（两层机制）。
/// - 自动与手动**共用同一个 `BackupService`**（同一个单飞锁）——
///   启动 5 秒后用户就点「立即备份」也不会跑两遍（§AE 遗漏 3）。
/// - UI 只拿到**算好的文案**（`backupStatusLine` / `backupReminder`）：
///   「要不要提醒」的判定只在 `needsBackupAttention` 一处。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

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
  ///
  /// ⚠️ **全应用唯一的配置入口**（台账 §AI-1）：启动加载、设置页读写、
  /// 传给 AppShell 的都必须是**这一个解析后的实例** ——
  /// 绝不把可空的 `widget.configStore` 往下传（2026-09-29 真机踩坑：
  /// 生产里它是 null，设置页因此在真机上永远是占位页）。
  late final AppConfigStore _configStore =
      widget.configStore ?? AppConfigStore.forEnvironment(_environment);

  /// 数据目录服务。**不注入** —— [configStore] 指向沙箱之后，
  /// 建目录、写标记、开库全都走真实路径，测出来的才是真的。
  late final DataDirectoryService _service = DataDirectoryService(
    environment: _environment,
    configStore: _configStore,
  );

  /// 最小日志（§AG-5 裁定）。
  ///
  /// **跟随 [configStore] 的位置**（`%APPDATA%\神算子\日志\`）——
  /// 于是测试把 `configStore` 指向沙箱时，日志也自动进沙箱，
  /// **不会往开发者真实的 `%APPDATA%` 里写文件**（`docs/testing.md` §K 的红线）。
  late final AppLog _log = AppLog.besideConfig(_configStore);

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

  /// 送货服务（同一数据库）—— 批次 1b
  DeliveryService? _deliveries;

  /// 账户建档服务（同一数据库）
  AccountService? _accounts;

  /// 往来方最小建档服务（供应商 / 客户选择器的「新建」共用）
  PartyService? _parties;

  /// 规则引擎（库存页期初录入入口用；与各服务同库）
  RuleEngine? _engine;

  /// 核销服务（单据详情页的收款 / 付款，批次 1a）
  SettlementService? _settlements;

  /// 聚合查询（库存页 + 备份的空库判定共用同一个 DAO）
  QueryDao? _queries;

  /// 备份服务（库打开成功才有；自动与手动共用它，于是共用单飞锁）
  BackupService? _backup;

  /// 主机同步服务（§AH · AH-A）。**库打开成功才有** —— 它要拿 `Db` 跑
  /// `SyncServer`，而配对文件 `host.json` 放数据目录。
  ///
  /// 注意它**不是** `AppBootstrap` 那种启动注入点：它只在设置页被用户
  /// 显式开关，**启动时不自动bind端口**（§AH 遗漏 5）。
  HostServiceController? _hostService;

  /// 导出服务（§AF；只依赖导出目录，不碰数据库）
  ExportService? _exports;

  /// 备份目录里最新的一份（`null` = 从未备份）。
  /// **启动与每次备份后重读**，不在 build 里列目录（那是 IO）
  BackupFileName? _lastBackup;

  /// 最近一次备份尝试的失败原因（`null` = 没失败）。
  ///
  /// §AE 遗漏 2：**失败不能静默** —— 只看「上次成功是什么时候」的话，
  /// 目录半年不可写、用户却一直看到「昨天备份过」的红字以外一切正常。
  /// 不持久化：每次启动重试，成功了就自动清零。
  String? _backupError;

  /// 库里有没有单据（§AE 遗漏 1：空库不自动备份、也不提醒）
  bool _hasDocuments = false;

  /// 当前配置（设置页修改后经 [onConfigChanged] 热应用）
  AppConfig _config = const AppConfig();

  /// 开库失败的原因（含「怎么办」）
  String? _dbFailure;

  /// 库的**真实数据格式版本**（`PRAGMA user_version`）。
  ///
  /// ⚠️ 不能用 `location.marker.schemaVersion`：老用户的标记还是 v1，
  /// 但 `Db.open` 已把库迁到 v2 —— 备份文件名（AE-4）与概览文案标的是
  /// 「备份内容是什么格式」，必须跟数据走。`0` = 库还没打开成功（此时没有
  /// 备份，显示回退到标记版本）。
  int _schemaVersion = 0;

  @override
  void initState() {
    super.initState();
    // 配置读一次（设置页修改会走 onConfigChanged 更新本状态）。
    // ⚠️ 必须用解析后的 `_configStore`：`widget.configStore` 在生产里是 null，
    // 用它读会永远拿到默认配置，缩放 / 店名 / 首启判定全部失效（§AI-1）
    _config = _configStore.load();
    // 首帧之后再弹对话框：此时才有可用的 Navigator
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  @override
  void dispose() {
    // 主机服务可能正听着端口 —— 退出时**主动关掉**，不要把 socket 留给下一次
    // 启动（`stop()` 是异步的，这里不 await：dispose 不能挂起，进程退出会收尾）
    final HostServiceController? host = _hostService;
    _hostService = null;
    if (host != null) unawaited(host.stop());
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
      // §AG 遗漏 1：只有「配置里根本没有位置」才是真首次启动 ——
      // 位置失效（盘符变了 / 被搬走）时不能再对用户说「这是第一次启动」
      firstRun: _config.dataDirectory == null,
    );
    if (chosen == null) return; // 用户退出了 —— 界面会停在「需要选择位置」
    _openDatabase(chosen);
  }

  void _openDatabase(DataLocation location) {
    try {
      final Db db = _service.open(location);
      // 打开即迁移完毕 —— 之后的自动备份内容是这个版本的格式，
      // 文件名（AE-4）必须标它，不能标标记文件里可能过时的版本
      final int schemaVersion = db.schemaVersion;

      // 三处版本号（程序 / 库 / 标记）：不一致 → 记日志（诊断用，不拦人），
      // 并把「目录身份证」刷新到库的真实版本（reply.md Schema 篇 §3.3）。
      // 刷新后下次启动就一致了 —— 所以这条日志只在「刚升级过」的那一次出现。
      if (location.marker.schemaVersion != schemaVersion) {
        _log.write(
          '版本号不一致：程序 schema v${Schema.version}'
          ' / 库 v$schemaVersion'
          ' / 标记 v${location.marker.schemaVersion}'
          '（库已迁移，刷新标记文件）',
        );
        // §AQ·六 方案 A（2026-10-02 裁定）：刷新标记是**诊断性辅助动作**，
        // 它在这里与 `Db.open` **同处一个 try** —— 一旦抛出，**开得好好的库**
        // 会被连坐成「数据文件打不开」，软件整页不可用（目录变只读 / 磁盘满就会）。
        // 所以走**不抛版本**，失败只记一条日志：标记没刷新 ⇒ 下次启动再判一次，
        // 多一条日志而已，**没有功能损失**。
        final Object? refreshError =
            _service.tryRefreshMarker(location, schemaVersion);
        if (refreshError != null) {
          _log.write(
            '刷新标记文件失败（$refreshError）—— 数据可正常使用，下次启动会再试',
          );
        }
      }
      final BackupService backup = BackupService(
        dataDirectory: location.directory,
        backupDirectory: location.backupDirectory,
        schemaVersion: schemaVersion,
      );
      final ExportService exports = ExportService(
        exportDirectory: location.exportDirectory,
      );
      setState(() {
        _location = location;
        _db = db;
        _schemaVersion = schemaVersion;
        _queries = QueryDao(db);
        _backup = backup;
        _exports = exports;
        _products = ProductService(db);
        _purchases = PurchaseService(
          engine: RuleEngine(db),
          queries: QueryDao(_db!),
        );
        _sales = SaleService(
          engine: RuleEngine(db),
          queries: QueryDao(_db!),
        );
        _deliveries = DeliveryService(
          engine: RuleEngine(db),
          queries: QueryDao(_db!),
        );
        _accounts = AccountService(AccountDao(db));
        _parties = PartyService(PartyDao(db));
        _engine = RuleEngine(db);
        _settlements = SettlementService(db: db, engine: RuleEngine(db));
        // §AH · AH-A：主机同步服务。**只建对象，不启服务** ——
        // 监听端口必须由用户在设置页显式打开（遗漏 5）。
        // `host.json` 与库同目录（`auth.dart`：主机设施放文件、不动 schema）。
        _hostService = HostServiceController(
          db: db,
          identities: HostIdentityStore(hostIdentityFile(location.directory)),
        );
        _dbFailure = null;
      });
      // 先把状态读出来（设置页/概览页首帧就得有「上次备份」），
      // 再异步跑自动备份 —— **不 await**：用户马上要用软件
      _refreshBackupStatus();
      unawaited(_autoBackup());
    } catch (error, stack) {
      // §AG-5：**启动失败要留现场** —— 用户只会说「打不开了」，
      // 而这里恰好知道「是哪个位置、哪条异常」。路径不是经营数据，可以记。
      _log.crash(error, stack, label: '打开数据库失败');
      _log.write('数据位置：${location.directory}');
      // 换库 / 换目录时**先把旧的主机服务停掉** —— 否则那个 shelf 实例
      // 会继续占着端口、还握着一个即将失效的 `Db`。
      final HostServiceController? leavingHost = _hostService;
      _hostService = null;
      if (leavingHost != null) unawaited(leavingHost.stop());
      setState(() {
        _location = location;
        _db = null;
        _schemaVersion = 0;
        _queries = null;
        _backup = null;
        _exports = null;
        _lastBackup = null;
        _backupError = null;
        _hasDocuments = false;
        _products = null;
        _purchases = null;
        _sales = null;
        _deliveries = null;
        _accounts = null;
        _parties = null;
        _engine = null;
        _settlements = null;
        _dbFailure = '数据文件打不开（$error）。'
            '如果这个文件夹在 U 盘或网盘里，请换到本机磁盘上的文件夹。';
      });
    }
  }

  /// 重读「最新一份备份」+「库里有没有单据」。
  ///
  /// ⚠️ **只在启动与每次备份后调用，不放 `build` 里** —— 目录列举是 IO，
  /// 放 build 会变成「每点一下导航就读一次盘」。
  void _refreshBackupStatus() {
    final BackupService? backup = _backup;
    if (backup == null) return;
    final BackupFileName? last = backup.latestBackupFile();
    final bool hasDocuments = _queries?.hasAnyDocument() ?? false;
    if (!mounted) return;
    setState(() {
      _lastBackup = last;
      _hasDocuments = hasDocuments;
    });
  }

  /// §AE-3：每天首次启动自动备份一次。
  ///
  /// ⚠️ 先让出一次事件循环再动库：备份是**同步**文件拷贝
  /// （`File.copySync`，几 MB 级别），别卡在「启动那一下」里 ——
  /// 用户先看到界面，备份在后面很快跑完。
  ///
  /// **失败完全静默**（不弹窗、不阻塞）；失败原因留给 [_backupError]，
  /// 由概览橙卡与设置页呈现（§AE 遗漏 2：静默不等于永远看不见）。
  Future<void> _autoBackup() async {
    await Future<void>.delayed(Duration.zero);
    // 让出之后重新取值：期间可能失败重选位置 / 窗口被关掉
    final BackupService? backup = _backup;
    final Db? db = _db;
    if (!mounted || backup == null || db == null) return;
    final BackupOutcome outcome = await backup.autoBackup(
      db: db,
      hasContent: _hasDocuments,
    );
    _noteBackupOutcome(outcome);
    _refreshBackupStatus();
  }

  /// 「立即备份」（设置页按钮 / 概览橙卡共用）。返回结果供页面弹 SnackBar。
  Future<BackupOutcome> _backupNow() async {
    final BackupService? backup = _backup;
    final Db? db = _db;
    if (backup == null || db == null) {
      return const BackupOutcome.failure('数据文件还没打开，暂时不能备份');
    }
    final BackupOutcome outcome = await backup.backupNow(db: db);
    _noteBackupOutcome(outcome);
    // 成功/失败都要重读：失败可能是目录不可写，橙卡得如实反映
    _refreshBackupStatus();
    return outcome;
  }

  /// 记下这次尝试的结果。
  ///
  /// ⚠️ **`ok` 与 `skipped` 都算「没出事」**：`skipped` 覆盖「库还是空的」
  /// 「距上次不足 24 小时」「这一分钟里已经备过」—— 那是**设计内的跳过**，
  /// 记成失败会让橙卡天天喊「上次备份没成功：距上次备份不足 24 小时」。
  void _noteBackupOutcome(BackupOutcome outcome) {
    _backupError = (outcome.ok || outcome.skipped) ? null : outcome.message;
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
      // SC-1：全局文字缩放（覆盖系统缩放；设置页五档 + 一键恢复默认）
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(_config.uiScale.factor)),
        child: child!,
      ),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    // 备份文案跟当前时间有关（「今天 09:05」/「已经 4 天」）——
    // 每次 build 取一次当前时刻，跨天后下一次重绘就对了
    final DateTime now = DateTime.now();

    if (_dbFailure != null) {
      return _StartupPage(
        message: _dbFailure!,
        actionLabel: '重新选择位置',
        onAction: () async {
          setState(() => _dbFailure = null);
          _location = null;
          _db = null;
          // 与失败分支保持同一份清单：库没了，依赖它的东西一起清掉
          final HostServiceController? leavingHost = _hostService;
          _hostService = null;
          if (leavingHost != null) unawaited(leavingHost.stop());
          _queries = null;
          _backup = null;
          _exports = null;
          _lastBackup = null;
          _backupError = null;
          _hasDocuments = false;
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
      // 库打开成功后用真实数据格式版本；没打开时没有备份，回退标记版本
      schemaVersion: _schemaVersion > 0
          ? _schemaVersion
          : location.marker.schemaVersion,
      databaseReady: _db != null,
      products: _products,
      purchases: _purchases,
      sales: _sales,
      deliveries: _deliveries,
      accounts: _accounts,
      parties: _parties,
      queries: _queries,
      documents: _db == null ? null : DocumentDao(_db!),
      settlements: _settlements,
      engine: _engine,
      hostService: _hostService,
      uiScale: _config.uiScale,
      shopName: _config.shopName,
      // ---- 备份文案（§AE-3 / AE-5 / 遗漏 2）----
      // ⚠️ 判定在这里算、UI 只摆字符串：概览橙卡与设置页红字**必须是同一个
      //    结论**（`needsBackupAttention` 只有一处）。时钟取每次 build 的
      //    当前值，于是跨天后下一次重绘就自洽。
      backupStatusLine: _backup == null
          ? null
          : backupStatusLine(
              lastBackup: _lastBackup?.time,
              manual: _lastBackup?.manual ?? false,
              now: now,
              lastFailure: _backupError,
            ),
      backupNeedsAttention:
          _backup != null &&
          needsBackupAttention(
            lastBackup: _lastBackup?.time,
            now: now,
            hasDocuments: _hasDocuments,
            lastFailure: _backupError,
          ),
      backupReminder: _backup == null
          ? null
          : backupReminderText(
              lastBackup: _lastBackup?.time,
              now: now,
              hasDocuments: _hasDocuments,
              lastFailure: _backupError,
            ),
      onBackupNow: _backup == null ? null : _backupNow,
      exports: _exports,
      // §AI-1：传**解析后**的实例（生产里 widget.configStore 是 null）
      configStore: _configStore,
      onConfigChanged: (AppConfig config) {
        _configStore.save(config);
        setState(() => _config = config);
      },
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
