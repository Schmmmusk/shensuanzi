// 兜底 catch 的**用户文案**：把「不知道从哪冒出来的异常」变成一句能看的话（N-f）。
//
// #43② 的落地，2026-11-05 裁定**甲**：内部日志留完整异常，界面给可理解的
// 解决建议，**确实有日志出口时**才说「看日志」，且不许为了隐藏异常丢证据。
//
// ## 为什么又要一个文件（已有 `db/storage_error.dart` / `db/local_file_error.dart`）
//
// 那两个各认**一类**来源：SQLite 结果码 / 文件系统 errno。而兜底 catch 拿到的是
// `Object` —— **事先不知道是哪类**。本文件只做**分派**，不新增判据：
//
// | 异常 | 交给谁 | 为什么 |
// |---|---|---|
// | `SqliteException` | `classifyStorageFailure` | 库层失败，与「保存」几乎同义 |
// | `OSError` / `FileSystemException` | `localFileFailureAdvice` | 那套文案中性、不带动作前缀 |
// | 其它 | 固定一句 | 认不出来就**不许**把原文塞给用户 |
//
// ⚠️ **绝不返回异常原文**。`SqliteException.toString()` 带整条 SQL 与绑定参数
// （= 这张单的 payload），`FileSystemException.toString()` 带绝对路径 + errno
// —— 这正是本批要消掉的东西（§CV·十五 / #54）。
//
// ## 「详情见日志」这句话的纪律（裁定 ③）
//
// 只有**调用方确认自己接了日志出口**时才允许说。所以它做成 [unexpectedFailureAdvice]
// 的 `logged` 参数、**默认 `false`** —— 忘了传就说不出那句话，而不是反过来
// 默认承诺一个可能不存在的日志（纪律 17：指路指到一个不存在的日志 = 撒谎）。
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'db/local_file_error.dart';
import 'db/storage_error.dart';

/// 兜底 catch 给用户的**一句「怎么办」**。
///
/// * [error] —— 捕获到的异常（`Object`，类型未知）；
/// * [logged] —— 调用方**是否已经把原始异常写进日志**。默认 `false` ⇒
///   结尾给「重启后再试」而不是「去看日志」（见文件头的纪律）；
/// * [lead] —— 调用方**已经说出口的结论**（如「同步时出错。」）。传了它，
///   认不出来的那档就**不再**补一句「这一步没能完成。」—— 否则界面上会
///   出现两句同义反复（「修复没能完成。…这一步没能完成。」）。
///
/// 返回**不含**异常原文、绝对路径、SQL、异常类型名的中文句子。
String unexpectedFailureAdvice(
  Object error, {
  bool logged = false,
  String? lead,
}) {
  // ① 库层：按 SQLite 结果码分档（占用 / 满 / 只读 / 坏 / 找不到）。
  if (error is SqliteException) {
    switch (classifyStorageFailure(error)) {
      case StorageFailureKind.locked:
        return _withLead(
          lead,
          '数据文件正被占用（多半是另一个窗口开着同一个文件夹）。关掉其它窗口再试一次。',
        );
      case StorageFailureKind.full:
        return _withLead(
          lead,
          '磁盘空间不够了。清理一些空间，或者到「设置 → 数据」换到别的盘再试一次。',
        );
      case StorageFailureKind.readOnly:
        return _withLead(
          lead,
          '数据文件夹现在不能写入（只读，或者没有权限）。'
          '请检查这个文件夹的权限；如果刚刚改过权限，需要关掉软件重新打开才生效。',
        );
      case StorageFailureKind.corrupted:
        return _withLead(
          lead,
          '数据文件损坏了，这一步做不了。请先不要关闭软件，'
          '到「设置 → 数据」确认备份还在，再联系帮你装软件的人。',
        );
      case StorageFailureKind.unopenable:
        return _withLead(
          lead,
          '找不到数据文件（文件夹被改名 / 移走，或者 U 盘拔掉了）。'
          '请插回磁盘，或到「设置 → 数据」重新选一个位置。',
        );
      case StorageFailureKind.unknown:
        return _generic(logged, lead);
    }
  }

  // ② 文件系统：errno 分档（#35 那套 —— 2026-10-12 实测「按提示做永远修不好」
  //    就是因为没分 errno，把 errno 32「被 Excel 占用」说成「检查磁盘空间」）。
  //    ⚠️ **不直接转发** `localFileFailureAdvice`：它认不出来那档固定说
  //    「把日志发给技术支持」，而那句话在**没接日志出口的调用点**是假话（裁定 ③）。
  //    所以这里只借用它**认得出来**的四档，认不出来仍走 [_generic]。
  final LocalFileFailureKind fileKind = classifyLocalFileFailure(error);
  if (fileKind != LocalFileFailureKind.unknown &&
      (error is OSError || error is FileSystemException)) {
    return _withLead(lead, localFileFailureAdvice(error));
  }

  // ③ 认不出来 ⇒ 固定一句。**不拼 `$error`**。
  return _generic(logged, lead);
}

String _withLead(String? lead, String body) =>
    (lead == null || lead.isEmpty) ? body : '$lead$body';

String _generic(bool logged, String? lead) {
  final String escalate = logged
    ? '如果一直这样，软件的日志里有详细原因，请把它发给帮你装软件的人。'
    : '如果一直这样，请关掉软件重新打开后再试。';
  // 有 lead（调用方已说结论、甚至已给了本页的动作，如「请重新扫码」）
  // ⇒ 只补「一直这样怎么办」，不再重复结论和「可以再试一次」。
  if (lead != null && lead.isNotEmpty) return '$lead$escalate';
  return '这一步没能完成。可以再试一次；$escalate';
}