/// **6 位短码配对**的状态机（提案 58 · A4 乙，2026-11-01 用户裁定）。
///
/// ## 它治的是什么
///
/// 配对二维码里那段 `shensuanzi://pair?host_id=…&ip=…&port=…&token=…&v=1`
/// **约 100 个字符** —— 用户原话「真是又臭又长，没人愿意输入」，
/// 连他自己都被「手动填地址」这个入口名误导成「只填 IP 就行」。
/// 短码把「抄 100 个字符」换成「看一眼电脑屏幕上的 6 个数字」。
///
/// ## 六条安全约束（用户裁定原文，逐条落到这里）
///
/// | # | 约束 | 落点 |
/// |---|---|---|
/// | 1 | 密码学随机，不能用时间戳 / 递增 | [Random.secure] + [issueCode] |
/// | 2 | 5 分钟过期，一次性，成功后立即失效 | [codeTtl] / [_CodeState.consumed] |
/// | 3 | 限制错误尝试，防暴力猜测 | [maxAttemptsPerCode] / [maxRequestsPerIp] |
/// | 4 | 电脑端显示待配对设备，由用户主动确认 | [pendingAwaiting] / [approve] |
/// | 5 | 短码不能进普通日志 | 本类**不存**码（见 [PairPending]）、HTTP 层只记固定标签 |
/// | 6 | 多个待配对请求不能互相覆盖或串号 | 每个请求一个 [PairPending.id]，确认按 id 绑定 |
///
/// ## 一个必须说清的安全边界：**短码本身不是凭据**
///
/// 拿到短码只能**建一条待确认请求**（[pendingAwaiting]），拿不到令牌 ——
/// 令牌要等电脑前的人点「允许」（[approve]）之后才随 [statusOf] 的
/// `approved` 下发。所以「猜到码」≠「连上电脑」。
/// 这也是为什么短码可以只有 6 位：**第二道闸是坐在电脑前的人**。
///
/// ## 为什么是纯 Dart
///
/// 时间、随机源都注入 ⇒ `dart test` 能把 5 分钟过期、限次、串号
/// 这些**靠人手点不出来的分支**逐条钉住（本仓铁律：判断在领域层，UI 只摆放）。
library;

import 'dart:math';

import 'auth.dart' show HostToken;

/// 一条待确认请求的状态。
///
/// 顺序即生命周期：`awaiting → approved | denied | expired`。
enum PairRequestStatus {
  /// 等电脑前的人点「允许 / 拒绝」
  awaiting,
  approved,
  denied,

  /// 5 分钟内没人处理（[PairRequests.requestTtl]）
  expired,
}

/// 请求被拒的原因。**每一项对应一句人话**（文案在 `http_server.dart` 与手机端）。
enum PairRejection {
  /// 码不对（还可能剩几次机会，见 [PairRequestResult.remaining])
  badCode,

  /// 试错次数用完了 ⇒ 这个码作废，必须换新码
  codeExhausted,

  /// 超过 5 分钟
  codeExpired,

  /// 已经被别的手机用掉了（一次性）
  codeConsumed,

  /// 电脑上还没生成过码
  noCode,

  /// 同一来源 IP 试得太频繁
  rateLimited,

  /// 电脑上还有几台等着确认，先处理完
  tooManyPending,
}

/// 一条待确认的配对请求。
///
/// ⚠️ **这个类里没有短码字段，是刻意的**：约束 5 要求「短码不进日志」，
/// 而最容易泄进日志的就是「把整个对象 toString 出去」。码根本不在对象里，
/// 就不存在「谁不小心打出来」这回事（[toString] 也因此可以放心用）。
class PairPending {
  const PairPending({
    required this.id,
    required this.deviceName,
    required this.ip,
    required this.createdAt,
    this.status = PairRequestStatus.awaiting,
    this.decidedAt,
  });

  /// 请求标识（16 位十六进制，来自 [Random.secure]）
  ///
  /// 手机轮询状态时用它 —— 也是「并发请求不串号」的载体（约束 6）。
  final String id;

  /// 手机自报的设备名（人话，如「安卓手机（Android 14）」）
  final String deviceName;

  /// **请求来源地址**（由服务端从 socket 取，不信客户端自报）
  final String ip;

  final int createdAt;

  final PairRequestStatus status;

  /// 被允许 / 拒绝 / 判超时的时刻
  final int? decidedAt;

  PairPending copyWith({PairRequestStatus? status, int? decidedAt}) =>
      PairPending(
        id: id,
        deviceName: deviceName,
        ip: ip,
        createdAt: createdAt,
        status: status ?? this.status,
        decidedAt: decidedAt ?? this.decidedAt,
      );

