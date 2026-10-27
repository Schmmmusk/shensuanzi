/// 配对凭据的存取（§BL·二，2026-10-05 裁定 ②：**单独 `pairing.json`**）。
///
/// ## 为什么不进 `config.json`
///
/// config 是**偏好**（店名、界面缩放），pairing 是**凭据**（token、主机地址）。
/// 分开之后：重新配对只动这个文件；「忘记主机」= 删它；config 的读写路径
/// 与同步层零耦合。
///
/// ## 安全边界
///
/// 文件放**应用私有目录**（Android `/data/user/0/<pkg>/files/`、桌面由
/// 数据目录布局决定），不跨出去 —— token 是明文（与二维码同源，带外通道
/// 人眼 → 摄像头），安全性靠私有目录 + 主机侧可随时重置配对（token 失效）。
library;

import 'dart:convert';
import 'dart:io';

/// 一台已配对主机的凭据
class PairingInfo {
  const PairingInfo({
    required this.hostId,
    required this.ip,
    required this.port,
    required this.token,
    this.lastSyncAt,
  });

  factory PairingInfo.fromJson(Map<String, Object?> json) => PairingInfo(
    hostId: json['host_id']! as String,
    ip: json['ip']! as String,
    port: json['port']! as int,
    token: json['token']! as String,
    lastSyncAt: json['last_sync_at'] as int?,
  );

  /// 来自配对二维码（`PairingPayload`，§9.1）
  factory PairingInfo.fromPayload({
    required String hostId,
    required String ip,
    required int port,
    required String token,
  }) => PairingInfo(hostId: hostId, ip: ip, port: port, token: token);

  final String hostId;
  final String ip;
  final int port;
  final String token;

  /// 上次成功同步的时间（毫秒）；`null` = 从没同步成功过
  final int? lastSyncAt;

  /// 主机地址（`SyncClient.baseUri` 用）
  Uri get baseUri => Uri.parse('http://$ip:$port');

  Map<String, Object?> toJson() => <String, Object?>{
    'host_id': hostId,
    'ip': ip,
    'port': port,
    'token': token,
    if (lastSyncAt != null) 'last_sync_at': lastSyncAt,
  };

  PairingInfo withLastSyncAt(int millis) => PairingInfo(
    hostId: hostId,
    ip: ip,
    port: port,
    token: token,
    lastSyncAt: millis,
  );

  /// **只换地址**，`hostId` / 令牌 / 上次同步时间原样保留（2026-10-25 D 批）。
  ///
  /// 用途：二维码里的 IP 是电脑自动挑的，挑错时（穿透网卡抢了 WiFi）
  /// 用户在手机上手填一个正确地址。**身份没变** ⇒ 不该触发「换主机」的
  /// 归档重建（那条判据是 `hostId`，见 `pairFromCode` 的 F14 注释）。
  PairingInfo withAddress({required String ip, required int port}) =>
      PairingInfo(
        hostId: hostId,
        ip: ip,
        port: port,
        token: token,
        lastSyncAt: lastSyncAt,
      );
}

/// `pairing.json` 的读写（整文件读写，没有并发写入方 —— 同步按钮互斥）。
class PairingStore {
  PairingStore(this.file);

  final File file;

  /// 没配对过 / 文件损坏 ⇒ `null`（**损坏不抛**：删掉重来就是重新扫码）
  PairingInfo? load() {
    if (!file.existsSync()) return null;
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?>) return null;
      return PairingInfo.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  void save(PairingInfo info) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(info.toJson()),
      flush: true,
    );
  }

  /// 「忘记这台主机」/ 配对失效后重置
  void clear() {
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}
