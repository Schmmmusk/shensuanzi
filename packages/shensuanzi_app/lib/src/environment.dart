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
///
/// ## ⚠️ 第二条铁律：[AppEnvironment.detect] **永不抛异常**
///
/// `detect()` 是**环境探测**，不是「读机器事实」而是「**尽力**从机器读取事实」：
/// 每个字段都可能取不到，取不到就**降级**为 `null` / `unknown` / 空列表，
/// **绝不冒泡**。消费端因此必须容忍「全部未知」（`docs/data_directory.md` §二）。
///
/// 为什么这是铁律：`detect()` 在**启动路径**上（`_ShensuanziAppState` 的字段
/// 初始化、`main()` 的第一行）—— 抛一次就是「软件打不开」，用户只会说这四个字。
/// 而真机上的机器**不可预测**：离线映射盘、权限受限目录、网络共享超时、杀毒拦截……
///
/// **实证**（2026-10-01）：Windows 上 `Directory('Y:\\').existsSync()` 对
/// 「**映射了但离线的网络盘**」会**抛** `FileSystemException`
/// （`errno 53 找不到网络路径`），**而不是返回 `false`** ——
/// 旧实现没有容错，于是开发机上只要有一块离线映射盘，启动即崩
/// （`flutter test` 的 9 个启动场景全红）。见 `docs/reply_review.md` §AT。
///
/// ## ⚠️ 第三条：[AppEnvironment.detect] **不碰网络**
///
/// 容错只解决了「崩」，没解决「慢」：`existsSync()` 在离线的映射网络盘上要等
/// SMB 超时 —— 实测**首次 63,127 ms**（`docs/reply_review.md` §AT·六-3），
/// 而 `detect()` 在 `runApp` **之前**被调用 ⇒ 用户看到约一分钟白屏。
///
/// 根因是**用错了 API**：`existsSync()` 是「检查某个具体路径存不存在」，
/// **不是「列出有哪些盘」**。枚举盘符现在走 `windows_drives.dart` 的 FFI
/// （`GetLogicalDrives` + `GetDriveTypeW`，只读本地挂载表）——**整轮 3 ms**。
library;

import 'dart:io';

import 'windows_drives.dart';

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

/// 一次盘符枚举的**结果**。
///
/// 两样东西都要，缺一不可：
/// - [drives]：**事实** —— 本机有哪些盘、什么类型、剩多少（`null` = 未知）
/// - [failures]：**诊断** —— 盘符占着位、但类型问不出来的（见 [probeFailures]）
///
/// 为什么不让枚举器直接返回 `List<DriveInfo>`：那样就表达不了「**整体失败**」
/// （返回空列表到底是「没有盘」还是「问不出来」？）与「问不出来的那些盘符」。
/// 而「降级要留现场」是 §AT 已裁定的要求。
class DriveEnumeration {
  const DriveEnumeration({
    this.drives = const <DriveInfo>[],
    this.failures = const <String>[],
  });

  final List<DriveInfo> drives;
  final List<String> failures;

  @override
  String toString() => 'DriveEnumeration(${drives.length} 盘, 失败 $failures)';
}

/// 「枚举本机全部盘」的**系统调用抽象**（注入点）。
///
/// 生产实现 = `windows_drives.dart` 的 FFI；测试注入假实现来构造
/// 「有离线的映射盘」「枚举整个失败」这些真实机器上造不出来的场景。
///
/// 与 `folder_picker.dart` 是同一个模式：**系统调用收敛到注入点，
/// 判断逻辑留在纯 Dart**。
typedef DriveEnumerator = DriveEnumeration Function();

/// 本机事实的注入点
class AppEnvironment {
  const AppEnvironment({
    required this.isWindows,
    required this.homeDirectory,
    this.environment = const <String, String>{},
    this.drives = const <DriveInfo>[],
    this.probeFailures = const <String>[],
  });

