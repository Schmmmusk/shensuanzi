/// **本地文件写入失败**的**用户可读**文案（`#35` / `#36`，2026-10-14 裁定）。
///
/// ## 为什么和 `storage_error.dart` 分开
///
/// | 文件 | 认什么码 | 谁产生 |
/// |---|---|---|
/// | `storage_error.dart` | **SQLite 结果码**（`SqliteException.extendedResultCode`） | 数据库写失败 |
/// | **本文件** | **文件系统错误码**（`OSError.errorCode`） | 导出 / 备份写盘失败 |
///
/// 两者**来源不同、判据不同**，但同属「本地写入失败」这一族，口径完全一致：
/// **先说「你填的东西还在」→ 给可执行动作 → 不承诺做不到的事**。
///
/// ## 为什么必须分 errno（真机实证）
///
/// 2026-10-12 桌面版导出失败时，用户看到的建议是「**检查磁盘空间**」，
/// 而真实错误码是 `32`（Windows `ERROR_SHARING_VIOLATION` = 文件被别的程序占用，
/// 多半是 Excel 还开着那份 CSV）。**按提示做永远修不好** —— 这正是 M15
/// 「不承诺做不到的事」的反面。同时，原始异常（`PathAccessException` + 绝对路径
/// + `errno`）还**原文直抛**给了用户 ⇒ 一句话里既有禁用词、又看不懂。
///
/// ## 落点纪律
///
/// **分流表只在这里（领域层）**；调用方（导出 / 备份 / 建档）**只取值、不造句** ——
/// 前缀（`导出失败：` / `备份失败：`）由各自拼，因为同一张表服务多个动作，
/// 措辞必须能变（同 `fs.dart` 的 `label` 设计）。见 `docs/ui_principles.md` §五。
library;

import 'dart:io';

/// 本地文件失败的类别 —— 决定「告诉用户什么」和「让他做什么」。
enum LocalFileFailureKind {
  /// **文件被另一个程序占用**（Windows `ERROR_SHARING_VIOLATION` / POSIX `EBUSY`）。
  /// ⚠️ 清磁盘、换路径**都救不了** —— 必须让用户去关掉那个程序。
  busy,

  /// 磁盘 / 配额不够（Windows `ERROR_DISK_FULL` / POSIX `ENOSPC`）。
  noSpace,

  /// 没权限 / 只读（Windows `ERROR_ACCESS_DENIED` / POSIX `EACCES` · `EROFS`）。
  readOnly,

  /// 路径不存在（Windows `ERROR_FILE_NOT_FOUND` · `ERROR_PATH_NOT_FOUND` / POSIX `ENOENT`）。
  /// 常见于：文件夹被改名 / 移走，U 盘没插好。
  notFound,

  /// 其它（含非 IO 异常、以及平台重叠码取不到的保守值）。
  unknown,
}

/// 判定类别。认 [OSError] 的 `errorCode`（[FileSystemException] 是它的**持有者**
/// 而不是子类 —— `FileSystemException implements IOException`，OS 码挂在
/// `osError` 字段上）。
///
/// [windows] 只为**可测性**存在：`null`（默认）⇒ 取 [Platform.isWindows]。
/// ⚠️ Windows 与 POSIX 的**码值有重叠**（`13` 在 Windows 是 `ERROR_INVALID_DATA`、
/// 在 POSIX 是 `EACCES`；`11` 同理）⇒ 重叠处**必须**按平台分叉，否则会给出
/// 与 errno 不符的建议（正是本次要修的毛病）。
LocalFileFailureKind classifyLocalFileFailure(Object error, {bool? windows}) {
  final int code;
  if (error is OSError) {
    code = error.errorCode;
  } else if (error is FileSystemException) {
    final OSError? os = error.osError;
    if (os == null) return LocalFileFailureKind.unknown;
    code = os.errorCode;
  } else {
    return LocalFileFailureKind.unknown;
  }
  final bool isWindows = windows ?? Platform.isWindows;

  switch (code) {
    // 被占用：Windows「共享冲突 / 锁冲突」；POSIX EBUSY / EAGAIN。
    case 32:
    case 33:
      return LocalFileFailureKind.busy;
    case 16:
      return LocalFileFailureKind.busy;
    case 11:
      return isWindows
          ? LocalFileFailureKind
                .unknown // Windows: ERROR_BAD_FORMAT
          : LocalFileFailureKind.busy; // POSIX: EAGAIN
    // 磁盘满。
    case 112:
    case 28:
      return LocalFileFailureKind.noSpace;
    // 只读 / 无权限。
    case 5:
      return LocalFileFailureKind.readOnly;
    case 13:
      return isWindows
          ? LocalFileFailureKind
                .unknown // Windows: ERROR_INVALID_DATA
          : LocalFileFailureKind.readOnly; // POSIX: EACCES
    case 30:
      return LocalFileFailureKind.readOnly; // POSIX: EROFS
    // 路径不存在。
    case 2:
    case 3:
      return LocalFileFailureKind.notFound;
    default:
      return LocalFileFailureKind.unknown;
  }
}

/// 给用户看的**「怎么办」**。
///
/// ⚠️ **不含**路径、**不含**异常文本、**不含**动作前缀（`导出失败：` 由调用方拼）。
/// 三条共用口径与 [storageFailureNote] 一致：**给可执行动作、不给技术名词、
/// 不承诺做不到的事**。
String localFileFailureAdvice(Object error, {bool? windows}) {
  switch (classifyLocalFileFailure(error, windows: windows)) {
    case LocalFileFailureKind.busy:
      return '文件正被另一个程序占用。'
          '请关掉打开它的程序（多半是 Excel / WPS）再试一次。';
    case LocalFileFailureKind.noSpace:
      return '磁盘空间不够了。'
          '请清理一些空间，或换到别的盘再试一次。';
    case LocalFileFailureKind.readOnly:
      return '目标文件夹不能写入（只读，或者没有权限）。'
          '请检查它的权限，或换一个位置再试一次。';
    case LocalFileFailureKind.notFound:
      return '找不到目标文件夹（被改名 / 移走，或者磁盘没插好）。'
          '请检查位置后再试一次。';
    case LocalFileFailureKind.unknown:
      return '请再试一次；如果一直这样，'
          '请把软件的日志文件发给技术支持（日志里才有详细原因）。';
  }
}
