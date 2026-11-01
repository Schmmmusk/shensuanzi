// 手机端「用 6 位配对码」对话框（提案 58 · A4 乙，2026-11-01 用户裁定）。
//
// 这一层只钉「摆放 + 交互」：文案改对了没有、等电脑确认时用户看得到看不到、
// 电脑回错时红字留不留得住。真正的网络协议在
// `packages/shensuanzi_app/test/short_code_pairing_test.dart`。
//
// ⚠️ 传输层是**注入的假实现**：`testWidgets` 跑在假时钟下，真 socket 的回调
// 等不到（本仓踩过：实测卡死 4 分 54 秒）。假传输是纯 Future，配合
// `tester.pump(Duration(...))` 就能把「轮询两轮后批准」这条时间线走完。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shensuanzi/src/ui/pairing_scan_page.dart';
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';

/// 按路径回放响应的假传输
class _FakeTransport implements Transport {
  _FakeTransport(this.handler);

  final TransportResponse Function(TransportRequest request) handler;
  final List<TransportRequest> sent = <TransportRequest>[];

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    sent.add(request);
    return handler(request);
  }
}

const String _pairingCode =
    'shensuanzi://pair?host_id=host-a&ip=192.168.1.5&port=17890&token=tok-a&v=1';

TransportResponse _ok(String body) =>
    TransportResponse(statusCode: 200, body: body);

TransportResponse _fail(int status, String body) =>
    TransportResponse(statusCode: status, body: body);

