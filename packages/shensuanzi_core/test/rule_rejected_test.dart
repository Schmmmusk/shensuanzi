// #23（2026-10-17 裁定甲）—— 业务拒绝的类型化出口。
//
// 覆盖：`*Service.create` 把 `RuleOutcome.rejected` 转成 `RuleRejected`
//（reason 给用户看、code 机读），不再包裸 `StateError` ⇒ UI 不再显示
// 「请再试一次」（重试必然再败）。核销路径（SettlementInvalid）是既有
// 正确先例 —— 本批把其余服务改成同款，并用桩引擎把「转换」钉住。
//
// ⚠️ stocktake 服务也类型化了（裁定④：防御性，无测试覆盖 —— 现无可达
// 拒绝，登记在 `docs/reply_review.md` §CV·五十六）。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；Windows 需要可用的 SQLite 原生库。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

import 'package:shensuanzi_core/sqlite_local.dart';
import 'support/fixtures.dart';

/// 测试桩：引擎恒拒绝（业务拒绝文案 + 码）—— 只为把「服务层把
/// `RuleOutcome.rejected` 转成 `RuleRejected`」这条转换钉住。
class _RejectingEngine extends RuleEngine {
  _RejectingEngine(super.db);

  @override
  RuleOutcome dispatch({
    required Document document,
    required int now,
    List<DocumentLine> lines = const <DocumentLine>[],
    Map<String, int>? stocktakeActual,
    List<PaymentEntry> immediatePayments = const <PaymentEntry>[],
    List<Allocation> allocations = const <Allocation>[],
  }) => RuleOutcome.rejected(
    '测试拒绝：请把金额改小',
    code: RejectCode.ruleValidationFailed,
  );

  @override
  RuleOutcome markDelivered({required String documentId, int? now}) =>
      RuleOutcome.rejected(
        '测试拒绝：签收被拒',
        code: RejectCode.ruleValidationFailed,
      );
}

/// #23 补丁桩：**协议违反**码（target_missing）—— 钉「非业务拒绝保持
/// StateError」这一分界（用户复跑抓出的回归）。
class _ProtocolEngine extends RuleEngine {
  _ProtocolEngine(super.db);

