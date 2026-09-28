/// 备份执行（`docs/reply_review.md` §AE / reply.md 裁定）。
///
/// ## 判断都在本文件（纯 Dart，`dart test` 覆盖），UI 只摆放
///
/// - **AE-1 核心（WAL）**：`PRAGMA wal_checkpoint(TRUNCATE)` 后再拷，
///   否则副本缺最新事务（数据库是 WAL 模式，`database.dart`）
/// - **AE-1 加固**：副本 `PRAGMA integrity_check` 通过才算成功——
///   把「看起来成功的备份」变成「确实能用的备份」；失败删残件
/// - **遗漏 4 原子性**：先写 `.tmp` → 校验 → rename；每次顺带清理 `.tmp` 残留
/// - **遗漏 2 可写探测**：建目录 + 写删探针文件；失败给「怎么办」
///   （与导出**共用** `fs.dart` 的 `ensureWritableDirectory`，§AF 建议 1）
/// - **遗漏 3 并发串行**：进行中时新请求复用同一个 Future
/// - **遗漏 9 时钟回跳**：`now < lastBackup` → 备份一次重新锚定
/// - **AE-2 保留策略**：30 天前的自动包删除，「每个自然周最早的一份」豁免；
///   手动包（`m-` 前缀）永不自动清理（防连点：同一分钟只留一份）
/// - **遗漏 1 空库**：自动备份跳过；手动照执行（用户的主动意图）
/// - **遗漏 7 本地时间**：文件名给用户看，用本地时钟
///
/// ## 展示文案也在这里（UI 不造句）
///
/// [formatBackupTime] / [backupStatusLine] / [backupReminderText] /
/// [backupOutcomeMessage] —— 概览橙卡与设置页红字**共用同一个判定**
/// （[needsBackupAttention]，只有一处）；UI 只把字符串摆到界面上
/// （`docs/ui_principles.md` §二：错误信息由领域层给出，UI 不造句）。
/// 取「最新一份备份」用 [BackupService.latestBackupFile]。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'fs.dart';

/// 备份文件名（解析 / 生成）。
///
/// - 自动：`shensuanzi-schema1-20260928-1530.db`
/// - 手动：`shensuanzi-m-schema1-20260928-1530.db`（`m-` 前缀 = 不参与自动清理）
/// - schema 版本进文件名（AE-4：用户在文件管理器里就能看到版本差异）
class BackupFileName {
  const BackupFileName({
    required this.manual,
    required this.schemaVersion,
    required this.time,
  });

  /// `true` = 手动「立即备份」生成的包（不参与自动清理，AE-2 裁定）
  final bool manual;

  final int schemaVersion;

  /// 备份时刻（**本地时间**，分钟粒度 —— 同一分钟内的重复请求共享同名文件）
  final DateTime time;

  static final RegExp _pattern = RegExp(
    r'^shensuanzi(-m)?-schema(\d+)-(\d{8})-(\d{4})\.db$',
  );

  String get fileName {
    final String date =
        '${time.year.toString().padLeft(4, '0')}'
        '${time.month.toString().padLeft(2, '0')}'
        '${time.day.toString().padLeft(2, '0')}';
    final String clock =
        '${time.hour.toString().padLeft(2, '0')}'
        '${time.minute.toString().padLeft(2, '0')}';
    return 'shensuanzi${manual ? '-m' : ''}-schema$schemaVersion-$date-$clock.db';
  }

  /// 解析；不是本程序的备份文件 / 格式不对 → `null`
  static BackupFileName? tryParse(String fileName) {
    final RegExpMatch? match = _pattern.firstMatch(fileName);
    if (match == null) return null;
    final String date = match.group(3)!;
    final String clock = match.group(4)!;
    final DateTime time = DateTime(
      int.parse(date.substring(0, 4)),
      int.parse(date.substring(4, 6)),
      int.parse(date.substring(6, 8)),
      int.parse(clock.substring(0, 2)),
      int.parse(clock.substring(2, 4)),
    );
    return BackupFileName(
      manual: match.group(1) != null,
      schemaVersion: int.parse(match.group(2)!),
      time: time,
    );
  }
}

/// 备份结果。失败时 [message] 按 `ui_principles.md`「说怎么办」。
class BackupOutcome {
  const BackupOutcome.ok(this.path, {this.skipped = false}) : message = null;

  const BackupOutcome.skipped(this.message)
    : path = null,
      skipped = true;

  const BackupOutcome.failure(this.message)
    : path = null,
      skipped = false;

  /// 成功：最终备份文件的完整路径（SnackBar 直接展示，用户可复制）
  final String? path;