  /// 读真机：环境变量 + 本机盘列表。
  ///
  /// ⚠️ **本方法【永不抛异常】**（见文件头第二条铁律）。三层保护：
  ///
  /// 1. 读环境变量失败 → 降级成「最低限度环境」（盘列表为空）；
  /// 2. **盘符枚举整体失败** → 同样是「最低限度环境」（盘列表为空）；
  /// 3. 单块盘的类型问不出来 → 记进 [probeFailures]，**不猜一个 `kind` 出来**。
  ///
  /// ## 盘从哪来：**不再用 `existsSync()`**
  ///
  /// 默认实现是 `windows_drives.dart` 的 FFI 枚举
  /// （`GetLogicalDrives` + `GetDriveTypeW` + `GetDiskFreeSpaceExW`）——
  /// 只读本地挂载表，**永不触网**（整轮实测 **3 ms**）。
  /// 旧的「逐盘 `existsSync()`」在离线的映射网络盘上要等 SMB 超时
  /// （实测 **63,127 ms**），是启动白屏的根因（§AT·六-3）。详见该文件头。
  ///
  /// ## 领域映射在这里（纯 Dart、可测）
  ///
  /// FFI 只返回**原始 Win32 事实**（`RawDrive`：盘符 + `DRIVE_*` 数值 + 剩余字节），
  /// 「`DRIVE_*` → [DriveKind]」的映射是本文件的事：
  ///
  /// | Win32 | [DriveKind] | 进 [drives] 吗 |
  /// |---|---|---|
  /// | `DRIVE_FIXED` | `fixed` | ✅ |
  /// | `DRIVE_REMOVABLE` | `removable` | ✅ |
  /// | `DRIVE_REMOTE` | `network` | ✅ **事实可见** —— 但 [candidateDataDrives] 排除它（**策略**） |
  /// | `DRIVE_CDROM` / `DRIVE_RAMDISK` | — | ❌ 不进列表 |
  /// | `DRIVE_UNKNOWN` / `DRIVE_NO_ROOT_DIR` | — | ❌ 不进列表，且记进 [probeFailures] |
  ///
  /// **为什么远程盘「可见但不进候选」**（两条独立规则）：
  /// 枚举回答「**本机有什么**」（事实），候选回答「**哪块盘适合放数据**」（策略）。
  /// [DriveInfo.isGoodForData] 已排除 `network` —— 所以**不需要在下游再加一遍判断**。
  ///
  /// **为什么光驱 / 内存盘不进列表**：[DriveKind] 只有四档，装不下它们；
  /// 硬塞成 `unknown` 会被 [candidateDataDrives] 放行（`unknown` 是放行的）——
  /// 而**内存盘重启即丢数据**，正是要避免的。枚举的目的就是「找出能放经营数据的盘」。
  ///
  /// ## [driveEnumerator]：可注入的缝
  ///
  /// 「枚举失败」「离线盘」「远程盘」这些路径**没法用真实机器在测试里构造**
  /// （总不能在跑测试时拔一根网线），只能注入。默认 `null` = 生产实现。
  factory AppEnvironment.detect({DriveEnumerator? driveEnumerator}) {
    final Map<String, String> env;
    try {
      env = Platform.environment;
    } catch (_) {
      // 连环境变量都读不到时也要能启动 —— 给「最低限度环境」。
      return const AppEnvironment(isWindows: false, homeDirectory: '');
    }

    List<DriveInfo> drives = const <DriveInfo>[];
    List<String> probeFailures = const <String>[];
    if (Platform.isWindows) {
      try {
        final DriveEnumerator enumerate =
            driveEnumerator ?? _enumerateFromWin32;
        final DriveEnumeration result = enumerate();
        drives = result.drives;
        probeFailures = result.failures;
      } catch (_) {
        // 枚举整体失败 ⇒ 降级为「盘列表为空」，消费端按「没有非系统盘」处理
        // ⇒ 默认数据目录回退到用户目录。**能启动比「选对盘」重要。**
        drives = const <DriveInfo>[];
        probeFailures = const <String>[];
      }
    }
    return AppEnvironment(
      isWindows: Platform.isWindows,
      homeDirectory: env['USERPROFILE'] ?? env['HOME'] ?? '',
      environment: env,
      drives: drives,
      probeFailures: probeFailures,
    );
  }

