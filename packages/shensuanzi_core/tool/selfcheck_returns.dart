// R-11 自检：`dart run tool/selfcheck_returns.dart`
//
// 覆盖 RULE-007 销售退货 / RULE-008 采购退货，重点是 **成本分摊**（R-11 裁定 · 方案 A）。
// 与 `test/return_test.dart` 断言等价 —— 本机 `dart test` 无法编译测试文件
// （`test_core` 编译内核时要用 `frontend_server` 子进程，见 `docs/testing.md` §零）。
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**，失败可复现。
//
// 组织方式：**每个场景一个全新的内存库** —— 退货分摊依赖「前序退货」，
// 共用一个库会让断言顺序耦合。

import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:shensuanzi_core/sqlite_local.dart';

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

// ---------------------------------------------------------------- 共享状态

late Db db;
late RuleEngine engine;
late ProductDao products;
late DocumentDao documents;
late StockLedgerDao stock;
late MoneyLedgerDao money;
late PartyLedgerDao partyLedger;

/// 换一个干净的内存库，并把所有 DAO 重新绑定
void freshDb() {
  db = Db.openInMemory();
  engine = RuleEngine(db);
  products = ProductDao(db);
  documents = DocumentDao(db);
  stock = StockLedgerDao(db);
  money = MoneyLedgerDao(db);
  partyLedger = PartyLedgerDao(db);
}

// ---------------------------------------------------------------- 夹具

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

String createAccount() {
  final int t = now();
  final Account a = Account(
    id: newId(),
    name: '现金',
    type: AccountType.cash,
    createdAt: t,
    updatedAt: t,
  );
  AccountDao(db).insert(a);
  return a.id;
}

String createParty() {
  final int t = now();
  final Party p = Party(
    id: newId(),
    name: '往来方甲',
    roles: const <PartyRole>[PartyRole.customer, PartyRole.supplier],
    createdAt: t,
    updatedAt: t,
  );
  PartyDao(db).insert(p);
  return p.id;
}

Document mkDoc({
  required DocType type,
  String? partyId,
  int totalAmount = 0,
  String? refDocId,
}) => Document(
  id: newId(),
  docNo: '${Document.pendingDocNoPrefix}abc123',
  docType: type,
  status: DocStatus.confirmed,
  partyId: partyId,
  totalAmount: totalAmount,
  refDocId: refDocId,
  occurredAt: now(),
  createdAt: now(),
  updatedAt: now(),
);

List<DocumentLine> oneLine(String documentId, String productId, int qty, int price) =>
    <DocumentLine>[
      DocumentLine.create(
        documentId: documentId,
        productId: productId,
        quantity: qty,
        unitPrice: price,
      ),
    ];

RuleOutcome run(Document d, List<DocumentLine> ls) =>
    engine.dispatch(document: d, lines: ls, now: now());

bool applied(RuleOutcome o) => o.status == RuleStatus.applied;

/// 某单据写入的库存成本（该单只有一条 line 时无歧义）
int stockCostOf(String documentId) =>
    db.raw
            .select(
              'SELECT total_cost FROM stock_ledger WHERE document_id = ?',
              <Object?>[documentId],
            )
            .first['total_cost']!
        as int;

/// 入库备货，返回原采购单；失败即中止（夹具错误不应被当成断言通过）
Document seedPurchase(String productId, String partyId, int qty, int unitPrice) {
  final Document purchase = mkDoc(
    type: DocType.purchase,
    partyId: partyId,
    totalAmount: qty * unitPrice,
  );
  final RuleOutcome outcome = run(
    purchase,
    oneLine(purchase.id, productId, qty, unitPrice),
  );
  if (!applied(outcome)) {
    stderr.writeln('夹具失败：seedPurchase → ${outcome.reason}');
    exit(2);
  }
  return purchase;
}