  /// `true` = 同一分钟已有同名备份 / 库为空 / 距上次不足 24h —— 没有做新拷贝
  final bool skipped;

  final String? message;

  bool get ok => path != null;
}

/// 保留策略（纯函数，§AE-2 主方案：自然周锚定）。
///
/// - 30 天前的**自动包**删除；**每个自然周（周一锚）最早的一份豁免** ——
///   即使连续 30 天都在错录，也还留着每周一份的还原点（最坏情况的最低保障）
/// - **手动包（`m-` 前缀）永不自动清理**（用户的主动动作有持久意义）
/// - 边界：一周内只有周日一份 → 它是代表；一周内零备份 → 无代表（下周的
///   自动备份成为新代表）；恰好 30 天 → 不算过期（严格 `<`）
List<BackupFileName> expiredAutoBackups(
  List<BackupFileName> files,
  DateTime now,
) {
  final DateTime cutoff = now.subtract(const Duration(days: 30));
  final List<BackupFileName> candidates = files
      .where((BackupFileName f) => !f.manual && f.time.isBefore(cutoff))
      .toList();
  // 自然周锚 = 该周周一的日期串；同周内最早的一份豁免
  final Map<String, BackupFileName> weeklyEarliest = <String, BackupFileName>{};
  for (final BackupFileName file in candidates) {
    final String week = weekKeyOf(file.time);
    final BackupFileName? current = weeklyEarliest[week];
    if (current == null || file.time.isBefore(current.time)) {
      weeklyEarliest[week] = file;
    }
  }
  return candidates
      .where(
        (BackupFileName f) => !identical(weeklyEarliest[weekKeyOf(f.time)], f),
      )
      .toList();
}

/// 该时刻所在自然周（周一锚）的键。
String weekKeyOf(DateTime time) {
  final DateTime monday = DateTime(
    time.year,
    time.month,
    time.day - (time.weekday - 1),
  );
  return '${monday.year}-${monday.month}-${monday.day}';
}

/// 自动备份判定（§AE-3 / 遗漏 9）。
///
/// - `lastBackup == null` → 备份（首次）
/// - 时钟回跳（`now < lastBackup`）→ 备份一次重新锚定
/// - 距上次 >24h → 备份；否则跳过
bool shouldAutoBackup({required DateTime now, required DateTime? lastBackup}) {
  if (lastBackup == null) return true;
  if (now.isBefore(lastBackup)) return true;
  return now.difference(lastBackup) > const Duration(hours: 24);
}

/// 数据安全提醒判定（§AE-3 两层机制 / AE-5 / 遗漏 2：**唯一**的判定入口）。
///
/// - 没有单据（空库）→ 不提醒（没数据可丢，遗漏 1 的同款语义）
/// - **最近一次尝试就失败了** → 提醒（遗漏 2：不能静默 —— 否则用户
///   会一直以为「有备份」，直到真要用的时候才发现半年没成功过）
/// - 从未备份，或距上次备份超过 [staleAfter]（默认 3 天）→ 需要提醒
///
/// ⚠️ **判定必须只有这一处**：概览橙卡、设置页红字都必须问它，
/// 不许各自按「有没有文件 / 隔了几天」再算一遍。
bool needsBackupAttention({
  required DateTime? lastBackup,
  required DateTime now,
  required bool hasDocuments,
  String? lastFailure,
  Duration staleAfter = const Duration(days: 3),
}) {
  if (!hasDocuments) return false;
  if (lastFailure != null) return true;
  if (lastBackup == null) return true;
  return now.difference(lastBackup) > staleAfter;
}

/// `time` 到 `now` 差几个**自然日**（`time == null` → `null`）。
///
/// 按日历日算而不是 24 小时差：昨晚 23:00 备份的，今天早上看起来就是
/// 「昨天」—— 用户也是这么理解的。
int? daysSince(DateTime? time, DateTime now) {
  if (time == null) return null;
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime that = DateTime(time.year, time.month, time.day);
  return today.difference(that).inDays;
}

/// 「上次备份是什么时候」的人话（AE-5 / 遗漏 7：**本地时间**，给用户看）。
///
/// - `null` →「从未」
/// - 今天 →「今天 09:05」
/// - 昨天 →「昨天 21:30」
/// - 更早 →「9月25日 08:12」
String formatBackupTime(DateTime? time, DateTime now) {
  if (time == null) return '从未';
  final String clock =
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
  final int? days = daysSince(time, now);
  if (days == 0) return '今天 $clock';
  if (days == 1) return '昨天 $clock';
  return '${time.month}月${time.day}日 $clock';
}

