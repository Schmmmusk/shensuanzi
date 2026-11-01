// 提案 57 的**可行性探针**：Dart 直调 `crypt32.dll` 的 `CryptProtectData` /
// `CryptUnprotectData`，验「加密 → 解密往返」与「篡改后解不开」。
//
// 为什么要先探：提案 57 推荐用 DPAPI 存令牌明文。若这条路在 Dart 里走不通
// （FFI 结构体 / 调用约定 / 熵参数），整份提案的推荐就是空的 ——
// 纪律 20「先取证后动手」。
//
// 用法：`dart run tool/probe_dpapi.dart`
// 退出码：0 = 全部通过；1 = 有失败。
import 'dart:convert';
import 'dart:io';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// `DATA_BLOB`（`dpapi.h`）——
///
/// ⚠️⚠️ **字段顺序是 `cbData` 在前、`pbData` 在后**。写反了不会报类型错，
/// Windows 会把「指针的低 4 字节」当成长度去读 ⇒ `CryptProtectData` 返回
/// `ERROR_NOACCESS(998)`，而且 `GetLastError` 之外没有任何线索。
/// 本次实测踩过（先按「指针在前」写，四种参数组合全部 998）。
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

const int _cryptProtectUiForbidden = 0x1;

/// 最后一次 Win32 错误码。
///
/// ⚠️ **必须预热**：`DynamicLibrary.open` / `lookupFunction` 自己会重置
/// `GetLastError`，在失败**之后**才去解析这个函数，读到的永远是 0。
final int Function() _getLastError = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
int lastError() => _getLastError();

int _passed = 0;
int _failed = 0;
void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    print('  OK   $name');
  } else {
    _failed++;
    print('  FAIL $name${detail == null ? '' : '  → $detail'}');
  }
}

/// `LocalFree`（kernel32）—— DPAPI 的输出缓冲区由系统分配，必须还回去。
final Pointer<Void> Function(Pointer<Void>) _localFree = DynamicLibrary.open(
  'kernel32.dll',
).lookupFunction<Pointer<Void> Function(Pointer<Void>),
    Pointer<Void> Function(Pointer<Void>)>('LocalFree', isLeaf: true);

/// 把一段字节加密成 blob（返回 base64）。
String? protect(List<int> plain, {List<int>? entropy}) {
  final DynamicLibrary lib = DynamicLibrary.open('crypt32.dll');
  final _ProtectDart call = lib
      .lookupFunction<_ProtectNative, _ProtectDart>('CryptProtectData');

  final Pointer<DataBlob> inBlob = calloc<DataBlob>();
  final Pointer<DataBlob> entropyBlob = calloc<DataBlob>();
  final Pointer<DataBlob> outBlob = calloc<DataBlob>();
  final Pointer<Uint8> inBytes = malloc.allocate<Uint8>(plain.length);
  inBytes.asTypedList(plain.length).setAll(0, plain);
  inBlob.ref
    ..pbData = inBytes
    ..cbData = plain.length;

  Pointer<Uint8> entropyBytes = nullptr;
  if (entropy != null) {
    entropyBytes = malloc.allocate<Uint8>(entropy.length);
    entropyBytes.asTypedList(entropy.length).setAll(0, entropy);
    entropyBlob.ref
      ..pbData = entropyBytes
      ..cbData = entropy.length;
  }

  final int ok = call(
    inBlob,
    nullptr,
    entropy == null ? nullptr : entropyBlob,
    nullptr,
    nullptr,
    _cryptProtectUiForbidden,
    outBlob,
  );
  String? result;
  if (ok != 0) {
    result = base64.encode(
      outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
    );
    // 系统分配的缓冲区要还回去（`LocalFree` 在 **kernel32**，不在 crypt32）
    _localFree(outBlob.ref.pbData.cast());
  }
  malloc.free(inBytes);
  if (entropyBytes != nullptr) malloc.free(entropyBytes);
  calloc
    ..free(inBlob)
    ..free(entropyBlob)
    ..free(outBlob);
  return result;
}

