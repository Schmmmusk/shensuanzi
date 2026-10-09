// 送货开单页（`DeliveryPage`）的 widget 测试 —— §AZ·五 的欠账（§BB 审查意见 · 四）。
//
// 与 `purchase_page_test.dart` / `sale_page_test.dart` **同构**，但只钉**送货特有**的三件事：
//
// | # | 断言的差异 | 为什么它值得单测 |
// |---|---|---|
// | 1 | **客户必选**（没有「散客」这一档） | 送货单本身就是赊销 —— 没客户就没有人挂这笔欠款 |
// | 2 | 保存后单据**必定是「待签收」** | 状态由 RULE-003 强制，UI 不该猜 |
// | 3 | **不需要资金账户** | 与采购/销售相反（那两页没账户就存不了）—— 送货不碰钱 |
//
// ⚠️ 测试视口 800×600，页面超过一屏 —— 底部按钮先滚到可见再点。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/delivery_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

/// **弹层必须真的关掉** —— 否则下一步的点击会打在它的遮罩上
/// （`tester.tap` 默认 `warnIfMissed` 只是警告、不中断），
/// 下游于是报一个看不懂的 `Bad state: No element`。
///
/// 这道断言把「点错地方」缩到**出错的那一行**。它的灵敏度不是猜的：
/// 本文件第一版就是栽在它要防的那件事上（见 `pickCustomer` 的注释）。
///
/// ⚠️ **刻意放在顶层，而不是 `main()` 里**：Dart 的**局部**函数不提升 ——
/// 写在调用点后面会直接
/// `Error: Local variable '…' can't be referenced before it is declared`
/// （本文件第二版就是这么挂的）。顶层函数没有顺序约束，
/// **从结构上消灭这一类错**；同理，`main()` 里新加的助手一律排在最早调用点之前。
void expectPickerClosed() {
  expect(
    find.byKey(const Key('picker-search')),
    findsNothing,
    reason: '选择弹层没关上 —— 多半是「点结果行」点到了搜索框（`find.text` 连 '
        '`EditableText` 一起匹配）。见 pickCustomer 的注释。',
  );
}

