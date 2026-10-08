/// 存储失败的**用户可读**分类（M15，2026-10-08 裁定 · `docs/reply.md`）。
///
/// ## 为什么需要它
///
/// 三个开单页原来把异常对象直接拼进提示：
/// `'没能保存（$error）。请检查内容后重试…'` —— 而 `SqliteException.toString()`
/// **带着整条 SQL 和绑定参数**（等于把这张单的 payload 全印出来），
/// 手机上一屏都被它盖住；更糟的是文案（Android 报告 M15 实测）在
/// **只读权限恢复后仍叫人「检查内容重试」**，而真正需要的是重开连接。
///
/// ## 两个通道，不要混
///
/// | 给谁 | 内容 | 去哪 |
/// |---|---|---|
/// | **用户** | 一句中文结论 + 一句「怎么办」（本文件） | 界面 |
/// | **技术支持** | 原始异常 + 堆栈 | 日志（调用方 `AppLog.crash`） |
///
/// ## 分类依据是**结果码**，不是异常文本
///
/// `SqliteException.toString()` 会随 SQLite 版本与语句变化 —— 拿它做判断，
/// 换个版本就失效。用 `resultCode`（`extendedResultCode` 的低 8 位 = 主结果码）。
library;

import 'package:sqlite3/sqlite3.dart';

/// 存储失败的类别 —— 决定「告诉用户什么」和「让他做什么」。
enum StorageFailureKind {
  /// 库被另一个连接 / 进程占着（写锁）。**改小数量、换商品都救不了**。
  locked,

  /// 磁盘空间不够（`SQLITE_FULL`）。
  full,

  /// 只读 / 没权限。⚠️ **权限恢复后当前连接仍是只读**，需要重开或重启。
  readOnly,

  /// 文件不是数据库 / 已损坏（`SQLITE_NOTADB` / `SQLITE_CORRUPT`）。
  corrupted,

  /// 找不到或打不开文件（路径没了、U 盘拔了）。
  unopenable,

  /// 其它（含非 SQLite 异常）。
  unknown,
}

/// 判定类别。不是 [SqliteException] ⇒ [StorageFailureKind.unknown]。
///
/// `extendedResultCode & 0xff` 取的是**主结果码**：扩展码（如
/// `SQLITE_READONLY_RECOVERY` = 264）的低 8 位仍是主码 8
/// —— 这正是我们要的分档粒度。
StorageFailureKind classifyStorageFailure(Object error) {
  if (error is! SqliteException) return StorageFailureKind.unknown;
  switch (error.extendedResultCode & 0xff) {
    case 5: // SQLITE_BUSY
    case 6: // SQLITE_LOCKED
      return StorageFailureKind.locked;
    case 13: // SQLITE_FULL
      return StorageFailureKind.full;
    case 3: // SQLITE_PERM
    case 8: // SQLITE_READONLY
      return StorageFailureKind.readOnly;
    case 11: // SQLITE_CORRUPT
    case 26: // SQLITE_NOTADB
      return StorageFailureKind.corrupted;
    case 14: // SQLITE_CANTOPEN
      return StorageFailureKind.unopenable;
    default:
      return StorageFailureKind.unknown;
  }
}

/// 给用户看的**一句结论 + 怎么办**（不含 SQL、参数、异常文本）。
///
/// 三条共用口径：
/// 1. **先说「你填的东西还在」** —— 失败时用户第一反应是「我白填了」；
/// 2. **给出可执行的动作**（关窗口 / 清空间 / 重启 / 换位置），不给技术名词；
/// 3. **不承诺自己做不到的事** —— 例如只读场景明说要重启，因为
///    「重试一次」在当前连接上**必然再失败**。
String storageFailureNote(Object error) {
  switch (classifyStorageFailure(error)) {
    case StorageFailureKind.locked:
      return '没能保存：数据文件正被占用（多半是另一个窗口开着同一个文件夹）。'
          '关掉其它窗口再试一次 —— 你填的内容还在。';
    case StorageFailureKind.full:
      return '没能保存：磁盘空间不够了。'
          '清理一些空间（或到「设置 → 数据」换到别的盘）再试一次 —— 你填的内容还在。';
    case StorageFailureKind.readOnly:
      return '没能保存：数据文件夹现在不能写入（只读、或被别的程序占用）。'
          '请检查这个文件夹的权限；如果刚刚改过权限，需要关掉软件重新打开才能恢复 —— '
          '你填的内容还在。';
    case StorageFailureKind.corrupted:
      return '没能保存：数据文件损坏了，打不开。'
          '请先不要关闭这个页面，到「设置 → 数据」用备份恢复 —— '
          '恢复后你填的内容还在，再保存一次就行。';
    case StorageFailureKind.unopenable:
      return '没能保存：找不到数据文件（文件夹被改名 / 移走，或者 U 盘拔掉了）。'
          '请插回磁盘，或到「设置 → 数据」重新选一个位置 —— 你填的内容还在。';
    case StorageFailureKind.unknown:
      return '没能保存。请再试一次；如果一直这样，'
          '请把软件的日志文件发给技术支持（日志里才有详细原因）。';
  }
}
