// 账户页（`AccountsPage`）的 widget 测试。
//
// 直接挂页面（包 Scaffold），`AccountService` 指向**沙箱临时库** —— 走真实路径。
// ⚠️ 必须 `useLocalSqlite()`（§N）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/account_flow_page.dart';
import 'package:shensuanzi/src/ui/account_page.dart';
import 'package:shensuanzi/src/ui/document_detail_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

import 'support/fake_export.dart';

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

  Widget page({
    MasterDataPolicy? policy,
    PendingMarks? pendingMarks,
    SettlementService? settlements,
    ExportSink? exports,
  }) => MaterialApp(
    home: Scaffold(
      body: AccountsPage(
        service: service,
        // 缺省桌面（账户可建）⇒ 既有用例**零变化**；mobile() 组显式传入
        masterDataPolicy: policy ?? const MasterDataPolicy.desktop(),
        pendingMarks: pendingMarks,
        // #27 批 1：流水页的导出与「跳单据详情」所需服务
        settlements: settlements,
        exports: exports,
      ),
    ),
  );

  /// 让某个账户成为「主机还没确认」的乐观行（队列里一条 pending 条目）
  PendingMarks pendingFor(String accountId) {
    final SyncQueueDao queue = SyncQueueDao(db);
    queue.enqueue(
      SyncQueueEntry.create(
        SyncOperation(
          entity: Schema.accounts,
          entityId: accountId,
          operation: SyncOpType.createMasterData,
        ),
        now: 1700000000000,
      ),
    );
    return PendingMarks(queue);
  }

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
      AccountDraft(name: '现金', type: AccountType.cash, initialBalance: '300'),
      now: 1700000000000,
    );

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // ⚠️ 不能 tap 文字「现金」—— 列表行 + 对话框下拉选中项都叫这个名（歧义）
    // 2026-10-22（§CV·八十三）：行尾改成**文字按钮**（原来是 `⋮` 菜单）
    await tester.tap(find.byKey(Key('account-edit-${account.id}')));
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

  // ============================================================ §CV·九·五 甲
  // `MasterDataPolicy.mobile()`（账户 v1 禁建）下**本页消费值对象**的分支 ——
  // 与 §CV·七 的 ①②③ 是同一批的第 ④ 个数：product / party / account 三个**独立**分支。
  testWidgets('mobile()：＋新建账户 ⇒ 出**引导**（账户 v1 禁建）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(page(policy: const MasterDataPolicy.mobile()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建账户'));
    await tester.pumpAndSettle();

    expect(
      find.text('这一步在电脑上做'),
      findsOneWidget,
      reason: '账户 v1 禁建 ⇒ 保留入口 + 引导到电脑',
    );
    expect(
      find.byKey(const Key('account-name')),
      findsNothing,
      reason: '不能进表单 —— 条件写反（把 false 当 true 用）会在这里暴露',
    );
  });

  // ============================================================ D2b：乐观行的「待同步」小字
  // `data_model.md §4.4` 第 3 条：乐观行**必须可分辨**（「我有的」与「主机确认的」）。
  testWidgets('乐观行带一行浅灰「待同步」', (WidgetTester tester) async {
    final Account optimistic = service.create(
      AccountDraft(name: '微信收款', type: AccountType.wechat),
      now: 1700000000000,
    );

    await tester.pumpWidget(page(pendingMarks: pendingFor(optimistic.id)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(Key('pending-account-${optimistic.id}')),
      findsOneWidget,
      reason: '只在本地、主机还没确认 ⇒ 必须一眼看得出来',
    );
    expect(find.text('待同步'), findsOneWidget);
  });

  testWidgets('不注入 pendingMarks ⇒ 不出现「待同步」（桌面 / 未接队列时零变化）', (
    WidgetTester tester,
  ) async {
    service.create(
      AccountDraft(name: '现金', type: AccountType.cash),
      now: 1700000000000,
    );

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    expect(find.text('待同步'), findsNothing);
  });

  // ===== #27 批 1（2026-10-17）：账户流水页 + 行同构 =====

  testWidgets('#27：点账户行打开流水页（人可读行 + 导出按钮 + 行跳详情）', (WidgetTester tester) async {
    final Account account = service.create(
      AccountDraft(name: '现金', type: AccountType.cash, initialBalance: '300'),
      now: 1700000000000,
    );
    // 收款单 + 资金流水（规则引擎路径已由 core 测试覆盖，这里直种）
    db.raw.execute(
      "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
      'paid_amount, occurred_at, time_estimated, created_at, updated_at) '
      "VALUES ('d1', 'SK20260101-001', 'receipt', 'confirmed', 3000, 3000, "
      '1700000100000, 0, 1700000100000, 1700000100000)',
    );
    MoneyLedgerDao(db).insert(
      MoneyLedger(
        id: newId(),
        accountId: account.id,
        documentId: 'd1',
        amount: 3000,
        seqNo: 1,
        occurredAt: 1700000100000,
        createdAt: 1700000100000,
      ),
    );

    await tester.pumpWidget(
      page(
        settlements: SettlementService(db: db, engine: RuleEngine(db)),
        exports: FakeExport(),
      ),
    );
    await tester.pumpAndSettle();

    // 行 tap = 流水（裁定③：与 parties 行同构）
    await tester.tap(find.byKey(Key('account-row-${account.id}')));
    await tester.pumpAndSettle();

    expect(find.byType(AccountFlowPage), findsOneWidget);
    expect(find.text('现金 的流水'), findsOneWidget);
    expect(find.text('SK20260101-001'), findsOneWidget);
    expect(find.textContaining('收款'), findsWidgets);
    expect(find.byKey(const Key('export-account-flow')), findsOneWidget);
    expect(find.text('点流水行可以打开对应单据。'), findsOneWidget);

    // 流水行 tap ⇒ 跳单据详情（裁定⑤：桌面可跳）
    await tester.tap(find.byKey(const Key('account-flow-row-d1')));
    await tester.pumpAndSettle();
    expect(find.byType(DocumentDetailPage), findsOneWidget);
  });

  // 2026-10-21（§CV·八十 Q1）：与另外两个流水页同一组判据。
  testWidgets('#64④ 账户流水页不许把 2.0 夹到 1.15；2.0 下不溢出', (
    WidgetTester tester,
  ) async {
    final Account account = service.create(
      AccountDraft(name: '现金', type: AccountType.cash, initialBalance: '300'),
      now: 1700000000000,
    );
    // 种一条资金流水（与 #27 同款；规则引擎路径已由 core 覆盖）
    db.raw.execute(
      "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
      'paid_amount, occurred_at, time_estimated, created_at, updated_at) '
      "VALUES ('d1', 'SK20260101-001', 'receipt', 'confirmed', 3000, 3000, "
      '1700000100000, 0, 1700000100000, 1700000100000)',
    );
    MoneyLedgerDao(db).insert(
      MoneyLedger(
        id: newId(),
        accountId: account.id,
        documentId: 'd1',
        amount: 3000,
        seqNo: 1,
        occurredAt: 1700000100000,
        createdAt: 1700000100000,
      ),
    );

    Future<double> dateLineHeight(double scale) async {
      // 每次从**空树**重建：否则 Navigator 会把上一次 push 的流水页留着
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: AccountsPage(
              service: service,
              masterDataPolicy: const MasterDataPolicy.desktop(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('account-row-${account.id}')));
      await tester.pumpAndSettle();
      expect(find.byType(AccountFlowPage), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$scale× 下账户流水页溢出');
      // 量「单号 · 日期」那一行（含 docNo 的 Text）
      return tester.getSize(find.textContaining('SK20260101-001').first).height;
    }

    final double h1 = await dateLineHeight(1.0);
    final double h2 = await dateLineHeight(2.0);
    expect(
      h2 / h1,
      greaterThan(1.6),
      reason: '字号被夹到 1.15（比值≈1.15）—— 用户选的 2.0 必须真的生效',
    );
  });

  testWidgets('#27：行尾操作不丢 —— 编辑 / 停用是**文字按钮**（不再是 ⋮ 菜单）', (WidgetTester tester) async {
    final Account account = service.create(
      AccountDraft(name: '现金', type: AccountType.cash),
      now: 1700000000000,
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    // 行 tap 现在开的是流水页（不再是编辑）
    await tester.tap(find.byKey(Key('account-row-${account.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(AccountFlowPage), findsOneWidget);
    // 流水为空 ⇒ 空态文案（不是崩溃）
    expect(find.text('还没有资金流水。'), findsOneWidget);

    // 回到列表：行尾两个**文字按钮**（2026-10-22 起，`⋮` 菜单已删除）
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(Key('account-edit-${account.id}')), findsOneWidget);
    expect(find.byKey(Key('account-toggle-${account.id}')), findsOneWidget);
    expect(find.byTooltip('更多操作'), findsNothing, reason: '菜单已删');
  });

  // 2026-10-22（§CV·八十三 / 报告 §2.2 漂移 4）：账户页原来是
  // **既不确认也不撤销** —— 里面有钱也能一键停用、且没有退路。
  // 现在与往来方同一套：有余额先确认，余额为 0 直接执行 + 撤销。
  testWidgets('停用**有余额**的账户：先二次确认', (WidgetTester tester) async {
    final Account account = service.create(
      AccountDraft(name: '现金', type: AccountType.cash, initialBalance: '300'),
      now: 1700000000000,
    );
    db.raw.execute(
      "INSERT INTO documents (id, doc_no, doc_type, status, total_amount, "
      'paid_amount, occurred_at, time_estimated, created_at, updated_at) '
      "VALUES ('d1', 'SK20260101-001', 'receipt', 'confirmed', 3000, 3000, "
      '1700000100000, 0, 1700000100000, 1700000100000)',
    );
    MoneyLedgerDao(db).insert(
      MoneyLedger(
        id: newId(),
        accountId: account.id,
        documentId: 'd1',
        amount: 3000,
        seqNo: 1,
        occurredAt: 1700000100000,
        createdAt: 1700000100000,
      ),
    );

    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('account-toggle-${account.id}')));
    await tester.pumpAndSettle();

    expect(find.text('这个账户里还有钱'), findsOneWidget);
    // 还没确认 ⇒ 账户仍然是启用的
    expect(service.list(active: true).map((Account a) => a.id), contains(account.id));

    // 取消 ⇒ 不动
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.list(active: true).map((Account a) => a.id), contains(account.id));

    // 再来一次，「还是停用」
    await tester.tap(find.byKey(Key('account-toggle-${account.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('还是停用'));
    await tester.pumpAndSettle();
    expect(service.list(active: true).map((Account a) => a.id), isNot(contains(account.id)));
  });

  testWidgets('停用**无余额**的账户：不打扰，但有撤销', (WidgetTester tester) async {
    final Account account = service.create(
      AccountDraft(name: '空账户', type: AccountType.cash),
      now: 1700000000000,
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('account-toggle-${account.id}')));
    await tester.pumpAndSettle();

    expect(
      find.text('这个账户里还有钱'),
      findsNothing,
      reason: '余额为 0 还问一句是骚扰',
    );
    expect(service.list(active: true).map((Account a) => a.id), isNot(contains(account.id)));
    // 撤销 6 秒内可反悔
    expect(find.text('已停用「空账户」'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(service.list(active: true).map((Account a) => a.id), contains(account.id));
  });

  // 2026-10-19 用户实测（账户页截图，超大档，窗口与 VSCode 均分 960 宽）：
  // 「微信收款账户」+ 类型标签「微信」+ 右侧金额挤在同一行 ⇒ 黄黑溢出条纹。
  // 根因：`Row[名字, 类型]` 两个都不许收缩。
  testWidgets('超大档（2.0）+ 窄窗口：账户行不溢出，名字完整显示', (WidgetTester tester) async {
    service.create(
      AccountDraft(name: '微信收款账户', type: AccountType.wechat),
      now: 1700000000000,
    );
    service.create(
      AccountDraft(name: '店内现金', type: AccountType.cash, initialBalance: '100'),
      now: 1700000000000,
    );

    tester.view.physicalSize = const Size(960, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        // ⚠️ 真实条件是「窗口 960 宽，左侧导航占 435」⇒ 内容区只有 ~525。
        // 直接给 960 会测不出问题（我第一版就是这么写的，绿得毫无意义）。
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 520,
              child: AccountsPage(
                service: service,
                masterDataPolicy: const MasterDataPolicy.desktop(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: '账户行在 2.0 档下溢出（用户截图：黄黑条纹压在「微信」上）',
    );
    expect(
      find.text('微信收款账户'),
      findsOneWidget,
      reason: '名字是账户的唯一标识 —— 不许被省略号截成「微信收款账…」',
    );
    expect(find.textContaining('微信 · 期初'), findsOneWidget);
  });
}
