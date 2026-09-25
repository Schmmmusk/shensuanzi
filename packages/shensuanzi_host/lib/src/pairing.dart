import 'package:qr/qr.dart';

/// 配对载荷（`docs/sync_protocol.md` §9.1）。
///
/// ```
/// shensuanzi://pair?host_id=<uuid>&ip=<lan_ip>&port=<port>&token=<token>&v=1
/// ```
///
/// **只负责「生成/解析这个字符串」** —— 二维码的**渲染**在根 Flutter 应用
/// （`qr_flutter`）。把生成与渲染拆开，是为了让这一层留在纯 Dart 里可测。
class PairingPayload {
  const PairingPayload({
    required this.hostId,
    required this.ip,
    required this.port,
    required this.token,
    this.version = 1,
  });

  static const String scheme = 'shensuanzi';
  static const String host = 'pair';
  static const int currentVersion = 1;

  final String hostId;

  /// 局域网 IP。IP 变化后旧二维码失效，客户端需**重新扫码**（§9.2）
  final String ip;
  final int port;

  /// **明文令牌**。它随二维码走带外通道（人眼 → 摄像头）。
  final String token;
  final int version;

  String get uri {
    final Uri url = Uri(
      scheme: scheme,
      host: host,
      queryParameters: <String, String>{
        'host_id': hostId,
        'ip': ip,
        'port': '$port',
        'token': token,
        'v': '$version',
      },
    );
    return url.toString();
  }

  static PairingPayload parse(String raw) {
    final Uri? url = Uri.tryParse(raw);
    if (url == null || url.scheme != scheme || url.host != host) {
      throw FormatException('不是神算子配对码：$raw');
    }
    final Map<String, String> q = url.queryParameters;
    for (final String key in <String>['host_id', 'ip', 'port', 'token']) {
      if (q[key] == null || q[key]!.isEmpty) {
        throw FormatException('配对码缺少 $key：$raw');
      }
    }
    final int? port = int.tryParse(q['port']!);
    if (port == null || port <= 0 || port > 65535) {
      throw FormatException('配对码的 port 非法：${q['port']}');
    }
    return PairingPayload(
      hostId: q['host_id']!,
      ip: q['ip']!,
      port: port,
      token: q['token']!,
      version: int.tryParse(q['v'] ?? '') ?? currentVersion,
    );
  }
}

/// 配对二维码的**数据**生成（§9.1）。
///
/// 全部是纯计算 —— 没有 widget、没有图片编码，所以 `dart test` 可跑。
/// 渲染层拿到 [uri] 交给 `QrImageView` 即可；若要自己画，
/// 用 [matrix] 取模块矩阵。
class PairingQr {
  PairingQr(this.payload, {this.errorCorrectLevel = QrErrorCorrectLevel.M});

  final PairingPayload payload;

  /// 纠错等级。默认 `M`（15%）：二维码印在小屏上也能扫
  final int errorCorrectLevel;

  String get uri => payload.uri;

  QrCode get code =>
      QrCode.fromData(data: uri, errorCorrectLevel: errorCorrectLevel);

  QrImage get image => QrImage(code);

  int get moduleCount => image.moduleCount;

  /// 模块矩阵：`true` = 深色。行主序。
  ///
  /// 供自绘 / 生成图片用；Flutter 侧直接给 `QrImageView(data: uri)` 就行，
  /// 不需要经过这里。
  List<List<bool>> get matrix => <List<bool>>[
    for (int row = 0; row < moduleCount; row++)
      <bool>[
        for (int col = 0; col < moduleCount; col++) image.isDark(row, col),
      ],
  ];
}
