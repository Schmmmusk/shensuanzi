import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'dpapi.dart';
import 'host_write.dart';

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

/// 启动时**令牌明文能不能恢复**（2026-11-01，提案 57 裁定 ②③⑤）。
///
/// 为什么要一个显式状态而不是 `plaintextToken == null` 一个布尔：
/// 「只存了哈希」「密文解不开」「密文与哈希不符」对用户是**三件不同的事**，
/// 提示语和下一步动作都不一样（前者重新生成一次就好，后两者要先说清原因）。
enum TokenRestoreState {
  /// 没有身份记录（全新安装 / 文件不在）
  missing,

  /// 明文恢复了 —— 能画码
  restored,

  /// 只有哈希：老文件（v1），或本次加密失败
  hashOnly,

  /// 密文在，但解不开（换了 Windows 用户 / 换了机器 / 密文损坏）
  undecryptable,

  /// 解出来了，但 `sha256(明文) != token_hash` —— **两份身份数据互相矛盾**
  mismatch,

  /// `scheme` 不认识（将来换了算法 / 被手工改过）
  unsupported,
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
  bool authorizes(String? candidate) => HostToken.matches(candidate, tokenHash);

  /// 落盘用的 JSON。
  ///
  /// [protectedToken] = DPAPI 密文（base64）；`null` 时**只写哈希**，
  /// 行为与升级前完全一致（重启后画不出码，要重新生成）。
  ///
  /// ⚠️ 写进去的**永远不是明文** —— 明文只在内存里活，密文由操作系统保管。
  Map<String, Object?> toJson({String? protectedToken}) => <String, Object?>{
    // v2 起多一个 `token_protected`；**读的时候不看版本号**（有字段就试），
    // 所以老程序读新文件也不会崩（只是忽略这个字段）。
    'version': protectedToken == null ? 1 : 2,
    'host_id': hostId,
    // ⚠️ 只写哈希。写明文就等于把「只存哈希」这条设计作废。
    'token_hash': tokenHash,
    'created_at': createdAt,
    if (protectedToken != null)
      'token_protected': <String, Object?>{
        'scheme': dpapiScheme,
        'blob': protectedToken,
      },
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
  HostIdentityStore(
    this.file, {
    HostWriteIo io = const RealHostWriteIo(),
    TokenProtector protector = const DpapiTokenProtector(),
  }) : _memory = null,
       _io = io,
       _protector = protector;

  /// 不碰文件系统 —— 单测与自检用。
  ///
  /// `file == null` 就是「内存模式」的判据；[_memory] 是它的存储槽，
  /// **初值必须是 `null`（= 还没存过）**，而不是空 map ——
  /// 空 map 会让 [load] 误判成「已存过一条记录」。
  HostIdentityStore.inMemory({
    TokenProtector protector = const DpapiTokenProtector(),
  }) : file = null,
       _memory = null,
       _io = const RealHostWriteIo(),
       _protector = protector;

  /// `null` = 纯内存模式
  final File? file;

  /// 文件操作（**测试注入故障的接缝**；生产用 `dart:io`）
  final HostWriteIo _io;

  /// 令牌明文的加解密（**测试注入的接缝**：能强制「加密失败」）
  final TokenProtector _protector;

  /// 上一次「加密令牌」是否失败（`null` = 没失败 / 没试过）。
  ///
  /// 裁定 ③：加密失败时**允许**当前进程继续用内存令牌，但界面必须明说
  /// 「配对码本次运行有效，重启后可能需要重新生成」—— 不能报成「保存成功」。
  String? get lastProtectProblem => _lastProtectProblem;
  String? _lastProtectProblem;

  /// 上一次读取时**明文恢复到了什么程度**（裁定 ②③⑤）
  TokenRestoreState get lastRestoreState => _lastRestoreState;
  TokenRestoreState _lastRestoreState = TokenRestoreState.missing;

  /// 上一次读取时恢复失败的原因（`null` = 没失败）
  String? get lastRestoreProblem => _lastRestoreProblem;
  String? _lastRestoreProblem;

  /// 上一次写盘的**完整现场**（一行日志；`null` = 没失败过）
  ///
  /// 用户裁定（提案 56 批复 §二）：失败时日志要能准确说出**失败在哪一步** ——
  /// 只记一个 `errno` 不够，`create-parent` / `write-temp` / `rename` 三种失败
  /// 的调查方向完全不同。
  String? get lastWriteDiagnostics => _lastWriteDiagnostics;
  String? _lastWriteDiagnostics;

  /// 上一次写盘**最终落在哪一级**（`rename` / `inPlace` / `memory`）。
  ///
  /// 诊断用：`lastWriteFailed == false` 只说明「写成了」，不说明是 L1 原子写成的
  /// 还是 L2 原地重写成的 —— 而这两件事对「根因是什么」的指向完全不同。
  HostWriteLevel? get lastWriteLevel => _lastWriteLevel;
  HostWriteLevel? _lastWriteLevel;

  Map<String, Object?>? _memory;

  /// 上一次写盘**是否失败**（2026-10-31 真机：`host.json` 被拒写）。
  ///
  /// 失败时身份只活在本次运行里 —— 配对能用，重启后要重新生成码。
  /// **不能让写盘失败把「配对」这个功能整个废掉**：那是把一个小故障
  /// 升级成「手机永远连不上」。
  bool get lastWriteFailed => _lastWriteFailed;
  bool _lastWriteFailed = false;

  /// 上一次写盘失败的**原文**（`null` = 没失败过）。
  ///
  /// ## 为什么留它（2026-10-31 真机，联调待解决 #1）
  ///
  /// 那次 `host.json` 被拒写（`PathAccessException ... errno = 5`），
  /// 而 ACL / SDDL / 只读属性 / 完整性标签**全部排除**（与 `shensuanzi.db`
  /// 逐字节相同；同一用户、同一文件，我方进程能写、App 不能）—— **根因至今未定**。
  ///
  /// 没有这条记录，失败就只剩一个 `lastWriteFailed = true` 的布尔值：
  /// 下次真机复现，日志里看不到任何 errno，等于**又要从零查一遍**。
  /// 有它，宿主就能把原文写进日志（见 `ServiceController.resetToken`）。
  String? get lastWriteProblem => _lastWriteProblem;
  String? _lastWriteProblem;

  /// 读取已存的主机身份。
  ///
  /// **返回的实例里 [HostIdentity.plaintextToken] 恒为 `null`** ——
  /// 哈希不可逆，明文没法从文件里还原。要拿到明文必须 [reset]。
  HostIdentity? load() {
    final Map<String, Object?>? stored = _read();
    if (stored == null) return null;
    // ⚠️ 2026-10-31 实测（L2 探针）：文件是**合法 JSON 但字段不全**时，
    // 从前这里三个 `!` 会抛 `Null check operator used on a null value` ——
    // 与「半截 JSON」同一个后果（主机服务启动失败、用户不知道该删哪个文件），
    // 只是更难查（JSON 解析没报错）。所以字段类型逐个验，缺一个就当作没有身份。
    final Object? hostId = stored['host_id'];
    final Object? tokenHash = stored['token_hash'];
    final Object? createdAt = stored['created_at'];
    if (hostId is! String || tokenHash is! String || createdAt is! int) {
      _lastReadProblem =
          '身份文件字段不全（host_id=${hostId.runtimeType}, '
          'token_hash=${tokenHash.runtimeType}, created_at=${createdAt.runtimeType}）：'
          '${file?.path ?? '（内存）'}';
      return null;
    }
    final HostIdentity identity = HostIdentity(
      hostId: hostId,
      tokenHash: tokenHash,
      createdAt: createdAt,
    );
    return _withRestoredToken(identity, stored);
  }

  /// 把 `token_protected` 里的密文解回明文（裁定 ②）。
  ///
  /// ## 三道关，缺一不可
  ///
  /// 1. `scheme` 必须认识（将来换算法靠它区分，不认识就**明说**，不猜）；
  /// 2. 解密必须成功（换 Windows 用户 / 换机器 / 密文损坏 ⇒ 失败）；
  /// 3. **`sha256(明文) == token_hash`**（裁定原文：不一致时不得展示二维码，
  ///    也不得静默修正身份）。
  ///
  /// 任何一关不过 ⇒ 返回**原样的身份**（只有哈希），并把原因记进
  /// [lastRestoreState] / [lastRestoreProblem]。
  /// ⚠️ **绝不返回 `null`**：`loadOrCreate()` 是「没有身份就创建」，
  /// 返回 `null` 会**静默轮换令牌**，把所有手机踢下线（裁定 ⑤ 明确禁止）。
  HostIdentity _withRestoredToken(
    HostIdentity identity,
    Map<String, Object?> stored,
  ) {
    _lastRestoreProblem = null;
    final Object? raw = stored['token_protected'];
    if (raw == null) {
      _lastRestoreState = TokenRestoreState.hashOnly;
      return identity;
    }
    if (raw is! Map) {
      _lastRestoreState = TokenRestoreState.unsupported;
      _lastRestoreProblem = 'token_protected 不是对象（${raw.runtimeType}）';
      return identity;
    }
    final Object? scheme = raw['scheme'];
    final Object? blob = raw['blob'];
    if (scheme != dpapiScheme || blob is! String || blob.isEmpty) {
      _lastRestoreState = TokenRestoreState.unsupported;
      _lastRestoreProblem = '不认识的加密方案：scheme=$scheme';
      return identity;
    }
    final String? plaintext = _protector.unprotect(
      blob,
      hostId: identity.hostId,
    );
    if (plaintext == null) {
      _lastRestoreState = TokenRestoreState.undecryptable;
      _lastRestoreProblem = _protector.isSupported
          ? '密文解不开（可能换了 Windows 用户或换了电脑）'
          : '这台电脑不支持加密存储';
      return identity;
    }
    if (HostToken.hashOf(plaintext) != identity.tokenHash) {
      // 两份身份数据互相矛盾 ⇒ 谁的都不信，**明文丢弃**
      _lastRestoreState = TokenRestoreState.mismatch;
      _lastRestoreProblem = '密文解出来的令牌与 token_hash 不一致';
      return identity;
    }
    _lastRestoreState = TokenRestoreState.restored;
    return HostIdentity(
      hostId: identity.hostId,
      tokenHash: identity.tokenHash,
      createdAt: identity.createdAt,
      plaintextToken: plaintext,
    );
  }

  /// 首次启动：没有就生成并持久化（§9.3「Token 首次启动生成」）。
  /// 已有则原样读回（此时 [HostIdentity.canShowQr] 为 `false`）。
  HostIdentity loadOrCreate({required int now, Random? random}) =>
      load() ?? reset(now: now, random: random);

  /// 生成 / 重置令牌（§9.3「一键重置」）。
  ///
  /// **`host_id` 持久化不变**（C-3，2026-10-24 用户裁定 ⑦甲）：只轮换令牌 ——
  /// 所有已配对设备仍需重新扫码（旧令牌失效），但主机身份还是同一台。
  /// 从前 `host_id` 一并更换 ⇒「重启电脑想再看二维码 ⇒ 重新生成 ⇒ 手机重扫
  /// ⇒ 全量重建镜像 + 离线队列全部挂起」，而 `Agents.md` §4.2 承诺的
  /// 「同主机重新配对（`host_id` 不变）不清」**几乎永远走不到**。
  ///
  /// 真正的换主机（换电脑 / 换数据目录）走的是另一条路：新数据目录没有
  /// 身份记录 ⇒ [loadOrCreate] 自然生成新的 `host_id`。
  HostIdentity reset({required int now, Random? random}) {
    final String plaintext = HostToken.generate(random: random);
    final HostIdentity next = HostIdentity(
      hostId: load()?.hostId ?? newId(),
      tokenHash: HostToken.hashOf(plaintext),
      createdAt: now,
      plaintextToken: plaintext,
    );
    // 裁定 ②③：加密失败**不阻断**本次配对（内存令牌照用），但必须记下来 ——
    // 界面据此提示「本次运行有效，重启后要重新生成」，不许报成保存成功。
    final String? protectedToken = _protector.protect(
      plaintext,
      hostId: next.hostId,
    );
    _lastProtectProblem = protectedToken == null
        ? (_protector.isSupported ? '系统加密失败' : '这台电脑不支持加密存储')
        : null;
    try {
      _write(next, protectedToken: protectedToken);
      _lastWriteFailed = false;
      _lastWriteProblem = null;
    } catch (error) {
      // ⚠️ **不抛**（2026-10-31 真机）：`host.json` 写不进去时，从前异常一路
      // 穿到界面 ⇒ 二维码永远画不出来 ⇒ 手机永远连不上。
      // 现在降级：令牌只在本进程内存里有效 —— 本次能配对，重启后失效
      // （那时再生成一次即可）。**比「功能直接不可用」好得多。**
      _lastWriteFailed = true;
      // 原文留着给日志（根因未定，见 [lastWriteProblem] 的注释）
      _lastWriteProblem = error.toString();
    }
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
    try {
      return Map<String, Object?>.from(
        jsonDecode(target.readAsStringSync()) as Map<Object?, Object?>,
      );
    } catch (error) {
      // 2026-10-31 用户裁定（提案 56 批复 §三 故障注入表最后一行）：
      // 「写入过程中进程异常退出 ⇒ 下次启动**能够识别损坏文件，不应直接崩溃**」。
      //
      // L2 原地重写在「截断之后、写完之前」被打断时，`host.json` 会变成
      // 空文件或半截 JSON。从前这里直接 `jsonDecode` ⇒ 抛 FormatException ⇒
      // 一路冒到主机服务启动 ⇒ 界面「启动服务失败」，而用户完全不知道
      // 该删哪个文件。现在：**认作「没有身份」**（随后会生成新的），
      // 并把原文记下来进日志。
      _lastReadProblem = '身份文件读不懂（${error.runtimeType}）：${target.path}';
      return null;
    }
  }

  /// 上一次**读**身份文件失败的原因（`null` = 没失败过）。
  ///
  /// 与 [lastWriteProblem] 分开：读失败意味着「要重新生成身份」，
  /// 写失败意味着「这次能配对、重启后失效」—— 两件事的后果不同。
  String? get lastReadProblem => _lastReadProblem;
  String? _lastReadProblem;

  /// 落盘：**原子写 + 重试**。
  ///
  /// 直接 `writeAsStringSync(目标)` 是「打开就截断再写」，只要那一瞬间有别的
  /// 进程（杀毒 / 索引器 / 备份软件）攥着文件，整次就失败 ——
  /// 2026-10-31 真机就是这样：`PathAccessException ... errno = 5`。
  ///
  /// 改成「写临时文件 → rename 覆盖」：临时文件是**新文件**，不会撞上任何锁；
  /// rename 只需要极短的独占窗口。仍然失败就重试三次（60/120/180ms）。
  void _write(HostIdentity identity, {String? protectedToken}) {
    final Map<String, Object?> json = identity.toJson(
      protectedToken: protectedToken,
    );
    if (file == null) {
      _memory = json;
      return;
    }
    final File target = file!;
    final String text = const JsonEncoder.withIndent('  ').convert(json);

    final HostWriteReport report = HostWriteReport(
      level: HostWriteLevel.memory,
      target: target.path,
      temp: '${target.path}.tmp',
      targetExisted: false,
      steps: <String>[],
      retries: <String>[],
    );

    // L1 临时文件 + rename → L2 原地重写 → L3 内存（见 `host_write.dart` 文件头）
    writeIdentityFile(
      target: target,
      text: text,
      report: report,
      io: _io,
    );

    _lastWriteLevel = report.level;
    if (report.ok) {
      _lastWriteDiagnostics = null;
      return;
    }

    // 只有失败时才去摸环境（`attrib` / `whoami` 要起进程，平时不跑）
    collectEnvironment(report, target);
    _lastWriteDiagnostics = report.toLogLine();
    throw FileSystemException(
      '写不进 $file（${report.stage}，errno ${report.errno}）',
      target.path,
    );
  }
}
