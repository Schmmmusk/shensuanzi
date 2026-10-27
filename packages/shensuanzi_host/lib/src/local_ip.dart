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

/// 一块网卡上的**一个**候选地址（网卡名 + 地址）—— 给「让用户自己挑」用。
///
/// 与 [NetCandidate] 的区别：[NetCandidate] 是 `dart:io` 的原始形状（一块卡
/// 可能挂多个地址），这个是**摊平并按优先级排好序**之后的一项。
class NetAddressOption {
  const NetAddressOption({required this.name, required this.address});

  /// 网卡名，如 `WLAN` / `以太网` / `natpierce`
  final String name;

  /// 该网卡上的一个 IPv4 字面量
  final String address;

  /// 给人看的一行（配对对话框里列出来，让用户认出哪个是自己家的 WiFi）
  String get label => '$address（$name）';

  @override
  String toString() => label;
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
/// 2. **真网卡名优先**（`WLAN` / `Wi-Fi` / `以太网` / `Ethernet` / `本地连接`…）
/// 3. **优先私有网段**：`192.168/16`、`10/8`、`172.16~31/12`
/// 4. **跳过虚拟网卡**：VirtualBox / VMware / WSL / Hyper-V / VPN / **穿透工具** 的地址
///    扫出来常常不可达 —— 用户会得到「二维码扫了连不上」这种最难查的故障
/// 5. 都挑不出来就退回第一个非 loopback 地址；一个都没有 ⇒ `null`
///    （UI 必须能处理 `null`：显示「找不到局域网地址 + 怎么办」，**不能画个假地址**）
///
/// ## ⚠️ 为什么规则 2 是**正向**的，而不是继续往黑名单里加名字（2026-10-25 D 批）
///
/// 复跑现场：机器上装了 `natpierce` 穿透工具，多出一块同名网卡（`10.6.22.1`）。
/// Windows 的枚举顺序把它排在 `WLAN` 之前，而 [virtualMarkers] 是**穷举法**、
/// 名单里没有它 ⇒ 旧规则 ① 直接命中隧道地址，手机 `http=000` 5 秒超时。
///
/// **只补名单治不了根**：用户装的下一个穿透工具（frp / ngrok / 雷池 / 公司 VPN…）
/// 照样不在名单里。所以加了**正向规则**——「名字像真网卡的优先」。两条一起用：
///
/// | 只有正向规则 | 只有黑名单 |
/// |---|---|
/// | 纯隧道环境（没真网卡）挑不出东西 | 换个没见过的穿透工具又踩 |
///
/// ## 职责划分（这条让「扫」与「选」都能测）
///
/// | 层 | 可测性 |
/// |---|---|
/// | [rank]（纯函数，排序的**唯一来源**） | ✅ 喂假候选，覆盖全部规则 |
/// | [choose]（= rank 取第一个） | ✅ 同上 |
/// | [detect] / [detectAll] 的**兜底分支**（空候选 / 全被过滤 / 扫不动） | ✅ 注入 [scan] 桩 |
/// | 真网卡扫描（[_scanReal]） | ❌ **唯一不可测的部分**，隔离在默认参数里 |
///
/// **`detect` / `detectAll` 永不抛**：拿不到网卡不是「启动失败」，只是「画不出二维码」——
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
  ///
  /// ⚠️ **这是黑名单，天生补不全**（2026-10-25 D 批）：用户装什么穿透工具
  /// 我们就得知道什么名字。所以真正的保障是 [realMarkers] 的正向规则，
  /// 这里只负责把「已知的坑」垫到最低优先级。
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
    // ---- 2026-10-25 复跑现场 + 同族（穿透 / VPN / 虚拟网卡）----
    // `natpierce` 是当天的现场元凶：它在 Windows 上排在 `WLAN` 之前，
    // 地址 `10.6.22.1` 也是私有网段 ⇒ 旧规则直接挑中它。
    'natpierce',
    'pierce',
    'ngrok',
    'frp',
    'nps',
    'openvpn',
    'wireguard',
    'wintun',
    'tap-windows',
    'softether',
    'shadowsocks',
    'v2ray',
    'xray',
    'clash',
    'easyconnect',
    'sangfor',
    'anyconnect',
    'globalprotect',
    'fortinet',
    'radmin',
    'teamviewer',
    // Windows 的「WAN Miniport」家族 —— 名字里没有 VPN 字样，但都是拨号/隧道口
    'wan miniport',
    'pptp',
    'l2tp',
    'sstp',
    'ikev2',
    'pppoe',
    'ipsec',
  ];

  /// 真网卡的名字片段（小写比较）—— **正向规则**。
  ///
  /// 与 [virtualMarkers] 互为保险：黑名单补不全（用户装什么我们不知道），
  /// 正向名单则覆盖「绝大多数人家里/店里就一块 WiFi 或一块网线」这个主流情况。
  ///
  /// ⚠️ 命中这里**不等于**一定选它 —— [rank] 里虚拟判定优先，所以
  /// `vEthernet (WSL)` 虽然含 `ethernet` 也不会被当成真网卡。
  static const List<String> realMarkers = <String>[
    'wlan',
    'wi-fi',
    'wifi',
    '无线',
    '以太网',
    '本地连接',
    'ethernet',
    'eth',
    'wlp',
    'enp',
    'en0',
    'en1',
  ];

  /// 探测本机可用的局域网地址。`null` = 一块合适的网卡都没有 / 扫不动。
  ///
  /// [scan] 是**可注入的缝**（§AT 的 `driveEnumerator` 同款）：不传就真扫网卡。
  static Future<String?> detect({NetScanner? scan}) async {
    final List<NetAddressOption> all = await detectAll(scan: scan);
    return all.isEmpty ? null : all.first.address;
  }

  /// 探测**全部**可用地址（已按优先级排好序）—— 给「让用户自己挑」用。
  ///
  /// 为什么要有这个：规则再准也不可能覆盖所有机器（用户的网卡名千奇百怪）。
  /// 一旦挑错，用户看到的现象只是「手机连不上」，**没有任何办法自救** ——
  /// 所以配对对话框把候选全列出来，让他点一下换一个。
  ///
  /// 永不抛（同 [detect]）；扫不动 ⇒ 空列表。
  static Future<List<NetAddressOption>> detectAll({NetScanner? scan}) async {
    try {
      final NetScanner scanner = scan ?? _scanReal;
      return rank(await scanner());
    } catch (_) {
      // 扫网卡本身失败（个别系统会抛 SocketException）⇒ 当作「找不到地址」。
      // **不上抛**：这会让一个本来能跑的服务整个起不来，而它其实只是画不出二维码。
      return const <NetAddressOption>[];
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
  static List<NetCandidate> fromInterfaces(
    List<NetworkInterface> interfaces,
  ) => <NetCandidate>[
    for (final NetworkInterface iface in interfaces)
      NetCandidate(iface.name, <String>[
        for (final InternetAddress address in iface.addresses) address.address,
      ]),
  ];

  /// **纯函数**：从候选里挑一个。= [rank] 取第一个。
  static String? choose(List<NetCandidate> candidates) {
    final List<NetAddressOption> ranked = rank(candidates);
    return ranked.isEmpty ? null : ranked.first.address;
  }

  /// **纯函数**：把候选摊平并**按优先级排序** —— 排序逻辑的**唯一来源**
  /// （[choose] 与 UI 的候选列表都吃这一份，不另写一遍）。
  ///
  /// 分档（数字越小越优先）：
  ///
  /// | 档 | 条件 | 说明 |
  /// |---|---|---|
  /// | 0 | 私有网段 + **真网卡名** | 主流情况：家里/店里一块 WiFi 或一块网线 |
  /// | 1 | 私有网段 + 非虚拟名 | 名字不认识但也不像虚拟 ⇒ 大概是真网卡 |
  /// | 2 | 私有网段 + 虚拟名 | 只剩隧道时也得给个地址（见 [choose] 的兜底约定） |
  /// | 3 | 公网地址 + 非虚拟名 | 没有私有网段（罕见） |
  /// | 4 | 其余 | 第一个总比 `null` 好 |
  ///
  /// ⚠️ **虚拟判定优先于真网卡判定**：`vEthernet (WSL)` 的名字里含 `ethernet`，
  /// 若先看正向名单就会把它当"真网卡" —— 这正是既有用例
  /// 「虚拟网卡被跳过（WSL 的 172.x 不抢真网卡）」守着的边界。
  ///
  /// 同档内保持**枚举顺序**（分桶收集，不用 `sort` —— Dart 的 `sort` 不保证稳定）。
  static List<NetAddressOption> rank(List<NetCandidate> candidates) {
    final List<NetAddressOption> usable = <NetAddressOption>[
      for (final NetCandidate candidate in candidates)
        for (final String address in candidate.addresses)
          if (!_isLoopback(address) && !_isLinkLocal(address))
            NetAddressOption(name: candidate.name, address: address),
    ];
    if (usable.isEmpty) return const <NetAddressOption>[];

    final List<List<NetAddressOption>> buckets = <List<NetAddressOption>>[
      for (int i = 0; i < 5; i++) <NetAddressOption>[],
    ];
    for (final NetAddressOption option in usable) {
      buckets[_tier(option.name, option.address)].add(option);
    }
    return <NetAddressOption>[
      for (final List<NetAddressOption> b in buckets) ...b,
    ];
  }

  static int _tier(String name, String address) {
    final bool private = _isPrivate(address);
    if (_isVirtual(name)) return private ? 2 : 4;
    if (private && _isRealNic(name)) return 0;
    if (private) return 1;
    return 3;
  }

  static bool _isLoopback(String ip) => ip.startsWith('127.');

  /// `169.254/16` —— 没拿到 DHCP 时 Windows 自赋的地址，对方不可达。
  static bool _isLinkLocal(String ip) => ip.startsWith('169.254.');

  static bool _isVirtual(String name) {
    final String lower = name.toLowerCase();
    return virtualMarkers.any(lower.contains);
  }

  /// 名字像真网卡（WiFi / 网线）。⚠️ 调用方必须**先**判 [_isVirtual]。
  static bool _isRealNic(String name) {
    final String lower = name.toLowerCase();
    return realMarkers.any(lower.contains);
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