  /// 给电脑前的人看的一行：`安卓手机（Android 14）· 192.168.1.23`
  ///
  /// 约束 4 的「最好显示设备信息或请求来源」—— 两样都给，
  /// 因为用户认得出「我的手机」但认不出 IP，而 IP 能说明「是不是局域网里的设备」。
  String get label => deviceName.isEmpty ? ip : '$deviceName · $ip';

  @override
  String toString() => 'PairPending($id, $label, ${status.name})';
}

/// 一次配对请求的结果（成功 = 建了一条待确认请求）。
class PairRequestResult {
  const PairRequestResult.accepted(PairPending this.request)
    : rejection = null,
      remaining = 0;

  const PairRequestResult.rejected(
    PairRejection this.rejection, {
    this.remaining = 0,
  }) : request = null;

  /// 成功时非空
  final PairPending? request;

  /// 失败时非空
  final PairRejection? rejection;

  /// 码不对时还剩几次机会（给界面说「还可以试 N 次」）
  final int remaining;

  bool get ok => request != null;
}

/// 短码状态机（**服务运行期间**有效，随服务启停清空）。
class PairRequests {
  PairRequests({Random? random, int Function()? clock})
    : _random = random ?? Random.secure(),
      _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 短码有效期（约束 2：5 分钟）
  static const Duration codeTtl = Duration(minutes: 5);

  /// 一条待确认请求的存活期（没人处理就作废）
  static const Duration requestTtl = Duration(minutes: 5);

  /// 已判定（允许 / 拒绝）的记录**保留多久**供手机取走结果。
  ///
  /// 手机是 2 秒轮询一次，2 分钟足够；留太久等于把「已批准的凭据」多晾一会儿。
  static const Duration decidedTtl = Duration(minutes: 2);

  /// 同一来源 IP 的限次窗口（约束 3）
  static const Duration ipWindow = Duration(minutes: 1);

  /// 同一个码最多试错几次（约束 3）—— 6 位空间 100 万，5 次 ⇒ 猜中率 5e-6
  static const int maxAttemptsPerCode = 5;

  /// 同一 IP 一个窗口内最多请求几次（含正确的）—— 防「换码继续猜」
  static const int maxRequestsPerIp = 10;

  /// 同时最多几条待确认（约束 6：多台设备互不覆盖，但不能无限堆）
  static const int maxPending = 5;

  /// 短码位数
  static const int codeDigits = 6;

  final Random _random;
  final int Function() _clock;

  String? _code;
  int _codeIssuedAt = 0;
  int _failedAttempts = 0;
  _CodeState _codeState = _CodeState.none;

  /// 保序（Dart 的 `Map` 字面量保持插入顺序）—— 界面按「谁先来」排
  final Map<String, PairPending> _requests = <String, PairPending>{};

  /// 来源 IP → 窗口内的请求时刻
  final Map<String, List<int>> _ipAttempts = <String, List<int>>{};

  final List<void Function()> _listeners = <void Function()>[];

  // ------------------------------------------------------------ 码的生命周期

  /// 生成一个新码（**会作废上一个**）。
  ///
  /// 返回值给电脑端界面显示 —— 调用方**不许**把它写进日志（约束 5）。
  String issueCode({int? now}) {
    final int at = now ?? _clock();
    _code = _randomCode();
    _codeIssuedAt = at;
    _failedAttempts = 0;
    _codeState = _CodeState.active;
    _notify();
    return _code!;
  }

  /// 当前可用的码（过期 / 已用掉 / 从没生成 ⇒ `null`）。
  String? get code {
    final int at = _clock();
    return _alive(at) ? _code : null;
  }

  /// 当前码的到期时刻（毫秒）；没有可用码 ⇒ `null`
  int? get codeExpiresAt {
    final int at = _clock();
    if (!_alive(at)) return null;
    return _codeIssuedAt + codeTtl.inMilliseconds;
  }

  /// 还有几次试错机会
  int get remainingAttempts => _failedAttempts >= maxAttemptsPerCode
      ? 0
      : maxAttemptsPerCode - _failedAttempts;

  /// 电脑端界面要区分的四种情形（文案各不相同）
  PairRejection? get codeProblem {
    switch (_codeState) {
      case _CodeState.none:
        return PairRejection.noCode;
      case _CodeState.active:
        // 顺手把过期降级 —— 界面每秒重建一次，不需要额外的定时器判过期
        return _alive(_clock()) ? null : PairRejection.codeExpired;
      case _CodeState.expired:
        return PairRejection.codeExpired;
      case _CodeState.consumed:
        return PairRejection.codeConsumed;
      case _CodeState.exhausted:
        return PairRejection.codeExhausted;
    }
  }

