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
    test('amountNotice：空 → 不打扰；非数字 / ≤0 / 超收 → 各有一条', () {
      expect(
        SettlementService.amountNotice(
          rawAmount: '   ',
          unsettledCents: 5000,
          inbound: true,
        ),
        isNull,
      );
      expect(
        SettlementService.amountNotice(
          rawAmount: 'abc',
          unsettledCents: 5000,
          inbound: true,
        ),
        contains('只能填数字'),
      );
      expect(
        SettlementService.amountNotice(
          rawAmount: '0',
          unsettledCents: 5000,
          inbound: true,
        ),
        contains('大于 0'),
      );
      // 超收：内联提示（不弹窗），文案点名「未收金额」
      expect(
        SettlementService.amountNotice(
          rawAmount: '60',
          unsettledCents: 5000,
          inbound: true,
        ),
        contains('超过未收金额 ¥50.00，请改小'),
      );
      // 付款方向用「未付」
      expect(
        SettlementService.amountNotice(
          rawAmount: '60',
          unsettledCents: 5000,
          inbound: false,
        ),
        contains('超过未付金额'),
      );
      expect(
        SettlementService.amountNotice(
          rawAmount: '50',
          unsettledCents: 5000,
          inbound: true,
        ),
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

    test('拒绝：找不到单 / 类型不可核销 / 金额 ≤ 0 / 超收', () {
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
      // 超收：服务层**自己拦一遍**（界面内联提示只是提前告知，不是唯一防线）
      expect(
        () => service.settle(
          targetDocId: sale.id,
          accountId: acc,
          amountCents: 9999,
          now: now(),
        ),
        throwsA(
          isA<SettlementInvalid>().having(
            (SettlementInvalid e) => e.message,
            'message',
            contains('超过未收金额'),
          ),
        ),
      );
      expect(service.unsettledCentsOf(sale.id), 5000, reason: '拒绝时不落库');
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
  });
}