void main() {
  setUpAll(useLocalSqlite);

  late Directory box;
  late PairingStore store;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_short_code_dialog_');
    store = PairingStore(File(p.join(box.path, 'pairing.json')));
  });

  tearDown(() {
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 镜像可能还开着 —— 删不掉不影响结论
    }
  });

  MobileSyncService serviceWith(Transport transport) => MobileSyncService(
    mirrorPath: p.join(box.path, 'mirror', 'shensuanzi_mirror.db'),
    pairingStore: store,
    transport: transport,
  );

  /// 打开对话框，返回「有没有关掉、关掉时的返回值」
  Future<bool? Function()> openDialog(
    WidgetTester tester,
    MobileSyncService service,
  ) async {
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

  /// 填两栏并点「连接」
  Future<void> fillAndSubmit(
    WidgetTester tester, {
    String address = '192.168.1.5:17890',
    String code = '482913',
  }) async {
    await tester.enterText(
      find.byKey(const Key('manual-address-field')),
      address,
    );
    await tester.enterText(
      find.byKey(const Key('pairing-short-code-field')),
      code,
    );
    await tester.tap(find.byKey(const Key('manual-address-ok')));
    await tester.pump();
  }

  testWidgets('对话框有「6 位配对码」这一栏，且说清去电脑上哪一屏找', (WidgetTester tester) async {
    final MobileSyncService service = serviceWith(
      _FakeTransport((TransportRequest _) => _ok('{}')),
    );
    await openDialog(tester, service);

    expect(
      find.byKey(const Key('pairing-short-code-field')),
      findsOneWidget,
      reason: 'A4 的核心：6 位码必须有地方输',
    );
    expect(find.textContaining('用 6 位配对码连接'), findsOneWidget);
  });

  testWidgets('等电脑确认时明说「请在电脑上点允许」，批准后对话框关闭', (WidgetTester tester) async {
    int polls = 0;
    final _FakeTransport wire = _FakeTransport((TransportRequest request) {
      if (request.method == 'POST') {
        return _ok('{"request_id":"0123456789abcdef","status":"awaiting"}');
      }
      polls++;
      if (polls == 1) return _ok('{"status":"awaiting"}');
      return _ok('{"status":"approved","pairing_code":"$_pairingCode"}');
    });
    final MobileSyncService service = serviceWith(wire);
    final bool? Function() result = await openDialog(tester, service);

    await fillAndSubmit(tester);
    await tester.pump();

    expect(
      find.byKey(const Key('pairing-waiting')),
      findsOneWidget,
      reason: '等待期必须告诉用户「去电脑上点允许」，否则他只会以为卡住了',
    );
    expect(find.textContaining('请在电脑上点「允许」'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed,
      isNull,
      reason: '请求已经发出去了，中途撤掉会在电脑上留一条没人认领的待确认',
    );

    // 第一轮 awaiting ⇒ 等 2 秒再问；第二轮 approved
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byType(ManualAddressDialog), findsNothing);
    expect(result(), isTrue);
    final PairingInfo saved = store.load()!;
    expect(saved.hostId, 'host-a');
    expect(saved.token, 'tok-a');
    expect(
      wire.sent.where((TransportRequest r) => r.method == 'POST').length,
      1,
      reason: '重试也不能重复建请求（会多出一条待确认）',
    );
  });

  testWidgets('电脑说码不对 ⇒ 红字留在对话框里，配对没被改', (WidgetTester tester) async {
    final _FakeTransport wire = _FakeTransport(
      (TransportRequest _) =>
          _fail(400, '{"error":"配对码不对，请在电脑上再看一眼那 6 位数字。","remaining":4}'),
    );
    final bool? Function() result = await openDialog(tester, serviceWith(wire));

    await fillAndSubmit(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('再看一眼那 6 位数字'), findsOneWidget);
    expect(
      find.byType(ManualAddressDialog),
      findsOneWidget,
      reason: '错一次就把对话框关掉，用户得从头再来一遍',
    );
    expect(result(), isNull);
    expect(store.load(), isNull);
  });

  testWidgets('码不是 6 位 ⇒ 当场说清，不发请求（不浪费一次试错机会）', (WidgetTester tester) async {
    final _FakeTransport wire = _FakeTransport(
      (TransportRequest _) => _ok('{}'),
    );
    await openDialog(tester, serviceWith(wire));

    await fillAndSubmit(tester, code: '4829');
    await tester.pumpAndSettle();

    expect(find.textContaining('6 位数字'), findsWidgets);
    expect(wire.sent, isEmpty, reason: '少一位就发出去，等于白烧一次限次机会');
  });

  testWidgets('配对过的手机：地址自动预填，只需要输 6 位码', (WidgetTester tester) async {
    store.save(
      const PairingInfo(
        hostId: 'host-a',
        ip: '10.102.43.94',
        port: 17891,
        token: 'tok-old',
      ),
    );
    final _FakeTransport wire = _FakeTransport(
      (TransportRequest request) => request.method == 'POST'
          ? _ok('{"request_id":"abc","status":"awaiting"}')
          : _ok('{"status":"approved","pairing_code":"$_pairingCode"}'),
    );
    await openDialog(tester, serviceWith(wire));

    final TextField address = tester.widget<TextField>(
      find.byKey(const Key('manual-address-field')),
    );
    expect(
      address.controller!.text,
      '10.102.43.94:17891',
      reason: '地址照抄一遍纯属折腾（端口还可能不是默认的 17890）',
    );

    await tester.enterText(
      find.byKey(const Key('pairing-short-code-field')),
      '482913',
    );
    await tester.tap(find.byKey(const Key('manual-address-ok')));
    await tester.pumpAndSettle();

    expect(find.byType(ManualAddressDialog), findsNothing);
    expect(
      wire.sent.first.uri.toString(),
      contains('10.102.43.94:17891'),
      reason: '用的必须是预填的那个地址',
    );
  });

  testWidgets('特大字号下两栏与按钮都还在（2.0 档不溢出）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1220, 2712);
    tester.view.devicePixelRatio = 3.1;
    addTearDown(tester.view.reset);

    final MobileSyncService service = serviceWith(
      _FakeTransport((TransportRequest _) => _ok('{}')),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (BuildContext _) =>
                    ManualAddressDialog(service: service),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('manual-address-ok')), findsOneWidget);
    expect(find.byKey(const Key('pairing-short-code-field')), findsOneWidget);
  });
}
