/// 数据目录服务 —— **UI 面对的唯一入口**。
///
/// 四个方法名取自 `docs/reply.md` §四 的能力清单：
/// `resolveDefault` / `validate` / `ensureInitialized` / `isShensuanziDir`。
/// 命名成「意图」而不是沿用底层名（`defaultDataDirectory` / `inspect` /
/// `prepare`），是为了让 UI 代码读起来就是那份清单。
///
/// ## ⚠️ 本类**不含逻辑**
///
/// 全部转发给两层：
///
/// | 层 | 管什么 | 特征 |
/// |---|---|---|
/// | `DataDirectoryPolicy` | 默认位置、校验、容量提示、迁移校验 | **纯函数**，不碰磁盘 |
/// | `AppBootstrap` | 初始化（建目录 / 写标记 / 记配置）、启动恢复、开库 | **会落盘** |
///
/// 逻辑只写在那一份。**这里若复制一份判断，两处就会漂移** ——
/// 之前 `DataLocation.backupDirectory` 复制过一次备份目录的算法，
/// 就属于同类问题。所以本类只做「改名 + 转发」。
library;

import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'app_config.dart';
import 'bootstrap.dart';
import 'data_directory.dart';
import 'data_marker.dart';
import 'environment.dart';
import 'startup.dart';

class DataDirectoryService {
  DataDirectoryService({
    required this.environment,
    AppConfigStore? configStore,
  }) : bootstrap = AppBootstrap(
         environment: environment,
         configStore: configStore,
       );

  final AppEnvironment environment;
  final AppBootstrap bootstrap;

  DataDirectoryPolicy get policy => bootstrap.policy;

  /// ① **默认位置** —— `D:\神算子数据\`，没有可用的非系统盘时
  /// 退到 `C:\Users\<你>\神算子数据\`。
  ///
  /// 首次启动**不弹框**，直接把这个值填进对话框让用户确认或更改。
  String resolveDefault() => policy.defaultDataDirectory();

  /// ② **校验** —— 返回 `ok` / `warn`（能用但有代价）/ `reject`。
  ///
  /// 警告**不拦人**（`DirectoryAdvice.isUsable` 对 `warn` 是 `true`）：
  /// 中老年用户被拦住会认为「软件坏了」。
  DirectoryAdvice validate(String path) => policy.inspect(path);

  /// ③ **初始化** —— 创建目录 + 写 `.shensuanzi-data` + 记住路径。
  ///
  /// - 目录里已有标记 → **复用**（返回的 `createdNow == false`，数据立刻回来）
  /// - 目录非空且无标记 → 默认拒绝；用户在 UI 上确认过才传
  ///   `acceptForeignDirectory: true`
  ///
  /// 被拒绝时抛 [DataDirectoryRejected]，异常里**带「怎么办」**，UI 直接展示。
  DataLocation ensureInitialized(
    String path, {
    bool acceptForeignDirectory = false,
    int? now,
  }) => bootstrap.prepare(
    path,
    acceptForeignDirectory: acceptForeignDirectory,
    now: now,
  );

  /// ④ **这个目录是不是神算子的数据目录**（只看标记文件，不看内容和合法性）。
  ///
  /// 用来回答用户的「我以前的数据还在吗」—— 选中老目录时立刻能看出来。
  bool isShensuanziDir(String path) => DataMarker.existsIn(path);

  /// 启动时用：配置里记的位置**现在仍然可用**才能直接用。
  ///
  /// 返回 `null` 表示**要弹对话框**：没配过、目录没了、标记不见了、或路径已非法。
  DataLocation? existing() => bootstrap.resolved();

  /// 配置里的位置**目录与标记都在、只是库打不开** ⇒ 返回它（否则 `null`）。
  ///
  /// ⚠️ 调用方**不许**把它当成「首次启动」去弹向导 —— 走向导会覆盖
  /// `config.json`，用户原来的目录就找不回来了（§审查 2026-10-05 真机）。
  /// 正确处置：停在错误页 + 显示这个路径 + 给「重试」。
  DataLocation? unusableExisting() => bootstrap.unusableConfigured();

