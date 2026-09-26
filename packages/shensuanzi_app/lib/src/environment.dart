/// 运行环境：把「本机事实」收进一个可注入的对象里。
///
/// ## 为什么全部靠注入
///
/// 路径策略要能判断「这个目录会不会被清理软件删」「这块盘拔了怎么办」——
/// 这些判断依赖盘符类型（固定盘 / U 盘 / 网盘）与环境变量。
/// 如果直接读 `Platform.environment` 和真实磁盘，**这套逻辑就无法被测试**：
/// 总不能让测试去插一个 U 盘。
///
/// 所以：**判断逻辑是纯函数**（输入 [AppEnvironment]，输出结论），
/// 真机取值只在 [AppEnvironment.detect] 里做一次。
/// 测试用 [AppEnvironment] 的普通构造函数构造各种「虚拟机器」。
///
/// 同理，**剩余空间与盘类型拿不到时留 `null`**，而不是猜一个值 ——
/// `null` 表示「未知」，[DriveInfo.hasRoom] 对未知一律放行（不因为拿不到信息就拦人）。
library;

import 'dart:io';

/// 盘的类型。
///
/// 纯 Dart **无法**可靠区分固定盘与 U 盘（需要 Win32 `GetDriveType`），
/// 所以 [detect] 一律给 [DriveKind.unknown]；
/// **真实类型由 Flutter 侧用 `win32` / 插件注入**（见 [AppEnvironment.drives]）。
enum DriveKind {
  fixed,
  removable,
  network,
  unknown;

  String get label => switch (this) {
    DriveKind.fixed => '本机固定盘',
    DriveKind.removable => '可移动盘',
    DriveKind.network => '网络盘',
    DriveKind.unknown => '未知类型',
  };
}

/// 一块盘的信息
class DriveInfo {
  const DriveInfo({
    required this.root,
    this.kind = DriveKind.unknown,
    this.freeBytes,
  });

  /// 形如 `D:\`
  final String root;

  final DriveKind kind;

  /// 剩余字节；`null` = 未知
  final int? freeBytes;

  /// 低于这个值就不建议用来存经营数据（数据库 + WAL + 备份要留余地）
  static const int minimumFreeBytes = 200 * 1024 * 1024;

  /// 盘符（大写，无冒号无斜杠），如 `D`
  String get letter => root
      .replaceAll('\\', '')
      .replaceAll('/', '')
      .replaceAll(':', '')
      .trim()
      .toUpperCase();

  bool get isSystemDrive => letter == 'C';

  /// 剩余空间是否够。**未知（`null`）视为够** —— 不因为拿不到信息就拦人。
  bool get hasRoom =>
      freeBytes == null || freeBytes! >= minimumFreeBytes;

  /// 适合作默认数据盘：非系统盘 + 有空间 + **不是可移动盘 / 网络盘**
  bool get isGoodForData =>
      !isSystemDrive && hasRoom && kind != DriveKind.removable && kind != DriveKind.network;

  @override
  String toString() => 'DriveInfo($root, ${kind.name}, free=$freeBytes)';
}

/// 本机事实的注入点
class AppEnvironment {
  const AppEnvironment({
    required this.isWindows,
    required this.homeDirectory,
    this.environment = const <String, String>{},
    this.drives = const <DriveInfo>[],
  });

  /// 读真机：环境变量 + 各盘符是否存在。
  ///
  /// ⚠️ 这里**只探测盘符是否存在**，类型与剩余空间都留 `null`/`unknown`
  /// （纯 Dart 拿不到）。要精确盘类型，由 Flutter 侧构造 [AppEnvironment] 注入。
  factory AppEnvironment.detect() {
    final Map<String, String> env = Platform.environment;
    final String home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    final List<DriveInfo> drives = <DriveInfo>[];
    if (Platform.isWindows) {
      for (int code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++) {
        final String letter = String.fromCharCode(code);
        if (Directory('$letter:\\').existsSync()) {
          drives.add(DriveInfo(root: '$letter:\\'));
        }
      }
    }
    return AppEnvironment(
      isWindows: Platform.isWindows,
      homeDirectory: home,
      environment: env,
      drives: drives,
    );
  }

  final bool isWindows;

  /// `%USERPROFILE%`（Windows）或 `$HOME`
  final String homeDirectory;

  final Map<String, String> environment;

  /// 本机盘符清单。**空列表 = 未知**（此时不基于盘做任何判断）
  final List<DriveInfo> drives;

  String? variable(String key) {
    final String? value = environment[key];
    return (value == null || value.isEmpty) ? null : value;
  }

  /// `%LOCALAPPDATA%`（Windows 上会被清理软件扫的地方）
  String? get localAppData => variable('LOCALAPPDATA');

  /// `%APPDATA%`（漫游；配置放这里）
  String? get appData => variable('APPDATA');

  String? get temp => variable('TEMP') ?? variable('TMP');

  /// `%OneDrive%`（用户显式设置时会存在）
  String? get oneDrive => variable('OneDrive');

  /// 系统盘盘符（大写字母）。取 `%LOCALAPPDATA%` 的盘符，取不到则 `C`。
  String get systemDriveLetter {
    final String? local = localAppData;
    if (local != null && local.length >= 2 && local[1] == ':') {
      return local[0].toUpperCase();
    }
    return 'C';
  }

  /// 路径落在哪块盘上。盘符不在 [drives] 里时返回 `null`（= 未知，不判断）。
  DriveInfo? driveOf(String absolutePath) {
    if (absolutePath.length < 2 || absolutePath[1] != ':') return null;
    final String letter = absolutePath[0].toUpperCase();
    for (final DriveInfo drive in drives) {
      if (drive.letter == letter) return drive;
    }
    return null;
  }

  /// 可作默认数据盘的盘（非系统盘、有空间、非可移动/网络）。
  ///
  /// **优先 `fixed`**：机器上既有固定 D 盘又有 U 盘时，不该默认到 U 盘上。
  /// 若都是 `unknown`（纯 Dart 探测的结果），按盘符顺序取第一个。
  List<DriveInfo> get candidateDataDrives {
    final List<DriveInfo> candidates = <DriveInfo>[
      for (final DriveInfo drive in drives)
        if (drive.isGoodForData) drive,
    ];
    candidates.sort((DriveInfo a, DriveInfo b) {
      final bool aFixed = a.kind == DriveKind.fixed;
      final bool bFixed = b.kind == DriveKind.fixed;
      if (aFixed != bFixed) return aFixed ? -1 : 1;
      return a.letter.compareTo(b.letter);
    });
    return candidates;
  }
}
