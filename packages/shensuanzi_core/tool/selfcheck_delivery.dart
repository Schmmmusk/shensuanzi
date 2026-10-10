// RULE-003 送货自检：`dart run tool/selfcheck_delivery.dart`
//
// 与 `test/delivery_test.dart` 断言等价 —— 本机 `dart test` 无法编译测试文件
// （`test_core` 编译内核时要用 `frontend_server` 子进程，见 `docs/testing.md` §零）。
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**，失败可复现。
// 每个场景一个独立内存库，断言之间不互相污染。

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

// ---------------------------------------------------------------- 共享状态

late Db db;
late RuleEngine engine;
late ProductDao products;
late DocumentDao documents;
late StockLedgerDao stock;
late MoneyLedgerDao money;
late PartyLedgerDao partyLedger;
late SettlementDao settlements;

void freshDb() {
  db = Db.openInMemory();
  engine = RuleEngine(db);
  products = ProductDao(db);
  documents = DocumentDao(db);
  stock = StockLedgerDao(db);
  money = MoneyLedgerDao(db);
  partyLedger = PartyLedgerDao(db);
  settlements = SettlementDao(db);
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

String createParty({String name = '往来方甲'}) {
  final int t = now();
  final Party p = Party(
    id: newId(),
    name: name,
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
  String? accountId,
  int totalAmount = 0,
  DocStatus status = DocStatus.confirmed,
}) => Document(
  id: newId(),
  docNo: '${Document.pendingDocNoPrefix}abc123',
  docType: type,
  status: status,
  partyId: partyId,
  accountId: accountId,
  totalAmount: totalAmount,
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

bool applied(RuleOutcome o) => o.status == RuleStatus.applied;

/// 入库备货（送货出库的成本来源）。**必须有供应商**，否则欠款无处记录。
Document seedStock(
  String productId, {
  required String supplier,
  int qty = 20,
  int unitPrice = 100,
}) {
  final Document purchase = mkDoc(
    type: DocType.purchase,
    partyId: supplier,
    totalAmount: qty * unitPrice,
  );
  final RuleOutcome outcome = engine.dispatch(
    document: purchase,
    lines: oneLine(purchase.id, productId, qty, unitPrice),
    now: now(),
  );
  if (!applied(outcome)) {
    stderr.writeln('夹具失败：seedStock → ${outcome.reason}');
    exit(2);
  }
  return purchase;
}

RuleOutcome deliver(
  String productId, {
  required String customer,
  required int qty,
  int unitPrice = 100,
  List<PaymentEntry> withPayments = const <PaymentEntry>[],
  DocStatus status = DocStatus.confirmed,
}) {
  final Document delivery = mkDoc(
    type: DocType.delivery,
    partyId: customer,
    totalAmount: qty * unitPrice,
    status: status,
  );
  return engine.dispatch(
    document: delivery,
    lines: oneLine(delivery.id, productId, qty, unitPrice),
    immediatePayments: withPayments,
    now: now(),
  );
}

// ---------------------------------------------------------------- 主体

void main() {
  useLocalSqlite();

  section('RULE-003 创建路径');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty(name: '供应商甲');
    final String customer = createParty(name: '客户乙');
    seedStock(p, supplier: supplier, qty: 20, unitPrice: 100); // 库存 20 / 成本 2000

    final RuleOutcome outcome = deliver(p, customer: customer, qty: 10, unitPrice: 100);

    check('送货 applied', applied(outcome), '${outcome.reason}');
    check('库存 20 → 10（货离店即扣）', stock.stockOf(p) == 10, '${stock.stockOf(p)}');

    final StockLedger row = stock.ofProduct(p).last;
    check('quantity = -10', row.quantity == -10, '${row.quantity}');
    check('total_cost = -1000（2000 × 10 / 20）', row.totalCost == -1000,
        '${row.totalCost}');

    check('客户往来 +1000', partyLedger.balanceOf(customer) == 1000,
        '${partyLedger.balanceOf(customer)}');
    check('供应商往来 -2000', partyLedger.balanceOf(supplier) == -2000,
        '${partyLedger.balanceOf(supplier)}');
    check(
      '主机分配了正式单号',
      !outcome.document!.docNo.contains(Document.pendingDocNoPrefix),
      outcome.document!.docNo,
    );
    db.close();
  }

  section('RULE-003 状态机起点（R-10）');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty(name: '供应商甲');
    final String customer = createParty(name: '客户乙');
    seedStock(p, supplier: supplier);

    // 调用方故意传 confirmed —— 送货起始状态必须是 in_transit
    final RuleOutcome outcome = deliver(
      p,
      customer: customer,
      qty: 1,
      status: DocStatus.confirmed,
    );

    check('送货 applied', applied(outcome), '${outcome.reason}');
    check('主机强制 status = in_transit',
        outcome.document!.status == DocStatus.inTransit,
        '${outcome.document!.status}');
    check('落库后的 status = in_transit',
        documents.findById(outcome.document!.id)!.status == DocStatus.inTransit);
    db.close();
  }

  section('RULE-003 拒绝路径');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty(name: '供应商甲');
    final String customer = createParty(name: '客户乙');
    seedStock(p, supplier: supplier);

    // 数量为 0
    final Document zero = mkDoc(
      type: DocType.delivery,
      partyId: customer,
      totalAmount: 0,
    );
    final RuleOutcome zeroOutcome = engine.dispatch(
      document: zero,
      lines: <DocumentLine>[
        DocumentLine(
          id: newId(),
          documentId: zero.id,
          productId: p,
          quantity: 0,
          unitPrice: 0,
          amount: 0,
        ),
      ],
      now: now(),
    );
    check('数量为 0 → rejected', zeroOutcome.status == RuleStatus.rejected);
    check('整单无残留：单据未落库', documents.findById(zero.id) == null);
    check('整单无残留：库存未扣', stock.stockOf(p) == 20, '${stock.stockOf(p)}');

    // 有欠款但没有 party_id
    final Document noParty = mkDoc(
      type: DocType.delivery,
      totalAmount: 100,
    );
    final RuleOutcome noPartyOutcome = engine.dispatch(
      document: noParty,
      lines: oneLine(noParty.id, p, 1, 100),
      now: now(),
    );
    check('有欠款但无 party_id → rejected',
        noPartyOutcome.status == RuleStatus.rejected);
    check('拒绝原因指向 party_id',
        noPartyOutcome.code == RejectCode.ruleInternalError, '${noPartyOutcome.code}｜${noPartyOutcome.reason}');
    check('该单同样未落库', documents.findById(noParty.id) == null);
    db.close();
  }

  section('R-10：送货的 status 不由 paid_amount 推导');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty(name: '供应商甲');
    final String customer = createParty(name: '客户乙');
    final String account = createAccount();
    seedStock(p, supplier: supplier);

    final RuleOutcome outcome = deliver(
      p,
      customer: customer,
      qty: 10,
      unitPrice: 100,
      withPayments: <PaymentEntry>[
        PaymentEntry(accountId: account, amount: 1000),
      ],
    );
    check('送货 applied', applied(outcome), '${outcome.reason}');

    final Document saved = documents.findById(outcome.document!.id)!;
    check('paid_amount = 1000（不变量 B4 无例外）', saved.paidAmount == 1000,
        '${saved.paidAmount}');
    check('status 仍为 in_transit（钱到货未签收）',
        saved.status == DocStatus.inTransit, '${saved.status}');
    check('settlement 已建立', settlements.settledAmountOf(saved.id) == 1000);

    final Row moneyRow = db.raw
        .select(
          'SELECT m.amount, d.doc_type FROM money_ledger m '
          'JOIN documents d ON d.id = m.document_id WHERE d.ref_doc_id = ?',
          <Object?>[saved.id],
        )
        .first;
    check('资金流挂在 receipt 单下', moneyRow['doc_type'] == 'receipt',
        '${moneyRow['doc_type']}');
    check('资金流入 +1000', moneyRow['amount'] == 1000, '${moneyRow['amount']}');
    db.close();
  }

  section('在途视图');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty(name: '供应商甲');
    final String customer = createParty(name: '客户乙');
    seedStock(p, supplier: supplier, qty: 20, unitPrice: 100);
    deliver(p, customer: customer, qty: 5, unitPrice: 100);

    final int inTransit =
        db.raw
                .select(
                  '''
                  SELECT COALESCE(SUM(dl.quantity), 0) AS n
                  FROM document_lines dl
                  JOIN documents d ON d.id = dl.document_id
                  WHERE d.doc_type = 'delivery' AND d.status = 'in_transit'
                    AND dl.product_id = ?
                  ''',
                  <Object?>[p],
                )
                .first['n']!
            as int;

    check('账面库存 15', stock.stockOf(p) == 15, '${stock.stockOf(p)}');
    check('在途数量 5', inTransit == 5, '$inTransit');
    check('在店可售 = 15 − 5 = 10', stock.stockOf(p) - inTransit == 10);
    db.close();
  }

  section('RULE-003 签收（v1 主机本地路径）');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty(name: '供应商甲');
    final String customer = createParty(name: '客户乙');
    seedStock(p, supplier: supplier);

    final RuleOutcome delivered = deliver(p, customer: customer, qty: 10, unitPrice: 100);
    check('送货 applied', applied(delivered), '${delivered.reason}');
    check('创建后 status = in_transit',
        documents.findById(delivered.document!.id)!.status == DocStatus.inTransit);

    final RuleOutcome marked = engine.markDelivered(
      documentId: delivered.document!.id,
      now: now(),
    );
    check('签收 applied', applied(marked), '${marked.reason}');
    check('status → delivered',
        documents.findById(delivered.document!.id)!.status == DocStatus.delivered);
    check('paid_amount 仍为 0', documents.findById(delivered.document!.id)!.paidAmount == 0);
    db.close();
  }

  section('RULE-003 签收 · 幂等与副作用');
  {
    for (final int paid in <int>[0, 400, 1000]) {
      freshDb();
      final String product = createProduct(code: 'P-$paid');
      final String sup = createParty(name: '供应商-$paid');
      final String cus = createParty(name: '客户-$paid');
      final String account = createAccount();
      seedStock(product, supplier: sup, qty: 20, unitPrice: 100);

      final RuleOutcome created = deliver(
        product,
        customer: cus,
        qty: 10,
        unitPrice: 100,
        withPayments: paid == 0
            ? const <PaymentEntry>[]
            : <PaymentEntry>[PaymentEntry(accountId: account, amount: paid)],
      );
      if (!applied(created)) {
        stderr.writeln('夹具失败：送货（已付 $paid）→ ${created.reason}');
        exit(2);
      }
      final String id = created.document!.id;

      final int stockRows = stock.ofProduct(product).length;
      final int partyRows = partyLedger.ofParty(cus).length;
      final int stockBefore = stock.stockOf(product);
      final int costBefore = stock.costSnapshotOf(product).totalCost;
      final int partyBefore = partyLedger.balanceOf(cus);

      final RuleOutcome first = engine.markDelivered(documentId: id, now: now());
      check('已付 $paid → 签收 applied', applied(first), '${first.reason}');

      final DocStatus expected = paid >= 1000
          ? DocStatus.settled
          : DocStatus.delivered;
      check('已付 $paid → status = ${expected.wire}',
          documents.findById(id)!.status == expected,
          '${documents.findById(id)!.status}');

      final int updatedAtAfterFirst = documents.findById(id)!.updatedAt;
      final RuleOutcome second = engine.markDelivered(documentId: id, now: now());
      check('已付 $paid → 重复签收 alreadyExists',
          second.status == RuleStatus.alreadyExists, '${second.status}');
      check('已付 $paid → 签收不改库存', stock.stockOf(product) == stockBefore);
      check('已付 $paid → 签收不改库存成本',
          stock.costSnapshotOf(product).totalCost == costBefore);
      check('已付 $paid → 签收不改往来', partyLedger.balanceOf(cus) == partyBefore);
      check('已付 $paid → 签收不产生新流水',
          stock.ofProduct(product).length == stockRows &&
              partyLedger.ofParty(cus).length == partyRows);
      check(
        '已付 $paid → 幂等命中时不写 updated_at',
        documents.findById(id)!.updatedAt == updatedAtAfterFirst,
        '${documents.findById(id)!.updatedAt} vs $updatedAtAfterFirst',
      );
      db.close();
    }

    // 签收后收到余款 → settled
    freshDb();
    final String prod = createProduct(code: 'P-late');
    final String sup2 = createParty(name: '供应商-迟到');
    final String cus2 = createParty(name: '客户-迟到');
    final String acc2 = createAccount();
    seedStock(prod, supplier: sup2, qty: 20, unitPrice: 100);

    final RuleOutcome d2 = deliver(prod, customer: cus2, qty: 10, unitPrice: 100);
    engine.markDelivered(documentId: d2.document!.id, now: now());
    check('未收款先签收 → delivered',
        documents.findById(d2.document!.id)!.status == DocStatus.delivered);

    final Document receipt = mkDoc(
      type: DocType.receipt,
      partyId: cus2,
      accountId: acc2,
      totalAmount: 1000,
    );
    final RuleOutcome settle = engine.dispatch(
      document: receipt,
      allocations: <Allocation>[
        Allocation(targetDocId: d2.document!.id, amount: 1000),
      ],
      now: now(),
    );
    check('核销 applied', applied(settle), '${settle.reason}');
    check('签收后收满款 → settled',
        documents.findById(d2.document!.id)!.status == DocStatus.settled,
        '${documents.findById(d2.document!.id)!.status}');
    db.close();
  }

  section('RULE-003 签收 · 拒绝路径');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty(name: '供应商甲');
    final String customer = createParty(name: '客户乙');
    seedStock(p, supplier: supplier);

    final RuleOutcome created = deliver(p, customer: customer, qty: 1);
    final String id = created.document!.id;

    // 主机本地取消后再签收
    documents.updateStatusAndPaid(
      id: id,
      status: DocStatus.cancelled,
      updatedAt: now(),
    );
    final RuleOutcome onCancelled = engine.markDelivered(documentId: id, now: now());
    check('已取消的单不能签收 → rejected',
        onCancelled.status == RuleStatus.rejected);
    check('拒绝原因指向 cancelled',
        onCancelled.code == RejectCode.actionNotApplicable, '${onCancelled.code}｜${onCancelled.reason}');
    check('状态未被改动', documents.findById(id)!.status == DocStatus.cancelled);

    final Document purchase = seedStock(p, supplier: supplier);
    final RuleOutcome onPurchase = engine.markDelivered(
      documentId: purchase.id,
      now: now(),
    );
    check('非 delivery 单据不能签收 → rejected',
        onPurchase.status == RuleStatus.rejected);
    check('拒绝原因指向「不适用」',
        onPurchase.code == RejectCode.actionNotApplicable, '${onPurchase.code}｜${onPurchase.reason}');

    final RuleOutcome ghost = engine.markDelivered(
      documentId: 'no-such-document',
      now: now(),
    );
    check('单据不存在 → rejected', ghost.status == RuleStatus.rejected);
    check('拒绝原因指向「不存在」',
        ghost.code == RejectCode.targetMissing, '${ghost.code}｜${ghost.reason}');
    check('dispatch 结束后不残留事务', !db.inTransaction);
    db.close();
  }

  section('不变量');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty(name: '供应商甲');
    final String customer = createParty(name: '客户乙');
    seedStock(p, supplier: supplier, qty: 20, unitPrice: 100);
    for (final int qty in <int>[2, 3, 4]) {
      final RuleOutcome outcome = deliver(p, customer: customer, qty: qty);
      if (!applied(outcome)) {
        stderr.writeln('夹具失败：送货 $qty 件 → ${outcome.reason}');
        exit(2);
      }
    }

    final int sum =
        db.raw
                .select(
                  'SELECT COALESCE(SUM(quantity), 0) AS s FROM stock_ledger '
                  'WHERE product_id = ?',
                  <Object?>[p],
                )
                .first['s']!
            as int;
    check('库存 = SUM(stock_ledger.quantity)', stock.stockOf(p) == sum);
    check('库存 = 20 − 2 − 3 − 4 = 11', stock.stockOf(p) == 11, '${stock.stockOf(p)}');
    check('dispatch 结束后不残留事务', !db.inTransaction);
    db.close();
  }

  section('纪律 11：送货主单不直接写 money_ledger');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty(name: '供应商甲');
    final String customer = createParty(name: '客户乙');
    final String account = createAccount();
    seedStock(p, supplier: supplier);
    deliver(
      p,
      customer: customer,
      qty: 2,
      withPayments: <PaymentEntry>[
        PaymentEntry(accountId: account, amount: 200),
      ],
    );

    final Row onMain = db.raw
        .select('''
          SELECT COUNT(*) AS c FROM money_ledger m
          JOIN documents d ON d.id = m.document_id
          WHERE d.doc_type NOT IN ('receipt', 'payment')
        ''')
        .first;
    check('money_ledger 未挂在任何主单上', onMain['c'] == 0, '${onMain['c']}');
    check('现金账户余额 +200', money.balanceOf(account) == 200,
        '${money.balanceOf(account)}');
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
