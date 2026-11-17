// 商品名补全 × 中文输入法（2026-11-17 真实用户 P1 回归）。
//
// ## 真机现象
//
// 「初次输入商品名时不弹出补全，删去部分字符后才弹出。」
//
// 根因：`optionsBuilder` 里有一条 `if (value.composing.isValid) return [];`
// （依据是 2026-10-25 那条「拼音未上屏时触发**全表搜索**会把输入法搞崩」的裁定）。
// 但本组件**不查库**（进页取一次、内存里筛），而 Windows 输入法会把整段输入
// 长期标成「组合中」⇒ 候选永远为空，只有删字符（产生一次非组合编辑）才恢复。
//
// 这里用 `tester.testTextInput.updateEditingValue` 直接喂一个「文本已上屏但
// composing 仍有效」的值 —— 正是真机上那个形态。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shensuanzi/src/ui/product_name_autocomplete.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

Product _cola() => Product(
  id: 'id-P0001',
  code: 'P0001',
  name: '可口可乐',
  costPrice: 1000,
  sellPrice: 1500,
  createdAt: 1700000000000,
  updatedAt: 1700000000000,
);

void main() {
  Widget host({
    required TextEditingController controller,
    required FocusNode focusNode,
    required List<Product> products,
  }) => MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: ProductNameAutocomplete(
          fieldKey: const Key('f'),
          controller: controller,
          focusNode: focusNode,
          enabled: true,
          products: products,
          forPurchase: false,
          onPicked: (Product product, {required String typedBefore}) {},
          onChangedText: (String text) {},
          onPickPressed: () {},
        ),
      ),
    ),
  );

  testWidgets('组合期（composing 有效）也要出候选 —— 否则首次输入永远不弹', (
    WidgetTester tester,
  ) async {
    final TextEditingController controller = TextEditingController();
    final FocusNode focusNode = FocusNode();
    addTearDown(() {
      controller.dispose();
      focusNode.dispose();
    });

    await tester.pumpWidget(
      host(
        controller: controller,
        focusNode: focusNode,
        products: <Product>[_cola()],
      ),
    );
    await tester.tap(find.byKey(const Key('f')));
    await tester.pumpAndSettle();

    // 真机形态：字已经上屏（text 有「可口可乐」），但输入法仍把整段标成组合中
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '可口可乐',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('product-option-id-P0001')),
      findsOneWidget,
      reason: '老写法（composing 有效 ⇒ 返回空）会让这条红 —— 真机就是"第一次输入没候选"',
    );
  });

  testWidgets('组合期输入拼音（对不上任何商品）⇒ 不出候选，也不许崩', (
    WidgetTester tester,
  ) async {
    final TextEditingController controller = TextEditingController();
    final FocusNode focusNode = FocusNode();
    addTearDown(() {
      controller.dispose();
      focusNode.dispose();
    });

    await tester.pumpWidget(
      host(
        controller: controller,
        focusNode: focusNode,
        products: <Product>[_cola()],
      ),
    );
    await tester.tap(find.byKey(const Key('f')));
    await tester.pumpAndSettle();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'kekoukele',
        selection: TextSelection.collapsed(offset: 9),
        composing: TextRange(start: 0, end: 9),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('product-option-id-P0001')),
      findsNothing,
      reason: '拼音对不上中文名 —— 结果本来就是空，不会"糊一屏"',
    );
  });
}