  final bool isWindows;

  /// `%USERPROFILE%`（Windows）或 `$HOME`
  final String homeDirectory;

  final Map<String, String> environment;

  /// 本机盘符清单。**空列表 = 未知**（此时不基于盘做任何判断）
  final List<DriveInfo> drives;

  /// 盘符**占着位、但类型问不出来**的那些（大写字母）。
  ///
  /// ⚠️ 含义是「**没问到**」，**不是「不存在」** —— 对应 Win32 的
  /// `DRIVE_UNKNOWN` / `DRIVE_NO_ROOT_DIR`。FFI 枚举下**通常是空的**，
  /// 所以它是**降级诊断**，不是「正常机器会有的东西」。
  ///
  /// 这些盘**不会进入 [drives]**（理由见 [AppEnvironment.detect]），
  /// 所以消费端会把它们当成「未知」：不据其做任何判断、也不拦人。
  ///
  /// 它存在的唯一目的是**留现场** —— 启动时记一条日志（`lib/main.dart`）。
  /// 否则「软件能开了、但少了一块盘」这种事永远查不出原因。
  ///
  /// ## ⚠️ **仅诊断用：不参与值等价**
  ///
  /// 它描述的是「**我们没能问到什么**」（一次探测的遭遇），
  /// 而不是「**机器是什么**」（环境事实）。所以将来若给 [AppEnvironment]
  /// 加 `==` / `hashCode`（例如拿它当缓存 key），**必须排除本字段** ——
  /// 否则「两台事实完全相同的机器、只因某一块盘探测失败过一次」就会被判为不同。
  ///
  /// 当前 [AppEnvironment] **没有** `==` / `hashCode`（走默认同一性），
  /// 所以这不是在修 bug，而是**先把意图钉在这里**（`docs/reply.md` §四 的建议）。
  final List<String> probeFailures;

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

/// 生产默认实现：调 FFI 拿原始事实，再交给 [mapRawDrives] 映射。
///
/// ⚠️ 只在 Windows 上被调用 —— [AppEnvironment.detect] 里有 `Platform.isWindows` 判断。
DriveEnumeration _enumerateFromWin32() =>
    mapRawDrives(enumerateWindowsRawDrives());

/// 把 Win32 的**原始事实**映射成领域类型（**纯函数，可测**）。
///
/// 系统调用在 `windows_drives.dart`（本包唯一调 Win32 的文件）；
/// **归属判断留在这里** —— 于是「哪个 `DRIVE_*` 算哪种 [DriveKind]、
/// 哪些根本不进列表」能被单元测试钉住，**不需要真的插一块内存盘或光驱**。
///
/// 这正是「逻辑在纯 Dart，系统调用在注入点」那条边界
/// （与 `folder_picker.dart` 同一个模式）。
DriveEnumeration mapRawDrives(List<RawDrive> raw) {
  final List<DriveInfo> drives = <DriveInfo>[];
  final List<String> failures = <String>[];
  for (final RawDrive drive in raw) {
    final DriveKind? kind = switch (drive.type) {
      winDriveFixed => DriveKind.fixed,
      winDriveRemovable => DriveKind.removable,
      winDriveRemote => DriveKind.network,
      _ => null,
    };
    if (kind == null) {
      // 光驱 / 内存盘是**正常结果**（只是我们不列，见 detect() 的说明）；
      // `DRIVE_UNKNOWN` / `DRIVE_NO_ROOT_DIR` 才是「问不出来」⇒ 记进诊断。
      if (drive.type == winDriveUnknown || drive.type == winDriveNoRootDir) {
        failures.add(drive.letter);
      }
      continue;
    }
    drives.add(
      DriveInfo(
        root: '${drive.letter}:\\',
        kind: kind,
        freeBytes: drive.freeBytes,
      ),
    );
  }
  return DriveEnumeration(drives: drives, failures: failures);
}
