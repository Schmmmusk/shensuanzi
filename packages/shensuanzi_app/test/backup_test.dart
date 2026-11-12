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
      expect(
        BackupFileName.tryParse('shensuanzi-schema1-20260928-1530.db.bak'),
        isNull,
      );
      expect(
        BackupFileName.tryParse('shensuanzi-schema1-2026-1530.db'),
        isNull,
      );
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
      final List<BackupFileName> expired = expiredAutoBackups(<BackupFileName>[
        auto(8, 25),
        auto(8, 28),
      ], now);
      expect(expired.length, 1);
      expect(expired.first.time, DateTime(2026, 8, 28, 12));
    });

    test('不同周各留周代表（08-20 单份保留，08-26/08-28 删 08-28）', () {
      final List<BackupFileName> expired = expiredAutoBackups(<BackupFileName>[
        auto(8, 20),
        auto(8, 26),
        auto(8, 28),
      ], now);
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

    // 5c（2026-10-24，§CV·一百）：正在备份时**先说正在备份**。
    // 5a 之前拷贝在主线程、界面冻结，这句根本画不出来；搬进 isolate 之后才有意义。
    test('5c：backingUp ⇒ 说「正在备份」，不传则行为不变', () {
      expect(
        backupStatusLine(
          lastBackup: DateTime(2026, 9, 28, 9, 5),
          manual: false,
          now: now,
          backingUp: true,
        ),
        contains('正在备份'),
      );
      expect(
        backupStatusLine(
          lastBackup: DateTime(2026, 9, 28, 9, 5),
          manual: false,
          now: now,
        ),
        startsWith('上次备份：'),
        reason: '默认值不变（不传 backingUp 与从前一致）',
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
        'paid_amount, occurred_at, time_estimated, created_at, updated_at, '
        'business_day) '
        "VALUES ('d1', 'CG20260928-001', 'purchase', 'confirmed', 0, 0, "
        '1700000000000, 0, 1700000000000, 1700000000000, ${businessDayOf(1700000000000)})',
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

    test('自动备份：WAL 事务不丢（AE-1 核心）+ 文件名带 schema 版本（AE-4）', () async {
      final BackupOutcome r = await service.autoBackup(
        db: db,
        hasContent: true,
      );
      expect(r.ok, isTrue);
      expect(p.basename(r.path!), 'shensuanzi-schema1-20260928-1530.db');

      // 打开副本：checkpoint 前的事务必须都在（WAL 回归）
      final Db copy = Db.open(r.path!);
      final int count =
          (copy.raw.select('SELECT COUNT(*) AS c FROM documents').first['c']!
              as int);
      copy.close();
      expect(count, 1, reason: 'checkpoint 后副本必须包含全部事务');
    });

    test('P1：有其它连接持读事务时，副本仍含全部已提交事务（旧实现会丢）', () async {
      // ## 这条测试为什么能抓住旧实现（2026-11-11 用户审查 P1）
      //
      // 旧做法是主线程 `PRAGMA wal_checkpoint(TRUNCATE)` → 拷主库文件。
      // 但 WAL 模式下，**只要还有别的连接持着读事务**，checkpoint 就无法把
      // 后面的帧归并进主库 —— 此时 `wal_checkpoint` 返回 `busy=1`，
      // 而旧代码**没有检查这个返回值**，直接拷主库 ⇒ 副本缺最新事务。
      //
      // 新做法（`VACUUM INTO`）走的是一个**读事务快照**，它读的是逻辑内容，
      // 与「WAL 有没有归并」无关 ⇒ 事务一条都不会丢。
      //
      // 反向灵敏度：把 `_backupAndVerifyInIsolate` 换回 `File.copySync`
      // 并恢复 checkpoint ⇒ 本用例必须红（会报「缺 d2」）。
      //
      // ⚠️ **实测结果（2026-11-11，别把它当成已证实的区分度）**：
      // 换回旧实现后本用例**仍然通过**。原因是 `wal_checkpoint(TRUNCATE)` 在
      // 因读者存在而无法截断 WAL 时，**通常仍会先把数据帧写回主库**，只是
      // 文件没变短 —— 于是「拷主库」恰好也拿到了全部已提交事务。
      // 换句话说：**这条用例锁定的是「副本必须含全部已提交事务」这个性质，
      // 不是「旧实现一定失败」的证明。** 保留它是因为将来若有人改回
      // 「拷文件 + 不做校验」，在某些时序下仍会踩到。
      final int t = 1700000000000;
      db.raw.execute(
        "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
        'paid_amount, occurred_at, time_estimated, created_at, updated_at, '
        'business_day) '
        "VALUES ('d2', 'CG20260928-002', 'purchase', 'confirmed', 0, 0, "
        '$t, 0, $t, $t, ${businessDayOf(t)})',
      );

      // 另一条连接：**显式开一个读事务并保持住**，制造「checkpoint 无法归并」
      final Db reader = Db.open(p.join(dataDir, 'shensuanzi.db'));
      reader.raw.execute('BEGIN');
      reader.raw.select('SELECT COUNT(*) AS c FROM documents');

      final BackupOutcome r = await service.backupNow(db: db);
      expect(r.ok, isTrue, reason: r.message ?? '');

      final Db copy = Db.open(r.path!);
      final List<Object?> ids = copy.raw
          .select('SELECT id FROM documents ORDER BY id')
          .map((Map<String, Object?> row) => row['id'])
          .toList();
      copy.close();
      reader.raw.execute('COMMIT');
      reader.close();

      expect(
        ids,
        containsAll(<String>['d1', 'd2']),
        reason: '有其它读者时 checkpoint 可能只做了一半 —— 副本必须依然拿到全部已提交事务',
      );
    });

    test('P1：备份期间另一连接连续写入 ⇒ 副本是一致的快照（无洞）', () async {
      // ⚠️ **这条用例的局限（实测，2026-11-11）**：换回旧实现（checkpoint +
      // `File.copySync`）它**也是绿的**。原因很具体：
      // 备份开始之后才写入的那 500 条 live 数据，在旧实现下本来就该不在副本里
      // ——「备份开始时的快照」与「拷贝时刻的主库文件」在小数据量下结果相同。
      // 旧实现的真正风险是「写入超过 1000 页触发**自动 checkpoint**，
      // 复制进行到一半时主库页被改写 ⇒ 读到混合状态」，那需要几十 MB 数据
      // 才复现，不适合放进单元测试。
      //
      // ⇒ 本用例锁定的是**性质**（副本必须是一致快照：开始前的全在、
      // 之后的成连续前缀），不是「新旧实现的判别器」。
      final int t = 1700000000000;
      void insert(Db target, String id, String docNo) {
        target.raw.execute(
          "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
          'paid_amount, occurred_at, time_estimated, created_at, updated_at, '
          'business_day) '
          "VALUES ('$id', '$docNo', 'purchase', 'confirmed', 0, 0, "
          '$t, 0, $t, $t, ${businessDayOf(t)})',
        );
      }

      // 预置一批（让 VACUUM 有活干，制造与并发写的重叠窗口）
      db.raw.execute('BEGIN');
      for (int i = 0; i < 3000; i++) {
        insert(db, 'seed-${i.toString().padLeft(4, '0')}', 'SEED-$i');
      }
      db.raw.execute('COMMIT');

      // 启动备份但**不等它完成**
      final Future<BackupOutcome> pending = service.backupNow(db: db);

      // 备份进行中：另一条连接连续写入（模拟「用户一边开单一边备份」、
      // 或后台同步在写）。备份如果被这些写打断，就会出现空洞或倒退。
      final Db writer = Db.open(p.join(dataDir, 'shensuanzi.db'));
      int written = 0;
      try {
        for (int i = 0; i < 500; i++) {
          insert(writer, 'live-${i.toString().padLeft(4, '0')}', 'LIVE-$i');
          written++;
          // ⚠️ 每 25 条**让出一次事件循环**：500 次同步 INSERT 只要几毫秒，
          // 如果一口气跑完，备份 isolate 可能还没启动，就测不到真正的并发。
          // 让出之后 isolate 才有机会真的与写入交错 —— 这也是这条用例能区分
          // 「一致快照」与「拷到一半的文件」的前提。
          if (i % 25 == 0) await Future<void>.delayed(Duration.zero);
        }
      } finally {
        writer.close();
      }

      final BackupOutcome r = await pending;
      expect(r.ok, isTrue, reason: r.message ?? '');

      final Db copy = Db.open(r.path!);
      int seed = 0;
      List<Object?> live = const <Object?>[];
      try {
        seed =
            copy.raw
                    .select(
                      "SELECT COUNT(*) AS c FROM documents WHERE id LIKE 'seed-%'",
                    )
                    .first['c']!
                as int;
        live = copy.raw
            .select(
              "SELECT id FROM documents WHERE id LIKE 'live-%' ORDER BY id",
            )
            .map((Map<String, Object?> row) => row['id'])
            .toList();
      } finally {
        copy.close();
      }

      // ① 备份开始前已提交的，一条都不能少（抓「checkpoint 不完整 / 复制中途变化」）
      expect(seed, 3000, reason: '备份开始前的 3000 条必须全在');
      // ② 并发写的部分只能是**一个前缀**：出现 live-0000, live-0002 这种空洞，
      //    就说明拿到的是「东拼西凑」而不是某一时刻的快照
      for (int i = 0; i < live.length; i++) {
        expect(
          live[i],
          'live-${i.toString().padLeft(4, '0')}',
          reason: '副本里的并发写部分必须连续 —— 出现空洞/乱序 = 不是一致快照',
        );
      }
      // ③ 不可能多于实际写入（也不可能为负）
      expect(live.length, lessThanOrEqualTo(written));
    });

    test('距上次不足 24h → 自动 skipped', () async {
      await service.autoBackup(db: db, hasContent: true);
      final BackupOutcome r = await service.autoBackup(
        db: db,
        hasContent: true,
      );
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
      File(p.join(backupDir, auto(9, 24).fileName)).writeAsStringSync('旧备份');

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
      void writeDummy(BackupFileName name) =>
          File(p.join(backupDir, name.fileName)).writeAsStringSync('旧备份');

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

    test('备份目录不可写 → failure 说怎么办（遗漏 2）——探测路径是**手写分类文案**', () async {
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
      // （建不出来 / 探针写不进），两条都必须落到同一族「说怎么办」的话上。
      // 这条走的是 `ensureWritableDirectory` 的探测路径 —— 文案本来就是
      // 手写分类（无异常全文，#54 判据天然满足）。
      expect(r.message, contains('备份文件夹'));
      expect(r.message, isNot(contains('Exception')), reason: '异常类型名不进用户面');
    });

    test('#43：落盘阶段异常 ⇒ onFailure 收原始异常、failure = 同一异常的分类文案', () async {
      // 固定时钟 ⇒ 备份文件名确定（shensuanzi-m-schema1-20260928-1530.db）。
      // 预先在那个位置放一个**目录** ⇒ renameSync 必然抛文件系统异常
      // ⇒ 走 #43 新开的 catch 通道（异常原文不再进 failure 消息）。
      final String targetName = BackupFileName(
        manual: true,
        schemaVersion: 1,
        time: DateTime(2026, 9, 28, 15, 30),
      ).fileName;
      Directory(p.join(backupDir, targetName)).createSync(recursive: true);

      final List<Object> logged = <Object>[];
      final BackupService blocked = BackupService(
        dataDirectory: dataDir,
        backupDirectory: backupDir,
        schemaVersion: 1,
        now: () => base,
        onFailure: (Object error, StackTrace stack) => logged.add(error),
      );
      final BackupOutcome r = await blocked.backupNow(db: db);
      expect(r.ok, isFalse);
      expect(logged, isNotEmpty, reason: '原始异常一个不落全进 onFailure');
      expect(
        r.message,
        localFileFailureAdvice(logged.first),
        reason: '#43：failure 只带**同一异常**的分类文案',
      );
      expect(r.message, isNot(contains('Exception')), reason: '异常类型名不进用户面');
      expect(r.message, isNot(contains(r'$error')), reason: '旧拼接形态必须消失');
    });
  });

  // ============================================ 副本生成的两条防线（2026-11-12 审查 P1）
  //
  // 两条**确定会错**的行为，但**只有第一条能被测出来**（第二遍反向灵敏度实测过）：
  //   ① 源库不在时，`sqlite3.open` 默认 `readWriteCreate` 会**凭空建一个空库** ⇒
  //      VACUUM 成功、quick_check 是 ok、软件报「备份成功」，备份里却没有任何数据。
  //      ✅ **改前必红**（撤掉 `OpenMode.readOnly` ⇒ `Expected: not null, Actual: null`）。
  //   ② 失败（含「校验不过」那条 return 路径）时 `.tmp` 没被删掉，而提示写着「已删除」。
  //      ❌ **测不出**：垃圾源库在创建目标之前就失败了，没有半成品。真正会残留的是
  //      「VACUUM 写到一半被打断」（磁盘满 / 进程被杀），单元测试造不出来。
  //      ⇒ 用例只锁**不变量**，不冒充判别器（这条与上一组「一致性」测试同一个教训）。
  group('backupAndVerifyInIsolate 的防线', () {
    late Directory box;
    late Db sourceDb;
    late String sourcePath;
    late String targetPath;

    setUp(() {
      box = Directory.systemTemp.createTempSync('shensuanzi_snapshot_');
      final String dataDir = p.join(box.path, 'data');
      Directory(dataDir).createSync(recursive: true);
      sourcePath = p.join(dataDir, 'shensuanzi.db');
      sourceDb = Db.open(sourcePath);
      sourceDb.raw.execute(
        "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
        'paid_amount, occurred_at, time_estimated, created_at, updated_at, '
        'business_day) '
        "VALUES ('d1', 'CG20260928-001', 'purchase', 'confirmed', 0, 0, "
        '1700000000000, 0, 1700000000000, 1700000000000, ${businessDayOf(1700000000000)})',
      );
      targetPath = p.join(box.path, 'copy.db.tmp');
    });

    tearDown(() {
      sourceDb.close();
      try {
        box.deleteSync(recursive: true);
      } catch (_) {
        // 删不掉不影响结论
      }
    });

    test('源库不存在 ⇒ 失败，且**不会凭空建出一个空库**', () async {
      sourceDb.close();
      File(sourcePath).deleteSync();
      // 这一步就是把「主流程查过存在、isolate 打开时却没了」的窗口直接摊开
      expect(File(sourcePath).existsSync(), isFalse);

      final String? problem = await backupAndVerifyInIsolate((
        source: sourcePath,
        target: targetPath,
      ));

      expect(problem, isNotNull, reason: '源库不在必须失败，不能报成功');
      expect(
        File(sourcePath).existsSync(),
        isFalse,
        reason:
            '旧实现用默认 readWriteCreate ⇒ SQLite 会在这里建一个空库，'
            '于是「备份成功」而备份是空的',
      );
      expect(File(targetPath).existsSync(), isFalse, reason: '失败不留半成品');
    });

    test('源库存在但不是数据库 ⇒ 失败，且 .tmp 不残留', () async {
      sourceDb.close();
      File(sourcePath).writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);

      final String? problem = await backupAndVerifyInIsolate((
        source: sourcePath,
        target: targetPath,
      ));

      expect(problem, isNotNull);
      expect(
        File(targetPath).existsSync(),
        isFalse,
        // ⚠️ **这条锁的是不变量，不是旧实现的判别器**：实测撤掉修复后本用例
        // 仍然通过 —— 垃圾源库时 `VACUUM INTO` 在**创建目标之前**就失败了，
        // 没有半成品可删。真正会留下 `.tmp` 的是「VACUUM 写到一半被打断」
        // （磁盘满 / 进程被杀），单元测试造不出来。保留它是为了将来有人
        // 改这块逻辑时，「失败不留半成品」这条不许破。
        reason: '失败不留半成品（不变量）',
      );
    });

    test('正常库 ⇒ 成功、副本可读、无 -wal/-shm 残留', () async {
      final String? problem = await backupAndVerifyInIsolate((
        source: sourcePath,
        target: targetPath,
      ));

      expect(problem, isNull);
      expect(File(targetPath).existsSync(), isTrue);
      // 校验走只读连接 ⇒ 不该像 `Db.open` 那样把副本切成 WAL 并留下 -wal
      expect(File('$targetPath-wal').existsSync(), isFalse);
      expect(File('$targetPath-shm').existsSync(), isFalse);
      // 只读校验不该改动被校验的文件：user_version 原样
      final Db copy = Db.open(targetPath, foreignKeys: false);
      try {
        expect(copy.schemaVersion, sourceDb.schemaVersion);
        expect(
          copy.raw.select('SELECT COUNT(*) AS c FROM documents').first['c'],
          1,
        );
      } finally {
        copy.close();
      }
    });
  });
}
