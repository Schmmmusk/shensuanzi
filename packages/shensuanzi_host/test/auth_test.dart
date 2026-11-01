// 令牌与主机身份（`docs/sync_protocol.md` §9.1 / §9.3）。
//
// 核心主张：**只持久化哈希**，校验用**常量时间比较**。
//
// ⚠️ 纯 Dart 测试：先 `dart pub get`。
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shensuanzi_host/shensuanzi_host.dart';
import 'package:test/test.dart';

void main() {
  group('HostToken', () {
    test('generate 产出 32 字节 Base64，且注入种子时可复现', () {
      final String a = HostToken.generate(random: Random(42));
      final String b = HostToken.generate(random: Random(42));
      final String c = HostToken.generate(random: Random(43));

      expect(a, b, reason: '同种子必须同结果（用例可复现）');
      expect(a, isNot(c));
      expect(base64Url.decode(a).length, 32);
    });

    test('不注入种子时两次不同', () {
      expect(HostToken.generate(), isNot(HostToken.generate()));
    });

    test('hashOf 稳定且是 sha256 十六进制', () {
      expect(HostToken.hashOf('t'), HostToken.hashOf('t'));
      expect(HostToken.hashOf('t'), hasLength(64));
      expect(HostToken.hashOf('t'), isNot(HostToken.hashOf('u')));
    });

    test('matches：正确 / 错误 / null', () {
      final String hash = HostToken.hashOf('secret');
      expect(HostToken.matches('secret', hash), isTrue);
      expect(HostToken.matches('secrez', hash), isFalse);
      expect(HostToken.matches('', hash), isFalse);
      expect(HostToken.matches(null, hash), isFalse);
    });

    test('constantTimeEquals：等长不同 / 不等长', () {
      expect(HostToken.constantTimeEquals('abc', 'abc'), isTrue);
      expect(HostToken.constantTimeEquals('abc', 'abd'), isFalse);
      expect(HostToken.constantTimeEquals('abc', 'ab'), isFalse);
      expect(HostToken.constantTimeEquals('', ''), isTrue);
    });
  });

  group('HostIdentityStore', () {
    test('首次 loadOrCreate 生成身份，且带有明文（可画二维码）', () {
      final HostIdentityStore store = HostIdentityStore.inMemory();
      final HostIdentity identity = store.loadOrCreate(now: 1000);

      expect(identity.hostId, isNotEmpty);
      expect(identity.canShowQr, isTrue);
      expect(identity.authorizes(identity.plaintextToken), isTrue);
    });

    // ⚠️ 2026-11-01 语义变更（用户裁定，提案 57）：从前的断言是
    // 「重启后**一定**画不出码（哈希不可逆）」—— 那是**旧设计**。现在明文
    // 由 DPAPI 加密存下来，重启后能解回来 ⇒ 能画码。旧行为保留在下面那条
    // 「没有加密器时」的对照用例里，两种路径都有护栏。
    test('再次 loadOrCreate 读回同一身份，且**明文能恢复**（提案 57 之后）', () {
      final HostIdentityStore store = HostIdentityStore.inMemory(
        protector: FakeProtector(),
      );
      final HostIdentity first = store.loadOrCreate(now: 1000);

      final HostIdentity loaded = store.loadOrCreate(now: 2000);

      expect(loaded.hostId, first.hostId, reason: 'host_id 不变');
      expect(loaded.tokenHash, first.tokenHash);
      expect(
        loaded.canShowQr,
        isTrue,
        reason: '密文能解回明文 ⇒ 重启后仍能画同一个码（这才是提案 57 要的）',
      );
      expect(loaded.plaintextToken, first.plaintextToken, reason: '令牌不许变');
      expect(loaded.authorizes(first.plaintextToken), isTrue);
    });

    test('（对照）没有加密器时回到旧语义：画不出码，但校验照旧', () {
      final HostIdentityStore store = HostIdentityStore.inMemory(
        protector: const NoTokenProtector(),
      );
      final HostIdentity first = store.loadOrCreate(now: 1000);
      final HostIdentity loaded = store.loadOrCreate(now: 2000);

      expect(loaded.hostId, first.hostId);
      expect(loaded.canShowQr, isFalse, reason: '只存哈希 ⇒ 画不出码');
      expect(
        loaded.authorizes(first.plaintextToken),
        isTrue,
        reason: '校验只需要哈希，重启后照样能校验',
      );
    });

    // C-3（业务审查 §3.7，用户裁定 ⑦甲，2026-10-24）：**主机身份与令牌拆开**。
    // `reset` 只轮换令牌，`host_id` 持久化不变 —— 从前一并更换，导致
    // 「重启电脑想再看二维码 ⇒ 重新生成 ⇒ 手机重扫 ⇒ 全量重建镜像 + 队列全挂起」，
    // 而 `Agents.md` §4.2 的「同主机重配对不清」几乎永远走不到。
    test('reset 只换令牌，host_id 不变（C-3），旧令牌立刻失效', () {
      final HostIdentityStore store = HostIdentityStore.inMemory();
      final HostIdentity before = store.loadOrCreate(now: 1000);

      final HostIdentity after = store.reset(now: 2000);

      expect(after.hostId, before.hostId, reason: 'C-3：主机身份持久化，重生成配对码 ≠ 换主机');
      expect(after.canShowQr, isTrue);
      expect(
        after.authorizes(before.plaintextToken),
        isFalse,
        reason: '一键重置 → 所有设备需重新配对',
      );
      expect(after.authorizes(after.plaintextToken), isTrue);
      expect(store.storedHash(), after.tokenHash);
    });

    test('持久化的 JSON **不含明文令牌**', () {
      final HostIdentityStore store = HostIdentityStore.inMemory();
      final HostIdentity identity = store.loadOrCreate(now: 1000);

      final String serialized = jsonEncode(identity.toJson());

      expect(serialized, isNot(contains(identity.plaintextToken!)));
      expect(serialized, contains(identity.tokenHash));
      expect(identity.toJson()['token_hash'], identity.tokenHash);
      expect(identity.toJson().containsKey('token'), isFalse);
    });
  });

  // ============================================================ 落盘健壮性
  group('HostIdentityStore 落盘（2026-10-31 真机：host.json 被拒写）', () {
    late Directory box;

    setUp(() => box = Directory.systemTemp.createTempSync('host_ident_'));
    tearDown(() {
      try {
        box.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('原子写：落盘后内容合法，且**不留 .tmp**', () {
      final File target = File('${box.path}${Platform.pathSeparator}host.json');
      final HostIdentityStore store = HostIdentityStore(target);
      final HostIdentity identity = store.reset(now: 1000);

      expect(store.lastWriteFailed, isFalse);
      expect(target.existsSync(), isTrue);
      expect(
        File('${target.path}.tmp').existsSync(),
        isFalse,
        reason: '临时文件必须被 rename 掉，不能留垃圾',
      );
      // 落盘内容能读回来，哈希一致
      expect(store.storedHash(), identity.tokenHash);
    });

    test('文件被写坏（半截 JSON）⇒ **不崩**，认作没有身份，并记下原因', () {
      // 用户裁定（提案 56 批复 §三 故障注入表最后一行）：
      // 「写入过程中进程异常退出 ⇒ 下次启动能够识别损坏文件，不应直接崩溃」。
      // L2 原地重写在「截断之后、写完之前」被打断，留下的正是这种文件。
      final File target = File('${box.path}${Platform.pathSeparator}host.json')
        ..writeAsStringSync('{"host_id": "abc", "token_ha');

      final HostIdentityStore store = HostIdentityStore(target);
      late HostIdentity? loaded;
      expect(
        () => loaded = store.load(),
        returnsNormally,
        reason: '从前这里 jsonDecode 直接抛 ⇒ 主机服务启动失败，用户不知道该删哪个文件',
      );
      expect(loaded, isNull, reason: '读不懂就当作「没有身份」');
      expect(store.lastReadProblem, isNotNull);
      expect(store.lastReadProblem, contains('host.json'));

      // 还能继续用：生成新身份并把它写回去（自愈）
      final HostIdentity fresh = store.loadOrCreate(now: 1000);
      expect(fresh.plaintextToken, isNotNull);
      expect(store.lastWriteFailed, isFalse, reason: '新文件能正常写');
      expect(store.load()?.hostId, fresh.hostId);
    });

    test('写不进去 ⇒ **不抛**，降级成内存令牌，并置 lastWriteFailed', () {
      // 构造一个「父路径其实是个文件」的路径 ⇒ createSync 必然失败。
      // 真机上是 `PathAccessException ... errno = 5`，效果相同。
      final File blocker = File('${box.path}${Platform.pathSeparator}blocker')
        ..writeAsStringSync('x');
      final HostIdentityStore store = HostIdentityStore(
        File('${blocker.path}${Platform.pathSeparator}host.json'),
      );

      late HostIdentity identity;
      expect(
        () => identity = store.reset(now: 1000),
        returnsNormally,
        reason: '写盘失败不能把「生成配对码」整个废掉 —— 那是小故障升级成功能不可用',
      );
      expect(store.lastWriteFailed, isTrue);
      expect(identity.plaintextToken, isNotNull, reason: '内存里必须有明文，否则二维码画不出来');
      expect(identity.authorizes(identity.plaintextToken), isTrue);
      // 原文留着给日志（根因未定的那个 errno，下次复现要有现场）
      expect(store.lastWriteProblem, isNotNull);
      expect(store.lastWriteProblem, contains(blocker.path));
    });
  });
  // 2026-11-01（提案 57 裁定 ⑤⑥）：DPAPI × 写盘的**四种组合**，以及
  // 「密文缺失 / 损坏 / 格式不支持 / 解不开 / 哈希不符」五条读取路径。
  //
  // 这一组的意义：单独测 DPAPI 和单独测写盘都不够 —— 用户真正会遇到的
  // 是两者组合出来的四种状态，而它们对「下次开机能不能画码」的结论完全不同。
  group('令牌加密持久化（DPAPI × 写盘）', () {
    late Directory box;
    late File file;

    setUp(() {
      box = Directory.systemTemp.createTempSync('ssz_token_protect_');
      file = File('${box.path}${Platform.pathSeparator}host.json');
    });

    tearDown(() {
      try {
        box.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// 可编程的假加密器（真 DPAPI 造不出「失败」）
    ///
    /// 密文格式故意做成 `enc:<hostId>:<base64>` —— 顺便能验「熵绑定」：
    /// `hostId` 对不上就解不开。
    FakeProtector fake({
      bool failProtect = false,
      bool failUnprotect = false,
      bool tamper = false,
      bool supported = true,
    }) => FakeProtector(
      failProtect: failProtect,
      failUnprotect: failUnprotect,
      tamper: tamper,
      supported: supported,
    );

    /// 写盘必失败的文件操作（模拟 2026-10-31 真机那个 errno 5）
    HostWriteIo failingIo() => _FailingIo();

    test('组合 1：加密成功 + 写盘成功 ⇒ 重启后能恢复明文', () {
      final HostIdentityStore first = HostIdentityStore(
        file,
        protector: fake(),
      );
      final HostIdentity created = first.reset(now: 1000);
      expect(first.lastProtectProblem, isNull);
      expect(first.lastWriteFailed, isFalse);
      // 文件里是密文，不是明文
      final String raw = file.readAsStringSync();
      expect(raw, contains('token_protected'));
      expect(raw, isNot(contains(created.plaintextToken!)));

      // 「重启」= 同一文件上新建一个 store
      final HostIdentityStore second = HostIdentityStore(
        file,
        protector: fake(),
      );
      final HostIdentity? restored = second.load();
      expect(restored, isNotNull);
      expect(second.lastRestoreState, TokenRestoreState.restored);
      expect(restored!.plaintextToken, created.plaintextToken);
      expect(restored.canShowQr, isTrue);
      expect(restored.authorizes(created.plaintextToken), isTrue);
    });

    test('组合 2：加密成功 + 写盘失败 ⇒ 本次可用，但不能说「已保存」', () {
      final HostIdentityStore store = HostIdentityStore(
        file,
        io: failingIo(),
        protector: fake(),
      );
      final HostIdentity created = store.reset(now: 1000);

      expect(created.plaintextToken, isNotNull, reason: '本次必须能用');
      expect(store.lastWriteFailed, isTrue, reason: '写盘失败必须如实记');
      expect(store.lastProtectProblem, isNull);
      // 文件没写成功 ⇒ 重启后当然画不出码（这里连文件都没有）
      expect(file.existsSync(), isFalse);
    });

    test('组合 3：加密失败 + 写盘成功 ⇒ 只存哈希，重启后 hashOnly，但令牌仍可验证', () {
      final HostIdentityStore store = HostIdentityStore(
        file,
        protector: fake(failProtect: true),
      );
      final HostIdentity created = store.reset(now: 1000);

      expect(created.plaintextToken, isNotNull, reason: '加密失败不该阻断本次配对');
      expect(store.lastProtectProblem, isNotNull, reason: '必须记下来给界面提示');
      expect(store.lastWriteFailed, isFalse);
      expect(file.readAsStringSync(), isNot(contains('token_protected')));

      final HostIdentityStore second = HostIdentityStore(
        file,
        protector: fake(failProtect: true),
      );
      final HostIdentity? reloaded = second.load();
      expect(second.lastRestoreState, TokenRestoreState.hashOnly);
      expect(reloaded!.canShowQr, isFalse, reason: '只存哈希 ⇒ 画不出码');
      expect(
        reloaded.authorizes(created.plaintextToken),
        isTrue,
        reason: '校验只靠哈希，加密失败**不能**让手机连不上',
      );
    });

    test('组合 4：加密失败 + 写盘失败 ⇒ 两个都记，本次仍可配对', () {
      final HostIdentityStore store = HostIdentityStore(
        file,
        io: failingIo(),
        protector: fake(failProtect: true),
      );
      final HostIdentity created = store.reset(now: 1000);
      expect(created.plaintextToken, isNotNull);
      expect(store.lastProtectProblem, isNotNull);
      expect(store.lastWriteFailed, isTrue);
    });

    test('密文解不开（换用户/换机器）⇒ undecryptable，且**绝不轮换令牌**', () {
      final HostIdentityStore first = HostIdentityStore(
        file,
        protector: fake(),
      );
      final HostIdentity created = first.reset(now: 1000);

      final HostIdentityStore second = HostIdentityStore(
        file,
        protector: fake(failUnprotect: true),
      );
      final HostIdentity? reloaded = second.load();
      expect(second.lastRestoreState, TokenRestoreState.undecryptable);
      expect(second.lastRestoreProblem, isNotNull);
      expect(reloaded!.canShowQr, isFalse);
      expect(reloaded.hostId, created.hostId, reason: '身份不能变');
      expect(reloaded.tokenHash, created.tokenHash, reason: '令牌不能轮换');
      // loadOrCreate 走的是 load()（非 null）⇒ 不会静默 reset
      final HostIdentity again = second.loadOrCreate(now: 2000);
      expect(again.tokenHash, created.tokenHash, reason: 'loadOrCreate 不许静默换令牌');
    });

    test('密文与哈希不符 ⇒ mismatch，明文丢弃且不轮换', () {
      final HostIdentityStore first = HostIdentityStore(
        file,
        protector: fake(),
      );
      first.reset(now: 1000);
      final HostIdentityStore second = HostIdentityStore(
        file,
        protector: fake(tamper: true),
      );
      final HostIdentity? reloaded = second.load();
      expect(second.lastRestoreState, TokenRestoreState.mismatch);
      expect(reloaded!.plaintextToken, isNull, reason: '两份数据矛盾时谁的都不信');
      expect(reloaded.canShowQr, isFalse);
    });

    test('scheme 不认识 ⇒ unsupported（不猜、不崩）', () {
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': 2,
          'host_id': 'h-1',
          'token_hash': HostToken.hashOf('tok'),
          'created_at': 1,
          'token_protected': <String, Object?>{
            'scheme': 'something-else-v9',
            'blob': 'AAAA',
          },
        }),
      );
      final HostIdentityStore store = HostIdentityStore(
        file,
        protector: fake(),
      );
      final HostIdentity? loaded = store.load();
      expect(store.lastRestoreState, TokenRestoreState.unsupported);
      expect(loaded, isNotNull, reason: '身份还在，只是画不出码');
      expect(loaded!.canShowQr, isFalse);
    });

    test('老文件（v1，没有 token_protected）⇒ hashOnly，行为与升级前一致', () {
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': 1,
          'host_id': 'h-1',
          'token_hash': HostToken.hashOf('tok'),
          'created_at': 1,
        }),
      );
      final HostIdentityStore store = HostIdentityStore(
        file,
        protector: fake(),
      );
      final HostIdentity? loaded = store.load();
      expect(store.lastRestoreState, TokenRestoreState.hashOnly);
      expect(loaded!.canShowQr, isFalse);
      expect(loaded.authorizes('tok'), isTrue);
    });

    test('旧版程序重写文件会丢掉 token_protected ⇒ 新版按 hashOnly 处理，不崩', () {
      // 裁定 ④ 的边界：不承诺新旧版本无损往返
      final HostIdentityStore first = HostIdentityStore(
        file,
        protector: fake(),
      );
      final HostIdentity created = first.reset(now: 1000);
      // 模拟「旧版重写了这个文件」（只写 v1 字段）
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': 1,
          'host_id': created.hostId,
          'token_hash': created.tokenHash,
          'created_at': created.createdAt,
        }),
      );
      final HostIdentityStore second = HostIdentityStore(
        file,
        protector: fake(),
      );
      final HostIdentity? loaded = second.load();
      expect(second.lastRestoreState, TokenRestoreState.hashOnly);
      expect(loaded!.canShowQr, isFalse, reason: '密文没了 ⇒ 要重新生成一次');
      expect(loaded.authorizes(created.plaintextToken), isTrue, reason: '哈希还在，手机照连');
    });

    test('不支持加密的平台 ⇒ 只写哈希（与今天一致），不报错', () {
      final HostIdentityStore store = HostIdentityStore(
        file,
        protector: fake(supported: false, failProtect: true),
      );
      final HostIdentity created = store.reset(now: 1000);
      expect(created.plaintextToken, isNotNull);
      expect(store.lastProtectProblem, isNotNull);
      expect(file.readAsStringSync(), isNot(contains('token_protected')));
    });
  });

}

