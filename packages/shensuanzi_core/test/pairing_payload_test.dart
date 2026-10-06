// 配对载荷（`PairingPayload`）的**权威测试** —— §BL·一（2026-10-05 裁定：
// 编解码归属 core，host 只是 re-export）。格式见 `docs/sync_protocol.md` §9.1。
import 'package:shensuanzi_core/shensuanzi_core.dart';
import 'package:test/test.dart';

void main() {
  const PairingPayload sample = PairingPayload(
    hostId: 'h-0001',
    ip: '192.168.1.5',
    port: 17890,
    token: 'dG9rZW4=',
  );

  test('uri 形态与 §9.1 一致', () {
    expect(sample.uri, startsWith('shensuanzi://pair?'));
    expect(sample.uri, contains('host_id=h-0001'));
    expect(sample.uri, contains('port=17890'));
    expect(sample.uri, contains('v=1'));
  });

  test('往返一致（生成 → 解析）', () {
    final PairingPayload parsed = PairingPayload.parse(sample.uri);

    expect(parsed.hostId, sample.hostId);
    expect(parsed.ip, sample.ip);
    expect(parsed.port, sample.port);
    expect(parsed.token, sample.token);
    expect(parsed.version, sample.version);
    expect(parsed.uri, sample.uri);
  });

  test('含 URL 不安全字符的令牌也能往返（Base64Url 的 - 与 _）', () {
    const PairingPayload tricky = PairingPayload(
      hostId: 'h-0002',
      ip: '10.0.0.2',
      port: 17891,
      token: 'a-b_c=d+e/f',
    );
    expect(PairingPayload.parse(tricky.uri).token, tricky.token);
  });

  test('非配对码 → FormatException', () {
    for (final String bad in <String>[
      'https://pair?host_id=x',
      'shensuanzi://other?host_id=x',
      '随便一句话',
      '',
    ]) {
      expect(() => PairingPayload.parse(bad), throwsFormatException, reason: bad);
    }
  });

  test('缺字段 → FormatException', () {
    expect(
      () => PairingPayload.parse('shensuanzi://pair?host_id=h&ip=1.1.1.1&port=1'),
      throwsFormatException,
    );
    expect(
      () => PairingPayload.parse('shensuanzi://pair?ip=1.1.1.1&port=1&token=t'),
      throwsFormatException,
    );
  });

  test('port 非法（0 / 65536 / 非数字）→ FormatException', () {
    for (final String bad in <String>[
      'shensuanzi://pair?host_id=h&ip=1.1.1.1&port=0&token=t',
      'shensuanzi://pair?host_id=h&ip=1.1.1.1&port=65536&token=t',
      'shensuanzi://pair?host_id=h&ip=1.1.1.1&port=abc&token=t',
    ]) {
      expect(() => PairingPayload.parse(bad), throwsFormatException, reason: bad);
    }
  });
}
