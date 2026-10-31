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
import 'dart:io' show Directory, File, Platform;
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

import 'folder_picker.dart';
import 'ui/app_shell.dart';
import 'ui/data_directory_dialog.dart';
import 'ui/mobile_shell.dart';
import 'ui/pairing_scan_page.dart';
import 'ui/recovery_dialog.dart';
import 'ui/rescue_dialog.dart';
import 'ui/emphasized_text.dart';
import 'ui/notice.dart';

class ShensuanziApp extends StatefulWidget {
  /// `pickDirectory` 的默认值**就在参数上就地给出**（真实实现）——
  /// 不能留 `null` 再在 `build` 里兜底：那样「忘了传」会变成「运行时才炸」。
  /// 就地给默认值，类型系统保证它非空，现有调用点
  /// `runApp(const ShensuanziApp())` 一个字都不用改。
  const ShensuanziApp({
    super.key,
    this.pickDirectory = pickFolderFromSystem,
    this.configStore,
    this.defaultDataDirectory,
    this.shellKind,
    this.dataRoot,
    this.backup,
  });

  /// **备份服务的注入缝**（5a，2026-10-24，§CV·一百）。
  ///
  /// `null` = 生产行为（按解析出来的数据目录 / 备份目录现造一个）。
  ///
  /// 为什么需要它：备份的文件拷贝已搬进 `Isolate.run`，而 `testWidgets` 的
  /// fake async **不推真实事件循环** ⇒ widget 测试里「等真实备份完成」会挂。
  /// 所以 UI 层只验「**调用了备份服务、参数对**」，真实的拷贝 / 校验 / 轮转
  /// 留在纯 Dart 的 `backup_test.dart`（34 条）里测。
  final BackupService? backup;

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

  /// **机器给的默认数据目录** —— 仅供测试注入（§BR·补 2 裁定：**方案 B**）。
  ///
  /// ## ⚠️ 它是一个「值」，不是「机器环境的替身」—— 这是裁定的关键区分
  ///
  /// 注入它**不改变 UI 探测目录的方式**：UI 照样拿这个路径去**真实文件系统**
  /// 问「有没有 `.shensuanzi-data` 标记」（`isShensuanziDir` → `existsSync`），
  /// 行为是真实的。**注入整个 `AppEnvironment` 才叫「假机器」**
  /// （`AGENTS.md` §4.3 明令禁止前置替换环境）—— 那是**参数化 vs 假机器**的区别，
  /// **别拿这个当先例**去论证「再注入一个 `AppEnvironment` 也没问题」。
  ///
  /// ## 边界（写死在裁定里，实现不许越界）
  ///
  /// - `null` = 用真实机器算出来的默认位置 —— **生产行为，一个字都不变**；
  /// - 非 `null` = **只在「真·第一次启动」的场景判定里**替换这一个值；
  /// - **配置里已有路径时它不参与任何判定**（不影响 `openExisting` /
  ///   `brokenDatabase` / `recoverLocation` / `salvageConfig`）；
  /// - 与 [pickDirectory] **不重叠**：那个只在首启对话框里被调，这个只在首启判定时被读。
  final String? defaultDataDirectory;

  /// 壳形态（§BH B1a）。`null` = 按真实平台判（`shellKindFor`，纯 Dart 可测）。
  /// 测试里跑在 Windows 上 ⇒ 恒为桌面壳，注入只供将来移动端测试用。
  final ShellKind? shellKind;

  /// 移动端私有目录根（§BH·五 B1b；`main.dart` 的移动分支注入）。
  /// `null` = 桌面（走选目录对话框）。Android 的 data/backup/export
  /// 全部收在它下面（目录布局沿用 Windows 的兄弟目录算法）。
  final String? dataRoot;

  @override
  State<ShensuanziApp> createState() => _ShensuanziAppState();
}

