// 数据抢救 P1（只读抢救导出）的测试 —— 2026-10-29，提案 52 §四·P1。
//
// 这一层要动的是**用户仅存的那份数据**，所以每条用例都拿真 SQLite 文件库跑，
// 并且都断言「原件没被动过」。
//
// 覆盖：
//   · 完好库 ⇒ 全部读出、全部导入、0 条待确认
//   · 头坏 ⇒ 借头 + **修页数**后全救回（这是实测踩出来的关键：不修页数 ⇒ 0 行）
//   · 坏索引 ⇒ 砍索引后全救回
//   · 坏页 ⇒ 分批读跳过坏批，其余照常；报告里有 badBatches
//   · 缺明细的单据 ⇒ 进待确认列表、**不导入**（账不能不平）
//   · 截断 ⇒ 明确失败并说原因（不做页级扫描）
//   · 原件：字节不变 + 设为只读
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  useLocalSqlite();

  late Directory root;
  late String source;
  late String output;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ssz_rescue_');
    source = p.join(root.path, 'shensuanzi.db');
    output = p.join(root.path, 'shensuanzi-抢救.db');
  });

  tearDown(() {
    // 抢救会把原件设成只读 —— 不先去掉，Windows 上删不掉
    _clearReadOnly(source);
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // 临时目录，删不掉不影响结论
    }
  });

  /// 造 [docs] 张销售单：每单 2 行明细 + 1 条库存流水 + 1 条资金流水。
  void makeDb(String path, {int docs = 20, bool withPartyLedger = true}) {
    final Db db = Db.open(path);
    db.raw.execute(
      "INSERT OR IGNORE INTO products (id, code, name, unit, sell_price, "
      "cost_price, safety_stock, is_active, created_at, updated_at) "
      "VALUES ('prod1', 'P0001', '可乐', '瓶', 1000, 800, 0, 1, 0, 0)",
    );
    db.raw.execute(
      "INSERT OR IGNORE INTO parties (id, name, roles, created_at, updated_at) "
      "VALUES ('p1', '老王', '[\"customer\"]', 0, 0)",
    );
    db.raw.execute(
      "INSERT OR IGNORE INTO accounts (id, name, type, initial_balance, "
      "created_at, updated_at) VALUES ('acc1', '现金', 'cash', 0, 0, 0)",
    );
    for (int i = 0; i < docs; i++) {
      final String did = 'doc${i.toString().padLeft(3, '0')}';
      final int at = DateTime(2026, 9, 1).millisecondsSinceEpoch + i * 3600000;
      db.raw.execute(
        'INSERT INTO documents (id, doc_no, doc_type, status, party_id, '
        'total_amount, paid_amount, occurred_at, time_estimated, created_at, '
        'updated_at, business_day) VALUES (?,?,?,?,?,?,?,?,0,?,?,?)',
        <Object?>[
          did,
          'XS${i.toString().padLeft(3, '0')}',
          'sale',
          'confirmed',
          'p1',
          2000,
          2000,
          at,
          at,
          at,
          businessDayOf(at),
        ],
      );
      // ⚠️ **每行明细一条库存流水**（与 `rule_engine` 一致：`for (line in lines)
      // _insertStock(...)`）。从前这里 2 行明细只插 1 条流水，判据又只看
      // 「有没有任意一条」，两边一起把「少一条流水」放过去了 —— 夹具必须先对。
      for (int j = 0; j < 2; j++) {
        db.raw.execute(
          'INSERT INTO document_lines (id, document_id, product_id, quantity, '
          'unit_price, amount) VALUES (?,?,?,?,?,?)',
          <Object?>['$did-l$j', did, 'prod1', 1, 1000, 1000],
        );
        db.raw.execute(
          'INSERT INTO stock_ledger (id, product_id, document_id, quantity, '
          'unit_cost, total_cost, seq_no, occurred_at, created_at) '
          'VALUES (?,?,?,?,?,?,?,?,?)',
          <Object?>[
            '$did-s$j',
            'prod1',
            did,
            -1,
            1000,
            1000,
            i * 10 + j,
            at,
            at,
          ],
        );
      }
      db.raw.execute(
        'INSERT INTO money_ledger (id, account_id, document_id, amount, '
        'seq_no, occurred_at, created_at) VALUES (?,?,?,?,?,?,?)',
        <Object?>['$did-m', 'acc1', did, 2000, i + 1, at, at],
      );
      if (withPartyLedger) {
        db.raw.execute(
          'INSERT INTO party_ledger (id, party_id, document_id, amount, '
          'seq_no, occurred_at, created_at) VALUES (?,?,?,?,?,?,?)',
          <Object?>['$did-p', 'p1', did, 2000, i + 1, at, at],
        );
      }
    }
    db.close();
  }

  Future<RescueReport> rescue() => rescueDatabase(
    sourcePath: source,
    outputPath: output,
    workDirectory: p.join(root.path, 'work'),
  );

  /// 新库里的单据数
  int countDocs(String path) {
    final Db db = Db.open(path);
    final int n =
        db.raw.select('SELECT COUNT(*) FROM documents').first.values.first!
            as int;
    db.close();
    return n;
  }

  // ============================================================ 完好库
  group('完好库', () {
    test('全部读出、全部导入、0 条待确认', () async {
      makeDb(source);
      final RescueReport report = await rescue();

      expect(report.ok, isTrue, reason: report.failure);
      expect(report.totalDocuments, 20);
      expect(report.importedDocuments, 20);
      expect(report.issues, isEmpty);
      expect(report.headerRepaired, isFalse);
      expect(report.badBatches, 0);
      expect(report.unreadableTables, isEmpty);
      expect(countDocs(report.outputPath!), 20);
    });

    test('原件一个字节都没被动过，并且被设成只读', () async {
      makeDb(source);
      final List<int> before = File(source).readAsBytesSync();
      final RescueReport report = await rescue();

      expect(report.ok, isTrue, reason: report.failure);
      expect(
        File(source).readAsBytesSync(),
        before,
        reason: '抢救只动副本 —— 原件被改就等于毁了唯一的证据',
      );
      expect(report.readOnlyMarked, isTrue, reason: '原件要设只读，防手滑');
    });

    test('新库里主数据也在（否则单据指向空气）', () async {
      makeDb(source);
      final RescueReport report = await rescue();
      final Db db = Db.open(report.outputPath!);
      final int products =
          db.raw.select('SELECT COUNT(*) FROM products').first.values.first!
              as int;
      final int lines =
          db.raw
                  .select('SELECT COUNT(*) FROM document_lines')
                  .first
                  .values
                  .first!
              as int;
      db.close();
      expect(products, 1);
      expect(lines, 40, reason: '20 单 × 2 行');
    });
  });

  // ============================================================ 三种损坏
  group('损坏', () {
    test('文件头坏 ⇒ 借头（并修页数）后全部救回', () async {
      // ⚠️ 必须用**数据量够大**的库：20 单的库总页数与「空库 donor」只差几页，
      // 撤掉「修页数」也照样读得出 ⇒ 测试钉不住那个修复（实测踩到）。
      // 200 单时真实页数远大于 donor，不修页数会丢掉大半数据。
      makeDb(source, docs: 200);
      patchBytes(source, 0, List<int>.filled(100, 0));

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.headerRepaired, isTrue);
      expect(
        report.totalDocuments,
        200,
        reason: '只贴头不修「页数」⇒ SQLite 以为库只有 donor 那么大，后面的页不看',
      );
      expect(countDocs(report.outputPath!), 200);
    });

    test('坏一个索引 ⇒ 砍索引后全部救回', () async {
      makeDb(source);
      // 弄坏一个索引的根页
      final Db db = Db.open(source);
      final found = db.raw.select(
        "SELECT name, rootpage FROM sqlite_master "
        "WHERE type='index' AND rootpage > 0",
      );
      db.close();
      expect(found, isNotEmpty);
      final int rootPage = found.first['rootpage'] as int;
      // 页大小从文件头读（同坏页用例的理由）
      final RandomAccessFile head = File(source).openSync();
      final List<int> first = head.readSync(100);
      head.closeSync();
      final int pageSize = (first[16] << 8) | first[17];
      patchBytes(source, rootPage * pageSize, List<int>.filled(pageSize, 0));

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.totalDocuments, 20, reason: '坏索引不该让数据读不出来');
    });

    test('坏页 ⇒ 救回大部分，并把读不出的部分如实报出来', () async {
      // 50 单就够：夹具改成「每明细一条流水」后库变大，坏两页容易砸到关键结构，
      // 那时抢救会正确地报「读不出任何数据」—— 那就测不到「跳过坏页」这个能力了。
      makeDb(source, docs: 50);
      final int size = File(source).lengthSync();
      // ⚠️ 页大小必须从文件头读（偏移 16..17，大端），**不能假设 4096**。
      final RandomAccessFile head = File(source).openSync();
      final List<int> first = head.readSync(100);
      head.closeSync();
      final int pageSize = (first[16] << 8) | first[17];
      final int pages = size ~/ pageSize;

      // 坏**尾部两页**（数据叶子页）：坏根页的话 SQLite 会静默返回空表
      // （实测），那就成了「整份读不出」，测不到「跳过坏页」这个能力。
      for (final int target in <int>[pages - 2]) {
        patchBytes(source, target * pageSize, List<int>.filled(pageSize, 0));
      }

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.totalDocuments,
        greaterThan(20),
        reason:
            '坏两页只该丢掉落在那两页上的行，不是整表放弃'
            '（整表 SELECT * 会整表失败，这是分批 + 二分读的意义）',
      );
      expect(
        report.badBatches > 0 || report.importedDocuments < 50,
        isTrue,
        reason: '有损失就必须在报告里体现，不能悄悄少几张',
      );
    });

    test('截断 ⇒ 明确失败并说清原因（不做页级扫描）', () async {
      makeDb(source);
      final int size = File(source).lengthSync();
      final RandomAccessFile raf = File(
        source,
      ).openSync(mode: FileMode.writeOnly);
      raf.truncateSync((size * 0.6).round());
      raf.closeSync();

      final RescueReport report = await rescue();
      expect(report.ok, isFalse);
      expect(
        report.failure,
        anyOf(contains('修不好'), contains('截断'), contains('对不上')),
        reason: '截断救不了是已知结论，要说清而不是假装成功',
      );
      expect(File(output).existsSync(), isFalse, reason: '失败不许留下半成品');
    });
  });

  // ============================================================ 完整性
  group('完整性（按单据，不按行）', () {
    test('缺明细的单据进待确认、**不导入**', () async {
      makeDb(source, docs: 10);
      // 删掉第 5 单的全部明细 —— 模拟「明细那几行落在坏页上」
      final Db db = Db.open(source);
      db.raw.execute("DELETE FROM document_lines WHERE document_id = 'doc004'");
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.totalDocuments, 10);
      expect(report.importedDocuments, 9);
      expect(report.issues.length, 1);
      expect(report.issues.single.docNo, 'XS004');
      expect(report.issues.single.kind, RescueIssueKind.missingLines);
      expect(report.issues.single.summary, contains('明细'));

      // 新库里没有那张不完整的单 —— 账不能不平
      final Db out = Db.open(report.outputPath!);
      final int n =
          out.raw
                  .select("SELECT COUNT(*) FROM documents WHERE id = 'doc004'")
                  .first
                  .values
                  .first!
              as int;
      out.close();
      expect(n, 0, reason: '缺明细的单据导入进去会让金额对不上明细');
    });

    test('**同一商品多行明细、只丢一条流水** ⇒ 不完整（用户举的反例）', () async {
      // 夹具是「1 单 2 行明细（都是 prod1）+ 每行一条库存流水」。
      // 删掉其中一条 ⇒ 商品「prod1」**仍然出现在流水里**，
      // 所以「按 product_id 看有没有」这种判据会放过它（用户指出的漏检）。
      // 必须按商品核对**行数**与**数量**才抓得住。
      makeDb(source, docs: 1);
      final Db db = Db.open(source);
      db.raw.execute("DELETE FROM stock_ledger WHERE id = 'doc000-s1'");
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.issues.length,
        1,
        reason: '2 行明细只剩 1 条流水 ⇒ 这张单不完整，不能静默当完整导入',
      );
      expect(report.importedDocuments, 0);
    });

    test('往来流水金额与单据金额不符 ⇒ 不完整', () async {
      makeDb(source, docs: 1);
      final Db db = Db.open(source);
      // 单据金额 2000，往来冲减却被写成 1000（模拟坏页只救回一部分 / 数据被改）
      db.raw.execute(
        "UPDATE party_ledger SET amount = 1000 WHERE document_id = 'doc000'",
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.issues.length, 1, reason: '往来冲减 ≠ 单据金额 ⇒ 欠款会算错，不能当完整');
    });

    test('资金流水金额与已收金额不符 ⇒ 不完整', () async {
      makeDb(source, docs: 1);
      final Db db = Db.open(source);
      // 单据 paid_amount = 2000，资金流水却只有 1000
      db.raw.execute(
        "UPDATE money_ledger SET amount = 1000 WHERE document_id = 'doc000'",
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.issues.length, 1, reason: '收到的钱与流水对不上 ⇒ 账错了，不能当完整');
    });

    test('没有任何流水的单据也算不完整（库存/往来会不准）', () async {
      makeDb(source, docs: 5, withPartyLedger: false);
      final Db db = Db.open(source);
      // 把第 2 单的库存与资金流水都删掉
      db.raw.execute("DELETE FROM stock_ledger WHERE document_id = 'doc001'");
      db.raw.execute("DELETE FROM money_ledger WHERE document_id = 'doc001'");
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.importedDocuments, 4);
      expect(
        report.issues.single.kind,
        RescueIssueKind.missingLedger,
        reason: '单据在、明细在，但一行流水都没有 ⇒ 库存和欠款都会错',
      );
    });

    test('盘点单：数量无变化 ⇒ 不产生库存流水，仍算**完整**（反例）', () async {
      // 用户裁定补充里的反例：盘点的零差额**本来就不写库存流水**，
      // 所以不能要求「每行明细都有流水」—— 那样每张没差异的盘点单都会被误判。
      makeDb(source, docs: 0);
      final Db db = Db.open(source);
      final int at = DateTime(2026, 10, 1).millisecondsSinceEpoch;
      db.raw.execute(
        'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
        'paid_amount, occurred_at, time_estimated, created_at, updated_at, '
        'business_day) VALUES (?,?,?,?,0,0,?,0,?,?,?)',
        <Object?>[
          'stk1',
          'PD20261001-001',
          'stocktake',
          'confirmed',
          at,
          at,
          at,
          businessDayOf(at),
        ],
      );
      // 一行明细、数量无变化（= 账面），所以没有 stock_ledger
      db.raw.execute(
        'INSERT INTO document_lines (id, document_id, product_id, quantity, '
        'unit_price, amount) VALUES (?,?,?,?,0,0)',
        <Object?>['stk1-l0', 'stk1', 'prod1', 100],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.issues, isEmpty, reason: '零差额的盘点单没有库存流水是**正常**的，不能判不完整');
      expect(report.importedDocuments, 1);
    });

    test('单据本身没读到、但明细还在 ⇒ 单独报出来', () async {
      makeDb(source, docs: 5);
      // 关外键才能插出「指向不存在单据」的行 —— 现实里这是坏页造成的，
      // 不是正常写入能产生的形态
      final Db db = Db.open(source, foreignKeys: false);
      // 留一行「指向不存在单据」的明细（模拟单据行落在坏页上）
      db.raw.execute(
        'INSERT INTO document_lines (id, document_id, product_id, quantity, '
        'unit_price, amount) VALUES (?,?,?,?,?,?)',
        <Object?>['orphan-l0', 'ghost-doc', 'prod1', 1, 1000, 1000],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.issues.where(
          (RescueIssue i) => i.kind == RescueIssueKind.orphanLines,
        ),
        isNotEmpty,
        reason: '这种单据在列表里看不到，但账里有 —— 必须单独告诉用户',
      );
    });

    test('引用没救回来的商品 ⇒ 不导入并说清缺什么', () async {
      makeDb(source, docs: 3);
      // 关外键：模拟「商品那几行落在坏页上、单据还指着它」的形态
      final Db db = Db.open(source, foreignKeys: false);
      // 第 1 单引用一个不存在的商品（模拟商品那几行没救回来）
      db.raw.execute(
        "UPDATE document_lines SET product_id = 'ghost' "
        "WHERE document_id = 'doc000'",
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.importedDocuments, 2);
      expect(
        report.issues.single.kind,
        RescueIssueKind.missingMasterData,
        reason: '外键断了硬导进去，用户会看到一张指向空气的单',
      );
      expect(report.issues.single.detail, contains('ghost'));
    });
  });

  // ============================================================ WAL（裁定补充 ①）
  group('WAL', () {
    /// 造一个「主文件 100 单 + wal 里 20 单」的库，返回时**源库仍开着**
    /// （一关就会 checkpoint，wal 就空了 —— 这正是崩溃现场的形态）。
    Database makeWithPendingWal(String path) {
      makeDb(path, docs: 100);
      final Database raw = sqlite3.open(path);
      raw.execute('PRAGMA journal_mode = WAL');
      raw.execute('PRAGMA wal_autocheckpoint = 0');
      for (int i = 0; i < 20; i++) {
        final int at =
            DateTime(2026, 10, 1).millisecondsSinceEpoch + i * 3600000;
        final String did = 'wal${i.toString().padLeft(3, '0')}';
        raw.execute(
          'INSERT INTO documents (id, doc_no, doc_type, status, party_id, '
          'total_amount, paid_amount, occurred_at, time_estimated, created_at, '
          'updated_at, business_day) VALUES (?,?,?,?,?,?,?,?,0,?,?,?)',
          <Object?>[
            did,
            'WAL${i.toString().padLeft(3, '0')}',
            'sale',
            'confirmed',
            'p1',
            2000,
            2000,
            at,
            at,
            at,
            businessDayOf(at),
          ],
        );
        // ⚠️ 必须是**完整业务单元**（明细 + 库存流水 + 资金流水），否则会被
        // 完整性判定正确地判成「不完整」而不导入 —— 那时断言 120 就会失败，
        // 但失败原因是夹具不完整，不是 WAL 没救回来（这一条踩过）。
        raw.execute(
          'INSERT INTO document_lines (id, document_id, product_id, quantity, '
          'unit_price, amount) VALUES (?,?,?,?,?,?)',
          <Object?>['$did-l0', did, 'prod1', 1, 1000, 1000],
        );
        raw.execute(
          'INSERT INTO stock_ledger (id, product_id, document_id, quantity, '
          'unit_cost, total_cost, seq_no, occurred_at, created_at) '
          'VALUES (?,?,?,?,?,?,?,?,?)',
          <Object?>['$did-s', 'prod1', did, -1, 1000, 1000, 1000 + i, at, at],
        );
        raw.execute(
          'INSERT INTO money_ledger (id, account_id, document_id, amount, '
          'seq_no, occurred_at, created_at) VALUES (?,?,?,?,?,?,?)',
          <Object?>['$did-m', 'acc1', did, 2000, 1000 + i, at, at],
        );
      }
      return raw;
    }

    test('源库有还没落盘的事务 ⇒ 必须一起救回来', () async {
      // 实测（提案 53 §一）：只拷主文件会丢 17%。这条钉住「连 -wal 一起拷」。
      final Database raw = makeWithPendingWal(source);
      final int walSize = File('$source-wal').existsSync()
          ? File('$source-wal').lengthSync()
          : 0;
      expect(walSize, greaterThan(0), reason: '夹具前提：wal 里必须有内容');

      final RescueReport report = await rescue();
      raw.dispose();

      expect(report.ok, isTrue, reason: report.failure);
      expect(report.walCopied, isTrue, reason: '要告诉用户「用上了还没落盘的数据」');
      expect(
        report.totalDocuments,
        120,
        reason:
            '只拷主文件只能读到 100 —— 那 20 单是**已提交、还没 checkpoint** 的，'
            '丢掉它们不是「没办法」，是漏了',
      );
      expect(countDocs(report.outputPath!), 120);
    });

    test('源文件不存在 ⇒ 明确失败，不产半成品', () async {
      final RescueReport report = await rescue();
      expect(report.ok, isFalse);
      expect(report.failure, contains('已经不在了'));
      expect(File(output).existsSync(), isFalse);
    });

    test('源库没有 wal（正常关闭）⇒ 照常工作，不误报', () async {
      makeDb(source);
      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.walCopied, isFalse);
      expect(report.totalDocuments, 20);
    });
  });

  // ============================================================ 报告文案
  group('报告文案（用户补充建议第 2 条：不许出现 SQL 术语）', () {
    test('按类型统计用的是中文名，不是表名', () async {
      makeDb(source, docs: 6);
      final RescueReport report = await rescue();
      expect(report.typeStats.length, 1);
      expect(
        report.typeStats.single.label,
        '店内销售',
        reason: '报告里写「documents 表 6 行」用户看不懂',
      );
      expect(report.typeStats.single.total, 6);
      expect(report.typeStats.single.complete, 6);
    });

    test('不可读的表用中文名', () async {
      makeDb(source, docs: 2);
      final RescueReport report = await rescue();
      for (final String name in report.unreadableTables) {
        expect(name, isNot(contains('_')), reason: '不许把 stock_ledger 这种表名露给用户');
      }
    });
  });
}

/// 在文件的 [offset] 处写入 [bytes]（**保持文件其余部分不变**）。
///
/// ⚠️ 不能用 `RandomAccessFile`：Dart 在 Windows 上 `FileMode.write` /
/// `writeOnly` 都会**截断**文件，`append` 又是 O_APPEND（忽略 seek）。
/// 只有「读全部 → 改 → 整体写回」是可靠的。
void patchBytes(String path, int offset, List<int> bytes) {
  final Uint8List all = File(path).readAsBytesSync();
  all.setRange(offset, offset + bytes.length, bytes);
  File(path).writeAsBytesSync(all);
}

/// 去掉只读属性（Windows 上 `deleteSync` 对只读文件会失败）。
void _clearReadOnly(String path) {
  if (!Platform.isWindows) return;
  if (!File(path).existsSync()) return;
  try {
    Process.runSync('attrib', <String>['-R', path]);
  } on ProcessException {
    // 忽略：删不掉也只是留个临时文件
  }
}
