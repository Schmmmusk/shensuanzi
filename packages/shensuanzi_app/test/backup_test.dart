// 备份执行（BackupService / 保留策略 / 自动判定 / 展示文案）的测试
// （§AE + reply.md 裁定）。
//
// 覆盖：文件名往返（自动/手动/非法）/ shouldAutoBackup 边界（首次 / 24h 严格 /
// 时钟回跳）/ 保留策略边界（30 天严格 < / 周代表 / 手动包永不清理）/
// 展示文案（daysSince / formatBackupTime / backupStatusLine /
// backupReminderText —— 判定与文案同源，含「上次尝试失败」分支）/
// IO 集成（WAL checkpoint 不丢事务 / 同分钟防连点 / 并发串行化 /
// 残留 .tmp 清理 / 时钟回跳重触发 / latestBackupFile / 目录不可写）。
//
// ⚠️ 需要真实 SQLite 文件库 —— useLocalSqlite()（winsqlite3.dll 兜底可用）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

void main() {
  useLocalSqlite();

  final DateTime base = DateTime(2026, 9, 28, 15, 30);

  BackupFileName auto(int month, int day, {bool manual = false}) =>
      BackupFileName(
        manual: manual,
        schemaVersion: 1,
        time: DateTime(2026, month, day, 12),
      );

  // ============================================================ 文件名
  group('BackupFileName', () {
    test('生成/解析往返（自动）', () {
      final BackupFileName name = BackupFileName(
        manual: false,
        schemaVersion: 1,
        time: base,
      );
      expect(name.fileName, 'shensuanzi-schema1-20260928-1530.db');
      final BackupFileName? parsed = BackupFileName.tryParse(name.fileName);
      expect(parsed!.manual, isFalse);
      expect(parsed.schemaVersion, 1);
      expect(parsed.time, base);
    });

    test('生成/解析往返（手动 m- 前缀）', () {
      final BackupFileName name = BackupFileName(
        manual: true,
        schemaVersion: 1,
        time: base,
      );
      expect(name.fileName, 'shensuanzi-m-schema1-20260928-1530.db');
      expect(BackupFileName.tryParse(name.fileName)!.manual, isTrue);
    });

    test('别人的文件 / 格式不对 → null', () {
      expect(BackupFileName.tryParse('README.txt'), isNull);
      expect(BackupFileName.tryParse('shensuanzi-schema1-20260928-1530.db.bak'),
          isNull);
      expect(BackupFileName.tryParse('shensuanzi-schema1-2026-1530.db'), isNull);
    });

    test('分钟粒度：秒被舍弃（同分钟共享同名文件）', () {
      final BackupFileName name = BackupFileName(
        manual: false,
        schemaVersion: 1,
        time: DateTime(2026, 9, 28, 15, 30, 59),
      );
      expect(
        BackupFileName.tryParse(name.fileName)!.time,
        DateTime(2026, 9, 28, 15, 30),
      );
    });
  });

  // ============================================================ 自动判定
  group('shouldAutoBackup', () {
    final DateTime now = DateTime(2026, 9, 28, 15, 30);

    test('从未备份 → 备份', () {
      expect(shouldAutoBackup(now: now, lastBackup: null), isTrue);
    });

    test('不足 24h → 跳过', () {
      expect(
        shouldAutoBackup(
          now: now,
          lastBackup: now.subtract(const Duration(hours: 1)),
        ),
        isFalse,
      );
    });

    test('恰好 24h → 跳过（严格大于）', () {
      expect(
        shouldAutoBackup(
          now: now,
          lastBackup: now.subtract(const Duration(hours: 24)),
        ),
        isFalse,
      );
    });

    test('超过 24h → 备份', () {
      expect(
        shouldAutoBackup(
          now: now,
          lastBackup: now.subtract(const Duration(hours: 25)),
        ),
        isTrue,
      );
    });

    test('时钟回跳 → 备份一次重新锚定（遗漏 9）', () {
      expect(
        shouldAutoBackup(
          now: now,
          lastBackup: now.add(const Duration(hours: 1)),
        ),
        isTrue,
      );
    });
  });

  // ============================================================ 保留策略
  group('expiredAutoBackups（保留策略）', () {
    final DateTime now = DateTime(2026, 9, 28, 15, 30);

    test('空列表 → 空', () {
      expect(expiredAutoBackups(const <BackupFileName>[], now), isEmpty);
    });

    test('30 天内的自动包不清理', () {
      expect(expiredAutoBackups(<BackupFileName>[auto(9, 20)], now), isEmpty);
    });

    test('恰好 30 天 → 不过期（严格小于）', () {
      expect(expiredAutoBackups(<BackupFileName>[auto(8, 29)], now), isEmpty);
    });

    test('30 天前的手动包永不清理', () {
      expect(
        expiredAutoBackups(<BackupFileName>[auto(7, 1, manual: true)], now),
        isEmpty,
      );
    });

    test('同周两份旧自动包 → 只删晚的，周代表（最早）保留', () {
      // 08-25（周二）与 08-28（周五）同属周一 08-24 锚的周，均超 30 天
      final List<BackupFileName> expired = expiredAutoBackups(
        <BackupFileName>[auto(8, 25), auto(8, 28)],
        now,
      );
      expect(expired.length, 1);
      expect(expired.first.time, DateTime(2026, 8, 28, 12));
    });

    test('不同周各留周代表（08-20 单份保留，08-26/08-28 删 08-28）', () {
      final List<BackupFileName> expired = expiredAutoBackups(
        <BackupFileName>[auto(8, 20), auto(8, 26), auto(8, 28)],
        now,
      );
      expect(expired.length, 1);
      expect(expired.first.time, DateTime(2026, 8, 28, 12));
    });
  });

  // ============================================================ 状态与文案
  //
  // §AE-3 / AE-5：概览橙卡与设置页红字**同源** —— 文案非空 ⟺ 需要提醒，
  // 不允许两处各判一遍（判定住在 `needsBackupAttention` 里）。
  group('展示文案（与 needsBackupAttention 同源）', () {
    final DateTime now = DateTime(2026, 9, 28, 15, 30);

    test('从未备份 → 「从未」；空库不提醒（遗漏 1）', () {
      expect(formatBackupTime(null, now), '从未');
      expect(
        backupStatusLine(lastBackup: null, manual: false, now: now),
        '上次备份：从未',
      );
      expect(
        needsBackupAttention(lastBackup: null, now: now, hasDocuments: true),
        isTrue,
      );
      expect(
        needsBackupAttention(lastBackup: null, now: now, hasDocuments: false),
        isFalse,
        reason: '没数据可丢 → 不提醒',
      );
    });

    test('今天 / 昨天 / 更早 的人话（本地日历日，AE-5 遗漏 7）', () {
      expect(formatBackupTime(DateTime(2026, 9, 28, 9, 5), now), '今天 09:05');
      expect(formatBackupTime(DateTime(2026, 9, 27, 21, 30), now), '昨天 21:30');
      expect(
        formatBackupTime(DateTime(2026, 9, 25, 8, 12), now),
        '9月25日 08:12',
      );
    });

    test('daysSince 按自然日算（跨 24h 但同一天 → 0）', () {
      expect(daysSince(DateTime(2026, 9, 28, 0, 1), now), 0);
      expect(daysSince(DateTime(2026, 9, 27, 23, 59), now), 1);
      expect(daysSince(null, now), isNull);
    });

    test('backupStatusLine 带来源（自动 / 手动，AE-5）', () {
      expect(
        backupStatusLine(
          lastBackup: DateTime(2026, 9, 28, 9, 5),
          manual: false,
          now: now,
        ),
        '上次备份：今天 09:05（自动）',
      );
      expect(
        backupStatusLine(
          lastBackup: DateTime(2026, 9, 28, 9, 5),
          manual: true,
          now: now,
        ),
        '上次备份：今天 09:05（手动）',
      );
    });

    test('backupReminderText 与 needsBackupAttention 同源', () {
      expect(
        backupReminderText(lastBackup: null, now: now, hasDocuments: false),
        isNull,
        reason: '空库不提醒',
      );
      expect(
        backupReminderText(lastBackup: null, now: now, hasDocuments: true),
        contains('还没有备份过'),
      );
      expect(
        backupReminderText(
          lastBackup: DateTime(2026, 9, 24, 12),
          now: now,
          hasDocuments: true,
        ),
        contains('4 天'),
        reason: '超过 3 天 → 说清楚几天',
      );
      expect(
        backupReminderText(
          lastBackup: DateTime(2026, 9, 28, 9),
          now: now,
          hasDocuments: true,
        ),
        isNull,
        reason: '今天备份过 → 不打扰',
      );
      expect(
        backupReminderText(
          lastBackup: DateTime(2026, 9, 25, 15, 30),
          now: now,
          hasDocuments: true,
        ),
        isNull,
        reason: '恰好 3 天不算超（与 needsBackupAttention 的严格 > 对齐）',
      );
    });

    // §AE 遗漏 2：失败不能静默 —— 只看「上次成功是什么时候」的话，
    // 目录半年不可写、用户却一直以为「昨天还备份过」
    test('最近一次尝试失败 → 立刻提醒，且优先于「几天没备份」', () {
      const String failure = '备份文件夹用不了。请检查它是不是被删掉、被设成只读，或者磁盘满了';
      final DateTime fresh = DateTime(2026, 9, 28, 9, 5); // 「今天」刚成功过

      expect(
        needsBackupAttention(
          lastBackup: fresh,
          now: now,
          hasDocuments: true,
          lastFailure: failure,
        ),
        isTrue,
        reason: '时间上不欠备份，但这次没成 —— 要提醒',
      );
      expect(
        backupReminderText(
          lastBackup: fresh,
          now: now,
          hasDocuments: true,
          lastFailure: failure,
        ),
        '上次备份没成功：$failure',
      );
      expect(
        backupStatusLine(
          lastBackup: fresh,
          manual: false,
          now: now,
          lastFailure: failure,
        ),
        '上次备份没成功：$failure',
        reason: '只把「今天 09:05」染红，用户会对着红字猜「到底怎么了」',
      );
      expect(
        backupStatusLine(lastBackup: fresh, manual: false, now: now),
        '上次备份：今天 09:05（自动）',
        reason: '没失败就照常说时间',
      );
      expect(
        needsBackupAttention(
          lastBackup: fresh,
          now: now,
          hasDocuments: false,
          lastFailure: failure,
        ),
        isFalse,
        reason: '空库仍然不提醒（遗漏 1 优先）',
      );
    });
  });

  // ============================================================ IO 集成
  group('BackupService 集成（真实文件库）', () {
    late Directory box;
    late String dataDir;
    late String backupDir;
    late Db db;
    late BackupService service;

    setUp(() {
      box = Directory.systemTemp.createTempSync('shensuanzi_backup_');
      dataDir = p.join(box.path, 'data');
      backupDir = p.join(box.path, 'shensuanzi_backup');
      Directory(dataDir).createSync(recursive: true);
      db = Db.open(p.join(dataDir, 'shensuanzi.db'));
      service = BackupService(
        dataDirectory: dataDir,
        backupDirectory: backupDir,
        schemaVersion: 1,
        now: () => base,
      );
      // 一条单据 —— hasContent 判定 + WAL 回归探针
      db.raw.execute(
        "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
        'paid_amount, occurred_at, time_estimated, created_at, updated_at) '
        "VALUES ('d1', 'CG20260928-001', 'purchase', 'confirmed', 0, 0, "
        '1700000000000, 0, 1700000000000, 1700000000000)',
      );
    });

    tearDown(() {
      db.close();
      try {
        box.deleteSync(recursive: true);
      } catch (_) {
        // 删不掉不影响结论
      }
    });

    int dbFileCount() {
      final Directory dir = Directory(backupDir);
      if (!dir.existsSync()) return 0;
      return dir
          .listSync()
          .where((FileSystemEntity e) => e is File && e.path.endsWith('.db'))
          .length;
    }

    test('空库 + 自动 → skipped，不生成文件（遗漏 1）', () async {
      final BackupOutcome r = await service.autoBackup(
        db: db,
        hasContent: false,
      );
      expect(r.ok, isFalse);
      expect(r.skipped, isTrue);
      expect(r.message, contains('空'));
      expect(dbFileCount(), 0);
    });

    test('自动备份：WAL 事务不丢（AE-1 核心）+ 文件名带 schema 版本（AE-4）',
        () async {
      final BackupOutcome r = await service.autoBackup(db: db, hasContent: true);
      expect(r.ok, isTrue);
      expect(
        p.basename(r.path!),
        'shensuanzi-schema1-20260928-1530.db',
      );

      // 打开副本：checkpoint 前的事务必须都在（WAL 回归）
      final Db copy = Db.open(r.path!);
      final int count =
          (copy.raw.select('SELECT COUNT(*) AS c FROM documents')
                  .first['c']! as int);
      copy.close();
      expect(count, 1, reason: 'checkpoint 后副本必须包含全部事务');
    });

    test('距上次不足 24h → 自动 skipped', () async {
      await service.autoBackup(db: db, hasContent: true);
      final BackupOutcome r = await service.autoBackup(db: db, hasContent: true);
      expect(r.ok, isFalse);
      expect(r.skipped, isTrue);
      expect(r.message, contains('24'));
    });

    test('手动备份：空库也执行（遗漏 1）+ m- 前缀', () async {
      Directory(p.join(box.path, 'empty')).createSync(recursive: true);
      final Db empty = Db.open(p.join(box.path, 'empty', 'shensuanzi.db'));
      try {
        final BackupOutcome r = await service.backupNow(db: empty);
        expect(r.ok, isTrue);
        expect(p.basename(r.path!), 'shensuanzi-m-schema1-20260928-1530.db');
      } finally {
        empty.close();
      }
    });

    test('同分钟防连点：两次手动 → 第二次 skipped，目录仅一份', () async {
      Directory(p.join(box.path, 'empty')).createSync(recursive: true);
      final Db empty = Db.open(p.join(box.path, 'empty', 'shensuanzi.db'));
      try {
        final BackupOutcome first = await service.backupNow(db: empty);
        final BackupOutcome second = await service.backupNow(db: empty);
        expect(first.ok, isTrue);
        expect(second.ok, isTrue);
        expect(second.skipped, isTrue);
        expect(dbFileCount(), 1);
      } finally {
        empty.close();
      }
    });

    test('并发串行化：进行中复用同一 Future（遗漏 3）', () async {
      final Future<BackupOutcome> f1 = service.backupNow(db: db);
      final Future<BackupOutcome> f2 = service.backupNow(db: db);
      expect(identical(f1, f2), isTrue, reason: '同一 Future → 同一结果对象');
      final BackupOutcome r = await f1;
      expect(r.ok, isTrue);
    });

    test('残留 .tmp 被清理（遗漏 4-3）', () async {
      Directory(backupDir).createSync(recursive: true);
      final File orphan = File(
        p.join(backupDir, 'shensuanzi-schema1-20260928-1400.db.tmp'),
      );
      orphan.writeAsStringSync('残留');
      await service.backupNow(db: db);
      expect(orphan.existsSync(), isFalse);
    });

    test('时钟回跳 → 自动备份重新触发（遗漏 9）', () async {
      await service.backupNow(db: db); // 15:30 已有一份（手动）
      final BackupService rolled = BackupService(
        dataDirectory: dataDir,
        backupDirectory: backupDir,
        schemaVersion: 1,
        now: () => DateTime(2026, 9, 28, 14, 0), // 时钟拨回
      );
      final BackupOutcome r = await rolled.autoBackup(db: db, hasContent: true);
      expect(r.ok, isTrue);
      expect(p.basename(r.path!), 'shensuanzi-schema1-20260928-1400.db');
    });

    test('lastBackupTime：解析文件名取最大时刻', () async {
      expect(service.lastBackupTime(), isNull);
      await service.backupNow(db: db);
      expect(service.lastBackupTime(), base);
    });

    test('latestBackupFile：4 天前那份会被取到，判定随之生效', () async {
      Directory(backupDir).createSync(recursive: true);
      File(
        p.join(backupDir, auto(9, 24).fileName),
      ).writeAsStringSync('旧备份');

      final BackupFileName? last = service.latestBackupFile();
      expect(last, isNotNull);
      expect(last!.time, DateTime(2026, 9, 24, 12));
      expect(last.manual, isFalse);
      expect(
        backupStatusLine(lastBackup: last.time, manual: last.manual, now: base),
        '上次备份：9月24日 12:00（自动）',
      );
      expect(
        needsBackupAttention(
          lastBackup: last.time,
          now: base,
          hasDocuments: true,
        ),
        isTrue,
      );
      expect(
        needsBackupAttention(
          lastBackup: last.time,
          now: base,
          hasDocuments: false,
        ),
        isFalse,
        reason: '同样的目录，空库就不提醒（遗漏 1）',
      );

      await service.backupNow(db: db); // 15:30 手动
      final BackupFileName? fresh = service.latestBackupFile();
      expect(fresh!.time, base);
      expect(fresh.manual, isTrue, reason: '最新一份是手动包（AE-5 来源）');
      expect(
        needsBackupAttention(
          lastBackup: fresh.time,
          now: base,
          hasDocuments: true,
        ),
        isFalse,
        reason: '刚备份过 → 提醒消失',
      );
    });

    test('保留策略集成：周代表保留、同周晚者删除、手动包保留', () async {
      Directory(backupDir).createSync(recursive: true);
      void writeDummy(BackupFileName name) => File(
        p.join(backupDir, name.fileName),
      ).writeAsStringSync('旧备份');

      writeDummy(auto(8, 3)); // 周 08-03 代表（最早）
      writeDummy(auto(8, 5)); // 同周更晚 → 删
      writeDummy(auto(8, 10)); // 周 08-10 唯一一份 → 保留
      writeDummy(auto(7, 1, manual: true)); // 手动包 → 永不清理

      await service.backupNow(db: db); // 触发保留清理

      expect(
        File(p.join(backupDir, auto(8, 5).fileName)).existsSync(),
        isFalse,
        reason: '同周更晚者删除',
      );
      expect(
        File(p.join(backupDir, auto(8, 3).fileName)).existsSync(),
        isTrue,
        reason: '周代表（最早）保留',
      );
      expect(
        File(p.join(backupDir, auto(8, 10).fileName)).existsSync(),
        isTrue,
        reason: '周内唯一一份 → 代表，保留',
      );
      expect(
        File(p.join(backupDir, auto(7, 1, manual: true).fileName)).existsSync(),
        isTrue,
        reason: '手动包永不自动清理',
      );
    });

    test('备份目录不可写 → failure 说怎么办（遗漏 2）', () async {
      final File blocker = File(p.join(box.path, 'not-a-dir'));
      blocker.writeAsStringSync('占位');
      final BackupService blocked = BackupService(
        dataDirectory: dataDir,
        backupDirectory: blocker.path,
        schemaVersion: 1,
        now: () => base,
      );
      final BackupOutcome r = await blocked.backupNow(db: db);
      expect(r.ok, isFalse);
      // ⚠️ 断言「备份文件夹」而不是某一句具体文案：目录不可写有两条路径
      // （建不出来 / 探针写不进），两条都必须落到同一族「说怎么办」的话上
      expect(r.message, contains('备份文件夹'));
    });
  });
}
