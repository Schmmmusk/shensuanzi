import 'dart:io';

import 'package:shensuanzi_core/shensuanzi_core.dart';

import 'auth.dart';
import 'http_server.dart';
import 'local_ip.dart';
import 'pairing.dart';

/// 主机服务的启停状态（`docs/reply_review.md` §AH · AH-A）。
enum HostServiceState {
  /// 没开（**每次启动应用都是这个状态** —— §AH 遗漏 5：开关不持久化，
  /// 监听端口必须是**显式用户动作**，不是开机默认行为）
  stopped,

  /// 正在绑端口
  starting,

  /// 在听
  running,

  /// 起不来（端口被占 / 防火墙）。**必须给出「怎么办」**（同 §AE 备份的口径）
  failed,
}

/// 某一刻的**状态快照**（不可变）+ **全部用户可见文案**。
///
/// ## 为什么文案在这里而不是 UI
///
/// 与 §AE 备份同一条纪律：**错误信息由领域层给出、UI 不造句**。
/// 「端口被占用怎么办」是产品判断，不是排版。
class HostServiceSnapshot {
  const HostServiceSnapshot({
    required this.state,
    this.port,
    this.address,
    this.failureHint,
    this.addressHint,
    this.needsReset = false,
    this.qrAvailable = false,
    this.trafficCount = 0,
    this.lastTrafficAt,
  });

  final HostServiceState state;

  /// 实际生效的端口（`null` = 没在听）
  final int? port;

  /// 局域网 IPv4（二维码里那个地址）。`null` = 没探到合适网卡
  final String? address;

  /// **致命**失败的「怎么办」（仅 `state == failed`）
  final String? failureHint;

  /// **非致命**提示：服务在听，但探不到局域网地址（仅 `running && address == null`）
  final String? addressHint;

  /// 服务在听，但**手里没有明文令牌**（重启后哈希不可逆）⇒ 画不出二维码，
  /// 要换手机连接必须**重新生成配对码**（会作废已配对的手机）
  final bool needsReset;

  /// 现在能画二维码（= 在听 + 有明文 + 有地址）
  final bool qrAvailable;

  /// 本次启动后**通过鉴权**的请求次数（有人真的在用，不是被扫端口）
  final int trafficCount;

  /// 最近一次通过鉴权的时间
  final int? lastTrafficAt;

  bool get isRunning => state == HostServiceState.running;

  // ------------------------------------------------------------ 文案

  /// 打开开关时旁边的解释（§AH 遗漏 5：要讲清「打开」意味着什么）
  static const String switchHint = '打开后，同一 WiFi 下的手机可以扫码连接这里的数据';

  /// 二维码下面那行（§AH 遗漏 4）
  static const String qrHint = '用手机上的神算子扫这个码';

  /// 重置按钮的后果（§AH 遗漏 4 的空白处 —— 见 [needsReset]）
  static const String resetWarning = '重新生成后，已经连过的手机需要重新扫码';

  /// 状态行主文案
  String get headline {
    switch (state) {
      case HostServiceState.stopped:
        return '已关闭';
      case HostServiceState.starting:
        return '正在启动…';
      case HostServiceState.running:
        return '已开启';
      case HostServiceState.failed:
        return '启动失败';
    }
  }

  /// 状态行副文案（失败时就是「怎么办」）
  String? get detail {
    switch (state) {
      case HostServiceState.stopped:
        return null;
      case HostServiceState.starting:
        return null;
      case HostServiceState.running:
        return addressHint;
      case HostServiceState.failed:
        return failureHint;
    }
  }

  /// **手输兜底**（§AH 遗漏 4：扫码失败时用户要能手打地址）
  String? get addressLine {
    final int? port = this.port;
    final String? address = this.address;
    if (port == null || address == null) return null;
    return '主机地址：$address:$port';
  }

