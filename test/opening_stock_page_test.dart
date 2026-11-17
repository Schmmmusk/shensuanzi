// 期初录入页（`OpeningStockPage`）的 widget 测试（§AD）。
//
// 覆盖：空表单拦截 / 选商品与差额显示（建议 1）/ 确认弹窗（AD-5 摘要 +
// 用户语言）+ 成功后 SnackBar 与返回 / 原样重录的诚实反馈（建议 2）/
// 同商品两行拒绝（AD-3）/ 取消确认 / 选择器空查询显示全部商品（AD-2）。
//
// ⚠️ 必须 `useLocalSqlite()`（§N）；差额与账面数的判断在 core 侧
// （`stocktake_service_test.dart`）已钉，这里只钉摆放与交互。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/opening_stock_page.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late ProductService products;
  late QueryDao queries;
  late StocktakeService service;
  late String p1;
  late String p2;
  final int t = 1700000000000;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_opening_stock_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    products = ProductService(db);
    queries = QueryDao(db);
    service = StocktakeService(engine: RuleEngine(db), queries: queries);

    final Product a = Product(
      id: newId(),
      code: 'P0001',
      name: '可乐',
      createdAt: t,
      updatedAt: t,
    );
    final Product b = Product(
      id: newId(),
      code: 'P0002',
      name: '薯片',
      createdAt: t,
      updatedAt: t,
    );
    ProductDao(db).insert(a);
    ProductDao(db).insert(b);
    p1 = a.id;
    p2 = b.id;
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  /// 预置库存：先用服务录一次（「再次进入」场景）
  void seedBook(Map<String, int> qty) {
    service.create(
      StocktakeDraft(
        lines: <StocktakeLineDraft>[
          for (final MapEntry<String, int> e in qty.entries)
            StocktakeLineDraft(
              productId: e.key,
              productName: e.key == p1 ? '可乐' : '薯片',
              quantity: '${e.value}',
            ),
        ],
      ),
      now: t,
    );
  }

  Widget page({
    required bool isFirstTime,
    Map<String, int>? book,
    required void Function() onDone,
    DocumentSink? documentSink,
  }) => MaterialApp(
    home: Scaffold(
      body: OpeningStockPage(
        service: service,
        productService: products,
        masterDataSink: ServiceMasterSink(products),
        isFirstTime: isFirstTime,
        bookQuantities: book ?? const <String, int>{},
        documentSink: documentSink,
        onDone: onDone,
      ),
    ),
  );

  /// 走到「填完一行商品 + 数量」的状态
  Future<void> fillRow(
    WidgetTester tester, {
    required int row,
    required String productName,
    required String qty,
  }) async {
    await tester.tap(find.byKey(Key('opening-product-$row')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(productName).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(Key('opening-qty-$row')), qty);
    await tester.pumpAndSettle();
  }

  testWidgets('空表单点「记入库存」→ 顶部报「至少要填一行」，页面不关', (WidgetTester tester) async {
    bool done = false;
    await tester.pumpWidget(page(isFirstTime: true, onDone: () => done = true));

    await tester.tap(find.byKey(const Key('opening-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('至少要填一行'), findsOneWidget);
    expect(done, isFalse, reason: '拦截后留在本页改');
  });

  testWidgets('选商品 + 填数量 → 行内显示账面数与差额（建议 1）', (WidgetTester tester) async {
    seedBook(<String, int>{p1: 10});
    await tester.pumpWidget(
      page(isFirstTime: false, book: queries.stockByProduct(), onDone: () {}),
    );

    await fillRow(tester, row: 0, productName: '可乐', qty: '3');
    expect(find.textContaining('当前账面 10'), findsOneWidget);
    expect(find.textContaining('将减少 7'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('opening-qty-0')), '15');
    await tester.pumpAndSettle();
    expect(find.textContaining('将增加 5'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('opening-qty-0')), '10');
    await tester.pumpAndSettle();
    expect(find.textContaining('无变化'), findsOneWidget);
  });

  testWidgets('确认弹窗：摘要 + 用户语言（AD-5）；确认后 SnackBar + 返回', (
    WidgetTester tester,
  ) async {
    bool done = false;
    await tester.pumpWidget(page(isFirstTime: true, onDone: () => done = true));

    await fillRow(tester, row: 0, productName: '可乐', qty: '10');
    await tester.tap(find.byKey(const Key('opening-add-row')));
    await tester.pumpAndSettle();
    await fillRow(tester, row: 1, productName: '薯片', qty: '5');
    await tester.tap(find.byKey(const Key('opening-save')));
    await tester.pumpAndSettle();

    // 弹窗摘要给用户最后核对的机会；「不能取消」不说「不可撤销」
    expect(find.textContaining('即将记录 2 件商品'), findsOneWidget);
    expect(find.textContaining('记下之后不能取消'), findsOneWidget);
    await tester.tap(find.byKey(const Key('opening-confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已录入 2 件商品'), findsOneWidget);
    expect(done, isTrue, reason: '成功后回库存页（数字立刻可见）');
    expect(queries.stockByProduct(), <String, int>{p1: 10, p2: 5});
  });

  testWidgets('原样重录 → SnackBar 诚实反馈「都无变化」（建议 2）', (WidgetTester tester) async {
    seedBook(<String, int>{p1: 10});
    await tester.pumpWidget(
      page(isFirstTime: false, book: queries.stockByProduct(), onDone: () {}),
    );

    await fillRow(tester, row: 0, productName: '可乐', qty: '10');
    await tester.tap(find.byKey(const Key('opening-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('opening-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('都无变化'),
      findsOneWidget,
      reason: '不能假装「已录入」让用户以为改了什么',
    );
  });

  testWidgets('同商品两行 → 提交时行级「已经在上面」（AD-3），页面不关', (WidgetTester tester) async {
    bool done = false;
    await tester.pumpWidget(page(isFirstTime: true, onDone: () => done = true));

    await fillRow(tester, row: 0, productName: '可乐', qty: '10');
    await tester.tap(find.byKey(const Key('opening-add-row')));
    await tester.pumpAndSettle();
    await fillRow(tester, row: 1, productName: '可乐', qty: '20');
    await tester.tap(find.byKey(const Key('opening-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已经在上面'), findsOneWidget);
    expect(done, isFalse);
    // 已填内容必须还在（遗漏 4：状态保留）
    expect(find.text('可乐'), findsWidgets);
  });

  testWidgets('取消：有内容先确认「放弃这次录入吗」→ 放弃后返回', (WidgetTester tester) async {
    bool done = false;
    await tester.pumpWidget(page(isFirstTime: true, onDone: () => done = true));

    await fillRow(tester, row: 0, productName: '可乐', qty: '10');
    await tester.tap(find.byKey(const Key('opening-cancel')));
    await tester.pumpAndSettle();

    expect(find.textContaining('放弃这次录入吗'), findsOneWidget);
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();
    expect(done, isTrue);
  });

  testWidgets('选择器：空查询显示「全部商品」而不是「最近使用」（AD-2 差异）', (WidgetTester tester) async {
    await tester.pumpWidget(page(isFirstTime: true, onDone: () {}));

    await tester.tap(find.byKey(const Key('opening-product-0')));
    await tester.pumpAndSettle();

    expect(find.text('全部商品'), findsOneWidget, reason: '首次录入没有「最近」，空查询直接给全集');
    expect(find.text('可乐'), findsOneWidget);
    expect(find.text('薯片'), findsOneWidget);
  });

  // ------------------------------------------------------------ 真实用户 P0（2026-11-17）
  //
  // 现场日志：`Bad state: 这个出口没有装配盘点服务（ServiceSink.stocktakes）`
  // ← `opening_stock_page.dart:240`。桌面壳把**没装盘点服务**的 `ServiceSink`
  // 传进了期初页，老写法只看「sink 非空」就走它 ⇒ 抛异常 ⇒ **数量一条没落库**，
  // 用户再点一次还是 0（「重新清点后库存仍为 0」）。
  group('提交出口：按能力分支（P0 回归）', () {
    testWidgets('出口装不了盘点 ⇒ 退回直连服务，数量真的进库存', (WidgetTester tester) async {
      final ServiceSink sink = ServiceSink(
        sales: SaleService(engine: RuleEngine(db), queries: queries),
        purchases: PurchaseService(engine: RuleEngine(db), queries: queries),
        deliveries: DeliveryService(engine: RuleEngine(db), queries: queries),
        // ⚠️ 故意不传 stocktakes —— 桌面壳（`app.dart`）就是这么装配的
      );
      expect(
        sink.canSubmitStocktake,
        isFalse,
        reason: '没装 StocktakeService 就不该声称能提交盘点单',
      );

      bool done = false;
      await tester.pumpWidget(
        page(
          isFirstTime: true,
          documentSink: sink,
          onDone: () => done = true,
        ),
      );
      await fillRow(tester, row: 0, productName: '可乐', qty: '7');
      await tester.tap(find.byKey(const Key('opening-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opening-confirm')));
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: '真机那条 `Bad state` 不许再出现（它会变成「未捕获异常」）',
      );
      expect(done, isTrue, reason: '成功就该回宿主刷数字');
      expect(
        queries.stockByProduct()[p1],
        7,
        reason: 'P0 的本质 —— 填的数量必须落在库存上，否则用户看到的是 0',
      );
    });

    testWidgets('出口直落（isQueued=false、error=null）算成功，不许报「没能记上」', (
      WidgetTester tester,
    ) async {
      final _ScriptedSink sink = _ScriptedSink(
        const DocumentSubmitResult(
          finalDocNo: 'ST-1',
          isQueued: false,
          totalCents: 0,
        ),
      );

      bool done = false;
      await tester.pumpWidget(
        page(
          isFirstTime: true,
          documentSink: sink,
          onDone: () => done = true,
        ),
      );
      await fillRow(tester, row: 0, productName: '可乐', qty: '3');
      await tester.tap(find.byKey(const Key('opening-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opening-confirm')));
      await tester.pumpAndSettle();

      expect(sink.calls, 1, reason: '能装的出口就该走它（手机队列是这条路）');
      expect(
        done,
        isTrue,
        reason: '老写法把 isQueued==false 当失败 ⇒ 明明记上了却说没记上，用户会再录一遍',
      );
      expect(find.text('已记入库存：1 件商品'), findsOneWidget);
    });
  });
}

/// 只实现盘点提交的**假出口**（其余方法在本文件不会被调用）。
class _ScriptedSink implements DocumentSink {
  _ScriptedSink(this.result);

  final DocumentSubmitResult result;
  int calls = 0;

  @override
  bool get canCreateProducts => true;

  @override
  bool get canSubmitStocktake => true;

  @override
  DocumentSubmitResult submitSale(SaleDraft draft, {int? now}) =>
      throw UnimplementedError();

  @override
  DocumentSubmitResult submitPurchase(PurchaseDraft draft, {int? now}) =>
      throw UnimplementedError();

  @override
  DocumentSubmitResult submitDelivery(DeliveryDraft draft, {int? now}) =>
      throw UnimplementedError();

  @override
  DocumentSubmitResult submitStocktake(StocktakeDraft draft, {int? now}) {
    calls++;
    return result;
  }
}
