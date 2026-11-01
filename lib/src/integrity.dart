/// 进程的**完整性级别**（Windows 强制完整性控制，MIC）—— 2026-11-01。
///
/// ## 为什么需要它（真机踩了整整两天）
///
/// 联调 #1 那个「`host.json` 写不进去，`errno = 5`」查了很久：ACL 正常、
/// 没有只读属性、没有杀软拦截、同一个用户下 `dart run` 却能写。
/// 最后真相是 —— **进程跑在 Low 完整性级别**：
///
/// ```
/// icacls D:\shensuanzi\shensuanzi
///   Mandatory Label\Low Mandatory Level:(OI)(CI)(NW)     ← 仓库根带 Low 标签
/// build\...\Release\shensuanzi.exe
///   Mandatory Label\Low Mandatory Level:(I)(NW)          ← exe 继承了它
/// ```
///
/// **带 Low 标签的 exe，Windows 会以 Low 完整性启动它**；而 Low 进程
/// **不能写** Medium 标签的对象（`%APPDATA%` / `%LOCALAPPDATA%` / 数据目录全是 Medium）
/// ⇒ 每一次写都是「拒绝访问」。
///
/// 用户侧表现：改设置存不住、配对码存不住、开单也存不住 —— 但**读**一切正常，
/// 所以看起来像「软件偶尔抽风」，而不是「没权限」。
///
/// ## 为什么要在启动时自检
///
/// 这种状态下**什么都存不下来**，用户却可能先用半小时录单再发现白干。
/// 一句人话的提示 + 三条能自己走的路，比日志里的一行 `errno = 5` 有用得多。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 完整性级别（只关心前五档；`unknown` = 非 Windows / 查询失败）
enum IntegrityLevel {
  /// 不可信（`S-1-16-0`）
  untrusted,

  /// 低（`S-1-16-4096`）—— **就是这个会写不进去**
  low,

  /// 中（`S-1-16-8192`）—— 普通用户双击启动的正常值
  medium,

  /// 高（`S-1-16-12288`）—— 「以管理员身份运行」
  high,

  /// 系统（`S-1-16-16384`）
  system,

  /// 查不出来（非 Windows / 老系统 / 调用失败）
  unknown,
}

/// 读**当前进程**的完整性级别。**永不抛** —— 查不到就是 [IntegrityLevel.unknown]。
IntegrityLevel detectIntegrityLevel() {
  if (!Platform.isWindows) return IntegrityLevel.unknown;
  try {
    return _readIntegrity();
  } catch (_) {
    return IntegrityLevel.unknown;
  }
}

/// 「以低权限启动」时给用户看的那段话（`null` = 正常，不用提示）。
///
/// 抽成**纯函数**是为了能被 `dart test` 直接钉住 —— 这种提示只在
/// 特定机器上才会出现，靠人眼验太贵。
String? lowIntegrityNotice(IntegrityLevel level) {
  if (level != IntegrityLevel.low && level != IntegrityLevel.untrusted) {
    return null;
  }
  return '这个程序是以「低权限」方式启动的，所以**什么都存不下来**：'
      '改设置、生成配对码、录单都会提示「拒绝访问」。\n\n'
      '程序本身没坏，账目也没丢（读得到）。常见原因是：'
      '程序文件所在的文件夹带了「低完整性」标记 —— '
      '从网上下载、解压、或整包拷过来的文件夹经常是这样。\n\n'
      '怎么办（任选一种，都不影响已有账目）：\n'
      '一、把整个程序文件夹**复制到别的位置**（例如 D:\\神算子），'
      '双击新位置里的 shensuanzi.exe；\n'
      '二、或者右键那个 shensuanzi.exe → 属性 → 勾上「解除锁定」→ 确定，再打开；\n'
      '三、还不行就把这句话发给技术支持：「进程完整性 = Low」。\n\n'
      '⚠️ 修好之前别在这个窗口里录单 —— 存不进去。';
}

// ---------------------------------------------------------------- FFI

typedef _OpenProcessTokenNative =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>);
typedef _OpenProcessTokenDart =
    int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);

typedef _GetTokenInformationNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32, Pointer<Uint32>);
typedef _GetTokenInformationDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>);

