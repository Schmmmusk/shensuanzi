// 往来方页（`PartiesPage`）与流水页（`PartyFlowPage`）的 widget 测试。
//
// 覆盖：应收/应付/已结清三态表达（遗漏 2）/ 总应收总应付汇总（遗漏 3）/
// 排序（|余额| 降序、0 沉底，AA-5）/ 完整新建（双角色，遗漏 1）/
// 流水页（单号 + 类型 + 方向字，AA-6）/ 导出按钮（§AF-2 文案、AF-7 文件名）/
// 角色可编辑 + 停用前校验余额 + 「停用但有余额仍显示」（§审查 OBS-05 后半）。
//
// ⚠️ 必须 `useLocalSqlite()`（§N）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/party_flow_page.dart';
import 'package:shensuanzi/src/ui/parties_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

import 'support/fake_export.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late PartyService service;
  late SaleService sales;
  late ProductDao products;
  late AccountDao accounts;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_parties_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    service = PartyService(PartyDao(db));
    sales = SaleService(engine: RuleEngine(db), queries: QueryDao(db));
    products = ProductDao(db);
    accounts = AccountDao(db);

    final int t = 1700000000000;
    products.insert(Product(
      id: 'p1', code: 'P0001', name: '商品',
      costPrice: 300, sellPrice: 500, createdAt: t, updatedAt: t,
    ));
    accounts.insert(Account(
      id: 'a1', name: '现金', type: AccountType.cash, createdAt: t, updatedAt: t,
    ));
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  Party createCustomer(String name) => service.createFull(
    name: name,
    roles: <PartyRole>[PartyRole.customer],
    now: 1700000000000,
  );

  /// 客户赊销 [yuan] 元（欠款挂名下）
  void creditSale(Party customer, int yuan) {
    sales.create(
      SaleDraft(
        partyId: customer.id,
        date: '2026-09-28',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: 'p1',
            productName: '商品',
            quantity: '1',
            unitPrice: '$yuan',
          ),
        ],
        payments: const <SalePaymentDraft>[],
      ),
      now: 1700000000000,
    );
  }

  Widget page({ExportSink? exports, MasterDataPolicy? policy}) => MaterialApp(
    home: Scaffold(
      body: PartiesPage(
        service: service,
        exports: exports,
        // 缺省桌面（三族全开）⇒ 既有用例**零变化**；mobile() 组显式传入
        masterDataPolicy: policy ?? const MasterDataPolicy.desktop(),
      ),
    ),
  );

  testWidgets('空列表给「怎么办」；新建双角色往来方 → 列表出现「已结清」', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有往来方'), findsOneWidget);

    await tester.tap(find.text('新建往来方'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('party-name')), '王老板');
    await tester.tap(find.text('供应商（我从他进货）'));
    await tester.pump();
    await tester.tap(find.text('客户（我卖给他）'));
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.text('王老板'), findsOneWidget);
    expect(find.text('供应商 / 客户'), findsOneWidget);
    expect(find.text('已结清'), findsOneWidget);
  });

  testWidgets('应收 / 应付 / 已结清三态；按 |余额| 降序 0 沉底；汇总行', (
    WidgetTester tester,
  ) async {
    final Party owing = createCustomer('甲客户');
    final Party paid = createCustomer('乙客户');
    createCustomer('丙客户'); // 0 余额沉底用
    creditSale(owing, 100); // 甲欠我 100
    creditSale(paid, 50);
    creditSale(paid, 30); // 乙共欠 80

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 三态表达（不用负号）
    expect(find.text('应收 ¥100.00'), findsOneWidget);
    expect(find.text('应收 ¥80.00'), findsOneWidget);
    expect(find.text('已结清'), findsOneWidget);

    // 排序：甲(100) → 乙(80) → 丙(0 沉底)
    final double yA = tester.getTopLeft(find.text('应收 ¥100.00')).dy;
    final double yB = tester.getTopLeft(find.text('应收 ¥80.00')).dy;
    expect(yA < yB, isTrue, reason: '欠得多的在前');
    final double yC = tester.getTopLeft(find.text('已结清')).dy;
    expect(yC > yB, isTrue, reason: '0 沉底');

    // 汇总行
    expect(find.text('总应收 ¥180.00'), findsOneWidget);
    expect(find.text('总应付 ¥0.00'), findsOneWidget);
  });

  testWidgets('流水页：单号 + 类型 + 方向字 + 底部说明；行不可点', (
    WidgetTester tester,
  ) async {
    final Party customer = createCustomer('甲客户');
    creditSale(customer, 100);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PartyFlowPage(party: customer, service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 单号是正式单号（非待同步前缀）
    final String docNo = service.flowsOf(customer.id).single.docNo;
    expect(find.text(docNo), findsOneWidget);
    expect(docNo.startsWith(Document.pendingDocNoPrefix), isFalse);
    expect(find.text('店内销售'), findsOneWidget, reason: 'doc_type 的中文标签');
    expect(find.text('欠款 +¥100.00'), findsOneWidget);
    // C3·§CJ·补 1：底部文案两版 —— 默认宽表面（800×600）走桌面版
    expect(find.textContaining('在「单据」页找到对应单号'), findsOneWidget);
    expect(find.textContaining('功能开发中'), findsNothing);
  });

  testWidgets('窄屏（<600）流水页：两行卡片 + 「到电脑上」底部说明（B1′）', (
    WidgetTester tester,
  ) async {
    final Party customer = createCustomer('甲客户');
    creditSale(customer, 100);

    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PartyFlowPage(party: customer, service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 行重排：类型标签 / 金额 / 单号 / 日期 都在（两行卡片）
    expect(find.text('店内销售'), findsOneWidget);
    expect(find.text('欠款 +¥100.00'), findsOneWidget);
    expect(
      find.text(service.flowsOf(customer.id).single.docNo),
      findsOneWidget,
    );
    // 窄屏底部文案（引导到电脑 —— 手机无「单据」页入口）
    expect(find.textContaining('到电脑上打开「单据」页'), findsOneWidget);
    expect(find.textContaining('功能开发中'), findsNothing);
  });

  testWidgets('编辑资料：改名保存成功；流水与角色不受影响', (WidgetTester tester) async {
    final Party customer = createCustomer('甲客户');
    creditSale(customer, 100);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 编辑走行尾 PopupMenu（行点击是进流水页）
    await tester.tap(
      find.descendant(
        of: find.byKey(Key('party-row-${customer.id}')),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑资料'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('party-name')), '甲客户（新）');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('甲客户（新）'), findsOneWidget);
    // 余额与角色都没动
    expect(find.text('应收 ¥100.00'), findsOneWidget);
    final Party? stored = service.findByName('甲客户（新）');
    expect(stored?.roles, contains(PartyRole.customer));
  });

  // ---------------------------------------------------------------- 导出（§AF）

  testWidgets('导出往来方：全量、列含电话地址与应收/应付（AF-9 / AF-12 类推）', (
    WidgetTester tester,
  ) async {
    final Party customer = createCustomer('王老板');
    creditSale(customer, 100);

    final FakeExport fake = FakeExport();
    await tester.pumpWidget(page(exports: fake));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('export-parties')), findsOneWidget);
    expect(find.text('导出往来方'), findsOneWidget);

    await tester.tap(find.byKey(const Key('export-parties')));
    await tester.pumpAndSettle();

    expect(fake.calls, 1);
    final ExportTable table = fake.last;
    expect(table.label, '往来方');
    expect(table.header, <String>[
      '往来方',
      '角色',
      '电话',
      '地址',
      '应收',
      '应付',
      '状态',
    ]);
    final List<String> row = table.rows.single;
    expect(row[0], '王老板');
    expect(row[1], '客户');
    expect(row[4], '100.00', reason: '应收一列给正数（不用负号）');
    expect(row[5], '0.00');
    expect(row[6], '启用');
  });

  testWidgets('导出流水：文件名带往来方名（AF-7），行数 = 该方全部流水', (
    WidgetTester tester,
  ) async {
    final Party customer = createCustomer('王老板');
    creditSale(customer, 100);

    final FakeExport fake = FakeExport();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PartyFlowPage(
            party: customer,
            service: service,
            exports: fake,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // AF-2 语义改由页面上下文承载（本页只有这一方的流水）——
    // C3·裁定：按钮收窄为「导出流水」（原长文案在窄屏把标题挤成一字）
    expect(find.byKey(const Key('export-party-flow')), findsOneWidget);
    expect(find.text('导出流水'), findsOneWidget);

    await tester.tap(find.byKey(const Key('export-party-flow')));
    await tester.pumpAndSettle();

    expect(fake.calls, 1);
    expect(fake.last.label, '往来流水');
    expect(fake.last.header, <String>['单号', '单据类型', '金额', '日期']);
    expect(
      fake.last.rows.length,
      service.flowsOf(customer.id).length,
      reason: '该往来方的全部流水（不是前 200 条）',
    );
    expect(
      fake.extras.single,
      '王老板',
      reason: 'AF-7：文件名要带往来方名，否则多个客户的文件名全一样',
    );
  });

  // ---------------------------------------------------------------- §审查 OBS-05 后半
  //
  // 主数据生命周期的三件事：角色可编辑（从源头断掉「停用 + 重建」）/
  // 停用前有依据可校验 / 停用但还欠钱的往来方**不能从账上消失**。

  testWidgets('编辑能改角色：加一个角色，不再需要「停用 + 重建」', (WidgetTester tester) async {
    final Party customer = createCustomer('王老板');
    creditSale(customer, 100);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(Key('party-row-${customer.id}')),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑资料'));
    await tester.pumpAndSettle();

    // 编辑对话框里**也有**角色勾选框（以前只有新建才有 —— 想加角色只能重建）
    expect(find.byKey(const Key('party-role-supplier')), findsOneWidget);
    expect(find.byKey(const Key('party-role-customer')), findsOneWidget);

    await tester.tap(find.byKey(const Key('party-role-supplier')));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final Party? stored = service.findByName('王老板');
    expect(
      stored?.roles,
      containsAll(<PartyRole>[PartyRole.customer, PartyRole.supplier]),
      reason: '§审查 OBS-05：加角色不必重建同名 party（那会分流往来账）',
    );
    // 历史欠款一分没动
    expect(find.text('应收 ¥100.00'), findsOneWidget);
  });

  testWidgets('停用**有余额**的往来方：先二次确认；确认后**仍在列表里**（标「账未结清」）', (
    WidgetTester tester,
  ) async {
    final Party customer = createCustomer('王老板');
    creditSale(customer, 100);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    Future<void> openMenu() async {
      await tester.tap(
        find.descendant(
          of: find.byKey(Key('party-row-${customer.id}')),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pumpAndSettle();
    }

    await openMenu();
    await tester.tap(find.text('停用'));
    await tester.pumpAndSettle();

    // 有未结清的账 ⇒ 必须二次确认，且确认框要说清「还能看到」
    expect(find.text('这个往来方还有没结清的账'), findsOneWidget);
    expect(find.textContaining('应收 ¥100.00'), findsWidgets);

    // 「取消」⇒ 什么都不变
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      service.findByName('王老板')!.isActive,
      isTrue,
      reason: '取消就该原样（不能有副作用）',
    );

    // 再来一次，「还是停用」
    await openMenu();
    await tester.tap(find.text('停用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('还是停用'));
    await tester.pumpAndSettle();

    expect(service.findByNameIncludingInactive('王老板')!.isActive, isFalse);
    // ⚠️ 幽灵账无处可藏：停用了，但因为还欠钱，**仍然显示**
    expect(
      find.byKey(Key('party-row-${customer.id}')),
      findsOneWidget,
      reason: '§审查 OBS-05：藏起来就是用户看不到的应收',
    );
    expect(find.text('已停用 · 账未结清'), findsOneWidget);
    expect(find.text('应收 ¥100.00'), findsOneWidget, reason: '余额还在账上');
    expect(find.text('总应收 ¥100.00'), findsOneWidget, reason: '汇总也要算它');
  });

  testWidgets('停用**无余额**的往来方：不打扰（不弹确认），并从列表消失', (WidgetTester tester) async {
    final Party idle = createCustomer('没来往的');

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.byKey(Key('party-row-${idle.id}')), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(Key('party-row-${idle.id}')),
        matching: find.byIcon(Icons.more_vert),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('停用'));
    await tester.pumpAndSettle();

    expect(
      find.text('这个往来方还有没结清的账'),
      findsNothing,
      reason: '没欠钱就问一句是骚扰',
    );
    expect(service.findByNameIncludingInactive('没来往的')!.isActive, isFalse);
    expect(
      find.byKey(Key('party-row-${idle.id}')),
      findsNothing,
      reason: '干净停用的不必占位置（它没有账要提醒）',
    );
    expect(find.textContaining('还没有往来方'), findsOneWidget);
  });

  // ============================================================ §CV·七 ① 乙
  // `mobile()` 下**本页消费值对象**的分支（值对象本身由 `master_data_policy_test` /
  // `selfcheck_app` 钉）—— 这里钉「往来 = false ⇒ 走引导，不进表单」。
  testWidgets('mobile()：＋新建往来方 ⇒ 出**引导**（往来 v1 禁建）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page(policy: const MasterDataPolicy.mobile()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建往来方'));
    await tester.pumpAndSettle();

    expect(
      find.text('这一步在电脑上做'),
      findsOneWidget,
      reason: '往来 v1 禁建 ⇒ 保留入口 + 引导到电脑',
    );
    expect(
      find.byKey(const Key('party-name')),
      findsNothing,
      reason: '不能进表单 —— 条件写反（把 false 当 true 用）会在这里暴露',
    );
  });
}
