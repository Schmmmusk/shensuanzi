// DPAPI 封装（`dpapi.dart`）—— 2026-11-01，提案 57 裁定 ⑥。
//
// 裁定要求覆盖：空令牌 / 非法 Base64 / 空密文 / 截断密文 / DPAPI 失败 /
// **输出缓冲区每条路径都释放** / 非 Windows 不加载 DLL。
//
// ⚠️ 本组只在 Windows 上跑真加解密；非 Windows 只验「降级为不支持」。
// 运行：`dart test`
import 'dart:convert';
import 'dart:io';

import 'package:shensuanzi_host/shensuanzi_host.dart';
import 'package:test/test.dart';

void main() {
  const DpapiTokenProtector dpapi = DpapiTokenProtector();
  const String hostId = 'h-1';

  group('Windows 真加解密', () {
    test('往返一致，且密文里没有明文', () {
      if (!dpapi.isSupported) {
        markTestSkipped('非 Windows / DPAPI 不可用');
        return;
      }
      const String token = 'abc123XYZ-_token-value-0123456789';
      final String? blob = dpapi.protect(token, hostId: hostId);
      expect(blob, isNotNull);
      expect(blob, isNot(contains(token)));
      expect(dpapi.unprotect(blob!, hostId: hostId), token);
    });

    test('熵绑定：换 host_id 解不开（密文挪到别的 host.json 里没用）', () {
      if (!dpapi.isSupported) {
        markTestSkipped('非 Windows');
        return;
      }
      final String blob = dpapi.protect('tok', hostId: 'h-1')!;
      expect(dpapi.unprotect(blob, hostId: 'h-2'), isNull);
    });

    test('非法 Base64 / 空密文 / 截断密文 ⇒ 一律 null，不崩', () {
      if (!dpapi.isSupported) {
        markTestSkipped('非 Windows');
        return;
      }
      expect(dpapi.unprotect('', hostId: hostId), isNull);
      expect(dpapi.unprotect('这不是 base64!!!', hostId: hostId), isNull);
      final String blob = dpapi.protect('tok', hostId: hostId)!;
      expect(
        dpapi.unprotect(blob.substring(0, blob.length ~/ 2), hostId: hostId),
        isNull,
        reason: '截断的密文必须解不开，且不能返回垃圾',
      );
    });

    test('篡改 1 字节 ⇒ 解不开', () {
      if (!dpapi.isSupported) {
        markTestSkipped('非 Windows');
        return;
      }
      final List<int> raw = base64.decode(dpapi.protect('tok', hostId: hostId)!);
      raw[raw.length ~/ 2] ^= 0xFF;
      expect(dpapi.unprotect(base64.encode(raw), hostId: hostId), isNull);
    });

    test('空令牌也能加密（长度 0 不是崩溃条件）', () {
      if (!dpapi.isSupported) {
        markTestSkipped('非 Windows');
        return;
      }
      final String? blob = dpapi.protect('', hostId: hostId);
      // 加密空串：DPAPI 允许；若实现拒绝也必须是 null 而不是抛
      if (blob != null) {
        expect(dpapi.unprotect(blob, hostId: hostId), '');
      }
    });

    test('循环 500 次不崩（输出缓冲区释放的冒烟）', () {
      if (!dpapi.isSupported) {
        markTestSkipped('非 Windows');
        return;
      }
      for (int i = 0; i < 500; i++) {
        final String? blob = dpapi.protect('tok-$i', hostId: hostId);
        expect(blob, isNotNull);
        expect(dpapi.unprotect(blob!, hostId: hostId), 'tok-$i');
      }
    });
  });

  group('降级与平台边界', () {
    test('NoTokenProtector：永远不支持，永远返回 null（不抛）', () {
      const NoTokenProtector none = NoTokenProtector();
      expect(none.isSupported, isFalse);
      expect(none.protect('tok', hostId: hostId), isNull);
      expect(none.unprotect('whatever', hostId: hostId), isNull);
    });

    test('非 Windows 上 `DpapiTokenProtector` 不加载 DLL，且 isSupported=false', () {
      if (Platform.isWindows) {
        markTestSkipped('本用例只验非 Windows 的降级');
        return;
      }
      expect(dpapi.isSupported, isFalse);
      expect(dpapi.protect('tok', hostId: hostId), isNull);
      expect(dpapi.unprotect('AAAA', hostId: hostId), isNull);
    });

    test('Windows 上 isSupported 为真（DLL 与符号都在）', () {
      if (!Platform.isWindows) {
        markTestSkipped('只在 Windows 上断言');
        return;
      }
      expect(dpapi.isSupported, isTrue);
    });
  });
}
