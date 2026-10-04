import 'package:qr/qr.dart';

/// 配对载荷（`docs/sync_protocol.md` §9.1）。
///
/// ```
/// shensuanzi://pair?host_id=<uuid>&ip=<lan_ip>&port=<port>&token=<token>&v=1
/// ```
///
/// **只负责「生成/解析这个字符串」** —— 二维码的**渲染**在根 Flutter 应用
/// （自绘 painter，见 `reply_review.md` §BB·三 / §BF）。把生成与渲染拆开，
/// 是为了让这一层留在纯 Dart 里可测。
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
/// 渲染层拿到 [uri] 交给自绘 painter（`PairingQrPainter`）即可；
/// 若要自己画，用 [matrix] 取模块矩阵。
///
/// ## ⚠️ 缓存（2026-10-03，§BF·二）—— 这个类**曾经能把真机搞「未响应」**
///
/// 全部成员**曾经是 getter**：`matrix` 的双重循环里，`moduleCount` 与 `image`
/// 各被调用 **O(n²) 次**（n = 49 ⇒ 约 4900 次），而 `qr` 包的 `QrImage(QrCode)`
/// 构造一次 = **8 次掩码试算 + 1 次终绘 = 9 遍完整编码** ——
/// 于是**访问一次 `matrix` = 15.4 秒**（实测）。现在是 `late final`：
/// **编码一次，之后全部复用**（实测 3.1 ms，差距约 5000 倍）。
///
/// **`uri` 刻意不缓存**：它是纯字符串拼接，与编码无关 ——
/// 缓存它只是白加一层间接（§BF·二 补强 3）。
class PairingQr {
  PairingQr(this.payload, {this.errorCorrectLevel = QrErrorCorrectLevel.M});

  final PairingPayload payload;

  /// 纠错等级。默认 `M`（15%）：二维码印在小屏上也能扫
  final int errorCorrectLevel;

  /// **底层 `QrImage` 的构造次数** —— 缓存正确性的回归断言用（§BF·二 补强 2）。
  ///
  /// 语义（裁定定死）：**构造后为 0（惰性）⇒ 首次访问编码类成员后恰好 1
  /// ⇒ 之后无论怎么访问都不再增长**。
  /// 「恰好 1」能同时区分三种错误：每次访问重编码（>1）·
  /// 构造即编码（构造后就不是 0）· 惰性缓存（=1）。
  int encodeCount = 0;

  /// 配对码字符串。**刻意不缓存** —— 纯字符串拼接，与编码无关。
  String get uri => payload.uri;

  /// 数据编码 + 纠错码（**不含**掩码搜索；掩码搜索在 [image] 那一步）。
  late final QrCode code = QrCode.fromData(
    data: uri,
    errorCorrectLevel: errorCorrectLevel,
  );

  /// 完整模块图。**构造一次 = 9 遍全量编码**（8 次掩码试算 + 1 次终绘，
  /// 见 `qr-3.0.2/lib/src/qr_image.dart` 的工厂构造）—— 所以必须缓存。
  late final QrImage image = _buildImage();

  QrImage _buildImage() {
    encodeCount++;
    return QrImage(code);
  }

  /// 模块数（n × n）。
  late final int moduleCount = image.moduleCount;

  /// 模块矩阵：`true` = 深色。行主序。
  ///
  /// 供自绘 / 生成图片用；Flutter 侧直接给 `PairingQrPainter` 就行，
  /// 不需要经过这里。
  late final List<List<bool>> matrix = <List<bool>>[
    for (int row = 0; row < moduleCount; row++)
      <bool>[
        for (int col = 0; col < moduleCount; col++) image.isDark(row, col),
      ],
  ];
}
