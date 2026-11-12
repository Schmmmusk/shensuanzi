/// 换主机时的**镜像归档**（F14，2026-10-25 用户裁定）。
///
/// ## 裁定原话
///
/// 「手机扫码时，发现换了主机，**自动将之前连接的主机及其数据全部归档**，
/// 然后再执行现有内容。」
///
/// ## 归档是**快照**，不是搬走
///
/// 把当前镜像库整份拷到 `<镜像目录>/archive/<旧 hostId>-<yyyyMMdd-HHmm>/`，
/// 然后**活库照旧走既有的换主机流程**（重建镜像 + 把未推送的队列挂起）。
///
/// 为什么不"移动"（把队列从活库搬进归档）：队列里是**用户自己开的单**，
/// 留在活库里他才能在新主机上点「重试」把单补发出去
/// （既有行为，见 `mobile_sync_service_test.dart` 的换主机用例）。
/// 归档只负责"旧店那份数据有据可查"，不参与当前同步。
///
/// ## 失败不许阻断配对
///
/// 归档是尽力而为：磁盘满 / 权限不足 / 库被占用 ⇒ 返回 `null`，
/// 配对与重建**照常继续**（用户至少能继续用新主机）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 一份归档的元信息（设置页「历史主机数据」列表用）。
class MirrorArchiveEntry {
  const MirrorArchiveEntry({
    required this.directory,
    required this.hostId,
    required this.archivedAt,
  });

  final String directory;
  final String hostId;
  final DateTime archivedAt;
}

