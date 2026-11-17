/// 「进程从**被创建**到现在过了多久」—— 补上 `main()` 之前那段**任何 Dart 埋点都看不见**的时间。
///
/// ## 为什么需要它（2026-11-17 真机 14 秒）
///
/// 用户报「双击后 14 秒才出窗口」。而带埋点那几次的记录是：
///
/// ```
/// T0_main=0  T1_run_app=8  T4_first_frame=21  T2_db_open=43  T3b=43
/// ```
///
/// ⇒ **进程内一共只花了 43 ms**。也就是说那 14 秒**根本不在 Dart 的时间轴上** ——
/// 它发生在 `main()` 之前：`CreateProcess` → 加载 34 MB 的 exe / DLL（未签名，
/// 杀软首扫就在这里）→ Flutter 引擎初始化 → Dart isolate 起来。
///
/// 现有埋点的计时器**在 `main()` 第一行才起表**，所以那一段永远是 0
/// ——「看不见」不等于「没有」，这次就是被它骗了一轮。
///
/// ## 用什么拿
///
/// `kernel32!GetProcessTimes(GetCurrentProcess(), …)` 返回**进程创建时间**
/// （内核记账，`CreateProcess` 那一刻就写好了）。拿它和「现在」一比，
/// 就是「进程活了多久」= 到 `main()` 之前的那段 + 已经在跑的那段。
///
/// 为什么不自己记「本次启动时间」再和文件时间比：那是**另一个时钟源**（文件系统时间戳
/// 精度 / 时区 / 缓存都会掺进来），而 `GetProcessTimes` 与 `DateTime.now()` 都基于
/// 系统时钟，两个 FILETIME 直接相减，不引入第三个数。
///
/// ## 边界
///
/// - **只在 Windows 上有值**；其它平台返回 `null`（本 App 的桌面端只有 Windows）。
/// - **任何异常都吞掉返回 `null`** —— 这是诊断信息，绝不许因为它让软件起不来。
/// - 结果**可能是 0**（同一毫秒内），这是正常值，不要当成「拿不到」。
library;

import 'dart:ffi';
import 'dart:io' show Platform;

/// 1601-01-01 → 1970-01-01 的 100 ns 数（`FILETIME` 的纪元差）。
const int _fileTimeEpochDelta = 116444736000000000;

/// 纯函数：把 `DateTime` 换成 Win32 的 `FILETIME`（**100 ns** 为单位，起点 1601 UTC）。
///
/// 单独抽出来是为了可测 —— FFI 那条路径在测试里只能验「非空、非负」，
/// 换算错了却是**静默**的（数字看着像对的），必须有纯函数钉住。
int fileTimeOf(DateTime time) =>
    time.toUtc().microsecondsSinceEpoch * 10 + _fileTimeEpochDelta;

/// 纯函数：两个 `FILETIME` 相差多少毫秒。
///
/// `FILETIME` 是 100 ns 一格 ⇒ 除以 10 000。用整数除法（不四舍五入）：
/// 这个数只用来判断量级（43 ms 还是 13 900 ms），一位小数没有意义。
int msBetweenFileTimes(int now, int created) => (now - created) ~/ 10000;

/// 当前进程已经活了多久（毫秒）。拿不到返回 `null`。
///
/// 放在 `main()` 第一行调用：那一刻的值 ≈「`CreateProcess` → `main()`」，
/// 也就是**加载器 + 引擎初始化 + 杀软首扫**的全部耗时。
int? currentProcessAgeMs() {
  if (!Platform.isWindows) return null;
  final _Kernel32? k = _cached ?? _openKernel32();
  if (k == null) return null;

  // 4 个 FILETIME 连着放共 32 字节；只需要第 0 个（创建时间），
  // 但另外三个是**必填出参**，不给 NULL 会被拒绝（ERROR_INVALID_PARAMETER）。
  // 用 LPTR（= LMEM_FIXED | LMEM_ZEROINIT，0x0040）拿一块可写内存；
  // 不用 `package:ffi` 的 `calloc` —— 本包不为一次分配新增依赖
  //（`windows_drives.dart` 也是这么做的）。
  final Pointer<Uint32> buf = k.localAlloc(0x0040, 32);
  if (buf == nullptr) return null;
  try {
    // 伪句柄 -1 = 当前进程（`GetCurrentProcess()` 的返回值就是这个常量）
    final int ok = k.getProcessTimes(
      -1,
      buf,
      buf + 2, // +8 字节：lpExitTime
      buf + 4, // +16：lpKernelTime
      buf + 6, // +24：lpUserTime
    );
    if (ok == 0) return null;
    // 低 32 位在前、高 32 位在后（`FILETIME` 也是小端结构体）
    final int created = ((buf + 1).value << 32) | buf.value;
    final int ms = msBetweenFileTimes(fileTimeOf(DateTime.now()), created);
    // 时钟被往回调过（或系统时间跳变）⇒ 负数没有意义，当拿不到
    return ms < 0 ? null : ms;
  } catch (_) {
    return null;
  } finally {
    k.localFree(buf);
  }
}

/// 惰性缓存：`DynamicLibrary.open` + 三次 `lookupFunction` 只做一次。
_Kernel32? _cached;
bool _openFailed = false;

_Kernel32? _openKernel32() {
  if (_openFailed) return null;
  try {
    return _cached = _Kernel32.open();
  } catch (_) {
    // 打开失败就记住，别每次调用重试（那会在启动路径上反复抛异常）
    _openFailed = true;
    return null;
  }
}

// `IntPtr` 用于 HANDLE：x64 上是 64 位，用 Int32 会被截断。
typedef _GetProcessTimesNative = Int32 Function(
  IntPtr hProcess,
  Pointer<Uint32> creation,
  Pointer<Uint32> exit,
  Pointer<Uint32> kernel,
  Pointer<Uint32> user,
);
typedef _GetProcessTimesDart = int Function(
  int hProcess,
  Pointer<Uint32> creation,
  Pointer<Uint32> exit,
  Pointer<Uint32> kernel,
  Pointer<Uint32> user,
);

typedef _LocalAllocNative = Pointer<Uint32> Function(Uint32 flags, IntPtr bytes);
typedef _LocalAllocDart = Pointer<Uint32> Function(int flags, int bytes);

typedef _LocalFreeNative = Pointer<Uint32> Function(Pointer<Uint32> mem);
typedef _LocalFreeDart = Pointer<Uint32> Function(Pointer<Uint32> mem);

class _Kernel32 {
  _Kernel32._(this.getProcessTimes, this.localAlloc, this.localFree);

  factory _Kernel32.open() {
    final DynamicLibrary lib = DynamicLibrary.open('kernel32.dll');
    return _Kernel32._(
      lib.lookupFunction<_GetProcessTimesNative, _GetProcessTimesDart>(
        'GetProcessTimes',
      ),
      lib.lookupFunction<_LocalAllocNative, _LocalAllocDart>('LocalAlloc'),
      lib.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree'),
    );
  }

  final _GetProcessTimesDart getProcessTimes;
  final _LocalAllocDart localAlloc;
  final _LocalFreeDart localFree;
}
