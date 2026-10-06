// 手机端同步服务（`MobileSyncService`）的集成测试 —— §BL·二。
//
// 与 `backup_test.dart` 同款「真实文件」思路，更进一步：**起一个真实的
// `HttpServer` 当假主机**（127.0.0.1 随机端口）—— HttpTransport 的
// 显式 utf8、超时映射、401 分支，全是真循环里才验得出来的东西。
//
// 运行：`dart test`（本机由用户执行）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

/// 假主机：可编程的 health / pull / push 响应
class FakeHost {
  FakeHost() {
    unawaited(_start());
  }

  HttpServer? _server;
  Map<String, Object?> healthBody = <String, Object?>{
    'ok': true,
    'api_version': 1,
    'schema_version': Schema.version,
    'server_time': DateTime.now().millisecondsSinceEpoch,
  };
  Map<String, Object?> pullBody = <String, Object?>{
    'documents': <Object?>[],
    'document_lines': <Object?>[],
    'stock_ledger': <Object?>[],
    'money_ledger': <Object?>[],
    'party_ledger': <Object?>[],
    'settlements': <Object?>[],
    'products': <Object?>[],
    'parties': <Object?>[],
    'accounts': <Object?>[],
    'next_cursors': <String, String>{},
  };
  int healthStatus = 200;
  int pullStatus = 200;
  int pushStatus = 200;

  /// push 请求计数 + 可编程延迟（autoPush 并发/尾随测试用，B3a）
  int pushRequests = 0;
  Duration pushDelay = Duration.zero;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server!.port}');

  Future<void> _start() async {
    final HttpServer server = await HttpServer.bind('127.0.0.1', 0);
    _server = server;
    // listen 返回订阅（不是 Future）—— 服务生命周期 = 进程，不单独管理
    server.listen((HttpRequest request) async {
        final String path = request.uri.path;
        int status = 200;
        Object? body;
        if (path == '/api/health') {
          status = healthStatus;
          body = healthBody;
        } else if (path == '/api/sync/pull') {
          status = pullStatus;
          body = pullBody;
        } else if (path == '/api/sync/push') {
          pushRequests++;
          await Future<void>.delayed(pushDelay);
          status = pushStatus;
          body = <String, Object?>{'results': <Object?>[]};
          await request.drain<void>();
        } else {
          status = 404;
        }
        final HttpResponse response = request.response;
        response.statusCode = status;
        response.headers.contentType = ContentType.json;
        response.add(utf8.encode(jsonEncode(body)));
        await response.close();
      });
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}

