/// 扫码失败的**中文解释**（M03，2026-10-08）。
///
/// 判断与文案都在本文件（**纯 Dart，`dart test` 钉得住**），UI 只做摆放 ——
/// 与备份 / 导出 / 三态条的措辞同一条纪律（`docs/ui_principles.md` §二：
/// 错误信息由领域层给出，UI 不造句）。
///
/// ⚠️ **入参是 `MobileScannerErrorCode.name`（字符串）** —— 本包是纯 Dart，
/// 刻意**不依赖 `mobile_scanner`**（插件 import Flutter，进来就破了纯 Dart 边界，
/// `dart test` 直接跑不起来）。用字符串解耦的代价是「枚举改名不会编译报错」，
/// 所以 [scanFailureKindOf] 兜底成 [ScanFailureKind.generic]，
/// 且断言里钉住三个真实名字（`mobile_scanner` 的枚举名是稳定 API）。
library;

/// 扫码失败的类别（**只分用户能采取不同行动的三种**）。
enum ScanFailureKind {
  /// 相机权限被拒 —— 唯一「用户能自己修」的一类（去系统设置开权限）。
  permissionDenied,

  /// 设备没有可用相机 / 不支持扫码 —— 用户改不了，只能换设备。
  unsupported,

  /// 其它（插件内部错、相机被别的 App 占用等）—— 重试或重启。
  generic,
}

/// 由 `MobileScannerErrorCode.name` 归类。
///
/// **未知值一律 [ScanFailureKind.generic]** —— 宁可笼统，也不乱猜一个
/// 用户照着做却无效的指引。
ScanFailureKind scanFailureKindOf(String errorCodeName) => switch (errorCodeName) {
  'permissionDenied' => ScanFailureKind.permissionDenied,
  'unsupported' => ScanFailureKind.unsupported,
  _ => ScanFailureKind.generic,
};

/// 给用户看的**中文**说明（含「怎么办」）。
///
/// ⚠️ **绝不回显英文原文 / 类名 / 栈**（M15 同一条纪律）—— 那些对用户
/// 零价值，只会让人以为软件坏了。原文由调用方送进日志。
String scanFailureMessage(ScanFailureKind kind) => switch (kind) {
  ScanFailureKind.permissionDenied =>
    '没有相机权限，扫不了码。\n'
        '请到手机的「设置 → 应用 → 神算子 → 权限」里，把「相机」打开，'
        '再回到本页重试。',
  ScanFailureKind.unsupported =>
    '这台设备上打不开相机（可能没有可用的相机），没法扫码连接。\n'
        '请在电脑端确认配对二维码后，换一台带相机的设备再试。',
  ScanFailureKind.generic =>
    '相机暂时打不开。\n'
        '请退出本页再进来试一次；还是不行就重启一下手机。',
};
