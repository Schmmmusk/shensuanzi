/// 应用配置（`docs/data_directory.md` §配置）。
///
/// ⚠️ **配置不是数据**：它只记「上次选的路径」「界面缩放」这类**设备偏好**。
/// 放在 `%APPDATA%\神算子\config.json` —— 被清理软件删掉只丢偏好，
/// **经营数据一行都不会少**（这也是为什么路径恢复不依赖配置，见 `bootstrap.dart`）。
library;


import 'dart:convert';
import 'dart:io' show Directory, File, Process, ProcessResult, sleep;

import 'package:path/path.dart' as p;

import 'environment.dart';

/// 界面缩放档位（`docs/ui_principles.md`）
enum UiScale {
  small('小', 1.0),
  standard('标准', 1.25),
  large('大', 1.5),
  huge('特大', 1.75),
  giant('超大', 2.0);

  const UiScale(this.label, this.factor);

  final String label;
  final double factor;

  /// 默认 **125%**：Windows 上 1080p 显示器很多用户本来就调到 125%，
  /// 神算子跟上，用户第一眼看到的就是「合适的大小」。
  static const UiScale defaultScale = UiScale.standard;

  static UiScale? fromFactor(Object? raw) {
    if (raw is num) {
      for (final UiScale scale in UiScale.values) {
        if ((scale.factor - raw.toDouble()).abs() < 0.001) return scale;
      }
    }
    return null;
  }
}

class AppConfig {
  const AppConfig({
    this.dataDirectory,
    this.uiScale = UiScale.defaultScale,
    this.backupDirectory,
    this.shopName,
  });

  /// `null` = 还没选过（→ 走向导）
  final String? dataDirectory;

  final UiScale uiScale;

  /// **备份位置**（2026-10-22，用户实测：备份目录不可写时没有出路）。
  ///
  /// `null` = 跟随数据目录的兄弟目录（默认行为，老配置零变化）；
  /// 用户手动指定后写进 `backup_directory`，启动与备份都照它走。
  final String? backupDirectory;

  /// 店名（向导第 3 步，可跳过）
  final String? shopName;

  AppConfig copyWith({
    String? dataDirectory,
    UiScale? uiScale,
    String? shopName,
    bool clearShopName = false,
    String? backupDirectory,
  }) => AppConfig(
    dataDirectory: dataDirectory ?? this.dataDirectory,
    uiScale: uiScale ?? this.uiScale,
    backupDirectory: backupDirectory ?? this.backupDirectory, // ignore: unnecessary_this —— 与上下两行同形
    // 上面三行的 this. 都是「不传就保留原值」—— 统一保留，删一处反而不一致
    shopName: clearShopName ? null : (shopName ?? this.shopName),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'data_directory': dataDirectory,
    'ui_scale': uiScale.factor,
    if (backupDirectory != null) 'backup_directory': backupDirectory,
    'shop_name': shopName,
  };

  /// **容错解析**：任何字段不认识 / 类型不对 → 退回默认值，不抛。
  ///
  /// 配置文件是**外部输入**（用户手改、旧版本写的、被清理软件写坏过），
  /// 一个坏字段不该让软件打不开。
  factory AppConfig.fromJson(Map<String, Object?> json) {
    final Object? dir = json['data_directory'];
    final Object? shop = json['shop_name'];
    return AppConfig(
      dataDirectory: (dir is String && dir.trim().isNotEmpty) ? dir : null,
      uiScale: UiScale.fromFactor(json['ui_scale']) ?? UiScale.defaultScale,
      backupDirectory: json['backup_directory'] as String?,
      shopName: (shop is String && shop.trim().isNotEmpty) ? shop : null,
    );
  }

  @override
  String toString() =>
      'AppConfig(data=$dataDirectory, scale=${uiScale.factor}, shop=$shopName)';
}

/// 数据目录里的兜底配置文件名（前面加点：不与用户看得见的数据混在一起）。
const String dataDirConfigFileName = '.shensuanzi-config.json';

/// 真睡（生产）。测试里通过构造参数注入假睡。
void _sleep(Duration duration) => sleep(duration);

/// 配置文件的读写。**读永不抛**。
class AppConfigStore {
  AppConfigStore(
    this.file, {
    this.sleep = _realSleep,
    this.fallbackFile,
  });

  /// 重试之间的等待。生产 = 真睡；测试注入假睡以便**确定性地**造瞬时失败。
  final void Function(Duration) sleep;

  /// **备用位置**（2026-10-22 用户实测：`%APPDATA%\神算子\config.json`
  /// 在他的机器上**一直**写不进去 —— errno 5，而 ACL / 只读属性都正常）。
  ///
  /// 主位置写不进去时写这里；读也先读「上次成功写过的那个」。
  /// 没有备用位置 ⇒ 行为与从前完全一样。
  final File? fallbackFile;

  /// 上次**成功写入**的位置（读的时候优先找它）。
  File? _lastGood;