/// 可编程的假加密器：真 DPAPI 造不出「加密失败 / 解密失败 / 哈希不符」。
class FakeProtector implements TokenProtector {
  FakeProtector({
    this.failProtect = false,
    this.failUnprotect = false,
    this.tamper = false,
    this.supported = true,
  });

  final bool failProtect;
  final bool failUnprotect;

  /// 解出来的令牌故意改一个字（模拟「密文与哈希不一致」）
  final bool tamper;
  final bool supported;

  @override
  bool get isSupported => supported;

  @override
  String? protect(String plaintext, {required String hostId}) {
    if (!supported || failProtect) return null;
    return 'enc:$hostId:${base64.encode(utf8.encode(plaintext))}';
  }

  @override
  String? unprotect(String blob, {required String hostId}) {
    if (!supported || failUnprotect) return null;
    final List<String> parts = blob.split(':');
    if (parts.length != 3 || parts[0] != 'enc') return null;
    if (parts[1] != hostId) return null; // 熵绑定
    final String plain = utf8.decode(base64.decode(parts[2]));
    return tamper ? '${plain}x' : plain;
  }
}

/// 写盘必失败（模拟 `host.json` 被拒写）
class _FailingIo extends HostWriteIo {
  const _FailingIo();

  Never _deny() => throw const FileSystemException(
    '拒绝访问。',
    null,
    OSError('拒绝访问。', 5),
  );

  @override
  bool exists(File file) => file.existsSync();

  @override
  void createParent(File file) {}

  @override
  void writeString(File file, String text) => _deny();

  @override
  void rename(File from, File to) => _deny();

  @override
  String readString(File file) => file.readAsStringSync();

  @override
  void truncateAndWrite(File file, String text) => _deny();

  @override
  void delete(File file) {}
}
