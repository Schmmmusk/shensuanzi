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
    ProductDao(db).insert(Product(
      id: 'p1', code: 'P0001', name: '商品',
      costPrice: 300, sellPrice: 500, createdAt: t, updatedAt: t,
    ));
    AccountDao(db).insert(Account(
      id: 'a1', name: '现金', type: AccountType.cash, createdAt: t, updatedAt: t,
    ));
    PartyDao(db).insert(Party(
      id: 'pt1', name: '王老板',
      roles: const <PartyRole>[PartyRole.supplier], createdAt: t, updatedAt: t,
    ));
    PartyDao(db).insert(Party(
      id: 'pt2', name: '李姐',
      roles: const <PartyRole>[PartyRole.customer], createdAt: t, updatedAt: t,
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
          PurchasePaymentDraft(
            accountId: 'a1',
            amount: '${qty * 300 ~/ 100}',
          ),
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
          SalePaymentDraft(
            accountId: 'a1',
            amount: '${qty * 500 ~/ 100}',
          ),
        ],
      ),
      now: 1700000000000,
    );
  }

  /// 赊账销售（不收款）—— `sell` 是**当场结清**，测「未结清」要用这个。
  /// 散客不许赊账，所以必须给 partyId。
  void sellOnCredit({required String date, required int qty, required String partyId}) {
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

  Widget page({ExportSink? exports, bool withSettlement = false}) => MaterialApp(
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
    // ⚠️ 行内对方名渲染为「王老板 · 2026-09-27」插值串，精确匹配会 0 命中
    expect(find.textContaining('王老板'), findsWidgets,
        reason: '采购单与自动付款单都挂王老板');
    expect(find.textContaining('散客'), findsWidgets,
        reason: 'SC-6：无对方显示文字不是空白');
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

  testWidgets('类型 chips 补上「送货」「销售退货」（原来只有 4 类）', (
    WidgetTester tester,
  ) async {
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
    expect(
      find.textContaining('XS'),
      findsOneWidget,
      reason: '只留还没结清的那张',
    );
    expect(
      find.textContaining('未收'),
      findsOneWidget,
      reason: '行上要标出还欠多少',
    );

    // 三个状态 chip 都在（送货待签收 / 已作废也要有入口）
    for (final String name in <String>[
      'unsettled',
      'cancelled',
      'awaitingSignature',
    ]) {
      expect(find.byKey(Key('doc-status-$name')), findsOneWidget);
    }
  });

  testWidgets('点行打开单据详情（1a 起；复制单号挪到详情页）', (
    WidgetTester tester,
  ) async {
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

  testWidgets('没接核销服务 → 行不可点（与其他可选服务同款判定）', (
    WidgetTester tester,
  ) async {
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

    expect(find.textContaining('只显示最近 200 条'), findsNothing,
        reason: '默认最近 30 天不提示');

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
    expect(find.text('导出当前筛选的单据'), findsOneWidget);

    await tester.tap(find.byKey(const Key('export-documents')));
    await tester.pumpAndSettle();

    expect(fake.calls, 1, reason: '点一次只导一次');
    final ExportTable table = fake.last;
    expect(table.label, '单据');
    expect(table.header, <String>[
      '单号',
      '单据类型',
      '对方',
      '金额',
      '已收付',
      '状态',
      '日期',
    ]);
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
        (List<String> row) =>
            RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(row[6]),
      ),
      isTrue,
      reason: '单据日期只到日（§BG 方案甲：occurred_at 是业务日期，'
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
}
