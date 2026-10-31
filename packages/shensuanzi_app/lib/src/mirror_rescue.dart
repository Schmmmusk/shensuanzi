/// **镜像损坏时的队列抢救**（2026-10-31 用户裁定「状态 3」，`docs/reply.md` §四）。
///
/// ## 为什么单独一个文件
///
/// 用户的原话把手机上的数据分成两半，而且**两半的故障边界完全不同**：
///
/// > 电脑上的业务数据是可重新获取的；手机上尚未上传的操作是必须优先保护的。
///
/// 镜像里的商品 / 单据 / 库存可以**从主机整份重拉**；`sync_queue` 里那些
/// 「手机开了、还没推上去」的单**只在手机上**。所以镜像文件一旦打不开，
/// 第一件事不是重建，而是**先把队列抢出来**，再谈重建。
///
/// ## 抢救顺序（每一步都不动原件）
///
/// 1. 把 `.db` + `-wal` **复制**到工作目录（`-wal` 必须带上：未 checkpoint 的
///    条目就在里面，只拷 `.db` 会漏掉最新的那几张单）；
/// 2. 在**副本**上打开（副本可以随便改，原件一个字节都不碰）；
/// 3. 逐行读 `sync_queue`，单行认不出只跳过并计数（不整表放弃）；
/// 4. 删掉副本。
///
/// 原件由调用方负责留档（`archiveBrokenDatabase`），本文件**从不删除**原件。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';

/// 一次抢救的结果。
class MirrorQueueRescue {
  const MirrorQueueRescue({
    required this.entries,
    required this.unreadableRows,
    required this.problem,
    required this.attempted,
  });

  /// 抢出来的条目（`status` 原样保留：`pending` / `failed` / `sent`）
  final List<SyncQueueEntry> entries;

  /// 读不出来的行数（字段坏 / 枚举认不出）—— **必须如实报给用户**
  final int unreadableRows;

  /// 为什么一条都没抢出来（人话）；`null` = 没有出错
  final String? problem;

  /// 有没有真的试过（镜像文件本来就不存在 ⇒ `false`，不是「失败」）
  final bool attempted;

  bool get ok => problem == null;

  int get total => entries.length + unreadableRows;

  @override
  String toString() =>
      'MirrorQueueRescue(entries: ${entries.length}, '
      'unreadable: $unreadableRows, problem: $problem, attempted: $attempted)';
}

/// **镜像自检**：`ok` 返回 `null`，否则返回**人话**原因（状态 2 的判据）。
///
/// 用户裁定（`docs/reply.md` §四）把手机存储故障分成三个状态，这是第二个：
///
/// > 状态 2：镜像可打开，但数据异常 · **尝试修复**
///
/// 与状态 3 的区别只在**怎么发现的**：状态 3 是 `openMirror()` 直接抛（打不开），
/// 这里是**开得起来但内容不对**（坏页 / 结构损坏）。处置是同一条路
/// （抢队列 → 留档 → 重建 → 重拉），所以没有第二套流程。
///
/// ⚠️ `PRAGMA quick_check` 的返回值是**英文**（`database disk image is malformed`），
/// 一律翻译成人话再上界面 —— 与「原始异常只进日志」同一条纪律。
/// 实测代价（478 MB 主库）：`quick_check` **850 ms**、`integrity_check` 3105 ms，
/// 所以这里用 `quick_check`（见 `backup.dart` 的同一条裁定）。
String? mirrorHealthProblemOf(Db mirror) {
  try {
    final List<String> rows = mirror.raw
        .select('PRAGMA quick_check')
        .map((Row row) => '${row.values.first}')
        .toList();
    return quickCheckProblem(rows);
  } on SqliteException catch (error) {
    // ⚠️ 实测（2026-10-31）：坏页严重到 `quick_check` 自己跑不完时，
    // 它**不是返回一行错误**，而是**抛** `SqliteException(11) database disk image
    // is malformed`。不接住的话这个异常会一路冒到启动流程的通用 catch，
    // 被当成「打不开」（状态 3）—— 而它其实是「开得起来但内容不对」（状态 2）。
    return quickCheckProblem(<String>[error.message]);
  }
}

/// `PRAGMA quick_check` 的输出 → 人话（纯函数，测试直接喂字符串）。
String? quickCheckProblem(List<String> rows) {
  if (rows.isEmpty) return null;
  if (rows.length == 1 && rows.first.trim().toLowerCase() == 'ok') return null;
  final String raw = rows.join('；').toLowerCase();
  if (raw.contains('malformed') || raw.contains('corrupt')) {
    return '文件内部有坏页';
  }
  if (raw.contains('not a database') || raw.contains('encrypted')) {
    return '文件认不出来';
  }
  return '自检没通过';
}

