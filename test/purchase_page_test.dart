// 采购开单页（`PurchasePage`）的 widget 测试。
//
// 沿用启动流程的两个注入经验，但这里更简单：直接挂 `PurchasePage`，
// `PurchaseService` / `ProductService` 都指向**沙箱里的临时库** ——
// 走真实路径（真实建库、真实开单），测出来的才是真的。
//
// ⚠️ 必须 `useLocalSqlite()`：`flutter test` 不打包 `sqlite3.dll`（§N）。
//
// 运行：`flutter test`（本机由用户执行）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/purchase_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late PurchaseService service;
  late ProductService products;
  // B3b：页面提交改吃 Sink —— 桌面语义 = ServiceSink（与直连逐字同行为）
  late DocumentSink sink;
  late String productId;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_purchase_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    service = PurchaseService(engine: RuleEngine(db), queries: QueryDao(db));
    products = ProductService(db);
    sink = ServiceSink(
      sales: SaleService(engine: RuleEngine(db), queries: QueryDao(db)),
      purchases: service,
      deliveries: DeliveryService(engine: RuleEngine(db), queries: QueryDao(db)),
    );

    final Product product = Product(
      id: newId(),
      code: 'P0001',
      name: '红富士苹果',
      costPrice: 350,
      createdAt: 1,
      updatedAt: 1,
    );
    ProductDao(db).insert(product);
    productId = product.id;

    final Account account = Account(
      id: newId(),
      name: '现金',
      type: AccountType.cash,
      createdAt: 1,
      updatedAt: 1,
    );
    AccountDao(db).insert(account);

    final Party party = Party(
      id: newId(),
      name: '王老板',
      roles: const <PartyRole>[PartyRole.supplier],
      createdAt: 1,
      updatedAt: 1,
    );
    PartyDao(db).insert(party);
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  Widget page() => MaterialApp(
    home: Scaffold(
      body: PurchasePage(
        service: service,
        productService: products,
        sink: sink,
        masterDataPolicy: const MasterDataPolicy.desktop(),
        masterDataSink: ServiceMasterSink(products),
      ),
    ),
  );

  /// 选中第一行的商品。
  ///
  /// ⚠️ 两个坑（都是真踩过的）：
  /// ① 商品选择器**空查询显示的是「最近采购」**，首次使用时为空 ——
  ///    所以要先在搜索框输入商品名，让列表出现，再点选；
  /// ② **不能 `find.byType(TextField).first` 找搜索框** —— 弹层底下
  ///    还压着页面的 4 个输入框，树的先序遍历先碰到它们。搜索框一律用 Key。
  Future<void> pickFirstProduct(WidgetTester tester) async {
    await tester.tap(find.text('点此选商品'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('picker-search')), '红富士');
    await tester.pumpAndSettle();
    await tester.tap(find.text('红富士苹果').first);
    await tester.pumpAndSettle();
  }

  Future<void> fillRow(WidgetTester tester, {String qty = '10'}) async {
    await pickFirstProduct(tester);
    // 单价已预填进价 3.50 —— 不动它
    await tester.enterText(find.byKey(const Key('purchase-qty')), qty);
    await tester.pumpAndSettle();
  }

  /// 点底部按钮（保存 / 取消）。
  ///
  /// ⚠️ 测试视口是 800×600，而页面内容（表头 + 明细 + 合计 + 付款 + 操作区）
  /// 超过一屏 —— 直接 `tap` 会得到「offset 在渲染树之外」的 miss。
  /// 先滚到可见再点（真机上窗口小了同样要滚，语义一致）。
  Future<void> tapFinder(WidgetTester tester, Finder button) async {
    await tester.scrollUntilVisible(
      button,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  /// 按**文案**点底部按钮。⚠️ 保存按钮的文案会随「有没有找回」变（§AY·四）
  /// ⇒ 涉及找回的用例请用 [tapFinder] + `Key('purchase-save')`（按 Key 找）。
  Future<void> tapBottomButton(WidgetTester tester, String label) =>
      tapFinder(tester, find.text(label));

  testWidgets('空表单点保存 → 行级报「请选一个商品」等（不是整单级）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tapBottomButton(tester, '保存 (Ctrl+S)');
    await tester.pumpAndSettle();

    // 空行**照常报行级错误**（加了一行就得填或删），没有整单级「至少要有一行」
    expect(find.textContaining('请选一个商品'), findsOneWidget);
    expect(find.textContaining('请填数量'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('散采全款 → 保存成功，SnackBar 报单号与已结清', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester);
    await tester.tap(find.text('全款'));
    await tester.pumpAndSettle();
    await tapBottomButton(tester, '保存 (Ctrl+S)');
    await tester.pumpAndSettle();

    expect(find.textContaining('已保存'), findsOneWidget);
    expect(find.textContaining('已结清'), findsOneWidget);
    // 库存真的进来了
    expect(StockLedgerDao(db).stockOf(productId), 10);
  });

  testWidgets('散采欠款 → 报「散采要当场结清」', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester); // 不点全款 → 全赊
    await tapBottomButton(tester, '保存 (Ctrl+S)');
    await tester.pumpAndSettle();

    expect(find.textContaining('散采要当场结清'), findsOneWidget);
  });

  testWidgets('选供应商 + 部分付款 → SnackBar 带累计欠款', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 选供应商
    await tester.tap(find.text('散采（不记往来）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('王老板').first);
    await tester.pumpAndSettle();

    await fillRow(tester);
    await tester.enterText(
      find.byKey(const Key('purchase-pay-amount')),
      '10',
    );
    await tapBottomButton(tester, '保存 (Ctrl+S)');
    await tester.pumpAndSettle();

    expect(find.textContaining('已保存'), findsOneWidget);
    expect(find.textContaining('王老板 累计欠款'), findsOneWidget);
  });

  testWidgets('取消：有内容 → 先确认，确认后表单清空（保留不动）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester);
    await tapBottomButton(tester, '取消 (Esc)');
    await tester.pumpAndSettle();

    // 确认对话框出现
    expect(find.text('放弃这次开单？'), findsOneWidget);
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();

    // 表单清空：回到「点此选商品」
    expect(find.text('点此选商品'), findsOneWidget);
    expect(find.text('放弃这次开单？'), findsNothing);
  });

  testWidgets('供应商选择器：打字过滤不崩（定长列表 removeWhere 回归）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.text('散采（不记往来）'));
    await tester.pumpAndSettle();

    // 曾在这里逐字崩：`activeSuppliers()..removeWhere(...)` 打在 sqlite3
    // 返回的**定长列表**上 → `Cannot remove from a fixed-length list`（真机实测）
    await tester.enterText(find.byKey(const Key('picker-search')), '王');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('王老板'), findsOneWidget);

    // 过滤到空 → 空列表，同样不崩
    await tester.enterText(find.byKey(const Key('picker-search')), '不存在');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('王老板'), findsNothing);
  });

  // ------------------------------------------------- §AY·四 多付（找回）

  testWidgets('多付：内联告知 + 按钮说清记多少；落库只记应付', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await fillRow(tester); // 10 × 3.50 = 35.00
    await tester.tap(find.text('全款'));
    await tester.pumpAndSettle();
    // 把付款金额改成 50（> 应付 35）—— 旧行为是报「超过了本单合计」并拦住
    await tester.enterText(find.byKey(const Key('purchase-pay-amount')), '50');
    await tester.pumpAndSettle();

    expect(
      find.textContaining('实付 ¥50.00，其中 ¥35.00 入账、找零 ¥15.00'),
      findsOneWidget,
      reason: '§AY·四：橙色内联告知（采购用「实付」）',
    );
    expect(find.textContaining('超过了本单合计'), findsNothing, reason: '旧文案已废止');
    expect(
      find.textContaining('记 ¥35.00 并找零 ¥15.00'),
      findsOneWidget,
      reason: '按钮文字是用户动作的最终确认',
    );

    await tapFinder(tester, find.byKey(const Key('purchase-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已保存'), findsOneWidget);
    expect(
      find.textContaining('记账 ¥35.00（找零 ¥15.00）'),
      findsOneWidget,
      reason: '第二处告知：保存后再说一次记了多少',
    );
    // 库存进来了、成本按应付算（找回不影响成本口径）
    expect(StockLedgerDao(db).stockOf(productId), 10);
    final int cost = db.raw
        .select('SELECT total_cost FROM stock_ledger WHERE product_id = ?',
            <Object?>[productId])
        .first
        .values
        .first! as int;
    expect(cost, 3500, reason: '入库成本 = 应付 35.00，不是付出的 50.00');
    // 资金流水只出 3500
    final int cashOut = db.raw
        .select('SELECT COALESCE(SUM(amount), 0) AS s FROM money_ledger '
            'WHERE amount < 0')
        .first['s']! as int;
    expect(cashOut, -3500, reason: '出账 35.00（找回的 15.00 没进出）');
  });

  // ---- §BG 方案 A：切单位 ⇒ 未被手改的预填价跟着换算（三页同构，各钉各的 Key）----

  testWidgets('§BG 方案A：切到「箱」⇒ 预填价 ×12、单价标注单位、显示换算说明', (WidgetTester tester) async {
    final Product milk = Product(
      id: newId(),
      code: 'P0002',
      name: '蒙牛纯牛奶',
      unit: '瓶',
      costPrice: 250,
      packageUnit: '箱',
      packageSize: 12,
      createdAt: 2,
      updatedAt: 2,
    );
    ProductDao(db).insert(milk);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 选牛奶（⚠️ 结果行按 ListTile 找 —— 搜索框里的字也会被 find.text 命中）
    await tester.tap(find.text('点此选商品'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('picker-search')), '蒙牛');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '蒙牛纯牛奶'));
    await tester.pumpAndSettle();

    TextField priceField() => tester.widget<TextField>(
      find.byKey(const Key('purchase-price')),
    );
    // 预填 = 瓶价 2.50，label 标注最小单位
    expect(priceField().controller!.text, '2.50');
    expect(find.text('单价（元/瓶）'), findsOneWidget);

    // 切到「箱」⇒ 预填价 ×12 = 30.00（§BG 方案 A 的核心断言：
    // 否则瓶价被当成箱价 —— 真机踩过 1 箱 × ¥2.50 = ¥2.50）
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, '箱'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '箱'));
    await tester.pumpAndSettle();
    expect(priceField().controller!.text, '30.00');
    expect(find.text('单价（元/箱）'), findsOneWidget);
    expect(find.text('1 箱 = 12 瓶，入库按 12 瓶记。'), findsOneWidget);

    // 切回「瓶」⇒ ÷12 还原；换算说明消失（只在切到包装时显示，裁定 ③）
    await tester.tap(find.widgetWithText(ChoiceChip, '瓶'));
    await tester.pumpAndSettle();
    expect(priceField().controller!.text, '2.50');
    expect(find.text('单价（元/瓶）'), findsOneWidget);
    expect(find.text('1 箱 = 12 瓶，入库按 12 瓶记。'), findsNothing);
  });

  // ---- #25（§CV·二五 裁定「甲」）：同一行内换商品 ⇒ 单价必须**重新预填** ----
  //
  // 病根（已裁）：守卫用了 `pricePrefilled` —— 它一旦置 true **永不复位**，
  // 而它想表达的是 `priceTouched`（用户**是否手改过**）。见 §CV·二四·一 修复提案。
  // ⚠️ 第 ② 步在修复前**必红** —— 这就是本用例的反向灵敏度。
  testWidgets('#25 换商品 ⇒ 单价重填（含重选）；手改不阻挡覆盖；取消不覆盖', (WidgetTester tester) async {
    // 第二个商品：价必须与红富士（进价 3.50）不同，否则断言分辨不出来
    ProductDao(db).insert(Product(
      id: newId(),
      code: 'P0009',
      name: '黄金梨',
      costPrice: 1250,
      createdAt: 9,
      updatedAt: 9,
    ));

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    TextField priceField() => tester.widget<TextField>(
      find.byKey(const Key('purchase-price')),
    );
    TextField qtyField() => tester.widget<TextField>(
      find.byKey(const Key('purchase-qty')),
    );

    /// 打开选择器并选中 [name]。
    /// [opener] = 行内当前可点的文案：还没选过是「点此选商品」，选过是**上一个商品名**。
    Future<void> pick(String opener, String keyword, String name) async {
      await tester.tap(find.text(opener));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('picker-search')), keyword);
      await tester.pumpAndSettle();
      // ⚠️ 结果行一律用 `widgetWithText(ListTile, …)`：`find.text` 连搜索框的
      //    `EditableText` 一起匹配（送货页的 `pickCustomer` 注释里有真实教训）
      await tester.tap(find.widgetWithText(ListTile, name));
      await tester.pumpAndSettle();
    }

    // ① 选 A（红富士苹果 进价 3.50）⇒ 预填
    await pick('点此选商品', '红富士', '红富士苹果');
    expect(priceField().controller!.text, '3.50');

    // ② 同一行改选 B（黄金梨 进价 12.50）⇒ 【修复前必红】
    await pick('红富士苹果', '黄金梨', '黄金梨');
    expect(
      priceField().controller!.text,
      '12.50',
      reason: '换商品必须重填新商品的价 —— 旧价对新商品没有意义（#25）',
    );

    // ③ 再选回 A ⇒ 「重选同一商品」也要回到该商品的初始态
    await pick('黄金梨', '红富士', '红富士苹果');
    expect(priceField().controller!.text, '3.50');

    // ④ **手改过**也不阻挡覆盖（覆盖的是旧商品的价，不是用户的意愿）
    await tester.enterText(find.byKey(const Key('purchase-price')), '9.99');
    await tester.pumpAndSettle();
    expect(priceField().controller!.text, '9.99');
    await pick('红富士苹果', '黄金梨', '黄金梨');
    expect(priceField().controller!.text, '12.50', reason: '手改不阻挡覆盖');

    // ⑤ 换商品**不碰数量**（锁定「不改」的边界 —— 修复时最容易顺手把数量也清了）
    await tester.enterText(find.byKey(const Key('purchase-qty')), '7');
    await tester.pumpAndSettle();
    await pick('黄金梨', '红富士', '红富士苹果');
    expect(
      qtyField().controller!.text,
      '7',
      reason: '换商品只重置价与单位；数量是用户的输入',
    );

    // ⑥ 打开选择器后**取消** ⇒ 不覆盖（`picked == null` 的对称边界）
    final String before = priceField().controller!.text;
    await tester.tap(find.text('红富士苹果'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byKey(const Key('picker-search')))).pop();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('picker-search')),
      findsNothing,
      reason: '前提断言：选择器真的关掉了（否则下面那条会空过）',
    );
    expect(priceField().controller!.text, before, reason: '取消选择 ⇒ 不覆盖');
  });
}
