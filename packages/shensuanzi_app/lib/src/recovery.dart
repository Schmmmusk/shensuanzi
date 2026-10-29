// 数据抢救 P0：**体检 + 接回**（2026-10-29，提案 52）。
//
// 这一层只做两件事，都**不改业务数据**：
//
//   1. **体检**：把数据目录和「神算子备份」里所有能当退路的文件列出来，
//      逐个**只读**检查（`quick_check` + 版本 + 单据数），让用户看见
//      「我其实有 7 份备份，其中 5 份是好的，最近一份有 1234 张单据」。
//   2. **接回**：把选中的那一份接回去。**现库先改名留存**（`.broken-<时间>`），
//      复制失败或校验不过就自动回滚 —— 任何一步都不删用户的数据。
//
// ## 为什么这一层比「抢救技术」更重要
//
// 2026-10-29 的损坏实验（提案 52 §二）表明：坏索引、坏一页、坏文件头都能救回，
// 只有**截断**救不了。但真实事故里绝大多数用户根本不需要抢救 —— 他的每日备份
// 就躺在旁边，程序认识、他看不见。所以 P0 的产出不是「更聪明的恢复」，
// 而是**把已有的退路摆到台面上**。
//
// ## 三条硬约束（改动前请先读）
//
// 1. **只读打开候选**：体检绝不能改动候选文件。`Db.open` 会跑迁移（把旧备份
//    就地升级），所以这里用裸 `sqlite3.open(mode: readOnly)`。
// 2. **`-wal` / `-shm` 必须一起改名**：库是 WAL 模式，只挪 `.db` 而不挪 `-wal`，
//    新库一打开就会被**旧库的 WAL** 覆盖 —— 那比不恢复更糟。
// 3. **备份版本可以更老，不能更新**：老备份由 App 打开时迁移升上来（正常路径）；
//    新版本备份（比如用户装回旧版软件）打不开，所以体检就标红，不让选。

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/src/backup.dart';
import 'package:sqlite3/sqlite3.dart';

/// 候选文件的来源 —— 决定界面上怎么说（用户看到的是中文，不是枚举名）。
enum RecoverySource {
  /// 每日自动备份（`shensuanzi-schemaN-日期-时刻.db`）
  autoBackup,

  /// 用户自己点「立即备份」生成的（`shensuanzi-m-…`，永不自动清理）
  manualBackup,

  /// 升级前自动留的（`shensuanzi.db.before-vN`）
  beforeMigration,
}

/// 体检结论。
enum RecoveryState {
  /// 能打开、`quick_check` 通过、版本不高于当前 —— **可以接回**
  ok,

  /// 能打开，但 `quick_check` 报错（多半是坏页 / 坏索引）
  corrupted,

  /// 根本打不开（文件头坏了、被别的程序锁着、根本不是 SQLite 文件）
  unreadable,

  /// 版本比当前软件新 —— 接回来也打不开，所以不让选
  newerSchema,
}

/// 一份候选备份的体检结果。
class RecoveryCandidate {
  const RecoveryCandidate({
    required this.path,
    required this.fileName,
    required this.source,
    required this.state,
    required this.bytes,
    this.time,
    this.schemaVersion,
    this.documentCount,
    this.lastDocumentAt,
    this.note,
  });

  /// 完整路径（接回时原样传回去）
  final String path;
  final String fileName;
  final RecoverySource source;
  final RecoveryState state;

  /// 文件字节数（用户用它判断「这份是不是空的」）
  final int bytes;

  /// 备份时刻：优先取**文件名**里的时间（我们写的，确定性强），
  /// 解析不出来才退到文件修改时间。
  final DateTime? time;

  /// 库里的 `user_version`（读不到就是 `null`）
  final int? schemaVersion;

  /// 根单数（`ref_doc_id IS NULL`）—— 用户心里的「多少单」是这个数
  final int? documentCount;

  /// 最后一单的业务日期（`max(occurred_at)`）
  final DateTime? lastDocumentAt;

  /// 不可用的原因（给用户看的一句话；可用时为 `null`）
  final String? note;

  bool get usable => state == RecoveryState.ok;
}