/// 隔离恢复的整体结果（抢救 + 留档 + 重建 + 回填）。
class MirrorRecoveryResult {
  const MirrorRecoveryResult._({
    required this.rescue,
    required this.restored,
    required this.enqueueFailures,
    required this.paired,
    this.archivedPath,
    this.message,
  });

  factory MirrorRecoveryResult.ok({
    required MirrorQueueRescue rescue,
    required String? archivedPath,
    required int restored,
    required int enqueueFailures,
    required bool paired,
  }) => MirrorRecoveryResult._(
    rescue: rescue,
    restored: restored,
    enqueueFailures: enqueueFailures,
    paired: paired,
    archivedPath: archivedPath,
  );

  factory MirrorRecoveryResult.failure({
    required MirrorQueueRescue rescue,
    required String message,
    String? archivedPath,
  }) => MirrorRecoveryResult._(
    rescue: rescue,
    restored: 0,
    enqueueFailures: 0,
    paired: false,
    archivedPath: archivedPath,
    message: message,
  );

  final MirrorQueueRescue rescue;

  /// 抢出来并**已经放回新副本**的条数
  final int restored;

  /// 抢出来了、但放不回新副本的条数（写库失败）
  final int enqueueFailures;

  /// 这台手机还配着主机 ⇒ 调用方应该接着做一次全量重拉
  final bool paired;

  /// 原文件的留档路径（`null` = 原来就没有文件）
  final String? archivedPath;

  /// 失败原因（人话）；`null` = 成功
  final String? message;

  bool get ok => message == null;

  /// **明确没能找回**的条数 —— UI 必须说出来，不许假装全找回了
  int get lostCount => rescue.unreadableRows + enqueueFailures;

  @override
  String toString() =>
      'MirrorRecoveryResult(ok: $ok, restored: $restored, lost: $lostCount, '
      'paired: $paired, archived: $archivedPath, message: $message)';
}

/// 从**打不开的镜像文件**里尽量抢出 `sync_queue`。
///
/// [workDirectory] 放副本（调用方给私有目录下的临时位置，跑完自动清）。
/// 任何异常都变成 [MirrorQueueRescue.problem]，**不抛** —— 抢救失败也要能报出来。
MirrorQueueRescue rescueMirrorQueue({
  required String mirrorPath,
  required String workDirectory,
}) {
  final File source = File(mirrorPath);
  if (!source.existsSync()) {
    // 文件都没了 ⇒ 没有可抢救的东西（不是失败：可能是刚被清理软件删掉）
    return const MirrorQueueRescue(
      entries: <SyncQueueEntry>[],
      unreadableRows: 0,
      problem: null,
      attempted: false,
    );
  }

  final Directory work = Directory(workDirectory);
  final String copyPath = p.join(work.path, 'rescue-copy.db');
  final String copyWal = '$copyPath-wal';
  Database? db;
  try {
    work.createSync(recursive: true);
    // ① 复制（含 -wal：未 checkpoint 的最新条目就在里面）
    source.copySync(copyPath);
    final File wal = File('$mirrorPath-wal');
    if (wal.existsSync()) wal.copySync(copyWal);

    // ② 在副本上打开（不走 `Db.open` —— 它会跑迁移链，对一个坏文件只会再炸一次）
    db = sqlite3.open(copyPath);

    // ③ 逐行读，单行坏不连坐整表
    final List<SyncQueueEntry> entries = <SyncQueueEntry>[];
    int unreadable = 0;
    final ResultSet rows = db.select(
      'SELECT * FROM ${Schema.syncQueue} ORDER BY created_at, id',
    );
    for (final Row row in rows) {
      try {
        entries.add(SyncQueueEntry.fromRow(Map<String, Object?>.from(row)));
      } catch (_) {
        unreadable++;
      }
    }
    return MirrorQueueRescue(
      entries: entries,
      unreadableRows: unreadable,
      problem: null,
      attempted: true,
    );
  } on SqliteException catch (error) {
    // 文件头坏 / 页坏到读不出表 —— 对用户是「认不出来了」，不是 SQL 报错
    return MirrorQueueRescue(
      entries: const <SyncQueueEntry>[],
      unreadableRows: 0,
      problem: _explain(error),
      attempted: true,
    );
  } on FileSystemException catch (error) {
    return MirrorQueueRescue(
      entries: const <SyncQueueEntry>[],
      unreadableRows: 0,
      problem: '复制数据文件时出错（${error.osError?.message ?? error.message}）',
      attempted: true,
    );
  } finally {
    db?.dispose();
    _deleteQuietly(copyPath);
    _deleteQuietly(copyWal);
    _deleteQuietly('$copyPath-shm');
    // 2026-10-31 真机：只删文件会在 `mirror/` 下留一个空的 `rescue-tmp/`。
    // 用户看数据目录时会疑惑「这是什么东西」，所以目录也一并收掉。
    try {
      if (work.existsSync() && work.listSync().isEmpty) work.deleteSync();
    } on FileSystemException {
      // 删不掉不影响结论
    }
  }
}

