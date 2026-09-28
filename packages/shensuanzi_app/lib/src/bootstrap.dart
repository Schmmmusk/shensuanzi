/// 启动时的路径解析（`docs/data_directory.md` §恢复逻辑）。
///
/// ```
/// 启动 → 读 config.json
///   ├─ 有路径 → 直接打开
///   └─ 没路径（首次 或 配置被清）→ 弹向导
///        用户选了某个目录后
///          ├─ 目录里有 .shensuanzi-data → 直接复用
///          └─ 目录为空 → 初始化
/// ```
///
/// 这条链的设计目标只有一个：**即使 `%APPDATA%` 被清理软件干掉，
/// 用户重选原目录，数据立刻回来** —— 不需要用户记住路径。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'app_config.dart';
import 'data_directory.dart';
import 'data_marker.dart';
import 'environment.dart';

/// 数据目录被拒绝（含「里面已经有别人的东西」）
class DataDirectoryRejected implements Exception {
  const DataDirectoryRejected(this.advice);

  final DirectoryAdvice advice;

  String get reason => advice.reason;

  String? get howTo => advice.advice;

  @override
  String toString() => 'DataDirectoryRejected(${advice.reason}'
      '${advice.advice == null ? '' : ' → ${advice.advice}'})';
}

/// 本次启动用哪个目录
class DataLocation {
  const DataLocation({
    required this.directory,
    required this.marker,
    required this.createdNow,
    required this.backupDirectory,
    required this.exportDirectory,
  });

  final String directory;
  final DataMarker marker;

  /// true = 本次新建（首次启动 / 换目录）；false = 复用已有数据
  final bool createdNow;

  /// 备份目录（数据目录的**兄弟目录**）。
  ///
  /// **由 [DataDirectoryPolicy.backupDirectoryFor] 算出后传进来，不在这里重算** ——
  /// 那里有一条「数据目录自己就叫『神算子备份』时避让」的边界处理，
  /// 在本类里再写一遍就等于两处逻辑并行，早晚漂移。
  final String backupDirectory;

  /// 导出目录（数据目录的**另一个**兄弟目录，§AF-3）。
  /// 同一个出处：[DataDirectoryPolicy.exportDirectoryFor]。
  final String exportDirectory;

  /// 数据库文件路径
  String get databasePath => p.join(directory, AppBootstrap.databaseFileName);

  @override
  String toString() =>
      'DataLocation($directory, ${createdNow ? '新建' : '复用'}, $marker)';
}

/// 应用启动器：路径解析 + 配置读写 + 打开数据库
class AppBootstrap {
  AppBootstrap({
    required this.environment,
    AppConfigStore? configStore,
  }) : policy = DataDirectoryPolicy(environment),
       configStore = configStore ?? AppConfigStore.forEnvironment(environment);

  static const String databaseFileName = 'shensuanzi.db';

  final AppEnvironment environment;
  final DataDirectoryPolicy policy;
  final AppConfigStore configStore;

  AppConfig loadConfig() => configStore.load();

  AppConfig saveConfig(AppConfig config) {
    configStore.save(config);
    return config;
  }

  /// 从配置解析出可用位置。
  ///
  /// 返回 `null` 表示**需要走向导**：没配过、配置指向的目录没了、
  /// 或者目录里的标记不见了（被搬走 / 被清空）。
  DataLocation? resolved() {
    final String? configured = loadConfig().dataDirectory;
    if (configured == null) return null;

    final DirectoryAdvice advice = policy.inspect(configured);
    if (!advice.isUsable) return null;

    final DirectoryContents contents = contentsOf(configured);
    if (contents != DirectoryContents.ours) return null;
    final DataMarker? marker = DataMarker.read(configured);
    if (marker == null) return null;

    return DataLocation(
      directory: p.normalize(configured),
      marker: marker,
      createdNow: false,
      backupDirectory: policy.backupDirectoryFor(configured),
      exportDirectory: policy.exportDirectoryFor(configured),
    );
  }

  /// 向导第 2 步：用户选定目录后调用。
  ///
  /// 拒绝时抛 [DataDirectoryRejected]（**带「怎么办」**，UI 直接展示）。
  ///
  /// [acceptForeignDirectory] 为 `false`（默认）时，**非空且没有标记**的目录
  /// 会被拒绝 —— 避免把数据库丢进用户放了别的东西的文件夹里。
  /// 用户在 UI 上确认过（「我就要用这个文件夹」）之后再传 `true`。
  DataLocation prepare(
    String path, {
    bool acceptForeignDirectory = false,
    int? now,
  }) {
    final DirectoryAdvice advice = policy.inspect(path);
    if (!advice.isUsable) throw DataDirectoryRejected(advice);

    final int stamp = now ?? DateTime.now().millisecondsSinceEpoch;
    final String directory = p.normalize(path);
    final DirectoryContents contents = contentsOf(directory);

    if (contents == DirectoryContents.foreign && !acceptForeignDirectory) {
      throw const DataDirectoryRejected(
        DirectoryAdvice(
          DirectoryVerdict.reject,
          '这个文件夹里已经有别的东西',
          advice: '换一个空文件夹，或新建一个；'
              '确实要放在这里的话，请再确认一次',
        ),
      );
    }

    final DataMarker marker;
    final bool createdNow;
    if (contents == DirectoryContents.ours) {
      marker = DataMarker.read(directory)!;
      createdNow = false;
    } else {
      Directory(directory).createSync(recursive: true);
      marker = DataMarker.write(
        directory,
        schemaVersion: Schema.version,
        now: stamp,
      );
      createdNow = true;
    }

    saveConfig(loadConfig().copyWith(dataDirectory: directory));
    return DataLocation(
      directory: directory,
      marker: marker,
      createdNow: createdNow,
      backupDirectory: policy.backupDirectoryFor(directory),
      exportDirectory: policy.exportDirectoryFor(directory),
    );
  }

  /// 打开数据目录里的数据库（主机端：外键**开启**，主机是权威）。
  ///
  /// ⚠️ 客户端镜像相反 —— 必须 `foreignKeys: false`（见 `SyncClient` 构造函数）。
  Db open(DataLocation location) => Db.open(location.databasePath);

  /// 迁移前检查：目标能否用、会不会把数据搬进自己的备份里。
  ///
  /// ⚠️ **逻辑在 [DataDirectoryPolicy.inspectMigration]**，这里是给 UI 的转发入口。
  /// **不在这里再写一遍** —— 两处并行就等着漂移。
  DirectoryAdvice inspectMigration(String from, String to) =>
      policy.inspectMigration(from, to);
}
