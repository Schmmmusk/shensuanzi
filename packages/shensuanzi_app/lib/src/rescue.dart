// 数据抢救 P1：**只读抢救导出**（2026-10-29，提案 52 §四·P1）。
//
// 与 P0（`recovery.dart`）的分工：
//
//   - **P0 找回数据**：从**好的备份**接回去。绝大多数事故到这里就结束了。
//   - **P1 抢救**：备份也没有 / 都坏了，只能从**坏库本身**尽可能多地读出数据。
//
// ## 三条铁律（2026-10-29 用户补充建议，改动前请先读）
//
// 1. **只操作副本**。原件一个字节都不碰：先 `copySync` 到临时目录，在副本上
//    「借头」「砍索引」，并把**原件设为只读**（防的不是程序，是手滑）。
// 2. **报告不许出现 SQL 术语**。不写「documents 表恢复 1234/1300 行」，
//    写「成功找回了 100 笔进货单，其中 2 笔的明细可能缺失」。
// 3. **不完整必须可逐条看**。缺明细的单据要列出来（单号 / 日期 / 金额 / 缺什么），
//    否则用户只能整批接受或整批放弃，两种都是赌博。
//
// ## 为什么必须分批读（2026-10-29 实测，见提案 52 §四·P1）
//
// `SELECT * FROM stock_ledger` 在坏页库上**整表失败**（`database disk image is
// malformed`）—— 一行都拿不到。而 `WHERE rowid BETWEEN a AND b` 分批读，
// 只有命中坏页的那几批失败，其余照常读出（实测 800/1000 行），
// 且**坏批次之后连接不会被污染**。
//
// ## 借头必须同时修页数（实测踩出来的）
//
// 把「同版本空库」的前 100 字节整块贴到坏库上，能打开、`quick_check` 也过，
// 但**一行都读不出** —— 因为头里的「数据库页数」（偏移 28..31）变成了空库的页数，
// SQLite 以为库只有那么大，后面的页直接不看。**必须把页数改成真实值**
// （文件大小 / 页大小），改完立刻 100% 读回。

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';

/// 一张单据「缺了什么」。
enum RescueIssueKind {
  /// 单据在，但一行明细都没读到（本该有明细的类型）
  missingLines,

  /// 单据和明细都在，但没有任何库存/资金/往来流水
  missingLedger,

  /// 明细读到了，但单据本身没读到（单据行落在坏页上）
  orphanLines,

  /// 单据引用的商品/往来方/账户没救回来（外键断了）
  missingMasterData,

  /// 核销关系的另一端缺失或不完整（`receipt` ↔ 被核销单）
  brokenSettlement,

  /// 这个版本的软件不认识这张单的类型（可能是更新版本做的单）
  unknownType,

  /// 类型认得，但**当前版本的规则层不支持恢复**（如 `transfer` 调拨）
  unsupportedType,
}

/// 一张不完整的单据。
///
/// 用户要能**逐条看**（用户补充建议第 3 条）—— 所以带上单号、日期、金额，
/// 而不是只给一个数字。
class RescueIssue {
  const RescueIssue({
    required this.docId,
    required this.docNo,
    required this.typeLabel,
    required this.kind,
    this.occurredAt,
    this.totalAmount,
    this.detail,
  });

  final String docId;
  final String docNo;

  /// 中文类型名（「进货单」「销售单」…），不出现英文 wire 值
  final String typeLabel;

  final RescueIssueKind kind;
  final DateTime? occurredAt;
  final int? totalAmount;

  /// 一句人话，说清缺的是什么、后果是什么
  final String? detail;

  /// 一句话摘要（列表里显示这一行）
  String get summary => switch (kind) {
    RescueIssueKind.missingLines => '明细可能缺失',
    RescueIssueKind.missingLedger => '流水可能缺失（库存或往来会不准）',
    RescueIssueKind.orphanLines => '单据本身没读到，只有明细',
    RescueIssueKind.missingMasterData => '引用的商品或往来方没救回来',
    RescueIssueKind.brokenSettlement => '收款或付款记录对不上（账会不平）',
    RescueIssueKind.unknownType => '这个版本不认识这种单据',
    RescueIssueKind.unsupportedType => '这个版本还不支持这种单据',
  };
}

/// 按单据类型统计（报告的「成功找回 100 笔进货单」那部分）。
class RescueTypeStat {
  const RescueTypeStat({
    required this.label,
    required this.total,
    required this.complete,
  });

  /// 「进货单」「销售单」…
  final String label;

  /// 读到多少张
  final int total;

  /// 其中完整（能直接导入）多少张
  final int complete;

  int get incomplete => total - complete;
}

/// 抢救进度（界面用来显示「正在读第几张表」）。
class RescueProgress {
  const RescueProgress(this.step, this.detail);

  /// 0..1
  final double step;
  final String detail;
}

/// 抢救报告。
class RescueReport {
  const RescueReport({
    this.outputPath,
    this.headerRepaired = false,
    this.readOnlyMarked = false,
    this.walCopied = false,
    this.totalDocuments = 0,
    this.importedDocuments = 0,
    this.typeStats = const <RescueTypeStat>[],
    this.issues = const <RescueIssue>[],
    this.unreadableTables = const <String>[],
    this.badBatches = 0,
    this.failure,
  });

  const RescueReport.failed(String this.failure)
    : outputPath = null,
      headerRepaired = false,
      readOnlyMarked = false,
      walCopied = false,
      totalDocuments = 0,
      importedDocuments = 0,
      typeStats = const <RescueTypeStat>[],
      issues = const <RescueIssue>[],
      unreadableTables = const <String>[],
      badBatches = 0;

  /// 抢救出来的新库（失败时 `null`）
  final String? outputPath;

  /// 是否用过「借头」
  final bool headerRepaired;

  /// 原件是否成功设为只读
  final bool readOnlyMarked;

  /// 是否把 `-wal` 一起复制过来了（意味着「最近还没落盘的事务」也在里面）
  final bool walCopied;

  /// 从坏库里读到多少张单据
  final int totalDocuments;

  /// 其中导入了多少张（完整的那部分）
  final int importedDocuments;

  final List<RescueTypeStat> typeStats;
  final List<RescueIssue> issues;

  /// 完全读不出来的表（中文名，不是表名）
  final List<String> unreadableTables;

  /// 有多少批数据因为坏页没读出来
  final int badBatches;

  final String? failure;

  bool get ok => outputPath != null;
}

/// 表的中文名 —— 报告里绝不出现 `stock_ledger` 这种词（用户补充建议第 2 条）。
const Map<String, String> _tableLabels = <String, String>{
  Schema.products: '商品',
  Schema.parties: '往来方',
  Schema.accounts: '账户',
  Schema.documents: '单据',
  Schema.documentLines: '单据明细',
  Schema.stockLedger: '库存流水',
  Schema.moneyLedger: '资金流水',
  Schema.partyLedger: '往来流水',
  Schema.settlements: '核销记录',
};

/// 主数据表（单据会引用它们，必须先写进新库）
const List<String> _masterTables = <String>[
  Schema.products,
  Schema.parties,
  Schema.accounts,
];

/// 业务表（按「单据」为单位组装）
const List<String> _businessTables = <String>[
  Schema.documents,
  Schema.documentLines,
  Schema.stockLedger,
  Schema.moneyLedger,
  Schema.partyLedger,
  Schema.settlements,
];

