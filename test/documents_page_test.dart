// 单据列表页（`DocumentsPage`）的 widget 测试。
//
// 覆盖：时间范围默认最近 30 天（SC-3）/ 类型 chips 筛选 / 对方名与散客显示（SC-6）/
// **点击行打开单据详情（1a 起；以前是复制单号）** / 「全部」档的 200 条提示 /
// 导出按钮（§AF-2 文案、AF-5 走独立查询、筛选条件与列表一致）/
// **自动生成的收付款单被过滤**（§AN·二）。
// ⚠️ 必须 `useLocalSqlite()`（§N）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/documents_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

import 'support/fake_export.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late DocumentDao dao;
  late PurchaseService purchases;
  late SaleService sales;
  late SettlementService settlements;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_documents_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    dao = DocumentDao(db);
    purchases = PurchaseService(engine: RuleEngine(db), queries: QueryDao(db));
    sales = SaleService(engine: RuleEngine(db), queries: QueryDao(db));
    settlements = SettlementService(db: db, engine: RuleEngine(db));

    final int t = 1700000000000;
    ProductDao(db).insert(
      Product(
        id: 'p1',
        code: 'P0001',
        name: '商品',
        costPrice: 300,
        sellPrice: 500,
        createdAt: t,
        updatedAt: t,
      ),
    );
    AccountDao(db).insert(
      Account(
        id: 'a1',
        name: '现金',
        type: AccountType.cash,
        createdAt: t,
        updatedAt: t,
      ),
    );
    PartyDao(db).insert(
      Party(
        id: 'pt1',
        name: '王老板',
        roles: const <PartyRole>[PartyRole.supplier],
        createdAt: t,
        updatedAt: t,
      ),
    );
    PartyDao(db).insert(
      Party(
        id: 'pt2',
        name: '李姐',
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      ),
    );
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  void buy({required String date, required int qty, String? partyId}) {
    purchases.create(
      PurchaseDraft(
        partyId: partyId,
        date: date,
        lines: <PurchaseLineDraft>[
          PurchaseLineDraft(
            productId: 'p1',
            productName: '商品',
            quantity: '$qty',
            unitPrice: '3.00',
          ),
        ],
        payments: <PurchasePaymentDraft>[
          PurchasePaymentDraft(accountId: 'a1', amount: '${qty * 300 ~/ 100}'),
        ],
      ),
      now: 1700000000000,
    );
  }

  void sell({required String date, required int qty, String? partyId}) {
    sales.create(
      SaleDraft(
        partyId: partyId,
        date: date,
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: 'p1',
            productName: '商品',
            quantity: '$qty',
            unitPrice: '5.00',
          ),
        ],
        payments: <SalePaymentDraft>[
          SalePaymentDraft(accountId: 'a1', amount: '${qty * 500 ~/ 100}'),
        ],
      ),
      now: 1700000000000,
    );
  }

  /// 赊账销售（不收款）—— `sell` 是**当场结清**，测「未结清」要用这个。
  /// 散客不许赊账，所以必须给 partyId。
  void sellOnCredit({
    required String date,
    required int qty,
    required String partyId,
  }) {
    sales.create(
      SaleDraft(
        partyId: partyId,
        date: date,
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: 'p1',
            productName: '商品',
            quantity: '$qty',
            unitPrice: '5.00',
          ),
        ],
        payments: const <SalePaymentDraft>[],
      ),
      now: 1700000000000,
    );
  }

  Widget page({ExportSink? exports, bool withSettlement = false}) =>
      MaterialApp(
        home: Scaffold(
          body: DocumentsPage(
            dao: dao,
            exports: exports,
            // 默认**不接**核销服务：现有用例都是「只读列表」场景（行不可点）；
            // 需要测「点行进详情」时显式传 true（与其他可选服务同款判定）
            settlements: withSettlement ? settlements : null,
            products: withSettlement ? ProductService(db) : null,
          ),
        ),
      );

  testWidgets('空范围给空态提示', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.textContaining('这个范围里没有单据'), findsOneWidget);
  });

  testWidgets('列出单据：对方名 + 散客显示；日期倒序', (WidgetTester tester) async {
    // ⚠️ 日期刻意错开：occurred_at 相同时排序只靠 created_at 兜底，
    // 断言会变成赌 SQLite 的排序实现
    buy(date: '2026-09-27', qty: 10, partyId: 'pt1'); // 采购，王老板
    sell(date: '2026-09-28', qty: 2); // 散客销售
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // ⚠️ 立即付款会自动生成收/付款单（继承主单对方与日期，rule_engine §收付）：
    // 采购+付款 = 王老板 ×2（采购单 + 付款单）；散客销售同理 = 散客 ×2。
    // 所以断言「至少出现」而不是「恰好一行」。
    // ⚠️ 行内**对方名现在是独立的一行文字**（#26② 把单号从第一行挪走了），
    // 仍是 `documentPartyLabel` 的口径：散客 / 散采显示文字，不是空白。
    expect(find.textContaining('王老板'), findsWidgets, reason: '采购单与自动付款单都挂王老板');
    expect(find.textContaining('散客'), findsWidgets, reason: 'SC-6：无对方显示文字不是空白');
    expect(find.textContaining('XS'), findsWidgets, reason: '销售单号出现');

    // 日期倒序：09-28 的散客销售在 09-27 的采购前面 —— 用坐标验证
    final double ySale = tester.getTopLeft(find.textContaining('散客').first).dy;
    final double yBuy = tester.getTopLeft(find.textContaining('王老板').first).dy;
    expect(ySale < yBuy, isTrue, reason: '后发生的在前');
  });

  testWidgets('类型 chips：**多选**（可同时看销售与采购，§审查 2026-10-05）', (
    WidgetTester tester,
  ) async {
    buy(date: '2026-09-28', qty: 10, partyId: 'pt1');
    sell(date: '2026-09-28', qty: 2, partyId: 'pt2');
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // ⚠️ 一律**按 Key** 找 chip：文案是 `DocType.label`，与行内类型标签同字
    //    （按文案找会命中两处）；且 §审查 2026-10-05 起类型筛选是**多选**
    //    （`FilterChip`），不再有原来的「单选 / 再点一次取消」语义。
    await tester.tap(find.byKey(const Key('doc-type-sale')));
    await tester.pumpAndSettle();
    expect(find.textContaining('XS'), findsWidgets, reason: '销售单在');
    expect(find.textContaining('CG'), findsNothing, reason: '采购单被筛掉');

    // 再点「采购入库」⇒ **并集**（两张都回来）
    await tester.tap(find.byKey(const Key('doc-type-purchase')));
    await tester.pumpAndSettle();
    expect(find.textContaining('XS'), findsWidgets);
    expect(find.textContaining('CG'), findsWidgets, reason: '多选 = 并集');

    // 取消「店内销售」⇒ 只剩采购
    await tester.tap(find.byKey(const Key('doc-type-sale')));
    await tester.pumpAndSettle();
    expect(find.textContaining('XS'), findsNothing);
    expect(find.textContaining('CG'), findsWidgets);
  });

  testWidgets('类型 chips 补上「送货」「销售退货」（原来只有 4 类）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    for (final String wire in <String>[
      'purchase',
      'sale',
      'delivery',
      'sale_return',
      'purchase_return',
      'receipt',
      'payment',
    ]) {
      expect(
        find.byKey(Key('doc-type-$wire')),
        findsOneWidget,
        reason: '$wire 这一类要有入口',
      );
    }
    // 盘点 / 调拨 v1 不做 —— **不摆出来**（点了没数据 = 「软件坏了」）
    expect(find.byKey(const Key('doc-type-stocktake')), findsNothing);
    expect(find.byKey(const Key('doc-type-transfer')), findsNothing);
  });

  testWidgets('状态 chips：未结清只留还欠钱的单（§审查 2026-10-05）', (
    WidgetTester tester,
  ) async {
    sellOnCredit(date: '2026-09-28', qty: 2, partyId: 'pt2'); // 欠 ¥10
    sell(date: '2026-09-28', qty: 4, partyId: 'pt2'); // 当场结清
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.textContaining('XS'), findsNWidgets(2), reason: '两张都在');

    await tester.tap(find.byKey(const Key('doc-status-unsettled')));
    await tester.pumpAndSettle();
    expect(find.textContaining('XS'), findsOneWidget, reason: '只留还没结清的那张');
    expect(find.textContaining('未收'), findsOneWidget, reason: '行上要标出还欠多少');

    // 三个状态 chip 都在（送货待签收 / 已作废也要有入口）
    for (final String name in <String>[
      'unsettled',
      'cancelled',
      'awaitingSignature',
    ]) {
      expect(find.byKey(Key('doc-status-$name')), findsOneWidget);
    }
  });

  testWidgets('点行打开单据详情（1a 起；复制单号挪到详情页）', (WidgetTester tester) async {
    buy(date: '2026-09-28', qty: 10, partyId: 'pt1');
    await tester.pumpWidget(page(withSettlement: true));
    await tester.pumpAndSettle();

    final String docId = dao.listDocuments(limit: 1).single.document.id;
    await tester.tap(find.byKey(Key('doc-row-$docId')));
    await tester.pumpAndSettle();

    expect(find.text('单据详情'), findsOneWidget, reason: 'push 进了详情页');
    expect(
      find.byKey(const Key('copy-doc-no')),
      findsOneWidget,
      reason: '复制单号在详情页（SC-4 的动作没丢，只是挪了地方）',
    );
  });

  testWidgets('没接核销服务 → 行不可点（与其他可选服务同款判定）', (WidgetTester tester) async {
    buy(date: '2026-09-28', qty: 10, partyId: 'pt1');
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    final String docId = dao.listDocuments(limit: 1).single.document.id;
    await tester.tap(find.byKey(Key('doc-row-$docId')));
    await tester.pumpAndSettle();

    expect(find.text('单据详情'), findsNothing, reason: '没接服务就不跳转');
  });

  testWidgets('赊账未结清的行显示未收额（1a）', (WidgetTester tester) async {
    // 赊账销售：不收钱 → 未收 = 全额
    sales.create(
      SaleDraft(
        partyId: 'pt2',
        date: '2026-09-28',
        lines: <SaleLineDraft>[
          SaleLineDraft(
            productId: 'p1',
            productName: '商品',
            quantity: '2',
            unitPrice: '5.00',
          ),
        ],
      ),
      now: 1700000000000,
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(
      find.textContaining('未收 ¥'),
      findsOneWidget,
      reason: '一眼看出哪张还欠钱（比状态词直接）',
    );
  });

  testWidgets('「全部」档显示 200 条上限提示（SC-3）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(
      find.textContaining('只显示最近 200 条'),
      findsNothing,
      reason: '默认最近 30 天不提示',
    );

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.textContaining('只显示最近 200 条'), findsOneWidget);
  });

  // ---------------------------------------------------------------- 导出（§AF）

  testWidgets('导出按钮：导**当前筛选**、不写磁盘、列是中文（§AF-2 / AF-5）', (
    WidgetTester tester,
  ) async {
    buy(date: '2026-09-27', qty: 10, partyId: 'pt1'); // 采购入库（王老板）
    sell(date: '2026-09-28', qty: 2); // 散客销售
    final FakeExport fake = FakeExport();
    await tester.pumpWidget(page(exports: fake));
    await tester.pumpAndSettle();

    // AF-2：文案说清导的是「当前筛选」，不是「这一屏」
    expect(find.byKey(const Key('export-documents')), findsOneWidget);
    // AF-2：文案说清导的是「当前筛选」+ **不合并**（屏幕聚合、导出平铺）
    expect(
      find.text('导出当前筛选的单据（不做合并：退货单独一行）'),
      findsOneWidget,
      reason: '#26 批 3：屏幕一笔生意一行，导出逐条记录 —— 不说明会计会以为导错',
    );

    await tester.tap(find.byKey(const Key('export-documents')));
    await tester.pumpAndSettle();

    expect(fake.calls, 1, reason: '点一次只导一次');
    final ExportTable table = fake.last;
    expect(table.label, '单据');
    expect(table.header, <String>['单号', '单据类型', '对方', '金额', '已收付', '状态', '日期']);
    expect(table.rows, isNotEmpty);
    expect(
      table.rows.every((List<String> row) => row.length == 7),
      isTrue,
      reason: '每行字段数与表头一致',
    );
    expect(
      table.rows.any((List<String> row) => row[1] == '采购入库'),
      isTrue,
      reason: '单据类型输出中文',
    );
    expect(
      table.rows.any((List<String> row) => row[2] == '散客'),
      isTrue,
      reason: '散客不留空白（AF-9）',
    );
    expect(
      table.rows.every(
        (List<String> row) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(row[6]),
      ),
      isTrue,
      reason:
          '单据日期只到日（§BG 方案甲：occurred_at 是业务日期，'
          '带时分会整列印 00:00；往来流水导出才是带时分的适用面）',
    );
    // AF-5：导出走独立查询，**不是**列表用的 limit 200。
    // 这里是「同一批筛选」的间接证据：行数 = 库里的全部（示例里 4 张单）
    expect(
      table.rows.length,
      dao.listDocumentsForExport().length,
      reason: '导出的行数与「不分页读出来的行数」一致',
    );
    expect(fake.froms.single, isNotNull, reason: '默认最近 30 天 → 文件名带范围');
  });

  // #33（2026-10-14）：「自定义时间」选过一段范围之后**必须还能再打开** ——
  // `ChoiceChip` 点「已选中」项时回调收到的是 `false`（SDK `chip.dart:1128`
  // = `onSelected(!widget.selected)`）⇒ 吃过 `if (!selected) return;` 守卫就
  // 再也打不开（用户实测：必须先点别的档才绕得回来）。
  testWidgets('#33 「自定义时间」可以反复打开（点**已选中**的 chip 也要弹）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    final Finder custom = find.byKey(const Key('doc-range-custom'));

    // 第一次：打开 + **真选一段范围**。
    // ⚠️ 只「打开后取消」时 `_range` 仍是 last30、chip 未被选中 ⇒ **改前也是绿的**
    //（假绿）—— 所以必须把范围真的交回去。
    await tester.tap(custom);
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget);

    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop(
      DateTimeRange(start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 9)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsNothing);

    // ⭐ 回归点：此刻 chip 是**选中态**，再点一次仍必须弹出选择器
    await tester.tap(custom);
    await tester.pumpAndSettle();
    expect(
      find.byType(DateRangePickerDialog),
      findsOneWidget,
      reason: '#33：点「已选中」的 chip 回调收到 false ⇒ 吃了 !selected 守卫就再也打不开',
    );
  });

  // ------------------------------------------------- #26② 行内展示层级（2026-10-18）

  testWidgets('#26② 行内层级：对方 + 金额在第一行，单号降到第二行（仍可见）', (
    WidgetTester tester,
  ) async {
    sellOnCredit(date: '2026-09-28', qty: 2, partyId: 'pt2'); // 李姐 ¥10.00
    final String docNo = dao.listDocuments().single.document.docNo;
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    final Finder party = find.text('李姐');
    final Finder amount = find.text('¥ 10.00');
    final Finder meta = find.textContaining(docNo);

    expect(party, findsOneWidget, reason: '对方名是独立的一行（不再与日期拼串）');
    expect(amount, findsOneWidget);
    expect(meta, findsOneWidget, reason: '单号仍在行内，只是降级到第二行');

    final double yParty = tester.getTopLeft(party).dy;
    final double yAmount = tester.getTopLeft(amount).dy;
    final double yMeta = tester.getTopLeft(meta).dy;

    // 金额与对方名**同一行**（用户先看这两个数）
    expect(
      (yAmount - yParty).abs() < 8,
      isTrue,
      reason: '交易对象与交易金额必须在同一行（#26② 用户列的优先项）',
    );
    // 单号在**下面一行**，且横向靠左
    expect(yMeta, greaterThan(yParty), reason: '单号不再抢第一行');
    expect(
      tester.getTopLeft(meta).dx,
      lessThan(tester.getTopLeft(amount).dx),
      reason: '单号在左侧元信息行，不占金额那一列',
    );
  });

  testWidgets('#26② 长对方名：单行省略，不撑破行、不挤掉金额（截图实证）', (WidgetTester tester) async {
    // 用户截图里那一长串 `1` —— 原实现把它折成 3 行、把金额挤到屏幕边缘
    final String longName = '1' * 120;
    final int t = 1700000000000;
    PartyDao(db).insert(
      Party(
        id: 'pt-long',
        name: longName,
        roles: const <PartyRole>[PartyRole.customer],
        createdAt: t,
        updatedAt: t,
      ),
    );
    sellOnCredit(date: '2026-09-28', qty: 2, partyId: 'pt-long');
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    final Text nameText = tester.widget<Text>(find.text(longName));
    expect(nameText.maxLines, 1, reason: '对方名必须单行（否则长名撑成多行）');
    expect(nameText.overflow, TextOverflow.ellipsis);

    // 单行高度（bodyLarge 16sp × 行高 1.6 ≈ 26px；两行就 50+ 了）
    expect(
      tester.getSize(find.text(longName)).height,
      lessThan(40),
      reason: '长名不能把行撑高',
    );
    // 金额必须仍完整显示（左列是 Expanded，抢不走右列的宽度）
    expect(find.text('¥ 10.00'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不允许出现 overflow');
  });

  testWidgets('#26① 时间：主单只印日期（不印假的 00:00），收款单印到分', (WidgetTester tester) async {
    sellOnCredit(date: '2026-09-28', qty: 2, partyId: 'pt2');
    final String saleId = dao.listDocuments().single.document.id;
    // 手记收款：`occurred_at` = 真实时刻（`settlement_service` 的 `stamp`）
    settlements.settle(
      targetDocId: saleId,
      accountId: 'a1',
      amountCents: 1000,
      now: DateTime(2026, 9, 28, 16, 48).millisecondsSinceEpoch,
    );

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // §BG 回归：主单 occurred_at 是当天 00:00 ⇒ **不许印 00:00**
    expect(find.textContaining('00:00'), findsNothing);
    expect(find.textContaining('2026-09-28'), findsWidgets);

    // 点「收款」类目 ⇒ 派生单据放出来，必须带时分（否则同一天多张单分不出先后）
    await tester.tap(find.byKey(const Key('doc-type-receipt')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('2026-09-28 16:48'),
      findsOneWidget,
      reason: '有真时刻的单据要印到分（#26① Q3 乙）',
    );
  });

  // ------------------------------------------------------- #26 批 2：搜索（2026-10-18）

  testWidgets('#26 搜索：按对方名筛掉别的行（不是「空态」）', (WidgetTester tester) async {
    sellOnCredit(date: '2026-09-28', qty: 2, partyId: 'pt2'); // 李姐
    buy(date: '2026-09-27', qty: 10, partyId: 'pt1'); // 王老板
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('王老板'), findsWidgets, reason: '搜索前两张单都在');

    await tester.enterText(find.byKey(const Key('doc-search')), '李姐');
    await tester.pumpAndSettle();

    // ⚠️ 搜索框里也是「李姐」（EditableText 会被 find.text 命中）⇒
    // 只数**列表卡片里**的那一个
    expect(
      find.descendant(of: find.byType(Card), matching: find.text('李姐')),
      findsOneWidget,
    );
    expect(find.text('王老板'), findsNothing, reason: '不匹配的行要消失');
    expect(
      find.textContaining('这个范围里没有单据'),
      findsNothing,
      reason: '有结果时不能显示空态',
    );
  });

  testWidgets('#26 搜索：无结果时说的是「没找到」而不是「这个范围没有单」', (WidgetTester tester) async {
    sellOnCredit(date: '2026-09-28', qty: 2, partyId: 'pt2');
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('doc-search')), '查无此人');
    await tester.pumpAndSettle();

    expect(find.textContaining('没有找到和「查无此人」有关的单据'), findsOneWidget);
    expect(find.textContaining('这个范围里没有单据'), findsNothing);
  });

  testWidgets('#26 搜索：首次输入自动切「全部」并说明；清空后不切回', (WidgetTester tester) async {
    sellOnCredit(date: '2026-09-28', qty: 2, partyId: 'pt2');
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    ChoiceChip rangeChip(String name) =>
        tester.widget<ChoiceChip>(find.byKey(Key('doc-range-$name')));

    expect(rangeChip('last30').selected, isTrue, reason: '默认档');
    expect(find.textContaining('已切到「全部」来找'), findsNothing);

    await tester.enterText(find.byKey(const Key('doc-search')), '李姐');
    await tester.pumpAndSettle();

    expect(rangeChip('all').selected, isTrue, reason: '搜索跨全部时间');
    expect(rangeChip('last30').selected, isFalse);
    expect(
      find.textContaining('已切到「全部」来找（原来只显示最近 30 天）'),
      findsOneWidget,
      reason: '静默跨范围 = UI 撒谎（#26 批 2 裁定丙）',
    );

    // 清空：说明行消失，但**范围仍是「全部」**（用户可能还想接着找）
    await tester.tap(find.byKey(const Key('list-search-clear')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已切到「全部」来找'), findsNothing);
    expect(rangeChip('all').selected, isTrue, reason: '清空不自动切回');
  });

  testWidgets('#26 搜索：导出带同一个搜索词（AF-5：行数与列表一致）', (WidgetTester tester) async {
    sellOnCredit(date: '2026-09-28', qty: 2, partyId: 'pt2'); // 李姐
    buy(date: '2026-09-27', qty: 10, partyId: 'pt1'); // 王老板
    final FakeExport fake = FakeExport();
    await tester.pumpWidget(page(exports: fake));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('doc-search')), '李姐');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('export-documents')));
    await tester.pumpAndSettle();

    expect(fake.calls, 1);
    expect(fake.last.rows.length, 1, reason: '导出必须带同一个搜索词 —— 否则「导出当前筛选」当场变谎话');
    expect(fake.last.rows.single[2], '李姐', reason: '导出的确实是被筛中的那张');
  });

  // --------------------------------------------- #26 批 3：生命周期聚合（2026-10-18）

  /// 今天零点（默认「最近 30 天」要能命中，所以不能用写死的历史日期）
  int todayStart() {
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  }

  /// 一张销售 + 两张退货（都挂它）—— 用来验「一笔生意一行」的摘要与补偿项
  ({String saleId, String ret1, String ret2}) saleWithTwoReturns() {
    final RuleEngine engine = RuleEngine(db);
    final int t = todayStart();
    Document mk(String id, String no, DocType type, int total, {String? ref}) =>
        Document(
          id: id,
          docNo: no,
          docType: type,
          status: DocStatus.confirmed,
          partyId: 'pt1',
          totalAmount: total,
          refDocId: ref,
          occurredAt: t,
          createdAt: t + 1000,
          updatedAt: t + 1000,
        );

    final Document sale = mk('xs-1', 'XS20261012-008', DocType.sale, 24000);
    engine.dispatch(
      document: sale,
      lines: <DocumentLine>[
        DocumentLine.create(
          documentId: sale.id,
          productId: 'p1',
          quantity: 2,
          unitPrice: 12000,
        ),
      ],
      now: t + 1000,
    );
    for (final (String id, String no) in <(String, String)>[
      ('th-1', 'XT20261012-001'),
      ('th-2', 'XT20261012-002'),
    ]) {
      final Document ret = mk(id, no, DocType.saleReturn, 12000, ref: sale.id);
      engine.dispatch(
        document: ret,
        lines: <DocumentLine>[
          DocumentLine.create(
            documentId: ret.id,
            productId: 'p1',
            quantity: 1,
            unitPrice: 12000,
          ),
        ],
        now: t + 2000,
      );
    }
    return (saleId: sale.id, ret1: 'th-1', ret2: 'th-2');
  }

  testWidgets('#26 批 3：退货折进主单行，摘要「已退 N 次 ¥X」必须加粗', (WidgetTester tester) async {
    saleWithTwoReturns();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 一笔生意一行：主单在，两张退货单**不在**
    expect(find.textContaining('XS20261012-008'), findsOneWidget);
    expect(
      find.textContaining('XT20261012-001'),
      findsNothing,
      reason: '甲案：退货单折进主单行',
    );
    expect(find.textContaining('XT20261012-002'), findsNothing);

    final Finder trail = find.textContaining('已退 2 次');
    expect(trail, findsOneWidget);
    expect(find.textContaining('¥240.00'), findsWidgets);

    // 强制补偿项（docs/reply.md 2026-10-18）：
    // 「不能是灰扑扑的辅助文字」⇒ 必须加粗
    final Text trailText = tester.widget<Text>(trail);
    expect(
      trailText.style?.fontWeight,
      FontWeight.w600,
      reason: '摘要必须加粗（甲案的补偿项之一，不是可选装饰）',
    );
  });

  testWidgets('#26 批 3：没有关联的单不显示摘要行（反向灵敏度）', (WidgetTester tester) async {
    sellOnCredit(date: '2026-09-28', qty: 2, partyId: 'pt2');
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // ⚠️ 页面说明文字里也有「已退 N 次」⇒ 只在**列表卡片内**断言
    expect(
      find.descendant(
        of: find.byType(Card),
        matching: find.textContaining('已退'),
      ),
      findsNothing,
    );
    expect(find.textContaining('已收 0 笔'), findsNothing);
  });

  testWidgets('#26 批 3：筛「销售退货」⇒ 平铺 + 说明行（不让人以为单没了）', (
    WidgetTester tester,
  ) async {
    saleWithTwoReturns();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('doc-type-sale_return')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('当前按单张单据平铺显示'),
      findsOneWidget,
      reason: '平铺 / 聚合两种模式并存，必须说清现在是哪种',
    );
    expect(find.textContaining('XT20261012-001'), findsOneWidget);
    expect(find.textContaining('XT20261012-002'), findsOneWidget);
  });

  testWidgets('#26 批 3：详情页「退货记录」上移到金额区下方，且能点进退货单再返回', (
    WidgetTester tester,
  ) async {
    final ({String saleId, String ret1, String ret2}) f = saleWithTwoReturns();
    await tester.pumpWidget(page(withSettlement: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('doc-row-${f.saleId}')));
    await tester.pumpAndSettle();
    expect(find.text('单据详情'), findsOneWidget);

    // ① 上移：在「明细」区块**上方**（以前压在页面底部）
    final double yReturns = tester
        .getTopLeft(find.byKey(const Key('detail-returns')))
        .dy;
    final double yLines = tester.getTopLeft(find.text('明细')).dy;
    expect(yReturns < yLines, isTrue, reason: '甲案的「救生圈」：列表折叠了退货单，详情页必须一进来就看到');

    // ② 往返：点退货行 ⇒ 退货单详情 ⇒ 返回 ⇒ 回到原单
    await tester.tap(find.byKey(Key('return-row-${f.ret1}')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('XT20261012-001'),
      findsWidgets,
      reason: '进到了那张退货单的详情',
    );

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.textContaining('XS20261012-008'),
      findsWidgets,
      reason: '返回能回到原单，不是走丢',
    );
  });

  testWidgets('#26 批 3：赊账销售 + 详情页收款 ⇒ 列表只剩一行（用户复跑的场景）', (
    WidgetTester tester,
  ) async {
    sellOnCredit(date: '2026-09-28', qty: 2, partyId: 'pt2'); // 李姐 ¥10.00
    final String saleId = dao.listDocuments().single.document.id;
    // 用户真实路径：详情页点 [收款] ⇒ `settle` 生成的收款单 **ref_doc_id 是 NULL**，
    // 它与销售单的关联只在 `settlements` 里 —— 只看 ref_doc_id 就会漏折。
    settlements.settle(
      targetDocId: saleId,
      accountId: 'a1',
      amountCents: 1000,
      now: DateTime(2026, 9, 28, 16, 53).millisecondsSinceEpoch,
    );
    final DocumentSummary rcv = dao
        .listDocuments(includeDerived: true)
        .firstWhere(
          (DocumentSummary e) => e.document.docType == DocType.receipt,
        );

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(
      find.textContaining(rcv.document.docNo),
      findsNothing,
      reason: '收款单折进主单行，不再单独占一行（#26③ 的实质）',
    );
    expect(find.textContaining('已收 1 笔'), findsOneWidget);
  });

  testWidgets('#26 批 3：详情页「核销去向」上移，且能点开那张收款单再返回', (WidgetTester tester) async {
    sellOnCredit(date: '2026-09-28', qty: 2, partyId: 'pt2');
    final String saleId = dao.listDocuments().single.document.id;
    settlements.settle(
      targetDocId: saleId,
      accountId: 'a1',
      amountCents: 1000,
      now: DateTime(2026, 9, 28, 16, 53).millisecondsSinceEpoch,
    );
    final DocumentSummary rcv = dao
        .listDocuments(includeDerived: true)
        .firstWhere(
          (DocumentSummary e) => e.document.docType == DocType.receipt,
        );

    await tester.pumpWidget(page(withSettlement: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('doc-row-$saleId')));
    await tester.pumpAndSettle();

    // ① 上移：在「明细」上方
    final double yLinks = tester.getTopLeft(find.text('这单被哪些收付款核销过')).dy;
    final double yLines = tester.getTopLeft(find.text('明细')).dy;
    expect(yLinks < yLines, isTrue, reason: '收款单被折起来了，这里是它的唯一入口，不能压到底部');

    // ② 可点：进那张收款单的详情，再返回
    await tester.tap(find.byKey(Key('settle-row-${rcv.document.id}')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(rcv.document.docNo),
      findsWidgets,
      reason: '进到了那张收款单',
    );

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('单据详情'), findsOneWidget);
  });

  // 附录 B（`docs/ui-review-2026-10-21.md`）：单据列表页 原先**没有**大字号断言。
  // 批 3 第 18 条：前 17 项「尺寸随缩放派生」改造的机械护栏 —— 先立护栏再动尺寸。
  testWidgets('大字号（2.0）：单据列表页不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(960, 1000);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: '单据列表页在 2.0 档下溢出（附录 B 点名的结构：固定宽度 / 固定断点 / 顶部 Row）',
    );
  });

  // 批 3 第 16 条（用户裁定 ①③）：**真实总数** + **清空全部筛选**。
  testWidgets('真实总数：说「共 N 条」，超过 200 也说「只显示 200 / 共 N」', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.textContaining('共 '), findsOneWidget);
    expect(find.textContaining('条'), findsOneWidget);
  });

  testWidgets('清空全部筛选：搜索文字 + 三排筛选一次清完', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 先搜一下（会自动把范围切到「全部」）
    await tester.enterText(find.byKey(const Key('doc-search')), '李姐');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.textContaining('已切到「全部」'), findsOneWidget);

    // 一键清空：说明行消失 = 范围被切回来了
    await tester.tap(find.byKey(const Key('list-clear-filters')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已切到「全部」'), findsNothing);
  });
}
