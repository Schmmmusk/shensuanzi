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
      try {
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
          // ⚠️ 把请求体读干净（否则客户端等回执时会被自己的管道卡住）。
          // **客户端在收尾时断开是正常的**（`tearDown` 里 `close(force: true)`）
          // —— 那时这次 drain 会抛 `HttpException: Connection closed`，
          // 而它发生在**测试结束之后**，测试运行器会把它算到最后一个用例头上
          // （真实现象：整套跑红、单跑绿）。所以这类断开必须容忍。
          await request.drain<void>().catchError((Object _) {});
        } else {
          status = 404;
        }
        final HttpResponse response = request.response;
        response.statusCode = status;
        response.headers.contentType = ContentType.json;
        response.add(utf8.encode(jsonEncode(body)));
        await response.close();
      } catch (_) {
        // 收尾期的断开不影响任何断言（本文件断言的是「发了几次请求」）
      }
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
        'id': 'p1',
        'code': 'P0001',
        'name': '蒙牛纯牛奶',
        'unit': '瓶',
        'cost_price': 250,
        'sell_price': 350,
        'safety_stock': 0,
        'is_active': 1,
        'created_at': 1,
        'updated_at': 1,
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

    // P2 #8（2026-10-24）：认证失效由**服务自己**清配对，调用方不需要再点一次
    expect(
      PairingStore(pairingFile).load(),
      isNull,
      reason: 'P2 #8：401/403 ⇒ 清配对收进 MobileSyncService 一处',
    );
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
        'id': 'p2',
        'code': 'P0002',
        'name': '可乐',
        'unit': '瓶',
        'cost_price': 200,
        'sell_price': 300,
        'safety_stock': 0,
        'is_active': 1,
        'created_at': 1,
        'updated_at': 1,
      },
    ];

    final SyncOutcome outcome = await service.syncNow();
    expect(outcome.kind, SyncOutcomeKind.ok);
    expect(outcome.rebuilt, isTrue, reason: outcome.message);
    // 重建后从头拉：新数据在、旧游标被主机初始游标覆盖
    expect(mirror.raw.select('SELECT name FROM products').first['name'], '可乐');
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

  // P2 #8（业务审查 §3.7）：401/403 只在「立即同步」清配对 —— `autoPush`
  // （开单 / 建档成功后的后台推）不清 ⇒ 面板还显示「已连接」，后台每次
  // 推送都 401，用户看不到任何变化。清配对收进服务一处，三条路径共用。
  test('P2 #8：autoPush 遇 401 也清配对（不再只有「立即同步」清）', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    enqueueOne('q-auth');
    host.pushStatus = 401;

    final SyncOutcome outcome = await service.autoPush();

    expect(outcome.kind, SyncOutcomeKind.authExpired);
    expect(
      PairingStore(pairingFile).load(),
      isNull,
      reason: 'P2 #8：autoPush 的 401 也必须清配对（否则面板永远显示已连接）',
    );
  });

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

  // ============================================ 分页拉到底（2026-10-07 裁定）

  test('has_more 一直为真 ⇒ 不许说「同步完成」（如实报「只同步了一部分」）', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    // 主机永远说「还有下一页」—— 客户端有页数上限，必须**终止并如实上报**，
    // 既不能无限转圈，也不能假装拉完了（审查 #9 / Android 报告 ③）
    host.pullBody['has_more'] = true;

    final SyncOutcome outcome = await service.syncNow();

    expect(outcome.kind, SyncOutcomeKind.error, reason: outcome.message);
    expect(outcome.message, contains('只同步了一部分'));
  });

  test('has_more 缺省（旧主机）⇒ 当作到底，仍报成功', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    host.pullBody.remove('has_more'); // 旧主机不带这个字段

    final SyncOutcome outcome = await service.syncNow();

    expect(outcome.kind, SyncOutcomeKind.ok, reason: outcome.message);
    expect(outcome.message, contains('同步完成'));
  });

  // ================================== 换主机重置（2026-10-07 裁定 #3 / Android ②）

  test('扫到**另一台主机** ⇒ 重建镜像 + 挂起未同步队列', () async {
    // 先配 h-1 并同步一次（镜像里留下 h-1 的数据）
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    host.pullBody['products'] = <Object?>[
      <String, Object?>{
        'id': 'p-old',
        'code': 'P0009',
        'name': '旧主机的货',
        'unit': '瓶',
        'cost_price': 100,
        'sell_price': 200,
        'safety_stock': 0,
        'is_active': 1,
        'created_at': 1,
        'updated_at': 1,
      },
    ];
    await service.syncNow();
    final Db mirror = service.openMirror();
    expect(
      mirror.raw.select('SELECT COUNT(*) AS n FROM products').first['n'],
      1,
    );

    // 离线开了一单（还没推给 h-1）
    enqueueOne('q-offline');

    // 换主机：host_id 变了
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-2&ip=127.0.0.1&port=${host.baseUri.port}&token=tok2&v=1',
    );

    expect(
      mirror.raw.select('SELECT COUNT(*) AS n FROM products').first['n'],
      0,
      reason: '镜像必须清掉 —— 否则两台主机的数据混在一张表里',
    );
    expect(
      mirror.raw.select('SELECT COUNT(*) AS n FROM sync_cursor').first['n'],
      0,
      reason: '游标必须清零 —— 否则会从新主机的中间位置开始拉，前半截永远拉不到',
    );
    final List<SyncQueueEntry> left = SyncQueueDao(mirror).all();
    expect(left, hasLength(1), reason: '队列**不能删**（那是用户刚开的单）');
    expect(
      left.single.status,
      SyncQueueStatus.failed,
      reason: '挂起 ⇒ 不再自动推给新主机，等用户确认',
    );
    expect(left.single.lastError, contains('上一台主机'));
    expect(service.lastHostSwitchHeldEntries, 1);
  });

  // ============================================ F14：换主机必须**归档**（2026-10-25 裁定）
  //
  // 判定依据 = **镜像自己记的 hostId**（`mirror_meta`），不是 `pairing.json` ——
  // 「忘记这台主机」会删掉后者，旧实现据此跳过重建 ⇒ 旧镜像的商品编码与新主机
  // 撞车 ⇒ `UNIQUE constraint failed: products.code`，每次重试都必失败。

  int productRows() =>
      service
              .openMirror()
              .raw
              .select('SELECT COUNT(*) AS n FROM products')
              .first['n']!
          as int;

  String pairCode(String hostId, {String ip = '127.0.0.1'}) =>
      'shensuanzi://pair?host_id=$hostId&ip=$ip&port=${host.baseUri.port}'
      '&token=tok-$hostId&v=1';

  /// 镜像里放一个商品（模拟上一台主机拉下来的货）
  Future<void> syncOneProduct() async {
    host.pullBody['products'] = <Object?>[
      <String, Object?>{
        'id': 'p-old',
        'code': 'P0009',
        'name': '旧主机的货',
        'unit': '瓶',
        'cost_price': 100,
        'sell_price': 200,
        'safety_stock': 0,
        'is_active': 1,
        'created_at': 1,
        'updated_at': 1,
      },
    ];
    await service.syncNow();
    expect(productRows(), 1);
  }

  test('防呆① 同 IP、异 host_id ⇒ 必须归档 + 重建镜像', () async {
    service.pairFromCode(pairCode('h-1'));
    await syncOneProduct();

    // 同一个 IP / 端口，只有 host_id 变了（老王家和老李家都是 192.168.1.100）
    service.pairFromCode(pairCode('h-2'));

    expect(productRows(), 0, reason: '镜像必须重建，否则新主机推同编码会撞 UNIQUE');
    final List<MirrorArchiveEntry> archives = service.archive.list();
    expect(archives, hasLength(1), reason: '旧主机必须归档 —— 不能只清不存');
    expect(archives.single.hostId, 'h-1');
    expect(
      File(
        p.join(archives.single.directory, 'shensuanzi_mirror.db'),
      ).existsSync(),
      isTrue,
      reason: '归档里要有旧镜像本体',
    );
  });

  test('防呆② 同 host_id、异 IP ⇒ 不归档、镜像与积压队列都保留', () async {
    service.pairFromCode(pairCode('h-1'));
    await syncOneProduct();
    enqueueOne('q-keep');

    // 同一台主机，换了地址（换路由器 / DHCP 续租）
    service.pairFromCode(pairCode('h-1', ip: '127.0.0.2'));

    expect(service.archive.list(), isEmpty, reason: '同一台主机不该归档');
    expect(productRows(), 1, reason: '镜像不许重建');
    expect(
      SyncQueueDao(service.openMirror()).all(),
      hasLength(1),
      reason: '积压单必须还在，换地址不影响推送',
    );
    expect(service.lastHostSwitchHeldEntries, 0);
  });

  test('忘记主机后重新扫另一台 ⇒ 必须归档重建（F14 现场）', () async {
    service.pairFromCode(pairCode('h-1'));
    await syncOneProduct();
    enqueueOne('q-1');
    service.forgetHost(); // ← 这一步会删掉 pairing.json（旧实现据此跳过重建）
    expect(service.pairingStore.load(), isNull);

    service.pairFromCode(pairCode('h-2'));

    expect(productRows(), 0, reason: 'F14：旧镜像的商品还在 ⇒ 新主机一推同编码就 UNIQUE 撞死');
    expect(
      service.archive.list().single.hostId,
      'h-1',
      reason: '身份取自镜像（mirror_meta），不是已被删掉的 pairing.json',
    );
  });

  test('全新手机首次配对 ⇒ 不归档（情形 C）', () async {
    service.pairFromCode(pairCode('h-new'));

    expect(service.archive.list(), isEmpty);
    expect(
      Directory(service.archive.archiveRoot).existsSync(),
      isFalse,
      reason: '空镜像连 archive 目录都不该建',
    );
    expect(service.lastHostSwitchHeldEntries, 0);
  });

  test('老镜像（有数据但无 host_id 标记）⇒ 按换主机处理', () async {
    service.pairFromCode(pairCode('h-1'));
    await syncOneProduct();
    // 模拟 0.6.5 升上来：镜像里没有 mirror_meta
    MirrorMeta(service.openMirror()).clearHostId();
    service.forgetHost();

    service.pairFromCode(pairCode('h-1')); // 甚至还是同一台主机

    expect(productRows(), 0, reason: '无法证明这份镜像属于谁 ⇒ 安全侧：归档重建，不让旧店的货混进新店');
    expect(service.archive.list().single.hostId, 'unknown');
  });

  // C-2（业务审查 §3.7，2026-10-24）：`sent` 条目换主机后**两头落空** ——
  // 旧主机收下了但本机没确认（pull 还没跑）；换主机后新主机没有这条，
  // 而 `unsent()` 明确排除 `sent` ⇒ 它既不会被挂起、也永远不会再推。
  // 用户刚开的单**凭空消失**，队列里还留一条永远清不掉的 `sent`。
  test('C-2：换主机时 `sent` 条目也要降级为挂起（不能留成永远清不掉的 sent）', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    await service.syncNow();
    final Db mirror = service.openMirror();

    // 离线开一单，然后**模拟已推成功**（主机收下了、pull 还没确认）
    enqueueOne('q-sent');
    SyncQueueDao(mirror).markSent('q-sent');
    expect(
      SyncQueueDao(mirror).findById('q-sent')!.status,
      SyncQueueStatus.sent,
      reason: '前置：这条已推给 h-1',
    );

    // 换主机
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-2&ip=127.0.0.1&port=${host.baseUri.port}&token=tok2&v=1',
    );

    final SyncQueueEntry? after = SyncQueueDao(mirror).findById('q-sent');
    expect(after, isNotNull, reason: '条目不能删（那是用户刚开的单）');
    expect(
      after!.status,
      SyncQueueStatus.failed,
      reason:
          'C-2：新主机没有这条 ⇒ 必须降级为可处置（挂起），'
          '否则它永远停在 sent、永远不会再推',
    );
    expect(after.lastError, contains('已经发给上一台主机'));
    expect(service.lastHostSwitchHeldEntries, 1);
  });

  test('同一台主机重新扫码（host_id 不变）⇒ **不清镜像**（只换令牌）', () async {
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok&v=1',
    );
    host.pullBody['products'] = <Object?>[
      <String, Object?>{
        'id': 'p-keep',
        'code': 'P0010',
        'name': '留着',
        'unit': '瓶',
        'cost_price': 100,
        'sell_price': 200,
        'safety_stock': 0,
        'is_active': 1,
        'created_at': 1,
        'updated_at': 1,
      },
    ];
    await service.syncNow();
    final Db mirror = service.openMirror();

    // 主机重新生成配对码（host_id 不变）⇒ 只是换个令牌，数据是同一份
    service.pairFromCode(
      'shensuanzi://pair?host_id=h-1&ip=127.0.0.1&port=${host.baseUri.port}&token=tok-new&v=1',
    );

    expect(
      mirror.raw.select('SELECT COUNT(*) AS n FROM products').first['n'],
      1,
      reason: '同一台主机不该被当成换主机 —— 否则每次重扫码都要全量重拉',
    );
    expect(service.lastHostSwitchHeldEntries, 0);
  });
}