  /// 6 位数字，密码学随机（约束 1）。
  ///
  /// `nextInt(1000000)` 在 `Random.secure()` 上是均匀的；
  /// `padLeft` 保证前导零也是 6 位（`000123` 与 `123` 不是一回事）。
  String _randomCode() {
    final int value = _random.nextInt(1000000);
    return value.toString().padLeft(codeDigits, '0');
  }

  /// 码还活着吗（顺手把过期的清掉）
  bool _alive(int at) {
    if (_codeState != _CodeState.active) return false;
    if (at - _codeIssuedAt >= codeTtl.inMilliseconds) {
      // 降级到 **expired** 而不是 none —— 见 [_CodeState] 的说明
      _codeState = _CodeState.expired;
      _code = null;
      _failedAttempts = 0;
      return false;
    }
    return true;
  }

  // ------------------------------------------------------------ 请求

  /// 手机带着 6 位码来请求配对。
  ///
  /// [ip] 必须是**服务端看到的来源地址**（不信请求体）。
  /// 成功 ⇒ 建一条 [PairRequestStatus.awaiting]，**同时把这个码作废**（一次性）。
  PairRequestResult request({
    required String code,
    required String deviceName,
    required String ip,
    int? now,
  }) {
    final int at = now ?? _clock();
    _sweep(at);

    // ① 限次（约束 3）—— 先记一次尝试，再看超没超
    final List<int> attempts = _ipAttempts.putIfAbsent(ip, () => <int>[]);
    if (attempts.length >= maxRequestsPerIp) {
      return const PairRequestResult.rejected(PairRejection.rateLimited);
    }
    attempts.add(at);

    // ② 码的可用性
    //
    // ⚠️ **顺序要紧**：先判「用掉了 / 试错作废」，再判过期。
    // 反过来写的话，`_alive` 对这两种状态都返回 false ⇒ 一律报「过期」，
    // 用户会看到一个**已经用掉**的码被说成「过期了」，照着提示换码也治不好。
    if (_codeState == _CodeState.none) {
      return const PairRequestResult.rejected(PairRejection.noCode);
    }
    if (_codeState == _CodeState.consumed) {
      return const PairRequestResult.rejected(PairRejection.codeConsumed);
    }
    if (_codeState == _CodeState.exhausted) {
      return const PairRequestResult.rejected(PairRejection.codeExhausted);
    }
    if (_codeState == _CodeState.expired) {
      return const PairRequestResult.rejected(PairRejection.codeExpired);
    }
    if (!_alive(at)) {
      return const PairRequestResult.rejected(PairRejection.codeExpired);
    }

    // ③ 对码
    if (!_sameCode(code, _code!)) {
      _failedAttempts++;
      if (_failedAttempts >= maxAttemptsPerCode) {
        // 试错用完 ⇒ 这个码作废（必须换新码，否则等于给无限次猜测）
        _codeState = _CodeState.exhausted;
        _code = null;
        _notify();
        return const PairRequestResult.rejected(PairRejection.codeExhausted);
      }
      _notify();
      return PairRequestResult.rejected(
        PairRejection.badCode,
        remaining: remainingAttempts,
      );
    }

    // ④ 队列上限（约束 6：可以并行，但不能无限堆）
    if (pendingAwaiting(now: at).length >= maxPending) {
      // ⚠️ **不消耗这个码** —— 用户去电脑上处理掉一条之后还能接着用
      return const PairRequestResult.rejected(PairRejection.tooManyPending);
    }

    // ⑤ 成立：一次性消耗（约束 2）
    final PairPending pending = PairPending(
      id: _newId(),
      deviceName: _cleanDevice(deviceName),
      ip: ip,
      createdAt: at,
    );
    _requests[pending.id] = pending;
    _codeState = _CodeState.consumed;
    _code = null;
    _failedAttempts = 0;
    _notify();
    return PairRequestResult.accepted(pending);
  }

  /// 还在等确认的请求（按发起顺序）
  List<PairPending> pendingAwaiting({int? now}) {
    final int at = now ?? _clock();
    _sweep(at);
    return <PairPending>[
      for (final PairPending p in _requests.values)
        if (p.status == PairRequestStatus.awaiting) p,
    ];
  }

  /// 电脑前的人点了「允许」（约束 4：**只有这里**能让手机拿到令牌）
  bool approve(String id, {int? now}) =>
      _decide(id, PairRequestStatus.approved, now);

  /// 电脑前的人点了「拒绝」
  bool deny(String id, {int? now}) =>
      _decide(id, PairRequestStatus.denied, now);

  bool _decide(String id, PairRequestStatus to, int? now) {
    final int at = now ?? _clock();
    _sweep(at);
    final PairPending? p = _requests[id];
    if (p == null || p.status != PairRequestStatus.awaiting) return false;
    _requests[id] = p.copyWith(status: to, decidedAt: at);
    _notify();
    return true;
  }

