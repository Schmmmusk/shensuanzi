import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shensuanzi_core/shensuanzi_core.dart';

/// 令牌工具（`docs/sync_protocol.md` §9.1 / §9.3）。**全是静态方法** ——
/// 令牌在数据上就是「一段明文 + 它的哈希」，不需要一个实例类去承载。
class HostToken {
  HostToken._();

  /// 生成新令牌：32 字节随机数 → Base64（§9.1）。**返回明文。**
  ///
  /// [random] 可注入：测试里传固定种子，避免随机导致用例不可复现。
  static String generate({Random? random}) {
    final Random rng = random ?? Random.secure();
    final List<int> bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// `sha256(明文)` 的十六进制表示 —— **这是唯一会被持久化的部分**
  static String hashOf(String plaintext) =>
      sha256.convert(utf8.encode(plaintext)).toString();

  /// 校验候选令牌。**常量时间**：跑完全长才返回。
  ///
  /// 逐字节提前返回可用响应时间**逐字节猜出**令牌；这里异或累积。
  /// 长度不同立即返回 `false` —— 长度不是秘密。
  static bool matches(String? candidate, String storedHash) {
    if (candidate == null) return false;
    return constantTimeEquals(storedHash, hashOf(candidate));
  }

  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// 主机身份：`host_id` + 令牌哈希（+ 可选明文）。
///
/// ## 为什么要区分「哈希」与「明文」
///
/// 主机**只持久化 `sha256(token)`**（[HostIdentityStore] 写文件时只写哈希）。
/// 于是：
///
/// - **校验只需哈希** —— `sha256(候选)` 与存量哈希比较即可，重启后照样能校验
/// - **画二维码需要明文** —— 而哈希不可逆，所以**重启后画不出二维码**，
///   必须 [HostIdentityStore.reset]（换新令牌 + 新 `host_id`，所有设备重新配对）
///
/// [plaintextToken] 为 `null` 就是「重启后」的状态，[canShowQr] 据此判断。
class HostIdentity {
  const HostIdentity({
    required this.hostId,
    required this.tokenHash,
    required this.createdAt,
    this.plaintextToken,
  });

  /// 二维码里带的主机标识（§9.1）
  final String hostId;

  /// `sha256(明文)`。**唯一被持久化的部分。**
  final String tokenHash;

  final int createdAt;

  /// 明文令牌。**只有刚生成 / 刚重置后非空**：不要落库、不要写日志。
  final String? plaintextToken;

  /// 能否展示配对二维码（= 是否持有明文）
  bool get canShowQr => plaintextToken != null;

  /// 校验一个客户端出示的 Bearer 令牌
  bool authorizes(String? candidate) =>
      HostToken.matches(candidate, tokenHash);

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'host_id': hostId,
    // ⚠️ 只写哈希。写明文就等于把「只存哈希」这条设计作废。
    'token_hash': tokenHash,
    'created_at': createdAt,
  };
}

/// `host.json` 的读写。
///
/// ## 为什么存文件而不是建表
///
/// `docs/data_model.md` 里没有对应的表；令牌是**主机设施**（不是业务数据），
/// 放 `<数据目录>/host.json` 即可 —— **不动 schema**。
///
/// ## 纯内存模式
///
/// [HostIdentityStore.inMemory] 不碰文件系统，供单测使用。
class HostIdentityStore {
  HostIdentityStore(this.file) : _memory = null;

  /// 不碰文件系统 —— 单测与自检用。
  ///
  /// `file == null` 就是「内存模式」的判据；[_memory] 是它的存储槽，
  /// **初值必须是 `null`（= 还没存过）**，而不是空 map ——
  /// 空 map 会让 [load] 误判成「已存过一条记录」。
  HostIdentityStore.inMemory() : file = null, _memory = null;

  /// `null` = 纯内存模式
  final File? file;

  Map<String, Object?>? _memory;

  /// 读取已存的主机身份。
  ///
  /// **返回的实例里 [HostIdentity.plaintextToken] 恒为 `null`** ——
  /// 哈希不可逆，明文没法从文件里还原。要拿到明文必须 [reset]。
  HostIdentity? load() {
    final Map<String, Object?>? stored = _read();
    if (stored == null) return null;
    return HostIdentity(
      hostId: stored['host_id']! as String,
      tokenHash: stored['token_hash']! as String,
      createdAt: stored['created_at']! as int,
    );
  }

  /// 首次启动：没有就生成并持久化（§9.3「Token 首次启动生成」）。
  /// 已有则原样读回（此时 [HostIdentity.canShowQr] 为 `false`）。
  HostIdentity loadOrCreate({required int now, Random? random}) =>
      load() ?? reset(now: now, random: random);

  /// 生成 / 重置令牌（§9.3「一键重置」）。**`host_id` 一并更换** ——
  /// 所有已配对设备都作废，必须重新扫码。
  HostIdentity reset({required int now, Random? random}) {
    final String plaintext = HostToken.generate(random: random);
    final HostIdentity next = HostIdentity(
      hostId: newId(),
      tokenHash: HostToken.hashOf(plaintext),
      createdAt: now,
      plaintextToken: plaintext,
    );
    _write(next);
    return next;
  }

  /// 已持久化的令牌哈希（**不含明文**）。无记录时返回 `null`。
  ///
  /// 存在的意义：让「落盘里只有哈希」这条设计**可被断言**，
  /// 而不是只写在注释里。
  String? storedHash() => _read()?['token_hash'] as String?;

  Map<String, Object?>? _read() {
    // 内存模式：`file == null`，存储槽就是 `_memory`（未写入时为 null）
    if (file == null) return _memory;
    final File target = file!;
    if (!target.existsSync()) return null;
    return Map<String, Object?>.from(
      jsonDecode(target.readAsStringSync()) as Map<Object?, Object?>,
    );
  }

  void _write(HostIdentity identity) {
    final Map<String, Object?> json = identity.toJson();
    if (file == null) {
      _memory = json;
      return;
    }
    file!.parent.createSync(recursive: true);
    file!.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
  }
}