void main() {
  setUpAll(useLocalSqlite);

  late Directory box;
  late Db db;
  late DeliveryService service;
  late ProductService products;
  late PartyService parties;
  // B3b：页面提交改吃 Sink —— 桌面语义 = ServiceSink（与直连逐字同行为）
  late DocumentSink sink;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_delivery_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    service = DeliveryService(engine: RuleEngine(db), queries: QueryDao(db));
    products = ProductService(db);
    parties = PartyService(PartyDao(db));
    sink = ServiceSink(
      sales: SaleService(engine: RuleEngine(db), queries: QueryDao(db)),
      purchases: PurchaseService(engine: RuleEngine(db), queries: QueryDao(db)),
      deliveries: service,
    );

    final Product product = Product(
      id: newId(),
      code: 'P0001',
      name: '红富士苹果',
      sellPrice: 500,
      createdAt: 1,
      updatedAt: 1,
    );
    ProductDao(db).insert(product);

    final Party party = Party(
      id: newId(),
      name: '王老板',
      roles: const <PartyRole>[PartyRole.customer],
      createdAt: 1,
      updatedAt: 1,
    );
    PartyDao(db).insert(party);

    // ⚠️ **故意不建资金账户** —— 第 3 条断言就是「送货不碰钱」。
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
      body: DeliveryPage(
        service: service,
        productService: products,
        partyService: parties,
        sink: sink,
        masterDataPolicy: const MasterDataPolicy.desktop(),
        masterDataSink: ServiceMasterSink(products),
      ),
    ),
  );

  /// 选第一行的商品。
  ///
  /// ⚠️ 三个坑（都是真踩过的）：
  /// ① 选择器**空查询显示的是「最近送货」**，首次使用时为空 ⇒ 必须先输入商品名；
  /// ② 不能用 `find.byType(TextField).first` 找搜索框 —— 弹层底下还压着页面的
  ///    几个输入框，树的先序遍历先碰到它们。搜索框一律用 **Key**；
  /// ③ **点结果行一律用 `widgetWithText(ListTile, …)`，不要用 `find.text(名).first`**
  ///    —— 见 `pickCustomer` 里那段说明（搜索框里的字也会被 `find.text` 命中）。
  Future<void> pickFirstProduct(WidgetTester tester) async {
    await tester.tap(find.text('点此选商品'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('picker-search')), '红富士');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '红富士苹果'));
    await tester.pumpAndSettle();
    expectPickerClosed();
  }

  /// 选客户（送货的客户**必选**）。
  ///
  /// ⚠️ **这里绝不能写 `find.text('王老板').first`** —— 刚往搜索框里输入的就是
  /// 「王老板」，而 `find.text` **连 `EditableText` 一起匹配**
  /// （`flutter_test/src/finders.dart` 的 `_MatchTextFinder.matches`：
  /// `if (widget is EditableText) return _matchesEditableText(widget);`），
  /// 于是它同时命中**搜索框**与结果行；先序遍历里搜索框在结果列表**上面**
  /// ⇒ `.first` 点到的是搜索框，**只是重新聚焦，弹层不关**。
  ///
  /// 后果很隐蔽：下一次点击打在弹层的遮罩上 —— 遮罩只会**把弹层关掉**
  /// （`tester.tap` 默认 `warnIfMissed` 只是警告、不中断），
  /// 于是现象是「tap 没命中 + 随后找不到 `picker-search`」两道红，
  /// **看着像页面坏了，其实是测试点错了地方**。
  ///
  /// 办法：`widgetWithText(ListTile, …)` 点**结果行本身**（页面里没有别的
  /// `ListTile`，两个选择器各一个，同一时刻只开一个）。
  Future<void> pickCustomer(WidgetTester tester) async {
    await tester.tap(find.text('点这里选客户（必选）'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('picker-search')), '王老板');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '王老板'));
    await tester.pumpAndSettle();
    expectPickerClosed();
  }

  Future<void> fillRow(WidgetTester tester, {String qty = '10'}) async {
    await pickFirstProduct(tester);
    // 单价已预填**售价** 5.00 —— 不动它
    await tester.enterText(find.byKey(const Key('delivery-qty')), qty);
    await tester.pumpAndSettle();
  }

  /// 底部按钮先滚到可见再点（按 **Key** 找，不按文案找 —— 本项目约定）。
  Future<void> tapSave(WidgetTester tester) async {
    final Finder button = find.byKey(const Key('delivery-save'));
    await tester.scrollUntilVisible(
      button,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  int documentCount() =>
      db.raw.select('SELECT COUNT(*) AS n FROM documents').first['n']! as int;

  int stockSum() =>
      db.raw
              .select('SELECT COALESCE(SUM(quantity), 0) AS s FROM stock_ledger')
              .first['s']!
          as int;

  testWidgets('客户必选：填了货、没选客户 ⇒ 拦下并说清后果，库里没有单据', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await fillRow(tester);
    await tapSave(tester);

    expect(
      find.textContaining('送货要选一个客户'),
      findsOneWidget,
      reason: '文案要说清「货出了门，欠款得有人挂着」，不是干巴巴一句「必填」',
    );
    expect(documentCount(), 0, reason: '没选客户就不该落库');
    expect(stockSum(), 0, reason: '**也没扣库存** —— 单据没成立');
  });

  testWidgets('成功保存：库存 −10、单据是「待签收」、不需要资金账户', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await pickCustomer(tester);
    await fillRow(tester);
    await tapSave(tester);

    expect(find.textContaining('已保存'), findsOneWidget);

    expect(documentCount(), 1);
    expect(
      stockSum(),
      -10,
      reason: '送货**创建即扣库存**（货已经出门）',
    );

    final Map<String, Object?> row = db.raw
        .select('SELECT status, paid_amount FROM documents')
        .first;
    expect(
      row['status'],
      DocStatus.inTransit.wire,
      reason: 'RULE-003 强制送货单落在「待签收」'
          '（⚠️ 是 `.wire` = `in_transit`，不是 `.name` = `inTransit`）',
    );
    expect(row['paid_amount'], 0, reason: '送货单不碰钱 —— 全额挂客户');
  });

  testWidgets('欠款挂在客户名下（往来流水 +qty）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await pickCustomer(tester);
    await fillRow(tester);
    await tapSave(tester);

    final int due =
        db.raw
                .select(
                  'SELECT COALESCE(SUM(amount), 0) AS s FROM party_ledger',
                )
                .first['s']!
            as int;
    expect(due, 5000, reason: '10 个 × ¥5.00 = ¥50，客户欠我 50 元');

    // 送货不产生任何资金流水（这是与销售/采购最本质的区别）
    final int cash =
        db.raw
                .select('SELECT COALESCE(SUM(amount), 0) AS s FROM money_ledger')
                .first['s']!
            as int;
    expect(cash, 0, reason: '送货单**零资金流水** —— 收款是另一件事（详情页核销）');
  });

  // ---- §BG 方案 A：切单位 ⇒ 未被手改的预填价跟着换算（三页同构，各钉各的 Key）----

  testWidgets('§BG 方案A：切到「箱」⇒ 预填价 ×12、单价标注单位、显示换算说明', (WidgetTester tester) async {
    final Product milk = Product(
      id: newId(),
      code: 'P0002',
      name: '蒙牛纯牛奶',
      unit: '瓶',
      sellPrice: 250,
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
    expectPickerClosed();

    TextField priceField() => tester.widget<TextField>(
      find.byKey(const Key('delivery-price')),
    );
    // 预填 = 瓶价 2.50，label 标注最小单位
    expect(priceField().controller!.text, '2.50');
    expect(find.text('单价（元/瓶）*'), findsOneWidget);

    // 切到「箱」⇒ 预填价 ×12 = 30.00（§BG 方案 A 的核心断言）
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, '箱'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '箱'));
    await tester.pumpAndSettle();
    expect(priceField().controller!.text, '30.00');
    expect(find.text('单价（元/箱）*'), findsOneWidget);
    expect(find.text('1 箱 = 12 瓶，入库按 12 瓶记。'), findsOneWidget);

    // 切回「瓶」⇒ ÷12 还原；换算说明消失（只在切到包装时显示，裁定 ③）
    await tester.tap(find.widgetWithText(ChoiceChip, '瓶'));
    await tester.pumpAndSettle();
    expect(priceField().controller!.text, '2.50');
    expect(find.text('单价（元/瓶）*'), findsOneWidget);
    expect(find.text('1 箱 = 12 瓶，入库按 12 瓶记。'), findsNothing);
  });

  // ============================================ M09 / M11：草稿保护（2026-10-08）

  testWidgets('M09：填了数量后按**返回** → 先问「放弃这次送货？」（以前直接丢草稿）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('delivery-qty')), '1');
    await tester.pumpAndSettle();

    // 模拟返回：AppBar 返回键与系统返回**都走这条路**（route 的 popDisposition）。
    // 以前页面没接 PopScope ⇒ 直接 pop、草稿无声丢失（报告 M09 实测）。
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pumpAndSettle();

    expect(find.text('放弃这次送货？'), findsOneWidget);
  });

  testWidgets('M11：**只填了备注**，按返回 / 点取消都要先确认（以前直接清空）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 备注框没有 Key，按 label 定位
    final Finder remark = find.byWidgetPredicate(
      (Widget w) => w is TextField && w.decoration?.labelText == '备注（可选）',
    );
    await tester.enterText(remark, '给老王家留两箱');
    await tester.pumpAndSettle();

    // ① 走**返回**这条路（`canPop` 在 build 时求值 ⇒ 备注框必须有 onChanged
    //    触发重建，否则这一步会直接 pop 掉 —— 断言就是钉这个衔接）
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pumpAndSettle();
    expect(
      find.text('放弃这次送货？'),
      findsOneWidget,
      reason: 'M11：备注也算「有内容」，返回时不能直接丢',
    );

    // ② 「继续填」之后再走「取消」这条路 —— 两条路一个判据
    await tester.tap(find.text('继续填'));
    await tester.pumpAndSettle();
    final Finder cancel = find.text('取消 (Esc)');
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(find.text('放弃这次送货？'), findsOneWidget);
  });
}