  /// **最后兜底：数据目录里的配置**（2026-10-23，真机踩出来的）。
  ///
  /// 真机上出现过 `%APPDATA%\神算子\` 建不了文件、但数据目录（`D://神算子数据`）
  /// 完全可写的情况 —— 既然库能开，配置就一定能写在那儿。
  /// 由 `app.dart` 在**知道数据目录之后**注入（配置里才存着数据目录，鸡生蛋）。
  File? _dataDirFallback;

  /// 注入数据目录兜底（幂等；`null` = 取消）。
  void useDataDirectoryFallback(String? dataDirectory) {
    _dataDirFallback = dataDirectory == null
        ? null
        : File(p.join(dataDirectory, dataDirConfigFileName));
  }

  static void _realSleep(Duration duration) => _sleep(duration);

  /// `%APPDATA%\神算子\config.json`；
  /// `%APPDATA%` 拿不到时退回 `<home>\.shensuanzi\config.json`。
  factory AppConfigStore.forEnvironment(AppEnvironment environment) {
    final String? appData = environment.appData;
    final String base =
        appData ?? p.join(environment.homeDirectory, '.shensuanzi');
    final File primary = File(p.join(base, '神算子', 'config.json'));
    // 备用位置（2026-10-22 用户实测）：`%APPDATA%\神算子\` 在他的机器上
    // **一直写不进去**（errno 5，ACL 与只读属性都正常，`dart run` 却能写）。
    // 根因未定，但**设置存不上**不能忍 ⇒ 主位置写不进去时退到
    // `%LOCALAPPDATA%\神算子\config.json`。两个都是用户私有目录，
    // 不碰系统位置；`%LOCALAPPDATA%` 拿不到（罕见）就不设备用。
    final String? localAppData = environment.localAppData;
    return AppConfigStore(
      primary,
      fallbackFile: localAppData == null
          ? null
          : File(p.join(localAppData, '神算子', 'config.json')),
    );
  }

  final File file;

  /// 缺失 / 损坏 / 不可读 → 默认配置（**不抛**）
  AppConfig load() {
    for (final File candidate in <File>[
      ?_lastGood,
      file,
      ?fallbackFile,
      ?_dataDirFallback,
    ]) {
      try {
        if (!candidate.existsSync()) continue;
        final Object? decoded = jsonDecode(candidate.readAsStringSync());
        if (decoded is! Map) continue;
        final AppConfig config = AppConfig.fromJson(
          Map<String, Object?>.from(decoded),
        );
        _lastGood = candidate;
        return config;
      } catch (_) {
        // 这个位置读不出来 ⇒ 试下一个
      }
    }
    return const AppConfig();
  }

  /// 写配置。**会重试**（Windows 上杀毒软件实时扫描会**瞬时锁住**正在写的
  /// 文件，直接返回「拒绝访问 errno 5」—— 用户侧现象是「设置了但没生效」）。
  ///
  /// 2026-10-22 用户实测：选「大」后界面不变，SnackBar 报
  /// `Cannot open file ... config.json (OS Error: 拒绝访问。, errno = 5)`。
  /// 重试 4 次（间隔 30/60/90ms，共 180ms）把这类瞬时锁吞掉；仍失败才抛给上层
  /// （设置页会让本次改动照样生效、但明说「重启会变回去」）。
  ///
  /// ⚠️ 总时长 180ms：第一版用 80/160/240（共 480ms）被用户实测为
  /// 「明显的界面延迟」—— `save` 是同步的，睡在主线程上就是卡界面。
  void save(AppConfig config) {
    file.parent.createSync(recursive: true);
    final String text = const JsonEncoder.withIndent(
      '  ',
    ).convert(config.toJson());
    Object? lastError;
    for (final File target in <File>[file, ?fallbackFile, ?_dataDirFallback]) {
      for (int attempt = 0; ; attempt++) {
        try {
          target.parent.createSync(recursive: true);
          target.writeAsStringSync(text);
          _lastGood = target;
          return;
        } catch (error) {
          lastError = error;
          if (attempt >= 3) break; // 换下一个位置
          sleep(Duration(milliseconds: 30 * (attempt + 1)));
        }
      }
    }
    // 两个位置都写不进去才抛（设置页会让本次改动照样生效）。
    //
    // 2026-10-23：**把真错误一起带出来**。真机上出现过「ACL 正常、日志能写、
    // 就是 config.json 写不进」的矛盾，只报「写不进去」等于没报。
    // 附三样东西：最后一次的原始异常、同目录探针写结果、进程自己的身份。
    throw StateError(
      '配置文件写不进去（$file${fallbackFile == null ? '' : ' 与 $fallbackFile'}）。'
      '最后错误：$lastError。${_writeDiagnostic()}',
    );
  }

