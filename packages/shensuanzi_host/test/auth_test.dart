// 令牌与主机身份（`docs/sync_protocol.md` §9.1 / §9.3）。
//
// 核心主张：**只持久化哈希**，校验用**常量时间比较**。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`。
import 'dart:convert';
import 'dart:math';

import 'package:shensuanzi_host/shensuanzi_host.dart';
import 'package:test/test.dart';

void main() {
  group('HostToken', () {
    test('generate 产出 32 字节 Base64，且注入种子时可复现', () {
      final String a = HostToken.generate(random: Random(42));
      final String b = HostToken.generate(random: Random(42));
      final String c = HostToken.generate(random: Random(43));

      expect(a, b, reason: '同种子必须同结果（用例可复现）');
      expect(a, isNot(c));
      expect(base64Url.decode(a).length, 32);
    });

    test('不注入种子时两次不同', () {
      expect(HostToken.generate(), isNot(HostToken.generate()));
    });

    test('hashOf 稳定且是 sha256 十六进制', () {
      expect(HostToken.hashOf('t'), HostToken.hashOf('t'));
      expect(HostToken.hashOf('t'), hasLength(64));
      expect(HostToken.hashOf('t'), isNot(HostToken.hashOf('u')));
    });

    test('matches：正确 / 错误 / null', () {
      final String hash = HostToken.hashOf('secret');
      expect(HostToken.matches('secret', hash), isTrue);
      expect(HostToken.matches('secrez', hash), isFalse);
      expect(HostToken.matches('', hash), isFalse);
      expect(HostToken.matches(null, hash), isFalse);
    });

    test('constantTimeEquals：等长不同 / 不等长', () {
      expect(HostToken.constantTimeEquals('abc', 'abc'), isTrue);
      expect(HostToken.constantTimeEquals('abc', 'abd'), isFalse);
      expect(HostToken.constantTimeEquals('abc', 'ab'), isFalse);
      expect(HostToken.constantTimeEquals('', ''), isTrue);
    });
  });

  group('HostIdentityStore', () {
    test('首次 loadOrCreate 生成身份，且带有明文（可画二维码）', () {
      final HostIdentityStore store = HostIdentityStore.inMemory();
      final HostIdentity identity = store.loadOrCreate(now: 1000);

      expect(identity.hostId, isNotEmpty);
      expect(identity.canShowQr, isTrue);
      expect(identity.authorizes(identity.plaintextToken), isTrue);
    });

    test('再次 loadOrCreate 读回同一身份，但**没有明文**（哈希不可逆）', () {
      final HostIdentityStore store = HostIdentityStore.inMemory();
      final HostIdentity first = store.loadOrCreate(now: 1000);

      final HostIdentity loaded = store.loadOrCreate(now: 2000);

      expect(loaded.hostId, first.hostId, reason: 'host_id 不变');
      expect(loaded.tokenHash, first.tokenHash);
      expect(loaded.canShowQr, isFalse, reason: '重启后画不出二维码');
      expect(loaded.authorizes(first.plaintextToken), isTrue,
          reason: '校验只需要哈希，重启后照样能校验');
    });

    test('reset 换新 host_id 与新令牌，旧令牌立刻失效', () {
      final HostIdentityStore store = HostIdentityStore.inMemory();
      final HostIdentity before = store.loadOrCreate(now: 1000);

      final HostIdentity after = store.reset(now: 2000);

      expect(after.hostId, isNot(before.hostId));
      expect(after.canShowQr, isTrue);
      expect(after.authorizes(before.plaintextToken), isFalse,
          reason: '一键重置 → 所有设备需重新配对');
      expect(after.authorizes(after.plaintextToken), isTrue);
      expect(store.storedHash(), after.tokenHash);
    });

    test('持久化的 JSON **不含明文令牌**', () {
      final HostIdentityStore store = HostIdentityStore.inMemory();
      final HostIdentity identity = store.loadOrCreate(now: 1000);

      final String serialized = jsonEncode(identity.toJson());

      expect(serialized, isNot(contains(identity.plaintextToken!)));
      expect(serialized, contains(identity.tokenHash));
      expect(identity.toJson()['token_hash'], identity.tokenHash);
      expect(identity.toJson().containsKey('token'), isFalse);
    });
  });
}