/// 抢救：从 [sourcePath]（坏库）尽可能多地读出数据，写进 [outputPath]（新库）。
///
/// [outputPath] 必须**不存在**（避免覆盖任何东西）。失败时新库会被删掉。
Future<RescueReport> rescueDatabase({
  required String sourcePath,
  required String outputPath,
  String? workDirectory,
  void Function(RescueProgress)? onProgress,
}) async {
  final File source = File(sourcePath);
  if (!source.existsSync()) {
    return const RescueReport.failed('原来的数据文件已经不在了，没法抢救');
  }
  if (File(outputPath).existsSync()) {
    return const RescueReport.failed('抢救结果的存放位置已经有一个同名文件，请换一个名字');
  }

  // ① 副本：**只动副本**（用户补充建议第 1 条）
  final Directory work = Directory(
    workDirectory ??
        p.join(
          Directory.systemTemp.path,
          'ssz-rescue-${DateTime.now().millisecondsSinceEpoch}',
        ),
  );
  work.createSync(recursive: true);
  final String copy = p.join(work.path, 'work.db');

  bool readOnlyMarked = false;
  bool walCopied = false;
  try {
    onProgress?.call(const RescueProgress(0.05, '正在复制一份出来（原件不会被动）'));

    // ⚠️ **`-wal` 必须一起复制**（2026-10-29 审查意见 ①，实测丢 17%）。
    //
    // 库工作在 WAL 模式：已提交的事务可以先只落在 `-wal` 里，等 checkpoint 才
    // 写回主文件。只拷主文件就会丢掉那些事务 —— 实测（120 单的库、其中 20 单只在
    // wal 里）：只拷主文件读出 100 单；连 wal 一起拷读出 120 单。
    //
    // 而且实测「主文件头坏 / 坏页」时，wal 里的页仍能被正常应用（wal 存的是完整页，
    // 会覆盖主文件的坏页）。`-shm` 不用复制：共享内存索引，SQLite 打开时重建。
    //
    // ⚠️ **但两次复制之间源文件可能变**（2026-10-30 裁定补充）：如果还有别的进程在写库，
    // 会拿到「主文件 + 另一个时刻的 wal」—— 那比只拷主文件更糟（会应用半截事务）。
    // 所以复制前后各取一次指纹，不一致就**明确失败**，不硬着头皮往下走。
    final _FileSnapshot dbBefore = _FileSnapshot.of(sourcePath);
    final _FileSnapshot walBefore = _FileSnapshot.of('$sourcePath-wal');

    source.copySync(copy);
    if (walBefore.exists) {
      File('$sourcePath-wal').copySync('$copy-wal');
      walCopied = true;
    }

    final _FileSnapshot dbAfter = _FileSnapshot.of(sourcePath);
    final _FileSnapshot walAfter = _FileSnapshot.of('$sourcePath-wal');
    if (dbBefore != dbAfter || walBefore != walAfter) {
      _cleanup(work);
      return const RescueReport.failed(
        '复制的时候，这个数据文件还在被别的程序改动 —— 现在拿到的不是一份完整的快照。'
        '请先把神算子关掉（也检查一下有没有网盘同步、杀毒软件正在扫这个文件夹），'
        '然后再试一次。你的原文件没有被改动过。',
      );
    }

    // 原件设只读：防的不是我们（我们只读副本），是**用户手滑**
    readOnlyMarked = _markReadOnly(sourcePath);
  } on FileSystemException catch (error) {
    _cleanup(work);
    return RescueReport.failed(
      '复制数据文件时出错（${error.osError?.message ?? error.message}），'
      '可能磁盘空间不够，或被别的程序占着',
    );
  }

  try {
    return _rescueFromCopy(
      copy: copy,
      outputPath: outputPath,
      readOnlyMarked: readOnlyMarked,
      walCopied: walCopied,
      onProgress: onProgress,
    );
  } finally {
    // 副本用完就删（里面是用户数据的拷贝，不该留在临时目录里）
    _cleanup(work);
  }
}

RescueReport _rescueFromCopy({
  required String copy,
  required String outputPath,
  required bool readOnlyMarked,
  required bool walCopied,
  void Function(RescueProgress)? onProgress,
}) {
  // ② 打开副本。
  //
  // ⚠️ 这里**不能用 `immutable=1`**（两个坑都踩过）：
  //   · 只读连接上 `DROP INDEX` 会全部失败（被 catch 吞掉）⇒ 索引还在 ⇒
  //     读表时走坏索引 ⇒ 一行都读不出；
  //   · `immutable` 还会**忽略 `-wal`**，而副本是 WAL 模式，`DROP INDEX` 的
  //     改动就落在 wal 里 —— 读数据的连接看不到它。
  // 副本是我们自己拷到临时目录的，可写打开随便改，用完整个目录删掉。
  bool repaired = false;
  // ⚠️ **先验头再打开**（不是「打开失败再修」）：
  // `sqlite3.open` 对头坏的库是懒打开（不报错），而一旦真去读，SQLite 会把
  // 它当成空库处理 —— 实测能把文件搞到只剩几百字节，那时再想修就没得修了。
  // 头 16 字节的魔数是最便宜的判断，先看它。
  if (!_hasValidHeader(copy)) {
    onProgress?.call(const RescueProgress(0.12, '文件头坏了，正在修一下'));
    final String? problem = _repairHeader(copy);
    if (problem != null) {
      return RescueReport.failed('这个文件已经修不好了：$problem');
    }
    repaired = true;
  }

  // 打开**之前**先判截断：头里记着「我有多大」，实际文件比它短 ⇒ 一定被截过。
  // 放在这里而不是等 SQLite 报错，是为了给一句中文（见上面那条注释）。
  final String? truncated = _truncationProblem(copy);
  if (truncated != null) return RescueReport.failed(truncated);

  Database? db;
  try {
    db = sqlite3.open(copy);
    // 头好了也可能结构坏 —— 真读一下才算「打开成功」
    db.select('SELECT name FROM sqlite_master LIMIT 1');
  } on SqliteException {
    db?.dispose();
    // ⚠️ **不把 `error.message` 拼进报告**：那是英文的 SQLite 术语
    // （`database disk image is malformed`），而报告的硬规矩是
    // 「不许出现 SQL 术语」（用户补充建议第 2 条）。用户看懂了也没用，
    // 他要的是「现在怎么办」。
    return RescueReport.failed(
      '这个数据文件损坏得比较严重，连它自己的目录都读不出来了。'
      '这种情况没法继续抢救 —— 如果备份里有更早的版本，从备份恢复更稳妥。',
    );
  }

  try {
    // ③ 砍索引 —— 坏索引会让「走索引的查询」直接失败（实测：坏一个索引，
    //    整表读不出；砍掉之后 100% 读回）
    onProgress?.call(const RescueProgress(0.18, '正在整理读取方式'));
    try {
      final ResultSet indexes = db.select(
        "SELECT name FROM sqlite_master WHERE type='index' AND sql IS NOT NULL",
      );
      final List<String> names = <String>[
        for (final Row row in indexes)
          if (row['name'] is String) row['name']! as String,
      ];
      for (final String name in names) {
        try {
          db.execute('DROP INDEX "$name"');
        } on SqliteException {
          // 索引页本身坏了 ⇒ 删不掉；读数据时它会再失败一次，如实报告
        }
      }
    } on SqliteException {
      // `sqlite_master` 都读不了 ⇒ 下面逐表读会失败并如实报告
    }

    // ④ 逐表分批读
    final Map<String, List<Map<String, Object?>>> rows =
        <String, List<Map<String, Object?>>>{};
    final List<String> unreadable = <String>[];
    int badBatches = 0;
    final List<String> all = <String>[..._masterTables, ..._businessTables];
    for (int i = 0; i < all.length; i++) {
      final String table = all[i];
      onProgress?.call(
        RescueProgress(
          0.2 + 0.5 * (i / all.length),
          '正在读${_tableLabels[table] ?? table}',
        ),
      );
      final _TableRead read = _readTable(db, table);
      rows[table] = read.rows;
      badBatches += read.badBatches.length;
      if (read.rows.isEmpty && read.badBatches.isNotEmpty) {
        unreadable.add(_tableLabels[table] ?? table);
      }
    }

    // ⑤ 组装 + 判断完整性
    // ⚠️ 根页坏了时 SQLite **不报错、直接返回空表** —— 实测：把 documents
    // 的根页清零，`SELECT` 得到 0 行、`badBatches` 也是 0。
    // 这时如果照常出报告，用户会看到「0 张单据」而以为文件里本来就没数据。
    // 判据：所有业务表都 0 行 + 文件本身不小 ⇒ 是读不出来，不是空的。
    final bool allEmpty = _businessTables.every(
      (String t) => (rows[t] ?? const <Map<String, Object?>>[]).isEmpty,
    );
    if (allEmpty && File(copy).lengthSync() > 100 * 1024) {
      return const RescueReport.failed(
        '这个文件里读不出任何数据 —— 存放单据的关键结构坏了。'
        '这种情况只能从备份里恢复（如果备份也没有，就没有别的办法了）。',
      );
    }

    onProgress?.call(const RescueProgress(0.75, '正在核对哪些单据是完整的'));
    final _Assembly asm = _assemble(rows);

    // ⑥ 写新库
    onProgress?.call(const RescueProgress(0.85, '正在把找回来的数据写进新文件'));
    final String? writeProblem = _writeNewDatabase(
      outputPath: outputPath,
      rows: rows,
      asm: asm,
    );
    if (writeProblem != null) {
      _deleteQuietly(outputPath);
      return RescueReport.failed('写新文件时出错：$writeProblem');
    }

    onProgress?.call(const RescueProgress(1, '完成'));
    return RescueReport(
      outputPath: outputPath,
      headerRepaired: repaired,
      readOnlyMarked: readOnlyMarked,
      walCopied: walCopied,
      totalDocuments: asm.documents.length,
      importedDocuments: asm.documents.length - asm.issues.length,
      typeStats: asm.typeStats,
      issues: asm.issues,
      unreadableTables: unreadable,
      badBatches: badBatches,
    );
  } finally {
    db.dispose();
  }
}