String _explain(SqliteException error) {
  final String raw = error.message.toLowerCase();
  if (raw.contains('not a database') || raw.contains('encrypted')) {
    return '这个文件已经认不出来了（文件头坏了），里面的东西没法读';
  }
  if (raw.contains('malformed')) {
    return '文件内部有坏页，读不出来';
  }
  if (raw.contains('disk i/o') || raw.contains('unable to open')) {
    return '文件读不动（存储有问题，或文件被别的程序占着）';
  }
  return '读不出来（${error.message}）';
}

void _deleteQuietly(String path) {
  try {
    final File file = File(path);
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // 删不掉不影响结论：副本下次会被覆盖
  }
}

/// 抢救清单（给人看、也方便发给技术支持）。
///
/// 用户裁定原文要求：「保存能够恢复的未同步单据，必要时生成可分享的清单」
/// 以及「无法恢复的队列必须明确告诉用户，不能假装已经找回」。
String queueRescueReport({
  required MirrorQueueRescue rescue,
  required DateTime at,
  String? archivedPath,
}) {
  final StringBuffer out = StringBuffer('未同步单据抢救清单\n');
  out
    ..writeln('时间：${_stamp(at)}')
    ..writeln();
  if (!rescue.attempted) {
    out
      ..writeln('手机上的数据副本文件已经不在了，没有可抢救的内容。')
      ..writeln('（这不是失败 —— 可能是被清理软件删掉了。）');
    return out.toString();
  }
  if (!rescue.ok) {
    out
      ..writeln('抢救结果：一条也没能读出来。')
      ..writeln('原因：${rescue.problem}')
      ..writeln()
      ..writeln('原件已经留档，没有删除，需要时可以找技术支持再试一次。');
    if (archivedPath != null) out.writeln('留档位置：$archivedPath');
    return out.toString();
  }

  if (rescue.entries.isEmpty && rescue.unreadableRows == 0) {
    // 真机（状态 2）实测：队列本来就是空的，写成「抢回 0 条」很别扭
    out.writeln('没有还没传给电脑的操作 —— 不需要抢救。');
  } else {
    out.writeln('抢回 ${rescue.entries.length} 条还没传给电脑的操作。');
  }
  if (rescue.unreadableRows > 0) {
    out.writeln(
      '另有 ${rescue.unreadableRows} 条损坏太严重、读不出来 —— '
      '这部分内容没法还原，请不要当成「已经找回」。',
    );
  }
  out.writeln();
  if (rescue.entries.isNotEmpty) {
    out.writeln('明细：');
    int index = 1;
    for (final SyncQueueEntry entry in rescue.entries) {
      out.writeln(
        '$index. ${_stamp(DateTime.fromMillisecondsSinceEpoch(entry.createdAt))}'
        '　${_entityLabel(entry.entity)}'
        '　${_opLabel(entry.operation)}'
        '　${entry.entityId}'
        '　（${_statusLabel(entry.status)}）',
      );
      index++;
    }
  }
  if (archivedPath != null) {
    out
      ..writeln()
      // 「打不开」是状态 3 的说法；状态 2（自检没过）文件其实是开得起来的，
      // 所以这里用中性说法，两种情况都成立。
      ..writeln('原来那份文件已经留档（改名保存，不会删）：$archivedPath');
  }
  return out.toString();
}

String _entityLabel(String entity) => switch (entity) {
  'documents' => '单据',
  'products' => '商品',
  'parties' => '往来方',
  'accounts' => '账户',
  'stock_ledger' => '库存流水',
  _ => entity,
};

String _opLabel(SyncOpType op) => switch (op) {
  SyncOpType.createDocument => '开单',
  SyncOpType.createMasterData => '新增资料',
  SyncOpType.updateMasterData => '修改资料',
  SyncOpType.deleteMasterData => '删除资料',
  SyncOpType.documentAction => '单据动作',
};

String _statusLabel(SyncQueueStatus status) => switch (status) {
  SyncQueueStatus.pending => '待传',
  SyncQueueStatus.sent => '已推送待确认',
  SyncQueueStatus.failed => '失败（需人工）',
};

String _stamp(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} '
    '${_two(t.hour)}:${_two(t.minute)}';

String _two(int v) => v.toString().padLeft(2, '0');
