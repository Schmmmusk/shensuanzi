/// Windows 盘符枚举 —— **本包唯一直接调 Win32 的地方**（`dart:ffi`，零新依赖）。
///
/// ## 为什么不用 `Directory('X:\\').existsSync()`
///
/// `existsSync()` 是「**检查某个具体路径**存不存在」，**不是「列出有哪些盘」**。
/// 用它来枚举盘符，在**映射了但已离线的网络盘**上会去碰网络 ——
/// Windows 要等 SMB 超时才返回，实测**首次 21,039 ms**（`docs/reply_review.md` §AT·六-3）。
/// 用户看到的是「启动白屏二十秒」。而且它还**抛异常而不是返回 `false`**
/// （`errno 53`），旧实现因此直接崩（§AT）。
///
/// `GetLogicalDrives` 只读**本地挂载表**，一个 DWORD 位掩码，**永不触网**。
///
/// > 这是「用**对的** API 换**错的** API」，不是「用 FFI 换性能」。
///
/// ## 三个调用
///
/// | 调用 | 拿到什么 | 触网吗 |
/// |---|---|---|
/// | `GetLogicalDrives()` | 哪些盘符被占用（位掩码，bit 0 = `A`） | **否** |
/// | `GetDriveTypeW(root)` | 盘类型（`DRIVE_FIXED` / `DRIVE_REMOVABLE` / `DRIVE_REMOTE` …） | **否**（读本地 DOS 设备表） |
/// | `GetDiskFreeSpaceExW(root, …)` | 剩余空间 | ⚠️ **远程盘会触网** |
///
/// ⚠️ **所以远程盘一律不查剩余空间**（`freeBytes` 留 `null`）——
/// 那正是要避开的 21 秒。远程盘反正**不参与默认位置候选**
/// （`DriveInfo.isGoodForData` 排除 `network`），它的剩余空间没有消费者。
///
/// ## 边界
///
/// - **只返回原始 Win32 事实**，不做领域映射 —— `DRIVE_*` → `DriveKind` 的映射在
///   `environment.dart`（纯 Dart、可测）。本文件**不 import 任何包内文件**（避免循环依赖）。
/// - 失败就抛，由 `AppEnvironment.detect()` 兜底（它已裁定**永不抛**）。
library;

import 'dart:ffi';

/// `GetDriveType` 的返回值（`winbase.h`）。只列我们能遇到的几种。
const int winDriveUnknown = 0;
const int winDriveNoRootDir = 1;
const int winDriveRemovable = 2;
const int winDriveFixed = 3;
const int winDriveRemote = 4;
const int winDriveCdrom = 5;
const int winDriveRamdisk = 6;

/// 一块盘的**原始 Win32 事实**（未经领域映射 —— 那是 `environment.dart` 的事）。
class RawDrive {
  const RawDrive({
    required this.letter,
    required this.type,
    this.freeBytes,
    this.volumeLabel,
  });

  /// 大写盘符，如 `D`（不含冒号与反斜杠）
  final String letter;

  /// `winDrive*` 之一
  final int type;

  /// 剩余字节；`null` = 没查（**远程盘**）或查不到
  final int? freeBytes;

  /// 卷标（用户在「此电脑」里给盘起的名字，如「仓库」）；
  /// `null` = 没查（**远程盘**）、没起名或查不到。
  ///
  /// 为什么要它（§BK·二）：**让用户认得出「这是我的哪块盘」** ——
  /// 「E: 盘」对用户是抽象的，「E: 盘（卷标「仓库」）」不是。
  final String? volumeLabel;

  @override
  String toString() =>
      'RawDrive($letter:, type=$type, free=$freeBytes, label=$volumeLabel)';
}

/// 枚举本机的盘符与类型（+ 本地盘的剩余空间）。
///
/// ⚠️ **只在 Windows 上调用** —— 其它平台 `kernel32.dll` 打不开会抛。
/// 调用方（`AppEnvironment.detect`）负责平台判断与兜底。
List<RawDrive> enumerateWindowsRawDrives() {
  final _Kernel32 k = _kernel32();
  final int mask = k.getLogicalDrives();
  final List<RawDrive> out = <RawDrive>[];
  for (int i = 0; i < 26; i++) {
    if (mask & (1 << i) == 0) continue; // 这个盘符没被占用
    final String letter = String.fromCharCode(0x41 + i); // 'A' + i
    final Pointer<Uint16> root = _allocUtf16(k, '$letter:\\');
    if (root == nullptr) continue; // 分配失败：跳过这块盘，不影响其它盘
    try {
      final int type = k.getDriveType(root);
      // ⚠️ 卷标与剩余空间都**只给本地盘**查 —— 远程盘一查就触网（见文件头）
      final bool local = type == winDriveFixed || type == winDriveRemovable;
      final int? free = local ? _freeBytesOf(k, root) : null;
      final String? label = local ? _volumeLabelOf(k, root) : null;
      out.add(
        RawDrive(letter: letter, type: type, freeBytes: free, volumeLabel: label),
      );
    } finally {
      k.localFree(root.cast<Uint8>());
    }
  }
  return out;
}

// ---------------------------------------------------------------- FFI 细节

/// `LocalAlloc` 的 `LPTR`（`LMEM_FIXED | LMEM_ZEROINIT`）。
///
/// 用 kernel32 的 `LocalAlloc` 而不是 `package:ffi` 的 `calloc` ——
/// 后者要给本包引入**第一个第三方依赖**，而本包至今只有 `shensuanzi_core` + `path`。
const int _lptr = 0x0040;

