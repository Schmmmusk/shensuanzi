/// 数据目录标记文件 `.shensuanzi-data`（`docs/data_directory.md` §标记与恢复）。
///
/// ## 它解决什么问题
///
/// 配置（`%APPDATA%\神算子\config.json`）可能被清理软件删掉。
/// 那时软件**不知道**上次的数据放在哪 —— 如果只依赖配置，用户会以为数据丢了。
///
/// 标记文件让「**这个目录是神算子的数据目录**」这件事**写在数据自己身边**：
/// 用户重选原目录时，读到标记就知道是老数据，直接复用。
/// **不需要用户记住路径。**
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class DataMarker {
  const DataMarker({
    required this.schemaVersion,
    required this.createdAt,
    this.app = '神算子',
  });

  /// 标记文件名（`docs/data_directory.md`）
  static const String fileName = '.shensuanzi-data';

  static File fileIn(String dataDirectory) =>
      File(p.join(dataDirectory, fileName));

  static bool existsIn(String dataDirectory) => fileIn(dataDirectory).existsSync();

  /// 读取标记。**不存在 / 打不开 / 内容不认 → `null`**（而不是抛）。
  ///
  /// `null` 的语义是「这不是一个已初始化的神算子数据目录」，
  /// 调用方据此走「初始化」分支。
  ///
  /// ⚠️ 注意「目录非空但没有标记」**不等价于**「空目录」——
  /// 那种情况可能是用户选错了文件夹（里面有别人的东西），
  /// 判定见 `AppBootstrap.prepare`。
  static DataMarker? read(String dataDirectory) {
    try {
      final File file = fileIn(dataDirectory);
      if (!file.existsSync()) return null;
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      final Map<String, Object?> json = Map<String, Object?>.from(decoded);
      final Object? version = json['schema_version'];
      final Object? createdAt = json['created_at'];
      if (version is! int || createdAt is! int) return null;
      return DataMarker(
        schemaVersion: version,
        createdAt: createdAt,
        app: (json['app'] as String?) ?? '神算子',
      );
    } catch (_) {
      return null;
    }
  }

  static DataMarker write(
    String dataDirectory, {
    required int schemaVersion,
    required int now,
  }) {
    final DataMarker marker = DataMarker(
      schemaVersion: schemaVersion,
      createdAt: now,
    );
    Directory(dataDirectory).createSync(recursive: true);
    fileIn(dataDirectory).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(marker.toJson()),
    );
    return marker;
  }

  /// 标记里记的 schema 版本 —— 低于当前程序时提示升级，
  /// 高于当前程序时**拒绝打开**（`Db` 也会拦一次）。
  final int schemaVersion;

  final int createdAt;
  final String app;

  Map<String, Object?> toJson() => <String, Object?>{
    'app': app,
    'schema_version': schemaVersion,
    'created_at': createdAt,
    'marker_file': fileName,
  };

  @override
  String toString() => 'DataMarker(schema=$schemaVersion, created=$createdAt)';
}

/// 目录内容的三种状态
enum DirectoryContents {
  /// 不存在
  missing,

  /// 存在且为空
  empty,

  /// 存在，且是我们的数据目录（有标记文件）
  ours,

  /// 存在，非空，**且没有标记** —— 可能是用户选错了文件夹
  foreign,
}

/// 判定目录内容（不看磁盘类型，只看里面有什么）
DirectoryContents contentsOf(String directory) {
  final Directory dir = Directory(directory);
  if (!dir.existsSync()) return DirectoryContents.missing;
  if (DataMarker.existsIn(directory)) return DirectoryContents.ours;
  // 忽略我们的数据库残留（理论上有 db 就一定有标记，这里只做兜底）
  final bool hasAnything = dir.listSync().isNotEmpty;
  return hasAnything ? DirectoryContents.foreign : DirectoryContents.empty;
}
