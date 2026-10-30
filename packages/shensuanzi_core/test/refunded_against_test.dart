// `refundedAgainstCentsOf` 的口径迁移（用户裁定 2026-10-30 ⑥ 第二块）。
//
// ## 为什么单独一个文件
//
// 这个方法决定详情页「还欠客户退款 ¥X」显示多少。它从前读
// `SUM(documents.paid_amount)` —— 那是**派生缓存**（`Agents.md` §二·4），
// 真相在 `settlements`。
//
// 改它之前先做了**真库对拍**：4810 张有退货的原单，新旧算法 **0 差异** ——
// 说明这个库上缓存与真相没漂，可以安全迁移。
//
// 但「这个库没漂」不等于「永远不漂」。所以这里除了钉住正常值，还要钉住
// **缓存被写坏时以真相为准** —— 那才是改它的意义。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late RuleEngine engine;
  late SaleService sales;
  late ReturnService returns;
  late SettlementService settle;

  late String productId;
  late String accountId;
  late String customerId;

  setUp(() {
    resetClock();
    db = newMemoryDb();
    engine = RuleEngine(db);
    final QueryDao queries = QueryDao(db);
    sales = SaleService(engine: engine, queries: queries);
    returns = ReturnService(engine: engine, queries: queries);
    settle = SettlementService(db: db, engine: engine);

    final int t = now();
    final Product product = Product(
      id: newId(),
      code: 'P001',
      name: '纯牛奶',
      unit: '瓶',
      costPrice: 600,
      sellPrice: 1000,
      createdAt: t,
      updatedAt: t,
    );
    ProductDao(db).insert(product);
    productId = product.id;

    final Account cash = Account(
      id: newId(),
      name: '现金',
      type: AccountType.cash,
      createdAt: t,
      updatedAt: t,
    );
    AccountDao(db).insert(cash);
    accountId = cash.id;

    final Party customer = Party(
      id: newId(),
      name: '客户甲',
      roles: const <PartyRole>[PartyRole.customer],
      createdAt: t,
      updatedAt: t,
    );
    PartyDao(db).insert(customer);
    customerId = customer.id;
  });

  tearDown(() => db.close());

  String idOf(String docNo) =>
      db.raw.select('SELECT id FROM documents WHERE doc_no = ?', <Object?>[
            docNo,
          ]).first['id']!
          as String;

  String sell({required int qty, required int paidCents}) {
    final SaleSaved saved = sales.create(
      SaleDraft(
        partyId: customerId,
        partyName: '客户甲',
        date: '2026-10-04',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '$qty',
            unitPrice: '10',
          ),
        ],
        payments: paidCents > 0
            ? <SalePaymentDraft>[
                SalePaymentDraft(
                  accountId: accountId,
                  accountName: '现金',
                  amount: (paidCents / 100).toStringAsFixed(2),
                ),
              ]
            : const <SalePaymentDraft>[],
      ),
    );
    return idOf(saved.docNo);
  }

  /// 退货并立即退款；返回退货单 id。
  String doReturn({
    required String refDocId,
    required int qty,
    required int refundCents,
  }) {
    final ReturnSaved saved = returns.create(
      ReturnDraft(
        refDocId: refDocId,
        originalDocType: DocType.sale,
        partyId: customerId,
        partyName: '客户甲',
        lines: <ReturnLineDraft>[
          ReturnLineDraft(
            productId: productId,
            productName: '纯牛奶',
            quantity: '$qty',
            amount: (qty * 10).toStringAsFixed(2),
            originalQuantity: 100,
            originalAmountCents: 100000,
          ),
        ],
        refunds: refundCents > 0
            ? <ReturnRefundDraft>[
                ReturnRefundDraft(
                  accountId: accountId,
                  accountName: '现金',
                  amount: (refundCents / 100).toStringAsFixed(2),
                ),
              ]
            : const <ReturnRefundDraft>[],
      ),
    );
    return idOf(saved.docNo);
  }

  group('refundedAgainstCentsOf', () {
    test('正常路径：退 30 并退钱 ⇒ 已退 30', () {
      final String saleId = sell(qty: 10, paidCents: 10000);
      doReturn(refDocId: saleId, qty: 3, refundCents: 3000);

      expect(settle.refundedAgainstCentsOf(saleId), 3000);
    });

    test('挂账退货（不退钱）⇒ 已退 0', () {
      final String saleId = sell(qty: 10, paidCents: 10000);
      doReturn(refDocId: saleId, qty: 3, refundCents: 0);

      expect(settle.refundedAgainstCentsOf(saleId), 0);
    });

    test('多次退货累加', () {
      final String saleId = sell(qty: 10, paidCents: 10000);
      doReturn(refDocId: saleId, qty: 2, refundCents: 2000);
      doReturn(refDocId: saleId, qty: 1, refundCents: 1000);

      expect(settle.refundedAgainstCentsOf(saleId), 3000);
    });

    test('**缓存被写坏时以真相为准**（这是改它的意义）', () {
      // 造一张退 30、退了 30 的退货单
      final String saleId = sell(qty: 10, paidCents: 10000);
      final String returnId = doReturn(
        refDocId: saleId,
        qty: 3,
        refundCents: 3000,
      );
      expect(settle.refundedAgainstCentsOf(saleId), 3000);

      // 把退货单的 `paid_amount`（派生缓存）手工改成一个错的值。
      // `documents` 允许 UPDATE 的字段里就有 paid_amount（`Agents.md` §二·3），
      // 所以这在真实世界里**是可能发生的**（历史 bug / 手工改库 / 旧版本写坏）。
      db.raw.execute(
        'UPDATE documents SET paid_amount = 99999 WHERE id = ?',
        <Object?>[returnId],
      );

      expect(
        settle.refundedAgainstCentsOf(saleId),
        3000,
        reason: '真相在 settlements —— 缓存被写坏不该影响「已经退回去多少钱」',
      );
    });
  });
}