/// 设置页「上次备份」整行文案（AE-5：时间 + 来源）。
///
/// ⚠️ 最近一次尝试**失败**时这一行改说失败（遗漏 2）—— 只把
/// 「昨天 09:05」染红，用户会对着红字猜「到底怎么了」。
String backupStatusLine({
  required DateTime? lastBackup,
  required bool manual,
  required DateTime now,
  String? lastFailure,
}) {
  if (lastFailure != null) return '上次备份没成功：$lastFailure';
  if (lastBackup == null) return '上次备份：从未';
  return '上次备份：${formatBackupTime(lastBackup, now)}'
      '（${manual ? '手动' : '自动'}）';
}

/// 概览页橙卡文案（AE-3「两层机制」的上层）。
///
/// **`null` = 不需要提醒**（不显示卡片）；非 `null` ⟺ [needsBackupAttention]
/// 为真 —— 文案与判定同源，不会出现「卡片说没事、设置页标红」这种自相矛盾。
String? backupReminderText({
  required DateTime? lastBackup,
  required DateTime now,
  required bool hasDocuments,
  String? lastFailure,
  Duration staleAfter = const Duration(days: 3),
}) {
  if (!needsBackupAttention(
    lastBackup: lastBackup,
    now: now,
    hasDocuments: hasDocuments,
    lastFailure: lastFailure,
    staleAfter: staleAfter,
  )) {
    return null;
  }
  // 试过但没成功 → 说清楚「哪儿不对、怎么办」（失败文案由领域层写好）
  if (lastFailure != null) return '上次备份没成功：$lastFailure';
  if (lastBackup == null) {
    return '还没有备份过。点「立即备份」马上存一份，'
        '以后每天打开软件会自动备份。';
  }
  final int days = daysSince(lastBackup, now) ?? 0;
  return '数据已经 $days 天没有备份了。点「立即备份」马上存一份，'
      '别让辛苦记的账只存在一个地方。';
}

/// 手动备份结果的**用户可见**文案（§AE 遗漏 5：当下反馈，与 AE-5 的
/// 「设置页事后查看」不重复）。
///
/// 成功带上**完整路径** —— 用户可以立刻复制到文件管理器；
/// 失败直接用领域层写好的 [BackupOutcome.message]（那里已经说了「怎么办」）。
String backupOutcomeMessage(BackupOutcome outcome) {
  final String? path = outcome.path;
  if (path == null) return outcome.message ?? '备份没有成功，请稍后再试';
  return outcome.skipped
      ? '这一分钟里已经备份过了，没有重复生成：$path'
      : '已备份到 $path';
}

/// 备份执行服务。判断都在这里；UI 只调 [backupNow] / [autoBackup] /
/// [lastBackupTime] / [status]。
class BackupService {
  BackupService({
    required this.dataDirectory,
    required this.backupDirectory,
    required this.schemaVersion,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 数据目录（`shensuanzi.db` 所在处）
  final String dataDirectory;

  /// 备份目录（数据目录的兄弟目录「神算子备份」）
  final String backupDirectory;

  /// schema 版本（进文件名，AE-4 裁定）
  final int schemaVersion;

  final DateTime Function() _now;

  /// 遗漏 3：进行中的备份 —— 新请求直接复用同一个 Future，不重复执行
  Future<BackupOutcome>? _running;

  /// 目录里最新一份备份的时间（解析**文件名**——名字是我们自己写的，
  /// 确定性强；不含未完成的 .tmp）。目录为空 / 没有合法备份 → `null`。
  DateTime? lastBackupTime() => latestBackupFile()?.time;

  /// 目录里最新的一份备份（含 `manual` 标记 —— 设置页「上次备份：（手动）」
  /// 的来源显示用）。没有合法备份 → `null`。
  BackupFileName? latestBackupFile() {
    final Directory dir = Directory(backupDirectory);
    if (!dir.existsSync()) return null;
    BackupFileName? latest;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File) continue;
      final BackupFileName? name = BackupFileName.tryParse(
        p.basename(entity.path),
      );
      if (name == null) continue;
      if (latest == null || name.time.isAfter(latest.time)) latest = name;
    }
    return latest;
  }

  /// 手动备份（设置页 / 概览卡「立即备份」）。**空库也执行**（遗漏 1：
  /// 用户主动意图不受空库限制）。
  Future<BackupOutcome> backupNow({required Db db}) => _run(db: db, manual: true);

  /// 自动备份（启动后调用）。
  ///
  /// - 遗漏 1：[hasContent] = `QueryDao.hasAnyDocument()`，空库跳过
  /// - AE-3：距上次备份不足 24h 跳过（时钟由注入的 [_now] 决定）
  Future<BackupOutcome> autoBackup({
    required Db db,
    required bool hasContent,
  }) async {
    if (!hasContent) {
      return const BackupOutcome.skipped('库还是空的，没有可备份的数据');
    }
    if (!shouldAutoBackup(now: _now(), lastBackup: lastBackupTime())) {
      return const BackupOutcome.skipped('距上次备份不足 24 小时');
    }
    return _run(db: db, manual: false);
  }

