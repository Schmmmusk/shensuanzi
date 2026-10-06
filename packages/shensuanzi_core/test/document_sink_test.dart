// 「提交出口」抽象的测试（B3a·裁定 ①⑥⑦）。
//
// 分支表（reply.md 三 ①—⑦ → 用例）：
//
// | 输入 | 出口 | 期望 |
// |---|---|---|
// | 有效销售草稿 | ServiceSink | 落库：isQueued=false、正式单号、展示字段与直连服务**逐字段一致** |
// | 无效销售草稿 | ServiceSink | failure(SaleDraftInvalid)，**不落库** |
// | 有效销售草稿 | QueueSink | 入队：isQueued=true、占位单号、payload 逐字段合法 |
// | 无效销售草稿 | QueueSink | failure，**不入队**（裁定 ⑥） |
// | 采购超付 | QueueSink | 找回按草稿口径；paid = 封顶后 |
// | 送货草稿 | QueueSink | payload **无** immediate_payments 键 |
// | 同一草稿提交两次 | QueueSink | 两条队列条目（**无幂等** —— 裁定 ⑦：UI 防双击） |
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// 一套最小可开单环境（独立内存库）
class Env {
  Env() {
    sales = SaleService(engine: RuleEngine(db), queries: QueryDao(db));
    purchases = PurchaseService(engine: RuleEngine(db), queries: QueryDao(db));
    deliveries = DeliveryService(engine: RuleEngine(db), queries: QueryDao(db));
    sink = ServiceSink(
      sales: sales,
      purchases: purchases,
      deliveries: deliveries,
    );
    queueSink = QueueSink(queue: SyncQueueDao(db), clock: () => 1700000000000);
  }

  final Db db = newMemoryDb();
  late final SaleService sales;
  late final PurchaseService purchases;
  late final DeliveryService deliveries;
  late final ServiceSink sink;
  late final QueueSink queueSink;

  void seed({String costPrice = '3.50', String sellPrice = '5.00'}) {
    final int t = 1700000000000;
    ProductDao(db).insert(
      Product(
        id: productId,
        code: 'P001',
        name: '商品',
        costPrice: 350,
        sellPrice: 500,
        createdAt: t,
        updatedAt: t,
      ),
    );
    AccountDao(db).insert(
      Account(
        id: accountId,
        name: '现金',
        type: AccountType.cash,
        createdAt: t,
        updatedAt: t,
      ),
    );
    PartyDao(db).insert(
      Party(
        id: partyId,
        name: '李姐',
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      ),
    );
  }

  /// 先采购 10 件建正库存
  void stockUp() {
    purchases.create(
      PurchaseDraft(
        date: '2026-10-05',
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: productId,
            productName: '商品',
            quantity: '10',
            unitPrice: '3.50',
          ),
        ],
        payments: <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: accountId, amount: '35'),
        ],
      ),
      now: 1700000000000,
    );
  }

  int documentCount() => db.raw
      .select('SELECT COUNT(*) AS n FROM documents')
      .first['n']! as int;

  int queueCount() => SyncQueueDao(db).count();
}

