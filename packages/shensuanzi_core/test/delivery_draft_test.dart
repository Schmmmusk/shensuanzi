// 送货开单草稿与提交服务（批次 1b / RULE-003），对应 `docs/testing.md`。
//
// ⚠️ **分工**：`delivery_test.dart` 测的是**引擎层**（`RuleEngine._delivery` /
// `markDelivered` 的状态机与副作用，651 行）；本文件测的是**服务层** ——
// 表单门槛（客户必选）、草稿 → `Document` 的形状转换、以及给 UI 的返回值。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；Windows 需要可用的 SQLite 原生库。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);
  setUp(resetClock);

  // ==================================================== 草稿校验（纯函数）
  group('DeliveryDraft 校验', () {
    /// 一份**能通过校验**的草稿（客户必选 + 一行 10 × 5.00 = 50.00）
    DeliveryDraft goodDraft({String? partyId = 'c1'}) => DeliveryDraft(
      partyId: partyId,
      partyName: '李姐',
      date: '2026-09-27',
      lines: const <DeliveryLineDraft>[
        DeliveryLineDraft(
          productId: 'p1',
          productName: '红富士苹果',
          quantity: '10',
          unitPrice: '5.00',
        ),
      ],
    );

    test('齐全 → 通过，合计 = 5000', () {
      final DeliveryDraft draft = goodDraft();
      expect(draft.validate(), isEmpty);
      expect(draft.validateLines().single, isEmpty);
      expect(draft.isValid, isTrue);
      expect(draft.totalCents, 5000);
    });

    test('**客户必选** —— 不选客户时报错，且文案说清「为什么」', () {
      final DeliveryDraft draft = goodDraft(partyId: null);
      expect(draft.validate()[DeliveryField.party], isNotNull);
      expect(
        draft.validate()[DeliveryField.party],
        contains('货出了门'),
        reason: '中老年用户被拦会以为软件坏了 ⇒ 文案要说清原因，不只是「必填」',
      );
      expect(draft.isValid, isFalse);
    });

    test('空客户字符串也算没选（不是 `null` 才算）', () {
      expect(
        DeliveryDraft(
          partyId: '',
          date: '2026-09-27',
          lines: const <DeliveryLineDraft>[
            DeliveryLineDraft(productId: 'p1', quantity: '1', unitPrice: '1'),
          ],
        ).validate()[DeliveryField.party],
        isNotNull,
      );
    });

    test('日期缺失 / 格式不对 → 报', () {
      expect(
        DeliveryDraft(partyId: 'c1', date: '').validate()[DeliveryField.date],
        contains('请填日期'),
      );
      expect(
        DeliveryDraft(partyId: 'c1', date: '2026/9/27')
            .validate()[DeliveryField.date],
        contains('格式不对'),
      );
    });

    test('一行都没有 → 报「至少要有一行」', () {
      expect(
        DeliveryDraft(partyId: 'c1', date: '2026-09-27')
            .validate()[DeliveryField.lines],
        contains('至少要有一行'),
      );
    });

    test('行级：数量非正 / 单价非法', () {
      DeliveryLineDraft line(String qty, String price) => DeliveryLineDraft(
        productId: 'p1',
        quantity: qty,
        unitPrice: price,
      );
      expect(line('0', '5').validate()[DeliveryLineField.quantity], isNotNull);
      expect(line('x', '5').validate()[DeliveryLineField.quantity], isNotNull);
      expect(line('1', '-1').validate()[DeliveryLineField.unitPrice], isNotNull);
      expect(line('1', '1.234').validate()[DeliveryLineField.unitPrice], isNotNull);
      expect(line('1', '5.00').validate(), isEmpty);
    });

    test('单价预填**售价**（不是进价）—— 送货送的是卖出去的货', () {
      const Product product = Product(
        id: 'p1',
        code: 'P001',
        name: '苹果',
        costPrice: 350,
        sellPrice: 500,
        createdAt: 1,
        updatedAt: 1,
      );
      final DeliveryLineDraft line = DeliveryLineDraft.fromProduct(product);
      expect(line.unitPrice, '5.00', reason: '售价 500 分 = 5.00 元');
      expect(line.quantity, '', reason: '数量待用户填');
    });

    test('⚠️ 草稿上**没有**收款这个概念（§AP：送货单本身就是赊销）', () {
      // 这条是**结构性断言**：往 `DeliveryDraft` 上传 payments 编译都不过。
      // 能跑到的部分只能说清「合计 = 全部金额，没有已收扣减」。
      expect(goodDraft().totalCents, 5000);
    });
  });

  // ==================================================== 提交服务（集成）
  group('DeliveryService.create', () {
    late Db db;
    late DeliveryService service;
    late ProductDao products;
    late PartyDao parties;
    late String productId;
    late String customerId;

    setUp(() {
      db = newMemoryDb();
      service = DeliveryService(
        engine: RuleEngine(db),
        queries: QueryDao(db),
      );
      products = ProductDao(db);
      parties = PartyDao(db);

      final int t = now();
      final Product product = Product(
        id: newId(),
        code: 'P001',
        name: '商品-P001',
        costPrice: 350,
        sellPrice: 500,
        createdAt: t,
        updatedAt: t,
      );
      products.insert(product);
      productId = product.id;

      final Party customer = Party(
        id: newId(),
        name: '李姐',
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      );
      parties.insert(customer);
      customerId = customer.id;
    });

    tearDown(() => db.close());

    DeliveryDraft draftWith({String? partyId, String qty = '10'}) => DeliveryDraft(
      partyId: partyId ?? customerId,
      partyName: '李姐',
      date: '2026-09-27',
      lines: <DeliveryLineDraft>[
        DeliveryLineDraft(
          productId: productId,
          productName: '商品-P001',
          quantity: qty,
          unitPrice: '5.00',
        ),
      ],
    );

    test('校验不通过 → 抛 DeliveryDraftInvalid（带字段级原因）', () {
      expect(
        () => service.create(draftWith(partyId: '')),
        throwsA(isA<DeliveryDraftInvalid>()),
      );

      DeliveryDraftInvalid? caught;
      try {
        service.create(draftWith(partyId: ''));
      } on DeliveryDraftInvalid catch (error) {
        caught = error;
      }
      expect(caught!.fieldErrors[DeliveryField.party], contains('货出了门'));
      expect(caught.summary, contains('货出了门'));
      expect(
        caught.lineErrors,
        isNotEmpty,
        reason: '与行级校验**按位置对齐**（界面据此标红）',
      );
    });

    test('成功：单号 SH… / 状态强制 in_transit / 库存 −qty / 欠款挂客户', () {
      final DeliverySaved saved = service.create(draftWith(), now: now());

      expect(saved.docNo.startsWith('SH'), isTrue, reason: '送货单号前缀 SH');
      expect(saved.totalCents, 5000);
      expect(saved.status, DocStatus.inTransit, reason: 'RULE-003 强制 in_transit');
      expect(saved.partyDueCents, 5000);

      // 货离店即扣库存（负库存允许 —— 送出去的时候可能账面已经不够）
      expect(QueryDao(db).stockByProduct()[productId], -10);
      // 往来：客户欠我 +5000
      expect(QueryDao(db).partyBalances()[customerId], 5000);
      // ⚠️ 送货单**不收钱** ⇒ 没有任何资金流水
      expect(
        db.raw.select('SELECT COUNT(*) AS c FROM money_ledger').first['c'],
        0,
      );
      // 在途视图（「在店可售」的水位线）
      expect(service.inTransitByProduct()[productId], 10);
    });

    test('连续两单 → 单号序号递增（主机生成，不是占位号）', () {
      final String first = service.create(draftWith(), now: now()).docNo;
      final String second = service.create(draftWith(), now: now()).docNo;
      expect(first, isNot(second));
      expect(first.contains(Document.pendingDocNoPrefix), isFalse);
      expect(second.contains(Document.pendingDocNoPrefix), isFalse);
    });

    test('明细行**真的落库**了（不是只写了主单）', () {
      final DeliverySaved saved = service.create(draftWith(), now: now());
      final DocumentSummary row = service
          .pendingDeliveries()
          .firstWhere((DocumentSummary s) => s.document.docNo == saved.docNo);
      final List<DocumentLine> lines = DocumentDao(db).linesOf(row.document.id);
      expect(lines.single.quantity, 10);
      expect(lines.single.unitPrice, 500);
      expect(lines.single.amount, 5000);
    });
  });

  // ==================================================== 签收（1b 第二个入口）
  group('DeliveryService 签收', () {
    late Db db;
    late DeliveryService service;
    late String customerId;

    setUp(() {
      db = newMemoryDb();
      service = DeliveryService(engine: RuleEngine(db), queries: QueryDao(db));

      final int t = now();
      final Product product = Product(
        id: newId(),
        code: 'P001',
        name: '苹果',
        costPrice: 350,
        sellPrice: 500,
        createdAt: t,
        updatedAt: t,
      );
      ProductDao(db).insert(product);
      final Party customer = Party(
        id: newId(),
        name: '李姐',
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      );
      PartyDao(db).insert(customer);
      customerId = customer.id;

      service.create(
        DeliveryDraft(
          partyId: customerId,
          partyName: '李姐',
          date: '2026-09-27',
          lines: <DeliveryLineDraft>[
            DeliveryLineDraft(
              productId: product.id,
              productName: '苹果',
              quantity: '10',
              unitPrice: '5.00',
            ),
          ],
        ),
        now: now(),
      );
    });

    tearDown(() => db.close());

    // ⚠️ group() 的函数体里**不能**用 getter（只能声明在类/库顶层）——
    // 用局部函数（§AT·八 记过同一个坑）
    String docId() => service.pendingDeliveries().single.document.id;

    test('待签收列表：只列 in_transit，且带回客户名', () {
      final List<DocumentSummary> pending = service.pendingDeliveries();
      expect(pending, hasLength(1));
      expect(pending.single.partyName, '李姐');
    });

    test('签收 → delivered，且**不再扣库存**', () {
      final DeliverySigned signed = service.markDelivered(docId(), now: now());
      expect(signed.alreadyDone, isFalse);
      expect(signed.status, DocStatus.delivered);
      expect(signed.message, contains('已签收'));
      expect(service.pendingDeliveries(), isEmpty);
      expect(QueryDao(db).stockByProduct().values.single, -10, reason: '签收不再扣');
    });

    test('**重复签收是 no-op**（不抛）—— 中老年用户多点一次不该看到报错', () {
      // ⚠️ id 必须**先取一次存下来**：签收成功后它就不在 `pendingDeliveries()` 里了，
      // 第二次再调 `docId()` 会 `single` 一个空列表（`Bad state: No element`）。
      final String id = docId();
      service.markDelivered(id, now: now());
      final DeliverySigned again = service.markDelivered(id, now: now());
      expect(again.alreadyDone, isTrue);
      expect(again.status, DocStatus.delivered);
      expect(
        again.message,
        contains('早就签收过了'),
        reason: '文案要说清「这次什么都没变」，不是报错',
      );
    });

    test('已收满款时签收 → 直接落到 settled（状态机补完）', () {
      // 先收满（1a 的核销路径）
      final String id = docId();
      final SettlementService settle = SettlementService(
        db: db,
        engine: RuleEngine(db),
      );
      final String accountId = newId();
      final int t = now();
      AccountDao(db).insert(
        Account(
          id: accountId,
          name: '现金',
          type: AccountType.cash,
          createdAt: t,
          updatedAt: t,
        ),
      );
      settle.settle(
        targetDocId: id,
        accountId: accountId,
        amountCents: 5000,
        now: now(),
      );

      final DeliverySigned signed = service.markDelivered(id, now: now());
      expect(signed.status, DocStatus.settled);
    });

    test('真错误仍抛：单据不存在', () {
      expect(() => service.markDelivered('没有这张单'), throwsStateError);
    });
  });
}