/// 体检：把 [dataDirectory] 与 [backupDirectory] 里所有能当退路的文件列出来。
///
/// **流式返回**：每检查完一份就吐一条。真实场景下候选可能有十几份、
/// 每份 `quick_check` 要几百毫秒（478 MB 上实测 850 ms），
/// 一次性返回会让界面看起来卡死。
Stream<RecoveryCandidate> scanRecoveryCandidates({
  required String dataDirectory,
  required String backupDirectory,
  required int currentSchemaVersion,
}) async* {
  for (final _CandidateRef ref in _collectCandidateRefs(
    dataDirectory: dataDirectory,
    backupDirectory: backupDirectory,
  )) {
    yield _inspect(ref, currentSchemaVersion);
  }
}

/// 候选的「还没体检」形态（路径 + 来源 + 时间）。
class _CandidateRef {
  const _CandidateRef({
    required this.path,
    required this.fileName,
    required this.source,
    required this.time,
  });

  final String path;
  final String fileName;
  final RecoverySource source;
  final DateTime? time;
}

/// 收集候选（**不打开**，只列目录）。
///
/// 排序：时间倒序 —— 用户最可能想要的就是最近那份，把它排在最上面。
List<_CandidateRef> _collectCandidateRefs({
  required String dataDirectory,
  required String backupDirectory,
}) {
  final List<_CandidateRef> refs = <_CandidateRef>[];

  // ① 「神算子备份」里的每日备份 / 手动备份
  final Directory backupDir = Directory(backupDirectory);
  if (backupDir.existsSync()) {
    for (final FileSystemEntity entity in backupDir.listSync()) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);
      final BackupFileName? parsed = BackupFileName.tryParse(name);
      if (parsed == null) continue;
      refs.add(
        _CandidateRef(
          path: entity.path,
          fileName: name,
          source: parsed.manual
              ? RecoverySource.manualBackup
              : RecoverySource.autoBackup,
          time: parsed.time,
        ),
      );
    }
  }

  // ② 数据目录里升级前留的 `shensuanzi.db.before-vN`
  final Directory dataDir = Directory(dataDirectory);
  if (dataDir.existsSync()) {
    for (final FileSystemEntity entity in dataDir.listSync()) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);
      if (!_beforeMigrationPattern.hasMatch(name)) continue;
      refs.add(
        _CandidateRef(
          path: entity.path,
          fileName: name,
          source: RecoverySource.beforeMigration,
          // 文件名里只有版本号没有时间 ⇒ 用修改时间（`Db` 拷完就写，够准）
          time: entity.statSync().modified,
        ),
      );
    }
  }

  refs.sort((_CandidateRef a, _CandidateRef b) {
    final DateTime ta = a.time ?? DateTime.fromMillisecondsSinceEpoch(0);
    final DateTime tb = b.time ?? DateTime.fromMillisecondsSinceEpoch(0);
    return tb.compareTo(ta);
  });
  return refs;
}

/// `shensuanzi.db.before-v3`
final RegExp _beforeMigrationPattern = RegExp(r'^shensuanzi\.db\.before-v\d+$');

/// **只读、且不改动文件**地打开一个库。
///
/// 为什么必须带 `immutable=1`（2026-10-29 实测）：本系统的库是 WAL 模式，
/// 普通的 `mode: readOnly` 打开**仍会创建** `-shm` / `-wal` 两个文件 ——
/// 体检一次备份就在「神算子备份」里留下两个空文件，用户打开文件夹会看到
/// 一堆莫名其妙的 `xxx.db-shm`。`immutable=1` 告诉 SQLite「这个文件不会被改」，
/// 它就不碰 sidecar 了（实测：打开前后目录内容逐字相同）。
///
/// ⚠️ 代价：`immutable` 会**忽略**旁边的 `-wal`。对本模块是正确的 ——
/// 备份是 checkpoint 之后的单文件，`.before-vN` 是关闭状态下拷的，
/// 两者都不该有未落盘内容；真有的那种文件本来也不该被当成退路。
Database _openImmutable(String path) => sqlite3.open(
  '${Uri.file(path)}?immutable=1',
  uri: true,
  mode: OpenMode.readOnly,
);

