import 'dart:io';

/// 一块网卡 + 它的地址（[NetworkInterface] 没有公开构造函数，
/// 所以把它摊成这个可构造的小值类型，[LocalIp.choose] 才能被单测喂假数据）。
class NetCandidate {
  const NetCandidate(this.name, this.addresses);

  /// 网卡名，如 `en0` / `eth0` / `WLAN` / `vEthernet (WSL)`
  final String name;

  /// 该网卡上的 IPv4 字面量（已由 `includeLoopback: false` 过滤）
  final List<String> addresses;

  @override
  String toString() => '$name=$addresses';
}

/// 扫网卡的**可注入的缝**（与 §AT 的 `AppEnvironment.detect({driveEnumerator})` 同一模式）。
///
/// 为什么必须留缝：「一块网卡都没有」「扫到一堆 loopback 又被全过滤」这些路径
/// **没法用真实机器在测试里构造**，只能注入。默认 `null` = 真扫网卡。
typedef NetScanner = Future<List<NetCandidate>> Function();

/// 选一个**局域网 IPv4** —— 配对二维码里要填的那个地址。
///
/// ## 为什么不能直接用 `HostHttpServer.address`
///
/// 服务绑的是 `InternetAddress.anyIPv4`（`0.0.0.0`）—— 那是「监听全部网卡」的
/// **通配地址**。把 `0.0.0.0:17890` 画进二维码，手机照着连**永远连不上**。
/// 二维码里必须是一个**对端可达的具体地址**。
///
/// ## 选择规则
///
/// 1. 跳过 loopback / link-local（`NetworkInterface.list` 已经滤掉，这里再兜一次）
/// 2. **优先私有网段**：`192.168/16`、`10/8`、`172.16~31/12`
/// 3. **跳过虚拟网卡**：VirtualBox / VMware / WSL / Hyper-V / VPN 的地址
///    扫出来常常不可达 —— 用户会得到「二维码扫了连不上」这种最难查的故障
/// 4. 都挑不出来就退回第一个非 loopback 地址；一个都没有 ⇒ `null`
///    （UI 必须能处理 `null`：显示「找不到局域网地址 + 怎么办」，**不能画个假地址**）
///
/// ## 职责划分（这条让「扫」与「选」都能测）
///
/// | 层 | 可测性 |
/// |---|---|
/// | [choose]（纯函数） | ✅ 喂假候选，覆盖全部规则 |
/// | [detect] 的**兜底分支**（空候选 / 全被过滤） | ✅ 注入 [scan] 桩 |
/// | 真网卡扫描（[_scanReal]） | ❌ **唯一不可测的部分**，隔离在默认参数里 |
///
/// **`detect` 永不抛**：拿不到网卡不是「启动失败」，只是「画不出二维码」——
/// 上抛会让整个同步服务起不来（同 §AT 的 `AppEnvironment.detect` 口径）。
///
/// 纯 `dart:io`，无 Flutter 依赖。
class LocalIp {
  LocalIp._();

  /// 虚拟 / 隧道网卡的名字片段（小写比较）。
  ///
  /// 这些网卡的地址是**真地址但不可达**：`vEthernet (WSL)`、
  /// `VMware Network Adapter VMnet1`、`utun`、`tun`、`Tailscale`……
  /// 挑错了表现为「二维码看着正常，手机连不上」。
  static const List<String> virtualMarkers = <String>[
    'virtual',
    'vmware',
    'vbox',
    'virtualbox',
    'hyper-v',
    'vethernet',
    'wsl',
    'docker',
    'loopback',
    'tap',
    'tun',
    'utun',
    'tailscale',
    'zerotier',
    'hamachi',
    'bluetooth',
    'npcap',
  ];

  /// 探测本机可用的局域网地址。`null` = 一块合适的网卡都没有 / 扫不动。
  ///
  /// [scan] 是**可注入的缝**（§AT 的 `driveEnumerator` 同款）：不传就真扫网卡。
  static Future<String?> detect({NetScanner? scan}) async {
    try {
      final NetScanner scanner = scan ?? _scanReal;
      return choose(await scanner());
    } catch (_) {
      // 扫网卡本身失败（个别系统会抛 SocketException）⇒ 当作「找不到地址」。
      // **不上抛**：这会让一个本来能跑的服务整个起不来，而它其实只是画不出二维码。
      return null;
    }
  }

  /// 真扫网卡 —— **本文件唯一不可测的一行**（隔离在 [detect] 的默认参数后面）。
  static Future<List<NetCandidate>> _scanReal() async {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return fromInterfaces(interfaces);
  }

  /// 把 `dart:io` 的结果摊成 [NetCandidate]（测试可绕过这一步直接喂假数据）。
  static List<NetCandidate> fromInterfaces(List<NetworkInterface> interfaces) =>
      <NetCandidate>[
        for (final NetworkInterface iface in interfaces)
          NetCandidate(
            iface.name,
            <String>[
              for (final InternetAddress address in iface.addresses)
                address.address,
            ],
          ),
      ];

  /// **纯函数**：从候选里挑一个。
  static String? choose(List<NetCandidate> candidates) {
    final List<({String name, String address})> usable =
        <({String name, String address})>[
          for (final NetCandidate candidate in candidates)
            for (final String address in candidate.addresses)
              if (!_isLoopback(address) && !_isLinkLocal(address))
                (name: candidate.name, address: address),
        ];
    if (usable.isEmpty) return null;

    // ① 私有网段 **且** 非虚拟网卡
    for (final ({String name, String address}) entry in usable) {
      if (_isPrivate(entry.address) && !_isVirtual(entry.name)) {
        return entry.address;
      }
    }
    // ② 私有网段（哪怕网卡名像虚拟的）
    for (final ({String name, String address}) entry in usable) {
      if (_isPrivate(entry.address)) return entry.address;
    }
    // ③ 非虚拟网卡的任意地址
    for (final ({String name, String address}) entry in usable) {
      if (!_isVirtual(entry.name)) return entry.address;
    }
    // ④ 兜底：第一个
    return usable.first.address;
  }

  static bool _isLoopback(String ip) => ip.startsWith('127.');

  /// `169.254/16` —— 没拿到 DHCP 时 Windows 自赋的地址，对方不可达。
  static bool _isLinkLocal(String ip) => ip.startsWith('169.254.');

  static bool _isVirtual(String name) {
    final String lower = name.toLowerCase();
    return virtualMarkers.any(lower.contains);
  }

  /// `10/8`、`172.16~31/12`、`192.168/16`（RFC 1918）。
  static bool _isPrivate(String ip) {
    final List<int> parts = _octets(ip);
    if (parts.length != 4) return false;
    final int a = parts[0];
    final int b = parts[1];
    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    return false;
  }

  static List<int> _octets(String ip) => <int>[
    for (final String part in ip.split('.')) int.tryParse(part) ?? -1,
  ];
}
