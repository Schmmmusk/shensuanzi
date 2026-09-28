/// 备份执行的降级门禁（对应 `test/backup_test.dart`，§AE + reply.md 裁定）。
///
/// ⚠️ **改一边必须改另一边** —— `test/**` 是正式门禁，本脚本是
/// 「跑不了 `dart test` 时的降级门禁」（`docs/testing.md` §零）。
///
/// 运行：`dart run tool/selfcheck_backup.dart`
///
/// ⚠️ 需要真实 SQLite 文件库 —— `useLocalSqlite()`（winsqlite3.dll 兜底可用）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name');
  } else {
    _fail++;
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  →  $detail'}');
  }
}

void section(String title) => stdout.writeln('\n── $title ──');

Future<void> main() async {
  useLocalSqlite();

  final DateTime base = DateTime(2026, 9, 28, 15, 30);

  // ============================================================ 文件名
  section('BackupFileName');
  {
    final BackupFileName auto = BackupFileName(
      manual: false,
      schemaVersion: 1,
      time: base,
    );
    check('生成（自动）→ shensuanzi-schema1-20260928-1530.db',
        auto.fileName == 'shensuanzi-schema1-20260928-1530.db');
    final BackupFileName? parsed = BackupFileName.tryParse(auto.fileName);
    check('解析往返：manual=false / schema=1 / 时间还原',
        parsed != null &&
            !parsed.manual &&
            parsed.schemaVersion == 1 &&
            parsed.time == base);
    final BackupFileName manual = BackupFileName(
      manual: true,
      schemaVersion: 1,
      time: base,
    );
    check('手动 m- 前缀', manual.fileName == 'shensuanzi-m-schema1-20260928-1530.db');
    check('README.txt → null', BackupFileName.tryParse('README.txt') == null);
    check('秒被舍弃（分钟粒度）',
        BackupFileName.tryParse(
              BackupFileName(
                manual: false,
                schemaVersion: 1,
                time: DateTime(2026, 9, 28, 15, 30, 59),
              ).fileName,
            )!.time ==
            DateTime(2026, 9, 28, 15, 30));
  }

  // ============================================================ 自动判定
  section('shouldAutoBackup');
  {
    final DateTime now = DateTime(2026, 9, 28, 15, 30);
    check('从未备份 → 备份', shouldAutoBackup(now: now, lastBackup: null));
    check('不足 24h → 跳过',
        !shouldAutoBackup(now: now, lastBackup: now.subtract(const Duration(hours: 1))));
    check('恰好 24h → 跳过（严格大于）',
        !shouldAutoBackup(now: now, lastBackup: now.subtract(const Duration(hours: 24))));
    check('超过 24h → 备份',
        shouldAutoBackup(now: now, lastBackup: now.subtract(const Duration(hours: 25))));
    check('时钟回跳 → 备份一次重新锚定',
        shouldAutoBackup(now: now, lastBackup: now.add(const Duration(hours: 1))));
  }

  // ============================================================ 保留策略
  section('expiredAutoBackups');
  {
    final DateTime now = DateTime(2026, 9, 28, 15, 30);
    BackupFileName auto(int month, int day, {bool manual = false}) =>
        BackupFileName(
          manual: manual,
          schemaVersion: 1,
          time: DateTime(2026, month, day, 12),
        );

    check('空列表 → 空',
        expiredAutoBackups(const <BackupFileName>[], now).isEmpty);
    check('30 天内的自动包不清理',
        expiredAutoBackups(<BackupFileName>[auto(9, 20)], now).isEmpty);
    check('恰好 30 天 → 不过期（严格小于）',
        expiredAutoBackups(<BackupFileName>[auto(8, 29)], now).isEmpty);
    check('30 天前的手动包永不清理',
        expiredAutoBackups(<BackupFileName>[auto(7, 1, manual: true)], now).isEmpty);

    final List<BackupFileName> expired = expiredAutoBackups(
      <BackupFileName>[auto(8, 25), auto(8, 28)],
      now,
    );
    check('同周两份旧自动包 → 只删晚的（周代表 = 最早保留）',
        expired.length == 1 && expired.first.time == DateTime(2026, 8, 28, 12));

    final List<BackupFileName> mixed = expiredAutoBackups(
      <BackupFileName>[auto(8, 20), auto(8, 26), auto(8, 28)],
      now,
    );
    check('不同周各留周代表（08-20 单份保留，08-26/08-28 删 08-28）',
        mixed.length == 1 && mixed.first.time == DateTime(2026, 8, 28, 12));
  }

  // ============================================================ 展示文案
  section('展示文案（§AE-3 / AE-5 / 遗漏 2：与 needsBackupAttention 同源）');
  {
    final DateTime now = DateTime(2026, 9, 28, 15, 30);

    check('formatBackupTime(null) → 从未', formatBackupTime(null, now) == '从未');
    check('backupStatusLine 从未',
        backupStatusLine(lastBackup: null, manual: false, now: now) ==
            '上次备份：从未');
    check('空库不提醒（遗漏 1）',
        !needsBackupAttention(
            lastBackup: null, now: now, hasDocuments: false) &&
            needsBackupAttention(
                lastBackup: null, now: now, hasDocuments: true));

    check('今天 09:05',
        formatBackupTime(DateTime(2026, 9, 28, 9, 5), now) == '今天 09:05');
    check('昨天 21:30',
        formatBackupTime(DateTime(2026, 9, 27, 21, 30), now) == '昨天 21:30');
    check('更早 → 9月25日 08:12',
        formatBackupTime(DateTime(2026, 9, 25, 8, 12), now) == '9月25日 08:12');

    check('daysSince 按自然日（同日 → 0，跨日 → 1）',
        daysSince(DateTime(2026, 9, 28, 0, 1), now) == 0 &&
            daysSince(DateTime(2026, 9, 27, 23, 59), now) == 1 &&
            daysSince(null, now) == null);

    check('backupStatusLine 带来源（自动 / 手动）',
        backupStatusLine(
                lastBackup: DateTime(2026, 9, 28, 9, 5),
                manual: false,
                now: now) ==
            '上次备份：今天 09:05（自动）' &&
            backupStatusLine(
                    lastBackup: DateTime(2026, 9, 28, 9, 5),
                    manual: true,
                    now: now) ==
                '上次备份：今天 09:05（手动）');

    final String? never =
        backupReminderText(lastBackup: null, now: now, hasDocuments: false);
    final String? first =
        backupReminderText(lastBackup: null, now: now, hasDocuments: true);
    final String? stale = backupReminderText(
      lastBackup: DateTime(2026, 9, 24, 12),
      now: now,
      hasDocuments: true,
    );
    final String? fresh = backupReminderText(
      lastBackup: DateTime(2026, 9, 28, 9),
      now: now,
      hasDocuments: true,
    );
    final String? exactly3 = backupReminderText(
      lastBackup: DateTime(2026, 9, 25, 15, 30),
      now: now,
      hasDocuments: true,
    );
    check('backupReminderText 与 needsBackupAttention 同源',
        never == null &&
            first != null &&
            first.contains('还没有备份过') &&
            stale != null &&
            stale.contains('4 天') &&
            fresh == null &&
            exactly3 == null);

    // 遗漏 2：失败不能静默（时间上不欠备份，但这次没成 → 也要提醒）
    const String failure = '备份文件夹用不了。请检查它是不是被删掉、被设成只读，或者磁盘满了';
    final DateTime today = DateTime(2026, 9, 28, 9, 5);
    check('上次尝试失败 → 提醒（压过「几天没备份」）',
        needsBackupAttention(
            lastBackup: today,
            now: now,
            hasDocuments: true,
            lastFailure: failure) &&
            backupReminderText(
                    lastBackup: today,
                    now: now,
                    hasDocuments: true,
                    lastFailure: failure) ==
                '上次备份没成功：$failure');
    check('上次尝试失败 → 状态行改说失败（不让人对着红字猜）',
        backupStatusLine(
                lastBackup: today,
                manual: false,
                now: now,
                lastFailure: failure) ==
            '上次备份没成功：$failure' &&
            backupStatusLine(lastBackup: today, manual: false, now: now) ==
                '上次备份：今天 09:05（自动）');
    check('空库仍然不提醒（遗漏 1 优先于失败提醒）',
        !needsBackupAttention(
            lastBackup: today,
            now: now,
            hasDocuments: false,
            lastFailure: failure));
  }

  // ============================================================ IO 集成
  section('BackupService 集成（真实文件库）');
  {
    final Directory box = Directory.systemTemp.createTempSync('shensuanzi_bk_');
    final String dataDir = p.join(box.path, 'data');
    final String backupDir = p.join(box.path, 'shensuanzi_backup');
    Directory(dataDir).createSync(recursive: true);
    final Db db = Db.open(p.join(dataDir, 'shensuanzi.db'));
    final BackupService service = BackupService(
      dataDirectory: dataDir,
      backupDirectory: backupDir,
      schemaVersion: 1,
      now: () => base,
    );
    // 一条单据（documents 表）—— hasContent 判定 + WAL 回归探针
    db.raw.execute(
      "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
      'paid_amount, occurred_at, time_estimated, created_at, updated_at) '
      "VALUES ('d1', 'CG20260928-001', 'purchase', 'confirmed', 0, 0, "
      '1700000000000, 0, 1700000000000, 1700000000000)',
    );

    // 空库 + 自动 → skipped（遗漏 1）—— 目录都不该被创建
    final BackupOutcome emptyAuto = await service.autoBackup(
      db: db,
      hasContent: false,
    );
    final Directory backupDirObj = Directory(backupDir);
    final bool backupDirHasDb = backupDirObj.existsSync() &&
        backupDirObj
            .listSync()
            .any((FileSystemEntity e) => e is File && e.path.endsWith('.db'));
    check('空库 + 自动 → skipped，不生成文件',
        !emptyAuto.ok &&
            emptyAuto.skipped &&
            emptyAuto.message!.contains('空') &&
            !backupDirHasDb);

    // 自动备份：WAL 回归探针（必须在手动之前 —— 否则 lastBackup 已是
    // 同分钟，自动会被「不足 24h」跳过）
    final BackupOutcome auto = await service.autoBackup(db: db, hasContent: true);
    bool copyHasDocument = false;
    if (auto.ok) {
      final Db copy = Db.open(auto.path!);
      copyHasDocument =
          (copy.raw.select('SELECT COUNT(*) AS c FROM documents')
                  .first['c']! as int) ==
              1;
      copy.close();
    }
    check('自动备份：ok + WAL 事务不丢（副本里查得到单据）+ 文件名',
        auto.ok &&
            auto.path!.endsWith('shensuanzi-schema1-20260928-1530.db') &&
            copyHasDocument);

    // 手动：空库也执行 + m- 前缀
    Directory(p.join(box.path, 'empty')).createSync(recursive: true);
    final Db emptyDb = Db.open(p.join(box.path, 'empty', 'shensuanzi.db'));
    final BackupService manualService = BackupService(
      dataDirectory: p.join(box.path, 'empty'),
      backupDirectory: backupDir,
      schemaVersion: 1,
      now: () => base,
    );
    final BackupOutcome manual = await manualService.backupNow(db: emptyDb);
    check('手动：空库也执行 + m- 前缀文件名',
        manual.ok &&
            manual.path!.endsWith('shensuanzi-m-schema1-20260928-1530.db'));
    emptyDb.close();

    // 同分钟防连点：两次手动 → 第二次 skipped，目录里只有一份
    Directory(p.join(box.path, 'empty2')).createSync(recursive: true);
    final Db emptyDb2 = Db.open(p.join(box.path, 'empty2', 'shensuanzi.db'));
    final BackupService manualService2 = BackupService(
      dataDirectory: p.join(box.path, 'empty2'),
      backupDirectory: backupDir,
      schemaVersion: 1,
      now: () => base,
    );
    final BackupOutcome manualFirst = await manualService2.backupNow(db: emptyDb2);
    final BackupOutcome manualSecond = await manualService2.backupNow(db: emptyDb2);
    check('同分钟防连点：第二次手动 → skipped',
        manualFirst.ok && manualSecond.ok && manualSecond.skipped);
    emptyDb2.close();

    // 并发串行化：同一同步块内的两次请求复用同一 Future（遗漏 3）
    final Future<BackupOutcome> f1 = service.backupNow(db: db);
    final Future<BackupOutcome> f2 = service.backupNow(db: db);
    final BackupOutcome concurrent = await f1;
    check('并发串行化：复用同一 Future（遗漏 3）', identical(f1, f2));

    // lastBackupTime
    check('lastBackupTime 解析最大时刻',
        service.lastBackupTime() == DateTime(2026, 9, 28, 15, 30));

    // status()：判定只有一处（有单据 + 4 天前备份 → 提醒；空库不提醒）
    // latestBackupFile：4 天前那份被取到，判定随之生效（**独立目录**，
    // 不受上面各步残留影响）
    final String statusDir = p.join(box.path, 'status_dir');
    Directory(statusDir).createSync(recursive: true);
    final BackupService statusService = BackupService(
      dataDirectory: dataDir,
      backupDirectory: statusDir,
      schemaVersion: 1,
      now: () => base,
    );
    final BackupFileName staleName = BackupFileName(
      manual: false,
      schemaVersion: 1,
      time: DateTime(2026, 9, 24, 12),
    );
    File(p.join(statusDir, staleName.fileName)).writeAsStringSync('旧备份');
    final BackupFileName? stale = statusService.latestBackupFile();
    check('latestBackupFile：4 天前那份 + 人话时间',
        stale != null &&
            stale.time == DateTime(2026, 9, 24, 12) &&
            !stale.manual &&
            backupStatusLine(
                    lastBackup: stale.time, manual: stale.manual, now: base) ==
                '上次备份：9月24日 12:00（自动）');
    check('latestBackupFile：同一目录、空库 → 不提醒（遗漏 1）',
        needsBackupAttention(
                lastBackup: stale?.time, now: base, hasDocuments: true) &&
            !needsBackupAttention(
                lastBackup: stale?.time, now: base, hasDocuments: false));

    // 残留 .tmp 清理（遗漏 4-3）—— 顺带钉住 §九 的「跳过重拷不跳过清理」
    final File orphanTmp = File(
      p.join(statusDir, 'shensuanzi-schema1-20260928-1400.db.tmp'),
    );
    orphanTmp.writeAsStringSync('残留');
    await statusService.backupNow(db: db); // 15:30 手动
    check('残留 .tmp 被清理（遗漏 4-3）', !orphanTmp.existsSync());
    final BackupFileName? fresh = statusService.latestBackupFile();
    check('备份后 → 最新一份是手动包 + 提醒消失',
        fresh != null &&
            fresh.manual &&
            !needsBackupAttention(
                lastBackup: fresh.time, now: base, hasDocuments: true));

    // 备份目录不可写 → failure 说怎么办（遗漏 2）
    final File blocker = File(p.join(box.path, 'not-a-dir'));
    blocker.writeAsStringSync('占位');
    final BackupService blockedService = BackupService(
      dataDirectory: dataDir,
      backupDirectory: blocker.path,
      schemaVersion: 1,
      now: () => base,
    );
    final BackupOutcome blocked = await blockedService.backupNow(db: db);
    // ⚠️ 断言「备份文件夹」而不是某一句具体文案：目录不可写有两条路径
    // （建不出来 / 探针写不进），两条都必须落到同一族「说怎么办」的话上
    check('备份目录不可写 → failure 且说怎么办（遗漏 2）',
        !blocked.ok &&
            blocked.message != null &&
            blocked.message!.contains('备份文件夹'));

    // 时钟回跳 → 重新触发（遗漏 9）
    final BackupService rolled = BackupService(
      dataDirectory: dataDir,
      backupDirectory: backupDir,
      schemaVersion: 1,
      now: () => DateTime(2026, 9, 28, 14, 0),
    );
    final BackupOutcome rolledOutcome = await rolled.autoBackup(
      db: db,
      hasContent: true,
    );
    check('时钟回跳 → 自动备份重新触发（新文件名 1400）',
        rolledOutcome.ok && rolledOutcome.path!.endsWith('20260928-1400.db'));

    // 保留策略集成：周代表保留、同周晚者删除、手动包保留
    void writeDummy(BackupFileName name) => File(
      p.join(backupDir, name.fileName),
    ).writeAsStringSync('旧备份');
    BackupFileName mkName(int month, int day, {bool manual = false}) =>
        BackupFileName(
          manual: manual,
          schemaVersion: 1,
          time: DateTime(2026, month, day, 12),
        );
    writeDummy(mkName(8, 3)); // 周 08-03 代表（最早）
    writeDummy(mkName(8, 5)); // 同周更晚 → 删
    writeDummy(mkName(8, 10)); // 周 08-10 唯一一份 → 保留
    writeDummy(mkName(7, 1, manual: true)); // 手动包 → 永不清理
    await service.backupNow(db: db); // 触发保留清理
    check('保留策略集成：周代表保留、同周晚者删除、手动包保留',
        !File(p.join(backupDir, mkName(8, 5).fileName)).existsSync() &&
            File(p.join(backupDir, mkName(8, 3).fileName)).existsSync() &&
            File(p.join(backupDir, mkName(8, 10).fileName)).existsSync() &&
            File(p.join(backupDir, mkName(7, 1, manual: true).fileName))
                .existsSync());

    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
    // 并发结果与 f1 同对象（skipped：同名 m- 包已存在）
    check('并发结果复用（skipped：同名已存在）', concurrent.ok && concurrent.skipped);
  }

  // ============================================================ 汇总
  stdout.writeln(
    '\n自检完成：$_pass 过，$_fail 挂'
    '${_failures.isEmpty ? '' : '  →  ${_failures.join('；')}'}',
  );
  if (_fail > 0) exit(1);
}
