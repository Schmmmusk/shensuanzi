// 手机端「6 位短码配对」（提案 58 · A4 乙，2026-11-01 用户裁定）。
//
// 用户裁定的原话：「6 位数字短码不是普通验证码，它实际上是一个临时配对凭据」。
// 这一层盯的是**手机这半条链路**：
//
//   ① 发出去的请求长什么样（码 + 设备名，且不许把全角数字发上去）；
//   ② 电脑回了各种结果时，用户看到的是哪句话（每句都要说「怎么办」）；
//   ③ 批准之后**必须**走 `pairFromCode` 落盘 —— 身份切换 / 镜像归档的判据都在那里。
//
// 主机那半条（限次、一次性、不串号）见 `packages/shensuanzi_host/test/pair_requests_test.dart`。
//
// 运行：`dart test`（本机由用户执行）
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

/// 可编排的传输层：按请求路径回放响应，并把发出去的请求留下来供断言。
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

String _pairingCode({
  String hostId = 'host-a',
  String ip = '192.168.1.5',
  int port = 17890,
  String token = 'tok-a',
}) => 'shensuanzi://pair?host_id=$hostId&ip=$ip&port=$port&token=$token&v=1';

void main() {
  setUpAll(useLocalSqlite);

  late Directory box;
  late PairingStore store;

  setUp(() {
    box = Directory.systemTemp.createTempSync('shensuanzi_short_code_');
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

  /// 常规应答：POST 受理，轮询前 [awaitingRounds] 次 awaiting，然后 approved
  _FakeTransport approving({int awaitingRounds = 0, String? code}) {
    int polls = 0;
    return _FakeTransport((TransportRequest request) {
      if (request.method == 'POST' && request.uri.path == '/api/pair/request') {
        return const TransportResponse(
          statusCode: 200,
          body: '{"request_id":"0123456789abcdef","status":"awaiting"}',
        );
      }
      if (request.method == 'GET' && request.uri.path == '/api/pair/status') {
        polls++;
        if (polls <= awaitingRounds) {
          return const TransportResponse(
            statusCode: 200,
            body: '{"status":"awaiting"}',
          );
        }
        return TransportResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'status': 'approved',
            'pairing_code': code ?? _pairingCode(),
          }),
        );
      }
      return const TransportResponse(statusCode: 404, body: '{}');
    });
  }

  test('电脑批准 ⇒ 拿到身份并落盘（host_id / ip / port / 令牌都在）', () async {
    final _FakeTransport wire = approving();
    final MobileSyncService service = serviceWith(wire);

    final PairingInfo info = await service.pairFromShortCode(
      address: '192.168.1.5:17890',
      code: '482913',
      pollInterval: const Duration(milliseconds: 1),
    );

    expect(info.hostId, 'host-a');
    expect(info.ip, '192.168.1.5');
    expect(info.port, 17890);
    expect(info.token, 'tok-a');
    expect(store.load()!.hostId, 'host-a', reason: '必须落盘 —— 否则首拉拿不到令牌');
  });

  test('请求体带 6 位码与设备名；全角数字会被掰成半角', () async {
    final _FakeTransport wire = approving();
    await serviceWith(wire).pairFromShortCode(
      address: '192.168.1.5:17890',
      // 中文输入法打出来的全角数字（真机实测会发生）
      code: '４８２９１３',
      pollInterval: const Duration(milliseconds: 1),
    );

    final TransportRequest created = wire.sent.first;
    final Map<String, Object?> body = Map<String, Object?>.from(
      jsonDecode(created.body!) as Map<Object?, Object?>,
    );
    expect(body['code'], '482913', reason: '全角数字发出去就是「码不对」，白费一次机会');
    expect('${body['device_name']}', isNotEmpty, reason: '电脑上要能看出是哪台设备');
    expect(created.uri.path, '/api/pair/request');
    expect(created.uri.host, '192.168.1.5');
    expect(created.uri.port, 17890);
  });

  test('轮询期间一直 awaiting ⇒ 等到批准为止（不重复发 POST）', () async {
    final _FakeTransport wire = approving(awaitingRounds: 3);
    await serviceWith(wire).pairFromShortCode(
      address: '192.168.1.5:17890',
      code: '482913',
      pollInterval: const Duration(milliseconds: 1),
    );
    final int posts = wire.sent
        .where((TransportRequest r) => r.method == 'POST')
        .length;
    expect(posts, 1, reason: '重复 POST 会白白多建一条待确认请求');
  });

  test('电脑说码不对 ⇒ 原样展示它的「怎么办」', () async {
    final _FakeTransport wire = _FakeTransport(
      (TransportRequest _) => const TransportResponse(
        statusCode: 400,
        body: '{"error":"配对码不对，请在电脑上再看一眼那 6 位数字。","remaining":4}',
      ),
    );
    await expectLater(
      serviceWith(wire).pairFromShortCode(
        address: '192.168.1.5:17890',
        code: '482913',
        pollInterval: const Duration(milliseconds: 1),
      ),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('再看一眼那 6 位数字'),
        ),
      ),
    );
    expect(store.load(), isNull, reason: '没配对成功就不能凭空写一份凭据');
  });

  // ⚠️ 这两条盯的是「**别把电脑的话吞掉换成自己那句**」（2026-11-01 真机联调）：
  // 用户手动测「码放了 5 分钟再输」时，电脑说的是「过期了 / 换一个新码」，
  // 手机端如果显示成本地那句「配对码是电脑上显示的那 6 位数字」，
  // 用户会以为**自己抄错了**，然后一遍遍重抄同一个死码。
  test('电脑说「过期了」⇒ 原样展示，不许换成本地那句「6 位数字」', () async {
    final _FakeTransport wire = _FakeTransport(
      (TransportRequest _) => const TransportResponse(
        statusCode: 400,
        body: '{"error":"这个配对码过期了（只有 5 分钟）—— 请在电脑上点「换一个新码」。"}',
      ),
    );
    await expectLater(
      serviceWith(wire).pairFromShortCode(
        address: '192.168.1.5:17890',
        code: '482913',
        pollInterval: const Duration(milliseconds: 1),
      ),
      throwsA(
        isA<FormatException>()
            .having((FormatException e) => e.message, 'message', contains('过期'))
            .having(
              (FormatException e) => e.message,
              'message',
              isNot(contains('配对码是电脑上显示的那 6 位数字')),
            ),
      ),
    );
  });

  test('电脑说「已经被用掉了」⇒ 原样展示', () async {
    final _FakeTransport wire = _FakeTransport(
      (TransportRequest _) => const TransportResponse(
        statusCode: 409,
        body: '{"error":"这个码已经被用掉了 —— 请在电脑上点「换一个新码」。"}',
      ),
    );
    await expectLater(
      serviceWith(wire).pairFromShortCode(
        address: '192.168.1.5:17890',
        code: '482913',
        pollInterval: const Duration(milliseconds: 1),
      ),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('已经被用掉了'),
        ),
      ),
    );
  });

  test('电脑上点了拒绝 ⇒ 说清「谁点的」与「能不能再试」', () async {
    final _FakeTransport wire = _FakeTransport((TransportRequest request) {
      if (request.method == 'POST') {
        return const TransportResponse(
          statusCode: 200,
          body: '{"request_id":"0123456789abcdef","status":"awaiting"}',
        );
      }
      return const TransportResponse(
        statusCode: 200,
        body: '{"status":"denied"}',
      );
    });
    await expectLater(
      serviceWith(wire).pairFromShortCode(
        address: '192.168.1.5:17890',
        code: '482913',
        pollInterval: const Duration(milliseconds: 1),
      ),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('拒绝'),
        ),
      ),
    );
  });

  test('一直没人点允许 ⇒ 超时文案指向电脑上那一屏', () async {
    final _FakeTransport wire = _FakeTransport((TransportRequest request) {
      if (request.method == 'POST') {
        return const TransportResponse(
          statusCode: 200,
          body: '{"request_id":"0123456789abcdef","status":"awaiting"}',
        );
      }
      return const TransportResponse(
        statusCode: 200,
        body: '{"status":"awaiting"}',
      );
    });
    await expectLater(
      serviceWith(wire).pairFromShortCode(
        address: '192.168.1.5:17890',
        code: '482913',
        pollInterval: const Duration(milliseconds: 1),
        timeout: const Duration(milliseconds: 5),
      ),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          allOf(contains('没人点「允许」'), contains('多设备同步')),
        ),
      ),
    );
  });

  test('电脑端太旧（没有这两条路由）⇒ 明确让人去升级，而不是「连不上」', () async {
    final _FakeTransport wire = _FakeTransport(
      (TransportRequest _) =>
          const TransportResponse(statusCode: 404, body: ''),
    );
    await expectLater(
      serviceWith(wire).pairFromShortCode(
        address: '192.168.1.5:17890',
        code: '482913',
        pollInterval: const Duration(milliseconds: 1),
      ),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('版本太旧'),
        ),
      ),
    );
  });

  test('没配对过又没写端口 ⇒ 说清「要带上端口」', () async {
    final _FakeTransport wire = approving();
    await expectLater(
      serviceWith(wire).pairFromShortCode(
        address: '192.168.1.5',
        code: '482913',
        pollInterval: const Duration(milliseconds: 1),
      ),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('端口'),
        ),
      ),
    );
    expect(wire.sent, isEmpty, reason: '连地址都不全，不该发请求出去');
  });

  test('配对过的手机只填 IP ⇒ 沿用上次的端口', () async {
    store.save(
      const PairingInfo(
        hostId: 'host-a',
        ip: '10.0.0.9',
        port: 17891,
        token: 'tok-old',
      ),
    );
    final _FakeTransport wire = approving();
    await serviceWith(wire).pairFromShortCode(
      address: '192.168.1.5',
      code: '482913',
      pollInterval: const Duration(milliseconds: 1),
    );
    expect(wire.sent.first.uri.port, 17891);
  });

  test('不是 6 位数字 ⇒ 当场说清，不浪费一次试错机会', () async {
    final _FakeTransport wire = approving();
    await expectLater(
      serviceWith(wire).pairFromShortCode(
        address: '192.168.1.5:17890',
        code: '48291',
        pollInterval: const Duration(milliseconds: 1),
      ),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('6 位数字'),
        ),
      ),
    );
    expect(wire.sent, isEmpty);
  });

  test('批准的是另一台电脑 ⇒ 走 F14：镜像身份跟着换（不把旧店的货混进来）', () async {
    final _FakeTransport wire = approving(code: _pairingCode(hostId: 'host-b'));
    final MobileSyncService service = serviceWith(wire);
    // 镜像先属于 host-a（模拟「这台手机以前连的是另一台电脑」）
    MirrorMeta(service.openMirror()).writeHostId('host-a');

    await service.pairFromShortCode(
      address: '192.168.1.5:17890',
      code: '482913',
      pollInterval: const Duration(milliseconds: 1),
    );

    expect(MirrorMeta(service.openMirror()).hostId, 'host-b');
    expect(store.load()!.hostId, 'host-b');
  });
}
