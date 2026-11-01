// **控制器级**的「重启后画同一个码」验收（2026-11-01，提案 57 总验收）。
//
// 为什么还要这一层（`probe_restart_token.dart` 已经验过 store）：
// 用户裁定里的验收是「连续两次重启，二维码内容不变、手机不用重扫」——
// 二维码的内容是 `pairingPayload`（host_id + token + 地址 + 端口），
// 它由 **`HostServiceController`** 拼出来，不是 store 拼的。
// 这一层用**文件落盘的 host.json + 真 DB**，两个独立进程各起一次服务，
// 比对 `pairingPayload` 的每一个字段。
//
// 用法（两步，必须分两个进程）：
//   dart run tool/probe_controller_restart.dart start <dir>
//   dart run tool/probe_controller_restart.dart start <dir>   # 再来一次
import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:shensuanzi_host/shensuanzi_host.dart';

Future<void> main(List<String> args) async {
  useLocalSqlite();
  if (args.length != 2) {
    stderr.writeln(
      '用法：dart run tool/probe_controller_restart.dart <start|reset> <dir>',
    );
    exit(2);
  }
  final bool doReset = args[0] == 'reset';
  final Directory dir = Directory(args[1])..createSync(recursive: true);
  final Db db = Db.open(
    '${dir.path}${Platform.pathSeparator}shensuanzi.db',
    foreignKeys: false,
  );
  final HostIdentityStore identities = HostIdentityStore(
    File('${dir.path}${Platform.pathSeparator}host.json'),
  );
  final HostServiceController controller = HostServiceController(
    db: db,
    identities: identities,
    // 与生产同段，避开 17890 免得和真跑着的实例撞车
    ports: const PortRange(start: 17985, end: 17999),
    // 不真扫网卡：地址固定，两次才可比
    detectLocalIp: () async => '192.168.1.7',
    detectAddresses: () async => const <NetAddressOption>[
      NetAddressOption(address: '192.168.1.7', name: 'probe'),
    ],
  );

  HostServiceSnapshot snapshot = await controller.start();
  if (doReset) {
    // 「重新生成配对码」= 用户手动触发的一次性迁移：v1（只有哈希）→ v2（带密文）
    snapshot = await controller.resetToken();
  }
  final PairingPayload? payload = controller.pairingPayload;
  stdout.writeln('RESULT state=${snapshot.state.name}');
  stdout.writeln('RESULT token_restore=${snapshot.tokenRestore.name}');
  stdout.writeln('RESULT qr_available=${snapshot.qrAvailable}');
  stdout.writeln('RESULT needs_reset=${snapshot.needsReset}');
  stdout.writeln('RESULT token_protect_failed=${snapshot.tokenProtectFailed}');
  stdout.writeln('RESULT payload_host_id=${payload?.hostId}');
  stdout.writeln('RESULT payload_token=${payload?.token}');
  stdout.writeln('RESULT payload_ip=${payload?.ip}');
  stdout.writeln('RESULT payload_port=${payload?.port}');
  // 二维码里那串文本（真机上手机扫的就是它）
  stdout.writeln('RESULT payload_text=${payload?.uri}');

  await controller.stop();
  db.close();
  exit(0);
}
