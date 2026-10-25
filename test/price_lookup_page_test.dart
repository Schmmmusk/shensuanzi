// 查价页（真实诉求批 ③，2026-10-24，§CV·一百零四）。
//
// 钉四件事：
// ① 输入名字 → 防抖后出**大卡**（售价 + 库存）；
// ② **扫码回车打断防抖**：条码命中要立刻出卡，不等 300 ms（审查意见 §二-4）；
// ③ 没找到要说出来（不能一片空白）；
// ④ 库存 ≤ 0 ⇒ 「缺货」/「超卖」标记（顾客问「还有吗」时这就是答案）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/price_lookup_page.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Db db;
  late ProductService products;
  late String milkId;

  setUp(() {
    db = Db.openInMemory();
    products = ProductService(db);
    final int t = DateTime.now().millisecondsSinceEpoch;
    Product add(String code, String name, int sellPrice, {String? barcode}) {
      final Product p = Product(
        id: newId(),
        code: code,
        name: name,
        sellPrice: sellPrice,
        barcode: barcode,
        createdAt: t,
        updatedAt: t,
      );
      ProductDao(db).insert(p);
      return p;
    }

    milkId = add('P001', '蒙牛纯牛奶 500ml', 500, barcode: '6901234567890').id;
    add('P002', '伊利纯牛奶 250ml', 350);
    add('P003', '蒙牛酸奶', 400);
  });

  tearDown(() => db.close());

  Widget page({Map<String, int>? stock}) => MaterialApp(
    home: PriceLookupPage(
      products: products,
      stockSnapshot: () => stock ?? <String, int>{milkId: 36},
    ),
  );

  /// 输入 + 等过防抖
  Future<void> typeAndWait(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('price-lookup-input')), text);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  testWidgets('输入名字 ⇒ 唯一命中出大卡：售价 + 库存', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await typeAndWait(tester, '蒙牛纯牛奶');

    expect(find.byKey(const Key('price-lookup-card')), findsOneWidget);
    expect(find.text('¥ 5.00'), findsOneWidget, reason: '③ 大字售价');
    expect(
      find.byKey(const Key('price-lookup-stock')),
      findsOneWidget,
      reason: '③ 小字库存',
    );
    expect(find.textContaining('36'), findsOneWidget);
    expect(
      find.byKey(const Key('price-lookup-out-of-stock')),
      findsNothing,
      reason: '有货就不该报缺货',
    );
  });

  testWidgets('扫码回车 ⇒ **立刻**出大卡，不等 300 ms 防抖', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.enterText(
      find.byKey(const Key('price-lookup-input')),
      '6901234567890',
    );
    // 回车 = 扫码枪结束符
    await tester.testTextInput.receiveAction(TextInputAction.search);
    // ⚠️ 只 pump 一帧：防抖定时器（300 ms）**还没到**
    await tester.pump();

    expect(
      find.byKey(const Key('price-lookup-card')),
      findsOneWidget,
      reason: '③ 扫码命中必须打断防抖（等 300 ms 会让人觉得卡）',
    );
    expect(find.text('¥ 5.00'), findsOneWidget);
  });

  testWidgets('没找到 ⇒ 说「没找到」，不是一片空白', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await typeAndWait(tester, '不存在的商品');

    expect(find.byKey(const Key('price-lookup-not-found')), findsOneWidget);
    expect(find.byKey(const Key('price-lookup-card')), findsNothing);
  });

  // ⚠️ 这两条**必须分开**：`pumpWidget` 同类型同 key 会**复用 State**，
  // 而库存是 `late final`（进页读一次）—— 第二次 pump 不会重读，测出来是旧库存。
  testWidgets('库存 0 ⇒ 标「缺货」', (WidgetTester tester) async {
    await tester.pumpWidget(page(stock: <String, int>{milkId: 0}));
    await typeAndWait(tester, '蒙牛纯牛奶');
    expect(find.text('缺货'), findsOneWidget);
  });

  testWidgets('负库存 ⇒ 标「超卖」', (WidgetTester tester) async {
    await tester.pumpWidget(page(stock: <String, int>{milkId: -2}));
    await typeAndWait(tester, '蒙牛纯牛奶');
    expect(find.text('超卖'), findsOneWidget);
  });

  testWidgets('多个命中 ⇒ 列表；点一个才出大卡', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await typeAndWait(tester, '纯牛奶');

    expect(
      find.byKey(const Key('price-lookup-card')),
      findsNothing,
      reason: '命中多个时不猜，先列出来',
    );
    expect(find.textContaining('找到 2 个'), findsOneWidget);

    await tester.tap(find.byKey(Key('price-lookup-row-$milkId')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('price-lookup-card')), findsOneWidget);
  });
}
