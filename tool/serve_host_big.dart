// 起一个**常驻**的主机同步服务（供手机性能/拉取测试用）。
//
// 用法：`dart run tool/serve_host_big.dart <数据目录> <端口> <对外 IP>`
//
// 与 `probe_controller_restart.dart` 的区别：那个跑完就退（只验快照），
// 这个要**一直听**，好让手机真的连上来拉数据。
//
// ⚠️ 用的 `host.json` 必须是**同一台电脑、同一个 Windows 用户**的 ——
// 里面的令牌是 DPAPI 密文，换用户解不开，手机就会鉴权失败（401）。
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

Future<void> main(List<String> args) async {
  useLocalSqlite();
  if (args.length < 3) {
    stderr.writeln(
      '用法：dart run tool/serve_host_big.dart <数据目录> <端口> <对外 IP>',
    );
    exit(2);
  }
  final String dir = args[0];
  final int port = int.parse(args[1]);
  final String ip = args[2];

  final Stopwatch watch = Stopwatch()..start();
  final Db db = Db.open(
    '$dir${Platform.pathSeparator}shensuanzi.db',
    foreignKeys: false,
  );
  stdout.writeln('RESULT db_open_ms=${watch.elapsedMilliseconds}');
  final List<dynamic> docs = db.raw.select(
    'SELECT COUNT(*) AS n FROM documents',
  );
  stdout.writeln('RESULT documents=${docs.first['n']}');

  final HostServiceController controller = HostServiceController(
    db: db,
    identities: HostIdentityStore(
      File('$dir${Platform.pathSeparator}host.json'),
    ),
    ports: PortRange(start: port, end: port),
    detectLocalIp: () async => ip,
    detectAddresses: () async => <NetAddressOption>[
      NetAddressOption(address: ip, name: 'perf'),
    ],
  );

  final HostServiceSnapshot snapshot = await controller.start();
  stdout.writeln('RESULT state=${snapshot.state.name}');
  stdout.writeln('RESULT port=${snapshot.port}');
  stdout.writeln('RESULT token_restore=${snapshot.tokenRestore.name}');
  stdout.writeln('RESULT qr_available=${snapshot.qrAvailable}');
  final PairingPayload? payload = controller.pairingPayload;
  stdout.writeln('RESULT payload_token=${payload?.token}');
  stdout.writeln('READY 服务已监听 $ip:$port，可以开始测了');

  // 常驻：等 Ctrl-C 或两小时
  await Future<void>.delayed(const Duration(hours: 2));
  await controller.stop();
  db.close();
}
