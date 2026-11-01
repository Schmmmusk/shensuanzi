/// 令牌明文的**加密存储**（Windows DPAPI，当前用户作用域）。
///
/// ## 为什么需要它（用户裁定，`docs/reply.md` 提案 57 批复）
///
/// 主机从前只持久化 `sha256(令牌)`，于是**重启后画不出配对码**，用户只能点
/// 「重新生成」—— 而那个动作会**轮换令牌**，所有已配对手机立刻失效、必须重扫。
/// 用户每天开机一次，就每天断一次。真正的痛点不是写盘失败，是这一步。
///
/// ## 设计边界（裁定原文逐条）
///
/// - **当前用户作用域**（不加 `CRYPTPROTECT_LOCAL_MACHINE`）：换 Windows 用户 /
///   换机器 ⇒ 解不开，这是**期望**行为（换机器该重新配对）。
/// - **附加熵 = `sha256(host_id)`**：密文绑到那个 `host_id`，把它挪进别的
///   `host.json` 里解不出来。
/// - **解出来的令牌必须再过一次哈希校验**（`sha256(明文) == token_hash`）——
///   密文与哈希字段不一致时**不许用**，也不许静默改哈希（见 `HostIdentityStore.load`）。
/// - **失败必须说出来**：加密失败 ⇒ 只写哈希 + 明确的界面提示，
///   不许把「只存了哈希」报成「保存成功」。
///
/// ## ⚠️ 两个实测坑（2026-11-01，`tool/probe_dpapi.dart` 复现脚本）
///
/// 1. **`DATA_BLOB` 字段顺序是 `cbData` 在前、`pbData` 在后**。写反了
///    `CryptProtectData` 返回 0、`GetLastError = 998 (ERROR_NOACCESS)`，
///    **类型系统完全不报错** —— 只能靠 `GetLastError` 看出来。
/// 2. **`LocalFree` 在 `kernel32`**，不在 `crypt32`（在 crypt32 里查会报 127）。
///
/// ## 非 Windows
///
/// `dart test` 在别的平台也要能跑：本文件**不在 import 期打开任何 DLL**，
/// 所有 `DynamicLibrary.open` 都推迟到第一次真正调用；[isSupported] 为 false 时
/// 直接返回 `null`（调用方按「加密不可用」降级，行为与今天一致）。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

/// 令牌明文的加解密接口（**测试注入的接缝**：能强制「加密失败」）。
abstract class TokenProtector {
  /// 本机能不能用（非 Windows / DLL 缺失 ⇒ false）
  bool get isSupported;

  /// 加密；失败返回 `null`（**不抛** —— 调用方按降级处理）
  String? protect(String plaintext, {required String hostId});

  /// 解密；失败返回 `null`（**不抛**）
  String? unprotect(String blob, {required String hostId});
}

/// 明文方案（非 Windows / 测试用）：永远「不支持」。
///
/// 行为 = 今天的样子：只写哈希，重启后要重新生成。
class NoTokenProtector implements TokenProtector {
  const NoTokenProtector();

  @override
  bool get isSupported => false;

  @override
  String? protect(String plaintext, {required String hostId}) => null;

  @override
  String? unprotect(String blob, {required String hostId}) => null;
}

/// 方案名（写进 `host.json`，将来换算法/换作用域时靠它区分）
const String dpapiScheme = 'dpapi-user-v1';

/// Windows DPAPI 实现。
class DpapiTokenProtector implements TokenProtector {
  const DpapiTokenProtector();

  @override
  bool get isSupported => Platform.isWindows && _Dpapi.available;

  @override
  String? protect(String plaintext, {required String hostId}) {
    if (!isSupported) return null;
    final ByteSlice input = ByteSlice(utf8.encode(plaintext));
    final ByteSlice entropy = ByteSlice(_entropyOf(hostId));
    return _Dpapi.instance.protect(input, entropy);
  }

  @override
  String? unprotect(String blob, {required String hostId}) {
    if (!isSupported) return null;
    final List<int>? raw = _tryBase64(blob);
    if (raw == null) return null;
    final List<int>? plain = _Dpapi.instance.unprotect(
      ByteSlice(raw),
      ByteSlice(_entropyOf(hostId)),
    );
    if (plain == null) return null;
    try {
      return utf8.decode(plain);
    } on FormatException {
      // 解出来的不是 UTF-8 ⇒ 当作失败（不猜）
      return null;
    }
  }

  /// 附加熵 = `sha256(host_id)` —— 把密文绑到这台主机的身份上
  static List<int> _entropyOf(String hostId) =>
      sha256.convert(utf8.encode(hostId)).bytes;

  static List<int>? _tryBase64(String blob) {
    try {
      return base64.decode(blob);
    } on FormatException {
      return null;
    }
  }
}

/// 一层薄壳：把一段字节包起来传（避免到处传裸 `List<int>` 时看错顺序）。
class ByteSlice {
  ByteSlice(this.bytes);

  final List<int> bytes;
}