  /// 服务在听时显示的一行；`running` 之外恒为 `null`。
  ///
  /// ⚠️ **不是「已连接设备：N 台」** —— 按设备计数要客户端身份（属 AH-B），
  /// v1 没有。这里报的是**本次启动后收到过多少次同步**，宁可少说，
  /// 也不编一个「0 台」出来（见 `reply_review.md` §BB·五）。
  String? trafficLabel(int now) {
    if (!isRunning) return null;
    final int? at = lastTrafficAt;
    if (at == null) return '还没有手机连接过';
    final int minutes = (now - at) ~/ 60000;
    if (minutes <= 0) return '最近连接：刚刚';
    if (minutes < 60) return '最近连接：$minutes 分钟前';
    return '最近连接：${minutes ~/ 60} 小时前';
  }
}

/// 主机服务的**启停控制器**（纯 Dart —— 判断在这里，Flutter 只摆放）。
///
/// ## 职责边界
///
/// | 在这里 | 不在这里 |
/// |---|---|
/// | 状态迁移（关 → 启 → 听 / 失败） | 监听端口本身（→ [HostHttpServer]） |
/// | 令牌生命周期（取用 / 重置） | 令牌的密码学（→ [HostToken]） |
/// | 局域网地址探测 | 二维码**渲染**（→ 根 Flutter 应用） |
/// | 全部用户可见文案 | 排版 |
///
/// ## 一个容易踩的坑：**服务捕获的是「构造那一刻」的 identity**
///
/// `HostHttpServer` 在 `start` 时把 [HostIdentity] 快照交给路由，鉴权用的是那份。
/// 所以 [resetToken] **必须连服务一起重启** —— 否则新令牌画得出来，
/// 手机带着新令牌进来还是 401（「二维码是新的、就是连不上」这种最难查的故障）。
class HostServiceController {
  HostServiceController({
    required Db db,
    required HostIdentityStore identities,
    PortRange ports = PortRange.defaults,
    Future<String?> Function()? detectLocalIp,
    int Function()? clock,
  }) : _db = db,
       _identities = identities,
       _ports = ports,
       _detectLocalIp = detectLocalIp ?? LocalIp.detect,
       // ⚠️ 括号不能省：初始化列表里 `?? ` 后面直接跟 `() => ...` 会被解析成
       // 「构造函数带返回类型」而报错（Dart 的已知歧义）
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Db _db;
  final HostIdentityStore _identities;
  final PortRange _ports;
  final Future<String?> Function() _detectLocalIp;
  final int Function() _clock;

  HostHttpServer? _server;
  HostServiceState _state = HostServiceState.stopped;
  String? _failureHint;
  String? _addressHint;

  /// **持有明文的那一份**。会话内一直留着 —— 用户可以反复看二维码。
  /// 重启应用后只能拿到哈希版（明文不可逆）。
  HostIdentity? _identity;

  String? _address;
  int _trafficCount = 0;
  int? _lastTrafficAt;

  HostServiceState get state => _state;

  HostServiceSnapshot get snapshot => HostServiceSnapshot(
    state: _state,
    port: _server?.port,
    address: _address,
    failureHint: _state == HostServiceState.failed ? _failureHint : null,
    addressHint: _addressHint,
    needsReset: _state == HostServiceState.running && !_canShowQr,
    qrAvailable: _state == HostServiceState.running && pairingPayload != null,
    trafficCount: _trafficCount,
    lastTrafficAt: _lastTrafficAt,
  );

  /// 手里是否有**明文**令牌（判断依据是 `HostIdentity.plaintextToken`）
  bool get _canShowQr => _identity?.canShowQr ?? false;

  /// 配对载荷；**画不出二维码时返回 `null`**（没明文 / 没地址 / 没在听）。
  PairingPayload? get pairingPayload {
    final HostIdentity? identity = _identity;
    final String? token = identity?.plaintextToken;
    final String? address = _address;
    final int? port = _server?.port;
    if (identity == null || token == null || address == null || port == null) {
      return null;
    }
    return PairingPayload(
      hostId: identity.hostId,
      ip: address,
      port: port,
      token: token,
    );
  }

