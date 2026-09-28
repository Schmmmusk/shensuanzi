// 商品页（`ProductsPage`）的 widget 测试。
//
// 覆盖：§AF 导出按钮 —— 文案「导出全部商品」、**含停用**、**不看搜索框**
// （AF-2 的按钮文案就是「全部」，所以搜索框不该影响它）。
//
// ⚠️ 必须 `useLocalSqlite()`（§N）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/products_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

import 'support/fake_export.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late ProductService service;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_products_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    service = ProductService(db);

    final int t = 1700000000000;
    ProductDao(db).insert(Product(
      id: 'p1',
      code: 'P0001',
      name: '可乐',
      unit: '瓶',
      sellPrice: 300,
      costPrice: 200,
      safetyStock: 5,
      createdAt: t,
      updatedAt: t,
    ));
    ProductDao(db).insert(Product(
      id: 'p2',
      code: 'P0002',
      name: '停用货',
      isActive: false,
      createdAt: t,
      updatedAt: t,
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

  Widget page({ExportSink? exports}) => MaterialApp(
    home: Scaffold(body: ProductsPage(service: service, exports: exports)),
  );

  testWidgets('导出全部商品：含停用、不受搜索框影响（AF-2 / AF-12）', (
    WidgetTester tester,
  ) async {
    final FakeExport fake = FakeExport();
    await tester.pumpWidget(page(exports: fake));
    await tester.pumpAndSettle();

    // AF-2：按钮文案说清导的是「全部商品」
    expect(find.byKey(const Key('export-products')), findsOneWidget);
    expect(find.text('导出全部商品'), findsOneWidget);

    // 在搜索框里打字 —— 导出的仍是**全部**（按钮说的就是全部）
    await tester.enterText(find.byType(TextField).first, '可乐');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('export-products')));
    await tester.pumpAndSettle();

    expect(fake.calls, 1);
    final ExportTable table = fake.last;
    expect(table.label, '商品');
    expect(table.header, <String>[
      '编码',
      '商品名称',
      '条码',
      '单位',
      '售价',
      '进价',
      '安全库存',
      '状态',
    ]);
    expect(
      table.rows.length,
      2,
      reason: '搜索框不参与导出 —— 「导出全部商品」就是全部',
    );
    expect(
      table.rows.map((List<String> row) => row[7]).toList(),
      <String>['启用', '停用'],
      reason: 'AF-12：含停用，且状态列能一眼看出来',
    );
    expect(table.rows.first.sublist(1, 4), <String>['可乐', '', '瓶']);
  });

  testWidgets('没接导出服务 → 不显示按钮（与其他可选服务同款判定）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('export-products')), findsNothing);
    expect(find.text('导出全部商品'), findsNothing);
  });
}