/// `DATA_BLOB`（`dpapi.h`）。
///
/// ⚠️ **字段顺序是 `cbData` 在前、`pbData` 在后**（见文件头「两个实测坑」）。
final class DataBlob extends Struct {
  /// `DWORD cbData`
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _ProtectNative =
    Int32 Function(
      Pointer<DataBlob>, // pDataIn
      Pointer<Utf16>, // szDataDescr
      Pointer<DataBlob>, // pOptionalEntropy
      Pointer<Void>, // pvReserved
      Pointer<Void>, // pPromptStruct
      Uint32, // dwFlags
      Pointer<DataBlob>, // pDataOut
    );
typedef _ProtectDart =
    int Function(
      Pointer<DataBlob>,
      Pointer<Utf16>,
      Pointer<DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<DataBlob>,
    );

/// `CRYPTPROTECT_UI_FORBIDDEN`（后台不许弹系统对话框）
const int _uiForbidden = 0x1;

/// FFI 调用本体（**延迟初始化**：非 Windows 上永远不碰 DLL）。
class _Dpapi {
  _Dpapi._();

  static final _Dpapi instance = _Dpapi._();

  /// 能不能用（DLL 与符号都在）。
  ///
  /// **首次访问时才尝试加载**：`dart test` 在非 Windows 上跑，
  /// import 期打开 `crypt32.dll` 会直接崩。
  static bool get available {
    if (_loaded) return true;
    if (_failed) return false;
    try {
      _ensure();
      return _loaded;
    } catch (_) {
      // DLL 缺失 / 符号缺失 / 极老系统：记一次失败，之后一律 false
      _failed = true;
      return false;
    }
  }

  static bool _loaded = false;
  static bool _failed = false;

  static _ProtectDart? _protect;
  static _ProtectDart? _unprotect;
  static Pointer<Void> Function(Pointer<Void>)? _localFree;

  static void _ensure() {
    if (_loaded) return;
    if (!Platform.isWindows) return;
    final DynamicLibrary crypt32 = DynamicLibrary.open('crypt32.dll');
    final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
    _protect = crypt32.lookupFunction<_ProtectNative, _ProtectDart>(
      'CryptProtectData',
    );
    _unprotect = crypt32.lookupFunction<_ProtectNative, _ProtectDart>(
      'CryptUnprotectData',
    );
    // ⚠️ `LocalFree` 在 kernel32（见文件头）
    _localFree = kernel32
        .lookupFunction<Pointer<Void> Function(Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>)>('LocalFree', isLeaf: true);
    _loaded = true;
  }

  /// 加密 → base64；失败 `null`
  String? protect(ByteSlice input, ByteSlice entropy) {
    final List<int>? out = _call(input, entropy, protect: true);
    return out == null ? null : base64.encode(out);
  }

  /// base64 → 明文；失败 `null`
  List<int>? unprotect(ByteSlice input, ByteSlice entropy) =>
      _call(input, entropy, protect: false);

  /// 两个 API 的参数表完全一样，只有语义不同 —— 合成一处，
  /// **资源释放只在 finally 里做一次**（裁定：每条路径都要 LocalFree）。
  List<int>? _call(
    ByteSlice input,
    ByteSlice entropy, {
    required bool protect,
  }) {
    if (!_loaded) _ensure();
    final _ProtectDart? fn = protect ? _protect : _unprotect;
    if (fn == null) return null;

    Pointer<Uint8>? inBytes;
    Pointer<Uint8>? entropyBytes;
    final Pointer<DataBlob> inBlob = calloc<DataBlob>();
    final Pointer<DataBlob> entropyBlob = calloc<DataBlob>();
    final Pointer<DataBlob> outBlob = calloc<DataBlob>();
    try {
      inBytes = malloc.allocate<Uint8>(input.bytes.length);
      inBytes.asTypedList(input.bytes.length).setAll(0, input.bytes);
      inBlob.ref
        ..cbData = input.bytes.length
        ..pbData = inBytes;

      entropyBytes = malloc.allocate<Uint8>(entropy.bytes.length);
      entropyBytes.asTypedList(entropy.bytes.length).setAll(0, entropy.bytes);
      entropyBlob.ref
        ..cbData = entropy.bytes.length
        ..pbData = entropyBytes;

      final int ok = fn(
        inBlob,
        nullptr,
        entropyBlob,
        nullptr,
        nullptr,
        _uiForbidden,
        outBlob,
      );
      if (ok == 0) return null;
      final int length = outBlob.ref.cbData;
      final Pointer<Uint8> data = outBlob.ref.pbData;
      if (data == nullptr) return null;
      // 长度 0 是**合法**的（加密空串 ⇒ 解密回空串）。只有指针为空才算失败 ——
      // 把 `length <= 0` 也当失败，会让「空令牌」这条边界变成解不开。
      return length <= 0 ? const <int>[] : List<int>.from(data.asTypedList(length));
    } finally {
      // 系统分配的输出缓冲区：成功才需要还，但**失败路径也检查一遍**
      // （某些实现会先分配后失败；多调一次 LocalFree(nullptr) 是无害的）
      final Pointer<Uint8> out = outBlob.ref.pbData;
      if (out != nullptr) _localFree?.call(out.cast());
      if (inBytes != null) malloc.free(inBytes);
      if (entropyBytes != null) malloc.free(entropyBytes);
      calloc
        ..free(inBlob)
        ..free(entropyBlob)
        ..free(outBlob);
    }
  }
}