/// 这个错误是不是「压根不像数据库文件」（文件头坏了 / 选错了文件）。
///
/// 对用户的意义与「内部有坏页」不同：前者是**认不出**，后者是**认得出但破了**。
/// 界面上分开说，用户才知道下一步该找什么（找错文件 vs 找另一份备份）。
bool _looksNotADatabase(Object error) {
  final String raw = error is SqliteException ? error.message : '$error';
  return raw.toLowerCase().contains('not a database');
}

/// 体检一份候选。
///
/// ⚠️ 任何异常都要**变成结论**，不能冒出去 —— 体检的意义就是「坏文件也要能报出
/// 它坏在哪」，抛异常等于把用户挡在门外。
RecoveryCandidate _inspect(_CandidateRef ref, int currentSchemaVersion) {
  final int bytes;
  try {
    bytes = File(ref.path).lengthSync();
  } on FileSystemException catch (error) {
    return RecoveryCandidate(
      path: ref.path,
      fileName: ref.fileName,
      source: ref.source,
      state: RecoveryState.unreadable,
      bytes: 0,
      time: ref.time,
      note: '读不到这个文件（${error.osError?.message ?? '可能已被删除'}）',
    );
  }

  // 只读打开。**绝不**用 `Db.open`（那会跑迁移，把候选就地升级）。
  Database? db;
  try {
    db = _openImmutable(ref.path);
  } catch (error) {
    return RecoveryCandidate(
      path: ref.path,
      fileName: ref.fileName,
      source: ref.source,
      state: RecoveryState.unreadable,
      bytes: bytes,
      time: ref.time,
      note: _explainOpenFailure(error),
    );
  }

  try {
    // ① 完整性：`quick_check` 比 `integrity_check` 快一个数量级，
    //    能抓到的正是我们要判断的「这文件还能不能读」。
    String check = 'unknown';
    try {
      final ResultSet rows = db.select('PRAGMA quick_check');
      if (rows.isNotEmpty) {
        check = rows.first.values.first?.toString() ?? 'unknown';
      }
    } on SqliteException catch (error) {
      // 文件头坏掉时 SQLite 是「能打开、一查就报 not a database」——
      // 对用户来说这是「认不出这个文件」，不是「里面有几页坏了」。
      if (_looksNotADatabase(error)) {
        return RecoveryCandidate(
          path: ref.path,
          fileName: ref.fileName,
          source: ref.source,
          state: RecoveryState.unreadable,
          bytes: bytes,
          time: ref.time,
          note: _explainOpenFailure(error),
        );
      }
      return RecoveryCandidate(
        path: ref.path,
        fileName: ref.fileName,
        source: ref.source,
        state: RecoveryState.corrupted,
        bytes: bytes,
        time: ref.time,
        note: '文件内部有损坏（${error.message}）',
      );
    }
    if (check != 'ok') {
      return RecoveryCandidate(
        path: ref.path,
        fileName: ref.fileName,
        source: ref.source,
        state: RecoveryState.corrupted,
        bytes: bytes,
        time: ref.time,
        note: '文件内部有损坏（$check）',
      );
    }

    // ② 版本：比当前软件新 ⇒ 接回来也打不开，先标出来
    final int version =
        db.select('PRAGMA user_version').first.values.first! as int;
    if (version > currentSchemaVersion) {
      return RecoveryCandidate(
        path: ref.path,
        fileName: ref.fileName,
        source: ref.source,
        state: RecoveryState.newerSchema,
        bytes: bytes,
        time: ref.time,
        schemaVersion: version,
        note:
            '这份是新版本软件做的（格式 v$version，'
            '当前软件只认到 v$currentSchemaVersion），接回来打不开',
      );
    }

    // ③ 内容：让用户能判断「这份里有多少东西」
    int? documentCount;
    DateTime? lastDocumentAt;
    try {
      final ResultSet count = db.select(
        'SELECT COUNT(*) FROM documents WHERE ref_doc_id IS NULL',
      );
      documentCount = count.first.values.first! as int;
      final ResultSet last = db.select(
        'SELECT MAX(occurred_at) FROM documents WHERE ref_doc_id IS NULL',
      );
      final Object? raw = last.first.values.first;
      if (raw is int && raw > 0) {
        lastDocumentAt = DateTime.fromMillisecondsSinceEpoch(raw);
      }
    } on SqliteException {
      // 表结构不对（比如更老的版本没这张表）—— 不算坏，只是没这个信息
    }

    return RecoveryCandidate(
      path: ref.path,
      fileName: ref.fileName,
      source: ref.source,
      state: RecoveryState.ok,
      bytes: bytes,
      time: ref.time,
      schemaVersion: version,
      documentCount: documentCount,
      lastDocumentAt: lastDocumentAt,
    );
  } on SqliteException catch (error) {
    return RecoveryCandidate(
      path: ref.path,
      fileName: ref.fileName,
      source: ref.source,
      state: RecoveryState.corrupted,
      bytes: bytes,
      time: ref.time,
      note: '文件内部有损坏（${error.message}）',
    );
  } finally {
    db.dispose();
  }
}