typedef _GetSidSubAuthorityCountNative = Pointer<Uint8> Function(Pointer<Void>);
typedef _GetSidSubAuthorityCountDart = Pointer<Uint8> Function(Pointer<Void>);

typedef _GetSidSubAuthorityNative =
    Pointer<Uint32> Function(Pointer<Void>, Uint32);
typedef _GetSidSubAuthorityDart = Pointer<Uint32> Function(Pointer<Void>, int);

typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandleDart = int Function(Pointer<Void>);

typedef _GetCurrentProcessNative = Pointer<Void> Function();
typedef _GetCurrentProcessDart = Pointer<Void> Function();

const int _tokenQuery = 0x0008;
const int _tokenIntegrityLevel = 25; // TOKEN_INFORMATION_CLASS
const int _bufferSize = 256;

IntegrityLevel _readIntegrity() {
  final DynamicLibrary advapi = DynamicLibrary.open('advapi32.dll');
  final DynamicLibrary kernel = DynamicLibrary.open('kernel32.dll');

  final _OpenProcessTokenDart openProcessToken = advapi
      .lookupFunction<_OpenProcessTokenNative, _OpenProcessTokenDart>(
        'OpenProcessToken',
      );
  final _GetTokenInformationDart getTokenInformation = advapi
      .lookupFunction<_GetTokenInformationNative, _GetTokenInformationDart>(
        'GetTokenInformation',
      );
  final _GetSidSubAuthorityCountDart subAuthorityCount = advapi
      .lookupFunction<_GetSidSubAuthorityCountNative,
          _GetSidSubAuthorityCountDart>('GetSidSubAuthorityCount');
  final _GetSidSubAuthorityDart subAuthority = advapi
      .lookupFunction<_GetSidSubAuthorityNative, _GetSidSubAuthorityDart>(
        'GetSidSubAuthority',
      );
  final _CloseHandleDart closeHandle = kernel
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
  // 用真函数拿伪句柄 —— `Pointer.fromAddress(-1)` 在 Dart 里是负数，会抛
  final _GetCurrentProcessDart currentProcess = kernel
      .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
        'GetCurrentProcess',
      );

  final Pointer<Pointer<Void>> tokenPtr = calloc<Pointer<Void>>();
  final Pointer<Uint8> buffer = calloc<Uint8>(_bufferSize);
  final Pointer<Uint32> returned = calloc<Uint32>();
  try {
    if (openProcessToken(currentProcess(), _tokenQuery, tokenPtr) == 0) {
      return IntegrityLevel.unknown;
    }
    final Pointer<Void> token = tokenPtr.value;
    if (token == nullptr) return IntegrityLevel.unknown;
    try {
      final int ok = getTokenInformation(
        token,
        _tokenIntegrityLevel,
        buffer.cast(),
        _bufferSize,
        returned,
      );
      if (ok == 0) return IntegrityLevel.unknown;

      // TOKEN_MANDATORY_LABEL { SID_AND_ATTRIBUTES Label { PSID Sid; DWORD Attributes } }
      // ⇒ 头 8 字节就是 SID 指针（x64）
      final Pointer<Void> sid = buffer.cast<Pointer<Void>>().value;
      if (sid == nullptr) return IntegrityLevel.unknown;

      final int count = subAuthorityCount(sid).value;
      if (count <= 0) return IntegrityLevel.unknown;
      final int rid = subAuthority(sid, count - 1).value;
      return integrityLevelOfRid(rid);
    } finally {
      closeHandle(token);
    }
  } finally {
    calloc
      ..free(tokenPtr)
      ..free(buffer)
      ..free(returned);
  }
}

/// `SECURITY_MANDATORY_*_RID` → 枚举（**公开**：好让 `dart test` 直接钉映射）
IntegrityLevel integrityLevelOfRid(int rid) => switch (rid) {
  0x0000 => IntegrityLevel.untrusted,
  0x1000 => IntegrityLevel.low,
  0x2000 => IntegrityLevel.medium,
  0x3000 => IntegrityLevel.high,
  0x4000 => IntegrityLevel.system,
  _ => IntegrityLevel.unknown,
};
