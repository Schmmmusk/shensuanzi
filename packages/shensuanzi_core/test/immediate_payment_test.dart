// 方案 C：立即收付款自动生成收付款单（R-6 裁定，2026-09-25）。
// 对应 `docs/rules.md` §零 / RULE-001 / RULE-002，与 `docs/testing.md` D 组。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`（`test` 是 dev_dependency），
// 且 Windows 需要可用的 SQLite 原生库，见 `lib/sqlite_local.dart`。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'package:shensuanzi_core/sqlite_local.dart';
import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late RuleEngine engine;
  late ProductDao products;
  late AccountDao accounts;
  late DocumentDao documents;
  late StockLedgerDao stock;
  late MoneyLedgerDao money;
  late PartyLedgerDao partyLedger;
  late SettlementDao settlements;

  setUp(() {
    resetClock();
    db = newMemoryDb();
    engine = RuleEngine(db);
    products = ProductDao(db);
    accounts = AccountDao(db);
    documents = DocumentDao(db);
    stock = StockLedgerDao(db);
    money = MoneyLedgerDao(db);
    partyLedger = PartyLedgerDao(db);
    settlements = SettlementDao(db);
  });

  tearDown(() => db.close());

  String createProduct({String code = 'P001', int costPrice = 100}) {
    final int t = now();
    final Product p = Product(
      id: newId(),
      code: code,
      name: '商品-$code',
      costPrice: costPrice,
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

  String createParty({String name = '客户甲'}) {
    final int t = now();
    final Party p = Party(
      id: newId(),
      name: name,
      roles: const <PartyRole>[PartyRole.customer],
      createdAt: t,
      updatedAt: t,
    );
    PartyDao(db).insert(p);
    return p.id;
  }

  Document doc({
    required DocType type,
    String? partyId,
    String? accountId,
    required int totalAmount,
    String? refDocId,
    DocStatus status = DocStatus.confirmed,
  }) => Document(
    id: newId(),
    docNo: '${Document.pendingDocNoPrefix}abc123',
    docType: type,
    status: status,
    partyId: partyId,
    accountId: accountId,
    totalAmount: totalAmount,
    refDocId: refDocId,
    occurredAt: now(),
    createdAt: now(),
    updatedAt: now(),
  );

  int countOf(String table) =>
      db.raw.select('SELECT COUNT(*) AS c FROM $table').first['c']! as int;

  // ============================================================ RULE-002

  group('RULE-002 立即收款（方案 C）', () {
    test('全款现金 → 自动生成 receipt 单，status = settled，paid_amount = 总额', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final String accountId = createAccount();
      final Document sale = doc(
        type: DocType.sale,
        partyId: partyId,
        totalAmount: 5000,
      );

      final RuleOutcome outcome = engine.dispatch(
        document: sale,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: sale.id,
            productId: productId,
            quantity: 10,
            unitPrice: 500,
          ),
        ],
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: accountId, amount: 5000),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: '${outcome.reason}');

      final Document? main = documents.findById(sale.id);
      expect(main!.status, DocStatus.settled);
      expect(main.paidAmount, 5000);
      expect(main.totalAmount, 5000);

      // 自动生成的 receipt 单
      expect(countOf('documents'), 2, reason: 'sale + 自动 receipt');
      final Row auto = db.raw
          .select(
            'SELECT * FROM documents WHERE ref_doc_id = ? AND doc_type = ?',
            <Object?>[sale.id, 'receipt'],
          )
          .first;
      expect(auto['doc_no'].toString().startsWith('SK'), isTrue);
      expect(auto['total_amount'], 5000);
      expect(auto['status'], 'settled');
      expect(auto['paid_amount'], 0, reason: 'B4′：收付款单自身不出现在 target 侧');
      expect(auto['party_id'], partyId);
      expect(auto['account_id'], accountId);

      // 资金流水挂在收付款单下（纪律 11）
      final List<MoneyLedger> moneyRows = money.ofDocument(auto['id']! as String);
      expect(moneyRows.single.amount, 5000);
      expect(money.ofDocument(sale.id), isEmpty, reason: '主单不得直接写 money_ledger');

      // 核销关系
      expect(settlements.settledAmountOf(sale.id), 5000);
      expect(settlements.allocatedAmountOf(auto['id']! as String), 5000);

      // 往来净额为 0（欠款 +5000 后收款 -5000）
      expect(partyLedger.balanceOf(partyId), 0);

      // 库存已扣
      expect(stock.stockOf(productId), -10);
    });

    test('全赊 → 不生成 receipt 单，status = confirmed', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final Document sale = doc(
        type: DocType.sale,
        partyId: partyId,
        totalAmount: 5000,
      );

      engine.dispatch(
        document: sale,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: sale.id,
            productId: productId,
            quantity: 10,
            unitPrice: 500,
          ),
        ],
        now: now(),
      );

      expect(countOf('documents'), 1);
      expect(countOf('money_ledger'), 0);
      expect(documents.findById(sale.id)!.status, DocStatus.confirmed);
      expect(documents.findById(sale.id)!.paidAmount, 0);
      expect(partyLedger.balanceOf(partyId), 5000, reason: '客户欠我 5000');
    });

    test('部分收款 → status = confirmed，余款挂账（方案 B 无解的场景）', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final String accountId = createAccount();
      final Document sale = doc(
        type: DocType.sale,
        partyId: partyId,
        totalAmount: 5000,
      );

      engine.dispatch(
        document: sale,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: sale.id,
            productId: productId,
            quantity: 10,
            unitPrice: 500,
          ),
        ],
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: accountId, amount: 3000),
        ],
        now: now(),
      );

      final Document main = documents.findById(sale.id)!;
      expect(main.status, DocStatus.confirmed);
      expect(main.paidAmount, 3000);
      expect(money.balanceOf(accountId), 3000);
      expect(partyLedger.balanceOf(partyId), 2000, reason: '余 2000 挂账');
    });

    test('混合支付 → 生成两张 receipt 单', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final String cash = createAccount(name: '现金');
      final String wechat = createAccount(name: '微信');
      final Document sale = doc(
        type: DocType.sale,
        partyId: partyId,
        totalAmount: 5000,
      );

      engine.dispatch(
        document: sale,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: sale.id,
            productId: productId,
            quantity: 10,
            unitPrice: 500,
          ),
        ],
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: cash, amount: 2000),
          PaymentEntry(accountId: wechat, amount: 3000),
        ],
        now: now(),
      );

      expect(
        db.raw
            .select('SELECT COUNT(*) AS c FROM documents WHERE doc_type = ?', <Object?>[
              'receipt',
            ])
            .first['c'],
        2,
      );
      expect(documents.findById(sale.id)!.status, DocStatus.settled);
      expect(money.balanceOf(cash), 2000);
      expect(money.balanceOf(wechat), 3000);
      expect(partyLedger.balanceOf(partyId), 0);
    });

    test('收付款总额超过单据总额 → 拒绝，整单回滚', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final String accountId = createAccount();
      final Document sale = doc(
        type: DocType.sale,
        partyId: partyId,
        totalAmount: 5000,
      );

      final RuleOutcome outcome = engine.dispatch(
        document: sale,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: sale.id,
            productId: productId,
            quantity: 10,
            unitPrice: 500,
          ),
        ],
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: accountId, amount: 6000),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(countOf('documents'), 0);
      expect(countOf('money_ledger'), 0);
      expect(countOf('stock_ledger'), 0);
      expect(stock.stockOf(productId), 0);
    });

    test('有欠款但无 party_id → 拒绝（否则欠款凭空消失）', () {
      final String productId = createProduct();
      final Document sale = doc(type: DocType.sale, totalAmount: 5000);

      final RuleOutcome outcome = engine.dispatch(
        document: sale,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: sale.id,
            productId: productId,
            quantity: 10,
            unitPrice: 500,
          ),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.reason, contains('party_id'));
      expect(countOf('documents'), 0);
    });

    test('无 party_id 但立即全额收款 → 允许（零售散客，往来净额为 0）', () {
      final String productId = createProduct();
      final String accountId = createAccount();
      final Document sale = doc(type: DocType.sale, totalAmount: 5000);

      final RuleOutcome outcome = engine.dispatch(
        document: sale,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: sale.id,
            productId: productId,
            quantity: 10,
            unitPrice: 500,
          ),
        ],
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: accountId, amount: 5000),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: '${outcome.reason}');
      expect(partyLedger.balanceOf(''), 0);
      expect(countOf('party_ledger'), 0);
      expect(money.balanceOf(accountId), 5000);
    });
  });

  // ============================================================ RULE-001

  group('RULE-001 立即付款', () {
    test('全款采购付款 → 自动生成 payment 单，资金为负、欠款清零', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final String accountId = createAccount();
      final Document purchase = doc(
        type: DocType.purchase,
        partyId: partyId,
        totalAmount: 1000,
      );

      final RuleOutcome outcome = engine.dispatch(
        document: purchase,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: purchase.id,
            productId: productId,
            quantity: 10,
            unitPrice: 100,
          ),
        ],
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: accountId, amount: 1000),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: '${outcome.reason}');
      expect(documents.findById(purchase.id)!.status, DocStatus.settled);
      expect(money.balanceOf(accountId), -1000, reason: '支出 1000');
      expect(partyLedger.balanceOf(partyId), 0, reason: '欠款清零');
      expect(stock.stockOf(productId), 10);
      expect(
        db.raw
            .select('SELECT COUNT(*) AS c FROM documents WHERE doc_type = ?', <Object?>[
              'payment',
            ])
            .first['c'],
        1,
      );
    });
  });

  // ============================================================ RULE-004/005

  group('RULE-004 / RULE-005 手动核销', () {
    test('一收款核一单（部分）→ 主单 paid_amount 与 status 正确', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final String accountId = createAccount();

      // 赊账销售 5000
      final Document sale = doc(
        type: DocType.sale,
        partyId: partyId,
        totalAmount: 5000,
      );
      engine.dispatch(
        document: sale,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: sale.id,
            productId: productId,
            quantity: 10,
            unitPrice: 500,
          ),
        ],
        now: now(),
      );

      // 事后收 2000
      final Document receipt = doc(
        type: DocType.receipt,
        partyId: partyId,
        accountId: accountId,
        totalAmount: 2000,
      );
      final RuleOutcome outcome = engine.dispatch(
        document: receipt,
        allocations: <Allocation>[
          Allocation(targetDocId: sale.id, amount: 2000),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: '${outcome.reason}');
      expect(documents.findById(sale.id)!.paidAmount, 2000);
      expect(documents.findById(sale.id)!.status, DocStatus.confirmed);
      expect(money.balanceOf(accountId), 2000);
      expect(partyLedger.balanceOf(partyId), 3000);
    });

    test('收满 → status = settled', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final String accountId = createAccount();

      final Document sale = doc(
        type: DocType.sale,
        partyId: partyId,
        totalAmount: 5000,
      );
      engine.dispatch(
        document: sale,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: sale.id,
            productId: productId,
            quantity: 10,
            unitPrice: 500,
          ),
        ],
        now: now(),
      );

      // 先收 3000，再收 2000
      for (final int amount in <int>[3000, 2000]) {
        final Document receipt = doc(
          type: DocType.receipt,
          partyId: partyId,
          accountId: accountId,
          totalAmount: amount,
        );
        final RuleOutcome o = engine.dispatch(
          document: receipt,
          allocations: <Allocation>[
            Allocation(targetDocId: sale.id, amount: amount),
          ],
          now: now(),
        );
        expect(o.status, RuleStatus.applied, reason: '${o.reason}');
      }

      expect(documents.findById(sale.id)!.paidAmount, 5000);
      expect(documents.findById(sale.id)!.status, DocStatus.settled);
      expect(partyLedger.balanceOf(partyId), 0);
    });

    test('核销额超过被核销单未收金额 → 拒绝', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final String accountId = createAccount();

      final Document sale = doc(
        type: DocType.sale,
        partyId: partyId,
        totalAmount: 5000,
      );
      engine.dispatch(
        document: sale,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: sale.id,
            productId: productId,
            quantity: 10,
            unitPrice: 500,
          ),
        ],
        now: now(),
      );

      final Document receipt = doc(
        type: DocType.receipt,
        partyId: partyId,
        accountId: accountId,
        totalAmount: 6000,
      );
      final RuleOutcome outcome = engine.dispatch(
        document: receipt,
        allocations: <Allocation>[
          Allocation(targetDocId: sale.id, amount: 6000),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.reason, contains('超过被核销单未收金额'));
      expect(documents.findById(sale.id)!.paidAmount, 0);
    });

    test('预收（target_doc_id = null）→ 记录但不核销任何单', () {
      final String partyId = createParty();
      final String accountId = createAccount();
      final Document receipt = doc(
        type: DocType.receipt,
        partyId: partyId,
        accountId: accountId,
        totalAmount: 1000,
      );

      final RuleOutcome outcome = engine.dispatch(
        document: receipt,
        allocations: <Allocation>[
          const Allocation(targetDocId: null, amount: 1000),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied, reason: '${outcome.reason}');
      expect(money.balanceOf(accountId), 1000);
      expect(documents.findById(receipt.id)!.status, DocStatus.settled);
    });

    test('收付款单缺 account_id / party_id → 拒绝', () {
      final String partyId = createParty();
      final String accountId = createAccount();

      expect(
        engine.dispatch(
          document: doc(
            type: DocType.receipt,
            partyId: partyId,
            totalAmount: 100,
          ),
          now: now(),
        ).reason,
        contains('account_id'),
      );
      expect(
        engine.dispatch(
          document: doc(
            type: DocType.receipt,
            accountId: accountId,
            totalAmount: 100,
          ),
          now: now(),
        ).reason,
        contains('party_id'),
      );
    });
  });

  // ============================================================ 互斥

  group('payload 互斥（docs/sync_protocol.md §8.1）', () {
    test('immediate_payments 与 allocations 同时非空 → 拒绝', () {
      final String partyId = createParty();
      final String accountId = createAccount();
      final RuleOutcome outcome = engine.dispatch(
        document: doc(
          type: DocType.sale,
          partyId: partyId,
          totalAmount: 100,
        ),
        immediatePayments: <PaymentEntry>[
          PaymentEntry(accountId: accountId, amount: 100),
        ],
        allocations: <Allocation>[
          Allocation(targetDocId: null, amount: 100),
        ],
        now: now(),
      );
      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.reason, contains('互斥'));
    });
  });
}