void main() {
  useLocalSqlite();

  late Directory box;
  late FakeHost host;
  late File pairingFile;
  late String mirrorPath;
  late MobileSyncService service;

  setUp(() async {
    box = Directory.systemTemp.createTempSync('shensuanzi_sync_');
    pairingFile = File(p.join(box.path, 'pairing.json'));
    mirrorPath = p.join(box.path, 'mirror', 'shensuanzi_mirror.db');
    host = FakeHost();
    await Future<void>.delayed(const Duration(milliseconds: 20)); // 等 bind
    service = MobileSyncService(
      mirrorPath: mirrorPath,
      pairingStore: PairingStore(pairingFile),
    );
  });

  tearDown(() async {
    await host.close();
    try {
      box.deleteSync(recursive: true);
    } catch (_) {
      // 删不掉不影响结论
    }
  });

  test('未配对 ⇒ notPaired（不动镜像库）', () async {
    final SyncOutcome outcome = await service.syncNow();
    expect(outcome.kind, SyncOutcomeKind.notPaired);
    expect(File(mirrorPath).existsSync(), isFalse, reason: '没配对就不该建库');
  });

  test('扫码配对（pairFromCode）→ 同步成功 → 镜像里有数据、lastSync 落盘', () async {
    host.pullBody['products'] = <Object?>[
      <String, Object?>{
        'id': 'p1', 'code': 'P0001', 'name': '蒙牛纯牛奶', 'unit': '瓶',
        'cost_price': 250, 'sell_price': 350, 'safety_stock': 0,
        'is_active': 1, 'created_at': 1, 'updated_at': 1,
      },
    ];
    host.pullBody['next_cursors'] = <String, String>{
      'documents': '2026-10-05 00:00:00',
    };

    // 扫码（解析 + 落 pairing.json）
    final PairingInfo info = service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    expect(info.ip, '127.0.0.1');

    final SyncOutcome outcome = await service.syncNow();
    expect(outcome.kind, SyncOutcomeKind.ok, reason: outcome.message);
    expect(outcome.message, contains('1'));

    // 镜像里有商品（中文没有乱码 —— 显式 utf8 的回归面）
    final Db mirror = service.openMirror();
    expect(
      mirror.raw.select('SELECT name FROM products').first['name'],
      '蒙牛纯牛奶',
    );
    // 游标原样保存
    expect(
      mirror.raw
          .select("SELECT cursor FROM sync_cursor WHERE entity = 'documents'")
          .first['cursor'],
      '2026-10-05 00:00:00',
    );
    // lastSync 落盘
    final PairingInfo saved = PairingStore(pairingFile).load()!;
    expect(saved.lastSyncAt, isNotNull);
  });

  test('连不上（端口没人听）⇒ unreachable，文案含「怎么办」', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=1&token=tok&v=1',
    );
    final SyncOutcome outcome = await service.syncNow();
    expect(outcome.kind, SyncOutcomeKind.unreachable);
    expect(outcome.message, contains('同一个 Wi-Fi'));
  });

  test('health 401 ⇒ authExpired（配对失效，裁定 ②）', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    host.healthStatus = 401;

    final SyncOutcome outcome = await service.syncNow();
    expect(outcome.kind, SyncOutcomeKind.authExpired);
    expect(outcome.message, contains('重新扫码'));

    // 忘记主机 = 清 pairing.json
    service.forgetHost();
    expect(PairingStore(pairingFile).load(), isNull);
  });

  test('pull 401 ⇒ authExpired（任何请求都算）', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    host.pullStatus = 403;

    final SyncOutcome outcome = await service.syncNow();
    expect(outcome.kind, SyncOutcomeKind.authExpired);
  });

  test('主机 schema 版本更高 ⇒ 重建镜像（游标清零从头拉，裁定 §六）', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    // 第一次同步：镜像到 v3、游标有值
    await service.syncNow();
    final Db mirror = service.openMirror();
    expect(mirror.schemaVersion, Schema.version);

    // 主机升级了
    host.healthBody['schema_version'] = Schema.version + 1;
    host.pullBody['products'] = <Object?>[
      <String, Object?>{
        'id': 'p2', 'code': 'P0002', 'name': '可乐', 'unit': '瓶',
        'cost_price': 200, 'sell_price': 300, 'safety_stock': 0,
        'is_active': 1, 'created_at': 1, 'updated_at': 1,
      },
    ];

    final SyncOutcome outcome = await service.syncNow();
    expect(outcome.kind, SyncOutcomeKind.ok);
    expect(outcome.rebuilt, isTrue, reason: outcome.message);
    // 重建后从头拉：新数据在、旧游标被主机初始游标覆盖
    expect(
      mirror.raw.select('SELECT name FROM products').first['name'],
      '可乐',
    );
  });

  // ================================================ 自动推送（B3a·裁定 ③）

  /// 往镜像队列塞一条 `createDocument` 条目（autoPush 的推送对象）
  void enqueueOne(String id) {
    SyncQueueDao(service.openMirror()).enqueue(
      SyncQueueEntry(
        id: id,
        entity: 'documents',
        entityId: 'd-$id',
        operation: SyncOpType.createDocument,
        createdAt: 1700000000000,
      ),
    );
  }

  Future<void> waitFor(bool Function() cond) async {
    final Stopwatch sw = Stopwatch()..start();
    while (!cond()) {
      if (sw.elapsed > const Duration(seconds: 5)) {
        throw StateError('waitFor 超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('autoPush 未配对 ⇒ notPaired（不开镜像库）', () async {
    final SyncOutcome outcome = await service.autoPush();
    expect(outcome.kind, SyncOutcomeKind.notPaired);
    expect(File(mirrorPath).existsSync(), isFalse);
    expect(host.pushRequests, 0);
  });

  test('autoPush 队列为空 ⇒ ok 且**不发** push 请求', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    final SyncOutcome outcome = await service.autoPush();
    expect(outcome.kind, SyncOutcomeKind.ok, reason: outcome.message);
    expect(host.pushRequests, 0, reason: '没有到期条目就不该打主机');
  });

  test('autoPush 有待同步条目 ⇒ push 请求发出 ⇒ ok（失败也不抛）', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    enqueueOne('q-1');
    // 假主机回 results: [] ⇒ 无回执 ⇒ 排重试 —— 但 push 本身完成 ⇒ ok
    final SyncOutcome outcome = await service.autoPush();
    expect(outcome.kind, SyncOutcomeKind.ok, reason: outcome.message);
    expect(host.pushRequests, 1);
  });

  test('autoPush 并发：第二次 busy；第一轮结束后**尾随补推**（裁定 ③）', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    enqueueOne('q-1');
    host.pushDelay = const Duration(milliseconds: 300);

    final Future<SyncOutcome> first = service.autoPush();
    final SyncOutcome second = await service.autoPush();
    expect(second.kind, SyncOutcomeKind.error, reason: second.message);
    expect(second.message, contains('补推'));

    // 裁定 ③ 的原文场景：**推送中再有新单入队** —— 趁第一轮在途塞进 q-2。
    // （q-1 没拿到回执会进 1s 退避 ⇒ 尾随这轮推的是**到期的 q-2**。）
    enqueueOne('q-2');

    final SyncOutcome firstOutcome = await first;
    expect(firstOutcome.kind, SyncOutcomeKind.ok, reason: firstOutcome.message);
    expect(host.pushRequests, 1);

    // 尾随：第一轮结束后自动再推一次（连接开三单 = 两轮请求的约定）
    await waitFor(() => host.pushRequests >= 2);
  });
}