class MirrorArchive {
  MirrorArchive({
    required this.mirrorPath,
    int Function()? clock,
    this.debugFailManifestWrite = false,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 活镜像库的路径（`<私有目录>/mirror/shensuanzi_mirror.db`）
  final String mirrorPath;

  /// 测试注入：写 `manifest.json` 时**故意失败**。
  ///
  /// 真实机器上造不出「manifest 写到一半失败」（磁盘满 / 断电），而这一条的
  /// 后果是「留下一个没有 manifest 的空壳目录」，必须有用例钉住
  /// （与 `DataMigrator.debugFailCopyFor` 同款思路）。
  final bool debugFailManifestWrite;

  final int Function() _clock;

  /// 归档根目录：镜像库的兄弟目录 `archive/`
  String get archiveRoot => p.join(p.dirname(mirrorPath), 'archive');

  /// 归档当前镜像。返回落点目录；失败 ⇒ `null`（**不抛**，见文件头）。
  ///
  /// ## 为什么要进 isolate（2026-11-12 用户审查）
  ///
  /// `VACUUM INTO` 要**读整个库再写一份**，是纯同步重活。它原来是在调用方的
  /// （UI）isolate 上跑的 —— 换主机时界面会长时间不动，用户以为手机死机。
  /// 现在把活整段丢进独立 isolate，本方法只等结果。
  ///
  /// ⇒ 因此**不再需要传 `Db` 进来**：`snapshotDatabaseTo` 按**路径**自己开只读连接。
  /// 这样也顺带避免了「连接不能跨 isolate」那类问题。
  ///
  /// ## 失败要清整个目录
  ///
  /// 目录是在 `VACUUM` **之前**建好的。如果 VACUUM 失败、或 manifest 写到一半
  /// 崩了，就会留下一个**没有 manifest** 的空壳目录。`list()` 现在会跳过它
  /// （见下），但留着也没意义 —— 所以这里直接删掉。
  Future<Directory?> snapshot({required String hostId, int? now}) async {
    Directory? target;
    try {
      final Directory root = Directory(archiveRoot);
      if (!root.existsSync()) root.createSync(recursive: true);
      final int at = now ?? _clock();
      target = Directory(
        p.join(root.path, '${_safeName(hostId)}-${_stamp(at)}'),
      );
      // 同一分钟里重复触发（连扫两次）⇒ 覆盖同一份，不留一堆重复目录
      if (target.existsSync()) target.deleteSync(recursive: true);
      target.createSync(recursive: true);

      final String dbTarget = p.join(target.path, 'shensuanzi_mirror.db');
      // ⚠️ 只传两个**字符串**进 isolate：`Db` / `Directory` 不可发送，
      // **`this` 也不可**（`MirrorArchive` 带着 `_clock` 这个函数字段 ——
      // 函数只有顶层/静态的能跨 isolate）。所以先把值抄进局部变量再进闭包，
      // 否则 `Isolate.run` 抛「object is unsendable」，被下面的 `catch` 吞成
      // 「归档失败」—— 2026-11-12 五条归档用例一起红才发现（见 `proposals/63`）。
      final String sourcePath = mirrorPath;
      final SnapshotProblem? problem = await Isolate.run(
        () => snapshotDatabaseTo(source: sourcePath, target: dbTarget),
      );
      if (problem != null) {
        _deleteQuietly(target);
        return null;
      }

      if (debugFailManifestWrite) {
        throw const FileSystemException('注入：写 manifest 失败');
      }
      File(p.join(target.path, 'manifest.json')).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'app': '神算子',
          'host_id': hostId,
          'archived_at': at,
          'source': mirrorPath,
          'note': '换主机时自动归档：旧主机的镜像 + 当时未推送的队列都在 shensuanzi_mirror.db 里',
        }),
        flush: true,
      );
      return target;
    } catch (_) {
      if (target != null) _deleteQuietly(target);
      return null;
    }
  }

  /// 列出已有归档（新 → 旧）。**读不懂的目录一律跳过，不抛**。
  ///
  /// ## 「跳过」原来只跳了一半（2026-11-12 用户审查）
  ///
  /// 旧实现是 `manifest.existsSync() ? jsonDecode(...) : null` 然后
  /// `decoded is Map ? ... : 空 Map` —— **只有 `jsonDecode` 抛异常**才被 `catch` 跳过。
  /// 「文件不存在」根本不抛，于是拿到空 Map 后仍然 `add` 一条
  /// **「未知主机 · 1970-01-01」** 的假归档，用户点进去什么都没有。
  ///
  /// 而本次改造（VACUUM 失败 / manifest 写到一半崩）**更容易**造出这种半成品目录。
  /// 所以现在要求：**manifest 必须在、必须能解析、关键字段必须合法**，缺一条就跳过。
  List<MirrorArchiveEntry> list() {
    final Directory root = Directory(archiveRoot);
    if (!root.existsSync()) return const <MirrorArchiveEntry>[];
    final List<MirrorArchiveEntry> out = <MirrorArchiveEntry>[];
    for (final FileSystemEntity entity in root.listSync()) {
      if (entity is! Directory) continue;
      final File manifest = File(p.join(entity.path, 'manifest.json'));
      // ① 没有 manifest = 没写完的归档，不是一条记录
      if (!manifest.existsSync()) continue;
      try {
        final Object? decoded = jsonDecode(manifest.readAsStringSync());
        if (decoded is! Map) continue;
        final Map<String, Object?> json = Map<String, Object?>.from(decoded);
        final Object? hostId = json['host_id'];
        final Object? at = json['archived_at'];
        // ② 关键字段不合法 = 半截 manifest，同样不认
        if (hostId is! String || hostId.isEmpty) continue;
        if (at is! int || at <= 0) continue;
        out.add(
          MirrorArchiveEntry(
            directory: entity.path,
            hostId: hostId,
            archivedAt: DateTime.fromMillisecondsSinceEpoch(at),
          ),
        );
      } catch (_) {
        continue;
      }
    }
    out.sort(
      (MirrorArchiveEntry a, MirrorArchiveEntry b) =>
          b.archivedAt.compareTo(a.archivedAt),
    );
    return out;
  }

  /// 删掉一份归档（**只在用户明确要求时**用）。返回是否删成功。
  bool delete(String directory) {
    try {
      final Directory dir = Directory(directory);
      if (!dir.existsSync()) return false;
      dir.deleteSync(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 删掉一个**没做完**的归档目录（尽力而为，失败不抛）。
  static void _deleteQuietly(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉也不阻断（下次 `list()` 会因为缺 manifest 跳过它）
    }
  }

  /// 目录名里不能出现路径分隔符（hostId 来自二维码，别信它）
  static String _safeName(String raw) {
    final String cleaned = raw
        .replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_')
        .trim();
    return cleaned.isEmpty ? 'unknown' : cleaned;
  }

  static String _stamp(int millis) {
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
  }
}
