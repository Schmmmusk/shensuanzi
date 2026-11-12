/// 「一份数据库副本」的两种做法 —— **语义不同，名字必须不同**。
///
/// | 函数 | 保证什么 | 用在 |
/// |---|---|---|
/// | [snapshotDatabaseTo] | **逻辑一致、可读取**的快照（`VACUUM INTO`） | 镜像归档 · 手机导出 · 备份 |
/// | [copyDatabaseAsIs] | **尽可能原样保留字节**（`checkpoint` + 拷贝） | **只有**迁移前备份 |
///
/// ## 为什么不能只留一个（2026-11-12 用户裁定，见 `proposals/63`）
///
/// `VACUUM INTO` 的前提是**源库读得出来**。而迁移前备份存在的唯一理由，
/// 就是「这个库可能已经出问题了」—— 拿 VACUUM 去备份，等于把安全网绑在它要保护的对象上。
/// 反过来，「归档 / 导出」要的是**逻辑完整**，不需要字节保真，VACUUM 更合适：
/// 它在一个读事务里读完整库，并发写不会让它重启。
///
/// ## 三个共同的硬要求
///
/// 1. **源库只读打开**（`OpenMode.readOnly`）—— 默认的 `readWriteCreate`
///    会在源文件消失时**凭空建一个空库**，于是「备份成功」而备份是空的。
/// 2. **失败必须真删半成品** —— 提示说「已删除」就必须真删。
/// 3. **校验用只读连接**（`PRAGMA quick_check`），不许 `Db.open` —— 那会跑迁移链
///    并把库切成 WAL，「检查一份副本」等于顺手改被检查的文件。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../sqlite_local.dart';

/// 生成快照的失败原因（**原因码**，界面文案由调用方决定 —— 同一条原因在不同入口
/// 该说不同的话：备份要报「备份失败」，归档只要静默返回 null）。
enum SnapshotProblem {
  /// 源文件不在（**不建空库**）
  sourceMissing,

  /// 源文件打不开 / 不是数据库 / 内部坏页严重到读不出来
  unreadable,

  /// 写不进去（磁盘满、目录不可写、目标已存在且删不掉）
  writeFailed,

  /// 写完了但 `quick_check` 不过（写完整了没保证）
  verifyFailed,
}

/// 字节拷贝的失败原因。
enum CopyProblem {
  /// `wal_checkpoint` 没能把 WAL 全部归并（`busy != 0`，或 `log != checkpointed`）。
  ///
  /// ⚠️ **不能只看它有没有抛异常** —— WAL 模式下 checkpoint 遇到读者会「做一半
  /// 然后正常返回」，`busy=1` 就是那种情况。
  checkpointIncomplete,

  /// 拷贝本身失败（磁盘满 / 权限 / 文件被占用）
  copyFailed,

  /// 拷完字节数对不上（半份文件）
  sizeMismatch,
}

/// 生成一份**一致、可读取**的快照：`VACUUM INTO` + 只读校验。
///
/// 返回 `null` = 成功；否则是原因码（失败时**目标文件已被删除**，不留半成品）。
///
/// **参数是路径而不是连接** —— 这是刻意的：它要能在 `Isolate.run` 里跑
/// （备份、镜像归档都会这么用）。按连接设计的原语天生进不了 isolate，
/// 最后必然被就地同步调用，又把 UI 堵回去。
SnapshotProblem? snapshotDatabaseTo({
  required String source,
  required String target,
}) {
  useLocalSqlite();
  if (!File(source).existsSync()) return SnapshotProblem.sourceMissing;
  // 目标不能是源库自己（含正斜杠 / 短路径 / 大小写等不同写法）
  if (_sameFile(source, target)) return SnapshotProblem.writeFailed;

  try {
    final File targetFile = File(target);
    // `VACUUM INTO` 要求目标不存在（否则报 output file already exists）
    if (targetFile.existsSync()) targetFile.deleteSync();
  } catch (_) {
    return SnapshotProblem.writeFailed;
  }

  Database? from;
  Database? check;
  bool done = false;
  try {
    // ① 只读打开：源文件不在就报错，不建库
    from = sqlite3.open(source, mode: OpenMode.readOnly);
    from.execute("VACUUM INTO '${_sqlPath(target)}'");
    from.dispose();
    from = null;

    // ② 校验也走只读：不迁移、不切 WAL、不改被校验的文件
    check = sqlite3.open(target, mode: OpenMode.readOnly);
    final ResultSet rows = check.select('PRAGMA quick_check');
    final Object? verdict = rows.isEmpty ? null : rows.first.values.first;
    if ('$verdict' != 'ok') return SnapshotProblem.verifyFailed;
    done = true;
    return null;
  } on SqliteException catch (error) {
    return _looksUnreadable(error)
        ? SnapshotProblem.unreadable
        : SnapshotProblem.writeFailed;
  } catch (_) {
    return SnapshotProblem.writeFailed;
  } finally {
    from?.dispose();
    check?.dispose();
    // ③ 失败（含上面那些 return）必须真删半成品
    if (!done) {
      _deleteQuietly(target);
    }
    // 校验/读写可能在目标旁边留下 sidecar，别让它跟着副本走
    _deleteQuietly('$target-wal');
    _deleteQuietly('$target-shm');
  }
}