  /// 配置里的位置**目录与标记都在、但库文件本身不见了** ⇒ 返回它（否则 `null`）。
  ///
  /// ⚠️ **必须在碰库之前判**（判据是 `File.existsSync`，不是 `Db.probe` ——
  /// probe 对不存在的文件是「创建」，见 `startup.dart` 的 `missingDatabase`）。
  DataLocation? missingExisting() => bootstrap.missingConfigured();

  /// 用户确认「没有备份可恢复、就新建一本空账」时调用（见 [missingExisting]）。
  ///
  /// 已经存在同名文件时**不覆盖**（抛 `StateError`）—— 那是用户刚拷回来的真库。
  void createEmptyDatabase(DataLocation location) =>
      bootstrap.createEmptyDatabase(location);

  /// 配置文件的状态（§审查 OBS-15）：`absent` 才是真·第一次启动。
  AppConfigLoadStatus configStatus() => bootstrap.configStatus();

  /// **本次启动落在哪个场景**（§审查「启动路径健壮性」批次）。
  ///
  /// 把先前散在 UI 里的四个启动边界（BUG-03 坏库 / OBS-15 配置损坏 /
  /// OBS-11 首启撞已有数据 / 位置失效）收成一次判定，见 `startup.dart`。
  /// 本方法**只转发** —— 与其他方法一致（见文件头「本类不含逻辑」）。
  ///
  /// [defaultDataDirectory]：**只替换「机器给的默认位置」那一个值**（§BR·补 2
  /// 裁定 方案 B，仅供测试注入）；`null` = 用真实机器的默认值，生产行为不变。
  /// ⚠️ 它是**参数**不是「机器替身」——判定照样去真实文件系统问「有没有标记」。
  StartupDecision startupDecision({String? defaultDataDirectory}) =>
      bootstrap.startupDecision(defaultDataDirectory: defaultDataDirectory);

  /// 配置读不懂时从原文**抢救**原位置；救不到返回 `null`。
  DataLocation? salvagedExisting() => bootstrap.salvagedLocation();

  /// 把读不懂的配置另存 `config.json.corrupt`（不删原件）。
  void preserveCorruptConfig() => bootstrap.preserveCorruptConfig();

  /// 展示用容量提示，如 `D 盘剩余 128 GB`；拿不到返回 `null`（不编一个值）。
  String? spaceHint(String path) => policy.spaceHint(path);

  /// 打开数据目录里的数据库。**主机端：外键开启**（主机是权威）；
  /// 客户端镜像相反，必须 `foreignKeys: false`（见 `SyncClient`）。
  Db open(DataLocation location) => bootstrap.open(location);

  /// 迁移成功后把标记文件的版本刷新到**库的真实版本**。
  ///
  /// 标记只是「目录身份证」、不参与迁移判定（见 `AppBootstrap.refreshMarker`），
  /// 但升级后得跟上 —— 否则每次启动都判「三处版本号不一致」。
  DataMarker refreshMarker(DataLocation location, int schemaVersion) =>
      bootstrap.refreshMarker(location, schemaVersion);

  /// [refreshMarker] 的**不抛版本** —— 失败返回原因（`null` = 成功），
  /// 由 UI 记日志（§AQ·六 方案 A / 2026-10-02 裁定）。
  ///
  /// **启动路径一律用这个**：刷新标记只是诊断辅助，不该把可用软件弄挂。
  ///
  /// 本方法**只转发**（判据在 `AppBootstrap.tryRefreshMarker`）——
  /// 与本类其余方法一致，见文件头「本类不含逻辑」。
  Object? tryRefreshMarker(DataLocation location, int schemaVersion) =>
      bootstrap.tryRefreshMarker(location, schemaVersion);
}
