/// 数据目录策略（`docs/data_directory.md`）。
///
/// ## 为什么要「校验」而不是「随便选」
///
/// 经营数据与缓存**在文件系统里长得一模一样**。把一个装着账本的 SQLite
/// 放进 `%LOCALAPPDATA%`，等于把它交给清理软件；放进 OneDrive 同步目录，
/// 等于交给一个会在背后重写文件的进程；放进 U 盘，等于交给「拔掉」这个动作。
///
/// 所以：**默认值替用户想好 + 用户可改 + 改的时候立刻校验**。
/// 校验结论只有三档（见 [DirectoryVerdict]）：
///
/// - [DirectoryVerdict.reject] —— 真的不行（无权限 / 系统目录 / 系统盘根目录）
/// - [DirectoryVerdict.warn]   —— 能用但有代价（会被清理 / 同步冲突 / 拔盘失效）
/// - [DirectoryVerdict.ok]     —— 没问题
///
/// ⚠️ **警告不拦人**。中老年用户被拦住会认为「软件坏了」；
/// 这里给的是**代价说明 + 怎么办**，让他自己决定。
library;

import 'package:path/path.dart' as p;

import 'environment.dart';

/// 校验结论
enum DirectoryVerdict { ok, warn, reject }

/// 一次校验的结论。[reason] 是「为什么」，[advice] 是「怎么办」。
///
/// 按 `docs/ui_principles.md`：**错误信息说「怎么办」，不说「哪里错了」**。
class DirectoryAdvice {
  const DirectoryAdvice(this.verdict, this.reason, {this.advice});

  const DirectoryAdvice.ok()
    : verdict = DirectoryVerdict.ok,
      reason = '',
      advice = null;

  final DirectoryVerdict verdict;
  final String reason;
  final String? advice;

  /// 能不能用（`reject` 才拦）
  bool get isUsable => verdict != DirectoryVerdict.reject;

  bool get isWarning => verdict == DirectoryVerdict.warn;

  @override
  String toString() => 'DirectoryAdvice(${verdict.name}'
      '${reason.isEmpty ? '' : ', $reason'})';
}

/// 数据目录策略
class DataDirectoryPolicy {
  const DataDirectoryPolicy(this.environment);

  final AppEnvironment environment;

  /// 数据目录的默认名（也是识别「这是我们的目录」的线索之一）
  static const String dataFolderName = '神算子数据';

  /// 备份目录的默认名（数据目录的**兄弟目录**）
  static const String backupFolderName = '神算子备份';

  static const String markerFileName = '.shensuanzi-data';

  /// 已知的网盘同步目录名片段（小写比较）。
  ///
  /// 命中即警告：SQLite 在同步盘上运行有真实的损坏风险
  /// （同步进程会在背后重写文件，而 SQLite 假设文件只有自己在动）。
  static const List<String> syncFolderHints = <String>[
    'onedrive',
    'dropbox',
    'google drive',
    'googledrive',
    'icloud',
    'nutstore',
    '坚果云',
    'baidunetdisk',
    '百度网盘',
    'onedrive - ',
  ];

  /// 默认数据目录：**优先非系统盘**。
  ///
  /// ```
  /// D:\神算子数据\                 ← 存在可用的非系统盘时
  /// C:\Users\<你>\神算子数据\      ← 否则
  /// ```
  ///
  /// **为什么优先非系统盘**：重装系统不丢数据（个体工商户的最大杀手）、
  /// 绕开 `%LOCALAPPDATA%` 的清理风险、备份到 U 盘更顺手。
  ///
  /// **为什么不默认「文档」**：OneDrive 会同步它。
  String defaultDataDirectory() {
    final List<DriveInfo> candidates = environment.candidateDataDrives;
    if (candidates.isNotEmpty) {
      return p.join(candidates.first.root, dataFolderName);
    }
    final String home = environment.homeDirectory;
    if (home.isEmpty) return p.join('C:\\', dataFolderName);
    return p.join(home, dataFolderName);
  }

  /// 备份目录 = 数据目录的**兄弟目录**。
  ///
  /// **为什么不放子目录**：用户「把数据拷到 U 盘」时会形成「备份里包含备份」的递归。
  /// 分开之后两个目录都很直观，而且备份逻辑只依赖**数据目录的父目录**，
  /// 与 `%LOCALAPPDATA%` 完全解耦。
  String backupDirectoryFor(String dataDirectory) {
    final String parent = p.dirname(p.normalize(dataDirectory));
    // 万一用户把数据目录就叫「神算子备份」，别让备份路径等于数据路径
    final String name = _samePath(dataDirectory, p.join(parent, backupFolderName))
        ? '$backupFolderName-1'
        : backupFolderName;
    return p.join(parent, name);
  }

