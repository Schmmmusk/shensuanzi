// 方案 C 自检：`dart run tool/selfcheck_payments.dart`
//
// 覆盖「立即收付款自动生成收付款单」机制（R-6 裁定）。
// 与 `test/immediate_payment_test.dart` 断言等价 —— 本机 `dart test` 无法编译测试文件
// （`test_core` 编译内核时要用 `frontend_server` 子进程，见 `docs/testing.md` §零）。
//
// 退出码：全部通过为 0，否则为 1。**不使用随机数据**。

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

late Db db;
late RuleEngine engine;
late ProductDao products;
late AccountDao accounts;
late PartyDao parties;
late DocumentDao documents;
late StockLedgerDao stock;
late MoneyLedgerDao money;
late PartyLedgerDao partyLedger;
late SettlementDao settlements;

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

String createAccount({String name = '现金'}) {
  final int t = now();
  final Account a = Account(
    id: newId(),
    name: name,
    type: AccountType.cash,
    createdAt: t,
    updatedAt: t,
  );
  accounts.insert(a);
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
  parties.insert(p);
  return p.id;
}

Document mkDoc({
  required DocType type,
  String? partyId,
  String? accountId,
  required int totalAmount,
  String? refDocId,
}) => Document(
  id: newId(),
  docNo: '${Document.pendingDocNoPrefix}abc123',
  docType: type,
  status: DocStatus.confirmed,
  partyId: partyId,
  accountId: accountId,
  totalAmount: totalAmount,
  refDocId: refDocId,
  occurredAt: now(),
  createdAt: now(),
  updatedAt: now(),
);

List<DocumentLine> mkLines(
  String documentId,
  String productId,
  int qty,
  int price,
) => <DocumentLine>[
  DocumentLine.create(
    documentId: documentId,
    productId: productId,
    quantity: qty,
    unitPrice: price,
  ),
];

int countOf(String table) =>
    db.raw.select('SELECT COUNT(*) AS c FROM $table').first['c']! as int;

/// 卖 5000（10 × 500），可选立即收款
RuleOutcome sell({
  required String productId,
  required String? partyId,
  List<PaymentEntry> immediate = const <PaymentEntry>[],
}) {
  final Document sale = mkDoc(
    type: DocType.sale,
    partyId: partyId,
    totalAmount: 5000,
  );
  return engine.dispatch(
    document: sale,
    lines: mkLines(sale.id, productId, 10, 500),
    immediatePayments: immediate,
    now: now(),
  );
}

