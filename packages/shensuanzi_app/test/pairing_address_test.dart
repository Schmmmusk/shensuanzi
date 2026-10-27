// 「手动填地址」的两个纯逻辑（2026-10-25 D 批）：
//   ① `PairingAddress.parse` —— 用户粘进来的字符串怎么变成 ip/port；
//   ② `MobileSyncService.pairFromAddress` —— 只换地址、不动身份与令牌。
//
// 背景（复跑现场）：电脑自动挑网卡挑到了 `natpierce` 隧道地址（10.6.22.1），
// 二维码扫得到、手机连不上，而手机端从前**只有扫码、零兜底**。
//
// 运行：`dart test`（本机由用户执行）
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shensuanzi_app/shensuanzi_app.dart';
import 'package:shensuanzi_core/sqlite_local.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(useLocalSqlite);

  group('PairingAddress.parse', () {
    test('标准写法：ip:port', () {
      expect(PairingAddress.parse('192.168.1.5:17890'), (
        ip: '192.168.1.5',
        port: 17890,
      ));
    });

    test('不写端口 ⇒ port 为 null（调用方沿用上次的）', () {
      expect(PairingAddress.parse('10.102.43.94'), (
        ip: '10.102.43.94',
        port: null,
      ));
    });

    test('容错：带协议、带路径、前后空格', () {
      expect(PairingAddress.parse('  http://192.168.1.5:17890/  '), (
        ip: '192.168.1.5',
        port: 17890,
      ));
      expect(PairingAddress.parse('192.168.1.5:17890/api/health'), (
        ip: '192.168.1.5',
        port: 17890,
      ));
    });

    test('完整配对码被识别为「配对码」而不是地址', () {
      expect(
        PairingAddress.isPairingCode(
          'shensuanzi://pair?host_id=h1&ip=10.6.22.1&port=17890&token=t&v=1',
        ),
        isTrue,
      );
      expect(PairingAddress.isPairingCode('192.168.1.5:17890'), isFalse);
    });

    test('非法输入给**中文**原因（这些字会直接显示给用户）', () {
      // 空
      expect(
        () => PairingAddress.parse('   '),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('例如 192.168.1.5:17890'),
          ),
        ),
      );
      // 主机名（局域网里没有 DNS，填了只会「连不上」）
      expect(
        () => PairingAddress.parse('my-pc:17890'),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('不能填电脑名'),
          ),
        ),
      );
      // 段数不对 / 越界
      expect(() => PairingAddress.parse('192.168.1'), throwsFormatException);
      expect(
        () => PairingAddress.parse('192.168.1.300'),
        throwsFormatException,
      );
      // 端口越界 / 不是数字
      expect(
        () => PairingAddress.parse('192.168.1.5:99999'),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('端口不对'),
          ),
        ),
      );
      expect(
        () => PairingAddress.parse('192.168.1.5:abc'),
        throwsFormatException,
      );
      // 非 http 协议
      expect(
        () => PairingAddress.parse('https://192.168.1.5:17890'),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('只支持 http'),
          ),
        ),
      );
    });
  });

  group('MobileSyncService.pairFromAddress', () {
    late Directory box;
    late PairingStore store;
    late MobileSyncService service;

    setUp(() {
      box = Directory.systemTemp.createTempSync('shensuanzi_addr_');
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

    test('没配对过 ⇒ 拒绝，并说清「光填地址不够」', () {
      expect(
        () => service.pairFromAddress('192.168.1.5:17890'),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            allOf(contains('还没连过电脑'), contains('配对码')),
          ),
        ),
      );
    });

    test('配对过 ⇒ 只换地址，身份 / 令牌 / 上次同步时间都不动', () {
      // 先扫一次码（现场就是这一步拿到了令牌，只是 IP 是错的）
      service.pairFromCode(
        'shensuanzi://pair?host_id=h-1&ip=10.6.22.1&port=17890&token=tok&v=1',
      );
      final PairingInfo before = store.load()!;
      expect(before.ip, '10.6.22.1');

      final PairingInfo after = service.pairFromAddress('10.102.43.94:17890');

      expect(after.ip, '10.102.43.94', reason: '这才是用户填进来的东西');
      expect(after.port, 17890);
      expect(after.hostId, 'h-1', reason: '还是同一台电脑 —— 换的是路，不是身份');
      expect(after.token, 'tok', reason: '令牌必须留着，否则鉴权过不去');
      expect(store.load()!.ip, '10.102.43.94', reason: '必须落盘');
      // 同一台主机 ⇒ 不触发换主机的归档（那是 F14 的事）
      expect(service.lastHostSwitchHeldEntries, 0);
    });

    test('不写端口 ⇒ 沿用上次配对里的端口', () {
      service.pairFromCode(
        'shensuanzi://pair?host_id=h-1&ip=10.6.22.1&port=17901&token=tok&v=1',
      );
      final PairingInfo after = service.pairFromAddress('10.102.43.94');
      expect(after.port, 17901, reason: '用户只改了 IP，端口不该被悄悄改成默认值');
    });

    test('地址非法 ⇒ 抛，且**不改**已有的配对', () {
      service.pairFromCode(
        'shensuanzi://pair?host_id=h-1&ip=10.6.22.1&port=17890&token=tok&v=1',
      );
      expect(() => service.pairFromAddress('乱写的'), throwsFormatException);
      expect(store.load()!.ip, '10.6.22.1', reason: '填错了不能把原来的好地址弄丢');
    });
  });
}