  /// 手机轮询：这条请求现在什么状态（`null` = 不认识 / 已清理）。
  ///
  /// ⚠️ 按 **id** 取，绝不按「最新一条」取 —— 那是「串号」的根源（约束 6）。
  PairRequestStatus? statusOf(String id, {int? now}) {
    final int at = now ?? _clock();
    _sweep(at);
    return _requests[id]?.status;
  }

  /// 服务停了 / 重新开始了 ⇒ 全部作废。
  void clear() {
    _code = null;
    _codeIssuedAt = 0;
    _failedAttempts = 0;
    _codeState = _CodeState.none;
    _requests.clear();
    _ipAttempts.clear();
    _notify();
  }

  // ------------------------------------------------------------ 内部

  /// 清理过期记录（每次对外调用都先跑一遍 —— 没有后台线程，也就没有「忘了清」）
  void _sweep(int at) {
    for (final MapEntry<String, PairPending> entry
        in _requests.entries.toList()) {
      final PairPending p = entry.value;
      if (p.status == PairRequestStatus.awaiting) {
        if (at - p.createdAt >= requestTtl.inMilliseconds) {
          _requests[entry.key] = p.copyWith(
            status: PairRequestStatus.expired,
            decidedAt: at,
          );
        }
        continue;
      }
      final int? decided = p.decidedAt;
      if (decided != null && at - decided >= decidedTtl.inMilliseconds) {
        _requests.remove(entry.key);
      }
    }
    _ipAttempts.removeWhere((String _, List<int> stamps) {
      stamps.removeWhere((int t) => at - t >= ipWindow.inMilliseconds);
      return stamps.isEmpty;
    });
  }

  /// 16 位十六进制（64 位随机）—— 手机拿它轮询，猜不出来（约束 6）
  String _newId() {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < 4; i++) {
      out.write(_random.nextInt(0x10000).toRadixString(16).padLeft(4, '0'));
    }
    return out.toString();
  }

  /// 对码：先掰全角（中文输入法把 `4` 打成 `４` 是真的会发生），再常量时间比较
  bool _sameCode(String candidate, String expected) =>
      HostToken.constantTimeEquals(normalizeCode(candidate), expected);

  /// **把中文输入法的全角数字掰回半角**，并去掉空格。
  ///
  /// 手机端有一份同样的逻辑（`PairingAddress.normalize`），这里是**服务端兜底**：
  /// 老版本手机端、或用户直接把全角数字粘进请求体时，不能因为输入法就判「码不对」。
  /// 两份都是十几行、口径必须一致（全角 `０-９` 与半角空格/全角空格）。
  static String normalizeCode(String raw) {
    final StringBuffer out = StringBuffer();
    for (final int rune in raw.runes) {
      if (rune >= 0xFF10 && rune <= 0xFF19) {
        out.writeCharCode(rune - 0xFF10 + 0x30);
      } else if (rune == 0x3000 || rune == 0x20 || rune == 0x09) {
        // 全角空格 / 半角空格 / 制表符：用户从屏幕上抄数字时常带上
        continue;
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString().trim();
  }

  /// 设备名只做**展示**：限长、去控制字符（防止别人在界面里塞换行搞乱版式）
  static String _cleanDevice(String raw) {
    final StringBuffer out = StringBuffer();
    for (final int rune in raw.runes) {
      if (rune < 0x20 || rune == 0x7F) continue;
      out.writeCharCode(rune);
      if (out.length >= 40) break;
    }
    final String text = out.toString().trim();
    return text.isEmpty ? '一台手机' : text;
  }

  // ------------------------------------------------------------ 监听

  /// 界面订阅它（有待确认请求 / 码变了 ⇒ 重画）。
  ///
  /// 与 `HostServiceController` 用同一套**纯 Dart 回调表**：
  /// host 包不依赖 Flutter，引 `ValueNotifier` 会把整包拖进 UI 层。
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final void Function() listener in List<void Function()>.of(
      _listeners,
    )) {
      listener();
    }
  }
}

/// 码的五种状态。
///
/// ⚠️ **`expired` 必须是独立状态，不能并进 `none`**（2026-11-01 真机联调抓到的 bug）：
/// 界面上「读到码」和「读到码为什么不能用」是**两次独立调用**
/// （`code` 与 `codeProblem`）。若过期时直接降级成 `none`，
/// 用户会看到「现在没有可用的配对码」—— 而事实是「这个码过期了」，
/// 两句话给出的下一步完全不同（前者像是没生成，后者才指向「换一个新码」）。
enum _CodeState { none, active, consumed, exhausted, expired }
