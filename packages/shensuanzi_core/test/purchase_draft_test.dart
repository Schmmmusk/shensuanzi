// 采购开单草稿与提交服务（§X / RULE-001），对应 `docs/testing.md` §N。
//
// 覆盖：草稿校验（明细 / 立即付款 / 散采结清 / 日期）/ 取值 /
// 服务提交（散采全款、赊购、部分付款、校验拦截）/ 最小供应商建档。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；Windows 需要可用的 SQLite 原生库。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);
  setUp(resetClock);

  // ============================================================ 草稿校验（纯函数）
  group('PurchaseDraft 校验', () {
    /// 一份能通过校验的草稿（散采 + 全款）
    PurchaseDraft goodDraft({
      String? partyId,
      String partyName = '',
      String date = '2026-09-27',
      List<PurchaseLineDraft>? lines,
      List<PurchasePaymentDraft>? payments,
    }) => PurchaseDraft(
      partyId: partyId,
      partyName: partyName,
      date: date,
      lines:
          lines ??
          const <PurchaseLineDraft>[
            PurchaseLineDraft(
              productId: 'p1',
              productName: '红富士苹果',
              quantity: '10',
              unitPrice: '3.50',
            ),
          ],
      payments: payments ?? const <PurchasePaymentDraft>[],
    );

    test('散采 + 全款 → 通过（往来净额为 0）', () {
      final PurchaseDraft draft = goodDraft(
        payments: const <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: 'a1', amount: '35'),
        ],
      );
      expect(draft.validate(), isEmpty);
      expect(draft.linesOk, isTrue);
      expect(draft.paymentsOk, isTrue);
      expect(draft.isValid, isTrue);
    });

    test('没有明细 → lines 报「至少要有一行」', () {
      final PurchaseDraft draft = goodDraft(lines: const <PurchaseLineDraft>[]);
      expect(
        draft.validate()[PurchaseField.lines],
        contains('至少要有一行商品'),
      );
    });

    test('空行报行级错误（加了一行就得填或删）', () {
      const PurchaseLineDraft blank = PurchaseLineDraft();
      final Map<PurchaseLineField, String> errors = blank.validate();
      expect(errors.keys, containsAll(<PurchaseLineField>[
        PurchaseLineField.product,
        PurchaseLineField.quantity,
        PurchaseLineField.unitPrice,
      ]));
      expect(blank.isEmpty, isTrue, reason: '服务层据此做防御性跳过');
    });

    test('行级：商品 / 数量 / 单价 分别报，文案说「怎么办」', () {
      const PurchaseLineDraft line = PurchaseLineDraft(
        quantity: '0',
        unitPrice: '-1',
      );
      final Map<PurchaseLineField, String> errors = line.validate();

      expect(errors[PurchaseLineField.product], contains('请选一个商品'));
      expect(errors[PurchaseLineField.quantity], contains('正整数'));
      expect(errors[PurchaseLineField.unitPrice], contains('不能是负数'));
    });

    test('数量拒绝小数与非数字；单价拒绝三位小数', () {
      const PurchaseLineDraft a = PurchaseLineDraft(
        productId: 'p1',
        quantity: '1.5',
        unitPrice: '3.5',
      );
      expect(
        a.validate()[PurchaseLineField.quantity],
        contains('正整数'),
        reason: 'document_lines.quantity 是 INTEGER（已知限制，§X 遗漏 7）',
      );

      const PurchaseLineDraft b = PurchaseLineDraft(
        productId: 'p1',
        quantity: '2',
        unitPrice: '3.505',
      );
      expect(b.validate()[PurchaseLineField.unitPrice], contains('两位小数'));
    });

    test('付款行：金额留空 = 跳过（默认全赊）；金额 0 拦；无账户拦', () {
      const PurchasePaymentDraft blank = PurchasePaymentDraft(accountId: 'a1');
      expect(blank.validate(), isEmpty, reason: '默认「全赊」就是这么表达的');
      expect(blank.amountCents, isNull);

      const PurchasePaymentDraft zero = PurchasePaymentDraft(
        accountId: 'a1',
        amount: '0',
      );
      expect(zero.validate()[PurchasePaymentField.amount], contains('大于 0'));

      const PurchasePaymentDraft noAccount = PurchasePaymentDraft(amount: '10');
      expect(
        noAccount.validate()[PurchasePaymentField.account],
        contains('请选一个资金账户'),
      );
    });

    test('散采且有欠款 → party 报「散采要当场结清」', () {
      final PurchaseDraft draft = goodDraft(); // 无付款 = 全赊
      expect(draft.validate()[PurchaseField.party], contains('散采要当场结清'));
    });

    test('有供应商 + 欠款 → 不报（赊购合法）', () {
      final PurchaseDraft draft = goodDraft(
        partyId: 'party-1',
        partyName: '王老板',
      );
      expect(draft.validate(), isEmpty);
      expect(draft.dueCents, 3500);
    });

    test('散采校验在行本身不合法时**不报**（一次一个重点）', () {
      final PurchaseDraft draft = goodDraft(
        lines: const <PurchaseLineDraft>[
          PurchaseLineDraft(productId: 'p1', quantity: 'x', unitPrice: '3.50'),
        ],
      );
      expect(draft.validate().containsKey(PurchaseField.party), isFalse);
      expect(draft.linesOk, isFalse);
    });

    test('日期：空 / 格式不对 → date 报；正常格式且散采全款 → 通过', () {
      expect(
        goodDraft(date: '').validate()[PurchaseField.date],
        contains('请填日期'),
      );
      expect(
        goodDraft(date: '2026/9/27').validate()[PurchaseField.date],
        contains('日期格式不对'),
      );
      // 散采 + 全款（合计 3500，付款 3500）→ 整单无错
      final PurchaseDraft draft = goodDraft(
        date: '2026-09-27',
        payments: const <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: 'a1', amount: '35'),
        ],
      );
      expect(draft.validate(), isEmpty);
    });

    test('取值：合计 / 已付 / 欠款 / occurredAt', () {
      final PurchaseDraft draft = goodDraft(
        partyId: 'party-1',
        lines: const <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: 'p1',
            quantity: '10',
            unitPrice: '3.50',
          ),
          PurchaseLineDraft(
            productId: 'p2',
            quantity: '2',
            unitPrice: '100',
          ),
        ],
        payments: const <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: 'a1', amount: '200'),
        ],
      );

      // 10 × 3.50 元 = 3500 分；2 × 100 元 = 20000 分；付款 200 元 = 20000 分
      expect(draft.totalCents, 23500);
      expect(draft.paidCents, 20000);
      expect(draft.dueCents, 3500);
      expect(
        draft.occurredAt,
        DateTime.parse('2026-09-27').millisecondsSinceEpoch,
      );
    });

    test('fromProduct：单价预填的是商品的**进价**（数量留待填写）', () {
      const Product product = Product(
        id: 'p1',
        code: 'P0001',
        name: '红富士苹果',
        costPrice: 350,
        createdAt: 0,
        updatedAt: 0,
      );
      final PurchaseLineDraft line = PurchaseLineDraft.fromProduct(product);

      expect(line.productId, 'p1');
      expect(line.unitPrice, '3.50', reason: '进价 350 分 = 3.50 元');
      expect(line.quantity, '', reason: '数量待用户填');
      // 数量还没填 ⇒ 只报数量这一项（单价已预填、商品已选定）
      expect(line.validate().keys, <PurchaseLineField>[
        PurchaseLineField.quantity,
      ]);
    });

    test('付款合计超过本单合计 → **不再报错**（§AY·四：多付是找回）', () {
      final PurchaseDraft draft = goodDraft(
        payments: const <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: 'a1', amount: '999'),
        ],
      );
      expect(
        draft.validate()[PurchaseField.payments],
        isNull,
        reason: '旧行为是报「超过了本单合计」—— §AY·四 已废止（与销售同构）',
      );
      expect(draft.dueCents < 0, isTrue, reason: '多付 999 元 > 合计 35 元');
      expect(draft.recordedPaidCents, draft.totalCents, reason: '落库封顶到应付');
      expect(draft.changeCents, 99900 - draft.totalCents);
    });
  });

  // ======================================== §AY·四：多付（找回）——与销售同构
  group('§AY·四 多付 / 找回', () {
    /// 应付 35.00（10 × 3.50）
    PurchaseDraft draftWith(List<String> paidTexts, {String? partyId}) =>
        PurchaseDraft(
          partyId: partyId,
          date: '2026-09-27',
          lines: const <PurchaseLineDraft>[
            PurchaseLineDraft(
              productId: 'p1',
              productName: '红富士苹果',
              quantity: '10',
              unitPrice: '3.50',
            ),
          ],
          payments: <PurchasePaymentDraft>[
            for (final String text in paidTexts)
              PurchasePaymentDraft(
                accountId: 'a1',
                accountName: '现金',
                amount: text,
              ),
          ],
        );

    test('多付 → 不再报错；落库钳到应付、找回 = 差额', () {
      final PurchaseDraft d = draftWith(<String>['50']);
      expect(d.totalCents, 3500);
      expect(d.validate(), isEmpty);
      expect(d.recordedPaymentCents, <int>[3500]);
      expect(d.recordedPaidCents, 3500);
      expect(d.changeCents, 1500);
      expect(d.recordedDueCents, 0);
    });

    test('⚠️ 反向：未多付 / 刚好 ⇒ 原样（不是把一切都钳成 0）', () {
      expect(draftWith(<String>['20']).recordedPaymentCents, <int>[2000]);
      expect(draftWith(<String>['20']).changeCents, 0);
      expect(draftWith(<String>['35']).recordedPaymentCents, <int>[3500]);
      expect(draftWith(<String>['35']).changeCents, 0);
    });

    test('overpayNotice 用「实**付**」（销售是「实收」）', () {
      expect(
        draftWith(<String>['50']).overpayNotice,
        '实付 ¥50.00，其中 ¥35.00 入账、找零 ¥15.00',
      );
      expect(draftWith(<String>['35']).overpayNotice, isNull);
    });

    test('saveActionLabel：多付 ⇒ 说清记多少；否则「保存」', () {
      expect(draftWith(<String>['50']).saveActionLabel(), '记 ¥35.00 并找零 ¥15.00');
      expect(draftWith(<String>['35']).saveActionLabel(), '保存');
    });

    test('散采 + 多付 ⇒ **允许**（按落库金额结清）', () {
      expect(draftWith(<String>['50']).validate(), isEmpty);
      expect(
        draftWith(<String>['20']).validate()[PurchaseField.party],
        contains('散采要当场结清'),
      );
    });
  });

  // ============================================================ 提交服务（集成）
  group('PurchaseService.create', () {
    late Db db;
    late PurchaseService service;
    late ProductDao products;
    late AccountDao accounts;

    setUp(() {
      db = newMemoryDb();
      service = PurchaseService(
        engine: RuleEngine(db),
        queries: QueryDao(db),
      );
      products = ProductDao(db);
      accounts = AccountDao(db);
    });

    tearDown(() => db.close());

    String createProduct({String code = 'P001', int costPrice = 350}) {
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

    String createAccount({String name = '现金'}) {
      final int t = now();
      final Account account = Account(
        id: newId(),
        name: name,
        type: AccountType.cash,
        createdAt: t,
        updatedAt: t,
      );
      accounts.insert(account);
      return account.id;
    }

    String createSupplier({String name = '王老板'}) {
      final int t = now();
      final Party party = Party(
        id: newId(),
        name: name,
        roles: const <PartyRole>[PartyRole.supplier],
        createdAt: t,
        updatedAt: t,
      );
      PartyDao(db).insert(party);
      return party.id;
    }

    PurchaseDraft draftFor({
      String? partyId,
      required String productId,
      required String accountId,
      String quantity = '10',
      String unitPrice = '3.50',
      String paymentAmount = '',
    }) => PurchaseDraft(
      partyId: partyId,
      partyName: partyId == null ? '' : '王老板',
      date: '2026-09-27',
      lines: <PurchaseLineDraft>[
        PurchaseLineDraft(
          productId: productId,
          productName: '商品',
          quantity: quantity,
          unitPrice: unitPrice,
        ),
      ],
      payments: <PurchasePaymentDraft>[
        PurchasePaymentDraft(accountId: accountId, amount: paymentAmount),
      ],
    );

    test('散采全款 → applied，正式单号（非待同步），库存与资金同步', () {
      final String productId = createProduct();
      final String accountId = createAccount();
      final PurchaseDraft draft = draftFor(
        productId: productId,
        accountId: accountId,
        paymentAmount: '35',
      );

      final PurchaseSaved saved = service.create(draft, now: now());

      expect(
        Document.isPendingDocNo(saved.docNo),
        isFalse,
        reason: '主机路径必须拿到正式单号',
      );
      expect(saved.totalCents, 3500);
      expect(saved.paidCents, 3500);
      expect(saved.dueCents, 0);
      expect(saved.partyDueCents, 0, reason: '散采不记往来');

      // 库存 +10（货真进来）
      expect(StockLedgerDao(db).stockOf(productId), 10);
      // 资金 -3500（立即付款自动生成 payment 单 → MoneyLedger）
      expect(
        QueryDao(db).accountBalances()[accountId],
        -3500,
        reason: '账户初始 0，付款 35 元后为 -3500 分',
      );
      // 单据真的落库了（主单 + 1 行明细 + 1 张自动 payment 单 = 2 行 documents）
      final int docCount =
          db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n']! as int;
      expect(docCount, 2, reason: '采购主单 + 自动生成的付款单');
    });

    test('赊购（有供应商、无付款）→ 欠款记到名下', () {
      final String productId = createProduct();
      final String partyId = createSupplier();
      final PurchaseDraft draft = draftFor(
        partyId: partyId,
        productId: productId,
        accountId: createAccount(), // 金额留空 = 无付款
      );

      final PurchaseSaved saved = service.create(draft, now: now());

      expect(saved.totalCents, 3500);
      expect(saved.paidCents, 0);
      expect(saved.dueCents, 3500);
      expect(saved.partyDueCents, 3500, reason: '我欠供应商 3500');
    });

    test('部分付款 → 欠款 = 差额；供应商累计欠款同步', () {
      final String productId = createProduct();
      final String partyId = createSupplier();
      final String accountId = createAccount();
      // 合计 3500 分（10 × 3.50），立即付 1000 分（10 元）→ 欠 2500 分
      final PurchaseDraft draft = draftFor(
        partyId: partyId,
        productId: productId,
        accountId: accountId,
        paymentAmount: '10',
      );

      final PurchaseSaved saved = service.create(draft, now: now());

      expect(saved.paidCents, 1000);
      expect(saved.dueCents, 2500);
      expect(saved.partyDueCents, 2500);
    });

    test('校验不过 → 抛 PurchaseDraftInvalid（三组原因齐全），库里不留单', () {
      final String productId = createProduct();
      final String accountId = createAccount();
      final PurchaseDraft draft = draftFor(
        productId: productId,
        accountId: accountId,
        quantity: '0', // 行级错误
      );

      Object? thrown;
      try {
        service.create(draft, now: now());
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<PurchaseDraftInvalid>());
      final PurchaseDraftInvalid invalid = thrown! as PurchaseDraftInvalid;
      expect(
        invalid.lineErrors.single[PurchaseLineField.quantity],
        contains('正整数'),
      );
      expect(invalid.summary, contains('正整数'));
      final int docCount =
          db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n']! as int;
      expect(docCount, 0, reason: '事务回滚，不留半条单');
    });

    test('付款金额留空的行被跳过 → 等价于全赊', () {
      final String productId = createProduct();
      final String partyId = createSupplier();
      final String accountId = createAccount();
      final PurchaseDraft draft = draftFor(
        partyId: partyId,
        productId: productId,
        accountId: accountId,
        paymentAmount: '', // 空 = 没有这笔付款
      );

      final PurchaseSaved saved = service.create(draft, now: now());

      expect(saved.paidCents, 0);
      expect(saved.dueCents, 3500);
      expect(saved.partyDueCents, 3500);
    });

    test('createSupplier：最小建档（名称 + 电话可选），空名抛', () {
      final Party party = service.createSupplier('王老板', phone: ' 13800000000 ');
      expect(party.name, '王老板');
      expect(party.phone, '13800000000', reason: '电话要 trim');
      expect(party.roles.map((PartyRole r) => r.wire), <String>['supplier']);

      expect(
        () => service.createSupplier('   '),
        throwsStateError,
        reason: '名称必填',
      );
    });
  });

  group('v3 包装换算与让价（§BD，与销售同构）', () {
    PurchaseLineDraft boxed({
      String qty = '3',
      String price = '250.00',
      String entryUnit = '箱',
      String? packageSize = '12',
      String discount = '',
    }) => PurchaseLineDraft(
      productId: 'p1',
      productName: '牛奶',
      quantity: qty,
      unitPrice: price,
      entryUnit: entryUnit,
      discountAmount: discount,
      baseUnit: '个',
      packageUnit: '箱', // 恒定 —— "没设 size" 是档案缺列，不是包装不启用
      packageSize: packageSize == null ? null : int.parse(packageSize),
    );

    test('按箱录入 ⇒ quantity 36、amount 按录入进价', () {
      expect(boxed().validate(), isEmpty);
      expect(boxed().baseQuantityValue, 36);
      expect(boxed().amountCents, 75000);
    });

    test('让价 ⇒ amount = entry_qty × entry_price − discount', () {
      final PurchaseLineDraft line = boxed(
        qty: '10',
        price: '5.00',
        entryUnit: '',
        discount: '0.50',
      );
      expect(line.validate(), isEmpty);
      expect(line.amountCents, 4950);
    });

    test('三种换算失败文案分开', () {
      expect(
        boxed(packageSize: null).validate()[PurchaseLineField.entryUnit],
        '这个商品没设包装换算',
      );
      expect(
        boxed(packageSize: '0').validate()[PurchaseLineField.entryUnit],
        '包装换算无效',
      );
      expect(
        boxed(entryUnit: '桶').validate()[PurchaseLineField.entryUnit],
        '单位不合法',
      );
    });
  });
}