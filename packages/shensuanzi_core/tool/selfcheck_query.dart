// RULE-006 自检：`dart run tool/selfcheck_query.dart`
//
// 与 `test/query_test.dart` 断言等价 —— 本机 `dart test` 无法编译测试文件
// （`test_core` 编译内核时要用 `frontend_server` 子进程，见 `docs/testing.md` §零）。
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**，失败可复现。
// 每个场景一个独立内存库。

import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';

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

late Db db;
late RuleEngine engine;
late QueryDao query;

void freshDb() {
  db = Db.openInMemory();
  engine = RuleEngine(db);
  query = QueryDao(db);
}

String createProduct({String code = 'P001'}) {
  final int t = now();
  final Product p = Product(
    id: newId(),
    code: code,
    name: '商品-$code',
    createdAt: t,
    updatedAt: t,
  );
  ProductDao(db).insert(p);
  return p.id;
}

String createAccount({String name = '现金', int initialBalance = 0}) {
  final int t = now();
  final Account a = Account(
    id: newId(),
    name: name,
    type: AccountType.cash,
    initialBalance: initialBalance,
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
    name: '往来方',
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
}) => Document(
  id: newId(),
  docNo: '${Document.pendingDocNoPrefix}abc123',
  docType: type,
  status: DocStatus.confirmed,
  partyId: partyId,
  accountId: accountId,
  totalAmount: totalAmount,
  occurredAt: now(),
  createdAt: now(),
  updatedAt: now(),
);

List<DocumentLine> oneLine(String docId, String productId, int qty, int price) =>
    <DocumentLine>[
      DocumentLine.create(
        documentId: docId,
        productId: productId,
        quantity: qty,
        unitPrice: price,
      ),
    ];

bool applied(RuleOutcome o) => o.status == RuleStatus.applied;

void seedPurchase(String productId, String partyId, int qty, int unitPrice) {
  final Document purchase = mkDoc(
    type: DocType.purchase,
    partyId: partyId,
    totalAmount: qty * unitPrice,
  );
  final RuleOutcome outcome = engine.dispatch(
    document: purchase,
    lines: oneLine(purchase.id, productId, qty, unitPrice),
    now: now(),
  );
  if (!applied(outcome)) {
    stderr.writeln('夹具失败：seedPurchase → ${outcome.reason}');
    exit(2);
  }
}

