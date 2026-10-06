// 核销服务（`SettlementService`，批次 1a / `docs/reply_review.md` §AO）。
//
// 覆盖：方向判定 / 两条文案纯函数 / 成功核销（全额 + 部分 + 采购方向）/
// 四类拒绝（找不到单 / 类型不可核销 / 金额 ≤ 0 / 超收）。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；Windows 需要可用的 SQLite 原生库。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late RuleEngine engine;
  late SettlementService service;
  late DocumentDao documents;

  setUp(() {
    resetClock();
    db = newMemoryDb();
    engine = RuleEngine(db);
    service = SettlementService(db: db, engine: engine);
    documents = DocumentDao(db);
  });

  tearDown(() => db.close());

  // ---------------------------------------------------------------- 造数

  String createProduct() {
    final Product p = Product(
      id: newId(),
      code: 'P-${newId().substring(0, 6)}',
      name: '商品',
      costPrice: 100,
      createdAt: now(),
      updatedAt: now(),
    );
    ProductDao(db).insert(p);
    return p.id;
  }

  String createAccount() {
    final Account a = Account(
      id: newId(),
      name: '现金',
      type: AccountType.cash,
      createdAt: now(),
      updatedAt: now(),
    );
    AccountDao(db).insert(a);
    return a.id;
  }

  String createParty() {
    final Party p = Party(
      id: newId(),
      name: '老王批发',
      roles: const <PartyRole>[PartyRole.customer, PartyRole.supplier],
      createdAt: now(),
      updatedAt: now(),
    );
    PartyDao(db).insert(p);
    return p.id;
  }

  /// 造一张赊账 **销售单**（无立即收款）
  Document saleOnCredit(String productId, String partyId, int totalCents) {
    final Document d = Document(
      id: newId(),
      docNo: '${Document.pendingDocNoPrefix}${newId().substring(0, 8)}',
      docType: DocType.sale,
      status: DocStatus.confirmed,
      partyId: partyId,
      totalAmount: totalCents,
      occurredAt: now(),
      createdAt: now(),
      updatedAt: now(),
    );
    final RuleOutcome outcome = engine.dispatch(
      document: d,
      lines: <DocumentLine>[
        DocumentLine.create(
          documentId: d.id,
          productId: productId,
          quantity: 1,
          unitPrice: totalCents,
        ),
      ],
      now: now(),
    );
    expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
    return d;
  }

  /// 造一张赊账 **采购单**（无立即付款）
  Document purchaseOnCredit(String productId, String partyId, int totalCents) {
    final Document d = Document(
      id: newId(),
      docNo: '${Document.pendingDocNoPrefix}${newId().substring(0, 8)}',
      docType: DocType.purchase,
      status: DocStatus.confirmed,
      partyId: partyId,
      totalAmount: totalCents,
      occurredAt: now(),
      createdAt: now(),
      updatedAt: now(),
    );
    final RuleOutcome outcome = engine.dispatch(
      document: d,
      lines: <DocumentLine>[
        DocumentLine.create(
          documentId: d.id,
          productId: productId,
          quantity: 1,
          unitPrice: totalCents,
        ),
      ],
      now: now(),
    );
    expect(outcome.status, RuleStatus.applied, reason: outcome.reason);
    return d;
  }

  // ============================================================ 方向判定

  group('SettlementService.isInbound', () {
    test('sale / sale_return / delivery → 收款；purchase 系 → 付款', () {
      expect(SettlementService.isInbound(DocType.sale), isTrue);
      expect(SettlementService.isInbound(DocType.saleReturn), isTrue);
      expect(SettlementService.isInbound(DocType.delivery), isTrue);
      expect(SettlementService.isInbound(DocType.purchase), isFalse);
      expect(SettlementService.isInbound(DocType.purchaseReturn), isFalse);
    });

    test('盘点 / 收付款单自身 / 调拨 → null（不能核销）', () {
      expect(SettlementService.isInbound(DocType.stocktake), isNull);
      expect(SettlementService.isInbound(DocType.receipt), isNull);
      expect(SettlementService.isInbound(DocType.payment), isNull);
      expect(SettlementService.isInbound(DocType.transfer), isNull);
    });
  });

  // ============================================================ 文案

  group('内联提示与结论句（纯函数）', () {
    test('amountError：空 / 正常 / **超收** → 都不是错误（超收不再是拦的理由）', () {
      // §AX·一：超收走「告知」路径，不再是硬错误 —— 这条是**行为变更**的锚点
      expect(
        SettlementService.amountError(rawAmount: '   ', unsettledCents: 5000),
        isNull,
      );
      expect(
        SettlementService.amountError(rawAmount: '50', unsettledCents: 5000),
        isNull,
      );
      expect(
        SettlementService.amountError(rawAmount: '60', unsettledCents: 5000),
        isNull,
        reason: '超收（60 > 50）**不再报错** —— 多出的是找零',
      );
    });

    test('amountError：非数字 / ≤ 0 → 仍是硬错误', () {
      expect(
        SettlementService.amountError(rawAmount: 'abc', unsettledCents: 5000),
        contains('只能填数字'),
      );
      expect(
        SettlementService.amountError(rawAmount: '0', unsettledCents: 5000),
        contains('大于 0'),
      );
    });

    test('changeNotice：超收 → 「实收 / 入账 / 找零」三件事；未超收 → null', () {
      expect(
        SettlementService.changeNotice(
          rawAmount: '60',
          unsettledCents: 5000,
          inbound: true,
        ),
        '实收 ¥60.00，其中 ¥50.00 入账、找零 ¥10.00',
      );
      // 付款方向只有第一个字不同
      expect(
        SettlementService.changeNotice(
          rawAmount: '60',
          unsettledCents: 5000,
          inbound: false,
        ),
        startsWith('实付 '),
      );
      // 未超收 / 刚好 / 空 都**不打扰**
      for (final String raw in <String>['50', '30', '', 'abc']) {
        expect(
          SettlementService.changeNotice(
            rawAmount: raw,
            unsettledCents: 5000,
            inbound: true,
          ),
          isNull,
          reason: '「$raw」不该有找零告知',
        );
      }
    });

    test('actionLabel：超收 → 「记 ¥93 并找零 ¥7」；否则 null（用默认文字）', () {
      expect(
        SettlementService.actionLabel(rawAmount: '60', unsettledCents: 5000),
        '记 ¥50.00 并找零 ¥10.00',
      );
      expect(
        SettlementService.actionLabel(rawAmount: '50', unsettledCents: 5000),
        isNull,
      );
    });

    test('resultLine：够 → 就结清；不够 → 还欠 ¥Y', () {
      expect(
        SettlementService.resultLine(
          amountCents: 5000,
          unsettledCents: 5000,
          inbound: true,
        ),
        contains('就结清了'),
      );
      expect(
        SettlementService.resultLine(
          amountCents: 2000,
          unsettledCents: 5000,
          inbound: true,
        ),
        contains('还欠 ¥30.00'),
      );
      expect(
        SettlementService.resultLine(
          amountCents: 2000,
          unsettledCents: 5000,
          inbound: false,
        ),
        startsWith('付'),
      );
    });
  });

  // ============================================================ 核销

  group('SettlementService.settle', () {
    test('全额收款：生成 receipt 单 + 结清 + 未收归零', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();
      final Document sale = saleOnCredit(p, party, 5000);

      expect(service.unsettledCentsOf(sale.id), 5000);

      final SettlementSaved saved = service.settle(
        targetDocId: sale.id,
        accountId: acc,
        amountCents: 5000,
        now: now(),
      );

      expect(saved.inbound, isTrue);
      expect(saved.docNo.startsWith('SK'), isTrue, reason: '收款单号前缀');
      expect(saved.targetUnsettledAfterCents, 0);
      expect(service.unsettledCentsOf(sale.id), 0);

      final Document after = documents.findById(sale.id)!;
      expect(after.status, DocStatus.settled);
      expect(after.paidAmount, 5000);
    });

    test('部分收款 → 再收剩余 → 结清（一单多次收款）', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();
      final Document sale = saleOnCredit(p, party, 5000);

      final SettlementSaved first = service.settle(
        targetDocId: sale.id,
        accountId: acc,
        amountCents: 2000,
        now: now(),
      );
      expect(first.targetUnsettledAfterCents, 3000);
      expect(documents.findById(sale.id)!.status, DocStatus.confirmed);

      final SettlementSaved second = service.settle(
        targetDocId: sale.id,
        accountId: acc,
        amountCents: 3000,
        now: now(),
      );
      expect(second.targetUnsettledAfterCents, 0);
      expect(documents.findById(sale.id)!.status, DocStatus.settled);

      // 两个方向都能看到这两笔
      expect(service.settledBy(sale.id), hasLength(2));
    });

    test('采购单核销走付款（payment），前缀 FK', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();
      final Document purchase = purchaseOnCredit(p, party, 3000);

      final SettlementSaved saved = service.settle(
        targetDocId: purchase.id,
        accountId: acc,
        amountCents: 3000,
        now: now(),
      );
      expect(saved.inbound, isFalse);
      expect(saved.docNo.startsWith('FK'), isTrue);
      expect(documents.findById(purchase.id)!.status, DocStatus.settled);
    });

    test('拒绝：找不到单 / 金额 ≤ 0', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();
      final Document sale = saleOnCredit(p, party, 5000);

      expect(
        () => service.settle(
          targetDocId: '没有这张单',
          accountId: acc,
          amountCents: 100,
          now: now(),
        ),
        throwsA(isA<SettlementInvalid>()),
      );
      expect(
        () => service.settle(
          targetDocId: sale.id,
          accountId: acc,
          amountCents: 0,
          now: now(),
        ),
        throwsA(isA<SettlementInvalid>()),
      );
      expect(service.unsettledCentsOf(sale.id), 5000, reason: '拒绝时不落库');
    });

    // ---------------------------------------------- §AX·一：超收**不再拒绝**
    test('超收：**不再抛**，改为封顶到未收额 + 返回找零', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();
      final Document sale = saleOnCredit(p, party, 5000);

      final SettlementSaved over = service.settle(
        targetDocId: sale.id,
        accountId: acc,
        amountCents: 9999,
        now: now(),
      );
      expect(
        over.amountCents,
        5000,
        reason: '入账**封顶**到未收额（不是 9999）—— 旧行为是抛「超过未收金额…请改小」',
      );
      expect(over.changeCents, 4999, reason: '多出的是找零，不落库');
      expect(over.targetUnsettledAfterCents, 0);
      expect(service.unsettledCentsOf(sale.id), 0, reason: '封顶后正好结清');
      // 现金箱只进 5000（找零不是收入）
      final int cashIn = db.raw
          .select('SELECT COALESCE(SUM(amount), 0) AS s FROM money_ledger '
              'WHERE amount > 0')
          .first['s']! as int;
      expect(cashIn, 5000, reason: '⚡ 关键：找零 4999 没进账');
    });

    test('已结清的单：再核销仍拦（那是「没得收」，不是超收）', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();
      final Document sale = saleOnCredit(p, party, 5000);
      service.settle(
        targetDocId: sale.id,
        accountId: acc,
        amountCents: 5000,
        now: now(),
      );

      expect(
        () => service.settle(
          targetDocId: sale.id,
          accountId: acc,
          amountCents: 100,
          now: now(),
        ),
        throwsA(
          isA<SettlementInvalid>().having(
            (SettlementInvalid e) => e.message,
            'message',
            contains('已经结清'),
          ),
        ),
      );
    });

    test('核销后：这笔钱能在两个方向查到，且金额一致', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();
      final Document sale = saleOnCredit(p, party, 8000);

      final SettlementSaved saved = service.settle(
        targetDocId: sale.id,
        accountId: acc,
        amountCents: 3000,
        now: now(),
      );

      final List<SettlementView> fromReceipt = service.allocationsOf(
        saved.docId,
      );
      final List<SettlementView> fromTarget = service.settledBy(sale.id);
      expect(fromReceipt.single.docNo, documents.findById(sale.id)!.docNo);
      expect(fromTarget.single.docNo, saved.docNo);
      expect(fromReceipt.single.amount, 3000);
      expect(fromTarget.single.amount, 3000);
    });

    test('活跃账户列表可直接喂给下拉（启用中的才有）', () {
      final String acc = createAccount();
      final List<Account> accounts = service.activeAccounts();
      expect(accounts.map((Account a) => a.id), contains(acc));
    });
    // ============================================================ §审查 BUG-04
    //
    // 退货冲减必须反映到「真实未收」：赊销 60 → 收 40 → 退 12 ⇒ 真实未收 8。
    // （v0.1.0 发布包实测：退 12 后单据仍显示未收 20、收清 8 后仍显示未收 12，
    //   导致用户多收 12 —— 这是本次审查的 P1。）
    test('BUG-04 回归：赊 60 → 收 40 → 退 12 ⇒ 真实未收 8；退清后可结清', () {
      final String p = createProduct();
      final String acc = createAccount();
      final String party = createParty();
      final Document sale = saleOnCredit(p, party, 6000);
      final ReturnService returns = ReturnService(
        engine: engine,
        queries: QueryDao(db),
      );

      // 赊销 60 ⇒ 未收 60
      expect(service.unsettledCentsOf(sale.id), 6000);

      // 先退 12（挂账冲减）
      returns.create(
        ReturnDraft(
          refDocId: sale.id,
          originalDocType: DocType.sale,
          partyId: party,
          partyName: '老王批发',
          lines: <ReturnLineDraft>[
            ReturnLineDraft(
              productId: p,
              productName: '商品',
              quantity: '1',
              amount: '12.00',
              baseUnit: '件',
              originalQuantity: 1,
              originalAmountCents: 6000,
              packageSize: null,
            ),
          ],
        ),
      );

      // 退货冲减必须立刻反映：未收 60 − 12 = 48
      expect(service.unsettledCentsOf(sale.id), 4800, reason: '退货冲减未扣 = BUG-04');

      // 收 40 ⇒ 未收 8（不是 20！）
      service.settle(
        targetDocId: sale.id,
        accountId: acc,
        amountCents: 4000,
        now: now(),
      );
      expect(service.unsettledCentsOf(sale.id), 800, reason: '真实未收 = 60 − 40 − 12');

      // 收清真实余款 8 ⇒ 0；展示态即可显示「已结清」
      service.settle(
        targetDocId: sale.id,
        accountId: acc,
        amountCents: 800,
        now: now(),
      );
      expect(service.unsettledCentsOf(sale.id), 0);
      final Document after = documents.findById(sale.id)!;
      expect(
        SettlementService.displayStatus(after, 0),
        DocStatus.settled,
        reason: '已确认 + 真实未收 0 ⇒ 展示为已结清（BUG-04 的状态联动）',
      );
    });

    test('BUG-04 回归：退货额只算退货单，别的单不计入；作废态不被展示态改写', () {
      final String p = createProduct();
      final String party = createParty();
      final Document sale = saleOnCredit(p, party, 5000);
      // 另一张无关单据不该被算进来
      saleOnCredit(p, party, 7000);

      expect(documents.returnedAgainst(sale.id), 0);
      // 批量版：没退货的单据不在 map 里
      expect(
        documents.returnedAgainstMany(<String>[sale.id]).containsKey(sale.id),
        isFalse,
      );
      // cancelled / inTransit 的语义不被展示态改写
      final Document cancelled = Document(
        id: newId(),
        docNo: 'SH-X',
        docType: DocType.delivery,
        status: DocStatus.cancelled,
        totalAmount: 100,
        occurredAt: now(),
        createdAt: now(),
        updatedAt: now(),
      );
      expect(
        SettlementService.displayStatus(cancelled, 0),
        DocStatus.cancelled,
      );
    });
  });
}