  @override
  RuleOutcome markDelivered({required String documentId, int? now}) =>
      RuleOutcome.rejected(malformedSyncRequestReason, code: RejectCode.targetMissing);
}

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late RuleEngine engine;
  late ProductDao products;
  late QueryDao queries;

  late DeliveryService deliveries;

  late String productId;
  late String customerId;
  late String supplierId;

  setUp(() {
    resetClock();
    db = newMemoryDb();
    engine = RuleEngine(db);
    products = ProductDao(db);
    queries = QueryDao(db);

    deliveries = DeliveryService(engine: engine, queries: queries);

    final int t = now();
    final Product product = Product(
      id: newId(),
      code: 'P001',
      name: '蒙牛纯牛奶',
      unit: '瓶',
      costPrice: 200,
      sellPrice: 250,
      createdAt: t,
      updatedAt: t,
    );
    products.insert(product);
    productId = product.id;

    final Party customer = Party(
      id: newId(),
      name: '客户甲',
      roles: const <PartyRole>[PartyRole.customer],
      createdAt: t,
      updatedAt: t,
    );
    PartyDao(db).insert(customer);
    customerId = customer.id;

    final Party supplier = Party(
      id: newId(),
      name: '供应商乙',
      roles: const <PartyRole>[PartyRole.supplier],
      createdAt: t,
      updatedAt: t,
    );
    PartyDao(db).insert(supplier);
    supplierId = supplier.id;
  });

  SaleDraft saleDraft() => SaleDraft(
    partyId: customerId,
    partyName: '客户甲',
    date: '2026-10-04',
    lines: <SaleLineDraft>[
      SaleLineDraft(
        productId: productId,
        productName: '蒙牛纯牛奶',
        quantity: '3',
        unitPrice: '250',
        entryUnit: '瓶',
        baseUnit: '瓶',
      ),
    ],
  );

  PurchaseDraft purchaseDraft() => PurchaseDraft(
    partyId: supplierId,
    partyName: '供应商乙',
    date: '2026-10-04',
    lines: <PurchaseLineDraft>[
      PurchaseLineDraft.fromProduct(
        products.findById(productId)!,
        quantity: '10',
      ),
    ],
  );

  DeliveryDraft deliveryDraft() => DeliveryDraft(
    partyId: customerId,
    partyName: '客户甲',
    date: '2026-10-04',
    lines: <DeliveryLineDraft>[
      DeliveryLineDraft.fromProduct(
        products.findById(productId)!,
        quantity: '12',
      ),
    ],
  );

  group('#23 规则拒绝 ⇒ RuleRejected（桩引擎钉转换）', () {
    test('SaleService.create ⇒ RuleRejected（reason 原样带出）', () {
      final SaleService rejecting = SaleService(
        engine: _RejectingEngine(db),
        queries: queries,
      );
      expect(
        () => rejecting.create(saleDraft()),
        throwsA(
          isA<RuleRejected>()
              .having((RuleRejected e) => e.reason, 'reason', '测试拒绝：请把金额改小')
              .having(
                (RuleRejected e) => e.code,
                'code',
                RejectCode.ruleValidationFailed,
              ),
        ),
      );
    });

    test('PurchaseService.create ⇒ RuleRejected', () {
      final PurchaseService rejecting = PurchaseService(
        engine: _RejectingEngine(db),
        queries: queries,
      );
      expect(
        () => rejecting.create(purchaseDraft()),
        throwsA(isA<RuleRejected>()),
      );
    });

    test('DeliveryService.create ⇒ RuleRejected', () {
      final DeliveryService rejecting = DeliveryService(
        engine: _RejectingEngine(db),
        queries: queries,
      );
      expect(
        () => rejecting.create(deliveryDraft()),
        throwsA(isA<RuleRejected>()),
      );
    });

    test('DeliveryService.markDelivered（签收）⇒ RuleRejected', () {
      // 先用真引擎建一张送货单（待签收），再用桩引擎签收 ⇒ 拒绝
      final DeliverySaved saved = deliveries.create(deliveryDraft());
      // 按单号反查 id（tests 里 SalesSaved 只带 docNo；用 raw SQL 免依赖 DAO 面）
      final String deliveryId =
          db.raw
              .select(
                'SELECT id FROM documents WHERE doc_no = ?',
                <Object?>[saved.docNo],
              )
              .first['id']! as String;
      final DeliveryService rejecting = DeliveryService(
        engine: _RejectingEngine(db),
        queries: queries,
      );
      expect(
        () => rejecting.markDelivered(deliveryId),
        throwsA(
          isA<RuleRejected>().having(
            (RuleRejected e) => e.reason,
            'reason',
            '测试拒绝：签收被拒',
          ),
        ),
      );
      // 拒绝后单据状态未变（仍待签收）
      expect(
        DocumentDao(db).findById(deliveryId)!.status,
        DocStatus.inTransit,
      );
    });

    test('SettlementInvalid 是 RuleRejected 的特化（核销先例统一类型）', () {
      expect(const SettlementInvalid('任意核销拒绝'), isA<RuleRejected>());
    });

    test('#23 补丁：协议违反（target_missing）不走 RuleRejected —— 保持 StateError', () {
      // 用户复跑抓出的回归：markDelivered 指向不存在的单 = 客户端 bug
      //（协议文档把 target_missing 归「协议违反」）⇒ 真错误语义（M15），
      // 不该伪装成「业务拒绝」给用户看一句「同步请求格式有误」。
      final DeliveryService rejecting = DeliveryService(
        engine: _ProtocolEngine(db),
        queries: queries,
      );
      expect(
        () => rejecting.markDelivered('没有这张单'),
        throwsStateError,
        reason: '真错误保持 StateError（UI 走通用 catch + 日志）',
      );
    });
  });
}
