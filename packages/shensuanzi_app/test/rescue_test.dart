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

  /// 用**真实业务规则**造一本账（用户审查 2026-10-30 §三 的要求）。
  ///
  /// ## 为什么不能用 SQL 手写
  ///
  /// 手写夹具把资金流水直接挂在销售单上、`paid_amount` 设成同额；真实引擎是
  /// 「主单**不写** `money_ledger`，立即收款自动生成 `receipt` 单，资金流水挂在
  /// receipt 上，`settlements` 关联两端」。结构不同 ⇒ 抢救判据在夹具上永远绿、
  /// 在真数据上却会误判。审查抓到的「正常收款单被判不完整」就是被夹具掩盖的。
  ///
  /// ## 造出来是什么样
  ///
  /// [docs] 张销售单，每单 2 行明细（都是 `prod1`、各 1 瓶 ¥10）⇒ 每单：
  ///   · 1 张 `sale`（`paid_amount` = 0 或 2000）
  ///   · 2 条 `stock_ledger`（挂 sale）
  ///   · 1 条 `party_ledger`（挂 sale，+2000）
  ///   · [paid] 时再加：1 张 `receipt` + 1 条 `money_ledger` + 1 条 `party_ledger`
  ///     + 1 条 `settlements`（receipt → sale）
  ///
  /// 返回按建单顺序的销售单 id —— 测试要用它们注入损坏。
  List<String> makeLedger(String path, {int docs = 20, bool paid = false}) {
    final Db db = Db.open(path);
    final RuleEngine engine = RuleEngine(db);
    final QueryDao queries = QueryDao(db);
    final SaleService sales = SaleService(engine: engine, queries: queries);

    final int t = DateTime(2026, 9, 1).millisecondsSinceEpoch;
    ProductDao(db).insert(
      Product(
        id: 'prod1',
        code: 'P0001',
        name: '可乐',
        unit: '瓶',
        sellPrice: 1000,
        costPrice: 800,
        createdAt: t,
        updatedAt: t,
      ),
    );
    PartyDao(db).insert(
      Party(
        id: 'p1',
        name: '老王',
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      ),
    );
    AccountDao(db).insert(
      Account(
        id: 'acc1',
        name: '现金',
        type: AccountType.cash,
        createdAt: t,
        updatedAt: t,
      ),
    );

    final List<String> ids = <String>[];
    for (int i = 0; i < docs; i++) {
      final SaleSaved saved = sales.create(
        SaleDraft(
          partyId: 'p1',
          partyName: '老王',
          date: '2026-09-01',
          lines: <SaleLineDraft>[
            SaleLineDraft(
              productId: 'prod1',
              productName: '可乐',
              quantity: '1',
              unitPrice: '10',
            ),
            SaleLineDraft(
              productId: 'prod1',
              productName: '可乐',
              quantity: '1',
              unitPrice: '10',
            ),
          ],
          payments: paid
              ? <SalePaymentDraft>[
                  SalePaymentDraft(
                    accountId: 'acc1',
                    accountName: '现金',
                    amount: '20',
                  ),
                ]
              : const <SalePaymentDraft>[],
        ),
      );
      ids.add(
        db.raw.select('SELECT id FROM documents WHERE doc_no = ?', <Object?>[
              saved.docNo,
            ]).first['id']!
            as String,
      );
    }
    db.close();
    return ids;
  }

  /// 源库里某张单的单号（断言报告里的 `docNo` 用）。
  String docNoOf(String id) {
    final Db db = Db.open(source);
    final String no =
        db.raw.select('SELECT doc_no FROM documents WHERE id = ?', <Object?>[
              id,
            ]).first['doc_no']!
            as String;
    db.close();
    return no;
  }

  /// 造一张**盘点单**（用真实规则，不是手写 SQL）。
  ///
  /// [actual] = 盘点出来的实际数量。账面数由库里的流水决定：
  /// `makeLedger(docs: 0)` 之后账面为 0，所以 `actual: 5` ⇒ 差额 +5（写一条流水），
  /// `actual: 0` ⇒ 差额 0（**不写流水**）。
  String makeStocktake(String path, {required int actual}) {
    final Db db = Db.open(path);
    final RuleEngine engine = RuleEngine(db);
    final int t = DateTime(2026, 10, 1).millisecondsSinceEpoch;
    final Document doc = Document(
      id: newId(),
      docNo: 'PD-TEST-$actual',
      docType: DocType.stocktake,
      status: DocStatus.confirmed,
      totalAmount: 0,
      occurredAt: t,
      createdAt: t,
      updatedAt: t,
    );
    final RuleOutcome outcome = engine.dispatch(
      document: doc,
      now: t,
      stocktakeActual: <String, int>{'prod1': actual},
    );
    expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
    db.close();
    return doc.id;
  }

  /// 造一本**混合业务**的真实账本，覆盖资金方向相反的四条路径：
  ///
  /// ① 采购 + 当场全款付（钱流出、库存增加、往来方向相反）
  /// ② 销售只收一部分（部分核销）
  /// ③ 销售退货 + **延迟退款**（付款单事后核销退货单）
  /// ④ 采购退货 + **延迟收款**（收款单事后核销退货单）
  ///
  /// 用户审查 2026-10-30 §四：只验销售+收款，**不能推断**采购、采购退货、
  /// 延迟退款这些方向相反的路径也通过。尤其采购退货 —— 它的资金与往来方向
  /// 都跟销售退货相反，最容易暴露「只考虑销售业务」。
  void makeMixedLedger(String path) {
    final Db db = Db.open(path);
    final RuleEngine engine = RuleEngine(db);
    final QueryDao queries = QueryDao(db);
    final PurchaseService purchases = PurchaseService(
      engine: engine,
      queries: queries,
    );
    final SaleService sales = SaleService(engine: engine, queries: queries);
    final ReturnService returns = ReturnService(
      engine: engine,
      queries: queries,
    );

    final int t = DateTime(2026, 9, 1).millisecondsSinceEpoch;
    ProductDao(db).insert(
      Product(
        id: 'prod1',
        code: 'P0001',
        name: '可乐',
        unit: '瓶',
        sellPrice: 1000,
        costPrice: 800,
        createdAt: t,
        updatedAt: t,
      ),
    );
    PartyDao(db).insert(
      Party(
        id: 'p1',
        name: '客户甲',
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      ),
    );
    PartyDao(db).insert(
      Party(
        id: 'p2',
        name: '供应商乙',
        roles: const <PartyRole>[PartyRole.supplier],
        createdAt: t,
        updatedAt: t,
      ),
    );
    AccountDao(db).insert(
      Account(
        id: 'acc1',
        name: '现金',
        type: AccountType.cash,
        createdAt: t,
        updatedAt: t,
      ),
    );

    String idOf(String docNo) =>
        db.raw.select('SELECT id FROM documents WHERE doc_no = ?', <Object?>[
              docNo,
            ]).first['id']!
            as String;

    // ① 采购 10 瓶 × ¥10 = ¥100，当场全款付
    final PurchaseSaved bought = purchases.create(
      PurchaseDraft(
        partyId: 'p2',
        partyName: '供应商乙',
        date: '2026-09-01',
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: 'prod1',
            productName: '可乐',
            quantity: '10',
            unitPrice: '10',
          ),
        ],
        payments: <PurchasePaymentDraft>[
          PurchasePaymentDraft(
            accountId: 'acc1',
            accountName: '现金',
            amount: '100',
          ),
        ],
      ),
    );
    final String purchaseId = idOf(bought.docNo);

    // ② 销售 3 瓶 = ¥30，只收 ¥10（部分核销）
    final SaleSaved sold = sales.create(
      SaleDraft(
        partyId: 'p1',
        partyName: '客户甲',
        date: '2026-09-01',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: 'prod1',
            productName: '可乐',
            quantity: '3',
            unitPrice: '10',
          ),
        ],
        payments: <SalePaymentDraft>[
          SalePaymentDraft(accountId: 'acc1', accountName: '现金', amount: '10'),
        ],
      ),
    );
    final String saleId = idOf(sold.docNo);

    // ③ 销售退货 1 瓶 ¥10，**不立即退钱**；随后用付款单退给他
    final ReturnSaved saleReturn = returns.create(
      ReturnDraft(
        refDocId: saleId,
        originalDocType: DocType.sale,
        partyId: 'p1',
        partyName: '客户甲',
        lines: <ReturnLineDraft>[
          ReturnLineDraft(
            productId: 'prod1',
            productName: '可乐',
            quantity: '1',
            amount: '10.00',
            originalQuantity: 3,
            originalAmountCents: 3000,
          ),
        ],
      ),
    );

    // ④ 采购退货 2 瓶 ¥20，**不立即收钱**；随后用收款单收回来
    final ReturnSaved purchaseReturn = returns.create(
      ReturnDraft(
        refDocId: purchaseId,
        originalDocType: DocType.purchase,
        partyId: 'p2',
        partyName: '供应商乙',
        lines: <ReturnLineDraft>[
          ReturnLineDraft(
            productId: 'prod1',
            productName: '可乐',
            quantity: '2',
            amount: '20.00',
            originalQuantity: 10,
            originalAmountCents: 10000,
          ),
        ],
      ),
    );

    int seq = 0;
    void settle({
      required DocType type,
      required String partyId,
      required int cents,
      required String targetId,
    }) {
      final RuleOutcome outcome = engine.dispatch(
        document: Document(
          id: newId(),
          docNo: 'MIX-${++seq}',
          docType: type,
          status: DocStatus.confirmed,
          partyId: partyId,
          accountId: 'acc1',
          totalAmount: cents,
          occurredAt: t,
          createdAt: t,
          updatedAt: t,
        ),
        allocations: <Allocation>[
          Allocation(targetDocId: targetId, amount: cents),
        ],
        now: t,
      );
      expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
    }

    settle(
      type: DocType.payment,
      partyId: 'p1',
      cents: 1000,
      targetId: idOf(saleReturn.docNo),
    );
    settle(
      type: DocType.receipt,
      partyId: 'p2',
      cents: 2000,
      targetId: idOf(purchaseReturn.docNo),
    );

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
      makeLedger(source);
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
      makeLedger(source);
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
      makeLedger(source);
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
      makeLedger(source, docs: 200);
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
      makeLedger(source);
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
      makeLedger(source, docs: 50);
      final int size = File(source).lengthSync();
      // ⚠️ 页大小必须从文件头读（偏移 16..17，大端），**不能假设 4096**。
      final RandomAccessFile head = File(source).openSync();
      final List<int> first = head.readSync(100);
      head.closeSync();
      final int pageSize = (first[16] << 8) | first[17];
      final int pages = size ~/ pageSize;

      // 坏**中后段四页**：只坏一页时它可能正好落在空闲页 / 被砍掉的索引上，
      // 读数据根本不碰它（实测踩到过）。坏根页又会让 SQLite 静默返回空表
      // （那就成了「整份读不出」），所以取中后段的四页。
      for (final int target in <int>[
        pages ~/ 2,
        pages * 3 ~/ 5,
        pages * 4 ~/ 5,
        pages - 2,
      ]) {
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
      makeLedger(source);
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
      final List<String> ids = makeLedger(source, docs: 10);
      final String target = ids[4];
      final String targetNo = docNoOf(target);
      // 删掉第 5 单的全部明细 —— 模拟「明细那几行落在坏页上」
      final Db db = Db.open(source);
      db.raw.execute(
        'DELETE FROM document_lines WHERE document_id = ?',
        <Object?>[target],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.totalDocuments, 10);
      expect(report.importedDocuments, 9);
      expect(report.issues.length, 1);
      expect(report.issues.single.docNo, targetNo);
      expect(report.issues.single.kind, RescueIssueKind.missingLines);
      expect(report.issues.single.summary, contains('明细'));

      // 新库里没有那张不完整的单 —— 账不能不平
      final Db out = Db.open(report.outputPath!);
      final int n =
          out.raw
                  .select(
                    'SELECT COUNT(*) FROM documents WHERE id = ?',
                    <Object?>[target],
                  )
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
      final List<String> ids = makeLedger(source, docs: 1);
      final Db db = Db.open(source);
      db.raw.execute(
        'DELETE FROM stock_ledger WHERE id = '
        '(SELECT id FROM stock_ledger WHERE document_id = ? '
        ' ORDER BY id LIMIT 1)',
        <Object?>[ids.single],
      );
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
      final List<String> ids = makeLedger(source, docs: 1);
      final Db db = Db.open(source);
      // 单据金额 2000，往来冲减却被写成 1000（模拟坏页只救回一部分 / 数据被改）
      db.raw.execute(
        'UPDATE party_ledger SET amount = 1000 WHERE document_id = ?',
        <Object?>[ids.single],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.issues.length, 1, reason: '往来冲减 ≠ 单据金额 ⇒ 欠款会算错，不能当完整');
    });

    test('正常的收款单**不能**被判不完整（用户审查 2026-10-30 的 P0）', () async {
      // 真实引擎的收款单：`total_amount` = 2000、`paid_amount` = **0**、
      // 资金流水挂在它自己身上 = 2000。旧判据拿「资金流水 vs paid_amount」
      // 一比就是 2000 ≠ 0 ⇒ **每一张正常收款单都被判不完整**。
      //
      // 这条用例是那处 bug 的回归钉：夹具用真实 `SaleService` 生成，
      // 不改任何数据，必须全部完整。
      final List<String> ids = makeLedger(source, docs: 3, paid: true);
      expect(ids.length, 3);

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.issues, isEmpty, reason: '一份刚由神算子自己生成的账本，抢救不能挑出任何毛病');
      expect(report.importedDocuments, 6, reason: '3 张销售单 + 3 张自动生成的收款单');
    });

    test('收款单的资金流水金额与单据金额不符 ⇒ 两端都不完整', () async {
      final List<String> ids = makeLedger(source, docs: 1, paid: true);
      final Db db = Db.open(source);
      // 收款单 total_amount = 2000，资金流水被改成 1000
      db.raw.execute(
        'UPDATE money_ledger SET amount = 1000 '
        "WHERE document_id IN (SELECT id FROM documents WHERE doc_type = 'receipt')",
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.importedDocuments, 0, reason: '钱和单对不上，两边都不能导');
      expect(
        report.issues.where(
          (RescueIssue i) => i.kind == RescueIssueKind.brokenSettlement,
        ),
        isNotEmpty,
        reason: '销售单本身没毛病，但它的收款记录坏了 —— 必须一起拦下',
      );
      expect(ids.length, 1);
    });

    test('赊账单的往来流水**整张丢失** ⇒ 不完整（用户审查的 P0）', () async {
      // 从前 `party.isEmpty` 直接返回「不适用」⇒ 库存行数过、资金检查过
      // ⇒ 判完整导入。结果：货恢复了、单据恢复了、客户欠款不见了。
      final List<String> ids = makeLedger(source, docs: 2);
      final Db db = Db.open(source);
      db.raw.execute(
        'DELETE FROM party_ledger WHERE document_id = ?',
        <Object?>[ids.first],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.importedDocuments, 1);
      expect(
        report.issues.single.kind,
        RescueIssueKind.missingLedger,
        reason: '有往来方却一条往来流水都没有 ⇒ 欠款会凭空消失',
      );
      expect(report.issues.single.detail, contains('欠款'));
    });

    test('没有任何流水的单据也算不完整（库存/往来会不准）', () async {
      final List<String> ids = makeLedger(source, docs: 5);
      final Db db = Db.open(source);
      // 把第 2 单的库存与往来流水都删掉
      db.raw.execute(
        'DELETE FROM stock_ledger WHERE document_id = ?',
        <Object?>[ids[1]],
      );
      db.raw.execute(
        'DELETE FROM party_ledger WHERE document_id = ?',
        <Object?>[ids[1]],
      );
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

    test('库存流水数量与明细对不上（行数却相等）⇒ 不完整', () async {
      // 用户审查 2026-10-30（P1）：只比行数时「1 行明细 1 瓶 / 1 条流水 -1 瓶」
      // 之外的形态抓不住 —— 这里把流水数量改成 -2，行数仍是 1。
      final List<String> ids = makeLedger(source, docs: 1);
      final Db db = Db.open(source);
      db.raw.execute(
        'UPDATE stock_ledger SET quantity = -2 WHERE id = '
        '(SELECT id FROM stock_ledger WHERE document_id = ? ORDER BY id LIMIT 1)',
        <Object?>[ids.single],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.issues.single.kind,
        RescueIssueKind.missingLedger,
        reason: '行数相等、数量不等 ⇒ 库存照样会错',
      );
      expect(report.issues.single.detail, contains('数量'));
    });

    test('库存流水里有、明细里没有的商品 ⇒ 不完整', () async {
      // 旧判据只遍历「明细里的商品」，多出来的流水商品根本不看。
      final List<String> ids = makeLedger(source, docs: 1);
      final Db db = Db.open(source);
      db.raw.execute(
        "INSERT INTO products (id, code, name, unit, sell_price, cost_price, "
        "safety_stock, is_active, created_at, updated_at) "
        "VALUES ('prod2', 'P0002', '雪碧', '瓶', 1000, 800, 0, 1, 0, 0)",
      );
      db.raw.execute(
        "INSERT INTO stock_ledger (id, product_id, document_id, quantity, "
        "unit_cost, total_cost, seq_no, occurred_at, created_at) "
        "VALUES ('ghost-stock', 'prod2', ?, -1, 800, 800, 9999, 0, 0)",
        <Object?>[ids.single],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.issues.single.kind,
        RescueIssueKind.missingLedger,
        reason: '这条流水找不到对应的明细行 ⇒ 导入它库存会凭空变',
      );
    });

    test('收款单整张没读到 ⇒ 它核销的那张销售单也不完整（双端）', () async {
      // 用户审查 2026-10-30（P0）：从前写新库时只把核销关系过滤掉，
      // 销售单照旧导入 ⇒ 账上「已收 20」但没有任何收款记录。
      final List<String> ids = makeLedger(source, docs: 2, paid: true);
      // 关外键：`settlements` 指着这张收款单，不关就删不掉 —— 而现实里
      // 「单据那一行落在坏页上」正是这种「指着空气」的形态。
      final Db db = Db.open(source, foreignKeys: false);
      final String receiptId =
          db.raw.select(
                'SELECT id FROM documents WHERE doc_type = ? LIMIT 1',
                <Object?>['receipt'],
              ).first['id']!
              as String;
      // 模拟「收款单那一行落在坏页上」
      db.raw.execute('DELETE FROM documents WHERE id = ?', <Object?>[
        receiptId,
      ]);
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.issues.where(
          (RescueIssue i) => i.kind == RescueIssueKind.brokenSettlement,
        ),
        isNotEmpty,
        reason: '收款单没了，销售单的「已收」就无从核对 —— 不能单独导入',
      );
      expect(
        report.importedDocuments,
        lessThan(4),
        reason: '另一端也不许导入（2 张销售 + 1 张收款正常，另一端的销售要拦下）',
      );
      expect(ids.length, 2);
    });

    test('盘点单：数量无变化 ⇒ 不产生库存流水，仍算**完整**（反例）', () async {
      // 用户裁定补充里的反例：盘点的零差额**本来就不写库存流水**，
      // 所以不能要求「每行明细都有流水」—— 那样每张没差异的盘点单都会被误判。
      makeLedger(source, docs: 0);
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
      makeLedger(source, docs: 5);
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
      final List<String> ids = makeLedger(source, docs: 3);
      // 关外键：模拟「商品那几行落在坏页上、单据还指着它」的形态
      final Db db = Db.open(source, foreignKeys: false);
      // 第 1 单引用一个不存在的商品（模拟商品那几行没救回来）
      db.raw.execute(
        "UPDATE document_lines SET product_id = 'ghost' WHERE document_id = ?",
        <Object?>[ids.first],
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

    test('**混合业务**的真实账本（采购/部分收款/两种延迟退款）⇒ 全部完整', () async {
      // 用户审查 2026-10-30 §四：只验「销售 + 自动收款」不能推断采购、
      // 采购退货、延迟退款这些**方向相反**的路径也通过。
      // 这是一份刚由神算子自己生成的合法账本，抢救不能挑出任何毛病。
      makeMixedLedger(source);
      final RescueReport report = await rescue();

      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.issues,
        isEmpty,
        reason:
            '采购退货的往来与资金方向都跟销售退货相反 —— '
            '判据如果只想着销售，这里就会误杀',
      );
      expect(
        report.importedDocuments,
        8,
        reason: '采购 + 付款 + 销售 + 收款 + 销售退货 + 退款 + 采购退货 + 收款',
      );
    });

    test('盘点：**有差额**、流水完整 ⇒ 完整', () async {
      makeLedger(source, docs: 0);
      makeStocktake(source, actual: 5); // 账面 0、实际 5 ⇒ 差额 +5，写一条流水
      final RescueReport report = await rescue();

      expect(report.ok, isTrue, reason: report.failure);
      expect(report.issues, isEmpty);
      expect(report.importedDocuments, 1);
    });

    test('盘点：流水条数**多于**明细 ⇒ 不完整', () async {
      // 一条明细最多产生一条流水，所以「流水比明细多」一定是坏的。
      makeLedger(source, docs: 0);
      final String stk = makeStocktake(source, actual: 5);
      final Db db = Db.open(source);
      db.raw.execute(
        'INSERT INTO stock_ledger (id, product_id, document_id, quantity, '
        'unit_cost, total_cost, seq_no, occurred_at, created_at) '
        "VALUES ('dup-stock', 'prod1', ?, 1, 800, 800, 9998, 0, 0)",
        <Object?>[stk],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.issues.single.kind,
        RescueIssueKind.missingLedger,
        reason: '两条流水对着一行明细 ⇒ 有一条找不到出处',
      );
    });

    test('**明细与对应流水一起丢** ⇒ 不完整（明细金额合计 ≠ 单据总额）', () async {
      // 用户审查 2026-10-30（P0）的复现场景：两行各 ¥10 的销售单，
      // 第一行明细**和**它的库存流水一起没救出来。剩下的数据「局部完全自洽」：
      //   明细 1 行 / 流水 1 行、数量 1 / 1、往来 ¥20 = 单据 ¥20、核销也对得上
      // ⇒ 行数、数量、往来、资金四项全过，但单据 ¥20 只剩 ¥10 的明细。
      //
      // 只有「明细金额合计 = 单据总额」这条不变量能抓住它。
      final List<String> ids = makeLedger(source, docs: 1);
      final Db db = Db.open(source);
      db.raw.execute(
        'DELETE FROM document_lines WHERE id = '
        '(SELECT id FROM document_lines WHERE document_id = ? '
        ' ORDER BY id LIMIT 1)',
        <Object?>[ids.single],
      );
      db.raw.execute(
        'DELETE FROM stock_ledger WHERE id = '
        '(SELECT id FROM stock_ledger WHERE document_id = ? '
        ' ORDER BY id LIMIT 1)',
        <Object?>[ids.single],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.importedDocuments,
        0,
        reason: '单据 ¥20、明细只剩 ¥10 —— 导入它就是把金额改小了一半',
      );
      expect(report.issues.single.kind, RescueIssueKind.missingLines);
      expect(report.issues.single.detail, contains('金额'));
    });

    test('未知单据类型 ⇒ 进待确认，**不导入**', () async {
      // 抢救器不知道新类型的业务语义，就不该擅自把它当成已恢复完整的业务记录。
      // 从前 `type == null` ⇒ `expectsLines = false` ⇒ 明细/库存/核销三项检查
      // 全部跳过，一张空壳单据可能被当成「完整」导进新库。
      makeLedger(source, docs: 1);
      final Db db = Db.open(source);
      final int at = DateTime(2026, 10, 2).millisecondsSinceEpoch;
      db.raw.execute(
        'INSERT INTO documents (id, doc_no, doc_type, status, total_amount, '
        'paid_amount, occurred_at, time_estimated, created_at, updated_at, '
        'business_day) VALUES (?,?,?,?,0,0,?,0,?,?,?)',
        <Object?>[
          'future-1',
          'FUTURE-1',
          'future_type',
          'confirmed',
          at,
          at,
          at,
          businessDayOf(at),
        ],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.issues.map((RescueIssue i) => i.docId),
        contains('future-1'),
        reason: '不认识的类型必须让用户自己判断',
      );
      expect(report.importedDocuments, 1, reason: '只导入那张正常的销售单');
    });

    test('往来流水的**往来方**与单据不一致 ⇒ 不完整（欠款挂错人）', () async {
      makeLedger(source, docs: 1);
      final Db db = Db.open(source);
      db.raw.execute(
        "INSERT INTO parties (id, name, roles, created_at, updated_at) "
        "VALUES ('p2', '客户乙', '[\"customer\"]', 0, 0)",
      );
      // 模拟损坏把往来方改成了另一个**仍然存在**的客户：
      // 金额仍然对得上，`_firstMissingRef` 只看单据自己的 party_id ⇒ 全过。
      db.raw.execute("UPDATE party_ledger SET party_id = 'p2'");
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.importedDocuments, 0, reason: '这笔欠款会被记到另一个客户名下 —— 比丢数据更糟');
      expect(report.issues.single.kind, RescueIssueKind.missingLedger);
    });

    test('资金流水的**账户**不存在 ⇒ 不完整（不能等写库时外键报错）', () async {
      makeLedger(source, docs: 1, paid: true);
      // 关外键：这个 UPDATE 本身就会被外键拦住 —— 而坏页不管外键，
      // 它只会把字节改掉。这正是「抢救要自己复核引用」的理由。
      final Db db = Db.open(source, foreignKeys: false);
      db.raw.execute("UPDATE money_ledger SET account_id = 'ghost-account'");
      db.close();

      final RescueReport report = await rescue();
      expect(
        report.ok,
        isTrue,
        reason:
            '不能让它拖到写新库时被外键顶回来 —— 那时整次抢救都失败了，'
            '用户连其余能救的单据都拿不到',
      );
      expect(
        report.issues.map((RescueIssue i) => i.docId),
        isNotEmpty,
        reason: '账户不存在的收付款单必须进待确认',
      );
    });

    test('销售单的库存流水**方向反了**（−1 变 +1）⇒ 不完整', () async {
      // 用户审查 2026-10-30（P0）：符号不是格式，是业务含义本身。
      // 卖出 1 瓶 → 库存 −1；坏页把它变成 +1，绝对值一模一样，
      // 恢复出来却是「卖了 1 瓶、库存还多了 1 瓶」。
      final List<String> ids = makeLedger(source, docs: 1);
      final Db db = Db.open(source);
      db.raw.execute(
        'UPDATE stock_ledger SET quantity = -quantity WHERE document_id = ?',
        <Object?>[ids.single],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.importedDocuments, 0, reason: '出库变成入库，账反了');
      expect(report.issues.single.detail, contains('方向'));
    });

    test('采购单的库存流水**方向反了**（+10 变 −10）⇒ 不完整', () async {
      makeMixedLedger(source);
      final Db db = Db.open(source);
      final String purchaseId =
          db.raw.select(
                'SELECT id FROM documents WHERE doc_type = ? LIMIT 1',
                <Object?>['purchase'],
              ).first['id']!
              as String;
      db.raw.execute(
        'UPDATE stock_ledger SET quantity = -quantity WHERE document_id = ?',
        <Object?>[purchaseId],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.issues.map((RescueIssue i) => i.docId),
        contains(purchaseId),
        reason: '入库变成出库 —— 跟销售单反过来，判据不能只想着一边',
      );
    });

    test('销售单的往来流水**方向反了**（+2000 变 −2000）⇒ 不完整', () async {
      // 客户欠我 ¥20 → 变成我欠客户 ¥20。金额绝对值不变，语义完全相反。
      final List<String> ids = makeLedger(source, docs: 1);
      final Db db = Db.open(source);
      db.raw.execute(
        'UPDATE party_ledger SET amount = -amount WHERE document_id = ?',
        <Object?>[ids.single],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.importedDocuments, 0);
      expect(report.issues.single.detail, contains('方向'));
    });

    test('收款单的资金流水**方向反了**（+ 变 −）⇒ 不完整', () async {
      makeLedger(source, docs: 1, paid: true);
      final Db db = Db.open(source);
      db.raw.execute(
        'UPDATE money_ledger SET amount = -amount '
        "WHERE document_id IN (SELECT id FROM documents WHERE doc_type = 'receipt')",
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.importedDocuments, 0, reason: '收款记成付款，账户余额会反着算');
    });

    test('付款单的资金流水**方向反了**（− 变 +）⇒ 不完整', () async {
      makeMixedLedger(source);
      final Db db = Db.open(source);
      final String paymentId =
          db.raw.select(
                'SELECT id FROM documents WHERE doc_type = ? LIMIT 1',
                <Object?>['payment'],
              ).first['id']!
              as String;
      db.raw.execute(
        'UPDATE money_ledger SET amount = -amount WHERE document_id = ?',
        <Object?>[paymentId],
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.issues.map((RescueIssue i) => i.docId),
        contains(paymentId),
        reason: '付款记成收款 —— 与收款单方向相反',
      );
    });

    test('收款单**缺往来方 / 账户** ⇒ 不完整（规则层本来就要求必填）', () async {
      // 用户审查 2026-10-30（P1）：`_settle()` 明确要求收付款单必须同时有
      // `account_id` 与 `party_id`。损坏把这两列置空之后：
      //   · `_firstMissingRef` 不会把 NULL 当缺失
      //   · `_ledgerRefProblem` 因为单据字段为空，不做一致性比较
      //   · `_partyProblem` 把「没有往来方」当成「散客，不适用」
      // ⇒ 一张违反规则层必填约束的收款单可能被导入。
      makeLedger(source, docs: 1, paid: true);
      final Db db = Db.open(source);
      db.raw.execute(
        "UPDATE documents SET party_id = NULL, account_id = NULL "
        "WHERE doc_type = 'receipt'",
      );
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.importedDocuments, 0, reason: '收付款单没有往来方和账户，业务上根本不存在这种单');
      expect(report.issues, isNotEmpty);
    });

    test('**核销记录本身**丢失（两端单据都还在）⇒ 两端都被拦下', () async {
      // 用户审查 2026-10-30 §三：传播靠「读到的核销关系」，所以某条核销
      // **本身没读出来**时，传播这条路走不通 —— 得靠各端自己的核对：
      //   · 收款单：核销合计 0 ≠ 本单金额 ¥20 ⇒ 不完整
      //   · 销售单：`settlements` 合计 0 ≠ `paid_amount` ¥20 ⇒ 不完整
      // 两条都命中，两端自然都进不了新库。
      //
      // ⚠️ 这条**不是**在测传播（传播由「收款单整张没读到」那条钉住）。
      // 它测的是「核销行没了」这种更隐蔽的形态：关系不在了，只能靠
      // 金额对不上来发现 —— 所以 `_settlementProblem()` 不能省。
      makeLedger(source, docs: 1, paid: true);
      final Db db = Db.open(source);
      db.raw.execute('DELETE FROM settlements');
      db.close();

      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(
        report.importedDocuments,
        0,
        reason: '收款单核销合计变成 0、销售单的核销合计也变成 0 ⇒ 两边都不完整',
      );
      expect(report.issues.length, 2, reason: '收款单 + 销售单，各被自己的核对拦下');
      expect(
        report.issues.where(
          (RescueIssue i) => (i.detail ?? '').contains('核销记录'),
        ),
        isNotEmpty,
        reason: '销售单那端的说明要指向「核销记录对不上」，而不是笼统说「流水缺失」',
      );
    });
  });

  // ============================================================ WAL（裁定补充 ①）
  group('WAL', () {
    /// 造一个「主文件 100 单 + wal 里 20 单」的库，返回时**源库仍开着**
    /// （一关就会 checkpoint，wal 就空了 —— 这正是崩溃现场的形态）。
    Database makeWithPendingWal(String path) {
      makeLedger(path, docs: 100);
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
            // ⚠️ 赊账（`paid_amount = 0`）：这里的 20 单只造了「明细 + 库存流水」，
            // 没有自动生成的收款单与核销记录。若写成「已收 2000」，
            // 新的资金判据（核销合计必须 = paid_amount）会正确地判它们不完整，
            // 断言 120 就会失败 —— 而失败原因是夹具不是完整业务单元，不是 WAL 没救回来。
            0,
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
          // ⚠️ 明细金额必须 = 单据总额（2000）：新加的「明细金额合计」
          // 判据会正确地判它不完整，断言 120 就会失败 —— 而原因是夹具不完整。
          <Object?>['$did-l0', did, 'prod1', 1, 2000, 2000],
        );
        raw.execute(
          'INSERT INTO stock_ledger (id, product_id, document_id, quantity, '
          'unit_cost, total_cost, seq_no, occurred_at, created_at) '
          'VALUES (?,?,?,?,?,?,?,?,?)',
          <Object?>['$did-s', 'prod1', did, -1, 1000, 1000, 1000 + i, at, at],
        );
        // 赊账 ⇒ 往来流水挂在销售单上（与 `RuleEngine._sale` 一致：+total_amount）
        raw.execute(
          'INSERT INTO party_ledger (id, party_id, document_id, amount, '
          'seq_no, occurred_at, created_at) VALUES (?,?,?,?,?,?,?)',
          <Object?>['$did-p', 'p1', did, 2000, 1000 + i, at, at],
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
      makeLedger(source);
      final RescueReport report = await rescue();
      expect(report.ok, isTrue, reason: report.failure);
      expect(report.walCopied, isFalse);
      expect(report.totalDocuments, 20);
    });
  });

  // ============================================================ 报告文案
  group('报告文案（用户补充建议第 2 条：不许出现 SQL 术语）', () {
    test('按类型统计用的是中文名，不是表名', () async {
      makeLedger(source, docs: 6);
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
      makeLedger(source, docs: 2);
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
