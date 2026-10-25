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
  MirrorArchive({required this.mirrorPath, int Function()? clock})
    : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 活镜像库的路径（`<私有目录>/mirror/shensuanzi_mirror.db`）
  final String mirrorPath;

  final int Function() _clock;

  /// 归档根目录：镜像库的兄弟目录 `archive/`
  String get archiveRoot => p.join(p.dirname(mirrorPath), 'archive');

  /// 归档当前镜像。返回落点目录；失败 ⇒ `null`（**不抛**，见文件头）。
  Directory? snapshot({required Db db, required String hostId, int? now}) {
    try {
      final Directory root = Directory(archiveRoot);
      if (!root.existsSync()) root.createSync(recursive: true);
      final int at = now ?? _clock();
      final Directory target = Directory(
        p.join(root.path, '${_safeName(hostId)}-${_stamp(at)}'),
      );
      // 同一分钟里重复触发（连扫两次）⇒ 覆盖同一份，不留一堆重复目录
      if (target.existsSync()) target.deleteSync(recursive: true);
      target.createSync(recursive: true);

      // ⚠️ AE-1 同款：WAL 模式下直接拷会缺最新事务 —— 先 checkpoint 落盘
      db.raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      File(mirrorPath).copySync(p.join(target.path, 'shensuanzi_mirror.db'));

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
      return null;
    }
  }

  /// 列出已有归档（新 → 旧）。读不懂的目录跳过，**不抛**。
  List<MirrorArchiveEntry> list() {
    final Directory root = Directory(archiveRoot);
    if (!root.existsSync()) return const <MirrorArchiveEntry>[];
    final List<MirrorArchiveEntry> out = <MirrorArchiveEntry>[];
    for (final FileSystemEntity entity in root.listSync()) {
      if (entity is! Directory) continue;
      final File manifest = File(p.join(entity.path, 'manifest.json'));
      try {
        final Object? decoded = manifest.existsSync()
            ? jsonDecode(manifest.readAsStringSync())
            : null;
        final Map<String, Object?> json = decoded is Map
            ? Map<String, Object?>.from(decoded)
            : const <String, Object?>{};
        final Object? at = json['archived_at'];
        out.add(
          MirrorArchiveEntry(
            directory: entity.path,
            hostId: (json['host_id'] as String?) ?? '未知主机',
            archivedAt: DateTime.fromMillisecondsSinceEpoch(at is int ? at : 0),
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