/// 惰性缓存：`DynamicLibrary.open` 与三次 `lookupFunction` 只做一次。
_Kernel32? _cached;
_Kernel32 _kernel32() => _cached ??= _Kernel32.open();

class _Kernel32 {
  _Kernel32._(
    this.getLogicalDrives,
    this.getDriveType,
    this.getDiskFreeSpaceEx,
    this.getVolumeInformation,
    this.localAlloc,
    this.localFree,
  );

  factory _Kernel32.open() {
    final DynamicLibrary lib = DynamicLibrary.open('kernel32.dll');
    return _Kernel32._(
      lib.lookupFunction<_GetLogicalDrivesNative, _GetLogicalDrives>(
        'GetLogicalDrives',
      ),
      lib.lookupFunction<_GetDriveTypeNative, _GetDriveType>('GetDriveTypeW'),
      lib.lookupFunction<_GetDiskFreeSpaceExNative, _GetDiskFreeSpaceEx>(
        'GetDiskFreeSpaceExW',
      ),
      lib.lookupFunction<_GetVolumeInformationNative, _GetVolumeInformation>(
        'GetVolumeInformationW',
      ),
      lib.lookupFunction<_LocalAllocNative, _LocalAlloc>('LocalAlloc'),
      lib.lookupFunction<_LocalFreeNative, _LocalFree>('LocalFree'),
    );
  }

  final _GetLogicalDrives getLogicalDrives;
  final _GetDriveType getDriveType;
  final _GetDiskFreeSpaceEx getDiskFreeSpaceEx;
  final _GetVolumeInformation getVolumeInformation;
  final _LocalAlloc localAlloc;
  final _LocalFree localFree;
}

typedef _GetLogicalDrivesNative = Uint32 Function();
typedef _GetLogicalDrives = int Function();

typedef _GetDriveTypeNative = Uint32 Function(Pointer<Uint16>);
typedef _GetDriveType = int Function(Pointer<Uint16>);

typedef _GetDiskFreeSpaceExNative =
    Int32 Function(
      Pointer<Uint16>,
      Pointer<Uint64>,
      Pointer<Uint64>,
      Pointer<Uint64>,
    );
typedef _GetDiskFreeSpaceEx =
    int Function(Pointer<Uint16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);

typedef _GetVolumeInformationNative =
    Int32 Function(
      Pointer<Uint16>,
      Pointer<Uint16>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint16>,
      Uint32,
    );
typedef _GetVolumeInformation =
    int Function(
      Pointer<Uint16>,
      Pointer<Uint16>,
      int,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint16>,
      int,
    );

typedef _LocalAllocNative = Pointer<Uint8> Function(Uint32, IntPtr);
typedef _LocalAlloc = Pointer<Uint8> Function(int, int);

typedef _LocalFreeNative = Pointer<Uint8> Function(Pointer<Uint8>);
typedef _LocalFree = Pointer<Uint8> Function(Pointer<Uint8>);

/// 把 Dart 字符串写成**以 NUL 结尾的 UTF-16 缓冲区**（Win32 的 `LPCWSTR`）。
///
/// 盘符路径只有 ASCII（`D:\`），但 `codeUnitAt` 对 ASCII 就是码点，
/// 所以这里不需要处理代理对。
Pointer<Uint16> _allocUtf16(_Kernel32 k, String text) {
  final Pointer<Uint8> raw = k.localAlloc(_lptr, (text.length + 1) * 2);
  if (raw == nullptr) return nullptr.cast<Uint16>();
  final Pointer<Uint16> units = raw.cast<Uint16>();
  for (int i = 0; i < text.length; i++) {
    // ⚠️ 用 `+ i`（指针算术），不用 `elementAt(i)` —— 后者在本 SDK 已标记 deprecated
    (units + i).value = text.codeUnitAt(i);
  }
  (units + text.length).value = 0; // NUL 结尾
  return units;
}

/// 剩余空间（取「调用方可用」那一项）。拿不到返回 `null` —— **未知不猜值**。
int? _freeBytesOf(_Kernel32 k, Pointer<Uint16> root) {
  // 三个 ULARGE_INTEGER 输出：free available / total / total free
  const int bytes = 8 * 3;
  final Pointer<Uint8> raw = k.localAlloc(_lptr, bytes);
  if (raw == nullptr) return null;
  try {
    final Pointer<Uint64> out = raw.cast<Uint64>();
    final int ok = k.getDiskFreeSpaceEx(
      root,
      out,
      out + 1, // 指针算术（`elementAt` 在本 SDK 已 deprecated）
      out + 2,
    );
    if (ok == 0) return null;
    return out.value;
  } finally {
    k.localFree(raw);
  }
}

/// 卷标（`GetVolumeInformationW` 的第一个输出，只取名字、其余全传 `null`）。
///
/// 没起过名的盘返回 `null`（调用失败与「空卷标」都按没有处理 —— **未知不猜值**）。
String? _volumeLabelOf(_Kernel32 k, Pointer<Uint16> root) {
  // MAX_PATH + 1（卷标最长 32 字符，但按 MAX_PATH 给足余量）
  const int chars = 261;
  final Pointer<Uint8> raw = k.localAlloc(_lptr, chars * 2);
  if (raw == nullptr) return null;
  try {
    final Pointer<Uint16> name = raw.cast<Uint16>();
    final int ok = k.getVolumeInformation(
      root,
      name,
      chars,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      0,
    );
    if (ok == 0) return null;
    // 读到 NUL 为止
    int len = 0;
    while (len < chars && (name + len).value != 0) {
      len++;
    }
    if (len == 0) return null;
    return String.fromCharCodes(name.asTypedList(len));
  } finally {
    k.localFree(raw);
  }
}