/// 同商品多条明细的入库（用于构造非整除的原单成本）
Document seedPurchaseMulti(
  String partyId,
  String productId,
  List<List<int>> qtyPrice,
) {
  final int total = qtyPrice.fold<int>(
    0,
    (int acc, List<int> pair) => acc + pair[0] * pair[1],
  );
  final Document purchase = mkDoc(
    type: DocType.purchase,
    partyId: partyId,
    totalAmount: total,
  );
  final RuleOutcome outcome = engine.dispatch(
    document: purchase,
    lines: <DocumentLine>[
      for (final List<int> pair in qtyPrice)
        DocumentLine.create(
          documentId: purchase.id,
          productId: productId,
          quantity: pair[0],
          unitPrice: pair[1],
        ),
    ],
    now: now(),
  );
  if (!applied(outcome)) {
    stderr.writeln('夹具失败：seedPurchaseMulti → ${outcome.reason}');
    exit(2);
  }
  return purchase;
}

// ---------------------------------------------------------------- 主体

void main() {
  useLocalSqlite();

  // ============================================================ 成本分摊
  section('R-11 方案 A · 单次部分退');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    final Document purchase = seedPurchase(p, party, 10, 100);

    final Document ret = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 300,
      refDocId: purchase.id,
    );
    final RuleOutcome outcome = run(ret, oneLine(ret.id, p, 3, 100));

    check('采购退货 applied', applied(outcome), '${outcome.reason}');
    check('库存 10 → 7', stock.stockOf(p) == 7, '${stock.stockOf(p)}');
    check('quantity = -3（货出库）', stock.ofProduct(p).last.quantity == -3);
    check('total_cost = -300（1000 × 3 / 10）', stockCostOf(ret.id) == -300,
        '${stockCostOf(ret.id)}');
    db.close();
  }

  section('R-11 方案 A · 单次全额退');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    final Document purchase = seedPurchase(p, party, 10, 100);

    final Document ret = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 1000,
      refDocId: purchase.id,
    );
    run(ret, oneLine(ret.id, p, 10, 100));

    check('total_cost = -1000', stockCostOf(ret.id) == -1000, '${stockCostOf(ret.id)}');
    check('库存归零', stock.stockOf(p) == 0, '${stock.stockOf(p)}');
    check('库存成本精确归零', stock.costSnapshotOf(p).totalCost == 0,
        '${stock.costSnapshotOf(p).totalCost}');
    db.close();
  }

  section('R-11 方案 A · 多次部分退（余数归属）');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    // 原单 1×101 + 9×100 = 1001，数量 10
    final Document purchase = seedPurchaseMulti(party, p, <List<int>>[
      <int>[1, 101],
      <int>[9, 100],
    ]);
    check('原单成本 1001', stock.costSnapshotOf(p).totalCost == 1001,
        '${stock.costSnapshotOf(p).totalCost}');

    final List<int> costs = <int>[];
    for (final int qty in <int>[3, 3, 4]) {
      final Document ret = mkDoc(
        type: DocType.purchaseReturn,
        partyId: party,
        totalAmount: qty * 100,
        refDocId: purchase.id,
      );
      final RuleOutcome outcome = run(ret, oneLine(ret.id, p, qty, 100));
      if (!applied(outcome)) {
        stderr.writeln('夹具失败：第 ${costs.length + 1} 次退货 → ${outcome.reason}');
        exit(2);
      }
      costs.add(stockCostOf(ret.id));
    }

    check('三次依次为 -300 / -301 / -400',
        costs.join(',') == '-300,-301,-400', costs.join(','));
    check('三次之和精确为 -1001',
        costs.reduce((int a, int b) => a + b) == -1001);
    check('库存归零', stock.stockOf(p) == 0, '${stock.stockOf(p)}');
    check('库存成本归零', stock.costSnapshotOf(p).totalCost == 0);
    db.close();
  }

  section('R-11 方案 A · 超额退货');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    final Document purchase = seedPurchase(p, party, 10, 100);

    final Document ok = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 800,
      refDocId: purchase.id,
    );
    check('退 8 件 applied', applied(run(ok, oneLine(ok.id, p, 8, 100))));

    final Document over = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 300,
      refDocId: purchase.id,
    );
    final RuleOutcome outcome = run(over, oneLine(over.id, p, 3, 100));

    check('再退 3 件 → rejected', outcome.status == RuleStatus.rejected);
    check('错误码 return_exceeds_original',
        outcome.code == RejectCode.returnExceedsOriginal,
        '${outcome.reason}');
    check('整单回滚：单据未落库', documents.findById(over.id) == null);
    check('库存停在 2', stock.stockOf(p) == 2, '${stock.stockOf(p)}');
    db.close();
  }

  section('R-11 方案 A · 多商品独立约束');
  {
    freshDb();
    final String a = createProduct(code: 'A');
    final String b = createProduct(code: 'B');
    final String party = createParty();

    final Document purchase = mkDoc(
      type: DocType.purchase,
      partyId: party,
      totalAmount: 2000,
    );
    final RuleOutcome seeded = engine.dispatch(
      document: purchase,
      lines: <DocumentLine>[
        DocumentLine.create(
          documentId: purchase.id,
          productId: a,
          quantity: 10,
          unitPrice: 100,
        ),
        DocumentLine.create(
          documentId: purchase.id,
          productId: b,
          quantity: 5,
          unitPrice: 200,
        ),
      ],
      now: now(),
    );
    check('原单（A 10@100 + B 5@200）applied', applied(seeded), '${seeded.reason}');

    final Document a8 = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 800,
      refDocId: purchase.id,
    );
    check('A 退 8 applied', applied(run(a8, oneLine(a8.id, a, 8, 100))));
    check('A 退 8 成本 -800', stockCostOf(a8.id) == -800, '${stockCostOf(a8.id)}');

    final Document a3 = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 300,
      refDocId: purchase.id,
    );
    check('A 再退 3 → rejected',
        run(a3, oneLine(a3.id, a, 3, 100)).status == RuleStatus.rejected);

    final Document b5 = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 1000,
      refDocId: purchase.id,
    );
    check('B 全额退 5 不受 A 影响', applied(run(b5, oneLine(b5.id, b, 5, 200))));
    check('B 退 5 成本 -1000', stockCostOf(b5.id) == -1000, '${stockCostOf(b5.id)}');
    check('B 库存归零', stock.stockOf(b) == 0);
    db.close();
  }

  section('R-11 方案 A · 负库存出库后退货');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    seedPurchase(p, party, 3, 100); // 库存 3 / 成本 300

    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: party,
      totalAmount: 500,
    );
    check('超卖 5 件 applied', applied(run(sale, oneLine(sale.id, p, 5, 100))));
    check('库存 -2', stock.stockOf(p) == -2, '${stock.stockOf(p)}');
    check('库存成本 -200', stock.costSnapshotOf(p).totalCost == -200,
        '${stock.costSnapshotOf(p).totalCost}');
    check('原单出库成本 -500', stock.ofProduct(p).last.totalCost == -500,
        '${stock.ofProduct(p).last.totalCost}');

    final Document ret = mkDoc(
      type: DocType.saleReturn,
      partyId: party,
      totalAmount: 200,
      refDocId: sale.id,
    );
    check('退 2 件 applied', applied(run(ret, oneLine(ret.id, p, 2, 100))));
    check('回退 500 × 2 / 5 = 200', stockCostOf(ret.id) == 200,
        '${stockCostOf(ret.id)}');
    check('库存归零', stock.stockOf(p) == 0);
    check('库存成本归零', stock.costSnapshotOf(p).totalCost == 0);
    db.close();
  }

  // ============================================================ RULE-007
  section('RULE-007 全额退');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    seedPurchase(p, party, 10, 100);

    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: party,
      totalAmount: 2000,
    );
    run(sale, oneLine(sale.id, p, 10, 200));
    check('卖出后库存 0', stock.stockOf(p) == 0);
    // 采购未付 → -1000；销售 +2000；合计 +1000
    final int beforeReturn = partyLedger.balanceOf(party);
    check('退货前往来 +1000', beforeReturn == 1000, '$beforeReturn');

    final Document ret = mkDoc(
      type: DocType.saleReturn,
      partyId: party,
      totalAmount: 2000,
      refDocId: sale.id,
    );
    final RuleOutcome outcome = run(ret, oneLine(ret.id, p, 10, 200));

    check('销售退货 applied', applied(outcome), '${outcome.reason}');
    check('库存回到 10', stock.stockOf(p) == 10, '${stock.stockOf(p)}');
    check('quantity = +10（货回库）', stock.ofProduct(p).last.quantity == 10);
    check('total_cost = +1000（符号为正）', stockCostOf(ret.id) == 1000,
        '${stockCostOf(ret.id)}');
    check('库存成本回到 1000', stock.costSnapshotOf(p).totalCost == 1000);
    check('退货把销售的应收全额冲销（+1000 → -1000）',
        partyLedger.balanceOf(party) == -1000, '${partyLedger.balanceOf(party)}');
    check('退货本身的往来影响 = -2000',
        partyLedger.balanceOf(party) - beforeReturn == -2000,
        '${partyLedger.balanceOf(party) - beforeReturn}');
    db.close();
  }

  section('RULE-007 部分退 · round-half-up（不是截断）');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    seedPurchase(p, party, 1, 2); // 1 件 2 分
    seedPurchase(p, party, 2, 150); // 2 件 300 分 ⇒ 库存 3 / 成本 302
    check('库存成本 302', stock.costSnapshotOf(p).totalCost == 302,
        '${stock.costSnapshotOf(p).totalCost}');

    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: party,
      totalAmount: 600,
    );
    run(sale, oneLine(sale.id, p, 3, 200));
    check('出库成本 -302', stock.ofProduct(p).last.totalCost == -302,
        '${stock.ofProduct(p).last.totalCost}');

    final Document r1 = mkDoc(
      type: DocType.saleReturn,
      partyId: party,
      totalAmount: 200,
      refDocId: sale.id,
    );
    check('退 1 件 applied', applied(run(r1, oneLine(r1.id, p, 1, 200))));
    check('total_cost = 101（round-half-up）', stockCostOf(r1.id) == 101,
        '${stockCostOf(r1.id)}');
    check('若用 ~/ 截断会得到 100', 302 ~/ 3 == 100);

    final Document r2 = mkDoc(
      type: DocType.saleReturn,
      partyId: party,
      totalAmount: 400,
      refDocId: sale.id,
    );
    check('退 2 件 applied', applied(run(r2, oneLine(r2.id, p, 2, 200))));
    check('total_cost = 201（累计 302 − 已分摊 101）', stockCostOf(r2.id) == 201,
        '${stockCostOf(r2.id)}');
    check('两次之和 = 302', stockCostOf(r1.id) + stockCostOf(r2.id) == 302);
    check('库存成本回到 302', stock.costSnapshotOf(p).totalCost == 302);
    db.close();
  }

  section('RULE-007 立即退款 → 自动生成 payment 单');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    final String account = createAccount();
    seedPurchase(p, party, 10, 100);

    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: party,
      totalAmount: 5000,
    );
    run(sale, oneLine(sale.id, p, 10, 500));

    final Document ret = mkDoc(
      type: DocType.saleReturn,
      partyId: party,
      totalAmount: 1000,
      refDocId: sale.id,
    );
    final RuleOutcome outcome = engine.dispatch(
      document: ret,
      lines: oneLine(ret.id, p, 2, 500),
      immediatePayments: <PaymentEntry>[
        PaymentEntry(accountId: account, amount: 1000),
      ],
      now: now(),
    );

    check('退货 applied', applied(outcome), '${outcome.reason}');
    check('paid_amount = 1000', documents.findById(ret.id)!.paidAmount == 1000);
    check('status = settled', documents.findById(ret.id)!.status == DocStatus.settled,
        '${documents.findById(ret.id)!.status}');

    final Row refund = db.raw
        .select(
          'SELECT m.amount, d.doc_type FROM money_ledger m '
          'JOIN documents d ON d.id = m.document_id WHERE d.ref_doc_id = ?',
          <Object?>[ret.id],
        )
        .first;
    check('退款挂在 payment 单上', refund['doc_type'] == 'payment', '${refund['doc_type']}');
    check('资金流出 -1000', refund['amount'] == -1000, '${refund['amount']}');
    check('现金账户余额 -1000', money.balanceOf(account) == -1000,
        '${money.balanceOf(account)}');

    // 纪律 11：资金流只能挂在收付款单下
    final Row onMain = db.raw
        .select('''
          SELECT COUNT(*) AS c FROM money_ledger m
          JOIN documents d ON d.id = m.document_id
          WHERE d.doc_type NOT IN ('receipt', 'payment')
        ''')
        .first;
    check('money_ledger 未挂在任何主单上', onMain['c'] == 0, '${onMain['c']}');
    db.close();
  }

  section('RULE-007 未立即退款 → 未结清部分留在往来');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    seedPurchase(p, party, 10, 100);

    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: party,
      totalAmount: 5000,
    );
    run(sale, oneLine(sale.id, p, 10, 500));

    final Document ret = mkDoc(
      type: DocType.saleReturn,
      partyId: party,
      totalAmount: 1000,
      refDocId: sale.id,
    );
    run(ret, oneLine(ret.id, p, 2, 500));

    check('status = confirmed', documents.findById(ret.id)!.status == DocStatus.confirmed);
    check('paid_amount = 0', documents.findById(ret.id)!.paidAmount == 0);
    check('往来 = -1000 + 5000 - 1000 = 3000', partyLedger.balanceOf(party) == 3000,
        '${partyLedger.balanceOf(party)}');
    db.close();
  }

  section('RULE-007 退货不修改原单 paid_amount');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    final String account = createAccount();
    seedPurchase(p, party, 10, 100);

    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: party,
      totalAmount: 5000,
    );
    engine.dispatch(
      document: sale,
      lines: oneLine(sale.id, p, 10, 500),
      immediatePayments: <PaymentEntry>[
        PaymentEntry(accountId: account, amount: 3000),
      ],
      now: now(),
    );
    check('原单已收 3000', documents.findById(sale.id)!.paidAmount == 3000,
        '${documents.findById(sale.id)!.paidAmount}');

    final Document ret = mkDoc(
      type: DocType.saleReturn,
      partyId: party,
      totalAmount: 1000,
      refDocId: sale.id,
    );
    run(ret, oneLine(ret.id, p, 2, 500));

    check('退货后原单 paid_amount 仍为 3000',
        documents.findById(sale.id)!.paidAmount == 3000,
        '${documents.findById(sale.id)!.paidAmount}');
    check('原单 status 仍为 confirmed',
        documents.findById(sale.id)!.status == DocStatus.confirmed);
    db.close();
  }

  section('RULE-007 拒收（原单是 delivery）');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty();
    final String customer = createParty();
    seedPurchase(p, supplier, 20, 100); // 库存 20 / 成本 2000

    final Document delivery = mkDoc(
      type: DocType.delivery,
      partyId: customer,
      totalAmount: 1000,
    );
    final RuleOutcome shipped = run(delivery, oneLine(delivery.id, p, 10, 100));
    check('送货 applied', applied(shipped), '${shipped.reason}');
    check('库存 20 → 10', stock.stockOf(p) == 10, '${stock.stockOf(p)}');
    check('送货出库成本 -1000', stock.ofProduct(p).last.totalCost == -1000,
        '${stock.ofProduct(p).last.totalCost}');
    check('客户往来 +1000', partyLedger.balanceOf(customer) == 1000);

    final Document refused = mkDoc(
      type: DocType.saleReturn,
      partyId: customer,
      totalAmount: 400,
      refDocId: delivery.id, // 原单是 delivery（拒收），不是 sale
    );
    final RuleOutcome outcome = run(refused, oneLine(refused.id, p, 4, 100));

    check('拒收 applied（sale_return 接受 delivery）', applied(outcome), '${outcome.reason}');
    check('库存回到 14', stock.stockOf(p) == 14, '${stock.stockOf(p)}');
    check('quantity = +4（货回库）', stock.ofProduct(p).last.quantity == 4);
    check('成本按原送货单回退 1000 × 4 / 10 = 400',
        stockCostOf(refused.id) == 400, '${stockCostOf(refused.id)}');
    check('拒收冲销应收 400 → 仍欠 600',
        partyLedger.balanceOf(customer) == 600, '${partyLedger.balanceOf(customer)}');
    db.close();
  }

  // ============================================================ RULE-008 结算
  section('RULE-008 立即收退款 → 自动生成 receipt 单');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    final String account = createAccount();
    final Document purchase = seedPurchase(p, party, 10, 100);

    final Document ret = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 300,
      refDocId: purchase.id,
    );
    final RuleOutcome outcome = engine.dispatch(
      document: ret,
      lines: oneLine(ret.id, p, 3, 100),
      immediatePayments: <PaymentEntry>[
        PaymentEntry(accountId: account, amount: 300),
      ],
      now: now(),
    );

    check('采购退货 applied', applied(outcome), '${outcome.reason}');
    check('status = settled', documents.findById(ret.id)!.status == DocStatus.settled);
    check('paid_amount = 300', documents.findById(ret.id)!.paidAmount == 300);

    final Row refund = db.raw
        .select(
          'SELECT m.amount, d.doc_type FROM money_ledger m '
          'JOIN documents d ON d.id = m.document_id WHERE d.ref_doc_id = ?',
          <Object?>[ret.id],
        )
        .first;
    check('收退款挂在 receipt 单上', refund['doc_type'] == 'receipt', '${refund['doc_type']}');
    check('资金流入 +300', refund['amount'] == 300, '${refund['amount']}');
    check('现金账户余额 +300', money.balanceOf(account) == 300,
        '${money.balanceOf(account)}');
    check('仍欠供应商 1000', partyLedger.balanceOf(party) == -1000,
        '${partyLedger.balanceOf(party)}');
    db.close();
  }

  section('退货 · 原单校验');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    final Document purchase = seedPurchase(p, party, 10, 100);

    final Document wrongType = mkDoc(
      type: DocType.saleReturn,
      partyId: party,
      totalAmount: 100,
      refDocId: purchase.id, // sale_return 的原单必须是 sale
    );
    final RuleOutcome typeOutcome = run(wrongType, oneLine(wrongType.id, p, 1, 100));
    check('原单类型不符 → rejected', typeOutcome.status == RuleStatus.rejected);
    check('拒绝原因指向「原单类型」',
        typeOutcome.code == RejectCode.ruleInternalError, '${typeOutcome.code}｜${typeOutcome.reason}');

    final Document noRef = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 100,
    );
    final RuleOutcome noRefOutcome = run(noRef, oneLine(noRef.id, p, 1, 100));
    check('ref_doc_id 缺失 → rejected', noRefOutcome.status == RuleStatus.rejected);
    check('拒绝原因指向 ref_doc_id',
        noRefOutcome.code == RejectCode.ruleInternalError, '${noRefOutcome.code}｜${noRefOutcome.reason}');

    final Document ghost = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 100,
      refDocId: 'no-such-document',
    );
    final RuleOutcome ghostOutcome = run(ghost, oneLine(ghost.id, p, 1, 100));
    check('原单不存在 → rejected', ghostOutcome.status == RuleStatus.rejected);
    check('拒绝原因指向「原单不存在」',
        ghostOutcome.code == RejectCode.targetMissing, '${ghostOutcome.code}｜${ghostOutcome.reason}');
    db.close();
  }

  section('退货 · 商业规则');
  {
    freshDb();
    final String a = createProduct(code: 'A');
    final String b = createProduct(code: 'B');
    final String party = createParty();
    final Document purchase = seedPurchase(a, party, 10, 100);

    final Document ret = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 100,
      refDocId: purchase.id, // 原单里没有商品 B
    );
    final RuleOutcome outcome = run(ret, oneLine(ret.id, b, 1, 100));
    check('原单无该商品流水 → rejected', outcome.status == RuleStatus.rejected);
    check('拒绝原因指向「没有商品」',
        outcome.code == RejectCode.ruleInternalError, '${outcome.code}｜${outcome.reason}');

    check(
      'CostPolicy.returnCost 对不存在的原单抛错',
      throws(
        () => CostPolicy(stock).returnCost(
          refDocId: 'no-such-document',
          productId: a,
          returnQuantity: 1,
          returnType: DocType.saleReturn,
        ),
      ),
    );
    db.close();
  }

  // ============================================================ 事务
  section('事务');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    final Document purchase = seedPurchase(p, party, 10, 100);

    final Document ret = mkDoc(
      type: DocType.purchaseReturn,
      partyId: party,
      totalAmount: 300,
      refDocId: purchase.id,
    );
    run(ret, oneLine(ret.id, p, 3, 100));
    check('dispatch 结束后不残留事务', !db.inTransaction);
    db.close();
  }

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
