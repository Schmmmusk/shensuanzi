// 把性能基准库准备成**手机镜像**：迁移到当前 schema + 写 `mirror_meta.host_id`。
//
// 用法：`dart run tool/prep_perf_mirror.dart <源库> <目标库> <hostId>`
//
// 为什么需要这一步（2026-11-01 手机性能测试）：
// 1. 基准库是 v5（2026-10-24 造的），手机跑的是 v7 —— 直接推过去会让**手机自己迁移**，
//    那会把「迁移耗时」混进「首屏耗时」，测出来的数没法归因；
// 2. 镜像必须带 `mirror_meta.host_id`，否则 `openMirror` 判不出这台手机属于谁，
//    同步时会当成「换了主机」把整份镜像归档重建 —— 26 万单白测。
//
// ⚠️ 源库**不动**：先复制再迁移（迁移链会重建表、可能拷贝备份）。
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln(
      '用法：dart run tool/prep_perf_mirror.dart <源库> <目标库> <hostId>',
    );
    exit(2);
  }
  useLocalSqlite();
  final String src = args[0];
  final String dst = args[1];
  final String hostId = args[2];

  final File source = File(src);
  if (!source.existsSync()) {
    stderr.writeln('源库不存在：$src');
    exit(2);
  }
  final File target = File(dst);
  for (final String suffix in <String>['', '-wal', '-shm']) {
    final File f = File('$dst$suffix');
    if (f.existsSync()) f.deleteSync();
  }

  final Stopwatch copyWatch = Stopwatch()..start();
  source.copySync(dst);
  stdout.writeln('RESULT copy_ms=${copyWatch.elapsedMilliseconds}');

  final Stopwatch migrateWatch = Stopwatch()..start();
  final Db db = Db.open(dst);
  stdout.writeln(
    'RESULT migrate_ms=${migrateWatch.elapsedMilliseconds} '
    'schema=${db.schemaVersion} (expect ${Schema.version})',
  );

  MirrorMeta(db).writeHostId(hostId);
  stdout.writeln('RESULT host_id=${MirrorMeta(db).hostId}');

  for (final String table in <String>[
    'documents',
    'document_lines',
    'products',
    'parties',
    'sync_queue',
  ]) {
    final List<dynamic> rows = db.raw.select('SELECT COUNT(*) AS n FROM $table');
    stdout.writeln('RESULT $table=${rows.first['n']}');
  }
  // 镜像自检：手机启动时会跑 `PRAGMA quick_check`（状态 2 的判据），
  // 这里先跑一次，免得推过去才发现坏页。
  final List<String> check = db.raw
      .select('PRAGMA quick_check')
      .map((dynamic row) => '${row.values.first}')
      .toList();
  stdout.writeln('RESULT quick_check=${check.join('|')}');

  db.close();
  stdout.writeln(
    'RESULT size_mb=${(File(dst).lengthSync() / 1024 / 1024).toStringAsFixed(1)}',
  );
}
