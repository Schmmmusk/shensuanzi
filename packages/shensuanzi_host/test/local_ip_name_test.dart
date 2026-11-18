// 虚拟网卡名字判定（2026-11-18，提案 62 §四）。
//
// 只测这一个纯函数：它给设置页的「虚拟网卡 —— 手机多半连不上」提示提供判据，
// 判错了会**误导用户**（把真网卡说成虚拟，他会去换一个本来好用的地址）。
import 'package:shensuanzi_host/shensuanzi_host.dart';
import 'package:test/test.dart';

void main() {
  group('isVirtualName', () {
    test('已知的虚拟 / 隧道网卡都认得出（大小写不敏感）', () {
      for (final String name in <String>[
        'vEthernet (WSL)',
        'VMware Network Adapter VMnet1',
        'VirtualBox Host-Only Network',
        'Hyper-V Virtual Ethernet Adapter',
        'Tailscale',
        'utun3',
      ]) {
        expect(
          LocalIp.isVirtualName(name),
          isTrue,
          reason: '「$name」是虚拟/隧道网卡，漏判会让用户照着连一个不可达地址',
        );
      }
    });

    test('真网卡不许被误判（误判会让他换掉本来好用的地址）', () {
      for (final String name in <String>['WLAN', 'Wi-Fi', '以太网', 'Ethernet']) {
        expect(LocalIp.isVirtualName(name), isFalse, reason: name);
      }
    });

    test('NetAddressOption.looksVirtual 用的是同一张表', () {
      expect(
        const NetAddressOption(
          name: 'vEthernet (WSL)',
          address: '172.24.16.1',
        ).looksVirtual,
        isTrue,
      );
      expect(
        const NetAddressOption(
          name: 'WLAN',
          address: '10.102.43.94',
        ).looksVirtual,
        isFalse,
      );
    });
  });
}