void main() {
  useLocalSqlite();
  db = Db.openInMemory();
  engine = RuleEngine(db);
  products = ProductDao(db);
  accounts = AccountDao(db);
  parties = PartyDao(db);
  documents = DocumentDao(db);
  stock = StockLedgerDao(db);
  money = MoneyLedgerDao(db);
  partyLedger = PartyLedgerDao(db);
  settlements = SettlementDao(db);

  // ============================================================ RULE-002
  section('RULE-002 全款现金');
  final String p1 = createProduct(code: 'P001');
  final String party1 = createParty();
  final String cash = createAccount(name: '现金');
  final RuleOutcome full = sell(
    productId: p1,
    partyId: party1,
    immediate: <PaymentEntry>[PaymentEntry(accountId: cash, amount: 5000)],
  );
  check('applied', full.status == RuleStatus.applied, '${full.reason}');
  check('生成 2 张单据（sale + 自动 receipt）', countOf('documents') == 2,
      '${countOf('documents')}');
  final Row autoReceipt = db.raw
      .select(
        'SELECT * FROM documents WHERE doc_type = ? AND ref_doc_id = ?',
        <Object?>['receipt', full.document!.id],
      )
      .first;
  check('自动单类型为 receipt', autoReceipt['doc_type'] == 'receipt');
  check('自动单号以 SK 开头', autoReceipt['doc_no'].toString().startsWith('SK'),
      '${autoReceipt['doc_no']}');
  check('自动单 ref_doc_id 指向 sale', autoReceipt['ref_doc_id'] == full.document!.id);
  check('自动单 status = settled', autoReceipt['status'] == 'settled');
  check('自动单 paid_amount = 0（B4′）', autoReceipt['paid_amount'] == 0,
      '${autoReceipt['paid_amount']}');
  check('自动单金额 = 收款额', autoReceipt['total_amount'] == 5000);
  check('自动单继承 party_id / account_id',
      autoReceipt['party_id'] == party1 && autoReceipt['account_id'] == cash);

  final Document main = documents.findById(full.document!.id)!;
  check('主单 status = settled', main.status == DocStatus.settled, '${main.status}');
  check('主单 paid_amount = 5000', main.paidAmount == 5000, '${main.paidAmount}');

  final String autoId = autoReceipt['id']! as String;
  check('资金流水挂在自动单下', money.ofDocument(autoId).single.amount == 5000);
  check('主单不直接写 money_ledger（纪律 11）', money.ofDocument(main.id).isEmpty);
  check('核销关系：sale 已收 5000', settlements.settledAmountOf(main.id) == 5000);
  check('核销关系：receipt 已核销 5000', settlements.allocatedAmountOf(autoId) == 5000);
  check('往来净额为 0（+5000 后 -5000）', partyLedger.balanceOf(party1) == 0,
      '${partyLedger.balanceOf(party1)}');
  check('库存 -10', stock.stockOf(p1) == -10, '${stock.stockOf(p1)}');

  section('RULE-002 全赊 / 部分 / 混合');
  final String p2 = createProduct(code: 'P002');
  final String party2 = createParty(name: '往来方乙');
  final RuleOutcome credit = sell(productId: p2, partyId: party2);
  check('全赊 applied', credit.status == RuleStatus.applied, '${credit.reason}');
  check('全赊不生成收付款单', countOf('documents') == 3, '${countOf('documents')}');
  check('全赊无资金流水', countOf('money_ledger') == 1, '${countOf('money_ledger')}');
  check('全赊 status = confirmed',
      documents.findById(credit.document!.id)!.status == DocStatus.confirmed);
  check('全赊 paid_amount = 0',
      documents.findById(credit.document!.id)!.paidAmount == 0);
  check('全赊客户欠我 5000', partyLedger.balanceOf(party2) == 5000);

  final String p3 = createProduct(code: 'P003');
  final String party3 = createParty(name: '往来方丙');
  final String wechat = createAccount(name: '微信');
  final RuleOutcome partial = sell(
    productId: p3,
    partyId: party3,
    immediate: <PaymentEntry>[PaymentEntry(accountId: wechat, amount: 3000)],
  );
  check('部分收款 applied', partial.status == RuleStatus.applied, '${partial.reason}');
  final Document partialMain = documents.findById(partial.document!.id)!;
  check('部分收款 status = confirmed（方案 B 无解的场景）',
      partialMain.status == DocStatus.confirmed, '${partialMain.status}');
  check('部分收款 paid_amount = 3000', partialMain.paidAmount == 3000);
  check('部分收款资金入账 3000', money.balanceOf(wechat) == 3000);
  check('部分收款余 2000 挂账', partyLedger.balanceOf(party3) == 2000,
      '${partyLedger.balanceOf(party3)}');

  final String p4 = createProduct(code: 'P004');
  final String party4 = createParty(name: '往来方丁');
  final String cash2 = createAccount(name: '现金2');
  final RuleOutcome mixed = sell(
    productId: p4,
    partyId: party4,
    immediate: <PaymentEntry>[
      PaymentEntry(accountId: cash2, amount: 2000),
      PaymentEntry(accountId: wechat, amount: 3000),
    ],
  );
  check('混合支付 applied', mixed.status == RuleStatus.applied, '${mixed.reason}');
  check('混合支付生成 2 张自动单',
      db.raw
              .select(
                'SELECT COUNT(*) AS c FROM documents WHERE ref_doc_id = ?',
                <Object?>[mixed.document!.id],
              )
              .first['c'] ==
          2);
  check('混合支付 status = settled',
      documents.findById(mixed.document!.id)!.status == DocStatus.settled);
  check('混合支付往来清零', partyLedger.balanceOf(party4) == 0);

  section('RULE-002 校验与回滚');
  final String p5 = createProduct(code: 'P005');
  final String party5 = createParty(name: '往来方戊');
  final int docsBefore = countOf('documents');
  final int moneyBefore = countOf('money_ledger');
  final RuleOutcome over = sell(
    productId: p5,
    partyId: party5,
    immediate: <PaymentEntry>[PaymentEntry(accountId: wechat, amount: 6000)],
  );
  check('收款超总额 → rejected', over.status == RuleStatus.rejected);
  check('超额后无残留单据', countOf('documents') == docsBefore);
  check('超额后无残留资金流水', countOf('money_ledger') == moneyBefore);
  check('超额后库存未变', stock.stockOf(p5) == 0);

  final String p6 = createProduct(code: 'P006');
  final RuleOutcome noParty = sell(productId: p6, partyId: null);
  check('有欠款但无 party_id → rejected', noParty.status == RuleStatus.rejected);
  check('拒绝原因指向 party_id',
      noParty.reason?.contains('party_id') ?? false, '${noParty.reason}');
  check('拒绝后无残留单据', countOf('documents') == docsBefore);

  final String p7 = createProduct(code: 'P007');
  final int partyRowsBefore = countOf('party_ledger');
  final RuleOutcome walkIn = sell(
    productId: p7,
    partyId: null,
    immediate: <PaymentEntry>[PaymentEntry(accountId: cash2, amount: 5000)],
  );
  check('无 party_id 但立即全额收款 → applied（零售散客）',
      walkIn.status == RuleStatus.applied, '${walkIn.reason}');
  check('散客不产生往来流水', countOf('party_ledger') == partyRowsBefore);

  // ============================================================ RULE-001
  section('RULE-001 立即付款');
  final String p8 = createProduct(code: 'P008');
  final String sup = createParty(name: '供应商己');
  final Document purchase = mkDoc(
    type: DocType.purchase,
    partyId: sup,
    totalAmount: 1000,
  );
  final RuleOutcome pay = engine.dispatch(
    document: purchase,
    lines: mkLines(purchase.id, p8, 10, 100),
    immediatePayments: <PaymentEntry>[PaymentEntry(accountId: cash2, amount: 1000)],
    now: now(),
  );
  check('采购立即付款 applied', pay.status == RuleStatus.applied, '${pay.reason}');
  check('生成 payment 单',
      db.raw
              .select(
                'SELECT COUNT(*) AS c FROM documents WHERE doc_type = ?',
                <Object?>['payment'],
              )
              .first['c'] ==
          1);
  check('采购单 status = settled',
      documents.findById(purchase.id)!.status == DocStatus.settled);
  check('库存 +10', stock.stockOf(p8) == 10);
  check('欠款清零', partyLedger.balanceOf(sup) == 0, '${partyLedger.balanceOf(sup)}');
  check('资金净额 = 2000 + 5000 - 1000 = 6000', money.balanceOf(cash2) == 6000,
      '实际 ${money.balanceOf(cash2)}');

  // ============================================================ RULE-004/005
  section('RULE-004 手动核销');
  final String p9 = createProduct(code: 'P009');
  final String party9 = createParty(name: '往来方庚');
  final String bank = createAccount(name: '银行');
  final RuleOutcome sale9 = sell(productId: p9, partyId: party9);
  final String sale9Id = sale9.document!.id;

  final Document receiptPartial = mkDoc(
    type: DocType.receipt,
    partyId: party9,
    accountId: bank,
    totalAmount: 2000,
  );
  final RuleOutcome r1 = engine.dispatch(
    document: receiptPartial,
    allocations: <Allocation>[Allocation(targetDocId: sale9Id, amount: 2000)],
    now: now(),
  );
  check('部分核销 applied', r1.status == RuleStatus.applied, '${r1.reason}');
  check('被核销单 paid_amount = 2000',
      documents.findById(sale9Id)!.paidAmount == 2000);
  check('被核销单仍 confirmed',
      documents.findById(sale9Id)!.status == DocStatus.confirmed);
  check('银行入账 2000', money.balanceOf(bank) == 2000);
  check('欠款剩 3000', partyLedger.balanceOf(party9) == 3000);

  final Document receiptRest = mkDoc(
    type: DocType.receipt,
    partyId: party9,
    accountId: bank,
    totalAmount: 3000,
  );
  final RuleOutcome r2 = engine.dispatch(
    document: receiptRest,
    allocations: <Allocation>[Allocation(targetDocId: sale9Id, amount: 3000)],
    now: now(),
  );
  check('收满 applied', r2.status == RuleStatus.applied, '${r2.reason}');
  check('收满后 paid_amount = 5000',
      documents.findById(sale9Id)!.paidAmount == 5000);
  check('收满后 status = settled',
      documents.findById(sale9Id)!.status == DocStatus.settled);
  check('收满后欠款清零', partyLedger.balanceOf(party9) == 0);

  final Document receiptOver = mkDoc(
    type: DocType.receipt,
    partyId: party9,
    accountId: bank,
    totalAmount: 1000,
  );
  final RuleOutcome r3 = engine.dispatch(
    document: receiptOver,
    allocations: <Allocation>[Allocation(targetDocId: sale9Id, amount: 1000)],
    now: now(),
  );
  check('超收 → rejected', r3.status == RuleStatus.rejected);
  check('拒绝原因指向未收金额',
      r3.reason?.contains('超过被核销单未收金额') ?? false, '${r3.reason}');

  final Document prepay = mkDoc(
    type: DocType.receipt,
    partyId: party9,
    accountId: bank,
    totalAmount: 800,
  );
  final RuleOutcome r4 = engine.dispatch(
    document: prepay,
    allocations: <Allocation>[const Allocation(targetDocId: null, amount: 800)],
    now: now(),
  );
  check('预收 applied', r4.status == RuleStatus.applied, '${r4.reason}');
  check('预收单 status = settled',
      documents.findById(prepay.id)!.status == DocStatus.settled);
  check('预收不核销任何单',
      settlements.ofReceipt(prepay.id).single.targetDocId == null);

  check('收付款单缺 account_id → rejected',
      engine
          .dispatch(
            document: mkDoc(type: DocType.receipt, partyId: party9, totalAmount: 100),
            now: now(),
          )
          .reason
          ?.contains('account_id') ??
          false);
  check('收付款单缺 party_id → rejected',
      engine
          .dispatch(
            document: mkDoc(type: DocType.receipt, accountId: bank, totalAmount: 100),
            now: now(),
          )
          .reason
          ?.contains('party_id') ??
          false);

  // ============================================================ 互斥
  section('payload 互斥（sync_protocol §8.1）');
  final RuleOutcome both = engine.dispatch(
    document: mkDoc(type: DocType.sale, partyId: party9, totalAmount: 100),
    immediatePayments: <PaymentEntry>[
      PaymentEntry(accountId: bank, amount: 100),
    ],
    allocations: <Allocation>[const Allocation(targetDocId: null, amount: 100)],
    now: now(),
  );
  check('两者同时非空 → rejected', both.status == RuleStatus.rejected);
  check('拒绝原因指向互斥', both.reason?.contains('互斥') ?? false, '${both.reason}');

  // ============================================================ 纪律 11
  section('纪律 11：资金流必须挂在收付款单下');
  final Set<String> mainDocTypes = <String>{
    for (final Row r in db.raw.select('SELECT DISTINCT doc_type FROM documents'))
      r['doc_type']! as String,
  };
  final Row moneyOnMain = db.raw
      .select('''
        SELECT COUNT(*) AS c FROM money_ledger m
        JOIN documents d ON d.id = m.document_id
        WHERE d.doc_type NOT IN ('receipt', 'payment')
      ''')
      .first;
  check('money_ledger 未挂在任何主单上', moneyOnMain['c'] == 0, '${moneyOnMain['c']}');
  check('存在自动生成的收付款单',
      mainDocTypes.contains('receipt') && mainDocTypes.contains('payment'),
      '$mainDocTypes');

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
