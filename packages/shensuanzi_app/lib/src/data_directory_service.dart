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

  /// 展示用容量提示，如 `D 盘剩余 128 GB`；拿不到返回 `null`（不编一个值）。
  String? spaceHint(String path) => policy.spaceHint(path);

  /// 打开数据目录里的数据库。**主机端：外键开启**（主机是权威）；
  /// 客户端镜像相反，必须 `foreignKeys: false`（见 `SyncClient`）。
  Db open(DataLocation location) => bootstrap.open(location);
}
