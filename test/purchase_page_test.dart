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
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late PurchaseService service;
  late ProductService products;
  late String productId;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_purchase_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    service = PurchaseService(engine: RuleEngine(db), queries: QueryDao(db));
    products = ProductService(db);

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
      body: PurchasePage(service: service, productService: products),
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
  Future<void> tapBottomButton(WidgetTester tester, String label) async {
    final Finder button = find.text(label);
    await tester.scrollUntilVisible(
      button,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

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
}
