/// 采购开单的降级门禁（对应 `test/purchase_draft_test.dart`）。
///
/// ⚠️ **改一边必须改另一边** —— `test/**` 是正式门禁，本脚本是
/// 「跑不了 `dart test` 时的降级门禁」（`docs/testing.md` §零）。
///
/// 运行：`dart run tool/selfcheck_purchase.dart`
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
  section('PurchaseDraft 校验');
  {
    PurchaseDraft goodDraft({
      String? partyId,
      String date = '2026-09-27',
      List<PurchaseLineDraft>? lines,
      List<PurchasePaymentDraft>? payments,
    }) => PurchaseDraft(
      partyId: partyId,
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

    check('散采 + 全款 → 通过（往来净额为 0）', () {
      final PurchaseDraft d = goodDraft(
        payments: const <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: 'a1', amount: '35'),
        ],
      );
      return d.isValid;
    }());

    check('没有明细 → lines 报「至少要有一行」',
        (goodDraft(lines: const <PurchaseLineDraft>[]).validate()[PurchaseField.lines] ?? '')
            .contains('至少要有一行商品'));

    check('空行报行级错误（加了一行就得填或删）', () {
      const PurchaseLineDraft blank = PurchaseLineDraft();
      final Map<PurchaseLineField, String> e = blank.validate();
      return e.containsKey(PurchaseLineField.product) &&
          e.containsKey(PurchaseLineField.quantity) &&
          e.containsKey(PurchaseLineField.unitPrice) &&
          blank.isEmpty;
    }());

    check('行级三错齐报：商品 / 数量 / 单价', () {
      const PurchaseLineDraft line = PurchaseLineDraft(
        quantity: '0',
        unitPrice: '-1',
      );
      final Map<PurchaseLineField, String> e = line.validate();
      return (e[PurchaseLineField.product] ?? '').contains('请选一个商品') &&
          (e[PurchaseLineField.quantity] ?? '').contains('正整数') &&
          (e[PurchaseLineField.unitPrice] ?? '').contains('不能是负数');
    }());

    check('数量拒小数；单价拒三位小数', () {
      const PurchaseLineDraft a = PurchaseLineDraft(
        productId: 'p1',
        quantity: '1.5',
        unitPrice: '3.5',
      );
      const PurchaseLineDraft b = PurchaseLineDraft(
        productId: 'p1',
        quantity: '2',
        unitPrice: '3.505',
      );
      return (a.validate()[PurchaseLineField.quantity] ?? '').contains('正整数') &&
          (b.validate()[PurchaseLineField.unitPrice] ?? '').contains('两位小数');
    }());

    check('付款行：金额空 = 跳过；0 拦；缺账户拦', () {
      const PurchasePaymentDraft blank = PurchasePaymentDraft(accountId: 'a1');
      const PurchasePaymentDraft zero = PurchasePaymentDraft(
        accountId: 'a1',
        amount: '0',
      );
      const PurchasePaymentDraft noAccount = PurchasePaymentDraft(amount: '10');
      return blank.validate().isEmpty &&
          blank.amountCents == null &&
          (zero.validate()[PurchasePaymentField.amount] ?? '').contains('大于 0') &&
          (noAccount.validate()[PurchasePaymentField.account] ?? '')
              .contains('请选一个资金账户');
    }());

    check('散采且有欠款 → party 报「散采要当场结清」',
        (goodDraft().validate()[PurchaseField.party] ?? '')
            .contains('散采要当场结清'));

    check('有供应商 + 欠款 → 不报，欠款 = 3500', () {
      final PurchaseDraft d = goodDraft(partyId: 'party-1');
      return d.validate().isEmpty && d.dueCents == 3500;
    }());

    check('散采检查在行不合法时不报（一次一个重点）', () {
      final PurchaseDraft d = goodDraft(
        lines: const <PurchaseLineDraft>[
          PurchaseLineDraft(productId: 'p1', quantity: 'x', unitPrice: '3.50'),
        ],
      );
      return !d.validate().containsKey(PurchaseField.party) && !d.linesOk;
    }());

    check('日期：空 / 斜杠格式都报，标准格式过', () {
      return (goodDraft(date: '').validate()[PurchaseField.date] ?? '')
              .contains('请填日期') &&
          (goodDraft(date: '2026/9/27').validate()[PurchaseField.date] ?? '')
              .contains('日期格式不对') &&
          goodDraft(
            date: '2026-09-27',
            payments: const <PurchasePaymentDraft>[
              PurchasePaymentDraft(accountId: 'a1', amount: '35'),
            ],
          ).validate().isEmpty;
    }());

    check('取值：合计 23500 / 已付 20000 / 欠款 3500 / occurredAt 是当天', () {
      final PurchaseDraft d = goodDraft(
        partyId: 'party-1',
        lines: const <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: 'p1',
            quantity: '10',
            unitPrice: '3.50',
          ),
          PurchaseLineDraft(productId: 'p2', quantity: '2', unitPrice: '100'),
        ],
        payments: const <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: 'a1', amount: '200'),
        ],
      );
      return d.totalCents == 23500 &&
          d.paidCents == 20000 &&
          d.dueCents == 3500 &&
          d.occurredAt ==
              DateTime.parse('2026-09-27').millisecondsSinceEpoch;
    }());

    check('fromProduct：单价预填进价（350 分 = 3.50 元），数量待填', () {
      const Product product = Product(
        id: 'p1',
        code: 'P0001',
        name: '红富士苹果',
        costPrice: 350,
        createdAt: 0,
        updatedAt: 0,
      );
      final PurchaseLineDraft line = PurchaseLineDraft.fromProduct(product);
      return line.productId == 'p1' &&
          line.unitPrice == '3.50' &&
          line.quantity == '' &&
          line.validate().keys.single == PurchaseLineField.quantity;
    }());

    check('付款合计超合计 → payments 报「超过了本单合计」', () {
      final PurchaseDraft d = goodDraft(
        payments: const <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: 'a1', amount: '999'),
        ],
      );
      return (d.validate()[PurchaseField.payments] ?? '').contains('超过了本单合计');
    }());
  }

  // ============================================================ 提交服务
  section('PurchaseService.create');
  {
    // ⚠️ **每个用例独立内存库**：同一供应商连续开单会让「累计欠款」跨用例累计，
    // docCount 也会互相污染 —— 这是 testing.md §零 记过的「自检跨段复用」坑。
    ({
      Db db,
      PurchaseService service,
      String productId,
      String accountId,
      String partyId,
    }) setup() {
      final Db db = Db.openInMemory();
      final Product product = Product(
        id: newId(),
        code: 'P001',
        name: '商品-P001',
        costPrice: 350,
        createdAt: now(),
        updatedAt: now(),
      );
      ProductDao(db).insert(product);
      final Account account = Account(
        id: newId(),
        name: '现金',
        type: AccountType.cash,
        createdAt: now(),
        updatedAt: now(),
      );
      AccountDao(db).insert(account);
      final Party party = Party(
        id: newId(),
        name: '王老板',
        roles: const <PartyRole>[PartyRole.supplier],
        createdAt: now(),
        updatedAt: now(),
      );
      PartyDao(db).insert(party);

      final PurchaseService service = PurchaseService(
        engine: RuleEngine(db),
        queries: QueryDao(db),
      );
      return (
        db: db,
        service: service,
        productId: product.id,
        accountId: account.id,
        partyId: party.id,
      );
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

    int docCountOf(Db db) =>
        db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n']! as int;

    check('散采全款 → 正式单号 + 库存 +10 + 资金 -3500', () {
      final (:db, :service, :productId, :accountId, partyId: _) = setup();
      try {
        final PurchaseSaved saved = service.create(
          draftFor(
            productId: productId,
            accountId: accountId,
            paymentAmount: '35',
          ),
          now: now(),
        );
        return !Document.isPendingDocNo(saved.docNo) &&
            saved.totalCents == 3500 &&
            saved.paidCents == 3500 &&
            saved.dueCents == 0 &&
            saved.partyDueCents == 0 &&
            StockLedgerDao(db).stockOf(productId) == 10 &&
            QueryDao(db).accountBalances()[accountId] == -3500 &&
            docCountOf(db) == 2;
      } finally {
        db.close();
      }
    }());

    check('赊购（有供应商、无付款）→ 欠款记到名下', () {
      final (:db, :service, :productId, :accountId, :partyId) = setup();
      try {
        final PurchaseSaved saved = service.create(
          draftFor(
            partyId: partyId,
            productId: productId,
            accountId: accountId,
          ),
          now: now(),
        );
        return saved.paidCents == 0 &&
            saved.dueCents == 3500 &&
            saved.partyDueCents == 3500;
      } finally {
        db.close();
      }
    }());

    check('部分付款 → 欠款 = 差额，累计欠款同步', () {
      final (:db, :service, :productId, :accountId, :partyId) = setup();
      try {
        final PurchaseSaved saved = service.create(
          draftFor(
            partyId: partyId,
            productId: productId,
            accountId: accountId,
            paymentAmount: '10',
          ),
          now: now(),
        );
        return saved.paidCents == 1000 &&
            saved.dueCents == 2500 &&
            saved.partyDueCents == 2500;
      } finally {
        db.close();
      }
    }());

    check('校验不过 → 抛 PurchaseDraftInvalid，库里不留单', () {
      final (:db, :service, :productId, :accountId, partyId: _) = setup();
      try {
        Object? thrown;
        try {
          service.create(
            draftFor(
              productId: productId,
              accountId: accountId,
              quantity: '0',
            ),
            now: now(),
          );
        } catch (error) {
          thrown = error;
        }
        return thrown is PurchaseDraftInvalid &&
            (thrown.lineErrors.single[PurchaseLineField.quantity] ?? '')
                .contains('正整数') &&
            docCountOf(db) == 0;
      } finally {
        db.close();
      }
    }());

    check('付款金额留空的行被跳过 → 等价于全赊', () {
      final (:db, :service, :productId, :accountId, :partyId) = setup();
      try {
        final PurchaseSaved saved = service.create(
          draftFor(
            partyId: partyId,
            productId: productId,
            accountId: accountId,
            paymentAmount: '',
          ),
          now: now(),
        );
        return saved.paidCents == 0 &&
            saved.dueCents == 3500 &&
            saved.partyDueCents == 3500;
      } finally {
        db.close();
      }
    }());

    check('createSupplier：最小建档，空名抛', () {
      final (:db, :service, productId: _, accountId: _, partyId: _) = setup();
      try {
        final Party party = service.createSupplier('李老板', phone: ' 139 ');
        final bool ok = party.name == '李老板' &&
            party.phone == '139' &&
            party.roles.map((PartyRole r) => r.wire).join(',') == 'supplier';
        bool emptyThrows = false;
        try {
          service.createSupplier('   ');
        } on StateError {
          emptyThrows = true;
        }
        return ok && emptyThrows;
      } finally {
        db.close();
      }
    }());
  }

  // ============================================================ 收尾
  stdout.writeln('\n${'=' * 46}');
  stdout.writeln('通过 $_pass 项，失败 $_fail 项');
  if (_failures.isNotEmpty) {
    stdout.writeln('失败清单：');
    for (final String name in _failures) {
      stdout.writeln('  - $name');
    }
  }
  stdout.writeln('=' * 46);
  exit(_fail == 0 ? 0 : 1);
}
