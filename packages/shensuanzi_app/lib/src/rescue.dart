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
  try {
    onProgress?.call(const RescueProgress(0.05, '正在复制一份出来（原件不会被动）'));
    source.copySync(copy);
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

  Database? db;
  try {
    db = sqlite3.open(copy);
    // 头好了也可能结构坏 —— 真读一下才算「打开成功」
    db.select('SELECT name FROM sqlite_master LIMIT 1');
  } on SqliteException catch (error) {
    db?.dispose();
    return RescueReport.failed('打不开这个数据文件（${error.message}）');
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

// ============================================================ 借头

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
  final Set<String> knownDocIds = <String>{};

  for (final Map<String, Object?> doc in docs) {
    final String id = doc['id'] as String;
    knownDocIds.add(id);
    final String wire = doc['doc_type'] as String? ?? '';
    final DocType? type = DocType.fromWireOrNull(wire);
    final String label = type?.label ?? '未知类型';

    totalByType[label] = (totalByType[label] ?? 0) + 1;

    final List<Map<String, Object?>> myLines = lines[id] ?? const [];
    final List<Map<String, Object?>> myStock = stock[id] ?? const [];
    final List<Map<String, Object?>> myMoney = money[id] ?? const [];
    final List<Map<String, Object?>> myParty = party[id] ?? const [];

    RescueIssueKind? issue;
    String? detail;

    // 该有明细吗？收付款单没有明细（它们只有资金流水）
    final bool expectsLines =
        type != null && type != DocType.receipt && type != DocType.payment;
    final bool expectsLedger =
        myStock.isNotEmpty || myMoney.isNotEmpty || myParty.isNotEmpty;

    if (expectsLines && myLines.isEmpty) {
      issue = RescueIssueKind.missingLines;
      detail =
          '这张单的明细一行都没读到。导入它会让单据金额对不上明细，'
          '库存和往来也可能少算。';
    } else if (!expectsLedger && type != DocType.stocktake) {
      // 盘点只改数量、不产生资金流水，所以它没有流水是正常的
      issue = RescueIssueKind.missingLedger;
      detail = '这张单没有任何库存或往来记录。导入它会让库存、欠款不准。';
    } else {
      // 外键检查：明细引用的商品、单据引用的往来方/账户有没有救回来
      final String? missing = _firstMissingRef(
        doc: doc,
        lines: myLines,
        settle: settle[id] ?? const [],
        productIds: productIds,
        partyIds: partyIds,
        accountIds: accountIds,
      );
      if (missing != null) {
        issue = RescueIssueKind.missingMasterData;
        detail = '这张单引用的「$missing」没有救回来。补上它之前，这张单不能导入。';
      }
    }

    final Map<String, Object?> meta = _meta(doc, label);
    if (issue == null) {
      asm.importable.add(id);
      completeByType[label] = (completeByType[label] ?? 0) + 1;
    } else {
      asm.issues.add(
        RescueIssue(
          docId: id,
          docNo: doc['doc_no'] as String? ?? '（单号读不出来）',
          typeLabel: label,
          kind: issue,
          occurredAt: meta['occurredAt'] as DateTime?,
          totalAmount: meta['totalAmount'] as int?,
          detail: detail,
        ),
      );
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

/// 找出「这张单引用了、但主数据没救回来」的第一个名字（人话）。
String? _firstMissingRef({
  required Map<String, Object?> doc,
  required List<Map<String, Object?>> lines,
  required List<Map<String, Object?>> settle,
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
      // 核销：只写两端都在的单据（否则就是指向空气的核销）
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
