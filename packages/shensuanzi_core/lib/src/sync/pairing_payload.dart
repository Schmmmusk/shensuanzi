/// 配对载荷（`docs/sync_protocol.md` §9.1）—— **wire 格式，归属 core**（§BL·一）。
///
/// ```
/// shensuanzi://pair?host_id=<uuid>&ip=<lan_ip>&port=<port>&token=<token>&v=1
/// ```
///
/// ## 为什么在 core（2026-10-05 裁定）
///
/// 这个字符串是**主机生成、客户端解析**的两端协议：主机侧在 `shensuanzi_host`，
/// 客户端在 `shensuanzi_app` —— 而**包边界裁定 app 不依赖 host**（README 包图）。
/// 格式放 core，两端各自 import core，编解码只有一份（两份必然漂移）。
/// host 侧通过 re-export 保持旧导入路径不变（零破坏）。
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
