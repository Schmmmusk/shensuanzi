// 配对载荷与二维码数据（`docs/sync_protocol.md` §9.1）。
//
// 核心主张：**「生成」与「渲染」拆开** —— 这里全是纯计算，可 `dart test`；
// 只有最后的 widget 渲染在 Flutter 层，无需测试。
import 'package:qr/qr.dart';
// ⚠️ `PairingPayload` 归属 core（协议 wire 格式），**不经 host 桶转手** ——
// 见 `packages/shensuanzi_host/lib/src/pairing.dart` 的头注释（2026-10-06）。
import 'package:shensuanzi_core/shensuanzi_core.dart' show PairingPayload;
import 'package:shensuanzi_host/shensuanzi_host.dart';
import 'package:test/test.dart';

void main() {
  const PairingPayload sample = PairingPayload(
    hostId: 'h-0001',
    ip: '192.168.1.5',
    port: 17890,
    token: 'dG9rZW4=',
  );

  group('PairingPayload', () {
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
        reason: '缺 token',
      );
      expect(
        () => PairingPayload.parse('shensuanzi://pair?ip=1.1.1.1&port=1&token=t'),
        throwsFormatException,
        reason: '缺 host_id',
      );
    });

    test('port 非法 → FormatException', () {
      for (final String port in <String>['0', '-1', '70000', 'abc']) {
        expect(
          () => PairingPayload.parse(
            'shensuanzi://pair?host_id=h&ip=1.1.1.1&port=$port&token=t',
          ),
          throwsFormatException,
          reason: 'port=$port',
        );
      }
    });
  });

  group('PairingQr', () {
    test('uri 与载荷一致', () {
      expect(PairingQr(sample).uri, sample.uri);
    });

    test('模块矩阵是 moduleCount × moduleCount 的方阵', () {
      final PairingQr qr = PairingQr(sample);
      final List<List<bool>> matrix = qr.matrix;

      expect(qr.moduleCount, greaterThanOrEqualTo(21), reason: '最小 QR 版本是 21×21');
      expect(matrix, hasLength(qr.moduleCount));
      for (final List<bool> row in matrix) {
        expect(row, hasLength(qr.moduleCount));
      }
    });

    test('有深色模块（不是全白）', () {
      final List<List<bool>> matrix = PairingQr(sample).matrix;
      final int dark = matrix
          .expand((List<bool> row) => row)
          .where((bool cell) => cell)
          .length;
      expect(dark, greaterThan(0));
    });

    test('三个定位图案的左上角是深色（QR 固定结构）', () {
      final List<List<bool>> matrix = PairingQr(sample).matrix;
      final int n = matrix.length;

      expect(matrix[0][0], isTrue);
      expect(matrix[0][n - 1], isTrue);
      expect(matrix[n - 1][0], isTrue);
    });

    test('不同内容的二维码矩阵不同', () {
      final List<List<bool>> a = PairingQr(sample).matrix;
      final List<List<bool>> b = PairingQr(
        const PairingPayload(
          hostId: 'h-0009',
          ip: '192.168.1.9',
          port: 17899,
          token: 'other',
        ),
      ).matrix;

      expect(a.length, b.length, reason: '同长度内容 → 同版本');
      expect(a, isNot(b));
    });

    // ------------------------------------------------------------ 缓存（§BF·二）
    //
    // 背景：全部成员曾经是 getter ⇒ 访问一次 `matrix` = O(n²) 次 getter ×
    // `qr` 包每次构造 9 遍编码 = **15.4 秒**（真机「未响应」的根因）。
    // 这组断言钉住「编码一次，之后全部复用」。
    test('encodeCount：构造为 0（惰性）→ 首次访问后恰好 1 → 之后不再增长', () {
      final PairingQr qr = PairingQr(sample);

      expect(
        qr.encodeCount,
        0,
        reason: '构造**不编码**（惰性）——「构造即编码」也是要拦的错误形态',
      );

      final List<List<bool>> matrix = qr.matrix;
      expect(
        qr.encodeCount,
        1,
        reason: '首次访问，编码一次 —— 语义 = 底层 QrImage 的构造次数',
      );
      expect(matrix, hasLength(qr.moduleCount));

      qr.matrix;
      qr.matrix;
      expect(qr.encodeCount, 1, reason: '重复访问不增长');

      qr.moduleCount;
      qr.uri;
      expect(
        qr.encodeCount,
        1,
        reason: '跨字段访问仍不增长（同一次编码被所有成员共享）',
      );
    });

    test('缓存后的矩阵与「直接用 qr 包现算」逐 bit 一致（缓存没改语义）', () {
      final PairingQr qr = PairingQr(sample);

      // 参照实现：**绕开 PairingQr**，直接用底层 qr 包现算一遍
      final QrCode code = QrCode.fromData(
        data: sample.uri,
        errorCorrectLevel: QrErrorCorrectLevel.M,
      );
      final QrImage image = QrImage(code);
      final List<List<bool>> expected = <List<bool>>[
        for (int row = 0; row < image.moduleCount; row++)
          <bool>[
            for (int col = 0; col < image.moduleCount; col++)
              image.isDark(row, col),
          ],
      ];

      expect(qr.matrix, expected, reason: '缓存只改「算几次」，不改「算出什么」');
    });
  });
}
