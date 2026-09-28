// PartyService.ensureParty（§Z 四：同名追加 role），对应 `docs/testing.md` §O。
//
// 覆盖：三分支（新建 / 追加 role / 原样返回）+ 空名抛 + phone 只在新建时写。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`；Windows 需要可用的 SQLite 原生库。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(useLocalSqlite);
  setUp(resetClock);

  late Db db;
  late PartyService service;

  setUp(() {
    db = newMemoryDb();
    service = PartyService(PartyDao(db));
  });

  tearDown(() => db.close());

  test('无同名 → 新建（roles = [role]，phone trim）', () {
    final PartyMutation result = service.ensureParty(
      name: ' 王老板 ',
      role: PartyRole.customer,
      phone: ' 138 ',
      now: now(),
    );

    expect(result.action, PartyMutationAction.created);
    expect(result.party.name, '王老板');
    expect(result.party.phone, '138');
    expect(result.party.roles, <PartyRole>[PartyRole.customer]);
  });

  test('同名但没有该 role → **追加 role**，其余字段不动', () {
    // 老王先作为供应商存在
    final PartyMutation first = service.ensureParty(
      name: '老王',
      role: PartyRole.supplier,
      phone: '138',
      now: now(),
    );

    // 现在也从他这里买货 → 他成了客户
    final PartyMutation second = service.ensureParty(
      name: '老王',
      role: PartyRole.customer,
      phone: '999999', // 对已有往来方，phone 不该被改动
      now: now() + 1,
    );

    expect(second.action, PartyMutationAction.roleAppended);
    expect(second.party.id, first.party.id, reason: '同一条 party，不是新建');
    expect(second.party.roles, <PartyRole>[PartyRole.supplier, PartyRole.customer]);
    expect(second.party.phone, '138', reason: 'phone 只在新建时写');
    // 库里真实状态一致
    final Party? stored = PartyDao(db).findById(first.party.id);
    expect(stored?.roles, <PartyRole>[PartyRole.supplier, PartyRole.customer]);
  });

  test('同名且 role 齐全 → 原样返回（不新建、不改动）', () {
    final PartyMutation first = service.ensureParty(
      name: '老王',
      role: PartyRole.customer,
      now: now(),
    );
    final PartyMutation second = service.ensureParty(
      name: '老王',
      role: PartyRole.customer,
      now: now() + 1,
    );

    expect(second.action, PartyMutationAction.existing);
    expect(second.party.id, first.party.id);
    expect(second.party.updatedAt, first.party.updatedAt, reason: '什么都没改');
  });

  test('同名取**最早建的**（用户的「老朋友」）', () {
    final PartyMutation first = service.ensureParty(name: '老王', role: PartyRole.supplier, now: now());
    service.ensureParty(name: '老王', role: PartyRole.supplier, now: now() + 100)
        .action; // 新逻辑下第二次是 existing，不会建第二条；为测「多个同名」手搓一条
    final int t = now() + 200;
    PartyDao(db).insert(Party(
      id: newId(),
      name: '老王',
      roles: const <PartyRole>[PartyRole.supplier],
      createdAt: t,
      updatedAt: t,
    ));

    expect(service.findByName('老王')?.id, first.party.id);
  });

  test('空名 / 全空格 → StateError（UI 先拦，这里是最后防线）', () {
    expect(() => service.ensureParty(name: '', role: PartyRole.customer), throwsStateError);
    expect(() => service.ensureParty(name: '   ', role: PartyRole.customer), throwsStateError);
  });

  test('采购/销售两侧共用：createSupplier 与 createCustomer 走同一实现', () {
    final PurchaseService purchases = PurchaseService(
      engine: RuleEngine(db),
      queries: QueryDao(db),
    );
    final Party supplier = purchases.createSupplier('老王');

    final PartyMutation asCustomer = PartyService(PartyDao(db)).ensureParty(
      name: '老王',
      role: PartyRole.customer,
      now: now(),
    );

    expect(asCustomer.action, PartyMutationAction.roleAppended);
    expect(asCustomer.party.id, supplier.id, reason: '同一条 party');
    final int count =
        db.raw.select("SELECT COUNT(*) AS n FROM parties WHERE name = '老王'")
            .first['n']! as int;
    expect(count, 1, reason: '绝不出现两条同名 party');
  });

  test('recentCustomers：按最近销售排序；无历史为空；散客被排除', () {
    final int t = now();
    final Account account = Account(
      id: newId(), name: '现金', type: AccountType.cash,
      createdAt: t, updatedAt: t,
    );
    AccountDao(db).insert(account);
    ProductDao(db).insert(Product(
      id: 'p1', code: 'P0001', name: '商品',
      costPrice: 300, sellPrice: 500, createdAt: t, updatedAt: t,
    ));
    final PartyDao partyDao = PartyDao(db);
    final Party early = Party(
      id: newId(), name: '早客', roles: const <PartyRole>[PartyRole.customer],
      createdAt: t, updatedAt: t,
    );
    final Party late = Party(
      id: newId(), name: '晚客', roles: const <PartyRole>[PartyRole.customer],
      createdAt: t, updatedAt: t,
    );
    partyDao.insert(early);
    partyDao.insert(late);

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

    final SaleService sales = SaleService(
      engine: RuleEngine(db),
      queries: QueryDao(db),
    );
    expect(sales.recentCustomers(), isEmpty, reason: '还没有销售历史');

    // 早客先卖（09-27）、晚客后卖（09-28）
    sales.create(saleFor(early.id, '2026-09-27'), now: now());
    sales.create(saleFor(late.id, '2026-09-28'), now: now());

    expect(
      sales.recentCustomers().map((Party p) => p.name).toList(),
      <String>['晚客', '早客'],
      reason: '按最近一次交易时间倒序',
    );

    // 散客单（party_id null）不进列表也不报错
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
    expect(
      sales.recentCustomers().map((Party p) => p.name).toList(),
      <String>['晚客', '早客'],
    );
  });

  group('createFull（往来方页完整新建，§AA 遗漏 1）', () {
    test('新建带双角色 + 电话地址 trim；空 roles 拦', () {
      final Party party = service.createFull(
        name: ' 王老板 ',
        roles: <PartyRole>[PartyRole.supplier, PartyRole.customer],
        phone: ' 138 ',
        address: ' 东门 3 号 ',
        now: now(),
      );

      expect(party.name, '王老板');
      expect(party.phone, '138');
      expect(party.address, '东门 3 号');
      expect(party.roles.toSet(), <PartyRole>{
        PartyRole.supplier,
        PartyRole.customer,
      });

      expect(
        () => service.createFull(name: 'x', roles: <PartyRole>[], now: now()),
        throwsStateError,
        reason: '至少一个角色',
      );
    });

    test('同名复用：phone/address 不被覆盖，角色追加（Z-4 同一保证）', () {
      final Party first = service.createFull(
        name: '老王',
        roles: <PartyRole>[PartyRole.supplier],
        phone: '138',
        address: '东门',
        now: now(),
      );

      final Party second = service.createFull(
        name: '老王',
        roles: <PartyRole>[PartyRole.customer],
        phone: '999',
        address: '西门',
        now: now() + 1,
      );

      expect(second.id, first.id, reason: '同一条 party');
      expect(second.roles.toSet(), <PartyRole>{
        PartyRole.supplier,
        PartyRole.customer,
      });
      expect(second.phone, '138', reason: '只新建时写');
      expect(second.address, '东门', reason: '只新建时写');
    });
  });
}