  /// 写失败时的现场取证（只用来生成错误文案，不改变任何行为）。
  ///
  /// 回答三个问题：目录本身能不能写、进程是谁、系统怎么说的。
  String _writeDiagnostic() {
    final List<String> notes = <String>[];

    for (final Directory dir in <Directory>{
      file.parent,
      if (fallbackFile != null) fallbackFile!.parent,
    }) {
      try {
        dir.createSync(recursive: true);
        final File probe = File(
          p.join(dir.path, '.probe-${DateTime.now().microsecondsSinceEpoch}'),
        );
        probe.writeAsStringSync('x');
        probe.deleteSync();
        notes.add('${dir.path} 可写');
      } catch (error) {
        notes.add('${dir.path} 不可写（$error）');
      }
    }

    try {
      final ProcessResult r = Process.runSync('whoami', <String>[]);
      notes.add('进程身份=${'${r.stdout}'.trim()}');
    } catch (_) {
      notes.add('进程身份=取不到');
    }

    // 令牌里有没有被削掉东西 —— 用户名一样但权限可能被收窄
    //（沙箱 / 受限令牌 / 安全软件的启发式拦截都是这个表现）。
    try {
      final ProcessResult g = Process.runSync('whoami', <String>['/groups']);
      final List<String> lines = '${g.stdout}'
          .split(RegExp(r'\r?\n'))
          .where((String l) => l.trim().isNotEmpty)
          .toList();
      notes.add('令牌组数=${lines.length}');
      final String joined = lines.join(' | ');
      notes.add('含 Administrators=${joined.contains('Administrators')}');
      notes.add('含 BUILTIN\\Users=${joined.contains('BUILTIN\\Users')}');
      final String? mandatory = lines
          .where((String l) => l.contains('Mandatory Label'))
          .firstOrNull;
      notes.add('完整性=${mandatory?.trim() ?? '取不到'}');
    } catch (_) {
      notes.add('令牌组=取不到');
    }

    return notes.join('；');
  }

  void clear() {
    if (file.existsSync()) file.deleteSync();
  }

  /// 配置文件**当前是什么状态**（§审查 OBS-15）。
  ///
  /// ⚠️ 为什么不能只看 `load().dataDirectory == null`：那会把
  /// 「**从没配过**（真·第一次启动）」与「**配过、但文件坏了 / 字段没了**」
  /// 混成一件事 —— 后者对用户说「这是第一次启动」是**撒谎**，
  /// 而且会让他在惊慌里随便选个位置，把原来那个还完好的数据目录丢在一边。
  AppConfigLoadStatus status() {
    if (!file.existsSync()) return AppConfigLoadStatus.absent;
    return load().dataDirectory == null
        ? AppConfigLoadStatus.locationLost
        : AppConfigLoadStatus.ok;
  }

  /// 从**原始文本**里抢救 `data_directory`（§审查 OBS-15）。
  ///
  /// 为什么能救：配置损坏多半是「写到一半断电」⇒ JSON 截断，但
  /// `"data_directory": "D:////fed"` 这一小段往往**还在**。
  /// 救回来就能自动回到用户原来的数据，不必让他自己回忆路径。
  ///
  /// 用 `jsonDecode` 反转义（Windows 路径里的反斜杠是 `\\`）——
  /// 自己写 unescape 容易漏 case。解析不出来就当没救到（返回 `null`）。
  String? salvageDataDirectory() {
    try {
      if (!file.existsSync()) return null;
      final String? raw = _dataDirectoryPattern
          .firstMatch(file.readAsStringSync())
          ?.group(1);
      if (raw == null) return null;
      final Object? decoded = jsonDecode('"$raw"');
      if (decoded is! String) return null;
      final String trimmed = decoded.trim();
      return trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  /// 把**读不懂**的配置文件另存为 `config.json.corrupt`（§审查 OBS-15）。
  ///
  /// - **不删原件**：我们只是读不懂它，不代表它是垃圾
  /// - 已经有 `.corrupt` 就不覆盖（不堆积；**第一份**最有诊断价值）
  /// - 任何失败都吞掉：留档是辅助动作，绝不能因此拦人启动
  void preserveCorruptCopy() {
    try {
      if (!file.existsSync()) return;
      final File copy = File('${file.path}.corrupt');
      if (copy.existsSync()) return;
      copy.writeAsStringSync(file.readAsStringSync());
    } catch (_) {
      // 见上：留档失败不影响启动
    }
  }

  /// `"data_directory"` 后面那个 JSON 字符串（转义感知）。
  static final RegExp _dataDirectoryPattern = RegExp(
    r'"data_directory"\s*:\s*"((?:[^"\\]|\\.)*)"',
  );
}

/// 配置文件的读取状态（§审查 OBS-15）。
enum AppConfigLoadStatus {
  /// 文件**不存在** ⇒ 真·第一次启动（可以放心说「欢迎使用」）
  absent,

  /// 文件在，但**位置读不出来**（JSON 坏了 / 字段缺失或类型不对）
  /// ⇒ 数据没丢，只是软件记不住它在哪了 —— **不能说「第一次启动」**
  locationLost,

  /// 正常读到位置
  ok,
}
