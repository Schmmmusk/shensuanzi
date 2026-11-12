// 换主机时的镜像归档（`MirrorArchive`，F14）—— 提案 63-② 的验收测试。
//
// 这一组钉的是**失败路径**，因为旧实现的失败全都长得像成功：
//   - 归档目录建好了、`VACUUM` 失败了 ⇒ 留一个没有 manifest 的空壳目录；
//   - `list()` 把「没有 manifest」读成空 Map ⇒ 显示「未知主机 · 1970 年」，
//     用户点进去什么都没有；
//   - 归档是同步重活 ⇒ 换主机时界面不动（这条只能靠结构断言，见最后一组）。
//
// ⚠️ 「VACUUM 写到一半被打断（磁盘满 / 被强杀）」单元测试造不出来 ——
// 本文件不假装能测，见 `proposals/63` §七 的说明。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Directory box;
  late String mirrorPath;
  late Db mirror;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_archive_');
    mirrorPath = p.join(box.path, 'mirror', 'shensuanzi_mirror.db');
    Directory(p.dirname(mirrorPath)).createSync(recursive: true);
    mirror = Db.open(mirrorPath, foreignKeys: false);
    mirror.raw.execute(
      'INSERT INTO products (id, code, name, unit, cost_price, sell_price, '
      'safety_stock, is_active, created_at, updated_at, sync_version) '
      "VALUES ('p1','P0001','货','瓶',100,200,0,1,1,1,0)",
    );
  });

  tearDown(() {
    mirror.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  int countProducts(String path) {
    final Database raw = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return raw.select('SELECT COUNT(*) AS c FROM products').first['c']!
          as int;
    } finally {
      raw.dispose();
    }
  }

  /// 归档根目录里还有几个目录（用来断言「失败不留空壳」）
  int archiveDirs(String root) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) return 0;
    return dir.listSync().whereType<Directory>().length;
  }

  group('成功路径', () {
    test('归档落盘：库里真有数据、能列出、没有 -wal/-shm 残留', () async {
      final MirrorArchive archive = MirrorArchive(mirrorPath: mirrorPath);

      final Directory? snapshot = await archive.snapshot(hostId: 'h-1');

      expect(snapshot, isNotNull, reason: '归档失败会返回 null（不抛）');
      final String copy = p.join(snapshot!.path, 'shensuanzi_mirror.db');
      expect(File(copy).existsSync(), isTrue);
      expect(countProducts(copy), 1, reason: '归档必须是**有内容**的库，不是空壳');
      // `VACUUM INTO` 直写新文件，目标侧本来就不会有 sidecar
      expect(File('$copy-wal').existsSync(), isFalse);
      expect(File('$copy-shm').existsSync(), isFalse);
      expect(File(p.join(snapshot.path, 'manifest.json')).existsSync(), isTrue);

      final List<MirrorArchiveEntry> entries = archive.list();
      expect(entries.length, 1);
      expect(entries.single.hostId, 'h-1');
    });

    test('同一分钟重复触发 ⇒ 覆盖同一份，不堆一堆重复目录', () async {
      final MirrorArchive archive = MirrorArchive(mirrorPath: mirrorPath);

      await archive.snapshot(hostId: 'h-1', now: 1800000000000);
      await archive.snapshot(hostId: 'h-1', now: 1800000000000);

      expect(archive.list().length, 1);
    });
  });

  group('失败路径：不留空壳、不进列表', () {
    test('源库读不出来（快照失败）⇒ 返回 null，归档目录整个被删', () async {
      final String broken = p.join(box.path, 'mirror', 'broken.db');
      File(broken).writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
      final MirrorArchive archive = MirrorArchive(mirrorPath: broken);

      final Directory? snapshot = await archive.snapshot(hostId: 'h-1');

      expect(snapshot, isNull, reason: '归档是尽力而为：失败也不许抛（配对照常继续）');
      expect(
        archiveDirs(archive.archiveRoot),
        0,
        reason: '失败必须把刚建的目标目录删掉，否则 `list()` 会多一条假归档',
      );
      expect(archive.list(), isEmpty);
    });

    test('manifest 写不进去 ⇒ 返回 null，归档目录整个被删', () async {
      final MirrorArchive archive = MirrorArchive(
        mirrorPath: mirrorPath,
        debugFailManifestWrite: true,
      );

      final Directory? snapshot = await archive.snapshot(hostId: 'h-1');

      expect(snapshot, isNull);
      expect(archiveDirs(archive.archiveRoot), 0);
      expect(archive.list(), isEmpty);
    });

    test('缺 manifest 的目录**不出现**在列表里（旧实现会 add 一条「未知主机」）', () {
      final MirrorArchive archive = MirrorArchive(mirrorPath: mirrorPath);
      Directory(p.join(archive.archiveRoot, 'h-1-20260101-0000')).createSync(
        recursive: true,
      );

      expect(
        archive.list(),
        isEmpty,
        reason: '没有 manifest = 没写完的归档，不是一条记录',
      );
    });

    test('manifest 内容非法（host_id 不是字符串 / archived_at 不是整数）⇒ 跳过', () {
      final MirrorArchive archive = MirrorArchive(mirrorPath: mirrorPath);
      void write(String dir, String json) {
        final Directory target = Directory(p.join(archive.archiveRoot, dir));
        target.createSync(recursive: true);
        File(p.join(target.path, 'manifest.json')).writeAsStringSync(json);
      }

      write('a', '{"host_id": 42, "archived_at": 1800000000000}');
      write('b', '{"host_id": "h-1", "archived_at": "昨天"}');
      write('c', '{"host_id": "", "archived_at": 1800000000000}');
      write('d', '不是 json');

      expect(archive.list(), isEmpty);
    });
  });

  group('结构：归档不许堵住调用方（提案 63-②）', () {
    test('`snapshot` 是 `Future`（`VACUUM INTO` 在独立 isolate 里跑）', () {
      final MirrorArchive archive = MirrorArchive(mirrorPath: mirrorPath);
      // 编译期断言：同步方法赋不到这个函数类型上。
      // （不用「真调一次再 `isA<Future>`」—— 那会在后台留下一个真的归档，
      //  与 `tearDown` 删临时目录抢时间，测出来是 flaky 而不是结论。）
      final Future<Directory?> Function({required String hostId, int? now})
      snapshot = archive.snapshot;
      expect(snapshot, isNotNull);
    });
  });
}