  /// 启动。已经开着就是 no-op（**幂等**：用户多点一次不该看到报错）。
  Future<HostServiceSnapshot> start() async {
    if (_state == HostServiceState.running ||
        _state == HostServiceState.starting) {
      return snapshot;
    }
    _state = HostServiceState.starting;
    _failureHint = null;
    _addressHint = null;
    try {
      // ⚠️ 先看**会话内已有的**那份（可能带着明文），再退回读盘 / 新建。
      // 直接 `load() ?? reset()` 会把 [resetToken] 刚生成的明文丢掉 ——
      // 因为 `load()` 只读得到哈希。
      _identity ??= _identities.load() ?? _identities.reset(now: _clock());
      _address = await _detectLocalIp();
      if (_address == null) {
        _addressHint =
            '找不到局域网地址。请先把电脑连上路由器或手机热点，再关掉重开这个服务。';
      }
      _server = await HostHttpServer.start(
        db: _db,
        identity: _identity!,
        ports: _ports,
        onAuthenticated: _noteTraffic,
      );
      _state = HostServiceState.running;
    } on StateError {
      // HostHttpServer 的端口耗尽信号（它自己那条文案是给开发者看的）
      _failureHint =
          '端口 ${_ports.start}~${_ports.end} 都被占用了。'
          '请关掉可能占用它们的程序，或检查防火墙有没有拦下本软件，然后重试。';
      _state = HostServiceState.failed;
    } catch (error) {
      _failureHint = '启动服务失败：$error。可以重试；若一直失败，请重启软件。';
      _state = HostServiceState.failed;
    }
    return snapshot;
  }

  /// 关闭。没开着就是 no-op。
  Future<HostServiceSnapshot> stop() async {
    final HostHttpServer? server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
    _state = HostServiceState.stopped;
    _address = null;
    _failureHint = null;
    _addressHint = null;
    _trafficCount = 0;
    _lastTrafficAt = null;
    return snapshot;
  }

  /// 重新生成配对码 —— **作废所有已配对的手机**（§9.3「一键重置」）。
  ///
  /// 两种时机：① 用户换了手机 / 想收回旧手机；② **重启应用后想再显示二维码**
  /// （明文不落盘，重启后哈希画不出码）。
  Future<HostServiceSnapshot> resetToken() async {
    final bool wasRunning = _state == HostServiceState.running;
    if (wasRunning) await stop();
    // 重新生成后 `_identity` 带着明文 ⇒ [start] 里 `??=` 会直接用它，不会覆盖
    _identity = _identities.reset(now: _clock());
    if (wasRunning) return start();
    return snapshot;
  }

  void _noteTraffic() {
    _trafficCount++;
    _lastTrafficAt = _clock();
  }
}

/// `host.json` 在数据目录里的位置（`auth.dart` 的口径：主机设施放文件、
/// **不动 schema**）。
///
/// 参数是**路径字符串**（不是 `Directory`）—— 因为调用方 `DataLocation.directory`
/// 就是 `String`（`shensuanzi_app/lib/src/bootstrap.dart:50`），
/// 在这里收 `Directory` 只会逼每个调用点多写一次包装。
///
/// 拼接用 `Platform.pathSeparator` 而**不引 `package:path`**：
/// 本包只此一处拼路径，为一次 join 加一个依赖不划算
/// （`p.join` 唯一的额外好处是能吃掉结尾多余的分隔符，Windows 本来就容忍）。
File hostIdentityFile(String dataDirectory) => File(
  '$dataDirectory${Platform.pathSeparator}$hostIdentityFileName',
);

/// `host.json` 的文件名（`HostIdentityStore` 只接受一个 `File`，
/// 名字散在各调用点早晚会漂移 —— 收在这里一处）。
const String hostIdentityFileName = 'host.json';
