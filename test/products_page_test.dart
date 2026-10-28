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
    ProductDao(db).insert(
      Product(
        id: 'p1',
        code: 'P0001',
        name: '可乐',
        unit: '瓶',
        sellPrice: 300,
        costPrice: 200,
        safetyStock: 5,
        createdAt: t,
        updatedAt: t,
      ),
    );
    ProductDao(db).insert(
      Product(
        id: 'p2',
        code: 'P0002',
        name: '停用货',
        isActive: false,
        createdAt: t,
        updatedAt: t,
      ),
    );
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  Widget page({ExportSink? exports, PendingMarks? pendingMarks}) => MaterialApp(
    home: Scaffold(
      body: ProductsPage(
        service: service,
        exports: exports,
        pendingMarks: pendingMarks,
      ),
    ),
  );

  /// 让某个商品成为「主机还没确认」的乐观行（队列里一条 pending 条目）
  PendingMarks pendingFor(String productId) {
    final SyncQueueDao queue = SyncQueueDao(db);
    queue.enqueue(
      SyncQueueEntry.create(
        SyncOperation(
          entity: Schema.products,
          entityId: productId,
          operation: SyncOpType.createMasterData,
        ),
        now: 1700000000000,
      ),
    );
    return PendingMarks(queue);
  }

  testWidgets('导出全部商品：含停用、不受搜索框影响（AF-2 / AF-12）', (WidgetTester tester) async {
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
    expect(table.rows.length, 2, reason: '搜索框不参与导出 —— 「导出全部商品」就是全部');
    expect(
      table.rows.map((List<String> row) => row[7]).toList(),
      <String>['启用', '停用'],
      reason: 'AF-12：含停用，且状态列能一眼看出来',
    );
    expect(table.rows.first.sublist(1, 4), <String>['可乐', '', '瓶']);
  });

  // 2026-10-21（§CV·八十，报告 §2.2 漂移 1）：搜不到 ≠ 空库。
  // 店里有商品、只是搜错了，不能说「还没有商品」—— 否则用户会去重复建档。
  testWidgets('搜不到时说「没有找到」，不是「还没有商品」', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ProductsPage(service: service)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.textContaining('没有找到「zzz」'), findsOneWidget);
    expect(find.text('还没有商品'), findsNothing, reason: '空库才这么说');
    // 清空按钮在（报告 §2.5：清空搜索全仓只有单据页有）
    expect(find.byKey(const Key('products-clear-search')), findsOneWidget);
  });

  testWidgets('没接导出服务 → 不显示按钮（与其他可选服务同款判定）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('export-products')), findsNothing);
    expect(find.text('导出全部商品'), findsNothing);
  });

  // ---------------- D2b：乐观行的「待同步」小字 ----------------

  testWidgets('乐观行带一行浅灰「待同步」；主机已确认的行没有'
      '（`data_model.md §4.4` 第 3 条）', (WidgetTester tester) async {
    await tester.pumpWidget(page(pendingMarks: pendingFor('p1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('pending-product-p1')),
      findsOneWidget,
      reason: 'p1 只在本地（队列里还没被确认）⇒ 必须一眼看得出来',
    );
    expect(
      find.byKey(const Key('pending-product-p2')),
      findsNothing,
      reason: 'p2 不在队列里 ⇒ 它已是主机确认的',
    );
    expect(find.text('待同步'), findsOneWidget, reason: '文案就是「待同步」三个字');
  });

  testWidgets('不注入 pendingMarks ⇒ 一行小字都不出现（桌面 / 未接队列时零变化）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('待同步'), findsNothing);
  });
  // 附录 B（`docs/ui-review-2026-10-21.md`）：商品页 原先**没有**大字号断言。
  // 批 3 第 18 条：前 17 项「尺寸随缩放派生」改造的机械护栏 —— 先立护栏再动尺寸。
  testWidgets('大字号（2.0）：商品页不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(960, 1000);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: '商品页在 2.0 档下溢出（附录 B 点名的结构：固定宽度 / 固定断点 / 顶部 Row）',
    );
  });

  // ------------------------------------------------------------ 真实总数（2026-10-27）
  //
  // 现实用户暴雷：商品过 200 个后，页面上一直显示「共 200 种」。
  // 根因：`ProductService.list()` 的 `limit` 默认 200，而计数行写的是
  // `rows.length` —— 把「这一屏取到多少」当成「总共有多少」。
  // 这不是美观问题：用户拿它对账，会以为自己只有 200 个商品。
  testWidgets('商品超过 200 个：显示真实总数，并说清只展示了前 200 种', (WidgetTester tester) async {
    final int t = 1700000000000;
    // setUp 里已有 1 个启用 + 1 个停用 ⇒ 再补 249 个启用，共 250 个启用
    for (int i = 0; i < 249; i++) {
      ProductDao(db).insert(
        Product(
          id: 'bulk$i',
          code: 'B${i.toString().padLeft(4, '0')}',
          name: '批量商品$i',
          unit: '个',
          sellPrice: 100,
          costPrice: 80,
          createdAt: t,
          updatedAt: t,
        ),
      );
    }

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(
      find.textContaining('共 250 种'),
      findsOneWidget,
      reason: '必须说真实总数 —— 显示 200 会让用户以为自己只有 200 个商品',
    );
    expect(
      find.textContaining('当前仅展示前 200 种'),
      findsOneWidget,
      reason: '截断必须说出来，否则用户找不到第 201 个还以为数据丢了',
    );
    expect(
      find.textContaining('要具体的请用上方搜索'),
      findsOneWidget,
      reason: '光说「只展示 200」不给出口，用户还是不知道怎么办',
    );
  });

  // ------------------------------------------------------------ 查询不在 build 里（2026-10-28）
  //
  // 第五轮埋点：商品页首帧只有 7 ms，却要 **2.7 秒 / 110 帧**才稳定。
  // 根因之一：`_rows` / `_total` 是 getter，`build()` 每次取都现查库 ——
  // 任何一次重绘都等于重查一次。这条用例钉住「重建不许查库」。
  testWidgets('build 里不查库：只重建不换筛选，不产生新查询', (WidgetTester tester) async {
    final _CountingService counting = _CountingService(db);
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              rebuild = setState;
              return ProductsPage(service: counting);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final int afterMount = counting.queries;
    expect(afterMount, greaterThan(0), reason: '首屏必须查一次');

    rebuild(() {});
    await tester.pumpAndSettle();
    expect(
      counting.queries,
      afterMount,
      reason: '重建又查库 = 110 帧就查 110 次（真机 2.7 秒的成因）',
    );

    // 反过来：换筛选必须重查
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(counting.queries, greaterThan(afterMount), reason: '换筛选必须重查');
  });

  // ------------------------------------------------------------ 带按钮的 SnackBar 会自己退（2026-10-28）
  //
  // 用户实测 P2：「弹出的消息不自动退下，容易以为软件坏了」。
  // 根因在 SDK：Flutter 3.38+ 的 M3 规范把 `persist` 默认成 `action != null`
  // （`snack_bar.dart:303`）—— **带按钮的 SnackBar 永远不退**，只能被下一条挤下去。
  // 修法是显式写 `persist: false`；这条用例钉住「6 秒后它真的没了」。
  testWidgets('停用后的「撤销」提示会自己退（persist: false）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 第一行（可乐，启用中）的「停用」按钮
    await tester.tap(find.widgetWithText(TextButton, '停用').first);
    await tester.pumpAndSettle();

    expect(find.text('撤销'), findsOneWidget, reason: '提示先要出来');
    expect(find.text('已停用「可乐」'), findsOneWidget);

    // 走完 duration(6 秒) + 退场动画
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(
      find.text('撤销'),
      findsNothing,
      reason: '带按钮的 SnackBar 默认 persist=true（SDK 的 M3 行为）⇒ 必须显式 persist:false',
    );
  });
}

/// 只数「查了几次库」的服务（钉住「查询不在 build 里」）。
class _CountingService extends ProductService {
  _CountingService(super.db);

  int queries = 0;

  @override
  List<Product> list({String? query, bool? active = true, int limit = 200}) {
    queries++;
    return super.list(query: query, active: active, limit: limit);
  }

  @override
  int count({String? query, bool? active = true}) {
    queries++;
    return super.count(query: query, active: active);
  }
}
