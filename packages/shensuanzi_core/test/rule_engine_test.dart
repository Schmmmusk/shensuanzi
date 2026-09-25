// 业务规则：RULE-001 采购入库、RULE-009 盘点。
// 对应 `docs/rules.md` 与 `docs/testing.md`（B 不变量 / C 业务规则 / F 盘点）。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`（`test` 是 dev_dependency），
// 且 Windows 需要可用的 SQLite 原生库，见 `lib/sqlite_local.dart`。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

import 'package:shensuanzi_core/sqlite_local.dart';
import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late RuleEngine engine;
  late ProductDao products;
  late PartyDao parties;
  late DocumentDao documents;
  late StockLedgerDao stock;
  late PartyLedgerDao partyLedger;

  /// 默认供应商。
  ///
  /// 方案 C 起：**有欠款就必须有 `party_id`**（否则主单的往来流水被跳过、
  /// 欠款凭空消失），因此 `pendingDoc()` 默认带上它。
  late String supplierId;

  // ⚠️ 这两个工厂必须声明在 `setUp` **之前** —— Dart 的局部函数不能前向引用，
  // 而 setUp 里要用到 `createParty`。
  String createProduct({String code = 'P001', int costPrice = 100}) {
    final int t = now();
    final Product product = Product(
      id: newId(),
      code: code,
      name: '商品-$code',
      costPrice: costPrice,
      createdAt: t,
      updatedAt: t,
    );
    products.insert(product);
    return product.id;
  }

  String createParty({String name = '供应商甲'}) {
    final int t = now();
    final Party party = Party(
      id: newId(),
      name: name,
      roles: const <PartyRole>[PartyRole.supplier],
      createdAt: t,
      updatedAt: t,
    );
    parties.insert(party);
    return party.id;
  }

  setUp(() {
    resetClock();
    db = newMemoryDb();
    engine = RuleEngine(db);
    products = ProductDao(db);
    parties = PartyDao(db);
    documents = DocumentDao(db);
    stock = StockLedgerDao(db);
    partyLedger = PartyLedgerDao(db);
    supplierId = createParty(name: '默认供应商');
  });

  tearDown(() => db.close());

  /// 用**临时展示号**建单 —— 模拟客户端离线开单（正式号由主机分配）
  ///
  /// [partyId] 省略时用 [supplierId]；要测"确实没有往来方"请传 `noParty: true`。
  Document pendingDoc({
    required DocType type,
    String? partyId,
    bool noParty = false,
    int totalAmount = 0,
    DocStatus status = DocStatus.confirmed,
  }) => Document(
    id: newId(),
    docNo: '${Document.pendingDocNoPrefix}abc123',
    docType: type,
    status: status,
    partyId: noParty ? null : (partyId ?? supplierId),
    totalAmount: totalAmount,
    occurredAt: now(),
    createdAt: now(),
    updatedAt: now(),
  );

  // ============================================================ RULE-001

  group('RULE-001 采购入库', () {
    test('库存 + ，成本 = 数量 × 单价', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final Document doc = pendingDoc(
        type: DocType.purchase,
        partyId: partyId,
        totalAmount: 1000,
      );
      final List<DocumentLine> lines = <DocumentLine>[
        DocumentLine.create(
          documentId: doc.id,
          productId: productId,
          quantity: 10,
          unitPrice: 100,
        ),
      ];

      final RuleOutcome outcome = engine.dispatch(
        document: doc,
        lines: lines,
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied);
      expect(outcome.reason, isNull);
      expect(stock.stockOf(productId), 10);

      final StockLedger entry = stock.ofProduct(productId).single;
      expect(entry.quantity, 10);
      expect(entry.totalCost, 1000);
      expect(entry.unitCostValue, 100);
      expect(entry.seqNo, 1);
    });

    test('往来 -total_amount（我欠供应商），且不生成资金流水', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final Document doc = pendingDoc(
        type: DocType.purchase,
        partyId: partyId,
        totalAmount: 1000,
      );

      engine.dispatch(
        document: doc,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: doc.id,
            productId: productId,
            quantity: 10,
            unitPrice: 100,
          ),
        ],
        now: now(),
      );

      expect(partyLedger.balanceOf(partyId), -1000);
      expect(partyLedger.ofParty(partyId).single.seqNo, 1);
      expect(
        db.raw.select('SELECT COUNT(*) AS c FROM money_ledger').first['c'],
        0,
        reason: 'RULE-001 明确不生成 MoneyLedger',
      );
    });

    test('主机分配正式单号，替换客户端的临时展示号', () {
      final String productId = createProduct();
      final Document doc = pendingDoc(type: DocType.purchase, totalAmount: 100);

      final RuleOutcome outcome = engine.dispatch(
        document: doc,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: doc.id,
            productId: productId,
            quantity: 1,
            unitPrice: 100,
          ),
        ],
        now: now(),
      );

      final String docNo = outcome.document!.docNo;
      expect(docNo.startsWith('CG'), isTrue, reason: '实际 $docNo');
      expect(docNo.endsWith('-001'), isTrue, reason: '实际 $docNo');
      expect(Document.isPendingDocNo(docNo), isFalse);
      expect(documents.findById(doc.id)!.docNo, docNo);
    });

    test('已给定正式单号时原样保留', () {
      final String productId = createProduct();
      final Document doc = Document(
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

      final RuleOutcome outcome = engine.dispatch(
        document: doc,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: doc.id,
            productId: productId,
            quantity: 1,
            unitPrice: 100,
          ),
        ],
        now: now(),
      );

      expect(outcome.document!.docNo, 'CG20260101-042');
    });

    test('幂等：同一单据推送两次 → alreadyExists，且无重复流水', () {
      final String productId = createProduct();
      final String partyId = createParty();
      final Document doc = pendingDoc(
        type: DocType.purchase,
        partyId: partyId,
        totalAmount: 1000,
      );
      final List<DocumentLine> lines = <DocumentLine>[
        DocumentLine.create(
          documentId: doc.id,
          productId: productId,
          quantity: 10,
          unitPrice: 100,
        ),
      ];

      expect(
        engine.dispatch(document: doc, lines: lines, now: now()).status,
        RuleStatus.applied,
      );
      expect(
        engine.dispatch(document: doc, lines: lines, now: now()).status,
        RuleStatus.alreadyExists,
      );

      expect(documents.findById(doc.id), isNotNull);
      expect(stock.ofProduct(productId).length, 1, reason: '不得重复写流水');
      expect(partyLedger.ofParty(partyId).length, 1);
      expect(stock.stockOf(productId), 10, reason: '库存不得翻倍');
    });

    test('方案 C：有欠款但无 party_id → 拒绝（否则欠款凭空消失）', () {
      final String productId = createProduct();
      final Document doc = pendingDoc(
        type: DocType.purchase,
        noParty: true,
        totalAmount: 100,
      );

      final RuleOutcome outcome = engine.dispatch(
        document: doc,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: doc.id,
            productId: productId,
            quantity: 1,
            unitPrice: 100,
          ),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.reason, contains('party_id'));
      expect(documents.findById(doc.id), isNull, reason: '整单回滚');
      // 「无 party 但立即全额付款 → 允许（零售散客）」的正向用例见
      // test/immediate_payment_test.dart
    });

    test('明细金额之和与总额不符 → 拒绝，且整单无残留', () {
      final String productId = createProduct();
      final Document doc = pendingDoc(type: DocType.purchase, totalAmount: 999);

      final RuleOutcome outcome = engine.dispatch(
        document: doc,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: doc.id,
            productId: productId,
            quantity: 10,
            unitPrice: 100, // 1000 ≠ 999
          ),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.reason, contains('不变量 B5'));
      expect(documents.findById(doc.id), isNull, reason: '整单回滚');
      expect(stock.stockOf(productId), 0);
    });

    test('数量非正 → 拒绝，且整单无残留', () {
      final String productId = createProduct();
      final Document doc = pendingDoc(type: DocType.purchase, totalAmount: 0);

      final RuleOutcome outcome = engine.dispatch(
        document: doc,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: doc.id,
            productId: productId,
            quantity: 0,
            unitPrice: 100,
          ),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(documents.findById(doc.id), isNull);
    });

    test('seq_no 每表独立，多次入库按 1 递增', () {
      final String productId = createProduct();
      for (int i = 0; i < 3; i++) {
        final Document doc = pendingDoc(type: DocType.purchase, totalAmount: 100);
        engine.dispatch(
          document: doc,
          lines: <DocumentLine>[
            DocumentLine.create(
              documentId: doc.id,
              productId: productId,
              quantity: 1,
              unitPrice: 100,
            ),
          ],
          now: now(),
        );
      }
      expect(
        stock.ofProduct(productId).map((StockLedger e) => e.seqNo).toList(),
        <int>[1, 2, 3],
      );
    });
  });

  // ============================================================ RULE-009

  group('RULE-009 盘点', () {
    Future<void> seedPurchase(String productId, int quantity, int unitPrice) async {
      final Document doc = pendingDoc(
        type: DocType.purchase,
        totalAmount: quantity * unitPrice,
      );
      engine.dispatch(
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

    test('盘盈：diff > 0，成本用当前加权均价，库存 = 实际数量', () {
      final String productId = createProduct();
      seedPurchase(productId, 10, 100);

      final Document doc = pendingDoc(
        type: DocType.stocktake,
        totalAmount: 0,
      );
      final RuleOutcome outcome = engine.dispatch(
        document: doc,
        stocktakeActual: <String, int>{productId: 12},
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied);
      expect(stock.stockOf(productId), 12, reason: '盘点后库存 = 实际数量');

      final StockLedger surplus = stock.ofProduct(productId).last;
      expect(surplus.quantity, 2);
      expect(surplus.totalCost, 200, reason: '10 件均价 100 → 盘盈 2 件成本 200');
      expect(surplus.unitCostValue, 100);
    });

    test('盘亏：diff < 0，成本按出库口径', () {
      final String productId = createProduct();
      seedPurchase(productId, 12, 100);

      final Document doc = pendingDoc(type: DocType.stocktake, totalAmount: 0);
      engine.dispatch(
        document: doc,
        stocktakeActual: <String, int>{productId: 10},
        now: now(),
      );

      expect(stock.stockOf(productId), 10);
      final StockLedger shortage = stock.ofProduct(productId).last;
      expect(shortage.quantity, -2);
      expect(shortage.totalCost, -200, reason: '1200 / 12 × (-2) = -200');
    });

    test('盘亏成本用 round-half-up，不是截断（`~/` 会算错）', () {
      final String productId = createProduct();
      // 分 3 行入库：100 + 101 + 101 = 302，均价 = 302/3 = 100.666…
      final Document doc = pendingDoc(type: DocType.purchase, totalAmount: 302);
      engine.dispatch(
        document: doc,
        lines: <DocumentLine>[
          for (final int price in <int>[100, 101, 101])
            DocumentLine.create(
              documentId: doc.id,
              productId: productId,
              quantity: 1,
              unitPrice: price,
            ),
        ],
        now: now(),
      );
      expect(stock.costSnapshotOf(productId).totalCost, 302);

      final Document take = pendingDoc(type: DocType.stocktake, totalAmount: 0);
      engine.dispatch(
        document: take,
        stocktakeActual: <String, int>{productId: 2},
        now: now(),
      );

      final StockLedger shortage = stock.ofProduct(productId).last;
      expect(shortage.quantity, -1);
      expect(
        shortage.totalCost,
        -101,
        reason: '302 × (-1) / 3 = -100.666… → round-half-up → -101；'
            '若用 ~/ 截断会得到 -100（成本系统性偏低）',
      );
    });

    test('diff = 0 不产生流水', () {
      final String productId = createProduct();
      seedPurchase(productId, 10, 100);

      final Document doc = pendingDoc(type: DocType.stocktake, totalAmount: 0);
      engine.dispatch(
        document: doc,
        stocktakeActual: <String, int>{productId: 10},
        now: now(),
      );

      expect(stock.ofProduct(productId).length, 1, reason: '只应有那次入库');
      expect(stock.stockOf(productId), 10);
    });

    test('盘点不生成往来与资金流水', () {
      final String productId = createProduct();
      seedPurchase(productId, 10, 100);

      // ⚠️ 必须用「盘点前后是否变化」判断，不能用绝对行数 ——
      // 种子采购本身会写一条 party_ledger（方案 C 起采购默认带往来方）。
      final int moneyBefore = db.raw
          .select('SELECT COUNT(*) AS c FROM money_ledger')
          .first['c']! as int;
      final int partyBefore = db.raw
          .select('SELECT COUNT(*) AS c FROM party_ledger')
          .first['c']! as int;

      final Document doc = pendingDoc(type: DocType.stocktake, totalAmount: 0);
      engine.dispatch(
        document: doc,
        stocktakeActual: <String, int>{productId: 15},
        now: now(),
      );

      expect(
        db.raw.select('SELECT COUNT(*) AS c FROM money_ledger').first['c'],
        moneyBefore,
        reason: '盘点不产生资金流出',
      );
      expect(
        db.raw.select('SELECT COUNT(*) AS c FROM party_ledger').first['c'],
        partyBefore,
        reason: '盘亏只通过 stock_ledger.total_cost 进入毛利，不产生资金流出',
      );
    });

    test('total_amount 必须为 0，否则拒绝', () {
      final String productId = createProduct();
      final Document doc = pendingDoc(type: DocType.stocktake, totalAmount: 500);

      final RuleOutcome outcome = engine.dispatch(
        document: doc,
        stocktakeActual: <String, int>{productId: 1},
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.reason, contains('total_amount 必须为 0'));
      expect(documents.findById(doc.id), isNull);
    });

    test('盘点数量为负 → 拒绝', () {
      final String productId = createProduct();
      final Document doc = pendingDoc(type: DocType.stocktake, totalAmount: 0);

      final RuleOutcome outcome = engine.dispatch(
        document: doc,
        stocktakeActual: <String, int>{productId: -1},
        now: now(),
      );

      expect(outcome.status, RuleStatus.rejected);
      expect(documents.findById(doc.id), isNull);
    });

    test('可以直接从 lines 取实际数量（quantity 即实际数量）', () {
      final String productId = createProduct();
      seedPurchase(productId, 5, 100);

      final Document doc = pendingDoc(type: DocType.stocktake, totalAmount: 0);
      final RuleOutcome outcome = engine.dispatch(
        document: doc,
        lines: <DocumentLine>[
          DocumentLine(
            id: newId(),
            documentId: doc.id,
            productId: productId,
            quantity: 8,
            unitPrice: 0,
            amount: 0,
          ),
        ],
        now: now(),
      );

      expect(outcome.status, RuleStatus.applied);
      expect(stock.stockOf(productId), 8);
    });
  });

  // ============================================================ 分派边界

  group('dispatch 边界', () {
    test('transfer 被拒绝（v1 无对应规则）', () {
      final Document doc = pendingDoc(type: DocType.transfer, totalAmount: 0);
      final RuleOutcome outcome = engine.dispatch(document: doc, now: now());
      expect(outcome.status, RuleStatus.rejected);
      expect(outcome.reason, contains('尚未实现'));
      expect(documents.findById(doc.id), isNull);
    });

    test('唯一落到「尚未实现」分支的 doc_type 是 transfer', () {
      // 用**差集**而不是硬编码列举：将来新增 doc_type 时会在这里失败，
      // 而不是被静默漏掉（历史上出现过「用例因错误理由通过」）。
      // delivery / sale_return / purchase_return 的细则见 delivery_test / return_test。
      const Set<DocType> implemented = <DocType>{
        DocType.purchase,
        DocType.sale,
        DocType.delivery,
        DocType.saleReturn,
        DocType.purchaseReturn,
        DocType.stocktake,
        DocType.receipt,
        DocType.payment,
      };
      final Set<DocType> notImplemented = DocType.values.toSet()
        ..removeAll(implemented);
      expect(notImplemented, <DocType>{DocType.transfer});
    });
  });

  // ============================================================ 不变量

  group('不变量（docs/data_model.md §五）', () {
    test('库存 = SUM(stock_ledger.quantity)', () {
      final String productId = createProduct();
      for (final int qty in <int>[10, 5, 3]) {
        final Document doc = pendingDoc(
          type: DocType.purchase,
          totalAmount: qty * 100,
        );
        engine.dispatch(
          document: doc,
          lines: <DocumentLine>[
            DocumentLine.create(
              documentId: doc.id,
              productId: productId,
              quantity: qty,
              unitPrice: 100,
            ),
          ],
          now: now(),
        );
      }
      final int sum = db.raw
          .select(
            'SELECT COALESCE(SUM(quantity), 0) AS s FROM stock_ledger WHERE product_id = ?',
            <Object?>[productId],
          )
          .first['s']! as int;
      expect(stock.stockOf(productId), sum);
      expect(sum, 18);
    });

    test('往来余额 = SUM(party_ledger.amount)', () {
      final String productId = createProduct();
      final String partyId = createParty();
      for (final int total in <int>[1000, 500]) {
        final Document doc = pendingDoc(
          type: DocType.purchase,
          partyId: partyId,
          totalAmount: total,
        );
        engine.dispatch(
          document: doc,
          lines: <DocumentLine>[
            DocumentLine.create(
              documentId: doc.id,
              productId: productId,
              quantity: total ~/ 100,
              unitPrice: 100,
            ),
          ],
          now: now(),
        );
      }
      expect(partyLedger.balanceOf(partyId), -1500, reason: '我欠供应商 1500 分');
    });
  });

  // ============================================================ 事务硬约束

  group('事务硬约束', () {
    test('SeqCounter 在事务外调用 → StateError', () {
      expect(
        () => SeqCounter(db).nextStock(),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('必须在事务内分配'),
          ),
        ),
      );
    });

    test('DocNoGenerator 在事务外调用 → StateError', () {
      expect(
        () => DocNoGenerator(db).next(DocType.purchase, occurredAtMs: now()),
        throwsA(isA<StateError>()),
      );
    });

    test('dispatch 结束后不残留事务状态', () {
      final String productId = createProduct();
      final Document doc = pendingDoc(type: DocType.purchase, totalAmount: 100);
      engine.dispatch(
        document: doc,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: doc.id,
            productId: productId,
            quantity: 1,
            unitPrice: 100,
          ),
        ],
        now: now(),
      );
      expect(db.inTransaction, isFalse);
    });
  });
}