class _ShensuanziAppState extends State<ShensuanziApp>
    with WidgetsBindingObserver {
  /// 真机事实只探测一次（盘符 / 环境变量）。
  ///
  /// **刻意不注入、保持真实**：启动流程要验证的恰恰是「真实机器 + 沙箱配置」
  /// 下的行为；把机器也伪造了，就变成「在假机器上跑假配置」，
  /// 每个场景还得自己造一套盘符（`docs/reply_review.md` §W 二）。
  /// 机器环境（盘符 / 剩余空间）。**不注入**（`AGENTS.md` §4.3「启动流程的两个
  /// 注入点」：注入它会把「真实机器」变成假的）。测试要造机器就往下层走 ——
  /// `packages/shensuanzi_app` 的 `AppBootstrap` 收 `environment` 参数，那里可造。
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

  /// **#23（2026-10-17 裁定甲·补强②）**：统一构造带 `onInternalError` 的引擎
  /// —— 规则层的 `RuleRejection.detail`（诊断细节）经它进宿主日志。
  /// ⚠️ 此前桌面/手机壳的引擎都没接这个钩子 ⇒ detail 被静默丢弃
  ///（只有 `HostServiceController` 接过）—— 本批补上，业务拒绝的
  /// 「为什么被拒」才有排查依据。
  RuleEngine _newEngine(Db database) => RuleEngine(
    database,
    onInternalError: (String label, Object error, StackTrace stack) =>
        _log.crash(error, stack, label: label),
  );

  /// 壳形态：判断在 app 包（纯 Dart，`dart test` 覆盖），这里只取值分支。
  /// 平台不会中途变，`late final` 一次定死。
  late final ShellKind _shellKind =
      widget.shellKind ??
      shellKindFor(operatingSystem: Platform.operatingSystem);

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

  /// 退货服务（§BI R2：单据详情页的退货 / 拒收入口）
  ReturnService? _returns;

  /// 手机端同步服务（§BL·二/三；仅移动端 —— 桌面是主机，没有「客户端同步」）
  MobileSyncService? _mobileSync;

  /// 懒建：镜像库与 pairing.json 都在**应用私有目录**（`dataRoot`，main.dart 注入；
  /// 桌面 `dataRoot == null` ⇒ 服务不存在，设置页显示 hostService 面板）
  MobileSyncService? get _mobileSyncService {
    if (_shellKind != ShellKind.mobile) return null;
    final String? root = widget.dataRoot;
    if (root == null) return null;
    return _mobileSync ??= MobileSyncService(
      mirrorPath: p.join(root, 'mirror', 'shensuanzi_mirror.db'),
      pairingStore: PairingStore(File(p.join(root, '神算子', 'pairing.json'))),
      // F15 / M15 两通道：界面只给人话（`syncFailureMessage`），
      // 原始异常 + 栈进日志 —— 用户不再看到 `Bad state: …` 这种源码。
      onError: (Object error, StackTrace stack, String label) =>
          _log.crash(error, stack, label: label),
    );
  }

  /// 聚合查询（库存页 + 备份的空库判定共用同一个 DAO）
  QueryDao? _queries;

  /// 备份服务（库打开成功才有；自动与手动共用它，于是共用单飞锁）
  BackupService? _backup;

  /// 5c：**正在备份**（超过 300 ms 才置真 —— 不然每次启动都闪一下）。
  ///
  /// 5a 把文件拷贝搬进 isolate 之后界面不再冻结，这条提示才真的能画出来。
  bool _backingUp = false;

  /// 300 ms 后才把 [_backingUp] 置真的定时器（备份很快时不留痕迹）
  Timer? _backupHintTimer;

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

  /// 手机端**镜像打不开**的原因（M16，2026-10-08）。
  ///
  /// 与 [_dbFailure] 分开：镜像坏了主库可能是好的，但手机**没有镜像就用不了**
  /// （开单要入队、库存要看叠加值）⇒ 同样要拦住并给一条出路。
  String? _mirrorFailure;

  /// 打不开的那个数据目录（§审查 2026-10-05 真机）。
  ///
  /// 非 `null` 时错误页多给一个「重试」—— 库修好（或占用它的程序关掉）之后，
  /// **不用换文件夹就能回到原来的数据**。没有它，用户只能「换一个文件夹」，
  /// 等于把原目录连同里面的真数据一起放弃（实测踩过：`D://fed` 切不回去）。
  String? _brokenDirectory;

  /// 「库文件**不见了**」的那个目录（2026-10-07，`docs/reply.md` §6 的 #1）。
  ///
  /// 有值时错误页多一个「新建一本空账」——由用户点，不由软件替他决定
  /// （自动建空库 = 让他在毫无提示的情况下对着一本空账簿继续开单）。
  String? _missingDatabaseDirectory;

  /// 单实例锁（§审查 OBS-14）—— 同一个数据目录只允许一个实例开着库。
  final InstanceLock _instanceLock = InstanceLock();

  /// 「神算子已经在运行了」—— 与「数据有问题」是两回事，单独一个状态，
  /// 免得错误页给出「换一个文件夹」这种不相关的出路。
  bool _alreadyRunning = false;

  /// 库比程序新（`SchemaTooNewException`）—— 与「文件坏了」是**两件事**，
  /// 不能共用那一屏（2026-10-31 真机：用户双击了 10-28 的旧 exe，
  /// 界面却说「文件可能出了点小问题」，他以为数据坏了）。
  bool _dbTooNew = false;

  /// **镜像自检没通过**的原因（状态 2，2026-10-31 用户裁定）。
  ///
  /// 与 [_mirrorFailure] 的区别：那个是**打不开**（`openMirror()` 抛），
  /// 这个是**开得起来但内容不对**（`PRAGMA quick_check` 报坏页）。
  /// 处置是同一条路（抢队列 → 留档 → 重建 → 重拉），所以共用 `_recoverBrokenMirror`。
  String? _mirrorUnhealthy;

  /// 正在做**镜像隔离恢复**（状态 3）—— 期间整页显示「正在修复」。
  ///
  /// 为什么不弹进度框：这一步要复制几百 MB 的文件，必须在**首帧之后**才开始，
  /// 且不能给假进度（拿不到总字节就报百分比是骗人）。整页一句话最诚实。
  bool _recoveringMirror = false;

  /// 手机端**本机账本打不开**的原因（2026-10-31 联调 #0，用户裁定 A 第一阶段）。
  ///
  /// 与 [_dbFailure] 的分工：`_dbFailure` = **什么都用不了**，停在启动错误页；
  /// 这里 = 只是本机那本空壳账打不开，**镜像还能用** ⇒ 照常进主界面。
  ///
  /// ## 为什么手机端可以「降级」而不是「拦住」
  ///
  /// 手机壳的业务页**全部接镜像**（`app_shell.dart` 里 `allowBackup` 那段注释：
  /// 真机实测「备份文件里 0 商品 0 队列」⇒ 主库在手机上是**空壳**），
  /// 开单走 `QueueSink`（镜像 + 队列）—— **一次都不碰本地库**。
  /// 所以本地库坏掉不该让整个 App 停在错误页（真机实测的原始症状）。
  String? _localDbFailure;

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
    // 2026-10-07 裁定（`docs/reply.md` §一）：自动补传 = **开单后 + 回前台 + 手动**
    // —— 回前台这条要观察生命周期（零新依赖，用 `WidgetsBindingObserver`）
    WidgetsBinding.instance.addObserver(this);
    // 首帧之后再弹对话框：此时才有可用的 Navigator
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 主机服务可能正听着端口 —— 退出时**主动关掉**，不要把 socket 留给下一次
    // 启动（`stop()` 是异步的，这里不 await：dispose 不能挂起，进程退出会收尾）
    final HostServiceController? host = _hostService;
    _hostService = null;
    if (host != null) unawaited(host.stop());
    _db?.close();
    // §审查 OBS-14：放锁（其实进程退出操作系统也会收，显式放更干净）
    _instanceLock.release();
    super.dispose();
  }

  /// **回到前台时补传一次**（2026-10-07 裁定，`docs/reply.md` §一「B」）。
  ///
  /// ## 为什么是「回前台」而不是网络监听 / 定时
  ///
  /// 裁定原文三条理由：① 与 `ui_principles.md` §1.1 一致 —— 中老年用户
  /// **不会主动探索**，也理解不了「App 在后台悄悄同步」，所以触发点必须是
  /// **用户可感知、可预测**的；② 定时（`WorkManager` / 前台服务）会被
  /// Android 的 Doze 与后台限制砍掉，还要引依赖，违反「core 零新依赖」；
  /// ③ 网络恢复要装 `connectivity_plus` 并为移动网络做省电策略，收益不匹配成本。
  ///
  /// ## 静默是刻意的
  ///
  /// 结果**只给三态条**（`setState` 触发它重查），不弹 SnackBar：
  /// 用户切回来一次就弹一句「已推送 3 条」是打扰，而三态条本来就常驻在顶部。
  /// 「没有待同步条目」也算正常（`autoPush` 自己会返回那个结果）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    setState(() {}); // 先让三态条反映当前队列（可能已过期）
    final MobileSyncService? sync = _mobileSyncService;
    if (sync == null) return; // 桌面 / 未拿到私有目录
    unawaited(
      sync.autoPush().then((SyncOutcome _) {
        if (mounted) setState(() {}); // 失败也刷新：条目可能进了退避 / 死信
      }),
    );
  }

  Future<void> _prepare() async {
    // Android：私有目录用户选不了（scoped storage），没有「选择位置」这回事
    // —— 它自己一条路（§BH·五 B1b）
    if (_shellKind == ShellKind.mobile) {
      _prepareMobile();
      return;
    }

    // §审查「启动路径健壮性」批次：判定收在 `AppBootstrap.startupDecision()`
    // **一处**。原来是这里的一串 `if`，每加一个边界就补一段 —— **真机踩过**
    // 顺序打架：库损坏被当成「首次启动」，向导把 `config.json` 覆盖掉，
    // 用户的目录（实测 `D://fed`）再也切不回去。
    final StartupDecision decision = _service.startupDecision(
      // §BR·补 2 裁定 方案 B：只把「机器给的默认位置」这一个值参数化
      //（`null` = 用真实机器的默认值 —— 生产行为不变）
      defaultDataDirectory: widget.defaultDataDirectory,
    );

    // §审查 OBS-15：配置读不懂就**先留档**（另存 `.corrupt`、**不删原件**）——
    // 无论救不救得回来，那份读不懂的原文件对人工排查都有价值
    if (_service.configStatus() == AppConfigLoadStatus.locationLost) {
      _service.preserveCorruptConfig();
    }

    switch (decision.scenario) {
      case StartupScenario.openExisting:
        _openDatabase(decision.location!);
        return;

      case StartupScenario.salvageConfig:
        // ⚠️ **只改内存、不写盘**：`load()` 读的是坏文件（返回默认配置），
        // 直接 save 会把用户的字号 / 店名一起冲成默认值。用户下次改任何
        // 设置时这份内存配置会被整份写下去，配置就**自愈**了。
        setState(
          () => _config = _config.copyWith(
            dataDirectory: decision.location!.directory,
          ),
        );
        _openDatabase(decision.location!);
        return;

      case StartupScenario.brokenDatabase:
        // ⚠️ **不许**继续往下走向导：向导会拿默认路径**覆盖 config**，
        // 原目录就从配置里消失了（BUG-03 的另一半，§审查 2026-10-05 真机）
        setState(() {
          _brokenDirectory = decision.location!.directory;
          _dbFailure = _brokenDatabaseMessage(decision.location!.directory);
        });
        return;

      case StartupScenario.missingDatabase:
        // 同样的理由（不走向导），但**文案与出路不同**：这不是"坏"，是"没了"
        // ⇒ 先教怎么从备份 / before-vN 找回来，最后才给「新建一本空账」。
        setState(() {
          _missingDatabaseDirectory = decision.location!.directory;
          _dbFailure = _missingDatabaseMessage(decision.location!.directory);
        });
        return;

      case StartupScenario.firstRunWithData:
        await _askExistingOrDefault(decision.defaultPath!);
        return;

      case StartupScenario.welcome:
        await _chooseDirectory(firstRun: true, note: null);
        return;

      case StartupScenario.recoverLocation:
        // **不说「第一次启动」** —— 这是「我记不住位置了 / 原位置用不了」
        // （§AG 遗漏 1 + §审查 OBS-15）
        await _chooseDirectory(
          firstRun: false,
          note: decision.previousPath == null
              ? _lostConfigNote
              : '上次用的数据文件夹（${decision.previousPath}）现在找不到了。'
                    '如果它被搬走、或者盘符变了，点「更改」直接选它现在的位置就行；'
                    '数据本身不会因为这个提示消失。',
        );
        return;
    }
  }

  /// Android 的启动路径（§BH·五 B1b，2026-10-04 裁定）：**不弹选目录对话框**。
  ///
  /// 私有目录用户选不了（scoped storage，真机实测 `/storage/emulated/0` 写不进、
  /// 还会建议 `C:\` 这种 Windows 路径），数据直接落在 `<私有目录>/data`
  /// （兄弟目录算法自动生成 神算子备份 / 神算子导出）。
  /// 开单保存失败（M15，2026-10-08）：**原始异常进日志**。
  ///
  /// 界面由三张开单页显示 `storageFailureNote(error)` 的分类文案 ——
  /// `SqliteException.toString()` 带着整条 SQL 与绑定参数（= 这张单的 payload），
  /// 直接给用户看既不可读、也把开单内容摊在了屏上。
  ///
  /// ⚠️ #54（2026-10-15 外测 M15）：**日志通道同样是漏网的那半** ——
  /// 旧实现 `_log.crash(error, …)` 把同一条 payload 原样写进了日志文件
  /// （用户打包转发日志 = 经营内容出框）。改为只留分类 / 结果码 / 堆栈。
  void _onStorageFailure(Object error, StackTrace stack) =>
      _log.write('保存失败：${storageFailureLogLine(error)}\n$stack', level: '错误');

  void _prepareMobile() {
    final String? root = widget.dataRoot;
    if (root == null) {
      setState(() {
        _dbFailure =
            '应用数据目录不可用（没有拿到私有目录）。'
            '请卸载后重新安装再试；如果还不行，请把这句话告诉技术支持。';
      });
      return;
    }
    final DataLocation location;
    try {
      location = _service.ensureInitialized(p.join(root, 'data'));
    } on DataDirectoryRejected catch (error) {
      // 私有目录被拒（系统占位 / 只读）—— 这里**不能降级**：镜像
      // （`<root>/mirror/`）就在同一个根下面，目录都不可用 ⇒ 镜像也开不了。
      // 诚实展示，不兜圈子。
      setState(() {
        _dbFailure = '${error.reason}。${error.howTo ?? '请重新安装后再试。'}';
      });
      return;
    } catch (error, stack) {
      // 建目录 / 写标记就炸了（只读、空间满、存储坏了）—— 同上，降级没有意义
      _log.crash(error, stack, label: '手机数据目录初始化失败');
      setState(() => _dbFailure = storageFailureNote(error));
      return;
    }
    // ⚠️ `_openDatabase` **不抛**：它自己兜住，且手机端会把失败降级成
    // `_localDbFailure`（裁定 A）—— 于是无论本机账本能不能开，流程都走到这里，
    // **镜像照开**（2026-10-31 联调 #0 的核心修法）。
    _openDatabase(location);
    try {
      // M16（2026-10-08）：**镜像在这里打开，不要留给 build** ——
      // build 期该只做纯布局；在那里做 I/O，失败会炸成框架异常页
      // （无导航、无重试，用户被困 —— Android 报告 M16 实测）。
      // 打开后 `openMirror()` 返回缓存，build 期不再有 I/O。
      final Db? mirror = _mobileSyncService?.openMirror();
      // 状态 2（2026-10-31 裁定）：开得起来不代表数据是对的 ——
      // `quick_check` 走一遍所有页（478 MB 主库实测 850 ms，镜像是子集，
      // 通常几十毫秒）。报了坏页就走「隔离恢复」，与状态 3 同一条路。
      final String? problem = mirror == null ? null : mirrorHealthProblemOf(mirror);
      if (problem != null) {
        _log.write('镜像自检没通过：$problem');
        setState(() => _mirrorUnhealthy = problem);
      } else {
        setState(() => _mirrorUnhealthy = null);
      }
    } catch (error, stack) {
      // 镜像打不开：给**中文原因 + 重试出口**；原始异常只进日志
      _log.crash(error, stack, label: '打开手机镜像失败');
      setState(() {
        _mirrorFailure =
            '手机上的数据文件打不开（可能被清理软件删了、或存储空间不够）。'
            '点下面「重试」再看一次；如果一直这样，请把软件的日志发给技术支持 —— '
            '你在手机上开的单还在，不会丢。';
      });
    }
  }

  /// 弹「选择数据存放位置」对话框，选到了就开库。
  ///
  /// [firstRun] 控制**要不要说「欢迎使用」**（`docs/data_directory.md` §9.2）；
  /// [note] 是替换掉「欢迎」那一句的说明（配置读不懂 / 原位置用不了）。
  Future<void> _chooseDirectory({required bool firstRun, String? note}) async {
    // 用 Navigator 的 context（见 `_navigatorKey` 的注释）
    final BuildContext? dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;

    final DataLocation? chosen = await showDataDirectoryDialog(
      dialogContext,
      model: DataDirectoryDialogModel(_service),
      // 注入点：生产环境是系统选择器，测试里是桩
      pickDirectory: widget.pickDirectory,
      firstRun: firstRun,
      lostLocationNote: note,
      // §BR·补 2：对话框**预填**的默认位置必须与判定用的注入值**同一个** ——
      // 否则判定说「那个位置没数据 ⇒ 走欢迎向导」，用户点「开始使用」却落到
      // 机器默认位置（测试里还会写到开发机真实磁盘上）
      defaultPath: widget.defaultDataDirectory,
    );
    if (chosen == null) return; // 用户退出了 —— 界面会停在「需要选择位置」
    _openDatabase(chosen);
  }

  /// 首启撞上「**默认位置已经有数据**」—— 先问一句（§审查 OBS-11 前半）。
  ///
  /// ## 为什么要问
  ///
  /// 默认位置在同一台机器上每次都是同一个，而「重装软件 / 解压到别处 /
  /// 双击第二份 exe」都会走到这里。不问的话，用户直接点「开始使用」
  /// 就挂到同一份数据上了 —— 他以为「换了个文件夹就是新数据」。
  ///
  /// 「继续使用已有数据」= 复用那份数据（`ensureInitialized` 见标记即复用）；
  /// 「选一个新位置」= 正常走向导（**原来那份数据一个字节都不动**）。
  Future<void> _askExistingOrDefault(String defaultPath) async {
    final BuildContext? navContext = _navigatorKey.currentContext;
    if (navContext == null) return;

    final bool? useExisting = await showDialog<bool>(
      context: navContext,
      // 数据落在哪是启动前提，点外面关掉会停在「需要选择位置」——
      // 与选目录对话框同款（`showDataDirectoryDialog` 也是不可点掉的）
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('这个位置已经有神算子的数据'),
        content: Text(
          '$defaultPath\n\n'
          '这个文件夹里已经有一份神算子的数据了。\n'
          '要继续用这份数据，点「继续使用已有数据」；'
          '想从零开始、或者把数据放到别的地方，点「选一个新位置」。',
          style: const TextStyle(height: 1.8),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('选一个新位置'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('继续使用已有数据'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (useExisting == true) {
      // 有标记 ⇒ `ensureInitialized` 走**复用**分支，不动目录里的东西
      _openDatabase(_service.ensureInitialized(defaultPath));
      return;
    }
    // 「选一个新位置」/ 对话框被系统关掉（返回 null）—— 都走向导，
    // 但说明一句「默认位置里那份数据不会被动」，免得用户以为被删了。
    // ⚠️ `firstRun: false` —— 不说「这是第一次启动」：用户刚看到「那个位置
    // 已经有数据」，再说「第一次启动」会自相矛盾（`lostLocationNote` 就是
    // 用来替换那句欢迎语的）
    await _chooseDirectory(
      firstRun: false,
      note:
          '默认位置（$defaultPath）里已经有一份神算子的数据 —— '
          '它不会被删掉，你现在选的是新位置。'
          '数据都存在你自己电脑里，不会上传。',
    );
  }

  /// 切到**已经装过神算子数据**的目录（只改配置，**不搬文件**）。
  ///
  /// §审查 2026-10-05 真机：与「更改数据位置（搬迁）」是两件事 ——
  /// 那个把数据**搬**到新目录，这个只是把软件**指向**另一个已有数据目录。
  /// 两边数据都原样留着，随时能再切回来，所以确认文案必须说清「不搬、不删」。
  Future<void> _switchToExistingData(
    BuildContext navContext,
    String target,
  ) async {
    final DataLocation? current = _location;
    if (current == null) return;
    final Color hint = Theme.of(navContext).hintColor;

    final bool? confirmed = await showDialog<bool>(
      context: navContext,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('切到这个已有的数据文件夹？'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('这个文件夹里已经有神算子的数据：', style: const TextStyle(height: 1.6)),
              Text(
                target,
                style: const TextStyle(
                  height: 1.6,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '点「切过去」，软件就改用它的数据。不会搬文件，也不会删东西。',
                style: TextStyle(height: 1.6),
              ),
              const SizedBox(height: 8),
              Text(
                '现在的数据还留在 ${current.directory}，随时能切回来。',
                style: TextStyle(height: 1.6, color: hint),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('切过去'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 关旧库 + 停主机（与「换一个文件夹」同一套收尾）
    final Db? openingDb = _db;
    _db = null;
    if (openingDb != null) openingDb.close();
    final HostServiceController? leavingHost = _hostService;
    _hostService = null;
    if (leavingHost != null) unawaited(leavingHost.stop());

    try {
      // 标记在那儿 ⇒ `ensureInitialized` 走**复用**分支，不动目录里的东西
      final DataLocation location = _service.ensureInitialized(target);
      _configStore.save(_config.copyWith(dataDirectory: location.directory));
      setState(() => _config = _configStore.load());
      _openDatabase(location);
    } on DataDirectoryRejected catch (error) {
      final BuildContext? retryContext = _navigatorKey.currentContext;
      if (retryContext == null || !retryContext.mounted) return;
      setState(() {
        _brokenDirectory = target;
        _dbFailure = '${error.reason}。${error.howTo ?? '请再选一个文件夹。'}';
      });
    }
  }

  /// 「找回数据」：体检 + 从备份接回来（P0，提案 52）。
  ///
  /// 三条设计（2026-10-29 用户补充建议）：
  /// 1. 入口叫**找回数据**，不叫「数据体检」「数据库修复」—— 后者像医生下诊断；
  /// 2. 对话框里先给「有几份、哪份好、里面多少单据」，让用户能判断选哪份；
  /// 3. 接回时**原来的文件改名留存**（`.broken-<时间>`），并在确认框里明说
  ///    「我们帮你留着了，随时可以找回来」。
  Future<void> _openRecovery() async {
    final String? directory = _brokenDirectory ?? _missingDatabaseDirectory;
    if (directory == null) return;
    // ⚠️ 必须用 `_navigatorKey` 的 context：本 State 的 `context` 在
    // `MaterialApp` **之上**，上面没有 Navigator ⇒ `showDialog` 直接抛。
    final BuildContext? dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    final bool restored = await showRecoveryDialog(
      dialogContext,
      dataDirectory: directory,
      databasePath: p.join(directory, AppBootstrap.databaseFileName),
      backupDirectory:
          _config.backupDirectory ??
          _service.policy.backupDirectoryFor(directory),
      currentSchemaVersion: Schema.version,
    );
    if (!restored || !mounted) return;
    // 接回来了 ⇒ 走「重试」那条路重新开库（它会清掉错误态再 `_prepare`）
    await _retry();
  }

  /// 「从坏掉的文件里尽量找回」—— P1 抢救（提案 52 §四·P1）。
  ///
  /// 只在**备份也救不了**的时候用，所以入口是个低调的文字按钮，且点下去先解释。
  /// 产物落在「神算子导出」文件夹里（与备份分开：这是用户主动要的文件，
  /// 不该混进备份的 30 天清理里）。
  Future<void> _openRescue() async {
    final String? directory = _brokenDirectory ?? _missingDatabaseDirectory;
    if (directory == null) return;
    final BuildContext? dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    final String outputDirectory = _service.policy.exportDirectoryFor(
      directory,
    );
    final bool ok = await showRescueFlow(
      dialogContext,
      sourcePath: p.join(directory, AppBootstrap.databaseFileName),
      outputPath: p.join(outputDirectory, rescueFileName(DateTime.now())),
      outputDirectory: outputDirectory,
    );
    // 抢救产物是**另一个文件**，不会自动切过去 —— 用户可能想先看看再决定。
    // 所以这里什么都不做（报告里已经写清文件在哪）。
    if (ok) return;
  }

  /// 配置**读不懂 / 记不住位置**时的说明（§审查 OBS-15）。
  ///
  /// 要点：① 明说「不是第一次启动」的替代信息 —— 数据没丢；
  /// ② 给一条**能自己走通**的找回路径（我们不一定救得回来）。
  static const String _lostConfigNote =
      '上次记的数据位置读不出来了（配置文件坏了）。'
      '你的数据没有丢 —— 如果记得原来的文件夹，点「更改」直接选它；'
      '忘了也不怕：数据文件叫 shensuanzi.db，'
      '找到那个文件夹、点「更改」选它就回来了。';

  /// 数据文件打不开时的说辞。
  ///
  /// ⚠️ **文案是这一屏最重要的东西**（2026-10-29，用户补充建议）：
  /// 中老年用户看到「数据库损坏」的第一反应是「我是不是把电脑弄坏了」。
  /// 所以这里**不出现**「损坏 / 数据库 / 崩溃」这些词，先说「暂时打不开」，
  /// 再立刻给出**已有的退路**（每天自动备份），最后给一个动作（找回数据）。
  /// 库比程序新时的说辞（2026-10-31 真机）。
  ///
  /// ⚠️ 与 [_brokenDatabaseMessage] 的**关键区别**：这里**数据是好的**，
  /// 是「你打开的是旧版本软件」。所以：
  /// - 不出现「可能坏了 / 出点小问题」这类话；
  /// - 不给「从坏文件里找回」（那会把一份好数据改坏）。
  String _dbTooNewMessage(
    String directory, {
    required int dbVersion,
    required int appVersion,
  }) =>
      '这个数据文件是**更新版本**的神算子做的（数据格式 v$dbVersion，'
      '你现在打开的这个版本只到 v$appVersion）。\n\n'
      '数据一点没坏，别删它 —— 装上最新版本的神算子，再打开同一个文件夹就行。\n\n'
      '（文件夹：$directory）';

  String _brokenDatabaseMessage(String directory) =>
      '这个文件夹里的数据文件暂时打不开 —— 可能是被别的程序占着，'
      '也可能是文件本身出了点小问题。\n\n'
      '别担心，软件每天都会自动备份。点「找回数据」，'
      '从备份里挑一份接回来就行 —— 原来那个文件会改名留着，不会被删掉。\n\n'
      '（文件夹：$directory）';

  /// 数据文件**不见了**时的说辞（2026-10-07，`docs/reply.md` §6 的 #1）。
  ///
  /// 与 [brokenDatabase] 的区别必须在文案里说清楚：这里不是"坏"，是"没了"。
  /// 所以**先给找回的办法**（备份 + before-vN），最后才提"新建一本空账"，
  /// 且由用户点按钮决定 —— 软件替他建空库就等于让他对着空账簿继续开单。
  String _missingDatabaseMessage(String directory) =>
      '这个文件夹里找不到数据文件（shensuanzi.db）—— '
      '可能被误删了，也可能被清理软件或杀毒软件删掉了。\n\n'
      '别担心，软件每天都会自动备份。点「找回数据」，'
      '从备份里挑一份接回来就行。\n\n'
      '如果一份备份都没有，才需要点「新建一本空账」—— '
      '那会从零开始，里面不会有以前的单据。\n\n'
      '（文件夹：$directory）';

  /// 手机端「本机账本打不开」的**常驻说明**（2026-10-31 联调 #0，裁定 A 第一阶段）。
  ///
  /// 三句必须齐：① 出了什么事；② **什么照常**（账没丢、能看能查）；③ 写入被关。
  /// 按用户 `docs/reply.md` §三 的要求，**必须带上最近一次同步时间** ——
  /// 「现在看到的是哪一刻的数据」是用户判断能不能信这屏数字的唯一依据。
  /// 「怎么恢复」不写在这里 —— 那是「怎么办」按钮的事（[_showLocalDbAdvice]）。
  String _localDatabaseBrokenMessage() {
    final PairingInfo? pairing = _mobileSyncService?.pairingStore.load();
    final int? lastSyncAt = pairing?.lastSyncAt;
    final String syncLine = lastSyncAt == null
        ? '还没和电脑成功同步过'
        : '最近一次同步：${formatDateTime(lastSyncAt)}';
    return '手机上的账本文件打不开（多半是被清理软件动过、或存储空间不够）。'
        '账没丢：现在显示的是从电脑同步过来的数据（$syncLine），'
        '看数、查库存、查往来都照常。'
        '为了安全，这台手机暂时不能开单和改资料 —— 打不开的那个文件会原样留着，不会删。';
  }

  /// 「怎么办」—— 把**恢复路径**摆出来（裁定 A 第一阶段的唯一出口）。
  ///
  /// 为什么不是「一键重建本机账本」：用户 2026-10-31 的裁定明确说
  /// 「既然它已经不再是主要业务数据源，我认为也没有必要急着重建。
  /// 保留原文件、让 App 使用健康镜像，反而更加简单」——
  /// 真正的「重建」要留给**镜像损坏**那条路（那里才有不可重建的 `sync_queue`）。
  ///
  /// 但用户不能永远停在只读：这里给一条**自己走得到**的路 ——
  /// 先重试（可能只是被临时占用），再导出（把没传上去的单留一份），
  /// 最后重装（会清掉手机上的一切副本，所以必须先导出）。
  Future<void> _showLocalDbAdvice() async {
    final BuildContext? dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    final bool? retry = await showDialog<bool>(
      context: dialogContext,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('账本打不开，怎么办'),
        content: const SingleChildScrollView(
          child: EmphasizedText(
            '先说清楚：**你的账没有丢**。手机上的单据、库存都是从电脑同步过来的，'
            '电脑上的才是正本；打不开的这个文件是手机上的旧账本，'
            '它现在不装业务数据了，会原样留着、不会被删。\n\n'
            '想恢复「开单」和「改资料」，按顺序做：\n'
            '一、先点下面的「重试」—— 有时只是被清理软件或备份工具临时占着；\n'
            '二、到设置页点「立即同步」，把还没传上去的单推给电脑；\n'
            '三、再点「导出本机数据文件」，留一份带未同步单据清单的副本；\n'
            '四、做完上面两步后重装神算子，重新扫码连接电脑即可。\n\n'
            '⚠️ 重装会清掉手机上的一切副本，所以**第二步和第三步不能省**。',
            style: TextStyle(height: 1.6),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重试'),
          ),
        ],
      ),
    );
    if (retry != true || !mounted) return;
    await _retry();
  }

  /// **镜像隔离恢复**（2026-10-31 用户裁定「状态 3」，`docs/reply.md` §四）。
  ///
  /// ## 为什么不能只给「重试」
  ///
  /// 用户原话：「设置页现有的『重建本机数据副本』也存在这个限制：它先调用
  /// `_meta()`，而 `_meta()` 又会调用 `openMirror()`。镜像打不开时，
  /// 甚至无法进入真正的重建步骤。」—— 镜像文件一坏，**所有**需要打开它的
  /// 入口都跟着失效，用户被彻底锁死。
  ///
  /// ## 这一步做什么（六步，对应裁定原文）
  ///
  /// 1. 原件（`.db` + `-wal` + `-shm`）**改名留档**，一个字节不删；
  /// 2. 在**副本**上抢救 `sync_queue`（未 checkpoint 的条目在 `-wal` 里，必须带上）；
  /// 3. 把能抢回来的条目写回新副本，并落一份**抢救清单**（可发给技术支持）；
  /// 4. 建一份新的镜像库（同一台主机 ⇒ 不用重新扫码）；
  /// 5. 若还配着主机 ⇒ 立刻做一次**全量重拉**（新库游标为 0，天然从头拉）；
  /// 6. **救不回来的如实说出来** —— 不许假装全找回了。
  Future<void> _recoverBrokenMirror() async {
    final MobileSyncService? sync = _mobileSyncService;
    final String? root = widget.dataRoot;
    if (sync == null || root == null) return;
    final BuildContext? dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;

    final bool? confirmed = await showDialog<bool>(
      context: dialogContext,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('修复本机数据副本？'),
        content: const SingleChildScrollView(
          child: EmphasizedText(
            '会做四件事：\n'
            '一、把现在这份文件改名留档（不会删掉）；\n'
            '二、尽力把还没传给电脑的单抢出来；\n'
            '三、重新建一份空的副本；\n'
            '四、连上电脑后，把账从头拉一遍。\n\n'
            '⚠️ 抢不回来的单会**如实列出来**，不会假装都找回来了。'
            '电脑上的账不受影响。',
            style: TextStyle(height: 1.6),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('先不修'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('修复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _recoveringMirror = true);
    // 让「正在修复」那一帧先画出来，再开始拷文件（拷贝是同步 IO）
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;

    MirrorRecoveryResult result;
    String? reportPath;
    try {
      result = sync.recoverBrokenMirror(
        workDirectory: p.join(root, 'mirror', 'rescue-tmp'),
      );
      // 清单落在留档旁边（用户要发给技术支持时能直接找到）
      try {
        final String dir = p.dirname(sync.mirrorPath);
        final String name = '未同步单据抢救-${_rescueStamp(DateTime.now())}.txt';
        reportPath = p.join(dir, name);
        File(reportPath).writeAsStringSync(
          queueRescueReport(
            rescue: result.rescue,
            at: DateTime.now(),
            archivedPath: result.archivedPath,
          ),
          flush: true,
        );
      } catch (error, stack) {
        _log.crash(error, stack, label: '写抢救清单失败');
        reportPath = null;
      }
    } catch (error, stack) {
      // 领域层不抛（与主机服务同一条纪律），这里只兜「连兜都没兜住」的那种
      _log.crash(error, stack, label: '镜像隔离恢复失败');
      if (!mounted) return;
      setState(() => _recoveringMirror = false);
      final BuildContext? ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        await _migrationMessage(ctx, '修复没能完成：$error。原来的文件没有动，可以重试。');
      }
      return;
    }

    if (!mounted) return;
    setState(() => _recoveringMirror = false);
    _log.write(
      '镜像隔离恢复：抢回 ${result.restored} 条，'
      '读不出 ${result.rescue.unreadableRows} 条，'
      '写回失败 ${result.enqueueFailures} 条，'
      '留档 ${result.archivedPath ?? '（没有旧文件）'}',
    );

    final BuildContext? resultContext = _navigatorKey.currentContext;
    if (resultContext != null && resultContext.mounted) {
      await _showRecoveryResult(resultContext, result, reportPath: reportPath);
    }

    // 修完照常走启动流程（新副本已经能开了）；配着主机就顺手全量拉一遍
    _prepareMobile();
    if (result.ok && result.paired) {
      await _mobileSyncNow();
    }
  }

  /// 恢复结果的说明（**救不回来的必须说出来**）。
  Future<void> _showRecoveryResult(
    BuildContext context,
    MirrorRecoveryResult result, {
    String? reportPath,
  }) {
    final StringBuffer text = StringBuffer();
    if (!result.ok) {
      text.writeln('修复没能完成：${result.message}');
      text.writeln();
      text.writeln('原来的文件没有动过，可以再试一次。');
    } else {
      if (result.restored > 0) {
        text.writeln('抢回 ${result.restored} 条还没传给电脑的单，已经放回本机副本。');
        if (result.paired) {
          text.writeln('接下来会把账从头拉一遍，那些单也会重新推给电脑。');
        } else {
          text.writeln('扫码连上电脑后，它们会自动推过去。');
        }
      } else if (!result.rescue.ok) {
        // ⚠️ 「读不出来」与「本来就没有」是两件事 —— 不许混成一句
        // 「没有未传的单」（那是撒谎：我们根本没能看里面有什么）。
        text
          ..writeln('原来那份文件已经认不出来了，**里面有没有没传上去的单，现在无法确认**。')
          ..writeln('原因：${result.rescue.problem}');
      } else if (result.rescue.attempted) {
        text.writeln('这台手机上没有还没传上去的单 —— 不用找回什么。');
      } else {
        text.writeln('原来的副本文件已经不在了，直接建了一份新的。');
      }
      if (result.lostCount > 0) {
        text
          ..writeln()
          ..writeln(
            '⚠️ 另有 ${result.lostCount} 条没能找回（文件坏得太厉害）—— '
            '这部分内容没法还原，请不要当成已经找回来了。',
          );
      }
      if (!result.paired) {
        text
          ..writeln()
          ..writeln('这台手机还没连电脑：到「我的 → 设置」扫码，账就会拉回来。');
      }
    }
    if (reportPath != null) {
      // 只给文件名：完整私有路径在窄屏上要折四行，而且用户也点不进去。
      // 文件名 + 「和本机数据副本放在一起」足够支持人员定位。
      text
        ..writeln()
        ..writeln('详细清单已存成文件：${p.basename(reportPath)}')
        ..writeln('（和本机数据副本放在一起，需要时可以发给技术支持）');
    }
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(result.ok ? '修好了' : '没能修好'),
        content: SingleChildScrollView(
          child: EmphasizedText(text.toString(), style: const TextStyle(height: 1.6)),
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 清单文件名里的时间戳（`20261031-2205`，与备份文件名同风格）
  static String _rescueStamp(DateTime t) =>
      '${t.year}${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}-'
      '${t.hour.toString().padLeft(2, '0')}'
      '${t.minute.toString().padLeft(2, '0')}';

  /// 错误页的**重试**（§审查 2026-10-05 真机）。
  ///
  /// 不碰 `config.json`：只是把启动流程重跑一遍 —— 库修好了就原样回到原目录。
  Future<void> _retry() async {
    setState(() {
      _dbFailure = null;
      _brokenDirectory = null;
      _missingDatabaseDirectory = null;
      _alreadyRunning = false;
    });
    await _prepare();
  }

  /// 「新建一本空账」（只在「库文件不见了」时出现，2026-10-07）。
  ///
  /// 路径本来就对（目录 + 标记都在），所以**不碰 `config.json`**，只是在那份
  /// 标记所在的目录里建一份空库，然后把启动流程重跑一遍 —— 走的是
  /// 「目录与标记都在、库能打开」这条路，于是它和普通启动共用同一段代码。
  Future<void> _createEmptyDatabase() async {
    final String? directory = _missingDatabaseDirectory;
    if (directory == null) return;
    try {
      // ⚠️ 用 `DataDirectoryService` 的**转发面**（本类不含逻辑，见其文件头）：
      // `ensureInitialized` 就是底层的 `prepare` —— 它会认出「目录里有标记」⇒ 复用，
      // 不会重复写标记、也不会动 config（路径没变）
      final DataLocation location = _service.ensureInitialized(
        directory,
        acceptForeignDirectory: true,
      );
      _service.createEmptyDatabase(location);
    } catch (error, stack) {
      // #43（2026-10-16）：原始异常只进日志，界面给分类文案（M15 同款两通道）
      _log.crash(error, stack, label: '新建空账失败');
      if (!mounted) return;
      setState(() => _dbFailure = storageFailureNote(error));
      return;
    }
    await _retry();
  }

  /// 数据打不开时的出路：**直接弹目录选择框**（不经过自动解析）。
  ///
  /// §审查 BUG-03：坏库位置若仍能从配置解析出来，用户就会被困在
  /// 「点按钮 → 同一个错误页」的死循环里 —— 这里强制由用户挑一个新位置。
  Future<void> _pickAndOpen() async {
    final BuildContext? navContext = _navigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;

    final String? picked = await widget.pickDirectory();
    if (picked == null || picked.trim().isEmpty || !mounted) return;

    // 清掉旧状态（与失败分支同一份清单：库没了，依赖它的东西一起清）
    setState(() {
      _dbFailure = null;
      _brokenDirectory = null;
      _missingDatabaseDirectory = null;
      _alreadyRunning = false;
      _location = null;
      _db = null;
      _queries = null;
      _backup = null;
      _exports = null;
      _returns = null;
      _lastBackup = null;
      _backupError = null;
      _hasDocuments = false;
    });
    final HostServiceController? leavingHost = _hostService;
    _hostService = null;
    if (leavingHost != null) unawaited(leavingHost.stop());

    try {
      // 非空目录要用户再确认一次（与首启对话框同口径）
      final DataLocation location = _service.ensureInitialized(
        picked.trim(),
        acceptForeignDirectory: false,
      );
      _configStore.save(_config.copyWith(dataDirectory: location.directory));
      setState(() => _config = _configStore.load());
      _openDatabase(location);
    } on DataDirectoryRejected catch (error) {
      // 目录不可用 / 非空 —— 诚实展示原因与「怎么办」，用户可再点一次
      final BuildContext? retryContext = _navigatorKey.currentContext;
      if (retryContext == null || !retryContext.mounted) return;
      setState(
        () => _dbFailure = '${error.reason}。${error.howTo ?? '请再选一个文件夹。'}',
      );
    }
  }

  void _openDatabase(DataLocation location) {
    // §审查 OBS-14：**开库之前**先抢锁 —— 同一数据目录被两个实例同时打开，
    // 就是两条写路径（开单 / 核销 / **迁移**要关库）。第二个实例拦在这里。
    //
    // ⚠️ 锁拿不到 ≠ 数据有问题：单独一个状态，不给「换一个文件夹」这种出路。
    // ⚠️ `unavailable`（锁机制用不了）**必须放行** —— 锁是保护措施，
    //    不能变成新的故障点。
    final InstanceLockResult lock = _instanceLock.acquire(location.directory);
    if (lock == InstanceLockResult.alreadyRunning) {
      setState(() {
        _alreadyRunning = true;
        _dbFailure = null;
        _brokenDirectory = null;
      });
      return;
    }
    try {
      final Db db = _service.open(location);
      // T2：开库 + 迁移都已完成（`Db.open` 内部跑完迁移链才返回）
      StartupTrace.mark('T2_db_open');
      // 记下「这次测的是哪个库」—— 不然两轮数据分不清（小库 vs 478 MB 库）
      StartupTrace.noteDatabase(
        location.databasePath,
        File(location.databasePath).existsSync()
            ? File(location.databasePath).lengthSync() / (1024 * 1024)
            : null,
      );
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
        final Object? refreshError = _service.tryRefreshMarker(
          location,
          schemaVersion,
        );
        if (refreshError != null) {
          _log.write('刷新标记文件失败（$refreshError）—— 数据可正常使用，下次启动会再试');
        }
      }
      final BackupService backup =
          widget.backup ??
          BackupService(
            dataDirectory: location.directory,
            // 2026-10-22：用户可指定备份位置（默认仍 = 数据目录的兄弟目录）
            backupDirectory:
                _config.backupDirectory ?? location.backupDirectory,
            schemaVersion: schemaVersion,
            // #43：备份失败的原始异常进日志（界面只显示分类文案 —— 与
            // ExportService.onFailure 同款）
            onFailure: (Object error, StackTrace stack) =>
                _log.crash(error, stack, label: '备份失败'),
          );
      final ExportService exports = ExportService(
        exportDirectory: location.exportDirectory,
        // #35（2026-10-14）：写盘失败的**原始异常**进日志 —— 界面只显示
        // `localFileFailureAdvice` 的分类文案（原来把异常全文拼进了 SnackBar）。
        onFailure: (Object error, StackTrace stack) =>
            _log.crash(error, stack, label: '导出失败'),
      );
      setState(() {
        _location = location;
        _db = db;
        _dbTooNew = false;
        _schemaVersion = schemaVersion;
        // M16：主库开成功 ⇒ 清掉上一次的镜像失败（重试成功后不再停在错误页）
        _mirrorFailure = null;
        // 2026-10-31 联调 #0：本机账本开成功（含「重试」之后）⇒
        // 降级状态清零，顶部那条常驻说明自动消失、写入出口重新接上
        _localDbFailure = null;
        _queries = QueryDao(db);
        _backup = backup;
        _exports = exports;
        _products = ProductService(db);
        _purchases = PurchaseService(
          engine: _newEngine(db),
          queries: QueryDao(_db!),
        );
        _sales = SaleService(engine: _newEngine(db), queries: QueryDao(_db!));
        _deliveries = DeliveryService(
          engine: _newEngine(db),
          queries: QueryDao(_db!),
        );
        _accounts = AccountService(AccountDao(db));
        _parties = PartyService(PartyDao(db));
        // ⚠️ State 的实例字段不做类型提升 —— 刚赋值的 `_engine` 仍是 `RuleEngine?`，
        // 必须先落局部变量再传（`_engine!` 也能过，但局部变量让两处共享同一实例更明确）。
        final RuleEngine engine = _newEngine(db);
        _engine = engine;
        _settlements = SettlementService(db: db, engine: _newEngine(db));
        _returns = ReturnService(engine: engine, queries: QueryDao(db));
        // §AH · AH-A：主机同步服务。**只建对象，不启服务** ——
        // 监听端口必须由用户在设置页显式打开（遗漏 5）。
        // `host.json` 与库同目录（`auth.dart`：主机设施放文件、不动 schema）。
        // ⚠️ §BH·六 B1c（真机反馈 2026-10-04）：**Android 不是主机**（§AH 定位）
        // —— 不建主机服务，设置页的多设备区显示客户端引导（hostSyncNote）。
        _hostService = _shellKind == ShellKind.mobile
            ? null
            : HostServiceController(
                db: db,
                identities: HostIdentityStore(
                  hostIdentityFile(location.directory),
                ),
                // §CS·五 裁定 ③：同步内部的原始异常**只进日志**，
                // 客户端只收到一句中文（`syncFailureReason`）
                onInternalError:
                    (String label, Object error, StackTrace stack) =>
                        _log.crash(error, stack, label: label),
              );
        _dbFailure = null;
        _brokenDirectory = null;
        _alreadyRunning = false;
      });
      // T3：服务全部装配完（**在**自动备份之前 —— 备份是异步的，
      // 不该算进启动耗时；把它算进来会让首启数字随库大小漂）
      StartupTrace.mark('T3_services');
      // 先把状态读出来（设置页/概览页首帧就得有「上次备份」），
      // 再异步跑自动备份 —— **不 await**：用户马上要用软件
      _refreshBackupStatus();
      // T3b：备份状态读完（**同步**扫备份目录 + 一次 `SELECT 1`）。
      // 2026-10-28 实测：T3(14 ms) → 首屏开始构建(1.02 s) 之间空了 1 秒，
      // 最可能就是这一段在等磁盘（F: 若是机械盘/外置，首次访问要等它转起来）。
      StartupTrace.mark('T3b_backup_status');
      unawaited(_autoBackup());
    } on SchemaTooNewException catch (error) {
      // 旧版程序打开新版库：**文件一点没坏**，是软件版本不匹配。
      // 用单独一屏说清楚（不提供「从坏文件里找回」—— 那会把好数据改坏）。
      _log.write('库版本 ${error.dbVersion} 高于本程序 ${error.appVersion}（版本不匹配）');
      setState(() {
        _location = location;
        _db = null;
        _schemaVersion = 0;
        _queries = null;
        _dbTooNew = true;
        _brokenDirectory = location.directory;
        _dbFailure = _dbTooNewMessage(
          location.directory,
          dbVersion: error.dbVersion,
          appVersion: error.appVersion,
        );
      });
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
        // 导出只依赖「导出文件夹」，**不碰库** ⇒ 手机端降级时照旧可用
        // （桌面上库都打不开就没有数据可导，维持 `null`）
        _exports = _shellKind == ShellKind.mobile
            ? ExportService(
                exportDirectory: location.exportDirectory,
                onFailure: (Object error, StackTrace stack) =>
                    _log.crash(error, stack, label: '导出失败'),
              )
            : null;
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
        _returns = null;
        // §审查 OBS-13：原始异常只进日志（上面已 `_log.crash`）——
        // 界面只留结论 + 怎么办（中老年用户读不懂 SqliteException）
        _brokenDirectory = location.directory;
        if (_shellKind == ShellKind.mobile) {
          // 2026-10-31 联调 #0（用户裁定 A 第一阶段）：**手机端不拦人**。
          // 业务页全部读镜像 —— 本机这本空壳账坏了不该让整个 App 停在错误页。
          // 于是 `_dbFailure` 保持 `null`，改挂一条常驻说明 + 降级**只读**
          // （写入出口在 build 里按 `_localDbFailure != null` 全部摘掉）。
          _dbFailure = null;
          _localDbFailure = _localDatabaseBrokenMessage();
        } else {
          _dbFailure = _brokenDatabaseMessage(location.directory);
        }
      });
    }
  }

  /// 「更改数据位置」全流程（§BK·三，2026-10-05 裁定开工；七条工程细节全采纳）。
  ///
  /// 序列：选新位置 → 校验（嵌套 / 已存在 / 空间 ≥ 数据+备份+100MB，裁定 ①）
  /// → 二次确认（旧→新、文件数、大小）→ **关库**（先停 host 并等它收尾，裁定 ②）
  /// → `Isolate` 里拷贝 + 原子改名（进度经 `ReceivePort` 回流，裁定 ③）
  /// → 成功：更新 config（在 `%APPDATA%`，与数据分离 —— 裁定 ⑤）→ 重开库；
  /// 失败：删暂存（迁移器负责，裁定 ⑦）→ 原库重开 → 把话说清。
  Future<void> _migrateDataLocation() async {
    final DataLocation? current = _location;
    final Db? openingDb = _db;
    if (current == null || openingDb == null) return;
    // 库还没起来的界面不该出现「更改」按钮 —— 这里只做兜底
    if (_navigatorKey.currentContext == null) return;

    // ① 选新位置（与首启同一注入点 —— 测试传桩、生产系统选择器）
    final String? picked = await widget.pickDirectory();
    if (picked == null || picked.trim().isEmpty || !mounted) return;
    // 跨 async gap 后不持旧 context —— 每次从 navigatorKey 取新的；
    // ⚠️ 守卫必须用 **context 自己的 mounted** —— State 的 `mounted` 管不到
    // navigatorKey 取来的 context（lint use_build_context_synchronously 的判定）
    final BuildContext? navContext = _navigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;
    final String target = p.normalize(p.absolute(picked.trim()));

    // ② 校验（裁定 ①：空间算全；嵌套校验 `inspectMigration` 已备）
    final DirectoryAdvice advice = _service.policy.inspectMigration(
      current.directory,
      target,
    );
    if (!advice.isUsable) {
      await _migrationMessage(
        navContext,
        '${advice.reason}。${advice.advice ?? ''}',
      );
      return;
    }
    // ⚠️ §审查 2026-10-05 真机：用户选中的目录**本身就是神算子的数据目录**
    //（有标记文件）⇒ 这不是「迁移」，是**切回去用那个目录**。
    //
    // 为什么必须有这条路：下面「目标不能非空」的硬校验会把 `D://fed` 这种
    // **装过数据的目录**挡死 —— 而配置一旦被覆盖（旧代码在库损坏时会走首启
    // 向导、把 config 写成默认路径），用户就**再也回不到自己的数据**了。
    // 这条路**不搬任何文件**：只改 config 再开库，两边数据都原样留着。
    if (_service.isShensuanziDir(target)) {
      await _switchToExistingData(navContext, target);
      return;
    }
    final Directory targetDir = Directory(target);
    if (targetDir.existsSync() && targetDir.listSync().isNotEmpty) {
      await _migrationMessage(
        navContext,
        '目标文件夹已存在且有内容 —— 请选一个空文件夹，'
        '或者填一个还不存在的名字（会自动创建）',
      );
      return;
    }
    final DataMigrator migrator = DataMigrator(
      dataDirectory: current.directory,
      backupDirectory: current.backupDirectory,
      newDataDirectory: target,
      // 用户指定过备份位置 ⇒ 迁移后仍用同一个（不跟着数据目录搬家）
      newBackupDirectory:
          _config.backupDirectory ?? _service.policy.backupDirectoryFor(target),
    );
    final MigrationPlan plan = migrator.plan();
    final DriveInfo? drive = _environment.driveOf(target);
    if (drive != null &&
        drive.freeBytes != null &&
        drive.freeBytes! < plan.requiredBytes) {
      await _migrationMessage(
        navContext,
        '${drive.letter} 盘剩余空间不够：需要约 '
        '${formatBytes(plan.requiredBytes)}（数据 + 备份 + 余量），'
        '现在只剩 ${formatBytes(drive.freeBytes)}',
      );
      return;
    }

    // ③ 二次确认：危险操作说清下一步会发生什么
    final bool? confirmed = await showDialog<bool>(
      context: navContext,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('更改数据位置？'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '从 ${current.directory}',
                style: const TextStyle(height: 1.6),
              ),
              Text(
                '搬到 $target',
                style: const TextStyle(
                  height: 1.6,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '共 ${plan.fileCount} 个文件、约 ${formatBytes(plan.byteCount)}'
                '（含备份目录）。过程中会短暂不能开单，搬完自动继续。',
                style: const TextStyle(height: 1.6),
              ),
              const SizedBox(height: 8),
              Text(
                '原目录不会删除 —— 确认新位置好用之前，它是你唯一的完好备份。',
                style: TextStyle(
                  height: 1.6,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始迁移'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // 再取一次新 context（确认对话框已跨一个 async gap）
    final BuildContext? maskContext = _navigatorKey.currentContext;
    if (maskContext == null || !maskContext.mounted) return;

    // ④ 进度遮罩（裁定 ③：进度 + 请勿关闭；不可点掉）
    final ValueNotifier<MigrationProgress?> progress =
        ValueNotifier<MigrationProgress?>(null);
    final Completer<void> dialogClosed = Completer<void>();
    unawaited(
      showDialog<void>(
        context: maskContext,
        barrierDismissible: false,
        builder: (BuildContext context) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('正在搬数据…'),
            content: ValueListenableBuilder<MigrationProgress?>(
              valueListenable: progress,
              builder: (BuildContext context, MigrationProgress? value, _) {
                final int done = value?.filesCopied ?? 0;
                final int total = value?.totalFiles ?? 0;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    LinearProgressIndicator(value: value?.fraction),
                    const SizedBox(height: 12),
                    Text(
                      total == 0 ? '准备中…' : '已复制 $done / $total 个文件',
                      style: const TextStyle(height: 1.6),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '请勿关闭软件。',
                      style: TextStyle(
                        height: 1.6,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ).whenComplete(dialogClosed.complete),
    );

    // ⑤ 停 host（裁定 ②：不再收新请求 + 等在途收尾，带超时不无限等）
    final HostServiceController? host = _hostService;
    if (host != null) {
      try {
        await host.stop().timeout(const Duration(seconds: 3));
      } catch (_) {
        // 超时也继续 —— host 里没有未落库的数据（落库都在主机事务里完成）
      }
    }

    // ⑥ 关库 → Isolate 里搬文件（拷贝不再冻结界面，进度实时回流）
    openingDb.close();
    final ReceivePort progressPort = ReceivePort();
    // `ReceivePort` 本身没有 send —— 发送走它的 `sendPort`（我臆造 API 的教训）
    final SendPort progressSend = progressPort.sendPort;
    final StreamSubscription<dynamic> sub = progressPort.listen(
      (dynamic message) => progress.value = message as MigrationProgress?,
    );
    DataMigrationResult result;
    try {
      final DataMigrator worker = migrator;
      // ⚠️ isolate 入口必须是**顶层函数**（见文件末尾 `_runMigrationInIsolate`）：
      // 写成方法内闭包会沿作用域链把 State 的 Completer/Notifier 一起拖进
      // isolate 消息 —— 「object is unsendable」，真机炸过（§BK·三·补 2）
      result = await _runMigrationInIsolate(worker, progressSend);
    } catch (error, stack) {
      // #43：原始异常进日志；界面给「本地文件」分类文案（迁移 = 文件操作）
      _log.crash(error, stack, label: '数据迁移失败');
      result = DataMigrationResult.failed(localFileFailureAdvice(error));
    } finally {
      progressPort.close();
      await sub.cancel();
    }
    progress.value = MigrationProgress(
      filesCopied: plan.fileCount,
      totalFiles: plan.fileCount,
    );
    // 收起遮罩 —— **成功失败都要**：真机踩过「失败后遮罩永不消失」
    // （错误页盖在上面时看不出来，错误页一退它就露出来了）
    final BuildContext? popContext = _navigatorKey.currentContext;
    if (popContext != null && popContext.mounted) {
      Navigator.of(popContext, rootNavigator: true).pop();
    }
    await dialogClosed.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    if (!mounted) return;

    // ⑦ 成败处置
    if (result.ok) {
      final AppConfig updated = _config.copyWith(dataDirectory: target);
      _configStore.save(updated);
      setState(() => _config = updated);
      _openDatabase(_service.ensureInitialized(target));
      // 说明文件没写成**不算迁移失败**（2026-10-07，`docs/reply.md` §6 的 #10）：
      // 数据已经在新位置了，这里只是把「旧文件夹里没留说明」如实说一句
      _toast(
        result.warning == null
            ? '数据已迁移到 $target。原目录保留着，确认好用后可自行删除。'
            : '数据已迁移到 $target。${result.warning}',
      );
    } else {
      _openDatabase(current); // 旧位置原样 —— 立刻恢复可用
      _toast('没能搬过去（${result.error}）。数据还在原位置，软件已恢复。');
    }
  }

  /// **更改备份位置**（2026-10-22，用户实测反馈：备份目录不可写 ⇒ 死局）。
  ///
  /// 不搬数据、只改配置：备份是「数据目录的兄弟目录」的默认规则之外，
  /// 用户显式指定一个位置（写进 `backup_directory`）。
  Future<void> _changeBackupLocation() async {
    final String? picked = await widget.pickDirectory();
    if (picked == null || !mounted) return;
    final String target = p.normalize(picked);
    final AppConfig updated = _config.copyWith(backupDirectory: target);
    _configStore.save(updated);
    setState(() => _config = updated);
    _toast('备份位置已改为 $target。下次备份就放在这里。');
  }

  Future<void> _migrationMessage(BuildContext context, String message) =>
      showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('先停一下'),
          // 迁移结果的文案里有 `**先别删旧文件夹**`（`data_migrator.dart`）——
          // 用 EmphasizedText 才会真的加粗，否则星号原样显示
          content: EmphasizedText(message, style: const TextStyle(height: 1.6)),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

  void _toast(String message) {
    final BuildContext? dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;
    showSnack(
      dialogContext,
      SnackBar(content: Text(message), duration: const Duration(seconds: 8)),
    );
  }

  /// 「扫码连接主机」（§BL·三）：推扫码页（含相机理由文案与首拉），
  /// 回来后重建页面（裁定 ⑦：各页重查镜像库）。
  Future<void> _mobileScanPair() async {
    final MobileSyncService? service = _mobileSyncService;
    if (service == null) return;
    final BuildContext? context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final String? message = await showPairingScanPage(
      context,
      service,
      log: _log,
    );
    if (!mounted) return;
    setState(() {}); // 裁定 ⑦：镜像可能变了，全部页面重查
    if (message != null) {
      // C-2（2026-10-24）：换主机时队列条目会被挂起（含此前 `sent` 的）——
      // 必须**多说一句**（注释承诺过、从前没接线）：那几条是用户刚开的单，
      // 不说清楚他会以为还在自动补传。
      final int held = service.lastHostSwitchHeldEntries;
      _toast(
        held > 0
            ? '已连上新的电脑。有 $held 条单还没同步给旧电脑，'
                  '已暂停自动上传 —— 去「同步队列」确认要发到这台。'
            : message,
      );
    }
  }

  /// 「立即同步」（§BL·三，裁定 ③：B2 手动触发）。
  ///
  /// 裁定 ②：任何 401 / 403 ⇒ 配对失效 ⇒ **清除本地 pairing.json** +
  /// 提示重新扫码（面板会自动回到「扫码连接主机」态）。
  Future<void> _mobileSyncNow() async {
    final MobileSyncService? service = _mobileSyncService;
    if (service == null) return;
    final BuildContext? maskOwner = _navigatorKey.currentContext;
    if (maskOwner == null || !maskOwner.mounted) return;

    // 遮罩（小库同步是秒级；不做进度条 —— pull 分页拿不到总数，裁定 ⑥：
    // 拿不到总数就不放假进度条，给「正在同步」+ 请勿关闭）
    final Completer<void> dialogClosed = Completer<void>();
    unawaited(
      showDialog<void>(
        context: maskOwner,
        barrierDismissible: false,
        builder: (BuildContext context) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                const Text('正在同步…', style: TextStyle(height: 1.6)),
                const SizedBox(height: 8),
                Text(
                  '请勿关闭软件。',
                  style: TextStyle(
                    height: 1.6,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
        ),
      ).whenComplete(dialogClosed.complete),
    );

    SyncOutcome outcome;
    try {
      outcome = await service.syncNow();
    } catch (error) {
      // belt：服务层保证不抛，这里再兜一层（遮罩绝不能卡死）
      outcome = SyncOutcome(
        SyncOutcomeKind.error,
        '同步时出错（$error）—— 请重试；一直这样请把这句话告诉技术支持',
      );
    }

    // 收起遮罩（成功失败都要 —— 同遮罩教训 §BK·三·补 2）
    final BuildContext? popContext = _navigatorKey.currentContext;
    if (popContext != null && popContext.mounted) {
      Navigator.of(popContext, rootNavigator: true).pop();
    }
    await dialogClosed.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    if (!mounted) return;

    // P2 #8（2026-10-24）：清配对已收进 `MobileSyncService._authExpired`
    // （三条路径共用），这里**不再重复调用** —— 只留一句说明防回归。
    setState(() {}); // 裁定 ⑦：镜像可能变了 + 面板状态切换
    _toast(outcome.message);
  }

  /// **主数据提交成功**（2026-10-20）—— 与 [_onDocumentSubmitted] 逐字同构。
  ///
  /// 为什么单独一个而不是复用那个：`onDocumentSubmitted` 判的是
  /// `result.isQueued`（[DocumentSubmitResult]），这里是主数据的
  /// [MasterDataSubmitResult]，两个类型不通。**行为口径一致**：
  /// 先刷三态条（「待同步 N 条」立刻可见）→ 异步推一次 → 推完再刷。
  void _onMasterDataSubmitted() {
    setState(() {}); // 三态条重查
    final MobileSyncService? sync = _mobileSyncService;
    if (sync == null) return;
    unawaited(
      sync.autoPush().then((SyncOutcome _) {
        if (mounted) setState(() {}); // 失败也刷新：条目可能进了退避 / 死信
      }),
    );
  }

  /// 开单提交成功（B3b·§CA，手机端装配；桌面为 `null` 不走这里）。
  ///
  /// - **立即刷新**三态条（裁定 ②：保存后三态条马上变「待同步 N 条」）；
  /// - **异步推送一次**（裁定 ③）：不 await、不阻塞 UI，失败静默留队列；
  ///   推送结束后再刷一次（条目转 `sent` / 退避，三态条跟着变）。
  void _onDocumentSubmitted(DocumentSubmitResult result) {
    if (!result.isQueued) return; // 桌面结果不会到这里；防御
    setState(() {}); // 触发三态条重查（didUpdateWidget 以壳实例身份为版本号）
    final MobileSyncService? sync = _mobileSyncService;
    if (sync == null) return;
    unawaited(
      sync.autoPush().then((SyncOutcome _) {
        if (mounted) setState(() {}); // 失败也刷新（条目可能进了退避/死信）
      }),
    );
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
  /// ⚠️ 先让出一次事件循环再动库：备份要读库、写文件，别卡在「启动那一下」里 ——
  /// 用户先看到界面，备份在后面跑。
  ///
  /// 5a（2026-10-24，§CV·一百）：**文件拷贝已搬进 `Isolate.run`**
  /// （机械盘 100 MB ≈ 1–3 s，同步拷会把界面冻住）；`wal_checkpoint` 仍在
  /// 主线程（它要数据库连接，而连接不能跨 isolate）。
  ///
  /// **失败完全静默**（不弹窗、不阻塞）；失败原因留给 [_backupError]，
  /// 由概览橙卡与设置页呈现（§AE 遗漏 2：静默不等于永远看不见）。
  Future<void> _autoBackup() async {
    await Future<void>.delayed(Duration.zero);
    // 让出之后重新取值：期间可能失败重选位置 / 窗口被关掉
    final BackupService? backup = _backup;
    final Db? db = _db;
    if (!mounted || backup == null || db == null) return;
    // 5c：**超过 300 ms 还没跑完才提示** —— 小库瞬间完成时不该闪一下。
    _backupHintTimer?.cancel();
    _backupHintTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _backingUp = true);
    });
    try {
      final BackupOutcome outcome = await backup.autoBackup(
        db: db,
        hasContent: _hasDocuments,
      );
      _noteBackupOutcome(outcome);
      _refreshBackupStatus();
    } finally {
      _backupHintTimer?.cancel();
      if (mounted && _backingUp) setState(() => _backingUp = false);
    }
  }

  /// **「导出本机数据文件」**（原「导出备份到手机文件」；2026-10-07 按
  /// `docs/reply.md` §4 **B 方案**改口径）。
  ///
  /// ## 为什么不能叫「备份」（这一条是这次改动的全部理由）
  ///
  /// 手机是**移动开单终端**，权威数据在 Windows 主机上。叫「备份」会让用户
  /// 以为「手机上有备份，电脑坏了也没事」——而真正会丢的只有一样东西：
  /// **`sync_queue` 里还没推给主机的单**（`docs/reply.md` §4 原文）。
  /// 所以这个出口改名、挪到设置页深处，并把队列如实打包进去。
  ///
  /// ## 打进去什么
  ///
  /// 1. `shensuanzi_mirror.db` —— 镜像业务数据（可用任何 SQLite 工具打开，
  ///    符合「面向用户的输出优先开放格式」）
  /// 2. `shensuanzi.db` —— 主库（手机上通常是空壳，仍带上以便排查）
  /// 3. `未同步单据.txt` —— 队列里的人话清单 + 【重要】那句提示
  ///
  /// ⚠️ 两个库都**先 `wal_checkpoint(TRUNCATE)` 再拷**（与 `BackupService`
  /// 同一条纪律：WAL 模式下直接拷 `.db` 会丢未 checkpoint 的事务）。
  /// 打出来的文件放**应用私有目录下的 `export/`**（`file_selector` 在 Android
  /// 不支持「选保存位置」，所以只能先生成再交给系统分享面板）。
  Future<String> _exportBackupMobile() async {
    final DataLocation? location = _location;
    if (location == null) {
      return '数据文件还没打开，暂时不能导出';
    }
    final MobileSyncService? sync = _mobileSyncService;
    final Directory outDir = Directory(p.join(location.directory, '本机数据'));
    try {
      if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      outDir.createSync(recursive: true);
    } catch (error, stack) {
      // #43：原始异常进日志；界面给「本地文件」分类文案（建目录 = 文件操作）
      _log.crash(error, stack, label: '建导出文件夹失败');
      return localFileFailureAdvice(error);
    }

    final List<XFile> files = <XFile>[];
    String queueText = '这次没有未同步的单据 —— 刚开的单都已经推给电脑了。\n';
    try {
      if (sync != null) {
        final Db mirror = sync.openMirror();
        final List<SyncQueueEntry> unsent = SyncQueueDao(mirror).unsent();
        queueText = _unsentQueueText(unsent);
        _checkpoint(mirror);
        await _copyForExport(
          File(sync.mirrorPath),
          File(p.join(outDir.path, 'shensuanzi_mirror.db')),
        );
      }
      // 主库：真机历史上它可能是空壳，但排查时它是第一现场
      final File main = File(location.databasePath);
      if (main.existsSync()) {
        await _copyForExport(main, File(p.join(outDir.path, 'shensuanzi.db')));
      }
      final File note = File(p.join(outDir.path, '未同步单据.txt'));
      await note.writeAsString(queueText, flush: true);
      files.add(XFile(note.path));
      for (final String name in <String>[
        'shensuanzi_mirror.db',
        'shensuanzi.db',
      ]) {
        final File f = File(p.join(outDir.path, name));
        if (f.existsSync()) files.add(XFile(f.path));
      }
    } catch (error, stack) {
      // #43：原始异常进日志；界面给「本地文件」分类文案（拷贝/写文件）
      _log.crash(error, stack, label: '导出失败');
      return localFileFailureAdvice(error);
    }

    final ShareResult result = await SharePlus.instance.share(
      ShareParams(
        files: files,
        subject: '神算子本机数据-${formatFileDate(DateTime.now())}',
      ),
    );
    return switch (result.status) {
      ShareResultStatus.success =>
        '已唤起分享 —— 选「保存到文件」或发给微信即可。\n'
            '提醒：你的账本永远在电脑主机上，手机丢了不影响账；'
            '这里真正要紧的是还没传过去的单。',
      ShareResultStatus.dismissed => '已取消分享',
      ShareResultStatus.unavailable => '此设备暂不支持分享，请把这句话告诉技术支持',
    };
  }

  /// 导出前的落盘：WAL 中的事务必须先 checkpoint 回主库文件，
  /// 否则拷出来的 `.db` 会缺最新数据（`Agents.md` §四「备份模式」同一条纪律）。
  void _checkpoint(Db db) {
    try {
      db.raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (error) {
      _log.write('导出前 checkpoint 失败（$error）—— 继续导出，可能缺最新几笔');
    }
  }

  /// 异步拷贝（**在 UI 线程之外做文件 IO**：镜像库可能几十上百 MB，
  /// 同步拷会卡住界面；`BackupService` 那边是桌面后台，不必这么做）。
  Future<void> _copyForExport(File from, File to) async {
    await to.writeAsBytes(await from.readAsBytes(), flush: true);
  }

  /// 未同步单据的人话清单（也进分享的文件，用户拿它就能对账）。
  String _unsentQueueText(List<SyncQueueEntry> entries) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('未同步单据清单')
      ..writeln('生成时间：${DateTime.now()}')
      ..writeln('共 ${entries.length} 条还没传给电脑。')
      ..writeln()
      ..writeln('【重要】这些单只存在这台手机上。电脑主机上还没有它们 ——')
      ..writeln('手机丢了 / 卸载了，这部分就没了。请把左边的分享窗口发给')
      ..writeln('电脑（微信 / 邮件都行），然后在电脑上照着重新开一遍。')
      ..writeln();
    if (entries.isEmpty) {
      buffer.writeln('（没有未同步的单据）');
      return buffer.toString();
    }
    for (final SyncQueueEntry entry in entries) {
      buffer.writeln(
        '- 单号 ${entry.entityId}｜${entry.operation.wire}｜'
        '${entry.status.wire}｜开单时间 ${DateTime.fromMillisecondsSinceEpoch(entry.createdAt)}',
      );
    }
    return buffer.toString();
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
      // 日期选择器的左栏大字（「10月5 日周一」）默认用 headlineMedium（32px），
      // 在本应用的界面尺度里**过大**（发布后反馈 2026-10-05，100% 缩放仍大）。
      // 压回与正文协调的尺度；字体族随 ThemeData.fontFamily 自动继承。
      datePickerTheme: const DatePickerThemeData(
        headerHeadlineStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        headerHelpStyle: TextStyle(fontSize: 13),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '神算子',
      debugShowCheckedModeBanner: false,
      // 界面本地化（§BK·一）：Material 组件（日期选择器等）的文字用中文。
      // 没有这三行时 showDatePicker 全是英文 —— 用户反馈 2026-10-05 发布后。
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      locale: const Locale('zh'),
      // 启动流程要在首帧之后弹对话框，用它的 context（见 `_navigatorKey`）
      navigatorKey: _navigatorKey,
      theme: _theme,
      // SC-1：全局文字缩放（设置页五档 + 一键恢复默认）。
      //
      // 批 3 第 15 条：**系统字号与应用档位取较大值**，不再「应用覆盖系统」。
      // 原来那样会让「系统调大了、应用还是标准」的用户看到**更小**的字；
      // 而相乘会 1.3×2.0=2.6 倍直接崩界面（见 `effectiveTextScale` 注释）。
      builder: (BuildContext context, Widget? child) {
        final double system = MediaQuery.of(context).textScaler.scale(1.0);
        final double effective = effectiveTextScale(
          system: system,
          app: _config.uiScale.factor,
        );
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(effective)),
          child: child!,
        );
      },
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    // 备份文案跟当前时间有关（「今天 09:05」/「已经 4 天」）——
    // 每次 build 取一次当前时刻，跨天后下一次重绘就对了
    final DateTime now = DateTime.now();

    // §审查 OBS-14：已经在运行 —— 只给「重试」（用户关掉那个实例后再点）
    if (_alreadyRunning) {
      return _StartupPage(
        message:
            '神算子已经在运行了。\n请到任务栏找到它，不要重复打开。\n'
            '（同一个数据文件夹同时只允许一个神算子开着 —— '
            '同时开两个会有数据风险。）',
        actionLabel: '再试一次',
        onAction: _retry,
      );
    }
    if (_dbFailure != null) {
      // 「库文件不见了」有**三条**出路：找回备份（重试）/ 换一个文件夹 /
      // 明确放弃、新建一本空账（2026-10-07，`docs/reply.md` §6 的 #1）。
      final String? missing = _missingDatabaseDirectory;
      // 库比程序新 ⇒ **数据是好的**，只给「重试」和「更改」。
      // 「找回数据 / 从坏文件里找回」在这条路上是有害的：那是给坏文件用的，
      // 对一份完好的新库做抢救，只会把好数据弄坏。
      final bool tooNew = _dbTooNew;
      return _StartupPage(
        message: _dbFailure!,
        // 主路（2026-10-29 P0）：先让用户看见自己**有备份**。
        // 放在最前面 —— 它是这一屏唯一「不用放弃数据」的出路。
        recoveryLabel: tooNew ? null : '找回数据',
        onRecovery: tooNew ? null : _openRecovery,
        rescueLabel: tooNew ? null : '备份都不行？试试从坏文件里找回',
        onRescue: tooNew ? null : _openRescue,
        // 术语统一（§CV·八十 Q3）：按钮名与设置页/首启对话框一致，只叫「更改」
        actionLabel: '更改',
        // §审查 BUG-03：**必须强制弹目录选择框** —— 原来重新走 `_prepare()`，
        // 而 `resolved()` 会再次解析出同一个坏位置 ⇒ 反复点、反复回到错误页
        onAction: _pickAndOpen,
        // §审查 2026-10-05：知道是哪个目录打不开时，多给一条「重试」——
        // 用户把库修好（或关掉占用它的程序）就能**回到原来的数据**，
        // 不必放弃那个目录。不知道是哪个目录时不显示。
        retryLabel: _brokenDirectory == null ? null : '重试',
        onRetry: _brokenDirectory == null ? null : _retry,
        extraLabel: missing == null ? null : '新建一本空账',
        onExtra: missing == null ? null : _createEmptyDatabase,
      );
    }

    if (_recoveringMirror) {
      // 修复期间整页一句话：这一步在拷文件 + 建库，中途不能让人乱点
      return const _StartupPage(
        message: '正在修复本机数据副本……\n\n'
            '先把还没传上去的单抢救出来，再把原来那份文件留档、'
            '重新建一份空的 —— 期间请不要关掉软件。',
      );
    }

    if (_mirrorUnhealthy != null) {
      // 状态 2：开得起来但数据不对。文案与状态 3 分开写 —— 用户看到「打不开」
      // 会以为文件没了，其实文件在、只是内容有问题，处置是「修」而不是「救」。
      return _StartupPage(
        message:
            '手机上的数据副本自检没通过（${_mirrorUnhealthy!}）。\n\n'
            '电脑上的账没受影响。点「修复本机数据副本」就能修好：'
            '先把还没传上去的单抢出来，再把这份文件留档、重建一份空的，'
            '最后从电脑重新拉一遍。',
        actionLabel: '重试',
        onAction: _prepareMobile,
        extraLabel: '修复本机数据副本',
        onExtra: _recoverBrokenMirror,
      );
    }

    if (_mirrorFailure != null) {
      // M16（2026-10-08）：镜像打不开 —— 给**可操作的重试**。
      // 以前是在 build 期直接调 `openMirror()`，异常冒到框架 ⇒ 异常页，
      // 既没有导航也没有重试，用户只能重启（重启也可能还是坏的）。
      //
      // 2026-10-31（用户裁定「状态 3」，`docs/reply.md` §四）：镜像文件**打不开**
      // 时，光「重试」是死路 —— 设置页那个「重建本机数据副本」也进不去
      // （它先 `openMirror()`）。所以这里给一条**隔离恢复**：
      // 留档原件 → 独立抢救 `sync_queue` → 建新副本 → 全量重拉。
      return _StartupPage(
        message: _mirrorFailure!,
        actionLabel: '重试',
        onAction: _prepareMobile,
        extraLabel: '修复本机数据副本',
        onExtra: _recoverBrokenMirror,
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

    // §BH B1a：壳参数**装配一份**，桌面直接摆 / 移动端交给 MobileShell 持有。
    // B3b（§CA）：开单提交出口 —— 页面对它编程，无「是不是客户端」分支：
    // 桌面 = ServiceSink（落库+规则，与直连逐字同行为）；手机 = QueueSink（入队）。
    //
    // ⚠️ 降级只读（2026-10-31 用户裁定 A 第一阶段，`docs/reply.md` §三）：
    // 本机账本打不开时**不给提交出口** —— 这是「只读」真正落地的地方，
    // 不是把界面按钮画灰。用户原话：「暂时禁用开单、主数据修改等写入操作」，
    // 理由是还没逐页验证过每个提交出口都与旧主库解耦。
    final bool readOnly = _localDbFailure != null;
    final DocumentSink? documentSink;
    if (_shellKind == ShellKind.mobile) {
      final MobileSyncService? sync = _mobileSyncService;
      documentSink = sync == null || readOnly
          ? null
          : QueueSink(queue: SyncQueueDao(sync.openMirror()));
    } else {
      final SaleService? sales = _sales;
      final PurchaseService? purchases = _purchases;
      final DeliveryService? deliveries = _deliveries;
      documentSink = sales == null || purchases == null || deliveries == null
          ? null
          : ServiceSink(
              sales: sales,
              purchases: purchases,
              deliveries: deliveries,
            );
    }

    // C2·§CC 方案 1：手机端读面切**镜像**（主库废弃但保留 —— 边界见
    // `MirrorView` 类文档）。桌面分支维持主库服务，零变化。
    // ⚠️ 手机壳业务页用的服务全部构造在镜像 db 上；主数据的**建档/编辑**不再靠
    // 禁建兜底，而是走 `masterDataPolicy`（按能力门控）+ `masterDataSink`
    // （乐观写镜像 + 入队）—— 见下面那段装配。
    final Db? mirror = _shellKind == ShellKind.mobile
        ? _mobileSyncService?.openMirror()
        : null;
    final SaleService? shellSales = mirror == null
        ? _sales
        : SaleService(engine: _newEngine(mirror), queries: QueryDao(mirror));
    final PurchaseService? shellPurchases = mirror == null
        ? _purchases
        : PurchaseService(
            engine: _newEngine(mirror),
            queries: QueryDao(mirror),
          );
    final DeliveryService? shellDeliveries = mirror == null
        ? _deliveries
        : DeliveryService(
            engine: _newEngine(mirror),
            queries: QueryDao(mirror),
          );
    final ProductService? shellProducts = mirror == null
        ? _products
        : ProductService(mirror);
    final PartyService? shellParties = mirror == null
        ? _parties
        : PartyService(PartyDao(mirror));
    final AccountService? shellAccounts = mirror == null
        ? _accounts
        : AccountService(AccountDao(mirror));
    final QueryDao? shellQueries = mirror == null ? _queries : QueryDao(mirror);
    // 仅库存页期初入口用；手机上该入口被引导接管（engine 不会被调）
    final RuleEngine? shellEngine = mirror == null
        ? _engine
        : _newEngine(mirror);
    final StockDelta? stockDelta = mirror == null
        ? null
        : StockDelta(db: mirror, queue: SyncQueueDao(mirror));
    // D2b（`data_model.md §4.4` 第 3 条）：乐观行的「待同步」标记 —— 与 stockDelta
    // 同一份 mirror / 同一个队列，同一条件（桌面 `null` = 现状零变化）。
    final PendingMarks? pendingMarks = mirror == null
        ? null
        : PendingMarks(SyncQueueDao(mirror));
    // #27 批 2：商品流水查询 —— 手机壳 = 镜像实例化（与 products/queries
    // 同源，不存在误用主库）；桌面 = 主库（手机壳不显示成本列）。
    final StockLedgerDao? shellStockFlow = _shellKind == ShellKind.mobile
        ? (mirror == null ? null : StockLedgerDao(mirror))
        : (_db == null ? null : StockLedgerDao(_db!));

    // §CV·七 ① 乙（2026-10-09）：**主数据门控 + 提交出口**，与 documentSink 同构。
    //
    // 门控按**能力**（手机 v1 只开商品 —— §CH §8；往来 / 账户仍「保留入口 + 引导」）；
    // 出口桌面 = 落库、手机 = **乐观写镜像 + 入队**（同一个 `mirror` 上还挂着队列，
    // 所以行与队列条目同库同事务 —— 不会出现「行写了、条目没写」）。
    final MasterDataPolicy masterDataPolicy = _shellKind == ShellKind.mobile
        ? (readOnly
              ? const MasterDataPolicy.readOnly()
              : const MasterDataPolicy.mobile())
        : const MasterDataPolicy.desktop();
    final MasterDataSink? masterDataSink;
    // 2026-10-20（§CV·七十七）：**往来方**的手机队列出口。与商品同一条
    // `onEnqueued`（用户刚做完动作就推）；桌面恒 null ⇒ 走 PartyService。
    final QueuePartySink? partySink;
    if (_shellKind == ShellKind.mobile) {
      // 降级只读 ⇒ 出口全部为 null（与 `documentSink` 同一判据，见上）
      masterDataSink = mirror == null || readOnly
          ? null
          : QueueMasterSink(
              mirror: mirror,
              queue: SyncQueueDao(mirror),
              // 2026-10-20（用户实测：手机上建好的商品电脑看不到，要手动同步）：
              // 自动补传的触发点原本**只管单据**（开单后 / 回前台 / 手动）——
              // 手机 v1 后开的「商品建档」走的是另一条出口，那条路上没人推。
              // ⇒ 与「开单后」同性质：**用户刚做完一个可推送的动作就推一次**
              onEnqueued: _onMasterDataSubmitted,
            );
      partySink = mirror == null || readOnly
          ? null
          : QueuePartySink(
              mirror: mirror,
              queue: SyncQueueDao(mirror),
              onEnqueued: _onMasterDataSubmitted,
            );
    } else {
      final ProductService? products = _products;
      masterDataSink = products == null ? null : ServiceMasterSink(products);
      partySink = null;
    }

    // 2026-10-23：知道数据目录了 ⇒ 给配置加一条**必然可写**的兜底
    //（真机上 %APPDATA% 建不了文件，但数据目录能开库 ⇒ 一定写得进配置）
    _configStore.useDataDirectoryFallback(location.directory);

    final AppShell shell = AppShell(
      dataDirectory: location.directory,
      // 2026-10-22：用户指定的备份位置优先；否则跟随数据目录
      backupDirectory: _config.backupDirectory ?? location.backupDirectory,
      // 库打开成功后用真实数据格式版本；没打开时没有备份，回退标记版本
      schemaVersion: _schemaVersion > 0
          ? _schemaVersion
          : location.marker.schemaVersion,
      // ⚠️ 判据**跟壳走**（2026-10-31 联调 #0）：手机壳读的是镜像，
      // 本地账本坏掉（`_db == null`）不影响镜像可用 —— 否则概览页会显示
      // 「数据文件打不开，请到设置里换一个位置」，而手机上**没有**那个设置项。
      databaseReady: _shellKind == ShellKind.mobile
          ? mirror != null
          : _db != null,
      // 本机账本打不开时的常驻说明 + 「怎么办」（降级只读；桌面恒 null）
      localDbNotice: _localDbFailure,
      onLocalDbAdvice: _localDbFailure == null ? null : _showLocalDbAdvice,
      // 写入被关的原因 —— 手机壳「开单」tab 据此把三个入口画成不可点并说明
      readOnlyReason: _localDbFailure == null
          ? null
          : '本机账本打不开，开单和改资料暂时关闭（看数、查库存、查往来、导出都照常）。',
      products: shellProducts,
      purchases: shellPurchases,
      sales: shellSales,
      deliveries: shellDeliveries,
      documentSink: documentSink,
      onDocumentSubmitted: _shellKind == ShellKind.mobile
          ? _onDocumentSubmitted
          : null,
      // M15（2026-10-08）：开单保存失败 → 原始异常进日志，界面只给分类文案
      onStorageFailure: _onStorageFailure,
      stockDelta: stockDelta,
      pendingMarks: pendingMarks,
      // #27 批 2：商品流水查询（镜像 / 主库按壳取，同上）
      stockFlow: shellStockFlow,
      // #42 甲 · L4（2026-10-14 裁定）：读路径坏数据的计数。
      // 手机壳读的是**镜像库**、桌面读的是**主库** ⇒ 取 `mirror ?? _db`
      // （提示条只显示「这套壳正在读的那张库」的坏行；两张库不混算）。
      readFailures: (mirror ?? _db)?.readFailures,
      // §CV·七 ① 乙：主数据门控 + 出口。按壳判定（与上面 readOnly 同一理由）：
      // **不按 mirror 是否取到** —— 门控是「策略」，取不到 mirror 时 sink 为 null，
      // 相关页面退回 `_PendingPage`（宁可「数据未就绪」，也不给写不通的路）。
      masterDataPolicy: masterDataPolicy,
      masterDataSink: masterDataSink,
      partySink: partySink,
      // M05 / M07（2026-10-08）：同一份页面代码按壳给不同指引文案
      mobileShell: _shellKind == ShellKind.mobile,
      accounts: shellAccounts,
      parties: shellParties,
      queries: shellQueries,
      // ⚠️ 2026-10-31 联调 #4 的架构缺口：**手机端绝不能接本地库**。
      //
      // 手机上的主库是空壳（真机实测「备份文件里 0 商品 0 队列」），单据全在
      // 镜像里。原来这里写 `_db == null ? null : DocumentDao(_db!)` —— 手机 5 个
      // tab 里没有「单据」入口，所以是**潜在**缺口：一旦有人加了入口，
      // 列表会读一份空的 / 旧的副本，而界面看不出任何异常。
      // 现在：手机恒 `null`（真加了入口也是「正在开发」占位，不会读错库）；
      // 桌面照旧接主库，零变化。
      documents: _shellKind == ShellKind.mobile || _db == null
          ? null
          : DocumentDao(_db!),
      settlements: _settlements,
      returns: _returns,
      engine: shellEngine,
      hostService: _hostService,
      uiScale: _config.uiScale,
      // 月度对比：倍数（默认）还是百分数
      monthComparePercent: _config.monthComparePercent,
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
              // 5c：正在备份时先说「正在备份」，不说「上次备份是昨天」
              backingUp: _backingUp,
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
      // §BH·五 B1b 裁定 2：Android 私有目录用户打不开，概览显示友好文案
      // 而非具体路径（排查用的路径在帮助页「关于」小字里）
      dataLocationNote: _shellKind == ShellKind.mobile
          ? '数据存在应用私有目录（由系统管理）。'
          : null,
      // §BH·六 B1c（真机反馈 2026-10-04）：Android 设置页 —— 私有目录路径
      // 打不开、主机二维码不适用（Android 是客户端），均换友好文案
      dataPathsNote: _shellKind == ShellKind.mobile
          ? '数据存在应用私有目录（由系统管理）。卸载应用会删除全部数据 —— '
                '账本在电脑主机上，手机丢了不影响账；还没传过去的单可以用下面的'
                '「导出本机数据文件」发给电脑。'
          : null,
      hostSyncNote: _shellKind == ShellKind.mobile
          ? '手机版不做「主机」—— 与电脑连接这样用：\n'
                '一、到电脑上打开「设置 → 多设备同步」；\n'
                '二、用手机扫电脑上的二维码；\n'
                '三、连接后手机开单会自动推送到电脑（断网时先记在待同步队列，'
                '回到这个界面会自动再试一次，也可以点「立即同步」）。'
          : null,
      onExportBackup: _shellKind == ShellKind.mobile
          ? _exportBackupMobile
          : null,
      // §BK·三：更改数据位置 —— 桌面专属（Android 私有目录改不了）
      onMigrateData: _shellKind == ShellKind.mobile
          ? null
          : _migrateDataLocation,
      // 2026-10-22：备份位置可改（备份目录不可写时的出路）
      onChangeBackupLocation: _changeBackupLocation,
      // §BL·三：手机端同步（桌面是主机，无客户端同步）
      mobileSync: _mobileSyncService,
      onScanPair: _mobileScanPair,
      onSyncNow: _mobileSyncNow,
      // §AI-1：传**解析后**的实例（生产里 widget.configStore 是 null）
      configStore: _configStore,
      onConfigChanged: (AppConfig config) {
        // 一次设置变更一行（2026-10-23 真机排障总结）：这条是「用户到底改没改」
        // 的唯一证据 —— 没有它，「改了没生效」和「根本没改」看起来一模一样。
        // 写在 save 之前：save 抛异常也能留下痕迹。
        _log.write(
          '设置已变更：界面大小=${config.uiScale.label}'
          '（原 ${_config.uiScale.label}），'
          '店名=${config.shopName ?? '（空）'}',
          level: '信息',
        );
        _configStore.save(config);
        setState(() => _config = config);
      },
    );

    // §BH B1a：判断在 `shellKindFor`（纯 Dart，dart test 覆盖），这里只分支摆放。
    // 非 Android 一律桌面壳 ⇒ Windows 行为零变化；页面装配两壳共用
    // `appShellPage`（app_shell.dart），不存在「修桌面忘手机」的分叉面。
    if (_shellKind == ShellKind.mobile) {
      return MobileShell(shell: shell);
    }
    return shell;
  }
}

/// 还没进入主界面时的过渡页（选位置 / 开库失败）。
///
/// 刻意**不做**欢迎页、店名输入、账户预设 —— 那些按 `docs/reply.md` §五
/// 放到第 10 天回补。
class _StartupPage extends StatelessWidget {
  const _StartupPage({
    required this.message,
    // 2026-10-31：改成可选 —— 「正在修复本机数据副本」那一屏**不给按钮**
    // （修复期间不能让人乱点），但仍要复用这一页的排版。
    this.actionLabel,
    this.onAction,
    this.retryLabel,
    this.onRetry,
    this.extraLabel,
    this.onExtra,
    this.recoveryLabel,
    this.onRecovery,
    this.rescueLabel,
    this.onRescue,
  });

  final String message;

  /// 可选的「找回数据」入口（P0，提案 52）—— 数据文件打不开时才给。
  ///
  /// 单独一个字段而不是复用 [extraLabel]：数据文件「不见了」时两条路都要有
  /// （从备份接回来 / 明确放弃新建空账），复用就只能二选一。
  final String? recoveryLabel;
  final VoidCallback? onRecovery;

  /// 可选的「从坏文件里抢救」入口（P1，提案 52）。
  ///
  /// **刻意做成低调的文字按钮**：它是最后手段，结果不完整。
  /// 备份能用时不该有人走到这里。
  final String? rescueLabel;
  final VoidCallback? onRescue;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 可选的第二动作（如「重试」）；两个都为 `null` 时只显示主按钮
  final String? retryLabel;
  final VoidCallback? onRetry;

  /// 可选的第三动作（「库文件不见了」时才有的「新建一本空账」）——
  /// 由用户点，软件不替他决定（2026-10-07，`docs/reply.md` §6 的 #1）
  final String? extraLabel;
  final VoidCallback? onExtra;

  @override
  // 批 3 第 14 条：**整页可滚**。2.0 档 + 小窗口下，`Column` 会顶破屏幕
  // （按钮被推出可视区 = 用户点不到「重试」，等于卡死）。
  // `Center` 换成 `SingleChildScrollView` + 居中约束，内容超出时可滚。
  Widget build(BuildContext context) => Scaffold(
    body: SingleChildScrollView(
      child: ConstrainedBox(
        // 高度不足时也要能滚：给一个「至少一屏高」的最小高度，内容超了自然滚
        constraints: BoxConstraints(
          minHeight: MediaQuery.sizeOf(context).height,
        ),
        // 外层负责**居中**（滚动容器里的 ConstrainedBox 会左对齐，得自己包 Center）
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 文案里可能带 `**强调**`（如「更新版本」）——
                // 用 EmphasizedText 渲染，否则星号会原样显示在屏幕上
                //（2026-10-31 真机：`怎么办` 对话框里连星号一起显示）
                EmphasizedText(message, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                // 常驻可见的文字按钮，不用图标（`docs/ui_principles.md` §1.1）
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: <Widget>[
                    // 「找回数据」放最前面（2026-10-29 P0）：它是唯一
                    // 「不放弃原有数据」的出路，而用户此刻最怕的就是丢数据。
                    if (recoveryLabel != null && onRecovery != null)
                      FilledButton(
                        key: const Key('startup-recovery'),
                        onPressed: onRecovery,
                        child: Text(recoveryLabel!),
                      ),
                    // 「重试」放前面：它是**代价最小**的那条路（不用重选目录）
                    if (retryLabel != null && onRetry != null)
                      OutlinedButton(
                        onPressed: onRetry,
                        child: Text(retryLabel!),
                      ),
                    // 主按钮降为 tonal：有「找回数据」时，不该让「换个文件夹」
                    // 看起来是最该点的那个
                    if (actionLabel != null && onAction != null)
                      recoveryLabel != null && onRecovery != null
                          ? FilledButton.tonal(
                              onPressed: onAction,
                              child: Text(actionLabel!),
                            )
                          : FilledButton(
                              onPressed: onAction,
                              child: Text(actionLabel!),
                            ),
                    if (extraLabel != null && onExtra != null)
                      TextButton(onPressed: onExtra, child: Text(extraLabel!)),
                    // 抢救是最后手段：最不起眼的位置
                    if (rescueLabel != null && onRescue != null)
                      TextButton(
                        key: const Key('startup-rescue'),
                        onPressed: onRescue,
                        child: Text(rescueLabel!),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// 迁移的 **isolate 入口**（§BK·三·补 2）。
///
/// ⚠️ 必须是**顶层函数**：方法内闭包的上下文会沿作用域链拖走 State 的
/// `Completer` / `ValueNotifier`（都不可跨 isolate 发送）——
/// 真机炸过「object is unsendable: _AsyncCompleter」。顶层函数的闭包
/// 上下文只含这两个参数（`DataMigrator` 字段全为 String + null 函数，
/// `SendPort` 本就可发送），干净。
Future<DataMigrationResult> _runMigrationInIsolate(
  DataMigrator worker,
  SendPort progressSend,
) => Isolate.run<DataMigrationResult>(
  () => worker.execute(
    onProgress: (MigrationProgress value) => progressSend.send(value),
  ),
);
