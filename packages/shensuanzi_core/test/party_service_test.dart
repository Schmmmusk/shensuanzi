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

    test('OBS-05 回归：同名往来方已停用 ⇒ 恢复它 + 追加角色，**不造第二条**', () {
      final PartyService service = PartyService(PartyDao(db));
      final PartyMutation first = service.ensureParty(
        name: '老王批发',
        role: PartyRole.customer,
        now: now(),
      );
      // 停用它（模拟用户「不和他做了」）
      final Party disabled = Party(
        id: first.party.id,
        name: first.party.name,
        roles: first.party.roles,
        isActive: false,
        createdAt: first.party.createdAt,
        updatedAt: now(),
      );
      PartyDao(db).update(disabled);

      // 之后又以同名建（比如开采购单时输入「老王批发」）——
      // 修复前：查重只看启用行 ⇒ 造出第二条同名，往来账分流（OBS-05）
      final PartyMutation again = service.ensureParty(
        name: '老王批发',
        role: PartyRole.supplier,
        now: now(),
      );

      expect(again.party.id, first.party.id, reason: '必须复用同一条，不许新建');
      expect(again.action, PartyMutationAction.revived);
      expect(again.party.isActive, isTrue, reason: '恢复使用');
      expect(
        again.party.roles,
        containsAll(<PartyRole>[PartyRole.customer, PartyRole.supplier]),
      );
      // 库里只有一条同名
      expect(
        PartyDao(db)
            .findAll(active: null, limit: 100)
            .where((Party party) => party.name == '老王批发')
            .length,
        1,
      );
    });
  });

  // ============================================================ §审查 OBS-05 后半
  //
  // 主数据的生命周期：角色可编辑（从源头断掉「停用+重建」）+ 停用前有依据
  // 可校验 + 停用但还欠钱的往来方**不能从账上消失**。

  group('OBS-05 后半：角色可编辑 / 停用校验 / 幽灵账可见', () {
    test('updateProfile 可改角色：历史流水不受影响，syncVersion +1', () {
      final PartyMutation created = service.ensureParty(
        name: '老王',
        role: PartyRole.customer,
        phone: '138',
        now: now(),
      );
      final int before = created.party.syncVersion;

      final Party updated = service.updateProfile(
        created.party.id,
        name: '老王',
        roles: <PartyRole>[PartyRole.customer, PartyRole.supplier],
        now: now(),
      );

      expect(updated.roles, <PartyRole>[PartyRole.customer, PartyRole.supplier]);
      expect(updated.syncVersion, before + 1);
      // 角色以外的字段一个都不许动
      expect(updated.id, created.party.id);
      expect(updated.name, '老王');
      expect(updated.createdAt, created.party.createdAt);
      expect(updated.isActive, isTrue);
      // 再读回库里确认**落盘**（不是只改内存对象）
      expect(PartyDao(db).findById(created.party.id)!.roles, updated.roles);
    });

    test('updateProfile 的 roles 传 null =「不改角色」（只改资料）', () {
      final PartyMutation created = service.ensureParty(
        name: '老王',
        role: PartyRole.supplier,
        now: now(),
      );
      final Party updated = service.updateProfile(
        created.party.id,
        name: '老王批发',
        phone: '139',
        now: now(),
      );
      expect(updated.name, '老王批发');
      expect(updated.roles, <PartyRole>[PartyRole.supplier], reason: '角色原样');
    });

    test('角色**去重保序**（重复角色会让界面印出「客户 / 客户」）', () {
      final PartyMutation created = service.ensureParty(
        name: '老王',
        role: PartyRole.customer,
        now: now(),
      );
      final Party updated = service.updateProfile(
        created.party.id,
        name: '老王',
        roles: <PartyRole>[
          PartyRole.supplier,
          PartyRole.customer,
          PartyRole.supplier,
        ],
        now: now(),
      );
      expect(updated.roles, <PartyRole>[PartyRole.supplier, PartyRole.customer]);
    });

    test('角色可以清空（UI 会给提示），落库也是空', () {
      final PartyMutation created = service.ensureParty(
        name: '老王',
        role: PartyRole.customer,
        now: now(),
      );
      final Party updated = service.updateProfile(
        created.party.id,
        name: '老王',
        roles: <PartyRole>[],
        now: now(),
      );
      expect(updated.roles, isEmpty);
      expect(PartyDao(db).findById(created.party.id)!.roles, isEmpty);
    });

    test('balanceOf 从 party_ledger 算（正 = 应收 / 负 = 应付 / 无流水 = 0）', () {
      insertParty(db.raw, partyId);
      insertDocument(db.raw, documentId);
      expect(service.balanceOf(partyId), 0, reason: '没流水就是 0');

      insertPartyLedger(db.raw, 'pl-1', party: partyId, amount: 6000);
      expect(service.balanceOf(partyId), 6000);
      insertPartyLedger(db.raw, 'pl-2', party: partyId, amount: -2000);
      expect(service.balanceOf(partyId), 4000);
      // 停用前校验的口径必须与列表汇总一致 —— 未知 id 不编值
      expect(service.balanceOf('没有这个往来方'), 0);
    });

    test('listVisible：启用全显示；停用**无余额**不显示；停用**有余额**必须显示', () {
      final Party active = service.createFull(
        name: '在用的',
        roles: <PartyRole>[PartyRole.customer],
        now: now(),
      );
      final Party idleDisabled = service.createFull(
        name: '停用无账',
        roles: <PartyRole>[PartyRole.customer],
        now: now(),
      );
      final Party owingDisabled = service.createFull(
        name: '停用有账',
        roles: <PartyRole>[PartyRole.supplier],
        now: now(),
      );
      service.setActive(idleDisabled.id, active: false, now: now());
      service.setActive(owingDisabled.id, active: false, now: now());

      // 给「停用有账」造一笔应收（就是那种会被藏起来的钱）
      insertDocument(db.raw, documentId);
      insertPartyLedger(db.raw, 'pl-c', party: owingDisabled.id, amount: 4500);

      final Set<String> visible = service
          .listVisible()
          .map((Party party) => party.id)
          .toSet();
      expect(visible, contains(active.id), reason: '启用中的照常显示');
      expect(visible, isNot(contains(idleDisabled.id)), reason: '停用且无余额 ⇒ 不必显示');
      expect(
        visible,
        contains(owingDisabled.id),
        reason: '§审查 OBS-05：停用但**还欠着钱**的必须还能看到 —— 否则就是「幽灵账」',
      );
    });
  });

}
