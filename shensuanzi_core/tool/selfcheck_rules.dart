// 规则层自检：`dart run tool/selfcheck_rules.dart`
//
// 与 `test/rule_engine_test.dart` 断言等价，用进程内断言实现 ——
// 因为本机 `dart test` 无法启动测试运行器（见 `docs/testing.md` §零）。
// **`test/` 才是正式测试，本脚本是烟雾自检。**
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**，失败可复现。

import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'sqlite_local.dart';

int _passed = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void section(String title) => stdout.writeln('\n[$title]');

int _clock = 1700000000000;
int now() => _clock++;

bool throws(void Function() body) {
  try {
    body();
    return false;
  } catch (_) {
    return true;
  }
}

late Db db;
late RuleEngine engine;
late ProductDao products;
late PartyDao parties;
late DocumentDao documents;
late StockLedgerDao stock;
late PartyLedgerDao partyLedger;

/// 默认供应商 —— 供 `purchase()` 兜底。
/// 方案 C 起：**有欠款就必须有 party_id**，否则欠款无处记录。
String supplierId = '';

String createProduct({String code = 'P001'}) {
  final int t = now();
  final Product p = Product(
    id: newId(),
    code: code,
    name: '商品-$code',
    createdAt: t,
    updatedAt: t,
  );
  products.insert(p);
  return p.id;
}

String createParty() {
  final int t = now();
  final Party p = Party(
    id: newId(),
    name: '供应商甲',
    roles: const <PartyRole>[PartyRole.supplier],
    createdAt: t,
    updatedAt: t,
  );
  parties.insert(p);
  return p.id;
}

Document pendingDoc({
  required DocType type,
  String? partyId,
  int totalAmount = 0,
}) => Document(
  id: newId(),
  docNo: '${Document.pendingDocNoPrefix}abc123',
  docType: type,
  status: DocStatus.confirmed,
  partyId: partyId,
  totalAmount: totalAmount,
  occurredAt: now(),
  createdAt: now(),
  updatedAt: now(),
);

int countOf(String table) =>
    db.raw.select('SELECT COUNT(*) AS c FROM $table').first['c']! as int;

RuleOutcome purchase(String productId, {int quantity = 10, int unitPrice = 100, String? partyId, int? total}) {
  final int amount = quantity * unitPrice;
  final Document doc = pendingDoc(
    type: DocType.purchase,
    partyId: partyId ?? supplierId,
    totalAmount: total ?? amount,
  );
  return engine.dispatch(
    document: doc,
    lines: <DocumentLine>[
      DocumentLine.create(
        documentId: doc.id,
        productId: productId,
        quantity: quantity,
        unitPrice: unitPrice,
      ),
    ],
    now: now(),
  );
}

RuleOutcome stocktake(String productId, int actual) {
  final Document doc = pendingDoc(type: DocType.stocktake, totalAmount: 0);
  return engine.dispatch(
    document: doc,
    stocktakeActual: <String, int>{productId: actual},
    now: now(),
  );
}

