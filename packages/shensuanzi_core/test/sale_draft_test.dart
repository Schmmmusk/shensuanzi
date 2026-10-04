// 店内销售开单草稿与提交服务（§Z 四 / RULE-002），对应 `docs/testing.md` §O。
//
// 与 `purchase_draft_test.dart` 逐条镜像（两文件刻意保持同构，将来抽
// DocumentDraft 基类时机械搬运）；销售特有的点：售价预填 / 散客结清 /
// 负库存放行 / 客户累计欠款（正 = 客户欠我）。
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
  group('SaleDraft 校验', () {
    /// 一份能通过校验的草稿（散客 + 全款）
    SaleDraft goodDraft({
      String? partyId,
      String partyName = '',
      String date = '2026-09-27',
      List<SaleLineDraft>? lines,
      List<SalePaymentDraft>? payments,
    }) => SaleDraft(
      partyId: partyId,
      partyName: partyName,
      date: date,
      lines:
          lines ??
          const <SaleLineDraft>[
            SaleLineDraft(
              productId: 'p1',
              productName: '红富士苹果',
              quantity: '10',
              unitPrice: '5.00',
            ),
          ],
      payments: payments ?? const <SalePaymentDraft>[],
    );

    test('散客 + 全款 → 通过（往来净额为 0）', () {
      final SaleDraft draft = goodDraft(
        payments: const <SalePaymentDraft>[
          SalePaymentDraft(accountId: 'a1', amount: '50'),
        ],
      );
      expect(draft.validate(), isEmpty);
      expect(draft.isValid, isTrue);
    });

    test('没有明细 → lines 报「至少要有一行」；空行报行级错误', () {
      expect(
        goodDraft(lines: const <SaleLineDraft>[]).validate()[SaleField.lines],
        contains('至少要有一行商品'),
      );
      const SaleLineDraft blank = SaleLineDraft();
      expect(blank.validate().keys, containsAll(<SaleLineField>[
        SaleLineField.product,
        SaleLineField.quantity,
        SaleLineField.unitPrice,
      ]));
      expect(blank.isEmpty, isTrue, reason: '服务层据此做防御性跳过');
    });

    test('行级三错齐报；数量拒小数；单价拒三位小数与负数', () {
      const SaleLineDraft bad = SaleLineDraft(
        productId: 'p1',
        quantity: '1.5',
        unitPrice: '5.005',
      );
      final Map<SaleLineField, String> errors = bad.validate();
      expect(errors[SaleLineField.quantity], contains('正整数'));
      expect(errors[SaleLineField.unitPrice], contains('两位小数'));

      const SaleLineDraft negative = SaleLineDraft(
        productId: 'p1',
        quantity: '1',
        unitPrice: '-1',
      );
      expect(negative.validate()[SaleLineField.unitPrice], contains('不能是负数'));
    });

    test('收款行：金额留空 = 跳过（默认全赊）；金额 0 拦；无账户拦', () {
      const SalePaymentDraft blank = SalePaymentDraft(accountId: 'a1');
      expect(blank.validate(), isEmpty);

      const SalePaymentDraft zero = SalePaymentDraft(
        accountId: 'a1',
        amount: '0',
      );
      expect(zero.validate()[SalePaymentField.amount], contains('大于 0'));

      const SalePaymentDraft noAccount = SalePaymentDraft(amount: '10');
      expect(
        noAccount.validate()[SalePaymentField.account],
        contains('请选一个资金账户'),
      );
    });

    test('散客且有欠款 → party 报「散客要当场结清」', () {
      final SaleDraft draft = goodDraft(
        partyName: '顾客',
      );
      expect(
        draft.validate()[SaleField.party],
        contains('散客要当场结清'),
      );
    });

    test('有客户 + 欠款 → 不报（赊销合法）', () {
      expect(goodDraft(partyId: 'party-1', partyName: '李姐').validate(), isEmpty);
    });

    test('散客校验在行本身不合法时**不报**（一次一个重点）', () {
      final SaleDraft draft = goodDraft(
        lines: const <SaleLineDraft>[
          SaleLineDraft(productId: 'p1', quantity: 'x', unitPrice: '5.00'),
        ],
      );
      expect(draft.validate().containsKey(SaleField.party), isFalse);
      expect(draft.linesOk, isFalse);
    });

    test('日期：空 / 斜杠格式都报，标准格式过', () {
      expect(
        goodDraft(date: '').validate()[SaleField.date],
        contains('请填日期'),
      );
      expect(
        goodDraft(date: '2026/9/27').validate()[SaleField.date],
        contains('日期格式不对'),
      );
      expect(
        goodDraft(
          date: '2026-09-27',
          payments: const <SalePaymentDraft>[
            SalePaymentDraft(accountId: 'a1', amount: '50'),
          ],
        ).validate(),
        isEmpty,
      );
    });

    test('取值：合计 / 已收 / 欠款 / occurredAt', () {
      final SaleDraft draft = goodDraft(
        partyId: 'party-1',
        lines: const <SaleLineDraft>[
          SaleLineDraft(
            productId: 'p1',
            quantity: '10',
            unitPrice: '5.00',
          ),
          SaleLineDraft(
            productId: 'p2',
            quantity: '2',
            unitPrice: '100',
          ),
        ],
        payments: const <SalePaymentDraft>[
          SalePaymentDraft(accountId: 'a1', amount: '200'),
        ],
      );

      // 10 × 5.00 元 = 5000 分；2 × 100 元 = 20000 分；收款 200 元 = 20000 分
      expect(draft.totalCents, 25000);
      expect(draft.paidCents, 20000);
      expect(draft.dueCents, 5000);
      expect(
        draft.occurredAt,
        DateTime.parse('2026-09-27').millisecondsSinceEpoch,
      );
    });

    test('fromProduct：单价预填的是商品的**售价**（数量留待填写）', () {
      const Product product = Product(
        id: 'p1',
        code: 'P0001',
        name: '红富士苹果',
        costPrice: 350,
        sellPrice: 500,
        createdAt: 0,
        updatedAt: 0,
      );
      final SaleLineDraft line = SaleLineDraft.fromProduct(product);

      expect(line.productId, 'p1');
      expect(line.unitPrice, '5.00', reason: '售价 500 分 = 5.00 元（预填是默认值不是约束）');
      expect(line.quantity, '', reason: '数量待用户填');
      expect(line.validate().keys, <SaleLineField>[SaleLineField.quantity]);
    });

    test('收款合计超过本单合计 → **不再报错**，改由落库金额折算（§AY·二）', () {
      final SaleDraft draft = goodDraft(
        payments: const <SalePaymentDraft>[
          SalePaymentDraft(accountId: 'a1', amount: '999'),
        ],
      );
      expect(
        draft.validate()[SaleField.payments],
        isNull,
        reason: '旧行为是报「收款金额不能超过应收…」—— §AX·一 已废止（3甲：不拦）',
      );
      expect(draft.dueCents < 0, isTrue, reason: '草稿保留原文：多付 999 > 合计 50');
      expect(draft.recordedPaidCents, draft.totalCents, reason: '落库封顶到应收');
      expect(draft.changeCents, 99900 - draft.totalCents);
      // 告知三件套（给多少 / 记多少 / 找多少）由 core 的 `Overpay` 统一给 ——
      // 开单页与核销对话框**同源**，不各写一份
      expect(
        draft.overpayNotice,
        '实收 ¥999.00，其中 ¥50.00 入账、找零 ¥949.00',
      );
    });
  });

  // ============================================================ 提交服务（集成）
  group('SaleService.create', () {
    late Db db;
    late SaleService service;
    late PurchaseService purchases;
    late ProductDao products;
    late AccountDao accounts;

    setUp(() {
      db = newMemoryDb();
      service = SaleService(
        engine: RuleEngine(db),
        queries: QueryDao(db),
      );
      // 有采购才有正库存 —— 大部分销售用例先买后卖
      purchases = PurchaseService(
        engine: RuleEngine(db),
        queries: QueryDao(db),
      );
      products = ProductDao(db);
      accounts = AccountDao(db);
    });

    tearDown(() => db.close());

    String createProduct({String code = 'P001', int costPrice = 350, int sellPrice = 500}) {
      final int t = now();
      final Product product = Product(
        id: newId(),
        code: code,
        name: '商品-$code',
        costPrice: costPrice,
        sellPrice: sellPrice,
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

    String createCustomer({String name = '李姐'}) {
      final int t = now();
      final Party party = Party(
        id: newId(),
        name: name,
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      );
      PartyDao(db).insert(party);
      return party.id;
    }

    /// 先采购 10 件（3.50 进）建立正库存，再按 [unitPrice] 卖 [quantity] 件
    void stockUp(String productId, String accountId) {
      purchases.create(
        PurchaseDraft(
          date: '2026-09-27',
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
        now: now(),
      );
    }

    SaleDraft draftFor({
      String? partyId,
      required String productId,
      required String accountId,
      String quantity = '10',
      String unitPrice = '5.00',
      String paymentAmount = '',
    }) => SaleDraft(
      partyId: partyId,
      partyName: partyId == null ? '' : '李姐',
      date: '2026-09-27',
      lines: <SaleLineDraft>[
        SaleLineDraft(
          productId: productId,
          productName: '商品',
          quantity: quantity,
          unitPrice: unitPrice,
        ),
      ],
      payments: <SalePaymentDraft>[
        SalePaymentDraft(accountId: accountId, amount: paymentAmount),
      ],
    );

    test('散客全款 → applied，正式单号，库存 -10，资金 +5000', () {
      final String productId = createProduct();
      final String accountId = createAccount();
      stockUp(productId, accountId);

      final SaleDraft draft = draftFor(
        productId: productId,
        accountId: accountId,
        paymentAmount: '50', // 10 × 5.00 元
      );

      final SaleSaved saved = service.create(draft, now: now());

      expect(
        Document.isPendingDocNo(saved.docNo),
        isFalse,
        reason: '主机路径必须拿到正式单号',
      );
      expect(saved.totalCents, 5000);
      expect(saved.paidCents, 5000);
      expect(saved.dueCents, 0);
      expect(saved.partyDueCents, 0, reason: '散客不记往来');

      // 库存 10 - 10 = 0（货真出去了）
      expect(StockLedgerDao(db).stockOf(productId), 0);
      // 资金：采购付 3500 分，销售收 5000 分（receipt 单 → MoneyLedger）
      expect(QueryDao(db).accountBalances()[accountId], 1500);
      // 单据：采购主单 + 付款单 + 销售主单 + 收款单 = 4 行
      final int docCount =
          db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n']! as int;
      expect(docCount, 4, reason: '采购 + payment + 销售 + receipt');
    });

    test('负库存放行（RULE-002 允许；界面层才告警）', () {
      final String productId = createProduct();
      final String accountId = createAccount();
      // 没有采购，直接卖 10 件 → 库存 -10
      final SaleDraft draft = draftFor(
        productId: productId,
        accountId: accountId,
        paymentAmount: '50',
      );

      final SaleSaved saved = service.create(draft, now: now());

      expect(saved.totalCents, 5000);
      expect(StockLedgerDao(db).stockOf(productId), -10);
    });

    test('赊销（有客户、无收款）→ 客户欠款记到名下（正数 = 客户欠我）', () {
      final String productId = createProduct();
      final String partyId = createCustomer();
      final SaleDraft draft = draftFor(
        partyId: partyId,
        productId: productId,
        accountId: createAccount(), // 金额留空 = 无收款
      );

      final SaleSaved saved = service.create(draft, now: now());

      expect(saved.totalCents, 5000);
      expect(saved.paidCents, 0);
      expect(saved.dueCents, 5000);
      expect(saved.partyDueCents, 5000, reason: '客户欠我 5000 分');
    });

    test('部分收款 → 欠款 = 差额；客户累计欠款同步', () {
      final String productId = createProduct();
      final String partyId = createCustomer();
      final String accountId = createAccount();
      stockUp(productId, accountId);
      // 合计 5000 分，立收 2000 分（20 元）→ 欠 3000 分
      final SaleDraft draft = draftFor(
        partyId: partyId,
        productId: productId,
        accountId: accountId,
        paymentAmount: '20',
      );

      final SaleSaved saved = service.create(draft, now: now());

      expect(saved.paidCents, 2000);
      expect(saved.dueCents, 3000);
      expect(saved.partyDueCents, 3000);
    });

    test('校验不过 → 抛 SaleDraftInvalid（三组原因齐全），库里不留单', () {
      final String productId = createProduct();
      final String accountId = createAccount();
      final SaleDraft draft = draftFor(
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

      expect(thrown, isA<SaleDraftInvalid>());
      final SaleDraftInvalid invalid = thrown! as SaleDraftInvalid;
      expect(
        invalid.lineErrors.single[SaleLineField.quantity],
        contains('正整数'),
      );
      expect(invalid.summary, contains('正整数'));
      final int docCount =
          db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n']! as int;
      expect(docCount, 0, reason: '事务回滚，不留半条单');
    });

    test('收款金额留空的行被跳过 → 等价于全赊', () {
      final String productId = createProduct();
      final String partyId = createCustomer();
      final SaleDraft draft = draftFor(
        partyId: partyId,
        productId: productId,
        accountId: 'a-placeholder',
        paymentAmount: '',
      );

      final SaleSaved saved = service.create(draft, now: now());

      expect(saved.paidCents, 0);
      expect(saved.dueCents, 5000);
      expect(saved.partyDueCents, 5000);
    });

    test('stockSnapshot：采购后快照含商品；卖出后刷新可见', () {
      final String productId = createProduct();
      final String accountId = createAccount();
      expect(service.stockSnapshot().containsKey(productId), isFalse,
          reason: '还没流水，快照里没有（消费端用 ?? 0）');

      stockUp(productId, accountId);
      expect(service.stockSnapshot()[productId], 10);

      service.create(
        draftFor(
          partyId: createCustomer(),
          productId: productId,
          accountId: accountId,
          quantity: '3',
          paymentAmount: '',
        ),
        now: now(),
      );
      expect(service.stockSnapshot()[productId], 7);
    });

    test('createCustomer：最小建档，空名抛', () {
      final Party party = service.createCustomer('李姐', phone: ' 13900000000 ');
      expect(party.name, '李姐');
      expect(party.phone, '13900000000');
      expect(party.roles.map((PartyRole r) => r.wire), <String>['customer']);

      expect(() => service.createCustomer('   '), throwsStateError);
    });
  });

  // ============================================ §AX·一：超收（找零，方案 3甲）
  //
  // 裁定（2026-10-02）：**核心判断不变**（落库 = 应收，找零不持久化），
  // 但把「拦」改成「按应收折算 + 两处提前告知」。本组钉住这句话的每一半。

  group('§AX·一 超收 / 找零', () {
    /// 应收 93.00（3 × 31.00）
    SaleDraft draftWith(List<String> paidTexts, {String? partyId}) => SaleDraft(
      partyId: partyId,
      date: '2026-09-27',
      lines: const <SaleLineDraft>[
        SaleLineDraft(
          productId: 'p1',
          productName: '红富士苹果',
          quantity: '3',
          unitPrice: '31.00',
        ),
      ],
      payments: <SalePaymentDraft>[
        for (final String text in paidTexts)
          SalePaymentDraft(accountId: 'a1', accountName: '现金', amount: text),
      ],
    );

    test('应收 93.00 时，填 100 → **不再报错**（行为的锚点）', () {
      final SaleDraft d = draftWith(<String>['100']);
      expect(d.totalCents, 9300);
      expect(d.paidCents, 10000);
      expect(
        d.validate(),
        isEmpty,
        reason: '旧行为是报「收款金额不能超过应收…」—— §AX·一 已废止',
      );
    });

    test('落库金额钳到应收：填 100 ⇒ 记 93，找零 7', () {
      final SaleDraft d = draftWith(<String>['100']);
      expect(d.recordedPaymentCents, <int>[9300]);
      expect(d.recordedPaidCents, 9300);
      expect(d.changeCents, 700);
      expect(d.recordedDueCents, 0, reason: '记 93 = 应收 ⇒ 不欠');
    });

    test('逐行钳制（多行）：[50, 50] + 应收 93 ⇒ [50, 43]；只钳最后一行是不够的', () {
      final SaleDraft d = draftWith(<String>['50', '50']);
      expect(d.recordedPaymentCents, <int>[5000, 4300]);
      expect(d.recordedPaidCents, 9300);
      expect(d.changeCents, 700);
    });

    test('未超收 / 刚好 / 空 ⇒ 一律原样（**不是**把一切都钳成 0）', () {
      expect(draftWith(<String>['50']).recordedPaymentCents, <int>[5000]);
      expect(draftWith(<String>['50']).changeCents, 0);
      expect(draftWith(<String>['93']).recordedPaymentCents, <int>[9300]);
      expect(draftWith(<String>['93']).changeCents, 0);
      expect(draftWith(<String>['']).recordedPaymentCents, <int>[0]);
      // ⚠️ 反向灵敏度：钳制**不是**「超了就清零」—— 刚好时不丢钱
      expect(Overpay.clamp(<int>[9300], 9300), <int>[9300]);
      expect(Overpay.clamp(<int>[9400], 9300), <int>[9300]);
    });

    test('saveActionLabel：四档（未填 / 不够 / 有找零 / 已结清）', () {
      final SaleDraft d = draftWith(<String>['93']);
      expect(d.saveActionLabel(), '保存', reason: '未填「顾客给了」');
      expect(
        d.saveActionLabel(givenCents: 5000),
        '保存',
        reason: '给了 50 < 93：内联行已说「不够」，按钮不变',
      );
      expect(
        d.saveActionLabel(givenCents: 9300),
        '保存',
        reason: '刚好结清、无找零',
      );
      expect(
        d.saveActionLabel(givenCents: 10000),
        '记 ¥93.00 并找零 ¥7.00',
        reason: '**按钮文字是用户动作的最终确认**',
      );
      // 未填「顾客给了」但收款框自己填超了 —— 按钮也要说清
      expect(draftWith(<String>['100']).saveActionLabel(), '记 ¥93.00 并找零 ¥7.00');
    });

    test('overpayNotice：只有超收才出声，且说清三件事', () {
      expect(draftWith(<String>['100']).overpayNotice,
          '实收 ¥100.00，其中 ¥93.00 入账、找零 ¥7.00');
      expect(draftWith(<String>['93']).overpayNotice, isNull);
      expect(draftWith(<String>['50']).overpayNotice, isNull);
    });

    test('散客 + 超收 ⇒ **允许**（按落库金额结清，不是按填的数）', () {
      final SaleDraft d = draftWith(<String>['100']); // partyId = null = 散客
      expect(
        d.validate(),
        isEmpty,
        reason: '记录 93 = 应收 ⇒ 当场结清；那 7 元是找零，不是欠款',
      );
      // 对照：真的没付够时散客仍然被拦
      expect(
        draftWith(<String>['50']).validate()[SaleField.party],
        contains('散客要当场结清'),
      );
    });
  });

  group('v3 包装换算与让价（§BD）', () {
    // 与 fromProduct 同构的行：带换算上下文（baseUnit/packageUnit/packageSize）
    SaleLineDraft boxed({
      String qty = '3',
      String price = '250.00',
      String entryUnit = '箱',
      String? packageSize = '12',
      String discount = '',
    }) => SaleLineDraft(
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

    test('按箱录入 ⇒ quantity 换算 36、amount 按录入报价 3 × ¥250/箱', () {
      final SaleLineDraft line = boxed();
      expect(line.validate(), isEmpty);
      expect(line.baseQuantityValue, 36, reason: '3 箱 × 12 = 36 个');
      expect(line.amountCents, 75000, reason: '3 × ¥250.00（真相，按录入报价）');
      expect(line.entryUnitValue, '箱');
      expect(line.discountCents, 0);
    });

    test('没切单位（entryUnit 空）⇒ 原样，行为与 v2 一致', () {
      final SaleLineDraft line = boxed(qty: '10', price: '5.00', entryUnit: '');
      expect(line.validate(), isEmpty);
      expect(line.baseQuantityValue, 10);
      expect(line.amountCents, 5000);
      expect(line.entryUnitValue, isNull);
    });

    test('让价 ⇒ amount = entry_qty × entry_price − discount', () {
      final SaleLineDraft line = boxed(
        qty: '10',
        price: '5.00',
        entryUnit: '',
        discount: '0.50',
      );
      expect(line.validate(), isEmpty);
      expect(line.amountCents, 4950, reason: '5000 − 50（让价已含在 amount 里）');
    });

    test('让价越界 ⇒ 报「让价不能超过本行金额」且 amountCents null', () {
      final SaleLineDraft line = boxed(
        qty: '10',
        price: '5.00',
        entryUnit: '',
        discount: '60',
      );
      expect(
        line.validate()[SaleLineField.discount],
        contains('让价不能超过本行金额 ¥50.00'),
      );
      expect(line.amountCents, isNull);
    });

    test('三种换算失败 ⇒ 三句文案分开（§BD·九）', () {
      expect(
        boxed(packageSize: null).validate()[SaleLineField.entryUnit],
        '这个商品没设包装换算',
      );
      expect(
        boxed(packageSize: '0').validate()[SaleLineField.entryUnit],
        '包装换算无效',
      );
      expect(
        boxed(entryUnit: '桶').validate()[SaleLineField.entryUnit],
        '单位不合法',
      );
    });

    test('草稿 totalCents = Σ（amount，含让价）—— B5 的草稿侧', () {
      final SaleDraft draft = SaleDraft(
        partyName: '',
        date: '2026-09-27',
        lines: <SaleLineDraft>[
          boxed(),                                                    // 75000
          boxed(qty: '10', price: '5.00', entryUnit: '', discount: '0.50'), // 4950
        ],
      );
      expect(draft.totalCents, 79950);
    });
  });
}