// 移动端壳（`MobileShell`）的 widget 测试 —— §BH B1a。
//
// 页面装配与桌面壳**共用 `appShellPage`**（app_shell.dart），所以这里只钉
// 摆放层的三件事：5 个 tab 的文字标签、开单 tab 的三个入口、我的 tab 的
// 设置 / 帮助。服务全部不注入（走 `_PendingPage` 兜底）—— 摆放层不依赖库。
//
// 运行：`flutter test`（本机由用户执行）
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/app_shell.dart';
import 'package:shensuanzi/src/ui/mobile_shell.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

void main() {
  late Directory box;
  late AppConfigStore store;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_mobile_shell_');
    store = AppConfigStore(File(p.join(box.path, 'config.json')));
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  Widget page() => MaterialApp(
    home: MobileShell(
      // 服务全部缺省 ⇒ 各 tab 走 `_PendingPage` 兜底 —— 摆放层零依赖
      shell: AppShell(
        dataDirectory: '/tmp/data',
        backupDirectory: '/tmp/backup',
        schemaVersion: 3,
        databaseReady: false,
        configStore: store,
        onConfigChanged: (AppConfig config) {},
        // 门控按能力走（§CV·七 ① 乙）；sink 缺省 = 相关 tab 照旧 `_PendingPage`
        masterDataPolicy: const MasterDataPolicy.desktop(),
      ),
    ),
  );

  testWidgets('底部导航：5 个入口的文字标签齐（§AH-5，不许增减改名）', (WidgetTester tester) async {
    await tester.pumpWidget(page());

    for (final String label in <String>['概览', '开单', '库存', '往来', '我的']) {
      expect(find.text(label), findsWidgets, reason: 'tab 标签 $label 必须在');
    }
  });

  testWidgets('开单 tab：三个入口（销售 / 采购 / 送货），点销售推整屏', (WidgetTester tester) async {
    await tester.pumpWidget(page());

    await tester.tap(find.text('开单'));
    await tester.pumpAndSettle();

    // 三个入口的 label 取自 AppNavigation（与桌面导航同源，不会漂移）
    expect(find.text('销售开单'), findsOneWidget);
    expect(find.text('采购入库'), findsOneWidget);
    expect(find.text('送货'), findsOneWidget);

    // 点「销售开单」→ 推整屏：AppBar 标题在（列表项被盖在下面），
    // 服务缺省 ⇒ 页面内容是 _PendingPage 占位 —— 摆放层只验「推进去了、能返回」
    await tester.tap(find.text('销售开单'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('销售开单')),
      findsOneWidget,
      reason: '整屏 AppBar 标题 = 入口名',
    );
    expect(find.byType(BackButton), findsOneWidget, reason: '整屏要能返回');
  });

  testWidgets('我的 tab：设置 / 帮助 / 版本三行都在', (WidgetTester tester) async {
    await tester.pumpWidget(page());

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('帮助'), findsOneWidget);
    expect(find.text('版本与反馈'), findsOneWidget);
    expect(find.textContaining(AppVersion.display), findsOneWidget);
  });
  // ============================================ 三态条（B3b·§CA 裁定 ④）

  testWidgets('三态条：未注入 sync ⇒ 不显示（摆放层零依赖）', (WidgetTester tester) async {
    await tester.pumpWidget(page());
    expect(find.text('已同步'), findsNothing);
  });

  /// 三态条夹具：指向临时目录的同步服务。
  ///
  /// [pairing] 传 `null` = **没配对过**（`pairing.json` 不存在）；
  /// 传值 = 已配对（再带 `lastSyncAt` 才算「同步成功过」）。
  MobileSyncService syncServiceIn(Directory box, {PairingInfo? pairing}) {
    final PairingStore pairingStore = PairingStore(
      File(p.join(box.path, 'pairing.json')),
    );
    if (pairing != null) pairingStore.save(pairing);
    return MobileSyncService(
      mirrorPath: p.join(box.path, 'mirror', 'shensuanzi_mirror.db'),
      pairingStore: pairingStore,
    );
  }

  Widget shellWith(MobileSyncService sync) => MaterialApp(
    home: MobileShell(
      shell: AppShell(
        dataDirectory: '/tmp/data',
        backupDirectory: '/tmp/backup',
        schemaVersion: 3,
        databaseReady: false,
        configStore: store,
        onConfigChanged: (AppConfig config) {},
        masterDataPolicy: const MasterDataPolicy.desktop(),
        mobileSync: sync,
      ),
    ),
  );

  testWidgets('三态条：**没配对** + 空队列 ⇒ 「尚未连接电脑」（M04：空队列 ≠ 已同步）', (
    WidgetTester tester,
  ) async {
    final Directory syncBox = Directory.systemTemp.createTempSync(
      'shensuanzi_syncbar_',
    );
    addTearDown(() {
      try {
        syncBox.deleteSync(recursive: true);
      } catch (_) {
        // 镜像库可能还开着 —— 删不掉不影响结论（同既有测试的兜底）
      }
    });

    await tester.pumpWidget(shellWith(syncServiceIn(syncBox)));
    await tester.pumpAndSettle();

    // M04（2026-10-08，`docs/reply.md` §二·1）：**空队列不再等于「已同步」** ——
    // 没配对过就是什么都没连上，显示「已同步」会让用户以为单已经传给电脑了
    expect(find.text('尚未连接电脑'), findsOneWidget);
    expect(find.text('已同步'), findsNothing);

    // tab 之间常驻（切到「我的」再回来看，它还在）
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('概览'));
    await tester.pumpAndSettle();
    expect(find.text('尚未连接电脑'), findsOneWidget);
  });

  testWidgets('三态条：已配对 + 同步过 + 空队列 ⇒ 「已同步」', (WidgetTester tester) async {
    final Directory syncBox = Directory.systemTemp.createTempSync(
      'shensuanzi_syncbar2_',
    );
    addTearDown(() {
      try {
        syncBox.deleteSync(recursive: true);
      } catch (_) {
        // 同上：库还开着时删不掉，不影响结论
      }
    });

    await tester.pumpWidget(
      shellWith(
        syncServiceIn(
          syncBox,
          pairing: PairingInfo.fromPayload(
            hostId: 'h1',
            ip: '127.0.0.1',
            port: 17890,
            token: 't',
          ).withLastSyncAt(1700000000000),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 过了前两关，队列的空才有话语权（这就是原来那条断言的正确位置）
    expect(find.text('已同步'), findsOneWidget);
    expect(find.text('尚未连接电脑'), findsNothing);
  });

  // ============================================ #46（2026-10-14 外测 M01）

  /// #46 夹具：**备份接线全接上**（按钮 / 提醒 / 状态行 / 导出都给非空）
  /// —— 故意接满，才能证明「手机壳把备份断掉」是装配层的门起作用，
  /// 而不是夹具本来就没接（断言咬住的是门，不是空参数）。
  ///
  /// ⚠️ 手机分支必须套 **`MobileShell`**：底部导航（含「我的」）长在它身上，
  /// 直接把 `AppShell` 当 home 就没有「我的」可点（首跑踩过）。
  /// #47 丁 夹具：**真镜像 + 真配对 + 1 条挂起条目**。
  ///
  /// 配对带 `lastSyncAt`（⇒ linked，`_showDetail` 不走「怎么连电脑」提示）；
  /// 传输用 `_HangingTransport`（永不完成 ⇒ 重试后「正在推送中」是确定状态）。
  (MobileSyncService, String) wiredSync() {
    final MobileSyncService sync = MobileSyncService(
      mirrorPath: p.join(box.path, 'mirror', 'mirror.db'),
      pairingStore: PairingStore(File(p.join(box.path, 'pairing.json'))),
      transport: _HangingTransport(),
    );
    sync.pairingStore.save(
      const PairingInfo(
        hostId: 'h1',
        ip: '127.0.0.1',
        port: 17890,
        token: 'tok-test',
      ).withLastSyncAt(DateTime.now().millisecondsSinceEpoch),
    );
    final SyncQueueDao dao = SyncQueueDao(sync.openMirror());
    final SyncQueueEntry entry = dao.enqueue(
      SyncQueueEntry.create(
        SyncOperation(
          entity: Schema.documents,
          entityId: 'd-held-1',
          operation: SyncOpType.createDocument,
          payload: <String, Object?>{
            'document': <String, Object?>{'id': 'd-held-1', 'doc_type': 'sale'},
            'lines': <Object?>[],
          },
        ),
        now: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    dao.markHeld(entry.id, reason: '这条单是在连接上一台主机时开的（主机 旧店电脑）');
    return (sync, entry.id); // ⚠️ 队列 id 是 create 生成的 uuid，不是 entityId
  }

  Widget syncWiredPage(MobileSyncService sync) => MaterialApp(
    home: MobileShell(
      shell: AppShell(
        dataDirectory: box.path,
        backupDirectory: p.join(box.path, 'backup'),
        schemaVersion: 3,
        databaseReady: true,
        configStore: store,
        onConfigChanged: (AppConfig config) {},
        masterDataPolicy: const MasterDataPolicy.desktop(),
        mobileSync: sync,
      ),
    ),
  );

  Widget backupWiredPage({required bool mobileShell}) {
    final AppShell shell = AppShell(
      dataDirectory: '/tmp/data',
      backupDirectory: '/tmp/backup',
      schemaVersion: 3,
      databaseReady: true,
      configStore: store,
      onConfigChanged: (AppConfig config) {},
      masterDataPolicy: const MasterDataPolicy.desktop(),
      mobileShell: mobileShell,
      // 手机真机上它是非空（§BH·五 B1b：私有目录友好文案）——
      // 概览的「你的数据在」卡走手机分支，不再显示「备份会放在旁边」那行
      dataLocationNote: '数据存在手机的应用私有目录里',
      backupReminder: '已 5 天没备份',
      backupStatusLine: '上次备份：2026-10-14 08:00',
      backupNeedsAttention: true,
      onBackupNow: () async => const BackupOutcome.failure('不应被调到'),
      onExportBackup: () async => '导出成功',
    );
    return MaterialApp(home: mobileShell ? MobileShell(shell: shell) : shell);
  }

  testWidgets('#46：手机不给「立即备份」—— 数据安全出口是「导出本机数据文件」', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(backupWiredPage(mobileShell: true));

    // 初始 tab = 概览：橙卡（提醒）与按钮整块不出现
    expect(find.text('立即备份'), findsNothing);
    expect(find.text('已 5 天没备份'), findsNothing, reason: '提醒随门一起断 ⇒ 橙卡整块消失');

    // 我的 → 设置：备份区不出现；「导出本机数据文件」不许被一起藏掉
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(
      find.text('立即备份'),
      findsNothing,
      reason: '手机主库是空壳，备份它 = 假安全（既有裁定：手机不叫「备份」）',
    );
    expect(find.textContaining('上次备份'), findsNothing);
    expect(
      find.text('导出本机数据文件'),
      findsOneWidget,
      reason: '手机真正的数据安全出口 —— 打包镜像库 + 主库 + 未同步单据清单',
    );
  });

  testWidgets('#46 反向：桌面壳（mobileShell=false）照常显示「立即备份」', (
    WidgetTester tester,
  ) async {
    // 同一份接线，只把 mobileShell 关掉 ⇒ 桌面零变化
    await tester.pumpWidget(backupWiredPage(mobileShell: false));
    expect(find.text('立即备份'), findsOneWidget);
    expect(find.text('已 5 天没备份'), findsOneWidget);
  });

  // ===== #47 丁（2026-10-16 裁定）：队列明细的「重试 / 放弃」双出口 =====
  //
  // 用**真镜像 + 真配对 + 真 DAO**（不是摆放层的空壳）—— 这两条要穿过
  // `_showDetail` 的 linked 门、真三态计数与真数据库写入。
  testWidgets('#47 丁：挂起条目显示双出口；放弃 ⇒ 条目删除、三态条归零', (WidgetTester tester) async {
    final (MobileSyncService sync, String queueId) = wiredSync();
    await tester.pumpWidget(syncWiredPage(sync));
    await tester.pumpAndSettle();

    await tester.tap(find.text('失败 1 条'));
    await tester.pumpAndSettle();

    // 双出口并列（裁定丁：不预设用户意图）；挂起原因如实显示
    expect(find.text('重试，发给现在这台电脑'), findsOneWidget);
    expect(find.text('放弃，不发送'), findsOneWidget);
    expect(find.textContaining('这条单是在连接上一台主机时开的'), findsOneWidget);

    // 放弃（不可逆）⇒ 必须确认
    await tester.tap(find.text('放弃，不发送'));
    await tester.pumpAndSettle();
    expect(find.text('放弃这张单，不再发送？'), findsOneWidget);
    await tester.tap(find.text('先不放弃'));
    await tester.pumpAndSettle();
    expect(
      SyncQueueDao(sync.openMirror()).findById(queueId),
      isNotNull,
      reason: '先不放弃 ⇒ 条目原样保留',
    );

    await tester.tap(find.text('放弃，不发送'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();

    expect(
      SyncQueueDao(sync.openMirror()).findById(queueId),
      isNull,
      reason: '放弃 ⇒ 条目删除（快路径裁定；discarded 登记待办）',
    );
    expect(find.text('已同步'), findsWidgets, reason: '队列空了 ⇒ 三态条归零');
  });

  testWidgets('#47 丁：重试 ⇒ 回到待同步（发给现在这台电脑，语义在对话里讲清）', (
    WidgetTester tester,
  ) async {
    final (MobileSyncService sync, String queueId) = wiredSync();
    await tester.pumpWidget(syncWiredPage(sync));
    await tester.pumpAndSettle();

    await tester.tap(find.text('失败 1 条'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试，发给现在这台电脑'));
    await tester.pumpAndSettle();

    // 语义讲清（裁定丁：二次确认挡不住跨店错误，理解语义才能）
    expect(find.text('把这张单发给现在这台电脑？'), findsOneWidget);
    expect(find.textContaining('另一家店'), findsOneWidget);

    await tester.tap(find.text('发给这台电脑'));
    await tester.pumpAndSettle();

    // _HangingTransport 永不返回 ⇒ 推送进行中，条目停在 pending（确定性断言）
    final SyncQueueEntry? entry = SyncQueueDao(
      sync.openMirror(),
    ).findById(queueId);
    expect(entry, isNotNull);
    expect(
      entry!.status,
      SyncQueueStatus.pending,
      reason: '重试 ⇒ requeue 放回队列（正在推送中）',
    );
    expect(find.textContaining('待同步 1 条'), findsWidgets);
  });

  // ============================== F16 提案的**反证** + 回归护栏（2026-10-26）
  //
  // 背景：真机两次看到「同步成功后徽标仍写待同步，切走再回来才对」。
  // 提案（`docs/proposals/F16-同步徽标不刷新-方案.md`）当时判断根因是：
  // 「`_openFull` 推的路由闭包捕获了 push 那一刻的 `widget.shell`，
  //   加上 `_ModalScopeState._page` 缓存 ⇒ 徽标永远拿着旧实例」。
  //
  // **这条测试把它反证了。** 实测：队列清空 + 换新 `AppShell` 之后，
  // 整屏页上的徽标**当场**就变成「已同步」（`skipOffstage: false` 数到
  // 两个「已同步」：tab 一个、整屏页一个；「待同步」零个）。
  //
  // 为什么提案判断错了：闭包捕获的是 **`_MobileShellState` 这个 `State` 对象**，
  // 而 `widget` 是 `State` 上的**可变字段** —— `didUpdateWidget` 之后它已经指向
  // 新的 `MobileShell`，所以 `widget.shell` 读到的是**当前**实例，不是 push 时那个。
  // （`_page` 缓存确实存在，`routes.dart:1085`；但 `pumpWidget` 换根会触发
  //  `didChangeDependencies` 把它清掉，路由随之重建。）
  //
  // ⇒ 真机那条现象的根因**还没找到**，得回去取时间戳/日志，不许照着错根因改。
  // 这条测试留作**护栏**：整屏页的徽标必须跟着壳刷新。
  testWidgets('F16 反证：整屏页（设置）上的徽标会跟着壳刷新', (WidgetTester tester) async {
    final Directory syncBox = Directory.systemTemp.createTempSync(
      'shensuanzi_f16_',
    );
    addTearDown(() {
      try {
        syncBox.deleteSync(recursive: true);
      } catch (_) {
        // 镜像库可能还开着 —— 删不掉不影响结论
      }
    });

    final MobileSyncService sync = syncServiceIn(
      syncBox,
      pairing: PairingInfo.fromPayload(
        hostId: 'h1',
        ip: '127.0.0.1',
        port: 17890,
        token: 't',
      ).withLastSyncAt(1700000000000),
    );

    // 队列里放一条待同步的单 ⇒ 徽标「待同步 1 条」
    final Db mirror = sync.openMirror();
    final SyncQueueDao queue = SyncQueueDao(mirror);
    queue.enqueue(
      SyncQueueEntry(
        id: 'q-f16',
        entity: Schema.documents,
        entityId: 'd-f16',
        operation: SyncOpType.createDocument,
        payload: <String, Object?>{
          'document': <String, Object?>{'id': 'd-f16', 'doc_type': 'sale'},
          'lines': <Object?>[
            <String, Object?>{'product_id': 'p1', 'quantity': 1},
          ],
        },
        createdAt: 1700000000000,
      ),
    );

    await tester.pumpWidget(shellWith(sync));
    await tester.pumpAndSettle();
    expect(find.textContaining('待同步 1 条'), findsOneWidget, reason: '前提');

    // 进「我的 → 设置」—— 设置是 `_openFull` 推的**整屏页**，三态条也在里面
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('待同步 1 条'),
      findsOneWidget,
      reason: '整屏页上也有一条三态条（裁定 ②：用户是在这里开单的）',
    );

    // 模拟「同步完成」：队列清空
    queue.delete('q-f16');

    // 模拟 app `setState`：换一个**新的** AppShell 实例（同一棵树，State 保留）
    await tester.pumpWidget(shellWith(sync));
    await tester.pumpAndSettle();

    expect(
      find.text('已同步'),
      findsOneWidget,
      reason: 'F16：整屏页的徽标必须跟着换 —— 不许等到"退出去再进来"',
    );
    expect(find.textContaining('待同步'), findsNothing);
  });
}

/// 永不完成的传输桩 —— 重试用例里让「正在推送」成为**确定性状态**。
class _HangingTransport implements Transport {
  @override
  Future<TransportResponse> send(TransportRequest request) =>
      Completer<TransportResponse>().future;
}
