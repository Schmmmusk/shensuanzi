/// 店内销售开单的降级门禁（对应 `test/sale_draft_test.dart`）。
///
/// ⚠️ **改一边必须改另一边** —— `test/**` 是正式门禁，本脚本是
/// 「跑不了 `dart test` 时的降级门禁」（`docs/testing.md` §零）。
/// 与 `selfcheck_purchase.dart` 逐条镜像（销售差异：售价预填 / 散客 /
/// 负库存放行 / 客户欠款为正）。
///
/// ⚠️ **服务段每用例独立内存库** —— 同一客户连续开单会让「累计欠款」
/// 跨用例累计（§零 的跨段复用坑）。
///
/// 运行：`dart run tool/selfcheck_sale.dart`
library;

import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('  ✓ $name');
  } else {
    _fail++;
    _failures.add(name);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  →  $detail'}');
  }
}

void section(String title) => stdout.writeln('\n── $title ──');

void main() {
  useLocalSqlite();

  int clock = 1700000000000;
  int now() => clock++;

  // ============================================================ 草稿校验
  section('SaleDraft 校验');
  {
    SaleDraft goodDraft({
      String? partyId,
      String date = '2026-09-27',
      List<SaleLineDraft>? lines,
      List<SalePaymentDraft>? payments,
    }) => SaleDraft(
      partyId: partyId,
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

    check('散客 + 全款 → 通过（往来净额为 0）', () {
      final SaleDraft d = goodDraft(
        payments: const <SalePaymentDraft>[
          SalePaymentDraft(accountId: 'a1', amount: '50'),
        ],
      );
      return d.isValid;
    }());

    check('没有明细 → lines 报「至少要有一行」；空行报行级错误', () {
      const SaleLineDraft blank = SaleLineDraft();
      final Map<SaleLineField, String> e = blank.validate();
      return (goodDraft(lines: const <SaleLineDraft>[]).validate()[SaleField.lines] ?? '')
              .contains('至少要有一行商品') &&
          e.containsKey(SaleLineField.product) &&
          e.containsKey(SaleLineField.quantity) &&
          e.containsKey(SaleLineField.unitPrice) &&
          blank.isEmpty;
    }());

    check('行级：数量拒小数；单价拒三位小数与负数', () {
      const SaleLineDraft a = SaleLineDraft(
        productId: 'p1',
        quantity: '1.5',
        unitPrice: '5.005',
      );
      const SaleLineDraft b = SaleLineDraft(
        productId: 'p1',
        quantity: '1',
        unitPrice: '-1',
      );
      return (a.validate()[SaleLineField.quantity] ?? '').contains('正整数') &&
          (a.validate()[SaleLineField.unitPrice] ?? '').contains('两位小数') &&
          (b.validate()[SaleLineField.unitPrice] ?? '').contains('不能是负数');
    }());

    check('收款行：金额空 = 跳过；0 拦；缺账户拦', () {
      const SalePaymentDraft blank = SalePaymentDraft(accountId: 'a1');
      const SalePaymentDraft zero = SalePaymentDraft(
        accountId: 'a1',
        amount: '0',
      );
      const SalePaymentDraft noAccount = SalePaymentDraft(amount: '10');
      return blank.validate().isEmpty &&
          (zero.validate()[SalePaymentField.amount] ?? '').contains('大于 0') &&
          (noAccount.validate()[SalePaymentField.account] ?? '')
              .contains('请选一个资金账户');
    }());

    check('散客且有欠款 → party 报「散客要当场结清」', () {
      return (goodDraft().validate()[SaleField.party] ?? '')
          .contains('散客要当场结清');
    }());

    check('有客户 + 欠款 → 不报（赊销合法）', () {
      return goodDraft(partyId: 'party-1').validate().isEmpty;
    }());

    check('散客校验在行不合法时不报（一次一个重点）', () {
      final SaleDraft d = goodDraft(
        lines: const <SaleLineDraft>[
          SaleLineDraft(productId: 'p1', quantity: 'x', unitPrice: '5.00'),
        ],
      );
      return !d.validate().containsKey(SaleField.party) && !d.linesOk;
    }());

    check('日期：空 / 斜杠格式都报，标准格式过', () {
      return (goodDraft(date: '').validate()[SaleField.date] ?? '')
              .contains('请填日期') &&
          (goodDraft(date: '2026/9/27').validate()[SaleField.date] ?? '')
              .contains('日期格式不对') &&
          goodDraft(
            date: '2026-09-27',
            payments: const <SalePaymentDraft>[
              SalePaymentDraft(accountId: 'a1', amount: '50'),
            ],
          ).validate().isEmpty;
    }());

    check('取值：合计 25000 / 已收 20000 / 欠款 5000 / occurredAt 是当天', () {
      final SaleDraft d = goodDraft(
        partyId: 'party-1',
        lines: const <SaleLineDraft>[
          SaleLineDraft(productId: 'p1', quantity: '10', unitPrice: '5.00'),
          SaleLineDraft(productId: 'p2', quantity: '2', unitPrice: '100'),
        ],
        payments: const <SalePaymentDraft>[
          SalePaymentDraft(accountId: 'a1', amount: '200'),
        ],
      );
      return d.totalCents == 25000 &&
          d.paidCents == 20000 &&
          d.dueCents == 5000 &&
          d.occurredAt == DateTime.parse('2026-09-27').millisecondsSinceEpoch;
    }());

    check('fromProduct：单价预填**售价**（500 分 = 5.00 元），数量待填', () {
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
      return line.unitPrice == '5.00' &&
          line.quantity == '' &&
          line.validate().keys.single == SaleLineField.quantity;
    }());

    check('收款合计超合计 → **不再报错**（§AX·一：多付是找零）', () {
      final SaleDraft d = goodDraft(
        payments: const <SalePaymentDraft>[
          SalePaymentDraft(accountId: 'a1', amount: '999'),
        ],
      );
      return d.validate()[SaleField.payments] == null &&
          d.dueCents < 0 &&
          d.recordedPaidCents == d.totalCents &&
          d.changeCents == 99900 - d.totalCents &&
          (d.overpayNotice ?? '').contains('入账、找零');
    }());
  }

  // ============================================================ 提交服务
  // ⚠️ 每用例独立内存库 —— 累计欠款 / 库存 / documents 行数互不污染
  section('SaleService.create');
  {
    /// 一套全新的环境（独立 Db），返回 (db, service, purchases, productId,
    /// accountId, partyId)。每个 check 自取自还。
    (Db, SaleService, PurchaseService, String, String, String) newEnv() {
      final Db db = Db.openInMemory();
      final SaleService service = SaleService(
        engine: RuleEngine(db),
        queries: QueryDao(db),
      );
      final PurchaseService purchases = PurchaseService(
        engine: RuleEngine(db),
        queries: QueryDao(db),
      );
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
      ProductDao(db).insert(product);
      final Account account = Account(
        id: newId(),
        name: '现金',
        type: AccountType.cash,
        createdAt: t,
        updatedAt: t,
      );
      AccountDao(db).insert(account);
      final Party customer = Party(
        id: newId(),
        name: '李姐',
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      );
      PartyDao(db).insert(customer);
      return (db, service, purchases, product.id, account.id, customer.id);
    }

    /// 先采购 10 件（3.50 进）建立正库存
    void stockUp(PurchaseService purchases, String productId, String accountId) {
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

    SaleDraft draftFor(
      String productId,
      String accountId, {
      String? partyId,
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

    check('散客全款 → 正式单号 + 库存归零 + 资金 +1500（收 5000 - 付 3500）', () {
      final (Db db, SaleService service, PurchaseService purchases,
          String productId, String accountId, String _) = newEnv();
      stockUp(purchases, productId, accountId);

      final SaleSaved saved = service.create(
        draftFor(productId, accountId, paymentAmount: '50'),
        now: now(),
      );
      final int docCount =
          db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n']! as int;
      final bool ok = !Document.isPendingDocNo(saved.docNo) &&
          saved.totalCents == 5000 &&
          saved.paidCents == 5000 &&
          saved.dueCents == 0 &&
          saved.partyDueCents == 0 &&
          StockLedgerDao(db).stockOf(productId) == 0 &&
          QueryDao(db).accountBalances()[accountId] == 1500 &&
          docCount == 4;
      db.close();
      return ok;
    }());

    check('负库存放行（RULE-002 允许；界面层才告警）', () {
      final (Db db, SaleService service, PurchaseService _, String productId,
          String accountId, String _) = newEnv();
      final SaleSaved saved = service.create(
        draftFor(productId, accountId, paymentAmount: '50'),
        now: now(),
      );
      final bool ok = saved.totalCents == 5000 &&
          StockLedgerDao(db).stockOf(productId) == -10;
      db.close();
      return ok;
    }());

    check('赊销（有客户、无收款）→ 客户欠款记到名下（正数）', () {
      final (Db _, SaleService service, PurchaseService purchases,
          String productId, String accountId, String partyId) = newEnv();
      stockUp(purchases, productId, accountId);
      final SaleSaved saved = service.create(
        draftFor(productId, accountId, partyId: partyId),
        now: now(),
      );
      final bool ok = saved.paidCents == 0 &&
          saved.dueCents == 5000 &&
          saved.partyDueCents == 5000;
      return ok;
    }());

    check('部分收款 → 欠款 = 差额，累计欠款同步', () {
      final (Db _, SaleService service, PurchaseService purchases,
          String productId, String accountId, String partyId) = newEnv();
      stockUp(purchases, productId, accountId);
      final SaleSaved saved = service.create(
        draftFor(productId, accountId, partyId: partyId, paymentAmount: '20'),
        now: now(),
      );
      final bool ok = saved.paidCents == 2000 &&
          saved.dueCents == 3000 &&
          saved.partyDueCents == 3000;
      return ok;
    }());

    check('校验不过 → 抛 SaleDraftInvalid，库里不留单', () {
      final (Db db, SaleService service, PurchaseService _,
          String productId, String accountId, String _) = newEnv();
      Object? thrown;
      try {
        service.create(
          draftFor(productId, accountId, quantity: '0'),
          now: now(),
        );
      } catch (error) {
        thrown = error;
      }
      final int docCount =
          db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n']! as int;
      final bool ok = thrown is SaleDraftInvalid &&
          (thrown.lineErrors.single[SaleLineField.quantity] ?? '')
              .contains('正整数') &&
          docCount == 0;
      db.close();
      return ok;
    }());

    check('收款金额留空的行被跳过 → 等价于全赊', () {
      final (Db _, SaleService service, PurchaseService _,
          String productId, String accountId, String partyId) = newEnv();
      final SaleSaved saved = service.create(
        draftFor(productId, accountId, partyId: partyId, paymentAmount: ''),
        now: now(),
      );
      final bool ok = saved.paidCents == 0 &&
          saved.dueCents == 5000 &&
          saved.partyDueCents == 5000;
      return ok;
    }());

    check('stockSnapshot：采购后 10，卖出 3 件后 7', () {
      final (Db _, SaleService service, PurchaseService purchases,
          String productId, String accountId, String partyId) = newEnv();
      final bool before = !service.stockSnapshot().containsKey(productId);
      stockUp(purchases, productId, accountId);
      final bool afterBuy = service.stockSnapshot()[productId] == 10;
      service.create(
        draftFor(
          productId,
          accountId,
          partyId: partyId,
          quantity: '3',
        ),
        now: now(),
      );
      final bool afterSell = service.stockSnapshot()[productId] == 7;
      return before && afterBuy && afterSell;
    }());

    check('createCustomer：最小建档，空名抛', () {
      final (Db _, SaleService service, PurchaseService _,
          String _, String _, String _) = newEnv();
      final Party party = service.createCustomer('张姐', phone: ' 139 ');
      final bool ok = party.name == '张姐' &&
          party.phone == '139' &&
          party.roles.map((PartyRole r) => r.wire).join(',') == 'customer';
      bool emptyThrows = false;
      try {
        service.createCustomer('   ');
      } on StateError {
        emptyThrows = true;
      }
      return ok && emptyThrows;
    }());
  }

  // ============================================================ 收尾
  stdout.writeln('\n==============================================');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  stdout.writeln('==============================================');
  if (_failures.isNotEmpty) {
    for (final String name in _failures) {
      stdout.writeln('  失败：$name');
    }
    exit(1);
  }
}
