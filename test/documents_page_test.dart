// 单据列表页（`DocumentsPage`）的 widget 测试。
//
// 覆盖：时间范围默认最近 30 天（SC-3）/ 类型 chips 筛选 / 对方名与散客显示（SC-6）/
// 点击复制单号（SC-4）/ 「全部」档的 200 条提示。
// ⚠️ 必须 `useLocalSqlite()`（§N）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/documents_page.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late DocumentDao dao;
  late PurchaseService purchases;
  late SaleService sales;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_documents_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    dao = DocumentDao(db);
    purchases = PurchaseService(engine: RuleEngine(db), queries: QueryDao(db));
    sales = SaleService(engine: RuleEngine(db), queries: QueryDao(db));

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

  Widget page() => MaterialApp(
    home: Scaffold(body: DocumentsPage(dao: dao)),
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

  testWidgets('类型 chips：选「店内销售」只看销售', (WidgetTester tester) async {
    buy(date: '2026-09-28', qty: 10, partyId: 'pt1');
    sell(date: '2026-09-28', qty: 2, partyId: 'pt2');
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // ⚠️ chip 文案 = DocType.label：sale 是「店内销售」（不是「销售开单」）。
    // 同文案会命中两处（chip + 行内类型标签），必须用 ChoiceChip 祖先定位
    await tester.tap(
      find.ancestor(
        of: find.text('店内销售'),
        matching: find.byType(ChoiceChip),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('XS'), findsWidgets, reason: '销售单在');
    // 采购单被筛掉：切到「采购入库」chip 验证（同样用 ChoiceChip 定位）
    await tester.tap(
      find.ancestor(
        of: find.text('采购入库'),
        matching: find.byType(ChoiceChip),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('CG'), findsWidgets, reason: '采购单号 CG 前缀');
    expect(find.textContaining('XS'), findsNothing, reason: '销售单被筛掉');
  });

  testWidgets('点行复制单号（SC-4）', (WidgetTester tester) async {
    buy(date: '2026-09-28', qty: 10, partyId: 'pt1');
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    final String docNo = dao.listDocuments(limit: 1).single.document.docNo;
    await tester.tap(find.text(docNo));
    await tester.pumpAndSettle();

    expect(find.textContaining('已复制单号'), findsOneWidget);
    // 不回读 Clipboard.getData：widget 测试里没有真实剪贴板（平台通道是桩），
    // 读回为 null 会让断言假红 —— 复制内容正确性由 SnackBar 文案 + 一行
    // Clipboard.setData 平台调用兜底，属 Flutter 框架行为，不在本页测试范围。
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
}