void main() {
  group('ServiceSink（主机出口 —— 与直连服务逐字同行为）', () {
    test('submitSale 成功：isQueued=false、正式单号、展示字段与直连一致', () {
      final Env direct = Env()..seed()..stockUp();
      final Env viaSink = Env()..seed()..stockUp();

      final SaleDraft draft = SaleDraft(
        date: '2026-10-06',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: productId,
            productName: '商品',
            quantity: '2',
            unitPrice: '5.00',
          ),
        ],
        payments: <SalePaymentDraft>[
          SalePaymentDraft(accountId: accountId, amount: '10'),
        ],
      );

      final SaleSaved saved = direct.sales.create(draft);
      final DocumentSubmitResult result = viaSink.sink.submitSale(draft);

      expect(result.isFailure, isFalse);
      expect(result.isQueued, isFalse);
      expect(result.finalDocNo, startsWith('XS'), reason: '主机路径拿正式单号');
      expect(result.finalDocNo, saved.docNo);
      expect(result.totalCents, saved.totalCents);
      expect(result.paidCents, saved.paidCents);
      expect(result.dueCents, saved.dueCents);
      expect(result.partyDueCents, saved.partyDueCents);
      expect(result.changeCents, saved.changeCents);
      expect(viaSink.queueCount(), 0, reason: '主机路径不产生队列条目');
    });

    test('submitSale 校验失败 → failure（带原始 SaleDraftInvalid），不落库', () {
      final Env env = Env()..seed();
      final DocumentSubmitResult result = env.sink.submitSale(
        const SaleDraft(), // 没日期、没行
      );

      expect(result.isFailure, isTrue);
      expect(result.error, isA<SaleDraftInvalid>());
      expect(result.error!.summary, isNotEmpty);
      expect(result.finalDocNo, '');
      expect(env.documentCount(), 0);
    });
  });

  group('QueueSink（客户端出口 —— 校验 → 入队，不落库不跑规则）', () {
    test('submitSale 成功：isQueued=true、占位单号、队列 1 条', () {
      final Env env = Env()..seed();
      final DocumentSubmitResult result = env.queueSink.submitSale(
        SaleDraft(
          date: '2026-10-06',
          lines: <SaleLineDraft>[
            SaleLineDraft(
              productId: productId,
              productName: '商品',
              quantity: '2',
              unitPrice: '5.00',
            ),
          ],
          payments: <SalePaymentDraft>[
            SalePaymentDraft(accountId: accountId, amount: '10'),
          ],
        ),
      );

      expect(result.isFailure, isFalse);
      expect(result.isQueued, isTrue);
      expect(result.finalDocNo, startsWith(Document.pendingDocNoPrefix));
      expect(result.totalCents, 1000);
      expect(result.paidCents, 1000);
      expect(result.dueCents, 0);
      expect(result.changeCents, 0);
      expect(result.status, DocStatus.confirmed);
      expect(env.documentCount(), 0, reason: '客户端不落库');
      expect(env.queueCount(), 1);
      expect(result.documentId, isNotNull);
    });

    test('submitSale 校验失败 → failure，**不入队**（裁定 ⑥）', () {
      final Env env = Env()..seed();
      final DocumentSubmitResult result = env.queueSink.submitSale(
        const SaleDraft(),
      );

      expect(result.isFailure, isTrue);
      expect(result.error, isA<SaleDraftInvalid>());
      expect(env.queueCount(), 0);
      expect(env.documentCount(), 0);
    });

    test('payload 逐字段合法：id = entity_id、无主机专属列、lines/payments 齐', () {
      final Env env = Env()..seed();
      final DocumentSubmitResult result = env.queueSink.submitSale(
        SaleDraft(
          date: '2026-10-06',
          lines: <SaleLineDraft>[
            SaleLineDraft(
              productId: productId,
              productName: '商品',
              quantity: '2',
              unitPrice: '5.00',
            ),
          ],
          payments: <SalePaymentDraft>[
            SalePaymentDraft(accountId: accountId, amount: '10'),
          ],
        ),
      );

      final SyncQueueEntry entry = SyncQueueDao(env.db).all().single;
      expect(entry.entity, Schema.documents);
      expect(entry.operation, SyncOpType.createDocument);
      expect(entry.entityId, result.documentId);
      expect(entry.status, SyncQueueStatus.pending);

      final Map<String, Object?> payload = entry.payload;
      final Object? rawDocument = payload['document'];
      expect(rawDocument, isA<Map<String, Object?>>());
      final Map<String, Object?> document = rawDocument! as Map<String, Object?>;
      expect(document['id'], entry.entityId, reason: '幂等键必须一致（§二）');
      expect(document['doc_type'], 'sale');
      expect(document['status'], 'confirmed');
      expect(
        document.keys,
        isNot(anyOf(contains('paid_amount'), contains('created_at'), contains('updated_at'))),
        reason: '主机专属列不上 wire（hostOnlyColumns）',
      );

      final Object? rawLines = payload['lines'];
      expect(rawLines, isA<List<Object?>>());
      final List<Object?> lines = rawLines! as List<Object?>;
      expect(lines, hasLength(1));
      final Map<String, Object?> line = lines.single! as Map<String, Object?>;
      expect(line['id'], isNotEmpty, reason: 'wire 行含客户端生成的 id');
      expect(line['product_id'], productId);
      expect(line['quantity'], 2);

      final Object? rawPayments = payload['immediate_payments'];
      expect(rawPayments, isA<List<Object?>>());
      final Map<String, Object?> payment =
          (rawPayments! as List<Object?>).single! as Map<String, Object?>;
      expect(payment['account_id'], accountId);
      expect(payment['amount'], 1000);

      // 客户端的「未同步影响」直接吃这条 payload —— 签名必须对上
      expect(SyncClient.deltaOf(entry), <String, int>{productId: -2});
    });

    test('submitDelivery：payload **无** immediate_payments 键（送货没有收款区）', () {
      final Env env = Env()..seed();
      final DocumentSubmitResult result = env.queueSink.submitDelivery(
        DeliveryDraft(
          partyId: partyId,
          date: '2026-10-06',
          lines: <DeliveryLineDraft>[
            DeliveryLineDraft(
              productId: productId,
              productName: '商品',
              quantity: '4',
              unitPrice: '6.00',
            ),
          ],
        ),
      );

      expect(result.isFailure, isFalse);
      expect(result.isQueued, isTrue);
      expect(result.status, DocStatus.inTransit);
      expect(result.paidCents, 0);
      expect(result.dueCents, 0);
      expect(result.partyDueCents, isNull, reason: '客户端算不出累计欠款 —— 诚实给 null');

      final SyncQueueEntry entry = SyncQueueDao(env.db).all().single;
      expect(entry.payload.containsKey('immediate_payments'), isFalse);
      expect(SyncClient.deltaOf(entry), <String, int>{productId: -4});
    });

    test('submitPurchase 超付：paid = 封顶后 3500，找回 1500 按草稿口径', () {
      final Env env = Env()..seed();
      final DocumentSubmitResult result = env.queueSink.submitPurchase(
        PurchaseDraft(
          date: '2026-10-06',
          lines: <PurchaseLineDraft>[
            PurchaseLineDraft(
              productId: productId,
              productName: '商品',
              quantity: '10',
              unitPrice: '3.50',
            ),
          ],
          payments: <PurchasePaymentDraft>[
            PurchasePaymentDraft(accountId: accountId, amount: '50'),
          ],
        ),
      );

      expect(result.isQueued, isTrue);
      expect(result.totalCents, 3500);
      expect(result.paidCents, 3500, reason: 'payload 收付款 = 封顶后金额');
      expect(result.dueCents, 0);
      expect(result.changeCents, 1500);

      final SyncQueueEntry entry = SyncQueueDao(env.db).all().single;
      final Map<String, Object?> payment =
          (entry.payload['immediate_payments']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(payment['amount'], 3500);
      expect(SyncClient.deltaOf(entry), <String, int>{productId: 10});
    });

    test('同一草稿提交两次 → 两条条目（无幂等 —— 裁定 ⑦：UI 必须防双击）', () {
      final Env env = Env()..seed();
      // ⚠️ 草稿必须**合法**（挂客户）—— 散客不结清会被校验拦下（裁定 ⑥），
      // 这里要测的是「合法草稿重复提交」的入队行为。
      SaleDraft makeDraft() => SaleDraft(
        partyId: partyId,
        date: '2026-10-06',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: productId,
            productName: '商品',
            quantity: '1',
            unitPrice: '5.00',
          ),
        ],
      );

      final DocumentSubmitResult first = env.queueSink.submitSale(makeDraft());
      final DocumentSubmitResult second = env.queueSink.submitSale(makeDraft());

      expect(first.isQueued, isTrue, reason: first.error?.summary);
      expect(second.isQueued, isTrue, reason: second.error?.summary);
      expect(env.queueCount(), 2, reason: 'enqueue 不按 entity_id 判重（现状钉住）');
      expect(first.documentId, isNot(second.documentId));
    });
  });
}