/// 把「打不开」翻译成用户能懂的一句话。
///
/// 真实场景里这一条最常出现的原因是**别的程序占着文件**（网盘同步、
/// 杀毒软件扫描、另一个神算子进程），所以先说这个，再说损坏。
String _explainOpenFailure(Object error) {
  final String raw = error is SqliteException ? error.message : '$error';
  final String lower = raw.toLowerCase();
  if (lower.contains('not a database')) {
    return '这不是一个能识别的数据文件（文件头坏了，或选错了文件）';
  }
  if (lower.contains('locked') || lower.contains('busy')) {
    return '文件正被别的程序占用（关掉它再试）';
  }
  if (lower.contains('unable to open')) {
    return '打不开（可能被别的程序占着，或权限不够）';
  }
  return '打不开（$raw）';
}

/// 接回的结果。
class RecoveryRestoreResult {
  const RecoveryRestoreResult.ok({
    required this.candidatePath,
    required this.archivedPath,
  }) : message = null;

  const RecoveryRestoreResult.failure(this.message)
    : candidatePath = null,
      archivedPath = null;

  /// 接回来的那一份
  final String? candidatePath;

  /// 原来的数据文件被改名到了哪里（`null` = 原来就没有库文件）
  final String? archivedPath;

  final String? message;

  bool get ok => candidatePath != null;
}

