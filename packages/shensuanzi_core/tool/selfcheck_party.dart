/// PartyService.ensureParty 的降级门禁（对应 `test/party_service_test.dart`）。
///
/// ⚠️ **改一边必须改另一边** —— `test/**` 是正式门禁，本脚本是
/// 「跑不了 `dart test` 时的降级门禁」（`docs/testing.md` §零）。
///
/// 运行：`dart run tool/selfcheck_party.dart`
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

  section('PartyService.ensureParty');
  {
    final Db db = Db.openInMemory();
    final PartyService service = PartyService(PartyDao(db));

    check('无同名 → 新建（roles=[role]，phone trim）', () {
      final PartyMutation r = service.ensureParty(
        name: ' 王老板 ',
        role: PartyRole.customer,
        phone: ' 138 ',
        now: now(),
      );
      return r.action == PartyMutationAction.created &&
          r.party.name == '王老板' &&
          r.party.phone == '138' &&
          r.party.roles.map((PartyRole role) => role.wire).join(',') ==
              PartyRole.customer.wire;
    }());

    check('同名但没有该 role → 追加 role，其余字段不动（phone 不改）', () {
      final PartyMutation first = service.ensureParty(
        name: '老王',
        role: PartyRole.supplier,
        phone: '138',
        now: now(),
      );
      final PartyMutation second = service.ensureParty(
        name: '老王',
        role: PartyRole.customer,
        phone: '999999',
        now: now() + 1,
      );
      return second.action == PartyMutationAction.roleAppended &&
          second.party.id == first.party.id &&
          second.party.roles.map((PartyRole role) => role.wire).join(',') ==
              '${PartyRole.supplier.wire},${PartyRole.customer.wire}' &&
          second.party.phone == '138' &&
          PartyDao(db).findById(first.party.id)!.roles.length == 2;
    }());

    check('同名且 role 齐全 → 原样返回（updatedAt 也不动）', () {
      final PartyMutation first = service.ensureParty(
        name: '老张',
        role: PartyRole.customer,
        now: now(),
      );
      final PartyMutation second = service.ensureParty(
        name: '老张',
        role: PartyRole.customer,
        now: now() + 1,
      );
      return second.action == PartyMutationAction.existing &&
          second.party.id == first.party.id &&
          second.party.updatedAt == first.party.updatedAt;
    }());

    check('同名取最早建的（findByName）', () {
      final PartyMutation first = service.ensureParty(
        name: '老刘',
        role: PartyRole.supplier,
        now: now(),
      );
      final int t = now() + 100;
      PartyDao(db).insert(Party(
        id: newId(),
        name: '老刘',
        roles: const <PartyRole>[PartyRole.supplier],
        createdAt: t,
        updatedAt: t,
      ));
      return service.findByName('老刘')?.id == first.party.id;
    }());

    check('空名 / 全空格 → StateError', () {
      bool emptyThrows = false;
      bool blankThrows = false;
      try {
        service.ensureParty(name: '', role: PartyRole.customer, now: now());
      } on StateError {
        emptyThrows = true;
      }
      try {
        service.ensureParty(name: '   ', role: PartyRole.customer, now: now());
      } on StateError {
        blankThrows = true;
      }
      return emptyThrows && blankThrows;
    }());

    check('采购/销售两侧共用：createSupplier + ensureParty(customer) 同一条', () {
      final PurchaseService purchases = PurchaseService(
        engine: RuleEngine(db),
        queries: QueryDao(db),
      );
      final Party supplier = purchases.createSupplier('老赵');
      final PartyMutation asCustomer = service.ensureParty(
        name: '老赵',
        role: PartyRole.customer,
        now: now(),
      );
      final int count =
          db.raw.select("SELECT COUNT(*) AS n FROM parties WHERE name = '老赵'")
              .first['n']! as int;
      return asCustomer.action == PartyMutationAction.roleAppended &&
          asCustomer.party.id == supplier.id &&
          count == 1;
    }());

    check('recentCustomers：按最近销售倒序；无历史为空；散客排除', () {
      final Db db2 = Db.openInMemory();
      final int t = now();
      final Account account = Account(
        id: newId(), name: '现金', type: AccountType.cash,
        createdAt: t, updatedAt: t,
      );
      AccountDao(db2).insert(account);
      ProductDao(db2).insert(Product(
        id: 'p1', code: 'P0001', name: '商品',
        costPrice: 300, sellPrice: 500, createdAt: t, updatedAt: t,
      ));
      final Party early = Party(
        id: newId(), name: '早客', roles: const <PartyRole>[PartyRole.customer],
        createdAt: t, updatedAt: t,
      );
      final Party late = Party(
        id: newId(), name: '晚客', roles: const <PartyRole>[PartyRole.customer],
        createdAt: t, updatedAt: t,
      );
      PartyDao(db2).insert(early);
      PartyDao(db2).insert(late);
      final SaleService sales = SaleService(
        engine: RuleEngine(db2),
        queries: QueryDao(db2),
      );
      SaleDraft saleFor(String partyId, String date) => SaleDraft(
        partyId: partyId,
        date: date,
        lines: const <SaleLineDraft>[
          SaleLineDraft(productId: 'p1', quantity: '1', unitPrice: '5.00'),
        ],
        payments: <SalePaymentDraft>[
          SalePaymentDraft(accountId: account.id, amount: '5.00'),
        ],
      );
      final bool empty = sales.recentCustomers().isEmpty;
      sales.create(saleFor(early.id, '2026-09-27'), now: now());
      sales.create(saleFor(late.id, '2026-09-28'), now: now());
      bool ordered = sales.recentCustomers().map((Party p) => p.name).join(',') ==
          '晚客,早客';
      sales.create(
        SaleDraft(
          date: '2026-09-29',
          lines: const <SaleLineDraft>[
            SaleLineDraft(productId: 'p1', quantity: '1', unitPrice: '5.00'),
          ],
          payments: <SalePaymentDraft>[
            SalePaymentDraft(accountId: account.id, amount: '5.00'),
          ],
        ),
        now: now(),
      );
      bool stillSame = sales.recentCustomers().map((Party p) => p.name).join(',') ==
          '晚客,早客';
      db2.close();
      return empty && ordered && stillSame;
    }());

    db.close();
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