/// 把库**按字节**拷一份（`checkpoint` → `.tmp` → 比大小 → 原子改名）。
///
/// 只用于**迁移前备份**：那一处要的是「迁移前的原样」，而且源库可能已经损坏
/// （VACUUM 会读不出来）。前提是**此刻没有第二个写者** —— 这个前提由调用顺序保证
/// （先 `host.stop()`、再关库、再备份、最后迁移），见 `Agents.md` §4.5。
///
/// 返回 `null` = 成功（**包括「目标已存在，跳过」**）；否则是原因码。
///
/// ## 已有同名备份时不覆盖
///
/// 同名意味着「这个版本号的迁移之前已经备过一次」。那一份是**最早**的状态，
/// 比再抓一次（库可能已被上一次失败的迁移动过）更接近用户想要的「退路」。
/// 加上 tmp→rename 保证正式文件永远是完整的，所以「存在即完整」，跳过是安全的。
CopyProblem? copyDatabaseAsIs({
  required Database db,
  required String source,
  required String target,
}) {
  // ① checkpoint 必须真的归并完 —— 三列一起看
  final ResultSet rows = db.select('PRAGMA wal_checkpoint(TRUNCATE)');
  if (rows.isNotEmpty) {
    final Row row = rows.first;
    final int busy = (row['busy'] as int?) ?? 0;
    final int log = (row['log'] as int?) ?? 0;
    final int checkpointed = (row['checkpointed'] as int?) ?? 0;
    // 非 WAL 模式下 log / checkpointed 都是 -1，此时两者相等 ⇒ 不误判
    if (busy != 0 || log != checkpointed) {
      return CopyProblem.checkpointIncomplete;
    }
  }

  final File targetFile = File(target);
  if (targetFile.existsSync()) return null;

  final File tmp = File('$target.tmp');
  try {
    if (tmp.existsSync()) tmp.deleteSync();
    final File sourceFile = File(source);
    sourceFile.copySync(tmp.path);
    // ② 字节数必须一致（磁盘满会写短，copySync 不报错）
    if (sourceFile.lengthSync() != tmp.lengthSync()) {
      _deleteQuietly(tmp.path);
      return CopyProblem.sizeMismatch;
    }
    // ③ 原子改名：正式文件名 **只会** 在内容完整时出现
    tmp.renameSync(target);
    return null;
  } catch (_) {
    _deleteQuietly(tmp.path);
    return CopyProblem.copyFailed;
  }
}

/// 拼进 SQL 字符串字面量的路径：单引号双写，反斜杠统一成正斜杠。
String _sqlPath(String path) =>
    path.replaceAll(r'\', '/').replaceAll("'", "''");

/// 两个路径是否指向同一个文件（大小写 / 分隔符 / `..` 都算同）。
bool _sameFile(String a, String b) =>
    p.equals(p.normalize(p.absolute(a)), p.normalize(p.absolute(b)));

/// SQLite 报的是不是「这压根不是能读的库」。
///
/// 与「写不进去」分开：前者换一份文件还有救，后者是磁盘/权限问题。
bool _looksUnreadable(SqliteException error) {
  final String raw = error.message.toLowerCase();
  return raw.contains('not a database') ||
      raw.contains('malformed') ||
      raw.contains('corrupt') ||
      raw.contains('encrypted');
}

void _deleteQuietly(String path) {
  try {
    final File file = File(path);
    if (file.existsSync()) file.deleteSync();
  } catch (_) {
    // 删不掉不影响结论（外层保留清理会再扫）
  }
}