/// 把 [candidatePath] 接回去（覆盖 [databasePath]）。
///
/// ## 顺序（每一步失败都能退回原状）
///
/// 1. **再体检一次候选** —— 扫描到点按之间文件可能被改（用户可能刚把它删了）。
/// 2. 现库（`.db` + `-wal` + `-shm`）**改名**成 `<db>.broken-<时间>`，不删。
/// 3. 候选复制成 `<db>.restoring`，再 rename 成 `<db>`（避免复制一半被当成库）。
/// 4. 校验新库能开、`quick_check` 通过、版本不高于当前。
/// 5. 任何一步失败 ⇒ **回滚**：删掉半成品、把 `.broken-*` 改回原名。
Future<RecoveryRestoreResult> restoreFromCandidate({
  required String candidatePath,
  required String databasePath,
  required int currentSchemaVersion,
  DateTime Function()? now,
}) async {
  final File candidate = File(candidatePath);
  if (!candidate.existsSync()) {
    return const RecoveryRestoreResult.failure('这份备份已经不在了，请重新体检');
  }

  // ① 再体检一次（候选自己也得是好的 —— 拿坏的盖掉能用的，是最坏的结果）
  final _CandidateRef ref = _CandidateRef(
    path: candidatePath,
    fileName: p.basename(candidatePath),
    source: RecoverySource.autoBackup,
    time: null,
  );
  final RecoveryCandidate check = _inspect(ref, currentSchemaVersion);
  if (!check.usable) {
    return RecoveryRestoreResult.failure('这份备份现在不能用了：${check.note ?? '体检没通过'}');
  }

  final DateTime stamp = (now ?? DateTime.now)();
  final String suffix =
      '${stamp.year.toString().padLeft(4, '0')}'
      '${stamp.month.toString().padLeft(2, '0')}'
      '${stamp.day.toString().padLeft(2, '0')}'
      '-'
      '${stamp.hour.toString().padLeft(2, '0')}'
      '${stamp.minute.toString().padLeft(2, '0')}'
      '${stamp.second.toString().padLeft(2, '0')}';
  final String archived = '$databasePath.broken-$suffix';

  // ② 现库改名留存。**`-wal` / `-shm` 必须一起挪** —— 库是 WAL 模式，
  //    只挪 `.db` 的话，新库一打开就会被旧库的 WAL 覆盖（比不恢复更糟）。
  final bool hadDatabase = File(databasePath).existsSync();
  final List<String> moved = <String>[];
  if (hadDatabase) {
    for (final String sidecar in <String>['', '-wal', '-shm']) {
      final File source = File('$databasePath$sidecar');
      if (!source.existsSync()) continue;
      try {
        source.renameSync('$archived$sidecar');
        moved.add(sidecar);
      } on FileSystemException catch (error) {
        // 改不动（被占用 / 权限）⇒ 立刻退回，别继续往下走
        _rollbackArchive(databasePath, archived, moved);
        return RecoveryRestoreResult.failure(
          '原来的数据文件正被别的程序占用，改不了名'
          '（${error.osError?.message ?? '请关掉占用它的程序'}）。'
          '数据没有动过。',
        );
      }
    }
  }

  // ③ 复制候选（先落到 `.restoring`，成功后再换名）
  final String staging = '$databasePath.restoring';
  try {
    final File stagingFile = File(staging);
    if (stagingFile.existsSync()) stagingFile.deleteSync();
    candidate.copySync(staging);
    stagingFile.renameSync(databasePath);
  } on FileSystemException catch (error) {
    _deleteQuietly(staging);
    _rollbackArchive(databasePath, archived, moved);
    return RecoveryRestoreResult.failure(
      '复制备份时出错（${error.osError?.message ?? error.message}）。数据没有动过。',
    );
  }

  // ④ 校验新库
  final String? problem = _verifyRestored(databasePath, currentSchemaVersion);
  if (problem != null) {
    _deleteQuietly(databasePath);
    _rollbackArchive(databasePath, archived, moved);
    return RecoveryRestoreResult.failure('接回来之后检查不通过：$problem。数据没有动过。');
  }

  return RecoveryRestoreResult.ok(
    candidatePath: candidatePath,
    archivedPath: hadDatabase ? archived : null,
  );
}

/// 校验刚复制过来的库；返回 `null` 表示没问题。
String? _verifyRestored(String databasePath, int currentSchemaVersion) {
  Database? db;
  try {
    db = _openImmutable(databasePath);
    final ResultSet rows = db.select('PRAGMA quick_check');
    final String check = rows.isEmpty
        ? 'unknown'
        : (rows.first.values.first?.toString() ?? 'unknown');
    if (check != 'ok') return '文件内部有损坏（$check）';
    final int version =
        db.select('PRAGMA user_version').first.values.first! as int;
    if (version > currentSchemaVersion) {
      return '这份是新版本软件做的（v$version），当前软件只认到 v$currentSchemaVersion';
    }
    return null;
  } on SqliteException catch (error) {
    return error.message;
  } finally {
    db?.dispose();
  }
}

/// 把改名走的现库（含 `-wal` / `-shm`）改回原名。
void _rollbackArchive(
  String databasePath,
  String archived,
  List<String> moved,
) {
  for (final String sidecar in moved) {
    final File file = File('$archived$sidecar');
    if (!file.existsSync()) continue;
    try {
      file.renameSync('$databasePath$sidecar');
    } on FileSystemException {
      // 回滚也失败：留给用户手工处理，界面上会报「数据没有动过」——
      // 严格说这句此时不成立，所以下面用 `.broken-*` 的路径提示他。
    }
  }
}

void _deleteQuietly(String path) {
  try {
    final File file = File(path);
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // 删不掉就算了：它是 `<db>.restoring` / `<db>` 的中间态，
    // 下次启动会被 `Db.open` 覆盖或报错，不会误当数据用。
  }
}