  /// [candidate] 是否在 [container] 之内（含相等）。
  ///
  /// ⚠️ **`container` 是盘根时必须特殊处理**：[_key] 只剥掉**长度 > 3** 的末尾
  /// 分隔符，所以 `C:\` 会原样保留末尾那个反斜杠。此时若直接拼 `'$parent\\'`
  /// 会得到 `C:\\`（两个反斜杠），任何子路径都匹配不上 ——
  /// 判定会**静默失效**（不报错，只是永远返回 false）。
  ///
  /// 这个缺陷实际发生过：`isNested(r'C:\Users\x', r'C:\')` 返回 `false`。
  /// 它会让「新位置在旧位置里面」这类迁移校验在盘根场景下放行。
  bool isNested(String candidate, String container) {
    final String child = _key(candidate);
    final String parent = _key(container);
    if (child == parent) return true;
    final String prefix = parent.endsWith('\\') ? parent : '$parent\\';
    return child.startsWith(prefix);
  }

  /// 校验一个数据目录。
  DirectoryAdvice inspect(String path) {
    if (path.trim().isEmpty) {
      return const DirectoryAdvice(
        DirectoryVerdict.reject,
        '还没有选择位置',
        advice: '请点「更改位置」选一个文件夹',
      );
    }
    if (!p.isAbsolute(path)) {
      return const DirectoryAdvice(
        DirectoryVerdict.reject,
        '这不是一个完整的路径',
        advice: '请点「更改位置」，从「此电脑」里选一个文件夹',
      );
    }
    final String target = p.normalize(path);
    final String key = _key(target);
    final String systemLetter = environment.systemDriveLetter;

    // ---- 硬拒绝：系统目录 ----
    final List<String> protectedRoots = <String>[
      '$systemLetter:\\Windows',
      '$systemLetter:\\Program Files',
      '$systemLetter:\\Program Files (x86)',
    ];
    for (final String root in protectedRoots) {
      if (isNested(target, root)) {
        return DirectoryAdvice(
          DirectoryVerdict.reject,
          '这是系统目录（$root），不能放经营数据',
          advice: '建议用默认位置，或选一个自己建的文件夹',
        );
      }
    }

    // ---- 硬拒绝：系统盘根目录 ----
    //
    // ⚠️ **必须用 [_key] 归一化后再比**：[_key] 会把路径转小写，而
    // [AppEnvironment.systemDriveLetter] 是**大写**字母。直接写
    // `key == '$systemLetter:\\'` 会得到 `'c:\' == 'C:\'` → **永远 false**，
    // 于是 `C:\` 会被当成普通盘根**静默放行**（返回 warn）。
    // 实测踩到过一次：`C:\` 被判成「放在盘根目录不好认」，而规范要求 reject。
    final String systemRoot = _key('$systemLetter:\\');
    final String systemDriveBare = _key('$systemLetter:');
    if (key == systemRoot || key == systemDriveBare) {
      return DirectoryAdvice(
        DirectoryVerdict.reject,
        '不能直接放在 $systemLetter 盘根目录',
        advice: '请选一个子文件夹，例如 '
            '${p.join('$systemLetter:\\', dataFolderName)}',
      );
    }

    // ---- 警告：会被清理软件删 ----
    for (final MapEntry<String, String> entry in <String, String>{
      '%LOCALAPPDATA%': environment.localAppData ?? '',
      '%APPDATA%': environment.appData ?? '',
      '%TEMP%': environment.temp ?? '',
    }.entries) {
      if (entry.value.isNotEmpty && isNested(target, entry.value)) {
        return DirectoryAdvice(
          DirectoryVerdict.warn,
          '这个位置在 ${entry.key} 下，清理软件（如 Nova）可能把它当缓存删掉',
          advice: '建议换一个位置，经营数据不该和缓存混在一起',
        );
      }
    }

    // ---- 警告：网盘同步目录 ----
    if (_looksSynced(target)) {
      return const DirectoryAdvice(
        DirectoryVerdict.warn,
        '这个位置看起来在网盘同步文件夹里，同步过程中数据库有可能损坏',
        advice: '建议换一个不同步的文件夹',
      );
    }

    // ---- 警告：可移动盘 / 网络盘 / 剩余空间不足 ----
    final DriveInfo? drive = environment.driveOf(target);
    if (drive != null) {
      if (drive.kind == DriveKind.removable) {
        return const DirectoryAdvice(
          DirectoryVerdict.warn,
          '这是可移动盘（U 盘 / 移动硬盘），拔掉之后就打不开了',
          advice: '想随身带走数据的话，建议用同一磁盘上的固定分区，或只把备份拷到 U 盘',
        );
      }
      if (drive.kind == DriveKind.network) {
        return const DirectoryAdvice(
          DirectoryVerdict.warn,
          '这是网络盘，断网或对方关机时数据打不开',
          advice: '建议用本机磁盘',
        );
      }
      if (!drive.hasRoom) {
        return DirectoryAdvice(
          DirectoryVerdict.warn,
          '${drive.letter} 盘剩余空间不足'
              '（${formatBytes(drive.freeBytes)}，建议留 ${formatBytes(DriveInfo.minimumFreeBytes)} 以上）',
          advice: '清理一些空间，或换一个盘',
        );
      }
      // ---- 警告：非系统盘根目录（能用，但不建议） ----
      if (isNested(target, drive.root) && _samePathKey(target, drive.root)) {
        return DirectoryAdvice(
          DirectoryVerdict.warn,
          '放在盘根目录不好认，也不好迁移',
          advice: '建议再建一层文件夹，例如 '
              '${p.join(drive.root, dataFolderName)}',
        );
      }
    }

    return const DirectoryAdvice.ok();
  }

