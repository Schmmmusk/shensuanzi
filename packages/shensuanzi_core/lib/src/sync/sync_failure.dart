/// 同步操作在**主机端**失败时的可读原因（`docs/reply_review.md` §CS·五 裁定，2026-10-08）。
///
/// ## 为什么要有它
///
/// `SyncServer.handle` 原来是 `catch (error) => rejected('操作失败：$error')` ——
/// 而 `SqliteException.toString()` **带着整条 SQL 与绑定参数**，等于把客户端的
/// payload 原样回传；用户看到的是一屏英文加问号（与 M15 是**同一类问题**，
/// 裁定要求**这次就修**，别等下次换个字段再踩一遍）。
///
/// ## 两个通道，不要混
///
/// | 给谁 | 内容 | 去哪 |
/// |---|---|---|
/// | **客户端 / 用户** | 一句中文结论（本文件） | `SyncResponse.reason` |
/// | **技术支持** | 原始异常 + 堆栈 | 主机日志（`SyncServer.onInternalError`） |
///
/// ## 与 M15 的分工
///
/// 两者共用**同一套结果码分类**（[classifyStorageFailure]，M15 建的那份）：
///
/// | | 面向 | 措辞 |
/// |---|---|---|
/// | M15 `storageFailureNote` | **本机界面**的保存动作 | 「你填的内容还在」这类界面语气 |
/// | 本文件 `syncFailureReason` | **同步回执**（客户端只该知道「主机为什么没收」） | 说清主机侧原因 + 让主机做什么 |
///
/// ## 分类依据是**结果码**，不是异常文本
///
/// 与 M15 同一条理由：`toString()` 会随 SQLite 版本与语句变化，拿它做判断早晚失效。
library;

import 'package:sqlite3/sqlite3.dart';

import '../db/storage_error.dart';

/// 约束冲突的细分 —— **只分用户能理解的三类**（裁定点名的那三类）。
///
/// 用户改不了「是哪个列」，所以不往下细分；但「重复 / 引用没了 / 填错」是
/// 三件**不同的事**，用户要做的动作也不同。
enum ConstraintKind {
  /// 唯一字段重复（`PRIMARY KEY` / `UNIQUE`）。
  duplicate,

  /// 引用的对象在主机上不存在（`FOREIGN KEY`）。
  missingReference,

  /// 数据不完整或不合法（`NOT NULL` / `CHECK`）。
  invalid,
}

/// 判定约束冲突的细分；**不是约束冲突返回 `null`**。
///
/// 先按**扩展结果码**细分；主码是 `SQLITE_CONSTRAINT`（19）但扩展码不认识时
/// （DB 版本差异）兜底成 [ConstraintKind.invalid] —— **宁可说笼统，也不漏报**。
ConstraintKind? constraintKindOf(Object error) {
  if (error is! SqliteException) return null;
  switch (error.extendedResultCode) {
    case 1555: // SQLITE_CONSTRAINT_PRIMARYKEY
    case 2067: // SQLITE_CONSTRAINT_UNIQUE
      return ConstraintKind.duplicate;
    case 787: // SQLITE_CONSTRAINT_FOREIGNKEY
      return ConstraintKind.missingReference;
    case 275: // SQLITE_CONSTRAINT_CHECK
    case 1299: // SQLITE_CONSTRAINT_NOTNULL
      return ConstraintKind.invalid;
    default:
      return (error.extendedResultCode & 0xff) == 19
          ? ConstraintKind.invalid
          : null;
  }
}

/// 给客户端看的**中文原因**：一句结论，**不含 SQL / 参数 / 表名 / 类型名**。
String syncFailureReason(Object error) {
  switch (constraintKindOf(error)) {
    case ConstraintKind.duplicate:
      return '主机上已有相同的数据（唯一字段重复），这条没有收下。';
    case ConstraintKind.missingReference:
      return '这条数据引用的对象在主机上不存在（可能已被删除），没有收下。';
    case ConstraintKind.invalid:
      return '这条数据不完整或不合法（必填项缺失或校验没过），主机没有收下。';
    case null:
      break;
  }
  return switch (classifyStorageFailure(error)) {
    StorageFailureKind.locked => '主机正忙（数据文件被占用），请稍后重试。',
    StorageFailureKind.full => '主机磁盘空间不够，写不进去。请在电脑上清理空间后重试。',
    StorageFailureKind.readOnly => '主机的数据文件现在不能写入，请在电脑上检查后重试。',
    StorageFailureKind.corrupted => '主机的数据文件损坏，无法写入。请在电脑上用备份恢复。',
    StorageFailureKind.unopenable => '主机找不到数据文件。请在电脑上检查数据位置。',
    StorageFailureKind.unknown => '主机处理这条操作时出错，请把电脑上的日志发给技术支持。',
  };
}
