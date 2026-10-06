/// 应用配置（`docs/data_directory.md` §配置）。
///
/// ⚠️ **配置不是数据**：它只记「上次选的路径」「界面缩放」这类**设备偏好**。
/// 放在 `%APPDATA%\神算子\config.json` —— 被清理软件删掉只丢偏好，
/// **经营数据一行都不会少**（这也是为什么路径恢复不依赖配置，见 `bootstrap.dart`）。
library;

import 'dart:convert';
import 'dart:io';

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
    this.shopName,
  });

  /// `null` = 还没选过（→ 走向导）
  final String? dataDirectory;

  final UiScale uiScale;

  /// 店名（向导第 3 步，可跳过）
  final String? shopName;

  AppConfig copyWith({
    String? dataDirectory,
    UiScale? uiScale,
    String? shopName,
    bool clearShopName = false,
  }) => AppConfig(
    dataDirectory: dataDirectory ?? this.dataDirectory,
    uiScale: uiScale ?? this.uiScale,
    shopName: clearShopName ? null : (shopName ?? this.shopName),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'data_directory': dataDirectory,
    'ui_scale': uiScale.factor,
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
      shopName: (shop is String && shop.trim().isNotEmpty) ? shop : null,
    );
  }

  @override
  String toString() =>
      'AppConfig(data=$dataDirectory, scale=${uiScale.factor}, shop=$shopName)';
}

/// 配置文件的读写。**读永不抛**。
class AppConfigStore {
  const AppConfigStore(this.file);

  /// `%APPDATA%\神算子\config.json`；
  /// `%APPDATA%` 拿不到时退回 `<home>\.shensuanzi\config.json`。
  factory AppConfigStore.forEnvironment(AppEnvironment environment) {
    final String? appData = environment.appData;
    final String base = appData ?? p.join(environment.homeDirectory, '.shensuanzi');
    return AppConfigStore(File(p.join(base, '神算子', 'config.json')));
  }

  final File file;

  /// 缺失 / 损坏 / 不可读 → 默认配置（**不抛**）
  AppConfig load() {
    try {
      if (!file.existsSync()) return const AppConfig();
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return const AppConfig();
      return AppConfig.fromJson(Map<String, Object?>.from(decoded));
    } catch (_) {
      return const AppConfig();
    }
  }

  void save(AppConfig config) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
    );
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