  /// 供向导展示的容量提示，如 `D 盘剩余 128 GB`；拿不到返回 `null`。
  String? spaceHint(String path) {
    final DriveInfo? drive = environment.driveOf(_absoluteOr(path));
    final int? free = drive?.freeBytes;
    if (drive == null || free == null) return null;
    return '${drive.letter} 盘剩余 ${formatBytes(free)}';
  }

  /// 迁移校验：`from` → `to` 能不能搬。
  ///
  /// 两条硬约束（都会造成**数据套娃**）：
  ///
  /// 1. **目标本身必须合法**（走 [inspect]）
  /// 2. **新旧位置不能互相嵌套** —— 否则搬完会形成 `新\旧\数据` 或
  ///    `旧\新\数据`，用户之后每改一次路径就多套一层
  ///
  /// 真正的搬迁（数据 + 备份一起搬）由 UI 执行，本方法**只给结论**。
  DirectoryAdvice inspectMigration(String from, String to) {
    final DirectoryAdvice target = inspect(to);
    if (!target.isUsable) return target;
    if (isNested(to, from)) {
      return const DirectoryAdvice(
        DirectoryVerdict.reject,
        '新位置在旧位置里面，搬过去会套在一起',
        advice: '请选一个和现在这个文件夹并列的位置',
      );
    }
    if (isNested(from, to)) {
      return const DirectoryAdvice(
        DirectoryVerdict.reject,
        '旧位置在新位置里面，搬过去会套在一起',
        advice: '请选一个和现在这个文件夹并列的位置',
      );
    }
    return const DirectoryAdvice.ok();
  }

  bool _looksSynced(String target) {
    final String? oneDrive = environment.oneDrive;
    if (oneDrive != null && isNested(target, oneDrive)) return true;
    final String lower = target.toLowerCase();
    for (final String hint in syncFolderHints) {
      if (lower.contains(hint)) return true;
    }
    return false;
  }

  String _absoluteOr(String path) => p.isAbsolute(path) ? p.normalize(path) : path;

  /// 比较用的键：统一小写、**去掉末尾分隔符**。
  ///
  /// Windows 路径大小写不敏感，`d:\数据` 与 `D:\数据` 是同一个地方 ——
  /// 不归一化就会出现「看起来不同、实际同一个」的绕过。
  static String _key(String path) {
    String key = p.normalize(path).toLowerCase();
    while (key.length > 3 && (key.endsWith('\\') || key.endsWith('/'))) {
      key = key.substring(0, key.length - 1);
    }
    return key;
  }

  bool _samePath(String a, String b) => _key(a) == _key(b);

  bool _samePathKey(String normalizedA, String normalizedB) =>
      _key(normalizedA) == _key(normalizedB);
}

/// 人类可读的字节数（KB / MB / GB，保留一位小数）
String formatBytes(int? bytes) {
  if (bytes == null) return '未知';
  const int kb = 1024;
  const int mb = kb * 1024;
  const int gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  return '$bytes 字节';
}
