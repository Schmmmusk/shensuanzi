// 缺货榜卡片（`LowStockCard`）的摆放与文案。
//
// 断言的都是**用户能读到的字**与**必须存在的结构**（Key），不测像素：
// - 决策 4 乙的引导卡是「普通提示」而不是警告；
// - 金额区的三态（正常 / 单价未填 / 缺口 0）都不能假装成别的东西；
// - #16 的文案红线：整张卡**不许**出现「成本」「约合」——
//   `cost_price` 只是参考进价，写成「成本」会让用户以为是真实进价。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/low_stock_card.dart';
import 'package:shensuanzi/src/ui/shortage.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

Product product(
  String id, {
  String? name,
  int safety = 0,
  int cost = 0,
  String unit = '件',
}) => Product(
  id: id,
  code: 'C-$id',
  name: name ?? '商品$id',
  unit: unit,
  costPrice: cost,
  safetyStock: safety,
  createdAt: 0,
  updatedAt: 0,
);

StockAgg stock(int quantity, {bool inbound = true}) =>
    StockAgg(quantity: quantity, cost: 0, hasInbound: inbound);

ShortageSummary summaryOf(
  List<Product> products,
  Map<String, StockAgg> agg, {
  int limit = 10,
}) => computeShortage(
  products: products,
  agg: agg,
  inTransit: const <String, int>{},
  limit: limit,
);

Widget host(ShortageSummary summary, {VoidCallback? onOpenAll}) => MaterialApp(
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: LowStockCard(summary: summary, onOpenAll: onOpenAll),
    ),
  ),
);

/// 卡片里所有可见文字（判断文案红线用）。
List<String> textsOf(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((Text t) => t.data ?? '')
    .where((String s) => s.isNotEmpty)
    .toList();

void main() {
  testWidgets('全店没设安全库存 ⇒ 普通提示卡（引导去哪设）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        summaryOf(<Product>[product('a')], <String, StockAgg>{'a': stock(3)}),
      ),
    );

    expect(find.byKey(const Key('low-stock-guide')), findsOneWidget);
    expect(find.text('还没有设置安全库存'), findsOneWidget);
    expect(find.textContaining('商品 → 编辑 → 安全库存'), findsOneWidget);
    // 引导卡不是「报表」：不该出现榜单标题或空态那句话
    expect(find.byKey(const Key('low-stock-none')), findsNothing);
  });

  testWidgets('超卖段在「该补货」段之上，且两段的量都写出来', (WidgetTester tester) async {
    final ShortageSummary s = summaryOf(
      <Product>[
        product('bad', name: '红富士苹果', safety: 5, cost: 1000),
        product('ok', name: '大米', safety: 50, cost: 300),
      ],
      <String, StockAgg>{'bad': stock(-3), 'ok': stock(10)},
    );
    await tester.pumpWidget(host(s));

    expect(find.byKey(const Key('low-stock-oversold-header')), findsOneWidget);
    expect(find.byKey(const Key('low-stock-restock-header')), findsOneWidget);
    // 超卖行：在店可售 −3 与「补 8 件」同时出现（两个数不混用）
    expect(find.byKey(const Key('low-stock-oversold-bad')), findsOneWidget);
    expect(find.textContaining('在店可售 -3 件'), findsOneWidget);
    expect(find.textContaining('补 8 件'), findsOneWidget);
    expect(find.textContaining('预计补货 ¥80.00'), findsOneWidget);
    // 该补货行：缺 40 件
    expect(find.byKey(const Key('low-stock-restock-ok')), findsOneWidget);
    expect(find.textContaining('缺 40 件'), findsOneWidget);

    // 顺序：超卖段在补货段**上面**
    final double oversoldY = tester
        .getTopLeft(find.byKey(const Key('low-stock-oversold-header')))
        .dy;
    final double restockY = tester
        .getTopLeft(find.byKey(const Key('low-stock-restock-header')))
        .dy;
    expect(oversoldY < restockY, isTrue);
  });

  testWidgets('#16 文案红线：写「预计补货金额」，不写「成本」「约合」', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        summaryOf(
          <Product>[product('a', name: '大米', safety: 10, cost: 300)],
          <String, StockAgg>{'a': stock(4)},
        ),
      ),
    );

    final List<String> texts = textsOf(tester);
    expect(
      texts.any((String t) => t.contains('按商品档案中的参考进价估算')),
      isTrue,
      reason: '必须说清金额的来源',
    );
    expect(texts.any((String t) => t.contains('实际采购金额以供应商报价为准')), isTrue);
    for (final String text in texts) {
      expect(text.contains('成本'), isFalse, reason: '「成本」是压货榜的口径：$text');
      expect(text.contains('约合'), isFalse, reason: '「约合」像已经询过价：$text');
    }
  });

  testWidgets('单价没填 ⇒ 写「单价未填」，不出现 ¥0', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        summaryOf(
          <Product>[product('a', safety: 10)],
          <String, StockAgg>{'a': stock(0)},
        ),
      ),
    );

    expect(find.text('单价未填'), findsOneWidget);
    expect(find.byKey(const Key('low-stock-price-unset')), findsOneWidget);
    for (final String text in textsOf(tester)) {
      expect(text.contains('¥0'), isFalse, reason: '会让人以为补货不要钱：$text');
    }
  });

  testWidgets('缺口为 0（刚好到安全库存）⇒ 写「刚好到安全库存」，不写 ¥0', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        summaryOf(
          <Product>[product('a', safety: 5, cost: 100)],
          <String, StockAgg>{'a': stock(5)},
        ),
      ),
    );

    expect(find.text('刚好到安全库存'), findsOneWidget);
    for (final String text in textsOf(tester)) {
      expect(text.contains('¥0'), isFalse, reason: text);
    }
  });

  testWidgets('全都不缺 ⇒ 出「没有要补的货」（不是空白，也不是引导卡）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        summaryOf(
          <Product>[product('a', safety: 5)],
          <String, StockAgg>{'a': stock(100)},
        ),
      ),
    );

    expect(find.byKey(const Key('low-stock-none')), findsOneWidget);
    expect(find.byKey(const Key('low-stock-guide')), findsNothing);
  });

  testWidgets('「查看全部 N 个」用真数，点了回调', (WidgetTester tester) async {
    bool opened = false;
    final ShortageSummary s = summaryOf(
      <Product>[
        for (int i = 0; i < 6; i++) product('p$i', safety: 10, cost: 100),
      ],
      <String, StockAgg>{for (int i = 0; i < 6; i++) 'p$i': stock(0)},
      limit: 3,
    );
    await tester.pumpWidget(host(s, onOpenAll: () => opened = true));

    expect(find.text('查看全部 6 个'), findsOneWidget);
    await tester.tap(find.byKey(const Key('low-stock-open-all')));
    await tester.pump();
    expect(opened, isTrue);
  });

  testWidgets('没有商品 ⇒ 整卡不渲染', (WidgetTester tester) async {
    await tester.pumpWidget(host(summaryOf(<Product>[], <String, StockAgg>{})));
    expect(find.byKey(const Key('low-stock-card')), findsNothing);
  });
}