// ============================================================ 复制前的指纹

/// 一个文件「这一刻长什么样」—— 用来判断复制期间源文件有没有被改动。
///
/// 只看**大小 + 修改时间**：
/// - 大小：wal 每写一个事务就会长（除非被 checkpoint 截断）
/// - 修改时间：毫秒精度，正常写入一定会变
///
/// ⚠️ 不读 wal 的 salt：那要解析 32 字节 header，而 salt 只在 checkpoint 时变，
/// 对「复制期间是否有人写」这个判断没有额外价值。
class _FileSnapshot {
  const _FileSnapshot({
    required this.exists,
    required this.size,
    required this.modifiedMs,
  });

  factory _FileSnapshot.of(String path) {
    final File file = File(path);
    if (!file.existsSync()) {
      return const _FileSnapshot(exists: false, size: 0, modifiedMs: 0);
    }
    final FileStat stat = file.statSync();
    return _FileSnapshot(
      exists: true,
      size: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  }

  final bool exists;
  final int size;
  final int modifiedMs;

  @override
  bool operator ==(Object other) =>
      other is _FileSnapshot &&
      other.exists == exists &&
      other.size == size &&
      other.modifiedMs == modifiedMs;

  @override
  int get hashCode => Object.hash(exists, size, modifiedMs);
}

// ============================================================ 借头

/// 文件是不是**被截断过**（头里写的页数 × 页大小 > 实际大小）。
///
/// 为什么单独判：截断的库 `sqlite3.open` 能成功，但一读就抛
/// `database disk image is malformed` —— 那句英文会直接进报告。
/// 提前判出来就能给一句人话，也省得后面一堆分支各自处理。
///
/// 只判「比头里记的小」这一个方向：文件**大于**声明值是允许的
/// （WAL 未 checkpoint 时主文件里可能有预留页）。
String? _truncationProblem(String path) {
  final RandomAccessFile raf;
  try {
    raf = File(path).openSync();
  } on FileSystemException {
    return null; // 读不了交给后面的分支报
  }
  try {
    final int size = raf.lengthSync();
    if (size < 512) {
      return '这个文件太小了，不像是一份完整的数据 —— 可能只复制了一半。';
    }
    final List<int> head = raf.readSync(100);
    final int rawPageSize = (head[16] << 8) | head[17];
    final int pageSize = rawPageSize == 1 ? 65536 : rawPageSize;
    if (pageSize < 512) return null; // 头本身不靠谱，交给借头分支
    final int pages =
        (head[28] << 24) | (head[29] << 16) | (head[30] << 8) | head[31];
    if (pages <= 0) return null; // 没写页数，判不了
    if (size < pages * pageSize || size % pageSize != 0) {
      return '这个文件比它自己记录的要小 —— 像是被截断过'
          '（复制到一半断了，或者硬盘出了问题）。'
          '这种情况没法继续抢救；备份里有更早的版本的话，从备份恢复更稳妥。';
    }
    return null;
  } on FileSystemException {
    return null;
  } finally {
    raf.closeSync();
  }
}

/// 文件头是不是一个合法的 SQLite 库（前 16 字节的魔数）。
bool _hasValidHeader(String path) {
  final RandomAccessFile raf;
  try {
    raf = File(path).openSync();
  } on FileSystemException {
    return false;
  }
  try {
    if (raf.lengthSync() < 100) return false;
    final List<int> head = raf.readSync(16);
    const List<int> magic = <int>[
      0x53,
      0x51,
      0x4C,
      0x69,
      0x74,
      0x65,
      0x20,
      0x66,
      0x6F,
      0x72,
      0x6D,
      0x61,
      0x74,
      0x20,
      0x33,
      0x00,
    ];
    for (int i = 0; i < 16; i++) {
      if (head[i] != magic[i]) return false;
    }
    return true;
  } on FileSystemException {
    return false;
  } finally {
    raf.closeSync();
  }
}

/// 修文件头。返回 `null` 表示修好了，否则是「修不好」的原因（人话）。
///
/// 做法：用**同一个 Schema** 建一个空库当 donor，取它的前 100 字节，
/// 但把「数据库页数」（偏移 28..31）改成**真实值**（文件大小 / 页大小）。
/// 不修页数 ⇒ 能打开、`quick_check` 也过，但**一行都读不出**（实测）。
String? _repairHeader(String path) {
  // ⚠️ Dart 的 `RandomAccessFile` **没有「随机写且不截断」的模式**（实测）：
  // `FileMode.write` / `writeOnly` 都会把文件截断（1000 字节变 3 字节），
  // 而 `append` 是 O_APPEND、`setPositionSync` 被忽略（写入永远在末尾）。
  // 所以只能「读全部 → 改 → 整体写回」。
  //
  // 内存代价：一次 `Uint8List` = 库的大小（478 MB 的库就占 478 MB）。
  // 这是**只读抢救**里唯一一处需要整份进内存的地方，可以接受 ——
  // 它只在「文件头坏了」这条罕见路径上跑，而且跑完立刻释放。
  final Uint8List bytes;
  try {
    bytes = File(path).readAsBytesSync();
  } on FileSystemException catch (error) {
    return '读不到这个文件（${error.osError?.message ?? error.message}）';
  }
  if (bytes.length < 512) return '文件太小了，不像是一个完整的数据文件';

  // donor：用当前 Schema 建一个空库，借它的头（魔数 / 页大小 / 编码 / 格式版本…）
  final Directory donorDir = Directory(
    p.join(
      Directory.systemTemp.path,
      'ssz-donor-${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  final String donorPath = p.join(donorDir.path, 'donor.db');
  try {
    donorDir.createSync(recursive: true);
    final Db donor = Db.open(donorPath);
    donor.close();
    final Uint8List donorBytes = File(donorPath).readAsBytesSync();
    if (donorBytes.length < 100) return '建不出参照用的空文件';
    final Uint8List head = Uint8List.fromList(donorBytes.sublist(0, 100));

    // ⚠️ SQLite 的头里「页大小 = 1」表示 **65536**（2 字节放不下 65536）。
    final int rawPageSize = (head[16] << 8) | head[17];
    final int pageSize = rawPageSize == 1 ? 65536 : rawPageSize;
    if (pageSize < 512 || bytes.length % pageSize != 0) {
      return '文件大小和页大小对不上（这个文件可能被截断过）';
    }
    final int pages = bytes.length ~/ pageSize;

    // **关键一步**：把「数据库页数」改成真实值。
    // 只贴头不改这一项 ⇒ 能打开、`quick_check` 也过，但**一行都读不出** ——
    // 因为 SQLite 以为库只有 donor 那么大，后面的页直接不看（实测）。
    head[28] = (pages >> 24) & 0xFF;
    head[29] = (pages >> 16) & 0xFF;
    head[30] = (pages >> 8) & 0xFF;
    head[31] = pages & 0xFF;

    bytes.setRange(0, 100, head);
    File(path).writeAsBytesSync(bytes);
    return null;
  } on FileSystemException catch (error) {
    return '改文件头时出错（${error.osError?.message ?? error.message}）';
  } finally {
    _deleteQuietly(donorPath);
    try {
      donorDir.deleteSync(recursive: true);
    } on FileSystemException {
      // 临时目录，删不掉不影响结论
    }
  }
}

// ============================================================ 分批读

class _TableRead {
  const _TableRead(this.rows, this.badBatches);

  final List<Map<String, Object?>> rows;

  /// 读失败的 rowid 区间（报告里用来判断「丢了多少」）
  final List<(int, int)> badBatches;
}

/// 逐 rowid 分批读一张表。**遇到坏页就二分**，把损失精确到「坏页上的那几行」。
///
/// ## 为什么必须二分（2026-10-29 实测）
///
/// 一批 500 行跨十几页，其中**一页**坏了 ⇒ 整批失败、500 行全丢。
/// 实测：84 页的库坏 5 页，`batch=500` 时**一张单据都读不出**（全被坏页传染）。
/// 二分之后只有真正落在坏页上的那几行丢失，其余照常救回。
///
/// 递归深度 = log2(batch) ≈ 8，代价可忽略；正常情况（没坏页）一次就成功。
_TableRead _readTable(Database db, String table, {int batch = 200}) {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  final List<(int, int)> bad = <(int, int)>[];

  int? hi;
  try {
    hi = db.select('SELECT MAX(rowid) FROM $table').first.values.first as int?;
  } on SqliteException {
    hi = null;
  }

  if (hi == null || hi == 0) {
    // 连 `MAX(rowid)` 都读不出（坏页正好在索引上 / 表是空的）⇒
    // 一直往上扫，**连续 10 批都读不到东西**就停（避免坏页导致无限扫）
    int lo = 1;
    int empty = 0;
    while (empty < 10 && lo <= 50_000_000) {
      final int before = rows.length;
      _readRange(db, table, lo, lo + batch - 1, rows, bad);
      empty = rows.length > before ? 0 : empty + 1;
      lo += batch;
    }
    return _TableRead(rows, bad);
  }

  int lo = 1;
  while (lo <= hi) {
    _readRange(db, table, lo, lo + batch - 1, rows, bad);
    lo += batch;
  }
  return _TableRead(rows, bad);
}

/// 读 `[lo, hi]` 这一段；失败就二分重试，直到单行。
void _readRange(
  Database db,
  String table,
  int lo,
  int hi,
  List<Map<String, Object?>> rows,
  List<(int, int)> bad,
) {
  if (lo > hi) return;
  try {
    final ResultSet result = db.select(
      'SELECT * FROM $table WHERE rowid BETWEEN ? AND ?',
      <Object?>[lo, hi],
    );
    for (final Row row in result) {
      rows.add(_rowToMap(row));
    }
  } on SqliteException {
    if (lo >= hi) {
      // 单行都读不出 ⇒ 这一行确实在坏页上
      bad.add((lo, hi));
      return;
    }
    final int mid = lo + (hi - lo) ~/ 2;
    _readRange(db, table, lo, mid, rows, bad);
    _readRange(db, table, mid + 1, hi, rows, bad);
  }
}

/// `Row` 本身就是 `Map<String, dynamic>` —— 直接转成不带泛型擦除的副本。
Map<String, Object?> _rowToMap(Row row) => Map<String, Object?>.from(row);

// ============================================================ 组装

class _Assembly {
  _Assembly();

  /// 读到的单据（按 id）
  final List<Map<String, Object?>> documents = <Map<String, Object?>>[];

  /// 完整、可以导入的单据 id
  final Set<String> importable = <String>{};

  final List<RescueIssue> issues = <RescueIssue>[];
  final List<RescueTypeStat> typeStats = <RescueTypeStat>[];
}

/// 把逐表读到的行按「单据」组装起来，判断每张是否完整。
///
/// ## 为什么按单据而不是按表
///
/// 神算子的账是四张流水表的求和（`Agents.md` §二·4）。单据在、流水缺一行，
/// 就等于**制造一笔对不上的账** —— 比不救更糟，因为用户会拿它当真。
/// 所以「完整」的单位是**一张单据的全部构成**，不是「一张表的行」。
_Assembly _assemble(Map<String, List<Map<String, Object?>>> rows) {
  final _Assembly asm = _Assembly();

  final List<Map<String, Object?>> docs = rows[Schema.documents] ?? const [];
  final Map<String, List<Map<String, Object?>>> lines = _groupBy(
    rows[Schema.documentLines] ?? const [],
    'document_id',
  );
  final Map<String, List<Map<String, Object?>>> stock = _groupBy(
    rows[Schema.stockLedger] ?? const [],
    'document_id',
  );
  final Map<String, List<Map<String, Object?>>> money = _groupBy(
    rows[Schema.moneyLedger] ?? const [],
    'document_id',
  );
  final Map<String, List<Map<String, Object?>>> party = _groupBy(
    rows[Schema.partyLedger] ?? const [],
    'document_id',
  );
  final Map<String, List<Map<String, Object?>>> settle = _groupBy(
    rows[Schema.settlements] ?? const [],
    'receipt_doc_id',
  );

  // 主数据 id 集合（判断外键能不能满足）
  final Set<String> productIds = _ids(rows[Schema.products] ?? const []);
  final Set<String> partyIds = _ids(rows[Schema.parties] ?? const []);
  final Set<String> accountIds = _ids(rows[Schema.accounts] ?? const []);

  final Map<String, int> totalByType = <String, int>{};
  final Map<String, int> completeByType = <String, int>{};

  // 核销是**双端**关系 —— 判「另一端在不在」得先收齐所有单据 id。
  final Set<String> knownDocIds = <String>{
    for (final Map<String, Object?> doc in docs)
      if (doc['id'] is String) doc['id']! as String,
  };
  // 目标一端也要能反查（`settlements` 默认按 receipt 分组，这里再按 target 分一份）
  final Map<String, List<Map<String, Object?>>> settleByTarget = _groupBy(
    rows[Schema.settlements] ?? const [],
    'target_doc_id',
  );

  // id → 结论。**不在这里 = 完整**。核销传播要在第一遍之后才能定，
  // 所以先攒结论、最后再统一落 `importable`。
  final Map<String, RescueIssue> verdicts = <String, RescueIssue>{};

  for (final Map<String, Object?> doc in docs) {
    final String id = doc['id'] as String;
    final String wire = doc['doc_type'] as String? ?? '';
    final DocType? type = DocType.fromWireOrNull(wire);
    final String label = type?.label ?? '未知类型';

    totalByType[label] = (totalByType[label] ?? 0) + 1;

    final List<Map<String, Object?>> myLines = lines[id] ?? const [];
    final List<Map<String, Object?>> myStock = stock[id] ?? const [];
    final List<Map<String, Object?>> myMoney = money[id] ?? const [];
    final List<Map<String, Object?>> myParty = party[id] ?? const [];
    final List<Map<String, Object?>> mySettle = settle[id] ?? const [];
    final int settledCents = _sumCents(settleByTarget[id] ?? const []);

    // 该有明细吗？收付款单没有明细（它们只有资金流水）
    final bool expectsLines =
        type != null && type != DocType.receipt && type != DocType.payment;
    final int totalCents = doc['total_amount'] is int
        ? doc['total_amount']! as int
        : 0;
    final int paidCents = doc['paid_amount'] is int
        ? doc['paid_amount']! as int
        : 0;

    RescueIssueKind? issue;
    String? detail;

    // 判据顺序：**越具体越靠前**。
    // 「引用的商品 ghost 没救回来」比「库存记录条数对不上」更可操作 ——
    // 前者告诉用户缺什么，后者只告诉他数字不匹配。所以外键检查排在流水检查之前。
    final String? missingRef = _firstMissingRef(
      doc: doc,
      lines: myLines,
      productIds: productIds,
      partyIds: partyIds,
      accountIds: accountIds,
    );

    if (type == null) {
      // 用户审查 2026-10-30（P1）：**不认识的类型一律进待确认**。
      //
      // 从前 `type == null` ⇒ `expectsLines == false` ⇒ 明细 / 库存 / 核销
      // 三项检查全部跳过，而收付款单那几条又都带 `type != null` 条件 ——
      // 于是一张空壳单据（没有明细、没有往来、金额为零）可能一路绿灯被导入。
      //
      // 抢救器不知道新类型的业务语义，就不该擅自替用户判断它「完整」。
      issue = RescueIssueKind.unknownType;
      detail =
          '这张单的类型（$wire）这个版本的软件不认识 —— 可能是更新版本做的单。'
          '为了不把账弄错，先不导入；用新版本的软件打开，它就能正常恢复。';
    } else if (!isSupportedDocType(type)) {
      // 类型**认得**、但规则层没实现（v1 的 `transfer` 调拨）。
      //
      // 从前这种单会一路走完所有判据：三种流水方向都是 `absent`、没有明细、
      // 金额为零 ⇒ 全部「通过」，被当成完整单据导进新库。用户得到的是一张
      // **本版本根本没法继续操作**的单（用户审查 2026-10-30）。
      issue = RescueIssueKind.unsupportedType;
      detail =
          '这张单是「${type.label}」—— 当前版本的软件还不支持这种单据。'
          '为了不让账里出现看不懂的东西，先不导入；等支持它的版本再恢复。';
    } else if (expectsLines && myLines.isEmpty) {
      issue = RescueIssueKind.missingLines;
      detail =
          '这张单的明细一行都没读到。导入它会让单据金额对不上明细，'
          '库存和往来也可能少算。';
    } else if (missingRef != null) {
      issue = RescueIssueKind.missingMasterData;
      detail = '这张单引用的「$missingRef」没有救回来。补上它之前，这张单不能导入。';
    } else if (linesAmountAppliesTo(type) &&
        _linesAmountMismatch(myLines, totalCents)) {
      // **明细金额合计 = 单据总额**（用户审查 2026-10-30 的 P0）。
      //
      // 这条不变量规则层本来就在守（`_requireLinesTotalMatches` /
      // `linesAmountMatchesTotal`），抢救器必须复核同一个东西。
      //
      // 为什么行数 + 数量不够：两行各 ¥10 的销售单，第一行明细**和**它的
      // 库存流水一起没救出来时，剩下的「1 行明细 + 1 条流水 + 数量 1」
      // 局部完全自洽，往来 ¥20 = 单据 ¥20、核销也对得上 —— 四项全过，
      // 可单据 ¥20 只剩 ¥10 的明细。**只有这条不变量抓得住。**
      issue = RescueIssueKind.missingLines;
      detail =
          '这张单的明细加起来是 ${_yuan(_sumCents(myLines))}，'
          '但单据金额是 ${_yuan(totalCents)} —— 少了一行（或几行）明细。'
          '导入它等于把金额改小了。';
    } else if (expectsLines) {
      final String? stockProblem = _stockProblem(
        lines: myLines,
        stock: myStock,
        type: type,
      );
      if (stockProblem != null) {
        issue = RescueIssueKind.missingLedger;
        detail = stockProblem;
      }
    }

    // **不该有的流水**：符号表说「这类单据不产生」⇒ 一行都不许有
    if (issue == null) {
      final String? unexpected = _unexpectedLedgerProblem(
        // 类型为空已在上一个分支返回，这里必然非空
        type: type!,
        stock: myStock,
        party: myParty,
        money: myMoney,
        partyId: doc['party_id'],
      );
      if (unexpected != null) {
        issue = RescueIssueKind.missingLedger;
        detail = unexpected;
      }
    }

    // 流水**自己**的引用（往来方 / 账户）—— 用户审查 2026-10-30（P1）
    if (issue == null) {
      final String? ledgerRef = _ledgerRefProblem(
        party: myParty,
        money: myMoney,
        docPartyId: doc['party_id'],
        docAccountId: doc['account_id'],
        partyIds: partyIds,
        accountIds: accountIds,
        isSettleDoc: !expectsLines && type != null,
      );
      if (ledgerRef != null) {
        issue = RescueIssueKind.missingLedger;
        detail = ledgerRef;
      }
    }

    // 往来流水：**有往来方就必须有**（不能拿「流水为空」当「不适用」）
    if (issue == null) {
      final String? partyProblem = _partyProblem(
        party: myParty,
        partyId: doc['party_id'],
        totalCents: totalCents,
        // 类型为空的情形已在上一个分支返回，这里必然非空
        type: type!,
      );
      if (partyProblem != null) {
        issue = RescueIssueKind.missingLedger;
        detail = partyProblem;
      }
    }

    // 资金流水：**按单据类型分开判**
    if (issue == null) {
      final String? moneyProblem = _moneyProblem(
        type: type,
        money: myMoney,
        totalCents: totalCents,
        paidCents: paidCents,
        settledCents: settledCents,
      );
      if (moneyProblem != null) {
        issue = RescueIssueKind.missingLedger;
        detail = moneyProblem;
      }
    }

    // 收付款单：核销合计必须等于本单金额
    if (issue == null && !expectsLines && type != null) {
      final String? settleProblem = _settlementProblem(
        settle: mySettle,
        totalCents: totalCents,
      );
      if (settleProblem != null) {
        issue = RescueIssueKind.missingLedger;
        detail = settleProblem;
      }
    }

    if (issue != null) {
      final Map<String, Object?> meta = _meta(doc, label);
      verdicts[id] = RescueIssue(
        docId: id,
        docNo: doc['doc_no'] as String? ?? '（单号读不出来）',
        typeLabel: label,
        kind: issue,
        occurredAt: meta['occurredAt'] as DateTime?,
        totalAmount: meta['totalAmount'] as int?,
        detail: detail,
      );
    }
  }

  // ---- 核销双端：一端缺失/不完整 ⇒ 另一端也不完整 ----
  //
  // 用户审查 2026-10-30（P0）：从前写新库时只是**把这条核销关系过滤掉**，
  // 两端的单据照旧导入 —— 于是「收付款单还在、它核销的那张单没了」或者
  // 「单还在、收的钱没了」，两种都是**能打开但账不对**的账本。
  _propagateSettlements(
    verdicts: verdicts,
    settlements: rows[Schema.settlements] ?? const [],
    knownDocIds: knownDocIds,
    docs: docs,
  );

  // ---- 汇总 ----
  for (final Map<String, Object?> doc in docs) {
    final String id = doc['id'] as String;
    final String label =
        DocType.fromWireOrNull(doc['doc_type'] as String? ?? '')?.label ??
        '未知类型';
    final RescueIssue? verdict = verdicts[id];
    if (verdict != null) {
      asm.issues.add(verdict);
    } else {
      asm.importable.add(id);
      completeByType[label] = (completeByType[label] ?? 0) + 1;
    }
  }

  // 明细读到了、单据没读到 —— 这类单据在列表里根本不会出现，但账会错，
  // 所以必须单独报出来（否则用户以为「就这些单」）。
  final Set<String> orphan = <String>{
    ...lines.keys,
    ...stock.keys,
    ...money.keys,
    ...party.keys,
  }.difference(knownDocIds);
  for (final String id in orphan) {
    final List<Map<String, Object?>> sample = lines[id] ?? const [];
    asm.issues.add(
      RescueIssue(
        docId: id,
        docNo: sample.isNotEmpty ? '（单据本身没读到）' : '（单据本身没读到）',
        typeLabel: '未知类型',
        kind: RescueIssueKind.orphanLines,
        detail:
            '这张单的明细或流水还在，但单据本身的那一行没读到。'
            '它在单据列表里不会出现，可库存和往来里已经有它了。',
      ),
    );
  }

  asm.documents.addAll(docs);
  asm.typeStats.addAll(
    totalByType.entries
        .map(
          (MapEntry<String, int> e) => RescueTypeStat(
            label: e.key,
            total: e.value,
            complete: completeByType[e.key] ?? 0,
          ),
        )
        .toList()
      ..sort(
        (RescueTypeStat a, RescueTypeStat b) => b.total.compareTo(a.total),
      ),
  );
  return asm;
}

Map<String, Object?> _meta(Map<String, Object?> doc, String label) {
  final Object? at = doc['occurred_at'];
  return <String, Object?>{
    'occurredAt': at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null,
    'totalAmount': doc['total_amount'] is int ? doc['total_amount'] : null,
  };
}

Map<String, List<Map<String, Object?>>> _groupBy(
  List<Map<String, Object?>> rows,
  String key,
) {
  final Map<String, List<Map<String, Object?>>> out =
      <String, List<Map<String, Object?>>>{};
  for (final Map<String, Object?> row in rows) {
    final Object? value = row[key];
    if (value is! String) continue;
    (out[value] ??= <Map<String, Object?>>[]).add(row);
  }
  return out;
}

Set<String> _ids(List<Map<String, Object?>> rows) => <String>{
  for (final Map<String, Object?> row in rows)
    if (row['id'] is String) row['id']! as String,
};

/// 库存流水核对 —— 按商品比 **行数** 与 **数量绝对值合计**。
///
/// 返回一句人话（`null` = 没问题）。
///
/// ## 为什么行数不够（用户审查 2026-10-30，P1）
///
/// 只比行数时，「1 行明细 10 瓶 / 1 条流水 -8 瓶」也通过 —— 数量对不上，
/// 库存照样错。所以要再比一次**数量绝对值合计**（符号按业务类型相反，
/// 比绝对值就不必关心方向）。
///
/// ## 盘点单是例外，但**不是整类跳过**
///
/// 盘点的零差额**本来就不写流水**，所以不能要求「每行明细都有流水」。
/// 但「流水里有、明细里没有的商品」仍然是错的 —— 那说明这条流水
/// 找不到对应的盘点行，导入它库存会凭空变。
String? _stockProblem({
  required List<Map<String, Object?>> lines,
  required List<Map<String, Object?>> stock,
  required DocType type,
}) {
  // 商品引用必须是有效值（`document_lines.product_id` 与
  // `stock_ledger.product_id` 都是 NOT NULL）。从前这里 `if (pid is! String)
  // continue` 会把坏行悄悄跳过 —— 连盘点分支也一样（用户审查 2026-10-30）。
  for (final Map<String, Object?> line in lines) {
    final Object? pid = line['product_id'];
    if (pid is! String || pid.isEmpty) {
      return '有一行明细没有商品（数据可能坏了）—— 导入它，金额和库存都会对不上。';
    }
  }
  for (final Map<String, Object?> row in stock) {
    final Object? pid = row['product_id'];
    if (pid is! String || pid.isEmpty) {
      return '有一条库存记录没有商品（数据可能坏了）—— 导入它，库存会错。';
    }
  }

  final Map<String, int> lineRows = <String, int>{};
  final Map<String, int> lineQty = <String, int>{};
  for (final Map<String, Object?> line in lines) {
    final Object? pid = line['product_id'];
    if (pid is! String) continue;
    lineRows[pid] = (lineRows[pid] ?? 0) + 1;
    final Object? qty = line['quantity'];
    if (qty is int) lineQty[pid] = (lineQty[pid] ?? 0) + qty;
  }
  final Map<String, int> stockRows = <String, int>{};
  final Map<String, int> stockQty = <String, int>{};
  for (final Map<String, Object?> row in stock) {
    final Object? pid = row['product_id'];
    if (pid is! String) continue;
    stockRows[pid] = (stockRows[pid] ?? 0) + 1;
    final Object? qty = row['quantity'];
    // ⚠️ **有符号**累加：库存流水的符号就是「进还是出」，
    // 取绝对值会把「卖了 10 瓶」和「进了 10 瓶」当成同一件事。
    if (qty is int) stockQty[pid] = (stockQty[pid] ?? 0) + qty;
  }

  // ① 流水里有、明细里没有的商品 —— 任何类型都算错
  for (final String pid in stockRows.keys) {
    if (!lineRows.containsKey(pid)) {
      return '「$pid」有库存记录，但明细里没有这个商品 —— 导入它库存会凭空变。';
    }
  }

  // ② 盘点：**能查的比「该有的」更多，但不能少**
  //
  // 盘点的明细存的是「实际数量」，差额只在流水里（`diff = 实际 − 账面`），
  // 而差额为 0 时**根本不写流水**（`rule_engine._stocktake`）。
  // 所以「某条本该存在的盘点流水丢了」这件事，单凭单据**判断不出来** ——
  // 要判它得知道当时的账面数，而账面数只能从（可能已经损坏的）流水反推，
  // 那等于用被怀疑的数据去验证它自己。这里如实不做，不假装查过。
  //
  // 能查且值得查的是**多出来的**：一条明细最多产生一条流水，
  // 所以「流水条数 > 明细条数」一定是坏的（重复写入 / 串了单据）。
  if (type == DocType.stocktake) {
    for (final MapEntry<String, int> entry in stockRows.entries) {
      final int lines = lineRows[entry.key] ?? 0;
      if (entry.value > lines) {
        return '「${entry.key}」的库存记录比盘点明细还多（明细 $lines 条，'
            '库存记录 ${entry.value} 条）—— 有一条对不上任何盘点行。';
      }
    }
    return null;
  }

  for (final MapEntry<String, int> entry in lineRows.entries) {
    final String pid = entry.key;
    if ((stockRows[pid] ?? 0) != entry.value) {
      return '「$pid」的库存记录条数对不上明细（明细 ${entry.value} 条，'
          '库存记录 ${stockRows[pid] ?? 0} 条）—— 可能少读了几条。';
    }
    // **方向也要对**（用户审查 2026-10-30，P0）：销售/送货/采购退货是出库（−），
    // 采购/销售退货是入库（+）。方向由 `stockDirectionOf()` 统一给出 —— 与规则层
    // 同一套约定（`ledger_signs_test` 用真引擎对拍）。
    final int sign = stockDirectionOf(type).sign ?? 0;
    // `0` = 这类单据不该有库存流水：由 `_unexpectedLedgerProblem` 判「一条都不许有」，
    // 这里不重复（也走不到：盘点已在上面返回，收付款单没有明细）。
    if (sign == 0) return null;
    final int want = sign * (lineQty[pid] ?? 0);
    final int got = stockQty[pid] ?? 0;
    if (want != got) {
      if (want.abs() == got.abs()) {
        return '「$pid」的库存记录**方向反了**（这张单应该是'
            '${want > 0 ? '入库' : '出库'} ${want.abs()} 瓶，'
            '库存记录却是 ${got > 0 ? '入库' : '出库'} ${got.abs()} 瓶）—— '
            '导入它，库存会朝反方向变。';
      }
      return '「$pid」的库存数量对不上明细（明细 $want，库存记录 $got）—— '
          '可能有一条流水只读到了一半。';
    }
  }
  return null;
}

/// 往来流水：**有往来方就必须有**，且金额等于单据金额。
///
/// ## 为什么不能拿「流水为空」推断「不适用」（用户审查 2026-10-30，P0）
///
/// 从前 `party.isEmpty` 直接 `return null`，注释说「一条都没有由前面的分支处理」
/// —— 但前面根本没有那个分支。于是一张赊账销售单**整张往来流水丢失**时：
/// 库存行数过、往来检查跳过、资金检查也过 ⇒ 被判完整导入。
/// 结果就是「货恢复了、单据恢复了、客户欠款不见了」。
///
/// 「散客 / 散采」（没有往来方）才是真正的不适用 —— 那种情况 `party_id` 为空。
String? _partyProblem({
  required List<Map<String, Object?>> party,
  required Object? partyId,
  required int totalCents,
  required DocType type,
}) {
  // 没有往来方 = 散客当场结清，本来就不写往来流水
  if (partyId is! String || partyId.isEmpty) return null;
  if (party.isEmpty) {
    return '这张单有往来方，但一行欠款记录都没读到 —— '
        '导入它，这位客户/供应商的欠款就凭空消失了。';
  }
  // 符号也要对（用户审查 2026-10-30，P0）：
  // 销售/送货/采购退货/付款是**增加**（+），采购/销售退货/收款是**减少**（−）。
  // 取绝对值会把「客户欠我 100」和「我欠客户 100」当成同一件事 ——
  // 这不是小误差，是账务方向整个反过来。
  final int sign = partyDirectionOf(type).sign ?? 0;
  // `0` = 这类单据不该有往来流水（如盘点）：由 `_unexpectedLedgerProblem` 判
  if (sign == 0) return null;
  final int sum = _sumCents(party);
  final int want = sign * totalCents;
  if (sum != want) {
    if (sum.abs() == want.abs()) {
      return '这张单的欠款记录**方向反了**（应该是'
          '${want > 0 ? '对方欠我方' : '我方欠对方'} ${_yuan(want.abs())}，'
          '记录里却是 ${sum > 0 ? '对方欠我方' : '我方欠对方'} ${_yuan(sum.abs())}）'
          '—— 导入它，欠款会记反。';
    }
    return '这张单的欠款记录金额（${_yuan(sum)}）'
        '与单据金额（${_yuan(totalCents)}）对不上 —— 欠款会算错。';
  }
  return null;
}

/// 资金流水：**按单据类型分开判**（用户审查 2026-10-30，P0）。
///
/// ## 两种单据的「钱」根本不在同一个地方
///
/// | 单据 | `money_ledger` 挂谁 | 真正的金额在哪 |
/// |---|---|---|
/// | `sale/purchase/delivery/退货` | **不写**（只在自动生成的收付款单上） | `settlements` 核销合计 = `paid_amount` |
/// | `receipt/payment` | 挂自己，`±total_amount` | 本单 `total_amount`（它的 `paid_amount` **恒为 0**） |
///
/// 从前一律拿 `money_ledger` 去比 `paid_amount`：正常的 ¥100 收款单是
/// 「资金流水 100、`paid_amount` 0」⇒ **被判成不完整**；而主单因为
/// `money_ledger` 本来就是空的，这项检查**从来没生效过**。
String? _moneyProblem({
  required DocType? type,
  required List<Map<String, Object?>> money,
  required int totalCents,
  required int paidCents,
  required int settledCents,
}) {
  final bool isSettleDoc = type == DocType.receipt || type == DocType.payment;
  final String name = type == DocType.payment ? '付款单' : '收款单';

  if (isSettleDoc) {
    if (money.isEmpty) {
      return '这张$name没有任何资金记录 —— 导入它，这笔钱就凭空消失了。';
    }
    // 符号也要对（用户审查 2026-10-30，P0）：收款（`receipt`）+，付款（`payment`）−。
    // 取绝对值会把「收进 100」和「付出 100」当成同一件事，恢复出来余额反着走。
    final int sum = _sumCents(money);
    final int want = (moneyDirectionOf(type!).sign ?? 0) * totalCents;
    if (sum != want) {
      if (sum.abs() == want.abs()) {
        return '这张$name的资金记录**方向反了**（应该是'
            '${want > 0 ? '收到' : '付出'} ${_yuan(want.abs())}，'
            '记录里却是 ${sum > 0 ? '收到' : '付出'} ${_yuan(sum.abs())}）'
            '—— 导入它，账户余额会反着算。';
      }
      return '这张$name的资金记录金额与单据金额对不上 —— 账会不平。';
    }
    return null;
  }

  // 主单：真实收付款在 `settlements`，不在自己的 `money_ledger` 上
  if (settledCents != paidCents) {
    return '这张单记着已收/已付 ${_yuan(paidCents)}，'
        '但实际核销记录只有 ${_yuan(settledCents)} —— '
        '钱和单对不上，导入它账会不平。';
  }
  return null;
}

/// 收付款单：核销出去的合计必须等于本单金额。
String? _settlementProblem({
  required List<Map<String, Object?>> settle,
  required int totalCents,
}) {
  if (settle.isEmpty) {
    if (totalCents != 0) {
      return '这张收付款单没有任何核销记录 —— 导入它，这笔钱挂不到任何单据上。';
    }
    return null;
  }
  final int sum = _sumCents(settle);
  if (sum != totalCents) {
    return '这张收付款单核销出去的钱与单据金额对不上 —— 账会不平。';
  }
  return null;
}

/// 核销**双端**传播：一端缺失或不完整 ⇒ 另一端也不完整，迭代到不动点。
///
/// ## 为什么不能只把关系过滤掉（用户审查 2026-10-30，P0）
///
/// `_writeNewDatabase` 从前遇到「一端不在可导入集合里」就 `continue`，
/// 把那条核销扔掉、两端的单据照旧导入。用户拿到的是一份**结构上能打开、
/// 但某笔收付款与它原本核销的单据失去了联系**的账本。
///
/// 传播是必要的：A 不完整 ⇒ B 不完整 ⇒ B 的另一笔核销又让 C 不完整。
/// 轮数上限 20 只是保险（正常两三轮就收敛），不是业务规则。
void _propagateSettlements({
  required Map<String, RescueIssue> verdicts,
  required List<Map<String, Object?>> settlements,
  required Set<String> knownDocIds,
  required List<Map<String, Object?>> docs,
}) {
  if (settlements.isEmpty) return;
  final Map<String, Map<String, Object?>> byId = <String, Map<String, Object?>>{
    for (final Map<String, Object?> doc in docs)
      if (doc['id'] is String) doc['id']! as String: doc,
  };

  for (int round = 0; round < 20; round++) {
    bool changed = false;
    for (final Map<String, Object?> row in settlements) {
      final Object? rawReceipt = row['receipt_doc_id'];
      if (rawReceipt is! String) continue;
      final Object? rawTarget = row['target_doc_id'];
      final String? target = rawTarget is String ? rawTarget : null;

      final bool receiptOk =
          knownDocIds.contains(rawReceipt) && !verdicts.containsKey(rawReceipt);
      // `target_doc_id` 为空的核销是**预收 / 预付**（还没落到某张单上），
      // 只有收付款单一端，不需要两端都在。
      final bool targetOk =
          target == null ||
          (knownDocIds.contains(target) && !verdicts.containsKey(target));

      if (receiptOk && targetOk) continue;

      if (knownDocIds.contains(rawReceipt) &&
          !verdicts.containsKey(rawReceipt)) {
        verdicts[rawReceipt] = _settlementIssue(
          byId[rawReceipt],
          receipt: true,
        );
        changed = true;
      }
      if (target != null &&
          knownDocIds.contains(target) &&
          !verdicts.containsKey(target)) {
        verdicts[target] = _settlementIssue(byId[target], receipt: false);
        changed = true;
      }
    }
    if (!changed) break;
  }
}

RescueIssue _settlementIssue(
  Map<String, Object?>? doc, {
  required bool receipt,
}) {
  final String label =
      DocType.fromWireOrNull(doc?['doc_type'] as String? ?? '')?.label ??
      '未知类型';
  final Map<String, Object?> meta = doc == null
      ? const <String, Object?>{}
      : _meta(doc, label);
  return RescueIssue(
    docId: doc?['id'] as String? ?? '',
    docNo: doc?['doc_no'] as String? ?? '（单号读不出来）',
    typeLabel: label,
    kind: RescueIssueKind.brokenSettlement,
    occurredAt: meta['occurredAt'] as DateTime?,
    totalAmount: meta['totalAmount'] as int?,
    detail: receipt
        ? '这张收付款单核销的那张单据没救回来（或者它本身不完整）。'
              '单独导入它，这笔钱就挂不到任何单据上。'
        : '这张单的收款/付款记录没救回来（或者那条记录本身不完整）。'
              '单独导入它，欠款会对不上。',
  );
}

/// 出现了**不该有**的流水（用户审查 2026-10-30，P0）。
///
/// 符号表里 [LedgerDirection.absent] 的意思是「这类单据**不产生**这本账的流水」，
/// 不是「方向为零」。所以只要出现了行，就是坏数据 —— 而从前三条判据
/// 各自只看自己的那一侧，谁都没管「多余」：
///
/// | 场景 | 从前为什么漏 |
/// |---|---|
/// | 普通销售单多出一条资金流水 | `_moneyProblem` 的主单分支只比 `settled vs paid`，不看 `money` 是否为空 |
/// | 散客销售多出一条往来流水 | `_partyProblem` 在 `party_id` 为空时直接 `return null` |
/// | 收付款单多出一条库存流水 | `_stockProblem` 只在 `expectsLines` 时调用，收付款单没有明细 ⇒ 整个跳过 |
///
/// 后果都是「账户余额凭空多一笔 / 欠款挂到别人名下 / 收款改了库存」。
///
/// ⚠️ 例外：**盘点的库存流水是合法的**（差额可正可负），所以库存那条只判
/// `absent`，`either` 放行。
String? _unexpectedLedgerProblem({
  required DocType type,
  required List<Map<String, Object?>> stock,
  required List<Map<String, Object?>> party,
  required List<Map<String, Object?>> money,
  required Object? partyId,
}) {
  if (!stockDirectionOf(type).mayHaveRows && stock.isNotEmpty) {
    return '这张单不该有库存记录，却读到了 ${stock.length} 条 —— '
        '导入它，库存会凭空变。';
  }
  // 往来：**两个条件任一不成立都不该有** ——
  //   ① 这类单据本来就不产生往来流水（如盘点）
  //   ② 单据根本没有往来方（散客 / 散采）⇒ 欠款无处可挂
  final bool partyAllowed =
      partyDirectionOf(type).mayHaveRows &&
      partyId is String &&
      partyId.isNotEmpty;
  if (!partyAllowed && party.isNotEmpty) {
    return '这张单不该有欠款记录，却读到了 ${party.length} 条 —— '
        '导入它，这笔欠款会被挂到某个客户/供应商名下。';
  }
  if (!moneyDirectionOf(type).mayHaveRows && money.isNotEmpty) {
    return '这张单不该有资金记录，却读到了 ${money.length} 条 —— '
        '导入它，账户余额会凭空变。';
  }
  return null;
}

/// 分 → 「¥1,234.56」。报告里一律用这个，不写「1234.56 分」。
String _yuan(int cents) => '¥${Money.formatGrouped(cents)}';

/// 明细金额合计 ≠ 单据总额。
///
/// ⚠️ **用 `amount` 之和**，**不许**用 `unit_price × quantity` 重算：
/// 让价体现在 `amount` 里（`document_line.dart` 的注释），重算必然误报。
///
/// 哪些类型不适用由 `linesAmountAppliesTo()` 决定 —— 与规则层
/// `linesAmountMatchesTotal()` 共用同一个定义，不在这里复制例外清单。
bool _linesAmountMismatch(List<Map<String, Object?>> lines, int totalCents) =>
    _sumCents(lines) != totalCents;

/// 流水**自己**的引用是否站得住（用户审查 2026-10-30，P1）。
///
/// 为什么单据级的外键检查不够：`_firstMissingRef` 只看单据自己的
/// `party_id` / `account_id`。而损坏完全可以把**流水那一行**的引用改成
/// 另一个仍然存在的往来方 —— 金额照样对得上，欠款却被记到了别人名下。
///
/// 账户不存在的情况更糟：目标库有外键，写库时会直接抛错 ⇒ **整次抢救失败**，
/// 用户连其余能救的单据都拿不到。所以必须在这里就把它变成「待确认」。
String? _ledgerRefProblem({
  required List<Map<String, Object?>> party,
  required List<Map<String, Object?>> money,
  required Object? docPartyId,
  required Object? docAccountId,
  required Set<String> partyIds,
  required Set<String> accountIds,
  required bool isSettleDoc,
}) {
  final String? docParty = docPartyId is String && docPartyId.isNotEmpty
      ? docPartyId
      : null;
  // 收付款单**必须**同时有往来方与账户（`rule_engine._settle` 直接 `StateError`）。
  // 损坏把这两列置空后，下面那些「字段为空就不比」的检查会全部跳过 ⇒
  // 一张业务上根本不存在的收付款单会被当成完整数据导入（用户审查 2026-10-30，P1）。
  if (isSettleDoc) {
    if (docParty == null) {
      return '这张收付款单没有往来方 —— 钱不知道是谁给的、给谁的，不能导入。';
    }
    if (docAccountId is! String || docAccountId.isEmpty) {
      return '这张收付款单没有账户 —— 钱不知道进出哪个账户，不能导入。';
    }
  }
  for (final Map<String, Object?> row in party) {
    final Object? pid = row['party_id'];
    // ⚠️ **不能 `continue`**（用户审查 2026-10-30）：`party_ledger.party_id`
    // 在 schema 里是 `NOT NULL`，读到空值只可能是数据坏了。跳过它等于放过，
    // 而写新库时会被 NOT NULL 顶回来 —— **整次抢救全失败**，
    // 用户连其余能救的单据都拿不到。
    if (pid is! String || pid.isEmpty) {
      return '有一条欠款记录没有往来方（数据可能坏了）—— '
          '导入它会让整次恢复失败。';
    }
    if (!partyIds.contains(pid)) {
      return '这条欠款记录挂在一个不存在的往来方（$pid）上 —— 补上它之前不能导入。';
    }
    if (docParty != null && pid != docParty) {
      return '这条欠款记录挂的往来方（$pid）和单据上的（$docParty）不是同一个 —— '
          '导入它会把欠款记到别人名下。';
    }
  }
  final String? docAccount = docAccountId is String && docAccountId.isNotEmpty
      ? docAccountId
      : null;
  for (final Map<String, Object?> row in money) {
    final Object? aid = row['account_id'];
    // 同上：`money_ledger.account_id` 也是 `NOT NULL`
    if (aid is! String || aid.isEmpty) {
      return '有一笔资金记录没有账户（数据可能坏了）—— '
          '导入它会让整次恢复失败。';
    }
    if (!accountIds.contains(aid)) {
      return '这笔钱记在一个不存在的账户（$aid）上 —— 补上它之前不能导入。';
    }
    if (isSettleDoc && docAccount != null && aid != docAccount) {
      return '这笔钱的账户（$aid）和收付款单上的（$docAccount）不是同一个 —— '
          '导入它账会对不上。';
    }
  }
  return null;
}

int _sumCents(List<Map<String, Object?>> rows) {
  int sum = 0;
  for (final Map<String, Object?> row in rows) {
    final Object? amount = row['amount'];
    if (amount is int) sum += amount;
  }
  return sum;
}

/// 找出「这张单引用了、但主数据没救回来」的第一个名字（人话）。
///
/// ⚠️ 核销关系的检查**不在这里**：它需要「两端都在不在」的全量视角，
/// 由 [_propagateSettlements] 统一处理（从前这里收了个 `settle` 参数却没用，
/// 是个半成品入口 —— 2026-10-30 审查指出）。
String? _firstMissingRef({
  required Map<String, Object?> doc,
  required List<Map<String, Object?>> lines,
  required Set<String> productIds,
  required Set<String> partyIds,
  required Set<String> accountIds,
}) {
  for (final Map<String, Object?> line in lines) {
    final Object? pid = line['product_id'];
    if (pid is String && !productIds.contains(pid)) return '商品 $pid';
  }
  final Object? party = doc['party_id'];
  if (party is String && party.isNotEmpty && !partyIds.contains(party)) {
    return '往来方 $party';
  }
  final Object? account = doc['account_id'];
  if (account is String &&
      account.isNotEmpty &&
      !accountIds.contains(account)) {
    return '账户 $account';
  }
  return null;
}

// ============================================================ 写新库

/// 把读到的数据写进新库。返回 `null` 表示成功，否则是原因。
///
/// 只写**完整**的业务单元（`asm.importable`）—— 不完整的留在报告里，
/// 由用户看过之后决定要不要（第一版不做「强行导入」）。
String? _writeNewDatabase({
  required String outputPath,
  required Map<String, List<Map<String, Object?>>> rows,
  required _Assembly asm,
}) {
  Db? db;
  try {
    db = Db.open(outputPath);
    db.transaction(() {
      // 主数据先写（单据要引用它们）
      for (final String table in _masterTables) {
        for (final Map<String, Object?> row in rows[table] ?? const []) {
          _insertRow(db!, table, row);
        }
      }
      // 业务数据：只写完整单元
      final Set<String> ok = asm.importable;
      for (final Map<String, Object?> row
          in rows[Schema.documents] ?? const []) {
        if (!ok.contains(row['id'])) continue;
        _insertRow(db!, Schema.documents, row);
      }
      for (final String table in <String>[
        Schema.documentLines,
        Schema.stockLedger,
        Schema.moneyLedger,
        Schema.partyLedger,
      ]) {
        for (final Map<String, Object?> row in rows[table] ?? const []) {
          if (!ok.contains(row['document_id'])) continue;
          _insertRow(db!, table, row);
        }
      }
      // 核销：只写两端都可导入的单据。
      //
      // 到这里 `ok` 已经过 `_propagateSettlements` 的双端传播 —— 只要一端
      // 缺失或不完整，另一端也已经被踢出 `ok` 了。所以这个 `continue`
      // 现在只是**兜底**（防将来有人改动传播逻辑后静默丢关系），
      // 正常情况下一条都不会命中。
      for (final Map<String, Object?> row
          in rows[Schema.settlements] ?? const []) {
        final Object? receipt = row['receipt_doc_id'];
        final Object? target = row['target_doc_id'];
        if (!ok.contains(receipt)) continue;
        if (target is String && !ok.contains(target)) continue;
        _insertRow(db!, Schema.settlements, row);
      }
    });
    return null;
  } on SqliteException catch (error) {
    return error.message;
  } on StateError catch (error) {
    return error.message;
  } finally {
    db?.close();
  }
}

/// 插一行：**只写目标表真有的列**。
///
/// 为什么过滤：抢救源可能是**老版本**的库（少 `business_day` 这类新列），
/// 直接按源列 INSERT 会因缺列而失败；反过来源里有、目标没有的列也会报错。
void _insertRow(Db db, String table, Map<String, Object?> row) {
  final Set<String> targetColumns = <String>{
    for (final Row r in db.raw.select('PRAGMA table_info($table)'))
      r['name'] as String,
  };
  final Map<String, Object?> values = <String, Object?>{
    for (final MapEntry<String, Object?> e in row.entries)
      if (targetColumns.contains(e.key)) e.key: e.value,
  };
  // v6 起 `business_day` NOT NULL 且无默认值：老库没有这一列 ⇒ 现算
  if (table == Schema.documents && !values.containsKey('business_day')) {
    final Object? at = row['occurred_at'];
    if (at is int) values['business_day'] = businessDayOf(at);
  }
  if (values.isEmpty) return;
  final String columns = values.keys.map((String c) => '"$c"').join(', ');
  final String marks = List<String>.filled(values.length, '?').join(', ');
  db.raw.execute(
    'INSERT OR IGNORE INTO "$table" ($columns) VALUES ($marks)',
    values.values.toList(),
  );
}

// ============================================================ 杂项

/// 把原件设为只读。返回是否成功（失败不影响抢救本身，报告里会说）。
bool _markReadOnly(String path) {
  try {
    if (Platform.isWindows) {
      final ProcessResult result = Process.runSync('attrib', <String>[
        '+R',
        path,
      ]);
      return result.exitCode == 0;
    }
    final ProcessResult result = Process.runSync('chmod', <String>[
      '444',
      path,
    ]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void _cleanup(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } on FileSystemException {
    // 删不掉就算了（临时目录，系统会回收）
  }
}

void _deleteQuietly(String path) {
  try {
    final File file = File(path);
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // 同上
  }
}

/// 抢救结果的文件名：`shensuanzi-抢救-20261029-2015.db`
String rescueFileName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'shensuanzi-抢救-${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}.db';
}
