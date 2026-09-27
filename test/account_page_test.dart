// 账户页（`AccountsPage`）的 widget 测试。
//
// 直接挂页面（包 Scaffold），`AccountService` 指向**沙箱临时库** —— 走真实路径。
// ⚠️ 必须 `useLocalSqlite()`（§N）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/account_page.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  useLocalSqlite();

  late Directory box;
  late Db db;
  late AccountService service;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_account_page_');
    db = Db.open(p.join(box.path, 'shensuanzi.db'));
    service = AccountService(AccountDao(db));
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
    home: Scaffold(body: AccountsPage(service: service)),
  );

  testWidgets('空列表给出「怎么办」（新建账户的引导）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有资金账户'), findsOneWidget);
    expect(find.text('新建账户'), findsOneWidget);
  });

  testWidgets('新建账户 → 列表出现，余额含期初', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建账户'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('account-name')), '微信收款');
    // 下拉选项要先点开下拉框才出现在树上
    await tester.tap(find.byKey(const Key('account-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('微信').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('account-initial')), '200');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.text('微信收款'), findsOneWidget);
    // 余额 = 期初 200 元
    expect(find.text('¥ 200.00'), findsOneWidget);
    // 空态引导消失
    expect(find.textContaining('还没有资金账户'), findsNothing);
  });

  testWidgets('编辑：期初余额只读且不可改（Z-3 方案 A）', (WidgetTester tester) async {
    final Account account = service.create(
      AccountDraft(
        name: '现金',
        type: AccountType.cash,
        initialBalance: '300',
      ),
      now: 1700000000000,
    );

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // ⚠️ 不能 tap 文字「现金」—— 列表行 + 对话框下拉选中项都叫这个名（歧义）
    await tester.tap(find.byKey(Key('account-row-${account.id}')));
    await tester.pumpAndSettle();

    // 期初余额显示为**只读文本**，没有可编辑的期初输入框
    expect(find.textContaining('建账后不可改'), findsOneWidget);
    expect(find.byKey(const Key('account-initial')), findsNothing);

    // 改名保存 → 期初余额不变
    await tester.enterText(find.byKey(const Key('account-name')), '门店现金');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('门店现金'), findsOneWidget);
    expect(service.list().first.initialBalance, 30000);
    expect(AccountDao(db).findById(account.id)?.initialBalance, 30000);
  });

  testWidgets('空名保存 → 字段级报错（不关对话框）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建账户'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请填账户名称'), findsOneWidget);
    expect(find.text('新建账户'), findsWidgets, reason: '对话框还开着（标题也是这四个字）');
  });
}