void main() {
  useLocalSqlite();

  // ============================================================ 库存
  section('RULE-006 库存');
  {
    freshDb();
    final String p = createProduct();
    final String untouched = createProduct(code: 'P002');
    final String party = createParty();
    seedPurchase(p, party, 10, 100);

    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: party,
      totalAmount: 300,
    );
    engine.dispatch(
      document: sale,
      lines: oneLine(sale.id, p, 3, 100),
      now: now(),
    );

    check('库存 = 10 − 3 = 7', query.stockByProduct()[p] == 7, '${query.stockByProduct()[p]}');
    check('没进过货的商品不出现在结果里',
        !query.stockByProduct().containsKey(untouched));
    check('消费端用 ?? 0 兜底', (query.stockByProduct()[untouched] ?? 0) == 0);
    db.close();
  }

  section('RULE-006 负库存');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    seedPurchase(p, party, 2, 100);

    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: party,
      totalAmount: 500,
    );
    engine.dispatch(
      document: sale,
      lines: oneLine(sale.id, p, 5, 100),
      now: now(),
    );

    check('超卖后库存 = -3（如实反映）', query.stockByProduct()[p] == -3,
        '${query.stockByProduct()[p]}');
    db.close();
  }

  // ============================================================ 账户余额
  section('RULE-006 账户余额');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    final String cash = createAccount(initialBalance: 10000);
    final String idle = createAccount(name: '闲置', initialBalance: 500);

    seedPurchase(p, party, 10, 100);

    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: party,
      totalAmount: 3000,
    );
    engine.dispatch(
      document: sale,
      lines: oneLine(sale.id, p, 3, 1000),
      now: now(),
    );

    final Document receipt = mkDoc(
      type: DocType.receipt,
      partyId: party,
      accountId: cash,
      totalAmount: 3000,
    );
    final RuleOutcome outcome = engine.dispatch(
      document: receipt,
      allocations: <Allocation>[Allocation(targetDocId: sale.id, amount: 3000)],
      now: now(),
    );
    check('收款 applied', applied(outcome), '${outcome.reason}');

    check('余额 = initial_balance + SUM(money) = 13000',
        query.accountBalances()[cash] == 13000, '${query.accountBalances()[cash]}');
    check('无流水账户也在结果里（LEFT JOIN）',
        query.accountBalances().containsKey(idle));
    check('无流水账户余额 = 期初 500', query.accountBalances()[idle] == 500,
        '${query.accountBalances()[idle]}');
    db.close();
  }

  // ============================================================ 往来余额
  section('RULE-006 往来余额');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty();
    final String customer = createParty();
    seedPurchase(p, supplier, 10, 100);

    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: customer,
      totalAmount: 2000,
    );
    engine.dispatch(
      document: sale,
      lines: oneLine(sale.id, p, 2, 1000),
      now: now(),
    );

    final Map<String, int> balances = query.partyBalances();
    check('供应商 = -1000（应付为负）', balances[supplier] == -1000,
        '${balances[supplier]}');
    check('客户 = +2000（应收为正）', balances[customer] == 2000,
        '${balances[customer]}');
    db.close();
  }

  // ============================================================ 在途
  section('RULE-006 在途与在店可售');
  {
    freshDb();
    final String p = createProduct();
    final String supplier = createParty();
    final String customer = createParty();
    seedPurchase(p, supplier, 20, 100);

    final Document delivery = mkDoc(
      type: DocType.delivery,
      partyId: customer,
      totalAmount: 500,
    );
    final RuleOutcome shipped = engine.dispatch(
      document: delivery,
      lines: oneLine(delivery.id, p, 5, 100),
      now: now(),
    );
    check('送货 applied', applied(shipped), '${shipped.reason}');
    check('账面库存 15', query.stockByProduct()[p] == 15, '${query.stockByProduct()[p]}');
    check('在途数量 5', query.inTransitByProduct()[p] == 5,
        '${query.inTransitByProduct()[p]}');
    check('在店可售 = 15 − 5 = 10', query.availableInStore()[p] == 10,
        '${query.availableInStore()[p]}');

    final RuleOutcome signed = engine.markDelivered(
      documentId: delivery.id,
      now: now(),
    );
    check('签收 applied', applied(signed), '${signed.reason}');
    check('签收后在途归零', (query.inTransitByProduct()[p] ?? 0) == 0,
        '${query.inTransitByProduct()[p]}');
    check('签收后在店可售 = 账面 15', query.availableInStore()[p] == 15,
        '${query.availableInStore()[p]}');
    db.close();
  }

  section('RULE-006 无送货时在店可售 = 账面');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    seedPurchase(p, party, 8, 100);

    check('在途为空', query.inTransitByProduct().isEmpty);
    check('在店可售 = 8', query.availableInStore()[p] == 8);
    db.close();
  }

  // ============================================================ 成本余值
  section('RULE-006 costByProduct（加权成本余值，R-9）');
  {
    freshDb();
    final String p = createProduct();
    final String party = createParty();
    seedPurchase(p, party, 10, 100);

    check('入库后成本余值 = 1000', query.costByProduct()[p] == 1000,
        '${query.costByProduct()[p]}');

    // ⚠️ totalAmount 必须等于明细和（12 × 100）：B5 不变量，不符会被拒
    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: party,
      totalAmount: 1200,
    );
    engine.dispatch(document: sale, lines: oneLine(sale.id, p, 12, 100), now: now());

    check('超卖 12 件 → 余值 -200（UI 必须红色，§AA AA-4）',
        query.costByProduct()[p] == -200, '${query.costByProduct()[p]}');
    db.close();
  }

  // ============================================================ 往来流水视图
  section('往来流水视图（§AA 六 / AA-6：JOIN documents 人可读版）');
  {
    freshDb();
    final String p = createProduct();
    final String customer = createParty();
    final Document sale = mkDoc(
      type: DocType.sale,
      partyId: customer,
      totalAmount: 2000,
    );
    engine.dispatch(document: sale, lines: oneLine(sale.id, p, 2, 1000), now: now());

    final List<PartyFlowEntry> flow = PartyLedgerDao(db).ofParty(customer);
    // ⚠️ dispatch 会把占位单号换成正式单号 —— 断言「非待同步前缀」才有意义
    check('带回 doc_no（用户认单号不认 UUID）',
        flow.length == 1 &&
            !flow.single.docNo.startsWith(Document.pendingDocNoPrefix));
    check('带回 doc_type（区分采购/收款）',
        flow.single.docType == DocType.sale);
    check('金额口径不变：正 = 对方欠我增加', flow.single.amount == 2000);
    check('seqNo 保留（裸流水时代调用兼容）', flow.single.seqNo > 0);

    // 散客单（party_id null）不进流水
    final Document cashSale = mkDoc(type: DocType.sale, totalAmount: 300);
    engine.dispatch(
      document: cashSale,
      lines: oneLine(cashSale.id, p, 1, 300),
      now: now(),
    );
    check('散客单不产生往来流水', PartyLedgerDao(db).ofParty(customer).length == 1);
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
