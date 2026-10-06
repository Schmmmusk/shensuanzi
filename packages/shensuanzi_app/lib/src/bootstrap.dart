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
import 'startup.dart';

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
    final DataLocation? location = _configuredLocation();
    if (location == null) return null;
    // §审查 BUG-03：目录与标记都在 ≠ 库能用 —— 再加一步**可打开性探测**
    if (!Db.probe(location.databasePath)) return null;
    return location;
  }

  /// 「配置里的位置**目录与标记都在，但库打不开**」时返回那个位置；否则 `null`。
  ///
  /// ⚠️ **为什么必须把它与 [resolved] 的 `null` 分开**（§审查 2026-10-05 真机）：
  /// 库损坏时若一律 `null`，启动流程会当成「首次启动」**弹选目录向导**，
  /// 而向导会把 `config.json` 写成一个**新**路径 —— 用户原来的目录
  /// （实测 `D://fed`）就**再也切不回去**了（配置里已经没有它）。
  ///
  /// ⇒ 这种情况要停在**错误页**：把原路径摆出来，给「重试」（库修好即原样回来）
  /// 与「换一个文件夹」两条出路，**绝不覆盖配置**。
  DataLocation? unusableConfigured() {
    final DataLocation? location = _configuredLocation();
    if (location == null) return null;
    return Db.probe(location.databasePath) ? null : location;
  }

  /// 配置文件的读取状态（§审查 OBS-15）—— `absent` 才是真·第一次启动。
  AppConfigLoadStatus configStatus() => configStore.status();

  /// 这个目录是不是神算子的数据目录（**只看标记文件**，不看内容与合法性）。
  bool isShensuanziDir(String path) => DataMarker.existsIn(path);

  /// 本次启动落在哪个场景（§审查「启动路径健壮性」批次，见 `startup.dart`）。
  ///
  /// **只判定，不落盘** —— 留档（`.corrupt`）与抢救都是写操作，由调用方按
  /// [StartupDecision.scenario] 决定做不做。判定保持纯函数，才能用 `dart test` 钉住。
  ///
  /// 这条链把先前散在 `app.dart` 的四个边界（BUG-03 坏库 / OBS-15 配置损坏 /
  /// OBS-11 首启撞已有数据 / 位置失效）**收成一次判定**，避免顺序打架。
  ///
  /// ## [defaultDataDirectory]：**只替换「机器给的那个值」**
  ///
  /// 这是一个**参数**，不是「机器环境的替身」（§BR·补 2 裁定 方案 B）——
  /// 注入它之后，判定**照样拿这个路径去真实文件系统问**「有没有 `.shensuanzi-data`」
  /// （[isShensuanziDir] → `existsSync`）。**别拿它当先例去论证「注入整个
  /// `AppEnvironment` 也行」**：那是把真实机器换成假的，`AGENTS.md` §4.3 明令禁止。
  ///
  /// - `null` = 用机器算出来的默认位置（[DataDirectoryPolicy.defaultDataDirectory]）
  ///   —— **生产行为，一个字都不变**
  /// - 非 `null` = **只在「真·第一次启动」那一支**替换这一个值；
  ///   配置里已有路径时它**不参与任何判定**
  StartupDecision startupDecision({String? defaultDataDirectory}) {
    final AppConfigLoadStatus status = configStore.status();

    if (status == AppConfigLoadStatus.ok) {
      // ⚠️ **复用** [resolved] / [unusableConfigured] —— 不在这里再写一遍
      // 「库能不能打开」的判断：那样就有两处并行，早晚漂移（纪律 17）。
      final DataLocation? existing = resolved();
      if (existing != null) return StartupDecision.openExisting(existing);
      final DataLocation? broken = unusableConfigured();
      if (broken != null) return StartupDecision.brokenDatabase(broken);
      // 位置记着，但目录 / 标记现在用不了（被搬走、盘符变了……）——
      // 走向导，但**不许**说「第一次启动」（§AG 遗漏 1）
      return StartupDecision.recoverLocation(
        previousPath: loadConfig().dataDirectory,
      );
    }

    if (status == AppConfigLoadStatus.locationLost) {
      // §审查 OBS-15：从原始文本里抢救原位置；**救得到且库也能开**才算数
      //（`salvagedLocation` 只解析位置，不 probe —— 见它的文档）
      final DataLocation? salvaged = salvagedLocation();
      if (salvaged != null && Db.probe(salvaged.databasePath)) {
        return StartupDecision.salvageConfig(salvaged);
      }
      return const StartupDecision.recoverLocation();
    }

    // absent = 真·第一次启动。但**默认位置可能已经有数据**（§审查 OBS-11 前半：
    // 重装软件 / 解压到别处 / 双击第二份 exe 都会撞上）—— 那就要先问一句，
    // 不能直接点「开始使用」挂上去。
    //
    // ⚠️ 这是 [defaultDataDirectory] **唯一**被读的地方（见方法头注释）。
    final String defaultPath =
        defaultDataDirectory ?? policy.defaultDataDirectory();
    return isShensuanziDir(defaultPath)
        ? StartupDecision.firstRunWithData(defaultPath)
        : const StartupDecision.welcome();
  }

  /// 配置**读不懂 / 位置丢了**时，从原始文本里抢救原位置（§审查 OBS-15）。
  ///
  /// 救回来就能**自动回到用户原来的数据**（见 `app.dart` 的 `_prepare`），
  /// 不必让用户自己回忆路径 —— 这是 OBS-15 最好的收场：他根本不会察觉出过问题。
  ///
  /// ⚠️ **本方法只解析位置，不探测库能不能打开** —— 「打不开怎么办」由调用方
  /// 决定（[startupDecision] 会在救不到可用的库时退到「走向导」，
  /// 而别的调用方可能只想看看「原来是什么路径」）。
  DataLocation? salvagedLocation() =>
      _locationFrom(configStore.salvageDataDirectory());

  /// 把读不懂的配置另存一份 `config.json.corrupt`（**不删原件**）—— 人工退路。
  void preserveCorruptConfig() => configStore.preserveCorruptCopy();

  /// 配置位置的前置检查（**不含**「库能不能打开」这一步）—— 上面几个方法的共用体。
  DataLocation? _configuredLocation() =>
      _locationFrom(loadConfig().dataDirectory);

  DataLocation? _locationFrom(String? configured) {
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

  /// 迁移成功后，把标记文件的版本刷新到**库的真实版本**。
  ///
  /// ## 三处版本号的关系（reply.md Schema 篇 §3.3）
  ///
  /// | 位置 | 是什么 | 参与迁移判定？ |
  /// |---|---|---|
  /// | `Schema.version` | 当前代码的能力 | — |
  /// | `PRAGMA user_version` | 这个库文件的现状 | ✅ **唯一依据** |
  /// | 标记文件的 `schema_version` | 这个目录**最后一次被哪个版本操作过** | ❌ 只是「目录身份证」 |
  ///
  /// 身份证不参与判定，但**升级之后得跟上** —— 否则每次启动都会觉得
  /// 「三处版本号不一致」，诊断日志永远在喊狼来了。
  DataMarker refreshMarker(DataLocation location, int schemaVersion) =>
      DataMarker.write(
        location.directory,
        schemaVersion: schemaVersion,
        now: DateTime.now().millisecondsSinceEpoch,
      );

  /// [refreshMarker] 的**不抛版本**（§AQ·六 方案 A，2026-10-02 裁定）。
  ///
  /// ## 为什么要它
  ///
  /// 刷新标记是**诊断性辅助动作** —— 只做「把目录身份证跟上库的真实版本」。
  /// 但它里面是**真实文件写入**（[DataMarker.write]）：目录变只读 / 磁盘满时**会抛**。
  /// 而调用方 `_openDatabase` 里它与 `Db.open` **同处一个 `try`** ⇒
  /// 一个辅助动作能把**开得好好的库**连坐成「数据文件打不开」，整页不可用。
  ///
  /// ## 契约
  ///
  /// 返回 `null` = 成功；否则返回失败的异常对象。**由调用方记日志** ——
  /// 本层不知道日志该写去哪：`AppLog` 的路径是从**配置位置**推导的，
  /// 在这里再推一次就是**第二处路径推导**（`log.dart` 文件头明令避免）。
  ///
  /// ## 失败的影响面极小
  ///
  /// 标记没刷新 ⇒ 下次启动**再判一次**「三处版本号不一致」，多一条日志而已，
  /// **没有功能损失**。所以「不抛」在这里是严格更优的。
  Object? tryRefreshMarker(DataLocation location, int schemaVersion) {
    try {
      refreshMarker(location, schemaVersion);
      return null;
    } catch (error) {
      return error;
    }
  }

  /// 迁移前检查：目标能否用、会不会把数据搬进自己的备份里。
  ///
  /// ⚠️ **逻辑在 [DataDirectoryPolicy.inspectMigration]**，这里是给 UI 的转发入口。
  /// **不在这里再写一遍** —— 两处并行就等着漂移。
  DirectoryAdvice inspectMigration(String from, String to) =>
      policy.inspectMigration(from, to);
}
