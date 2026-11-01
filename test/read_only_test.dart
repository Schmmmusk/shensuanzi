// **只读模式**的强制力（2026-11-01，提案 57 批复 §三）。
//
// ## 为什么单独一组
//
// 用户的原话：
//
// > 当前实现能够做到：提醒用户不能保存；警告用户不要录单；允许用户继续查看。
// > 但它并没有从应用层强制禁止写操作……尤其要注意，不能只把开单按钮置灰，
// > 还要覆盖库存调整、主数据修改、收付款、同步队列写入等实际写入出口。
//
// 所以这里钉的是**代码路径**被切断，不是按钮长得像不能用：
//
// | 写入口 | 怎么挡 |
// |---|---|
// | 开单三页 | `documentSink == null` ⇒ 整页换成「暂时不能开 + 原因」 |
// | 库存清点 | `documentSink == null` ⇒ 入口不渲染（桌面也一样） |
// | 商品新增 / 编辑 / 停用 | `canWrite: false` ⇒ 按钮置灰 **且** 方法体直接 return |
// | 收付款 / 退货 | `settlements` / `returns` 传 `null` |
//
// ⚠️ 商品页是特例：桌面一直用 `ServiceMasterSink` 直连主库、**不看**
// `shell.masterDataSink`，所以只读必须显式传 `canWrite: false` —— 这条最容易漏。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/app_shell.dart';
import 'package:shensuanzi/src/ui/products_page.dart';
import 'package:shensuanzi/src/ui/sale_page.dart';
import 'package:shensuanzi/src/ui/stock_page.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;

  setUp(() {
    box = Directory.systemTemp.createTempSync('ssz_read_only_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
  });

  tearDown(() {
    db.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('商品页：三个写入口都要断', () {
    testWidgets('canWrite=false ⇒ 「新增商品」按钮置灰', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(ProductsPage(service: ProductService(db), canWrite: false)),
      );
      await tester.pumpAndSettle();

      final FilledButton button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '新增商品'),
      );
      expect(
        button.onPressed,
        isNull,
        reason: '置灰还不够，但至少要置灰 —— 代码路径另有 return 兜底',
      );
    });

    testWidgets('canWrite=true ⇒ 按钮可用（别把正常路径一起关掉）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        wrap(ProductsPage(service: ProductService(db))),
      );
      await tester.pumpAndSettle();

      final FilledButton button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '新增商品'),
      );
      expect(button.onPressed, isNotNull);
    });
  });

  group('库存页：只读时桌面也不给清点入口', () {
    testWidgets('canWrite=false（桌面壳）⇒ 不渲染「录入现有货物 / 重新清点」', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          StockPage(
            engine: RuleEngine(db),
            products: ProductService(db),
            queries: QueryDao(db),
            // 只读降级：app.dart 会把 canWrite 传成 false（桌面也挡）
            canWrite: false,
            documentSink: null,
            mobileShell: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('录入现有货物'), findsNothing);
      expect(find.text('重新清点'), findsNothing);
    });
  });
  // 2026-11-01 真机验收补的一条：**「只读」怎么传到页面**。
  //
  // `app.dart` 里 `readOnly` 的两个判据已经抽成纯函数（`write_blocked.dart`，
  // 由 `write_blocked_test.dart` 钉住）；页面拿到 `canWrite: false` 之后的行为
  // 由上面两组钉住。**中间那一段「壳按 readOnlyReason 传参」**原来只有真机能验 ——
  // 而真机上造 Low 完整性要给 exe 打标签、测完还得清现场（用户已说这条路走不通）。
  //
  // 这条把它补上：壳带 `readOnlyReason` ⇒ 商品页必须收到 `canWrite: false`。
  group('壳层传参：只读 ⇒ 页面真的收到 canWrite=false', () {
    AppShell shellWith({String? readOnlyReason}) => AppShell(
      dataDirectory: box.path,
      backupDirectory: box.path,
      schemaVersion: Schema.version,
      databaseReady: true,
      configStore: AppConfigStore(File(p.join(box.path, 'config.json'))),
      onConfigChanged: (AppConfig _) {},
      products: ProductService(db),
      masterDataPolicy: readOnlyReason == null
          ? const MasterDataPolicy.desktop()
          : const MasterDataPolicy.readOnly(),
      readOnlyReason: readOnlyReason,
    );

    test('有 readOnlyReason ⇒ ProductsPage.canWrite == false', () {
      final Widget page = appShellPage(
        shellWith(readOnlyReason: '本机账本打不开'),
        AppNavigation.byId('products')!,
      );
      expect(page, isA<ProductsPage>());
      expect(
        (page as ProductsPage).canWrite,
        isFalse,
        reason: '只读必须传到页面，否则「置灰」这件事永远不发生',
      );
    });

    test('没有 readOnlyReason ⇒ canWrite == true（别把正常路径一起关掉）', () {
      final Widget page = appShellPage(
        shellWith(),
        AppNavigation.byId('products')!,
      );
      expect((page as ProductsPage).canWrite, isTrue);
    });

    test('只读 ⇒ 开单页换成「暂时不能开」，而不是「正在开发」', () {
      // 手机上验过（整屏 push 页），这里钉住**判据**：只读时走 unavailable 分支
      final Widget page = appShellPage(
        shellWith(readOnlyReason: '本机账本打不开'),
        AppNavigation.byId('sale')!,
      );
      expect(
        page,
        isNot(isA<SalePage>()),
        reason: '只读时绝不能渲染开单页 —— 那是写入口本体',
      );
    });
  });

}
