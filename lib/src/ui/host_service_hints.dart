/// 「多设备同步」面板的**文案**（纯函数，UI 只渲染）—— 2026-11-01。
///
/// ## 为什么单独一个文件
///
/// 仓内一贯的做法：**文案在纯 Dart 层，UI 只负责摆放**（`sync_failure_message.dart`
/// 就是同一套路）。好处是这些话能被 `dart test` 直接钉住 ——
/// 而这次的文案**分叉很多**（提案 57 裁定 ②③⑤ 要求「原因不同，话就不一样」），
/// 埋在 widget 里就只能靠人眼在真机上一屏一屏点。
///
/// ## 三组文案
///
/// 1. **持久化提示**（[hostPersistHint]）：写盘失败 / 加密失败 —— 都意味着
///    「这次能用，重启要重来」，但**原因不同**（一个是文件写不进，一个是系统加密不可用），
///    不许混成一句，更不许报成「保存成功」。
/// 2. **画不出码的说明**（[hostRestoreHint]）：按 `TokenRestoreState` 分五种。
/// 3. 其余（开关说明等）仍在 `host_service_section.dart` 里，属于纯摆放。
library;

import 'package:shensuanzi_host/shensuanzi_host.dart';

/// 持久化提示（`null` = 一切正常，不提示）。
///
/// [writeFailed] = `host.json` 写不进去；[protectFailed] = 系统加密不可用
/// （只写进了哈希）。**两者都发生**时只说前者 —— 写盘失败更严重，
/// 而且加密失败的前提（写进去）本来就不成立了。
String? hostPersistHint({
  required bool writeFailed,
  required bool protectFailed,
}) {
  if (writeFailed) {
    return '配对码只对这次运行有效 —— 写不进数据文件夹里的 host.json。'
        '手机现在照样能连；下次开机再连时，要重新生成一次码。';
  }
  if (protectFailed) {
    return '这次的配对码没能加密存下来（系统加密不可用），只存了校验用的哈希。'
        '手机现在照样能连；下次开机会需要重新生成一次码。';
  }
  return null;
}

/// 「画不出二维码」时的说明 —— **原因不同，话就不一样**。
///
/// | `tokenRestore` | 对用户说什么 |
/// |---|---|
/// | `undecryptable` | 换了 Windows 用户 / 换了电脑（这是有意的） |
/// | `mismatch` | 两份身份数据对不上 ⇒ 按不可信处理 |
/// | `unsupported` | 存储格式不认识（可能被别的版本改过） |
/// | `hashOnly` | 只存了哈希（旧文件 / 加密失败） |
/// | `missing` / `restored` | 兜底（正常走不到） |
String hostRestoreHint(HostServiceSnapshot snapshot) {
  final String tail = '${HostServiceSnapshot.resetWarning}。';
  switch (snapshot.tokenRestore) {
    case TokenRestoreState.undecryptable:
      return '这台电脑换了 Windows 用户、或者换了一台电脑 —— '
          '之前配对码的加密副本打不开（这是有意的：换机器本来就该重新配对）。'
          '要连新手机请重新生成一次，手机会需要重扫。$tail';
    case TokenRestoreState.mismatch:
      return '身份文件里的两份数据对不上（密文解出来的令牌和哈希不一致）—— '
          '安全起见按不可信处理，不会拿它画码。请重新生成一次。$tail';
    case TokenRestoreState.unsupported:
      return '配对码的存储格式这台电脑不认识（可能被别的版本改过）。'
          '请重新生成一次。$tail';
    case TokenRestoreState.hashOnly:
    case TokenRestoreState.missing:
    case TokenRestoreState.restored:
      return '这台电脑重启过了，之前的配对码显示不出来（为安全起见，'
          '码上的令牌没有存到硬盘）。$tail';
  }
}