  Future<BackupOutcome> _run({required Db db, required bool manual}) {
    final Future<BackupOutcome>? running = _running;
    if (running != null) return running;
    final Future<BackupOutcome> future = _execute(db, manual);
    // 存**包装后**的 Future：并发方拿到的是同一个对象（遗漏 3 的可测形态）
    final Future<BackupOutcome> wrapped = future.whenComplete(
      () => _running = null,
    );
    _running = wrapped;
    return wrapped;
  }

  Future<BackupOutcome> _execute(Db db, bool manual) async {
    try {
      // 遗漏 2：目录可写探测 —— 与**导出共用**同一套判断与措辞（`fs.dart`，
      // §AF 建议 1）。它会：缺失就建 → 建不出来（被删 / 只读 / 路径上蹲着
      // 一个同名文件）报「用不了」→ 写探针文件验证**真的**能写
      final String? problem = ensureWritableDirectory(
        backupDirectory,
        label: '备份文件夹',
      );
      if (problem != null) return BackupOutcome.failure(problem);

      final Directory dir = Directory(backupDirectory);
      final DateTime stamp = _now(); // 遗漏 7：本地时间（给用户看的）
      final BackupFileName name = BackupFileName(
        manual: manual,
        schemaVersion: schemaVersion,
        time: stamp,
      );
      final String target = p.join(backupDirectory, name.fileName);
      final String tmp = '$target.tmp';
      // 同一分钟防连点（手动）/ 重启重入（自动）：已有同名 → 跳过。
      // ⚠️ 跳过重拷**不跳过清理** —— 残留 .tmp 与过期自动包照常处理
      if (File(target).existsSync()) {
        _applyRetention(dir);
        return BackupOutcome.ok(target, skipped: true);
      }

      // ⚠️ AE-1 核心：WAL 模式下直接拷会缺最新事务 —— 先 checkpoint 落盘
      db.raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');

      final File source = File(p.join(dataDirectory, 'shensuanzi.db'));
      if (!source.existsSync()) {
        return BackupOutcome.failure('找不到数据文件（$source），无法备份');
      }
      source.copySync(tmp);

      // AE-1 加固：打开**副本**做完整性校验 —— 「看起来成功的备份」变成
      // 「确实能用的备份」；失败删残件，不留假备份
      Db? check;
      try {
        check = Db.open(tmp);
        final List<Map<String, Object?>> rows = check.raw
            .select('PRAGMA integrity_check');
        final Object? verdict = rows.isEmpty ? null : rows.first.values.first;
        if ('$verdict' != 'ok') {
          return BackupOutcome.failure('备份校验失败，已删除不完整的备份');
        }
      } catch (_) {
        return BackupOutcome.failure('备份校验失败，已删除不完整的备份');
      } finally {
        check?.close();
        _deleteQuietly(File('$tmp-wal'));
        _deleteQuietly(File('$tmp-shm'));
      }

      // 遗漏 4：rename 是文件系统的原子保证 —— 不会出现「半份备份」
      File(tmp).renameSync(target);

      _applyRetention(dir);
      return BackupOutcome.ok(target);
    } catch (error) {
      _cleanupTmp(backupDirectory);
      return BackupOutcome.failure(
        '备份失败：$error。请重试；若反复失败，请检查备份文件夹所在磁盘',
      );
    }
  }

  /// 保留策略清理 + 残留清理（遗漏 4-3：`.tmp` / 探针文件一并删）
  void _applyRetention(Directory dir) {
    final DateTime now = _now();
    final List<BackupFileName> files = <BackupFileName>[];
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File) continue;
      final String base = p.basename(entity.path);
      if (base.endsWith('.tmp') || base.startsWith('.probe-')) {
        entity.deleteSync();
        continue;
      }
      final BackupFileName? name = BackupFileName.tryParse(base);
      if (name != null) files.add(name);
    }
    for (final BackupFileName expired in expiredAutoBackups(files, now)) {
      final File file = File(p.join(backupDirectory, expired.fileName));
      if (file.existsSync()) file.deleteSync();
    }
  }

  static void _cleanupTmp(String directory) {
    final Directory dir = Directory(directory);
    if (!dir.existsSync()) return;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is File && p.basename(entity.path).endsWith('.tmp')) {
        entity.deleteSync();
      }
    }
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 删不掉不影响结论
    }
  }
}
