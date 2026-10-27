/// 手机端「手动填地址」的解析（2026-10-25 D 批）。
///
/// ## 为什么需要它
///
/// 配对二维码里的 IP 是电脑**自动挑**的，而自动挑永远可能挑错 ——
/// 复跑现场就是 `natpierce` 穿透网卡抢了 `WLAN`，二维码里写着 `10.6.22.1`。
/// 手机扫得到码、却连不上，而**扫码页从前只有扫码、零兜底**：
/// 用户唯一的出路是来找我们。
///
/// 所以给两个兜底入口（都在这一个函数里分流）：
///
/// | 用户粘进来的 | 处理 |
/// |---|---|
/// | 完整配对码 `shensuanzi://pair?...` | 等同扫码（拿到 host_id + 令牌，**能完成配对**） |
/// | 光一个地址 `192.168.1.5:17890` | **只换地址**，令牌沿用上次配对的 |
///
/// ## 为什么「光填地址」必须已有配对
///
/// 配对 = `host_id` + `token` + `ip` + `port`。只填地址的话后两样**无从得知**，
/// 而令牌是鉴权凭据 —— 编不出来，也不该编。所以这条路径的前提是
/// 「之前扫码成功过、只是地址不对」，此时 `pairing.json` 里有令牌。
///
/// 从没配对过、又扫不了码的用户，走「粘整段配对码文字」那条（电脑上二维码
/// 下面可以复制）。
///
/// ⚠️ 只接受 **IPv4 字面量**，不接受主机名：局域网里没有 DNS，
/// 而「填个 `my-pc` 然后连不上」比「格式不对」难查一百倍。
class PairingAddress {
  const PairingAddress._();

  /// 完整配对码的 scheme（与 `PairingPayload` 一致）
  static const String codeScheme = 'shensuanzi://';

  /// 用户粘进来的是不是一整段配对码。
  static bool isPairingCode(String raw) =>
      normalize(raw).toLowerCase().startsWith(codeScheme);

  /// **把中文输入法的全角字符掰回半角**（2026-10-27 真机实测）。
  ///
  /// 现场：用中文输入法在手机上手打 `10.102.43.94:17890`，落到输入框里是
  /// `10。102。43。94：17890` —— 句号变「。」、冒号变「：」。
  ///
  /// **这不是用户打错**，是输入法的默认行为，而且中老年用户基本躲不开。
  /// 若解析层直接回一句「格式不对」，等于把输入法的锅甩给用户 ——
  /// 他会以为自己不会用这个功能（正是 D 批要消灭的那种处境）。
  ///
  /// 只处理**确定等价**的字符，不做花哨猜测：
  ///
  /// | 全角 | 半角 | 说明 |
  /// |---|---|---|
  /// | `。` `．` | `.` | 句号 / 全角句点（IP 里只会是点） |
  /// | `：` | `:` | 全角冒号（端口分隔） |
  /// | `／` | `/` | 全角斜杠（去掉路径用） |
  /// | `０`–`９` | `0`–`9` | 全角数字 |
  /// | 全角空格 | 半角空格 | `\u3000` |
  static String normalize(String raw) {
    final StringBuffer out = StringBuffer();
    for (final int code in raw.trim().runes) {
      if (code >= 0xFF10 && code <= 0xFF19) {
        // ０-９ ⇒ 0-9
        out.writeCharCode(code - 0xFF10 + 0x30);
      } else if (code == 0x3002 || code == 0xFF0E) {
        // 。．
        out.write('.');
      } else if (code == 0xFF1A) {
        // ：
        out.write(':');
      } else if (code == 0xFF0F) {
        // ／
        out.write('/');
      } else if (code == 0x3000) {
        // 全角空格
        out.write(' ');
      } else {
        out.writeCharCode(code);
      }
    }
    return out.toString().trim();
  }

  /// 解析 `ip` / `ip:port` / `http://ip:port`。
  ///
  /// `port` 为 `null` = 用户没写端口，调用方沿用上次配对里的端口。
  /// 格式不对抛 [FormatException]，**消息直接给用户看**（中文、说清怎么写）。
  static ({String ip, int? port}) parse(String raw) {
    String text = normalize(raw);
    if (text.isEmpty) {
      throw const FormatException('请填电脑上的地址，例如 192.168.1.5:17890');
    }
    // 容错：用户可能从别处复制了带协议的地址
    final int schemeAt = text.indexOf('://');
    if (schemeAt >= 0) {
      final String scheme = text.substring(0, schemeAt).toLowerCase();
      if (scheme != 'http') {
        throw FormatException('只支持 http 开头的地址，现在是「$scheme://」');
      }
      text = text.substring(schemeAt + 3);
    }
    // 去掉可能粘进来的路径（`192.168.1.5:17890/api/health`）
    final int slash = text.indexOf('/');
    if (slash >= 0) text = text.substring(0, slash);

    final int colon = text.lastIndexOf(':');
    String ip = text;
    int? port;
    if (colon >= 0) {
      ip = text.substring(0, colon);
      final String portText = text.substring(colon + 1);
      port = int.tryParse(portText);
      if (port == null || port <= 0 || port > 65535) {
        throw FormatException('端口不对：「$portText」。应该是 1~65535 之间的数字。');
      }
    }

    if (!_isIpv4(ip)) {
      throw FormatException(
        '地址格式不对：「$ip」。要写成电脑的局域网 IP，例如 192.168.1.5:17890'
        '（IP 是四段数字，不能填电脑名）。',
      );
    }
    return (ip: ip, port: port);
  }

  static bool _isIpv4(String text) {
    final List<String> parts = text.split('.');
    if (parts.length != 4) return false;
    for (final String part in parts) {
      if (part.isEmpty || part.length > 3) return false;
      // 只允许纯数字（`int.tryParse` 会接受 `+1` / ` 1`，这里挡掉）
      if (!RegExp(r'^\d{1,3}$').hasMatch(part)) return false;
      final int? value = int.tryParse(part);
      if (value == null || value > 255) return false;
    }
    return true;
  }
}