void main() {
  useLocalSqlite();
  db = Db.openInMemory();
  engine = RuleEngine(db);
  products = ProductDao(db);
  parties = PartyDao(db);
  documents = DocumentDao(db);
  stock = StockLedgerDao(db);
  partyLedger = PartyLedgerDao(db);

  // ---------------------------------------------------------- RULE-001
  section('RULE-001 采购入库');
  final String p1 = createProduct(code: 'P001');
  final String sup1 = createParty();
  supplierId = sup1;
  final RuleOutcome r1 = purchase(p1, quantity: 10, unitPrice: 100, partyId: sup1);
  check('返回 applied', r1.status == RuleStatus.applied, '${r1.status} ${r1.reason}');
  check('库存 = 10', stock.stockOf(p1) == 10, '${stock.stockOf(p1)}');
  final StockLedger first = stock.ofProduct(p1).single;
  check('total_cost = 1000', first.totalCost == 1000, '${first.totalCost}');
  check('unit_cost 派生为 100', first.unitCostValue == 100, '${first.unitCostValue}');
  check('seq_no 从 1 起', first.seqNo == 1, '${first.seqNo}');
  check('往来 = -1000（我欠供应商）', partyLedger.balanceOf(sup1) == -1000);
  check('不生成资金流水', countOf('money_ledger') == 0);

  final String docNo = r1.document!.docNo;
  check('主机分配正式单号（CG 前缀 + 日期 + 序号）',
      docNo.startsWith('CG') && docNo.endsWith('-001') && !Document.isPendingDocNo(docNo),
      docNo);
  check('临时展示号已被替换',
      documents.findById(r1.document!.id)!.docNo == docNo);

  section('RULE-001 幂等与拒绝');
  final Document dup = pendingDoc(
    type: DocType.purchase,
    partyId: sup1,
    totalAmount: 100,
  );
  final RuleOutcome dupOutcome = engine.dispatch(
    document: dup,
    lines: <DocumentLine>[
      DocumentLine.create(
        documentId: dup.id,
        productId: p1,
        quantity: 1,
        unitPrice: 100,
      ),
    ],
    now: now(),
  );
  check('首次 applied', dupOutcome.status == RuleStatus.applied);
  check('二次 alreadyExists', engine.dispatch(
        document: dup,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: dup.id,
            productId: p1,
            quantity: 1,
            unitPrice: 100,
          ),
        ],
        now: now(),
      ).status == RuleStatus.alreadyExists);
  check('幂等未重复写流水', stock.ofProduct(p1).length == 2, '${stock.ofProduct(p1).length}');
  check('幂等未重复加库存', stock.stockOf(p1) == 11, '${stock.stockOf(p1)}');

  final String p2 = createProduct(code: 'P002');
  final int docsBeforeMismatch = countOf('documents');
  final RuleOutcome mismatch = purchase(p2, quantity: 10, unitPrice: 100, total: 999);
  check('明细与总额不符 → rejected', mismatch.status == RuleStatus.rejected);
  check('拒绝原因指向不变量 B5',
      mismatch.reason?.contains('不变量 B5') ?? false, '${mismatch.reason}');
  check('整单回滚：单据未落库', countOf('documents') == docsBeforeMismatch,
      '${countOf('documents')} vs $docsBeforeMismatch');
  check('整单回滚：库存未变', stock.stockOf(p2) == 0);

  final String p3 = createProduct(code: 'P003');
  final Document zero = pendingDoc(type: DocType.purchase, totalAmount: 0);
  final RuleOutcome zeroOutcome = engine.dispatch(
    document: zero,
    lines: <DocumentLine>[
      DocumentLine.create(
        documentId: zero.id,
        productId: p3,
        quantity: 0,
        unitPrice: 100,
      ),
    ],
    now: now(),
  );
  check('数量为 0 → rejected', zeroOutcome.status == RuleStatus.rejected);

  final String p4 = createProduct(code: 'P004');
  // 方案 C：有欠款就必须有 party_id（否则主单的往来流水被跳过，欠款凭空消失）
  final Document noPartyDoc = pendingDoc(type: DocType.purchase, totalAmount: 100);
  final RuleOutcome noParty = engine.dispatch(
    document: noPartyDoc,
    lines: <DocumentLine>[
      DocumentLine.create(
        documentId: noPartyDoc.id,
        productId: p4,
        quantity: 1,
        unitPrice: 100,
      ),
    ],
    now: now(),
  );
  check('有欠款但无 party_id → rejected', noParty.status == RuleStatus.rejected);
  check('拒绝原因指向 party_id',
      noParty.reason?.contains('party_id') ?? false, '${noParty.reason}');

  // 内联构造 Document（不走 pendingDoc）时也必须带 party_id ——
  // 这正是漏改过两次的形状，所以在这里钉住。
  final String pKeep = createProduct(code: 'P010');
  final Document keepNoDoc = Document(
    id: newId(),
    docNo: 'CG20260101-042',
    docType: DocType.purchase,
    status: DocStatus.confirmed,
    partyId: supplierId,
    totalAmount: 100,
    occurredAt: now(),
    createdAt: now(),
    updatedAt: now(),
  );
  final RuleOutcome keepNo = engine.dispatch(
    document: keepNoDoc,
    lines: <DocumentLine>[
      DocumentLine.create(
        documentId: keepNoDoc.id,
        productId: pKeep,
        quantity: 1,
        unitPrice: 100,
      ),
    ],
    now: now(),
  );
  check('已给定正式单号时原样保留', keepNo.document?.docNo == 'CG20260101-042',
      '${keepNo.document?.docNo} / ${keepNo.reason}');
  check('内联构造的单据也能落库', keepNo.status == RuleStatus.applied,
      '${keepNo.reason}');

  // ---------------------------------------------------------- RULE-009
  section('RULE-009 盘点');
  final String p5 = createProduct(code: 'P005');
  purchase(p5, quantity: 10, unitPrice: 100);
  // 捕获点必须在「种子采购」之后 —— 采集它自己会写一条往来流水
  final int partyRowsBefore = countOf('party_ledger');
  final int moneyRowsBefore = countOf('money_ledger');
  final RuleOutcome surplus = stocktake(p5, 12);
  check('盘盈 applied', surplus.status == RuleStatus.applied, '${surplus.reason}');
  check('盘点后库存 = 实际数量 12', stock.stockOf(p5) == 12, '${stock.stockOf(p5)}');
  final StockLedger surplusRow = stock.ofProduct(p5).last;
  check('盘盈 diff = +2', surplusRow.quantity == 2, '${surplusRow.quantity}');
  check('盘盈成本 = 200（当前均价 100 × 2）', surplusRow.totalCost == 200, '${surplusRow.totalCost}');

  final RuleOutcome shortage = stocktake(p5, 10);
  check('盘亏 applied', shortage.status == RuleStatus.applied, '${shortage.reason}');
  check('盘亏后库存 = 10', stock.stockOf(p5) == 10, '${stock.stockOf(p5)}');
  final StockLedger shortageRow = stock.ofProduct(p5).last;
  check('盘亏 diff = -2', shortageRow.quantity == -2, '${shortageRow.quantity}');
  check('盘亏成本 = -200（1200 / 12 × -2）', shortageRow.totalCost == -200, '${shortageRow.totalCost}');

  final RuleOutcome noDiff = stocktake(p5, 10);
  check('diff = 0 时 applied 但不产生流水',
      noDiff.status == RuleStatus.applied && stock.ofProduct(p5).length == 3,
      '${stock.ofProduct(p5).length}');

  check('盘点不生成资金流水', countOf('money_ledger') == moneyRowsBefore,
      '${countOf('money_ledger')} vs $moneyRowsBefore');
  check('盘点不生成往来流水', countOf('party_ledger') == partyRowsBefore,
      '${countOf('party_ledger')} vs $partyRowsBefore');

  final Document badStocktake = pendingDoc(type: DocType.stocktake, totalAmount: 500);
  check('盘点 total_amount != 0 → rejected',
      engine.dispatch(
        document: badStocktake,
        stocktakeActual: <String, int>{p5: 1},
        now: now(),
      ).status == RuleStatus.rejected);

  // ------------------------------------------- 成本精度（round-half-up）
  section('成本精度：round-half-up 而非截断');
  final String p6 = createProduct(code: 'P006');
  final Document multi = pendingDoc(
    type: DocType.purchase,
    partyId: sup1,
    totalAmount: 302,
  );
  engine.dispatch(
    document: multi,
    lines: <DocumentLine>[
      for (final int price in <int>[100, 101, 101])
        DocumentLine.create(
          documentId: multi.id,
          productId: p6,
          quantity: 1,
          unitPrice: price,
        ),
    ],
    now: now(),
  );
  check('入库总额 302 / 3 件', stock.costSnapshotOf(p6).totalCost == 302);
  stocktake(p6, 2);
  final StockLedger roundedRow = stock.ofProduct(p6).last;
  check('-302/3 取 -101（半数远离零）', roundedRow.totalCost == -101, '${roundedRow.totalCost}');
  check('若用 ~/ 截断会得到 -100', (-302) ~/ 3 == -100);

  // ---------------------------------------------------------- 分派边界
  section('dispatch 边界');
  final RuleOutcome transfer = engine.dispatch(
    document: pendingDoc(type: DocType.transfer),
    now: now(),
  );
  check('transfer → rejected', transfer.status == RuleStatus.rejected);
  check('拒绝原因指向「尚未实现」',
      transfer.reason?.contains('尚未实现') ?? false, '${transfer.reason}');

  // 用**差集**而不是硬编码列举：将来新增 doc_type 时会在这里失败。
  // delivery / sale_return / purchase_return 的细则见
  // selfcheck_delivery.dart / selfcheck_returns.dart。
  final Set<DocType> notImplemented = DocType.values.toSet()
    ..removeAll(<DocType>{
      DocType.purchase,
      DocType.sale,
      DocType.delivery,
      DocType.saleReturn,
      DocType.purchaseReturn,
      DocType.stocktake,
      DocType.receipt,
      DocType.payment,
    });
  check('唯一未实现的 doc_type 是 transfer',
      notImplemented.length == 1 && notImplemented.first == DocType.transfer,
      '$notImplemented');

  // ---------------------------------------------------------- 不变量
  section('不变量');
  final int sumQty = db.raw
      .select('SELECT COALESCE(SUM(quantity), 0) AS s FROM stock_ledger WHERE product_id = ?', <Object?>[p1])
      .first['s']! as int;
  check('库存 = SUM(stock_ledger.quantity)', stock.stockOf(p1) == sumQty);
  final int sumParty = db.raw
      .select('SELECT COALESCE(SUM(amount), 0) AS s FROM party_ledger WHERE party_id = ?', <Object?>[sup1])
      .first['s']! as int;
  check('往来余额 = SUM(party_ledger.amount)', partyLedger.balanceOf(sup1) == sumParty);

  // ---------------------------------------------------------- 事务硬约束
  section('事务硬约束');
  check('SeqCounter 事务外调用 → StateError', throws(() => SeqCounter(db).nextStock()));
  check('DocNoGenerator 事务外调用 → StateError',
      throws(() => DocNoGenerator(db).next(DocType.purchase, occurredAtMs: now())));
  check('dispatch 结束后不残留事务', !db.inTransaction);

  db.close();

  stdout.writeln('\n${'=' * 46}');
  if (_failures.isEmpty) {
    stdout.writeln('全部通过：$_passed 项');
    exit(0);
  }
  stdout.writeln('通过 $_passed 项，失败 ${_failures.length} 项：');
  for (final String failure in _failures) {
    stdout.writeln('  - $failure');
  }
  exit(1);
}
