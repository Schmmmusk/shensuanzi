// 手机端「手动填地址」的 widget 测试（2026-10-25 D 批）。
//
// 背景：电脑自动挑网卡挑到了穿透工具的地址（`natpierce` 10.6.22.1），
// 二维码扫得到、手机连不上；而扫码页从前**只有扫码、零兜底**。
//
// 这一层只钉「摆放 + 校验反馈」：格式错的提示必须留在对话框里（用户能当场改），
// 配对写盘由 `packages/shensuanzi_app/test/pairing_address_test.dart` 覆盖。
// ⚠️ `ManualAddressDialog` **刻意不联网**（首拉由页面做）—— 否则在 `testWidgets`
// 的假时钟下会等不到真实 HTTP 回调，直接卡死。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/pairing_scan_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

void main() {
  setUpAll(useLocalSqlite);

  late Directory box;
  late PairingStore store;
  late MobileSyncService service;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_manual_');
    store = PairingStore(File(p.join(box.path, 'pairing.json')));
    service = MobileSyncService(
      mirrorPath: p.join(box.path, 'mirror', 'shensuanzi_mirror.db'),
      pairingStore: store,
    );
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 镜像可能还开着 —— 删不掉不影响结论
    }
  });

  /// 把对话框开起来，并把 `showDialog` 的返回值接出来
  Future<bool? Function()> openDialog(WidgetTester tester) async {
    bool? result;
    bool closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                result = await showDialog<bool>(
                  context: context,
                  builder: (BuildContext _) =>
                      ManualAddressDialog(service: service),
                );
                closed = true;
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return () => closed ? result : null;
  }

  testWidgets('扫码页有「手动填地址」入口（零兜底 → 有兜底）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: PairingScanPage(service: service)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('pairing-manual-entry')),
      findsOneWidget,
      reason: '扫码失败时用户必须有别的路可走',
    );
    expect(find.textContaining('手动填地址'), findsOneWidget);
  });

  testWidgets('格式不对 ⇒ 红字留在对话框里，配对没被改', (WidgetTester tester) async {
    final bool? Function() result = await openDialog(tester);

    await tester.enterText(
      find.byKey(const Key('manual-address-field')),
      'my-pc:17890',
    );
    await tester.tap(find.byKey(const Key('manual-address-ok')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('不能填电脑名'),
      findsOneWidget,
      reason: '提示要说清"为什么不行"，不能只说"格式错误"',
    );
    expect(
      find.byType(ManualAddressDialog),
      findsOneWidget,
      reason: '格式错不许把对话框关掉 —— 用户要能当场改',
    );
    expect(result(), isNull, reason: '没配对成功就不该回传 true');
    expect(store.load(), isNull, reason: '填错了不能凭空造一份配对出来');
  });

  testWidgets('没配对过就只填地址 ⇒ 说清「还缺配对令牌」', (WidgetTester tester) async {
    await openDialog(tester);

    await tester.enterText(
      find.byKey(const Key('manual-address-field')),
      '192.168.1.5:17890',
    );
    await tester.tap(find.byKey(const Key('manual-address-ok')));
    await tester.pumpAndSettle();

    expect(find.textContaining('还没连过电脑'), findsOneWidget);
    // ⚠️ 不能只断言「配对码」三个字：对话框里那段常驻说明也含它（会数到 2 个）
    expect(
      find.textContaining('光填地址不够'),
      findsOneWidget,
      reason: '要告诉用户下一步怎么办（去扫码 / 粘整段配对码）',
    );
    expect(find.byType(ManualAddressDialog), findsOneWidget);
  });

  testWidgets('配对过 + 地址合法 ⇒ 对话框关闭，只把地址换掉', (WidgetTester tester) async {
    // 先「扫」一次码（现场就是这一步拿到了令牌，只是 IP 是穿透网卡的）
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=10.6.22.1&port=17890&token=tok&v=1',
    );
    final bool? Function() result = await openDialog(tester);

    await tester.enterText(
      find.byKey(const Key('manual-address-field')),
      '10.102.43.94:17890',
    );
    await tester.tap(find.byKey(const Key('manual-address-ok')));
    await tester.pumpAndSettle();

    expect(
      find.byType(ManualAddressDialog),
      findsNothing,
      reason: '配对成功 ⇒ 关掉对话框，让页面去首拉',
    );
    expect(result(), isTrue);
    final PairingInfo saved = store.load()!;
    expect(saved.ip, '10.102.43.94');
    expect(saved.port, 17890);
    expect(saved.hostId, 'h-1', reason: '还是同一台电脑 —— 换的是路，不是身份');
    expect(saved.token, 'tok', reason: '令牌必须留着，否则鉴权过不去');
  });
}