/// 解密（失败返回 null）。
List<int>? unprotect(String blobBase64, {List<int>? entropy}) {
  final DynamicLibrary lib = DynamicLibrary.open('crypt32.dll');
  final _ProtectDart call = lib
      .lookupFunction<_ProtectNative, _ProtectDart>('CryptUnprotectData');

  final List<int> blob = base64.decode(blobBase64);
  final Pointer<DataBlob> inBlob = calloc<DataBlob>();
  final Pointer<DataBlob> entropyBlob = calloc<DataBlob>();
  final Pointer<DataBlob> outBlob = calloc<DataBlob>();
  final Pointer<Uint8> inBytes = malloc.allocate<Uint8>(blob.length);
  inBytes.asTypedList(blob.length).setAll(0, blob);
  inBlob.ref
    ..pbData = inBytes
    ..cbData = blob.length;

  Pointer<Uint8> entropyBytes = nullptr;
  if (entropy != null) {
    entropyBytes = malloc.allocate<Uint8>(entropy.length);
    entropyBytes.asTypedList(entropy.length).setAll(0, entropy);
    entropyBlob.ref
      ..pbData = entropyBytes
      ..cbData = entropy.length;
  }

  final int ok = call(
    inBlob,
    nullptr,
    entropy == null ? nullptr : entropyBlob,
    nullptr,
    nullptr,
    _cryptProtectUiForbidden,
    outBlob,
  );
  List<int>? result;
  if (ok != 0) {
    result = List<int>.from(
      outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
    );
    _localFree(outBlob.ref.pbData.cast());
  }
  malloc.free(inBytes);
  if (entropyBytes != nullptr) malloc.free(entropyBytes);
  calloc
    ..free(inBlob)
    ..free(entropyBlob)
    ..free(outBlob);
  return result;
}

void main() {
  print('DPAPI 可行性探针（Windows 当前用户作用域）');
  _getLastError(); // 预热（见 `_getLastError` 的注释）

  // 32 字节令牌的 Base64 文本，长度与真实令牌相当
  final String token = base64Url.encode(
    List<int>.generate(32, (int i) => (i * 37 + 11) & 0xFF),
  );
  final List<int> plain = utf8.encode(token);
  final List<int> entropy = utf8.encode('host-id-entropy-probe');

  final String? maybeBlob = protect(plain, entropy: entropy);
  check('CryptProtectData 成功', maybeBlob != null, 'GetLastError=${lastError()}');
  if (maybeBlob == null) {
    print('\n通过 $_passed，失败 $_failed');
    exit(1);
  }
  final String blob = maybeBlob;

  final List<int>? back = unprotect(blob, entropy: entropy);
  check('CryptUnprotectData 成功', back != null);
  check(
    '往返字节一致',
    back != null && back.length == plain.length &&
        List<int>.generate(plain.length, (int i) => i).every(
          (int i) => back[i] == plain[i],
        ),
  );

  // ① 密文里不能出现明文（这是「不是明文写盘」的最低证据）
  check(
    '密文不含明文',
    !base64.encode(plain).contains(blob.substring(0, 8)) &&
        !utf8.decode(base64.decode(blob), allowMalformed: true).contains(token),
  );

  // ② 换熵 ⇒ 解不开（提案里「blob 与 host_id 绑定」的依据）
  check('熵不符 ⇒ 解密失败', unprotect(blob, entropy: utf8.encode('别的')) == null);

  // ③ 篡改 1 字节 ⇒ 解密失败（不能返回垃圾）
  final List<int> raw = base64.decode(blob);
  raw[raw.length ~/ 2] ^= 0xFF;
  check('篡改 1 字节 ⇒ 解密失败', unprotect(base64.encode(raw), entropy: entropy) == null);

  // ④ 不带熵也能往返（提案里熵是可选加固，不是必需）
  final String? plainBlob = protect(plain);
  check(
    '不带熵：往返一致',
    plainBlob != null && unprotect(plainBlob)?.length == plain.length,
  );

  print('\n通过 $_passed，失败 $_failed');
  exit(_failed == 0 ? 0 : 1);
}
